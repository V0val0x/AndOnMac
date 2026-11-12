import Foundation
import Network
import UserNotifications
import AppKit

public final class NotificationService: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 58241
    public var onNotificationReceived: (@Sendable (NotificationItem) -> Void)?
    
    private override init() {
        super.init()
        setupNotificationCenter()
    }
    
    private func setupNotificationCenter() {
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
                self?.processIncomingNotificationData(data)
            }
            if error == nil && !isComplete {
                self?.receiveData(from: connection)
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
