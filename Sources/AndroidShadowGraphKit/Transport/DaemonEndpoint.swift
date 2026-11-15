import Foundation

public struct DaemonEndpointConfiguration: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let initialReconnectDelay: TimeInterval
    public let maxReconnectDelay: TimeInterval
    public let heartbeatTimeout: TimeInterval
    public let maxFrameBytes: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 27189,
        initialReconnectDelay: TimeInterval = 0.25,
        maxReconnectDelay: TimeInterval = 5.0,
        heartbeatTimeout: TimeInterval = 12.0,
        maxFrameBytes: Int = 8 * 1024 * 1024
    ) {
        self.host = host
        self.port = port
        self.initialReconnectDelay = max(0.02, initialReconnectDelay)
        self.maxReconnectDelay = max(self.initialReconnectDelay, maxReconnectDelay)
        self.heartbeatTimeout = max(0.5, heartbeatTimeout)
        self.maxFrameBytes = max(1024, maxFrameBytes)
    }
}
