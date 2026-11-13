import Foundation
import Network

public struct DiscoveredService: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: ServiceType
    public let host: String
    public let port: Int
    
    public enum ServiceType: String, Sendable {
        case connect = "_adb-tls-connect._tcp"
        case pairing = "_adb-tls-pairing._tcp"
    }
}

public final class DiscoveryService: @unchecked Sendable {
    public static let shared = DiscoveryService()
    
    private var browser: NWBrowser?
    private var isBrowsing = false
    public var onServiceFound: (@Sendable (DiscoveredService) -> Void)?
    
    private init() {}
    
    /// Starts native Apple Bonjour browser for Android Wireless Debugging
    public func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: "local.")
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let newBrowser = NWBrowser(for: descriptor, using: parameters)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    self?.resolveEndpoint(result.endpoint, name: name)
                }
            }
        }
        
        newBrowser.start(queue: .global(qos: .userInitiated))
        self.browser = newBrowser
    }
    
    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }
    
    private func resolveEndpoint(_ endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   case .hostPort(let host, let port) = remoteEndpoint {
                    var ip = ""
                    switch host {
                    case .ipv4(let ipv4): ip = "\(ipv4)"
                    case .ipv6(let ipv6): ip = "\(ipv6)"
                    default: break
                    }
                    if !ip.isEmpty {
                        let service = DiscoveredService(
                            id: "\(ip):\(port.rawValue)",
                            name: name,
                            type: .pairing,
                            host: ip,
                            port: Int(port.rawValue)
                        )
                        self?.onServiceFound?(service)
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }
    
    /// Starts QR pairing watcher that combines native Bonjour and ADB commands
    public func startQRPairingWatcher(
        password: String,
        onFound: @escaping @Sendable (String) -> Void,
        onPaired: @escaping @Sendable (String) -> Void
    ) {
        startBrowsing()
        onServiceFound = { service in
            onFound(service.host)
            Task {
                let pairArgs = ["pair", "\(service.host):\(service.port)", password]
                if let output = try? await ADBService.shared.execute(arguments: pairArgs, timeoutSeconds: 5.0) {
                    if output.lowercased().contains("success") || output.lowercased().contains("paired") {
                        self.stopBrowsing()
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        _ = try? await ADBService.shared.execute(arguments: ["connect", "\(service.host):5555"], timeoutSeconds: 5.0)
                        onPaired(service.host)
                    }
                }
            }
        }
    }
    
    public func stopQRPairingWatcher() {
        stopBrowsing()
        onServiceFound = nil
    }
}
