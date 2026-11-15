import Foundation

public enum DaemonConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(hello: WireHelloPayload?)
    case waitingToReconnect(attempt: Int, delaySeconds: TimeInterval, lastError: String?)
    case stopped

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct DaemonClientMetrics: Sendable, Equatable {
    public var framesReceived: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var decodeErrors: UInt64 = 0
    public var reconnectCount: UInt64 = 0
    public var lastFrameAt: Date?

    public init(
        framesReceived: UInt64 = 0,
        bytesReceived: UInt64 = 0,
        decodeErrors: UInt64 = 0,
        reconnectCount: UInt64 = 0,
        lastFrameAt: Date? = nil
    ) {
        self.framesReceived = framesReceived
        self.bytesReceived = bytesReceived
        self.decodeErrors = decodeErrors
        self.reconnectCount = reconnectCount
        self.lastFrameAt = lastFrameAt
    }
}

public enum DaemonClientError: Error, Sendable, Equatable {
    case invalidEndpoint(host: String, port: UInt16)
    case notConnected
    case stopped
    case sendFailed(String)
}
