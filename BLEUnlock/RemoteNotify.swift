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

    func savePhotoLocally(_ photo: Data, event: String) {
        guard prefs.bool(forKey: Self.savePhotoLocallyKey) else { return }
        let dir = Self.photoDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
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

        let body = composeBody(event: event, rssi: rssi)
        guard hasChannel else { return }

        let send = { (photo: Data?) in
            self.send(event: event, body: body, photo: photo)
        }
        if prefs.bool(forKey: Self.notifyWithPhotoKey) {
            if #available(macOS 10.15, *) {
                PhotoCapture.capture { photo in
                    send(photo)
                }
            } else {
                send(nil)
            }
        } else {
            send(nil)
        }
    }

    func sendTest() {
        let body = composeBody(event: "test", rssi: nil)
        guard hasChannel else { return }
        if prefs.bool(forKey: Self.notifyWithPhotoKey) {
            if #available(macOS 10.15, *) {
                PhotoCapture.capture { photo in
                    self.send(event: "test", body: body, photo: photo)
                }
            } else {
                send(event: "test", body: body, photo: nil)
            }
        } else {
            send(event: "test", body: body, photo: nil)
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

    private func send(event: String, body: String, photo: Data?) {
        if let photo {
            savePhotoLocally(photo, event: event)
        }
        if telegramConfigured && channelEnabled("telegram") {
            sendTelegram(body: body, photo: photo)
        }
        if barkConfigured && channelEnabled("bark") {
            sendBark(body: body)
        }
        if wecomConfigured && channelEnabled("wecom") {
            sendWecom(body: body, photo: photo)
        }
    }

    private func sendTelegram(body: String, photo: Data?) {
        let text = "BLEUnlock\n\(body)"

        if let photo {
            let url = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendPhoto")!
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
            run(request, channel: "telegram")
        } else {
            let url = URL(string: "https://api.telegram.org/bot\(telegramToken)/sendMessage")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let parts = [
                "chat_id=\(urlEncoded(telegramChatID))",
                "text=\(urlEncoded(text))",
            ]
            request.httpBody = parts.joined(separator: "&").data(using: .utf8)
            run(request, channel: "telegram")
        }
    }

    // Bark's iOS client only renders `image` as a remote URL (no base64), so
    // this channel is text-only by design.
    private func sendBark(body: String) {
        var server = barkServer
        if server.isEmpty { server = "https://api.day.app" }
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: "\(server)/\(urlEncoded(barkDeviceKey))") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["title": "BLEUnlock", "body": body, "group": "BLEUnlock"]
        let parts = fields.map { k, v -> String in
            "\(k)=\(urlEncoded(v))"
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        run(request, channel: "bark")
    }

    // WeCom group bot webhook: text by default, image message only when a
    // photo was captured (image limit is 2MB before base64).
    private func sendWecom(body: String, photo: Data?) {
        let base = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=\(wecomKey)"
        guard let url = URL(string: base) else { return }

        func post(_ json: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            run(request, channel: "wecom")
        }

        post(["msgtype": "text", "text": ["content": "BLEUnlock\n\(body)"]])
        if let photo, let small = Self.downscaledJPEG(photo, maxPixel: 1280) {
            post(["msgtype": "image", "image": [
                "base64": small.base64EncodedString(),
                "md5": Self.md5Hex(small),
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

    private static func downscaledJPEG(_ data: Data, maxPixel: Int = 480) -> Data? {
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

    private func run(_ request: URLRequest, channel: String) {
        session.dataTask(with: request) { _, response, error in
            if let error {
                print("RemoteNotifier[\(channel)]: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("RemoteNotifier[\(channel)]: HTTP \(http.statusCode)")
            }
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
