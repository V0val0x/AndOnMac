import Foundation

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
    
    private var pairingTimer: Timer?
    private var isPairingActive = false
    
    private init() {}
    
    /// Queries ADB for advertised wireless mDNS services in local network
    public func discoverServices() async -> [DiscoveredService] {
        guard let output = try? await ADBService.shared.execute(arguments: ["mdns", "services"], timeoutSeconds: 3.0) else {
            return []
        }
        
        var services: [DiscoveredService] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.starts(with: "List of") || trimmed.starts(with: "*") {
                continue
            }
            
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 3 else { continue }
            
            let name = parts[0]
            let rawType = parts[1]
            let addr = parts[2]
            
            let type: DiscoveredService.ServiceType
            if rawType.contains("pairing") {
                type = .pairing
            } else if rawType.contains("connect") {
                type = .connect
            } else {
                continue
            }
            
            let addrParts = addr.components(separatedBy: ":")
            guard addrParts.count == 2, let port = Int(addrParts[1]) else { continue }
            let host = addrParts[0]
            
            services.append(DiscoveredService(
                id: "\(host):\(port)",
                name: name,
                type: type,
                host: host,
                port: port
            ))
        }
        
        return services
    }
    
    /// Actively listens for Android's pairing mDNS broadcast and auto-pairs with the QR password
    public func startQRPairingWatcher(
        password: String,
        onFound: @escaping @Sendable (String) -> Void,
        onPaired: @escaping @Sendable (String) -> Void
    ) {
        stopQRPairingWatcher()
        isPairingActive = true
        
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, self.isPairingActive else {
                timer.invalidate()
                return
            }
            
            Task {
                let services = await self.discoverServices()
                if let pairingService = services.first(where: { $0.type == .pairing }) {
                    onFound(pairingService.host)
                    
                    // Attempt pairing with strict 5-second timeout
                    let pairArgs = ["pair", "\(pairingService.host):\(pairingService.port)", password]
                    if let output = try? await ADBService.shared.execute(arguments: pairArgs, timeoutSeconds: 5.0) {
                        if output.lowercased().contains("success") || output.lowercased().contains("paired") {
                            self.stopQRPairingWatcher()
                            
                            // Now connect via connect service or standard port 5555
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            let updatedServices = await self.discoverServices()
                            let connectPort = updatedServices.first(where: { $0.host == pairingService.host && $0.type == .connect })?.port ?? 5555
                            
                            _ = try? await ADBService.shared.execute(arguments: ["connect", "\(pairingService.host):\(connectPort)"], timeoutSeconds: 5.0)
                            onPaired(pairingService.host)
                        }
                    }
                }
            }
        }
    }
    
    public func stopQRPairingWatcher() {
        isPairingActive = false
        pairingTimer?.invalidate()
        pairingTimer = nil
    }
}
