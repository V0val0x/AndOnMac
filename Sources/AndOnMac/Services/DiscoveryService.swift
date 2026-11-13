import Foundation
import Network
import Combine

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

public final class DiscoveryService: ObservableObject, @unchecked Sendable {
    public static let shared = DiscoveryService()
    
    // Discovered state for UI
    @Published public var detectedPairingHost: String?
    @Published public var detectedPairingPort: Int?
    @Published public var detectedConnectPort: Int?
    @Published public var detectedDeviceName: String?
    @Published public var isBrowsing: Bool = false
    
    // Internal cache of host -> connect port
    public private(set) var hostConnectPorts: [String: Int] = [:]
    
    private var pairingBrowser: NWBrowser?
    private var connectBrowser: NWBrowser?
    private let queue = DispatchQueue(label: "com.andonmac.discovery", qos: .userInitiated)
    
    public var onPairingFound: (@Sendable (String, Int, String) -> Void)?
    public var onConnectFound: (@Sendable (String, Int, String) -> Void)?
    
    private init() {}
    
    /// Starts Bonjour discovery for both ADB pairing and connection services
    public func startBrowsing() {
        queue.async { [weak self] in
            guard let self = self, !self.isBrowsing else { return }
            
            DispatchQueue.main.async {
                self.isBrowsing = true
            }
            
            // 1. Browse for pairing service (_adb-tls-pairing._tcp)
            let pairingDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-pairing._tcp", domain: "local.")
            let pairingParams = NWParameters()
            pairingParams.includePeerToPeer = true
            let pBrowser = NWBrowser(for: pairingDesc, using: pairingParams)
            
            pBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        self?.resolveEndpoint(result.endpoint, name: name, isPairing: true)
                    }
                }
            }
            pBrowser.start(queue: self.queue)
            self.pairingBrowser = pBrowser
            
            // 2. Browse for connect service (_adb-tls-connect._tcp)
            let connectDesc = NWBrowser.Descriptor.bonjour(type: "_adb-tls-connect._tcp", domain: "local.")
            let connectParams = NWParameters()
            connectParams.includePeerToPeer = true
            let cBrowser = NWBrowser(for: connectDesc, using: connectParams)
            
            cBrowser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        self?.resolveEndpoint(result.endpoint, name: name, isPairing: false)
                    }
                }
            }
            cBrowser.start(queue: self.queue)
            self.connectBrowser = cBrowser
        }
    }
    
    /// Stops all Bonjour browsers
    public func stopBrowsing() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pairingBrowser?.cancel()
            self.pairingBrowser = nil
            self.connectBrowser?.cancel()
            self.connectBrowser = nil
            
            DispatchQueue.main.async {
                self.isBrowsing = false
            }
        }
    }
    
    /// Clears any cached pairing detection (e.g. after successful pairing)
    public func resetPairingState() {
        DispatchQueue.main.async {
            self.detectedPairingHost = nil
            self.detectedPairingPort = nil
            self.detectedDeviceName = nil
        }
    }
    
    /// Returns the cached connect port for a given IP host
    public func getConnectPort(for host: String) -> Int? {
        return hostConnectPorts[host]
    }
    
    private func resolveEndpoint(_ endpoint: NWEndpoint, name: String, isPairing: Bool) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
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
                    
                    let resolvedPort = Int(port.rawValue)
                    if !ip.isEmpty {
                        if isPairing {
                            DispatchQueue.main.async {
                                self.detectedPairingHost = ip
                                self.detectedPairingPort = resolvedPort
                                self.detectedDeviceName = name
                            }
                            self.onPairingFound?(ip, resolvedPort, name)
                        } else {
                            self.queue.async {
                                self.hostConnectPorts[ip] = resolvedPort
                            }
                            DispatchQueue.main.async {
                                self.detectedConnectPort = resolvedPort
                            }
                            self.onConnectFound?(ip, resolvedPort, name)
                        }
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
