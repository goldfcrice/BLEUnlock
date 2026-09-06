import Cocoa
import AVFoundation
import ImageIO
import Security
import CommonCrypto

let notifyEventNames = ["authFailed", "intruded", "away", "lost", "unlocked"]

func notifyEventKey(for event: String) -> String? {
    guard notifyEventNames.contains(event) else { return nil }
    return "notifyEvent_" + event
}

class RemoteNotifier {
    static let notifyMinRSSIKey = "notifyMinRSSI"
    static let notifyWithPhotoKey = "notifyWithPhoto"
    static let savePhotoLocallyKey = "notifySavePhotoLocally"

    private let prefs = UserDefaults.standard
    private let session = URLSession.shared

    private static let keychainService = "com.github.goldfcrice.BLEUnlock.remote-notify"
    private static let keychainAccounts = ["telegramToken", "telegramChatID", "barkServer", "barkDeviceKey", "wecomWebhookKey"]
    private static let defaultsKeys = [
        "telegramToken": "telegramBotToken",
        "telegramChatID": "telegramChatID",
        "barkServer": "barkServer",
        "barkDeviceKey": "barkDeviceKey",
        "wecomWebhookKey": "wecomKey",
    ]

    // One-time move of credentials that earlier builds kept in the Keychain;
    // reading those items prompted for the login password on every reinstall,
    // so they are plain user preferences now and live in UserDefaults.
    private static func migrateFromKeychain() {
        for account in keychainAccounts {
            let query: [String: Any] = [
                String(kSecClass): kSecClassGenericPassword,
                String(kSecAttrService): keychainService,
                String(kSecAttrAccount): account,
                String(kSecReturnData): true,
            ]
            var item: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let value = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(value, forKey: defaultsKeys[account] ?? account)
            }
            var delete = query
            delete.removeValue(forKey: String(kSecReturnData))
            SecItemDelete(delete as CFDictionary)
        }
    }

    init() {
        Self.migrateFromKeychain()
    }

    // MARK: - Configuration

    var telegramToken: String { prefs.string(forKey: "telegramBotToken") ?? "" }
    var telegramChatID: String { prefs.string(forKey: "telegramChatID") ?? "" }
    var barkServer: String { prefs.string(forKey: "barkServer") ?? "" }
    var barkDeviceKey: String { prefs.string(forKey: "barkDeviceKey") ?? "" }
    var wecomKey: String { prefs.string(forKey: "wecomKey") ?? "" }

    static func setTelegram(token: String, chatID: String) {
        let prefs = UserDefaults.standard
        prefs.set(token, forKey: "telegramBotToken")
        prefs.set(chatID, forKey: "telegramChatID")
    }

    static func setBark(server: String, deviceKey: String) {
        let prefs = UserDefaults.standard
        prefs.set(server, forKey: "barkServer")
        prefs.set(deviceKey, forKey: "barkDeviceKey")
    }

    static func setWecom(key: String) {
        UserDefaults.standard.set(key, forKey: "wecomKey")
    }

    static let channelEnableKeyPrefix = "notifyChannel_"

    func channelEnabled(_ channel: String) -> Bool {
        prefs.bool(forKey: Self.channelEnableKeyPrefix + channel)
    }

    func isChannelConfigured(_ channel: String) -> Bool {
        switch channel {
        case "telegram": return telegramConfigured
        case "bark": return barkConfigured
        case "wecom": return wecomConfigured
        default: return false
        }
    }

    static func setChannelEnabled(_ channel: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: channelEnableKeyPrefix + channel)
    }

    var hasChannel: Bool {
        (telegramConfigured && channelEnabled("telegram"))
            || (barkConfigured && channelEnabled("bark"))
            || (wecomConfigured && channelEnabled("wecom"))
    }

    var telegramConfigured: Bool {
        !telegramToken.isEmpty && !telegramChatID.isEmpty
    }

    var barkConfigured: Bool {
        !barkDeviceKey.isEmpty
    }

    var wecomConfigured: Bool {
        !wecomKey.isEmpty
    }

    static var photoDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/BLEUnlock", isDirectory: true)
    }

    // Expects the already-annotated JPEG; annotation is centralized in send().
    func savePhotoLocally(_ photo: Data, event: String) {
        guard prefs.bool(forKey: Self.savePhotoLocallyKey) else { return }
        let dir = Self.photoDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(df.string(from: Date()))-\(event).jpg"
        do {
            try photo.write(to: dir.appendingPathComponent(name))
        } catch {
            print("RemoteNotifier: failed to save photo locally: \(error.localizedDescription)")
        }
    }

    // MARK: - Dispatch

    func handle(event: String, rssi: Int?) {
        guard let key = notifyEventKey(for: event), prefs.bool(forKey: key) else { return }
        if let rssi, !passesRSSIThreshold(rssi) { return }
        guard hasChannel else { return }
        notify(event: event, rssi: rssi)
    }

    func sendTest() {
        guard hasChannel else { return }
        notify(event: "test", rssi: nil) { results in
            DispatchQueue.main.async {
                let lines = results.map { (channel, ok) -> String in
                    let name = channel == "wecom" ? "WeCom" : channel.capitalized
                    return (ok ? "✓ " : "✗ ") + name
                }.sorted().joined(separator: "\n")
                let allOk = !results.isEmpty && results.values.allSatisfy { $0 }
                let msg = NSAlert()
                msg.messageText = allOk ? t("notify_test_ok") : t("notify_test_failed")
                msg.informativeText = lines
                msg.window.title = "BLEUnlock"
                NSApp.activate(ignoringOtherApps: true)
                msg.runModal()
            }
        }
    }

    private func notify(event: String, rssi: Int?, report: (([String: Bool]) -> Void)? = nil) {
        let body = composeBody(event: event, rssi: rssi)
        let go = { (photo: Data?) in
            self.send(event: event, body: body, rssi: rssi, photo: photo, report: report)
        }
        if prefs.bool(forKey: Self.notifyWithPhotoKey), #available(macOS 10.15, *) {
            PhotoCapture.capture(completion: go)
        } else {
            go(nil)
        }
    }

    func passesRSSIThreshold(_ rssi: Int) -> Bool {
        let minRSSI = prefs.integer(forKey: Self.notifyMinRSSIKey)
        if minRSSI == 0 { return true }
        return rssi >= minRSSI
    }

    private func composeBody(event: String, rssi: Int?) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        var body = "Event: \(event) at \(df.string(from: Date()))"
        if let rssi { body += " (RSSI \(rssi) dBm)" }
        return body
    }

    // MARK: - Sending

    // Image decode/draw/encode is heavy; keep it off the main thread so event
    // timers and menu tracking never stall while a notification is prepared.
    private static let imageQueue = DispatchQueue(label: "com.github.goldfcrice.BLEUnlock.notify-images", qos: .userInitiated)

    private func send(event: String, body: String, rssi: Int?, photo: Data?, report: (([String: Bool]) -> Void)? = nil) {
        Self.imageQueue.async {
            var annotatedFull: Data?
            var annotatedWecom: Data?
            if let photo {
                // One caption burn at full resolution, reused for both the
                // local copy and Telegram.
                annotatedFull = Self.annotatedJPEG(photo, event: event, rssi: rssi)
                annotatedWecom = Self.downscaledJPEG(photo, maxPixel: 1280)
                    .flatMap { Self.annotatedJPEG($0, event: event, rssi: rssi) }
                self.savePhotoLocally(annotatedFull ?? photo, event: event)
            }

            var attempted: [String: Bool] = [:]
            var pending = 0
            func finish(channel: String, ok: Bool) {
                attempted[channel] = ok
                if attempted.count == pending, pending > 0, let report {
                    report(attempted)
                }
            }

            if self.telegramConfigured && self.channelEnabled("telegram") {
                pending += 1
                self.sendTelegram(body: body, photo: annotatedFull) { finish(channel: "telegram", ok: $0) }
            }
            if self.barkConfigured && self.channelEnabled("bark") {
                pending += 1
                self.sendBark(body: body) { finish(channel: "bark", ok: $0) }
            }
            if self.wecomConfigured && self.channelEnabled("wecom") {
                pending += 1
                self.sendWecom(body: body, photo: annotatedWecom) { finish(channel: "wecom", ok: $0) }
            }
            if pending == 0, let report {
                report([:])
            }
        }
    }

    // Burns a caption bar (timestamp | event | RSSI) into the photo before it
    // is sent or saved locally. Pixel-exact and safe off the main thread.
    private static func annotatedJPEG(_ data: Data, event: String, rssi: Int?) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return nil }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "\(df.string(from: Date()))   \(event)"
        if let rssi { text += "   RSSI \(rssi)dBm" }

        let fontSize = max(12, CGFloat(min(width, height)) / 22)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let barHeight = textSize.height + fontSize * 0.8

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(cgImage: cg, size: NSSize(width: width, height: height))
            .draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: barHeight).fill()
        str.draw(at: NSPoint(x: fontSize * 0.5, y: (barHeight - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private func sendTelegram(body: String, photo: Data?, completion: ((Bool) -> Void)? = nil) {
        let text = "BLEUnlock\n\(body)"

        if let photo {
            guard let url = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendPhoto") else { completion?(false); return }
            var request = URLRequest(url: url)
            let boundary = "BLEUnlock-\(UUID().uuidString)"
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var data = Data()
            func appendField(_ name: String, _ value: String) {
                data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
            }
            appendField("chat_id", telegramChatID)
            appendField("caption", text)
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(photo)
            data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = data
            run(request, channel: "telegram", completion: completion)
        } else {
            guard let url = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendMessage") else { completion?(false); return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let parts = [
                "chat_id=\(urlEncoded(telegramChatID))",
                "text=\(urlEncoded(text))",
            ]
            request.httpBody = parts.joined(separator: "&").data(using: .utf8)
            run(request, channel: "telegram", completion: completion)
        }
    }

    // Bark's iOS client only renders `image` as a remote URL (no base64), so
    // this channel is text-only by design.
    private func sendBark(body: String, completion: ((Bool) -> Void)? = nil) {
        var server = barkServer
        if server.isEmpty { server = "https://api.day.app" }
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: "\(server)/\(urlEncoded(barkDeviceKey))") else { completion?(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["title": "BLEUnlock", "body": body, "group": "BLEUnlock"]
        let parts = fields.map { k, v -> String in
            "\(k)=\(urlEncoded(v))"
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        run(request, channel: "bark", completion: completion)
    }

    // WeCom group bot webhook: text by default, image message only when a
    // photo was captured (image limit is 2MB before base64).
    private func sendWecom(body: String, photo: Data?, completion: ((Bool) -> Void)? = nil) {
        let base = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=\(wecomKey)"
        guard let url = URL(string: base) else { completion?(false); return }

        var anyFailed = false
        var remaining = 1 + (photo != nil ? 1 : 0)
        func post(_ json: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: json) else {
                completion?(false)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            run(request, channel: "wecom") { ok in
                if !ok { anyFailed = true }
                remaining -= 1
                if remaining == 0 { completion?(!anyFailed) }
            }
        }

        post(["msgtype": "text", "text": ["content": "BLEUnlock\n\(body)"]])
        if let photo {
            post(["msgtype": "image", "image": [
                "base64": photo.base64EncodedString(),
                "md5": Self.md5Hex(photo),
            ]])
        }
    }

    private static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func downscaledJPEG(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private func urlEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func run(_ request: URLRequest, channel: String, completion: ((Bool) -> Void)? = nil) {
        session.dataTask(with: request) { _, response, error in
            var ok = true
            if let error {
                print("RemoteNotifier[\(channel)]: \(error.localizedDescription)")
                ok = false
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("RemoteNotifier[\(channel)]: HTTP \(http.statusCode)")
                ok = false
            }
            completion?(ok)
        }.resume()
    }
}

// Grabs a single JPEG frame from the front camera. All state transitions happen
// on the serial PhotoCapture.queue, so double-fires (photo + timeout) and rapid
// back-to-back captures are coalesced instead of racing.
@available(macOS 10.15, *)
class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private static let queue = DispatchQueue(label: "com.github.goldfcrice.BLEUnlock.photo-capture")
    private static var current: PhotoCapture?
    private static var pending: [(Data?) -> Void] = []

    static func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { print("RemoteNotifier: camera access denied") }
        }
    }

    static func capture(completion: @escaping (Data?) -> Void) {
        queue.async {
            if Self.current != nil {
                // A capture is already in flight; piggyback on its result.
                Self.pending.append(completion)
                return
            }
            let capturer = PhotoCapture()
            Self.current = capturer
            Self.pending = [completion]
            capturer.shoot()
        }
    }

    private var output = AVCapturePhotoOutput()
    private var session = AVCaptureSession()

    private func deliver(_ data: Data?) {
        Self.queue.async {
            guard Self.current === self else { return }
            let completions = Self.pending
            Self.pending = []
            Self.current = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                if self.session.isRunning { self.session.stopRunning() }
                self.session.inputs.forEach { self.session.removeInput($0) }
            }
            completions.forEach { $0(data) }
        }
    }

    private func shoot() {
        // Do not trigger the TCC consent dialog from an event path; only the
        // explicit "attach photo" menu toggle asks for permission.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            deliver(nil)
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ??
                            AVCaptureDevice.default(for: .video) else {
            deliver(nil)
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            deliver(nil)
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            Self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, Self.current === self else { return }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }

        // Overall timeout: never leave the caller hanging (e.g. camera in use / TCC prompt).
        Self.queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, Self.current === self else { return }
            self.deliver(nil)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        deliver(error == nil ? photo.fileDataRepresentation() : nil)
    }
}
