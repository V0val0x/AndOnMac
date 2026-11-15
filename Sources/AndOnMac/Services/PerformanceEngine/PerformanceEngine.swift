import Foundation
import Network

/// Manages macOS latency-critical activity assertions, 500ms wireless RTT/jitter probing,
/// Adaptive Bitrate (ABR) step-down/recovery, and live Performance HUD telemetry.
@MainActor
public final class PerformanceEngine: ObservableObject {
    public static let shared = PerformanceEngine()

    public enum CodecLabel: String, Sendable {
        case hevc = "HEVC"
        case h264 = "H264"
    }

    @Published public private(set) var liveFPS: Int = 0
    @Published public private(set) var rttMs: Int = 0
    @Published public private(set) var jitterMs: Int = 0
    @Published public private(set) var activeCodec: CodecLabel = .hevc
    @Published public private(set) var transportLabel: String = "USB"
    @Published public private(set) var isABRReduced: Bool = false

    private var activityToken: NSObjectProtocol?
    private var probeTask: Task<Void, Never>?
    private var fpsTimer: Timer?

    private final class AtomicFrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: Int = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func resetAndRead() -> Int {
            lock.lock()
            let val = count
            count = 0
            lock.unlock()
            return val
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }
    }

    private nonisolated static let frameCounter = AtomicFrameCounter()

    // ABR state machine counters (500ms probe intervals)
    private var highRTTConsecutiveCount: Int = 0
    private var lowRTTConsecutiveCount: Int = 0
    private var previousRTTMs: Int?

    public var onABRStepChange: (@Sendable (_ bitRate: Int, _ maxSize: Int, _ reduced: Bool) -> Void)?

    private init() {}

    /// Starts a latency-critical macOS activity assertion (preventing App Nap & Wi-Fi radio sleep)
    /// and begins live FPS + 500ms wireless RTT probing.
    public func beginMirroringSession(device: Device, codec: CodecLabel = .hevc) {
        endMirroringSession()

        self.activeCodec = codec
        self.transportLabel = Self.resolveTransportLabel(for: device)
        self.isABRReduced = false
        self.highRTTConsecutiveCount = 0
        self.lowRTTConsecutiveCount = 0
        self.previousRTTMs = nil

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "120Hz Low-Latency Mirroring"
        )

        Self.frameCounter.reset()

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let count = Self.frameCounter.resetAndRead()
            Task { @MainActor in
                self.liveFPS = count
            }
        }
        fpsTimer?.tolerance = 0.2

        if device.connectionType == .wifi, let (host, port) = Self.extractHostAndPort(from: device) {
            probeTask = Task { [weak self] in
                while !Task.isCancelled {
                    let measured = await Self.measureTCPRTTMilliseconds(host: host, port: port)
                    guard !Task.isCancelled else { break }
                    _ = await MainActor.run {
                        self?.ingestProbeSample(rttMs: measured)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        } else {
            self.rttMs = 1
            self.jitterMs = 0
        }
    }

    public func endMirroringSession() {
        probeTask?.cancel()
        probeTask = nil
        fpsTimer?.invalidate()
        fpsTimer = nil

        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        liveFPS = 0
        rttMs = 0
        jitterMs = 0
        isABRReduced = false
        highRTTConsecutiveCount = 0
        lowRTTConsecutiveCount = 0
        previousRTTMs = nil
    }

    public func updateActiveCodec(_ codec: CodecLabel) {
        self.activeCodec = codec
    }

    /// Thread-safe frame presentation counter called from the video decoder / Metal display loop.
    public nonisolated static func recordPresentedFrame() {
        frameCounter.increment()
    }

    /// Evaluates ABR step-down (>120ms for >2s / 4 samples) and recovery (<60ms for 4s / 8 samples).
    /// Returns `(shouldApply, bitRate, maxSize, reduced)` if an ABR transition occurred.
    @discardableResult
    public func ingestProbeSample(rttMs measured: Int?) -> (changed: Bool, bitRate: Int, maxSize: Int, reduced: Bool) {
        let sample = measured ?? 200
        if let prev = previousRTTMs {
            jitterMs = abs(sample - prev)
        }
        previousRTTMs = sample
        rttMs = sample

        if !isABRReduced {
            if sample > 120 {
                highRTTConsecutiveCount += 1
                lowRTTConsecutiveCount = 0
                if highRTTConsecutiveCount >= 4 {
                    isABRReduced = true
                    highRTTConsecutiveCount = 0
                    onABRStepChange?(6_000_000, 1280, true)
                    return (true, 6_000_000, 1280, true)
                }
            } else {
                highRTTConsecutiveCount = 0
            }
        } else {
            if sample < 60 {
                lowRTTConsecutiveCount += 1
                highRTTConsecutiveCount = 0
                if lowRTTConsecutiveCount >= 8 {
                    isABRReduced = false
                    lowRTTConsecutiveCount = 0
                    onABRStepChange?(16_000_000, 1440, false)
                    return (true, 16_000_000, 1440, false)
                }
            } else {
                lowRTTConsecutiveCount = 0
            }
        }
        return (false, isABRReduced ? 6_000_000 : 16_000_000, isABRReduced ? 1280 : 1440, isABRReduced)
    }

    public nonisolated static func resolveTransportLabel(for device: Device) -> String {
        if device.connectionType == .usb {
            return "USB"
        }
        if device.id.hasPrefix("192.168.44.") || device.ipAddress?.hasPrefix("192.168.44.") == true {
            return "BT PAN"
        }
        if device.id.hasPrefix("192.168.43.") || device.ipAddress?.hasPrefix("192.168.43.") == true {
            return "Direct Hotspot"
        }
        return "Wi-Fi"
    }

    public nonisolated static func extractHostAndPort(from device: Device) -> (String, Int)? {
        if device.id.contains(":"), let colonIdx = device.id.lastIndex(of: ":") {
            let host = String(device.id[..<colonIdx])
            let port = Int(device.id[device.id.index(after: colonIdx)...]) ?? device.wirelessPort ?? 5555
            return (host, port)
        }
        if let ip = device.ipAddress, !ip.isEmpty {
            return (ip, device.wirelessPort ?? 5555)
        }
        return nil
    }

    private nonisolated static func measureTCPRTTMilliseconds(host: String, port: Int) async -> Int? {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }
        final class ProbeDoneFlag: @unchecked Sendable {
            var done = false
        }

        let start = CFAbsoluteTimeGetCurrent()
        return await withCheckedContinuation { continuation in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.andonmac.rttprobe")
            let lock = NSLock()
            let stateFlag = ProbeDoneFlag()

            let finish: @Sendable (Int?) -> Void = { ms in
                lock.lock()
                defer { lock.unlock() }
                guard !stateFlag.done else { return }
                stateFlag.done = true
                conn.stateUpdateHandler = nil
                conn.cancel()
                continuation.resume(returning: ms)
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000.0).rounded())
                    finish(max(1, elapsed))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.45) {
                finish(nil)
            }
        }
    }
}
