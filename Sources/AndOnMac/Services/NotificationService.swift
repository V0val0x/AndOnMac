import Foundation
import Network
import UserNotifications
import AppKit

public final class NotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 58241
    public var onNotificationReceived: (@Sendable (NotificationItem) -> Void)?
    public var onDeviceDiscoveredViaQR: (@Sendable (String) -> Void)?
    
    private override init() {
        super.init()
        setupNotificationCenter()
    }
    
    private func setupNotificationCenter() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    /// Starts the local server to receive push notifications from Android companion app
    public func startServer() {
        guard listener == nil else { return }
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("NotificationService server listening on port \(self.port)")
                case .failed(let error):
                    print("NotificationService server failed: \(error)")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .background))
        } catch {
            print("Failed to start NotificationService listener: \(error)")
        }
    }
    
    public func stopServer() {
        listener?.cancel()
        listener = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveData(from: connection)
    }
    
    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                if let str = String(data: data, encoding: .utf8), str.starts(with: "GET ") {
                    self?.handleHTTPQRCodeRequest(from: connection, request: str)
                } else {
                    self?.processIncomingNotificationData(data)
                }
            }
            if error == nil && !isComplete {
                self?.receiveData(from: connection)
            }
        }
    }
    
    private func handleHTTPQRCodeRequest(from connection: NWConnection, request: String) {
        // Extract client IP address from connection endpoint
        var clientIP: String? = nil
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let ip):
                clientIP = "\(ip)"
            default:
                break
            }
        }
        
        let html = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=UTF-8\r
        Connection: close\r
        \r
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>AndOnMac</title>
            <style>
                body { font-family: -apple-system, system-ui, sans-serif; background: #000; color: #fff; text-align: center; padding: 40px 20px; }
                .card { background: #1c1c1e; border-radius: 28px; padding: 32px 24px; max-width: 380px; margin: 40px auto; box-shadow: 0 12px 40px rgba(0,0,0,0.8); border: 1px solid rgba(255,255,255,0.1); }
                .icon { font-size: 54px; margin-bottom: 12px; }
                h2 { margin: 0 0 8px 0; font-size: 22px; font-weight: 700; }
                p { color: rgba(255,255,255,0.7); font-size: 15px; line-height: 1.4; margin: 0 0 20px 0; }
                .badge { display: inline-block; background: #30d158; color: #000; font-weight: 700; font-size: 13px; padding: 6px 14px; border-radius: 20px; }
            </style>
        </head>
        <body>
            <div class="card">
                <div class="icon">✨</div>
                <div class="badge">MacBook подключен</div>
                <h2>Телефон успешно обнаружен!</h2>
                <p>Ваше устройство связано с Mac. Экран трансляции открывается автоматически.</p>
            </div>
        </body>
        </html>
        """
        
        if let respData = html.data(using: .utf8) {
            connection.send(content: respData, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
        
        if let ip = clientIP {
            DispatchQueue.main.async {
                self.onDeviceDiscoveredViaQR?(ip)
            }
        }
    }
    
    private func processIncomingNotificationData(_ data: Data) {
        do {
            let item = try JSONDecoder().decode(NotificationItem.self, from: data)
            DispatchQueue.main.async {
                self.onNotificationReceived?(item)
                self.postToMacOSNotificationCenter(item: item)
            }
        } catch {
            print("Error decoding incoming notification: \(error)")
        }
    }
    
    private func postToMacOSNotificationCenter(item: NotificationItem) {
        let content = UNMutableNotificationContent()
        content.title = "\(item.appName): \(item.title)"
        content.body = item.text
        content.sound = .default
        content.userInfo = [
            "packageName": item.packageName,
            "id": item.id
        ]
        
        let request = UNNotificationRequest(
            identifier: item.id,
            content: content,
            trigger: nil // immediate
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to post macOS notification: \(error)")
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let packageName = userInfo["packageName"] as? String {
            Task {
                // If there is an active device, launch this app on the phone!
                let devices = await ADBService.shared.listDevices()
                if let activeDevice = devices.first(where: { $0.state == .ready }) {
                    try? await ADBService.shared.launchApp(serial: activeDevice.id, packageName: packageName)
                }
                
                await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        completionHandler()
    }
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even when app is active (just like iPhone Mirroring)
        completionHandler([.banner, .sound])
    }
}
