import Foundation
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

public final class DiscoveryService: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = DiscoveryService()
    
    // Discovered state for UI
    @Published public var detectedPairingHost: String?
    @Published public var detectedPairingPort: Int?
    @Published public var detectedConnectPort: Int?
    @Published public var detectedDeviceName: String?
    @Published public var isBrowsing: Bool = false
    
    // Internal cache of host -> connect port
    public private(set) var hostConnectPorts: [String: Int] = [:]
    
    private var pairingBrowser: NetServiceBrowser?
    private var connectBrowser: NetServiceBrowser?
    private var activeResolvers: [NetService] = []
    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "com.andonmac.discovery", qos: .userInitiated)
    
    public var onPairingFound: (@Sendable (String, Int, String) -> Void)?
    public var onConnectFound: (@Sendable (String, Int, String) -> Void)?
    
    private override init() {
        super.init()
    }
    
    /// Starts Bonjour discovery for both ADB pairing and connection services without TCP intrusive probes
    public func startBrowsing() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isBrowsing else { return }
            self.isBrowsing = true
            
            // 1. Browse for pairing service (_adb-tls-pairing._tcp.) via system mDNS
            let pBrowser = NetServiceBrowser()
            pBrowser.delegate = self
            pBrowser.schedule(in: .main, forMode: .common)
            pBrowser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "")
            self.pairingBrowser = pBrowser
            
            // 2. Browse for connect service (_adb-tls-connect._tcp.) via system mDNS
            let cBrowser = NetServiceBrowser()
            cBrowser.delegate = self
            cBrowser.schedule(in: .main, forMode: .common)
            cBrowser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "")
            self.connectBrowser = cBrowser
            
            // 3. Supplemental check via official 'adb mdns services'
            self.startPeriodicAdbMdnsPoll()
        }
    }
    
    /// Stops all Bonjour browsers and resolvers
    public func stopBrowsing() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            
            self.pairingBrowser?.stop()
            self.pairingBrowser?.delegate = nil
            self.pairingBrowser = nil
            
            self.connectBrowser?.stop()
            self.connectBrowser?.delegate = nil
            self.connectBrowser = nil
            
            for s in self.activeResolvers {
                s.stop()
                s.delegate = nil
            }
            self.activeResolvers.removeAll()
            
            self.isBrowsing = false
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
        return queue.sync {
            self.hostConnectPorts[host]
        }
    }
    
    // MARK: - ADB mDNS Fallback / Sync
    private func startPeriodicAdbMdnsPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            Task {
                await self?.pollAdbMdns()
            }
        }
        Task {
            await pollAdbMdns()
        }
    }
    
    public func pollAdbMdns() async {
        guard let output = try? await ADBService.shared.execute(arguments: ["mdns", "services"], timeoutSeconds: 2.0) else { return }
        parseAdbMdnsOutput(output)
    }
    
    public func parseAdbMdnsOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            let serviceType = parts[1]
            let hostAndPort = parts[2]
            
            let hpParts = hostAndPort.components(separatedBy: ":")
            guard hpParts.count == 2, let port = Int(hpParts[1]) else { continue }
            let ip = hpParts[0]
            guard !ip.isEmpty && ip != "127.0.0.1" else { continue }
            
            if serviceType.contains("_adb-tls-pairing") {
                DispatchQueue.main.async {
                    self.detectedPairingHost = ip
                    self.detectedPairingPort = port
                    self.detectedDeviceName = name
                }
                self.onPairingFound?(ip, port, name)
            } else if serviceType.contains("_adb-tls-connect") {
                self.queue.async {
                    self.hostConnectPorts[ip] = port
                }
                DispatchQueue.main.async {
                    self.detectedConnectPort = port
                }
                self.onConnectFound?(ip, port, name)
            }
        }
    }
}

// MARK: - NetServiceBrowserDelegate & NetServiceDelegate
extension DiscoveryService: NetServiceBrowserDelegate, NetServiceDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        activeResolvers.append(service)
        // Resolve SRV and address records via system mDNS (UDP 5353) - NEVER opens a TCP connection!
        service.resolve(withTimeout: 5.0)
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        activeResolvers.removeAll(where: { $0 == service })
    }
    
    public func netServiceDidResolveAddress(_ sender: NetService) {
        let port = sender.port
        guard port > 0 else { return }
        let isPairing = sender.type.contains("pairing")
        
        guard let addresses = sender.addresses else { return }
        for data in addresses {
            var storage = sockaddr_storage()
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            (data as NSData).getBytes(&storage, length: min(data.count, MemoryLayout<sockaddr_storage>.size))
            if Int32(storage.ss_family) == AF_INET {
                var addr4 = sockaddr_in()
                (data as NSData).getBytes(&addr4, length: MemoryLayout<sockaddr_in>.size)
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr4.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: ipBuf)
                guard !ip.isEmpty && ip != "0.0.0.0" else { continue }
                
                if isPairing {
                    self.detectedPairingHost = ip
                    self.detectedPairingPort = port
                    self.detectedDeviceName = sender.name
                    self.onPairingFound?(ip, port, sender.name)
                } else {
                    self.queue.async {
                        self.hostConnectPorts[ip] = port
                    }
                    self.detectedConnectPort = port
                    self.onConnectFound?(ip, port, sender.name)
                }
                break
            }
        }
    }
    
    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        activeResolvers.removeAll(where: { $0 == sender })
    }
}

