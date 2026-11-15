import Foundation

/// Per-device mirroring quality profile persisted by device serial.
public struct DeviceProfile: Codable, Hashable, Sendable {
    public var bitRate: Int
    public var maxFps: Int
    public var maxSize: Int

    public static let `default` = DeviceProfile(bitRate: 16_000_000, maxFps: 120, maxSize: 1440)

    public init(bitRate: Int = 16_000_000, maxFps: Int = 120, maxSize: Int = 1440) {
        self.bitRate = bitRate
        self.maxFps = maxFps
        self.maxSize = maxSize
    }
}

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
