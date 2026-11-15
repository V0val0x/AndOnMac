import Foundation

public enum WireCodecError: Error, Sendable, Equatable {
    case emptyFrame
    case unknownMessageType(String)
    case invalidDebounceMs(Int)
}

/// Host-side twin of Layer 1's `WireEncoder`, allowing NDJSON today and a binary codec later.
public protocol WireCodec: Sendable {
    var formatName: String { get }
    func decodeFrame(_ frameData: Data) throws -> WireMessage
    func encodeCommand(_ command: DaemonCommand) throws -> Data
}

/// High-frequency NDJSON codec using compile-time `CodingKeys` (no `DateFormatter`, no `convertFromSnakeCase`)
/// and a zero-allocation prefix check for `NdjsonWireEncoder`'s canonical `"type"` field ordering.
public final class NdjsonWireCodec: WireCodec, Sendable {
    public let formatName: String = "ndjson/1"

    private struct TypeHeader: Decodable {
        let type: String
    }

    // Pre-encoded command bytes for zero-allocation hot commands
    private static let cmdSnapshotBytes = Data("{\"cmd\":\"snapshot\"}\n".utf8)
    private static let cmdPingBytes = Data("{\"cmd\":\"ping\"}\n".utf8)
    private static let cmdShutdownBytes = Data("{\"cmd\":\"shutdown\"}\n".utf8)

    // Canonical prefixes emitted by Layer 1 NdjsonWireEncoder.kt
    private static let prefixDiff = Array("{\"type\":\"diff\"".utf8)
    private static let prefixSnapshot = Array("{\"type\":\"snapshot\"".utf8)
    private static let prefixHeartbeat = Array("{\"type\":\"heartbeat\"".utf8)
    private static let prefixPong = Array("{\"type\":\"pong\"".utf8)
    private static let prefixHello = Array("{\"type\":\"hello\"".utf8)
    private static let prefixError = Array("{\"type\":\"error\"".utf8)

    public init() {}

    public func decodeFrame(_ frameData: Data) throws -> WireMessage {
        guard !frameData.isEmpty else {
            throw WireCodecError.emptyFrame
        }

        let decoder = JSONDecoder()

        // Fast-path: single-pass decode when "type" is the first JSON key (100% of daemon output)
        if let fastType = fastDetectMessageType(frameData) {
            return try decodePayload(type: fastType, from: frameData, decoder: decoder)
        }

        // General fallback for arbitrary key ordering or formatted JSON
        let header = try decoder.decode(TypeHeader.self, from: frameData)
        return try decodePayload(type: header.type, from: frameData, decoder: decoder)
    }

    public func encodeCommand(_ command: DaemonCommand) throws -> Data {
        switch command {
        case .snapshot:
            return Self.cmdSnapshotBytes
        case .ping:
            return Self.cmdPingBytes
        case .shutdown:
            return Self.cmdShutdownBytes
        case .setDebounce(let ms):
            guard (0...5000).contains(ms) else {
                throw WireCodecError.invalidDebounceMs(ms)
            }
            return Data("{\"cmd\":\"set_debounce\",\"ms\":\(ms)}\n".utf8)
        }
    }

    private func decodePayload(type: String, from data: Data, decoder: JSONDecoder) throws -> WireMessage {
        switch type {
        case "diff":
            return .diff(try decoder.decode(WireDiffPayload.self, from: data))
        case "snapshot":
            return .snapshot(try decoder.decode(WireSnapshotPayload.self, from: data))
        case "heartbeat":
            return .heartbeat(try decoder.decode(WireHeartbeatPayload.self, from: data))
        case "pong":
            return .pong(try decoder.decode(WirePongPayload.self, from: data))
        case "hello":
            return .hello(try decoder.decode(WireHelloPayload.self, from: data))
        case "error":
            return .error(try decoder.decode(WireErrorPayload.self, from: data))
        default:
            throw WireCodecError.unknownMessageType(type)
        }
    }

    private func fastDetectMessageType(_ data: Data) -> String? {
        guard data.count >= 15 else { return nil }
        return data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixDiff) { return "diff" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixSnapshot) { return "snapshot" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixHeartbeat) { return "heartbeat" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixPong) { return "pong" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixHello) { return "hello" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixError) { return "error" }
            return nil
        }
    }

    private static func matchesPrefix(_ base: UnsafePointer<UInt8>, count: Int, prefix: [UInt8]) -> Bool {
        guard count >= prefix.count else { return false }
        for i in 0..<prefix.count {
            if base[i] != prefix[i] { return false }
        }
        // Ensure next byte is ',' or '}' or whitespace so "diff_v2" wouldn't falsely match "diff"
        if count > prefix.count {
            let next = base[prefix.count]
            return next == UInt8(ascii: ",") || next == UInt8(ascii: "}") || next == UInt8(ascii: " ") || next == UInt8(ascii: "\t")
        }
        return true
    }
}
