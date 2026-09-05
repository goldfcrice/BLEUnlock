import Cocoa
import AVFoundation

let notifyEventNames = ["authFailed", "intruded", "away", "lost", "unlocked"]

func notifyEventKey(for event: String) -> String? {
    guard notifyEventNames.contains(event) else { return nil }
    return "notifyEvent_" + event
}

class RemoteNotifier {
    static let notifyMinRSSIKey = "notifyMinRSSI"
    static let notifyWithPhotoKey = "notifyWithPhoto"
    static let telegramBotTokenKey = "telegramBotToken"
    static let telegramChatIDKey = "telegramChatID"
    static let barkServerKey = "barkServer"
    static let barkDeviceKeyKey = "barkDeviceKey"

    private let prefs = UserDefaults.standard
    private let session = URLSession.shared

    func handle(event: String, rssi: Int?) {
        guard let key = notifyEventKey(for: event), prefs.bool(forKey: key) else { return }
        if let rssi, !passesRSSIThreshold(rssi) { return }

        let title = "BLEUnlock"
        let body = composeBody(event: event, rssi: rssi)
        guard hasChannel else { return }

        let send = { (photo: Data?) in
            self.send(title: title, body: body, photo: photo)
        }
        if prefs.bool(forKey: Self.notifyWithPhotoKey) {
            PhotoCapture.capture { photo in
                send(photo)
            }
        } else {
            send(nil)
        }
    }

    func sendTest() {
        let body = composeBody(event: "test", rssi: nil)
        if prefs.bool(forKey: Self.notifyWithPhotoKey) {
            PhotoCapture.capture { photo in
                self.send(title: "BLEUnlock", body: body, photo: photo)
            }
        } else {
            send(title: "BLEUnlock", body: body, photo: nil)
        }
    }

    var hasChannel: Bool {
        telegramConfigured || barkConfigured
    }

    var telegramConfigured: Bool {
        !(prefs.string(forKey: Self.telegramBotTokenKey) ?? "").isEmpty &&
        !(prefs.string(forKey: Self.telegramChatIDKey) ?? "").isEmpty
    }

    var barkConfigured: Bool {
        !(prefs.string(forKey: Self.barkDeviceKeyKey) ?? "").isEmpty
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

    private func send(title: String, body: String, photo: Data?) {
        if telegramConfigured {
            sendTelegram(title: title, body: body, photo: photo)
        }
        if barkConfigured {
            sendBark(title: title, body: body, photo: photo)
        }
    }

    private func sendTelegram(title: String, body: String, photo: Data?) {
        let token = prefs.string(forKey: Self.telegramBotTokenKey) ?? ""
        let chatID = prefs.string(forKey: Self.telegramChatIDKey) ?? ""
        let text = "\(title)\n\(body)"

        if let photo {
            let url = URL(string: "https://api.telegram.org/bot\(token)/sendPhoto")!
            var request = URLRequest(url: url)
            let boundary = "BLEUnlock-\(UUID().uuidString)"
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var data = Data()
            func appendField(_ name: String, _ value: String) {
                data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
            }
            appendField("chat_id", chatID)
            appendField("caption", text)
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(photo)
            data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = data
            run(request, channel: "telegram")
        } else {
            var components = URLComponents(string: "https://api.telegram.org/bot\(token)/sendMessage")!
            components.queryItems = [
                URLQueryItem(name: "chat_id", value: chatID),
                URLQueryItem(name: "text", value: text),
            ]
            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            run(request, channel: "telegram")
        }
    }

    private func sendBark(title: String, body: String, photo: Data?) {
        var server = prefs.string(forKey: Self.barkServerKey) ?? ""
        if server.isEmpty { server = "https://api.day.app" }
        while server.hasSuffix("/") { server.removeLast() }
        let deviceKey = prefs.string(forKey: Self.barkDeviceKeyKey) ?? ""
        guard let url = URL(string: "\(server)/\(deviceKey)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["title": title, "body": body, "group": "BLEUnlock"]
        // Bark shows the image as an attachment; skip it when the payload gets too large.
        if let photo, photo.base64EncodedString().count < 2_000_000 {
            fields["image"] = photo.base64EncodedString()
        }
        let parts = fields.map { k, v -> String in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)"
        }
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        run(request, channel: "bark")
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

// Grabs a single JPEG frame from the front camera. Runs its work off the main
// thread; completion is called with nil on any failure (or a TCC denial).
class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private static let queue = DispatchQueue(label: "com.github.goldfcrice.BLEUnlock.photo-capture")
    private var completion: ((Data?) -> Void)?
    private var output = AVCapturePhotoOutput()
    private var session = AVCaptureSession()

    // Keep the in-flight capture alive; its only other references are weak.
    private static var current: PhotoCapture?

    static func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted { print("RemoteNotifier: camera access denied") }
        }
    }

    static func capture(completion: @escaping (Data?) -> Void) {
        queue.async {
            let capturer = PhotoCapture()
            Self.current = capturer
            capturer.shoot { data in
                Self.queue.async { Self.current = nil }
                completion(data)
            }
        }
    }

    private func shoot(completion: @escaping (Data?) -> Void) {
        self.completion = { [weak self] data in
            self?.finish()
            DispatchQueue.main.async { completion(data) }
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ??
                            AVCaptureDevice.default(for: .video) else {
            self.completion?(nil)
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            self.completion?(nil)
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }

        // Overall timeout: never leave the caller hanging (e.g. camera in use / TCC prompt).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.completion?(nil)
        }
    }

    private func finish() {
        completion = nil
        Self.queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.inputs.forEach { self.session.removeInput($0) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        completion?(error == nil ? photo.fileDataRepresentation() : nil)
    }
}
