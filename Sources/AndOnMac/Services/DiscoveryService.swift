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
    
    private init() {}
    
    /// Queries ADB for advertised wireless mDNS services in local network
    public func discoverServices() async -> [DiscoveredService] {
        guard let output = try? await ADBService.shared.execute(arguments: ["mdns", "services"]) else {
            return []
        }
        
        var services: [DiscoveredService] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.starts(with: "List of") || trimmed.starts(with: "*") {
                continue
            }
            
            // Format: <name>\t<type>\t<address> (or space delimited)
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
}
