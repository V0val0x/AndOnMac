import Foundation

public struct KnownDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var ipAddress: String
    public var port: Int
    public var lastConnected: Date
    public var autoConnect: Bool
    
    public init(
        id: String,
        name: String,
        ipAddress: String,
        port: Int = 5555,
        lastConnected: Date = Date(),
        autoConnect: Bool = true
    ) {
        self.id = id
        self.name = name
        self.ipAddress = ipAddress
        self.port = port
        self.lastConnected = lastConnected
        self.autoConnect = autoConnect
    }
}
