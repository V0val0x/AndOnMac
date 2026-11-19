import Foundation

public enum WireCodecError: Error, Sendable, Equatable {
    case emptyFrame
    case unknownMessageType(String)
    case invalidDebounceMs(Int)
    case invalidInputParameter(String)
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
    private static let prefixSecureScreen = Array("{\"type\":\"secure_screen\"".utf8)
    private static let prefixInputResult = Array("{\"type\":\"input_result\"".utf8)

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
        case .tap(let id, let x, let y):
            guard (0...16_384).contains(x), (0...16_384).contains(y) else {
                throw WireCodecError.invalidInputParameter("tap coords (\(x),\(y)) out of range 0...16384")
            }
            return Data("{\"cmd\":\"tap\",\"id\":\(id),\"x\":\(x),\"y\":\(y)}\n".utf8)
        case .swipe(let id, let x1, let y1, let x2, let y2, let durationMs, let holdMs):
            guard (0...16_384).contains(x1), (0...16_384).contains(y1),
                  (0...16_384).contains(x2), (0...16_384).contains(y2) else {
                throw WireCodecError.invalidInputParameter("swipe coords (\(x1),\(y1))->(\(x2),\(y2)) out of range 0...16384")
            }
            guard (10...10_000).contains(durationMs) else {
                throw WireCodecError.invalidInputParameter("swipe duration_ms \(durationMs) out of range 10...10000")
            }
            guard (0...1_000).contains(holdMs) else {
                throw WireCodecError.invalidInputParameter("swipe hold_ms \(holdMs) out of range 0...1000")
            }
            return Data("{\"cmd\":\"swipe\",\"id\":\(id),\"x1\":\(x1),\"y1\":\(y1),\"x2\":\(x2),\"y2\":\(y2),\"duration_ms\":\(durationMs),\"hold_ms\":\(holdMs)}\n".utf8)
        case .keyevent(let id, let keycode):
            guard (1...1024).contains(keycode) else {
                throw WireCodecError.invalidInputParameter("keycode \(keycode) out of range 1...1024")
            }
            return Data("{\"cmd\":\"keyevent\",\"id\":\(id),\"keycode\":\(keycode)}\n".utf8)
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
        case "secure_screen":
            return .secureScreen(try decoder.decode(WireSecureScreenPayload.self, from: data))
        case "input_result":
            return .inputResult(try decoder.decode(WireInputResultPayload.self, from: data))
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
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixSecureScreen) { return "secure_screen" }
            if Self.matchesPrefix(base, count: count, prefix: Self.prefixInputResult) { return "input_result" }
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
