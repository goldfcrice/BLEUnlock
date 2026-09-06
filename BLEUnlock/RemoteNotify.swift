import Cocoa
import AVFoundation
import ImageIO
import Security

let notifyEventNames = ["authFailed", "intruded", "away", "lost", "unlocked"]

func notifyEventKey(for event: String) -> String? {
    guard notifyEventNames.contains(event) else { return nil }
    return "notifyEvent_" + event
}

// Credentials (Telegram token, Bark key) live in the Keychain, not UserDefaults.
enum CredentialStore {
    private static let service = "com.github.goldfcrice.BLEUnlock.remote-notify"

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrService): service,
            String(kSecAttrAccount): account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[String(kSecValueData)] = Data(value.utf8)
        add[String(kSecAttrAccessible)] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrService): service,
            String(kSecAttrAccount): account,
            String(kSecReturnData): true,
            String(kSecMatchLimit): kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // One-time move of values that earlier builds stored in UserDefaults.
    static func migrateFromDefaults(_ key: String, account: String) {
        let prefs = UserDefaults.standard
        guard prefs.object(forKey: key) != nil else { return }
        let value = prefs.string(forKey: key) ?? ""
        set(value, account: account)
        prefs.removeObject(forKey: key)
    }
}

class RemoteNotifier {
    static let notifyMinRSSIKey = "notifyMinRSSI"
    static let notifyWithPhotoKey = "notifyWithPhoto"

    private static let telegramTokenAccount = "telegramToken"
    private static let telegramChatIDAccount = "telegramChatID"
    private static let barkServerAccount = "barkServer"
    private static let barkDeviceKeyAccount = "barkDeviceKey"
    private static let legacyDefaultsAccounts = [
        "telegramBotToken": telegramTokenAccount,
        "telegramChatID": telegramChatIDAccount,
        "barkServer": barkServerAccount,
        "barkDeviceKey": barkDeviceKeyAccount,
    ]

    private let prefs = UserDefaults.standard
    private let session = URLSession.shared

    init() {
        for (key, account) in Self.legacyDefaultsAccounts {
            CredentialStore.migrateFromDefaults(key, account: account)
        }
    }

    // MARK: - Configuration

    var telegramToken: String { CredentialStore.get(Self.telegramTokenAccount) ?? "" }
    var telegramChatID: String { CredentialStore.get(Self.telegramChatIDAccount) ?? "" }
    var barkServer: String { CredentialStore.get(Self.barkServerAccount) ?? "" }
    var barkDeviceKey: String { CredentialStore.get(Self.barkDeviceKeyAccount) ?? "" }

    static func setTelegram(token: String, chatID: String) {
        CredentialStore.set(token, account: telegramTokenAccount)
        CredentialStore.set(chatID, account: telegramChatIDAccount)
    }

    static func setBark(server: String, deviceKey: String) {
        CredentialStore.set(server, account: barkServerAccount)
        CredentialStore.set(deviceKey, account: barkDeviceKeyAccount)
    }

    var hasChannel: Bool {
        telegramConfigured || barkConfigured
    }

    var telegramConfigured: Bool {
        !telegramToken.isEmpty && !telegramChatID.isEmpty
    }

    var barkConfigured: Bool {
        !barkDeviceKey.isEmpty
    }

    // MARK: - Dispatch

    func handle(event: String, rssi: Int?) {
        guard let key = notifyEventKey(for: event), prefs.bool(forKey: key) else { return }
        if let rssi, !passesRSSIThreshold(rssi) { return }

        let body = composeBody(event: event, rssi: rssi)
        guard hasChannel else { return }

        let send = { (photo: Data?) in
            self.send(body: body, photo: photo)
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
                    self.send(body: body, photo: photo)
                }
            } else {
                send(body: body, photo: nil)
            }
        } else {
            send(body: body, photo: nil)
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

    private func send(body: String, photo: Data?) {
        if telegramConfigured {
            sendTelegram(body: body, photo: photo)
        }
        if barkConfigured {
            sendBark(body: body, photo: photo)
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

    private func sendBark(body: String, photo: Data?) {
        var server = barkServer
        if server.isEmpty { server = "https://api.day.app" }
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: "\(server)/\(urlEncoded(barkDeviceKey))") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["title": "BLEUnlock", "body": body, "group": "BLEUnlock"]
        // Bark shows the image as an attachment, but its servers reject large
        // bodies (HTTP 413) — downscale aggressively and skip on overflow.
        if let photo, let small = Self.downscaledJPEG(photo), small.base64EncodedString().count < 200_000 {
            fields["image"] = small.base64EncodedString()
        }
        let parts = fields.map { k, v -> String in
            "\(k)=\(urlEncoded(v))"
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        run(request, channel: "bark")
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
