import Foundation
import Network

/// Manages a persistent `NWConnection` to `127.0.0.1:27189` on a dedicated background `DispatchQueue`.
/// Handles fragmented TCP reads via `LineFramer` serially on `networkQueue` so chunk order is strictly preserved,
/// detects silent dead connections via heartbeat watchdog, and reconnects with jittered exponential backoff.
public actor DaemonTCPClient {
    public typealias BeforeReconnectHook = @Sendable (_ attempt: Int) async -> Void

    public private(set) var state: DaemonConnectionState = .disconnected {
        didSet {
            if state != oldValue {
                broadcastState(state)
            }
        }
    }
    public private(set) var metrics = DaemonClientMetrics()
    public nonisolated let configuration: DaemonEndpointConfiguration

    private let codec: WireCodec
    private let networkQueue = DispatchQueue(label: "com.shadowgraph.tcp.client", qos: .userInitiated)
    private var beforeReconnect: BeforeReconnectHook?

    private var connection: NWConnection?
    private var connectionGeneration: UInt64 = 0
    private var isStopped: Bool = false
    private var reconnectAttempt: Int = 0
    private var lastActivityAt: Date = Date()

    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var inboundPumpTask: Task<Void, Never>?

    private var messageContinuations: [UUID: AsyncStream<WireMessage>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<DaemonConnectionState>.Continuation] = [:]
    private var nextInputId: UInt64 = 1
    private var pendingInputWaiters: [UInt64: CheckedContinuation<WireInputResultPayload, Error>] = [:]
    private var pendingInputTimeouts: [UInt64: Task<Void, Never>] = [:]

    /// Queue-confined framing state so TCP chunks are framed and decoded strictly in arrival order off the main thread.
    private final class SerialFramePipeline: @unchecked Sendable {
        private var framer: LineFramer
        private let codec: WireCodec

        init(maxFrameBytes: Int, codec: WireCodec) {
            self.framer = LineFramer(maxFrameBytes: maxFrameBytes)
            self.codec = codec
        }

        enum Output {
            case stateChanged(NWConnection.State)
            case messages([WireMessage], byteCount: Int, decodeErrorCount: UInt64)
            case framingError(Error)
            case eof
        }

        func processChunk(_ data: Data) -> Output {
            do {
                let frames = try framer.append(data)
                if frames.isEmpty {
                    return .messages([], byteCount: data.count, decodeErrorCount: 0)
                }
                var decoded: [WireMessage] = []
                decoded.reserveCapacity(frames.count)
                var errors: UInt64 = 0
                for frame in frames {
                    do {
                        decoded.append(try codec.decodeFrame(frame))
                    } catch {
                        errors += 1
                    }
                }
                return .messages(decoded, byteCount: data.count, decodeErrorCount: errors)
            } catch {
                framer.reset()
                return .framingError(error)
            }
        }
    }

    public init(
        configuration: DaemonEndpointConfiguration = DaemonEndpointConfiguration(),
        codec: WireCodec = NdjsonWireCodec(),
        beforeReconnect: BeforeReconnectHook? = nil
    ) {
        self.configuration = configuration
        self.codec = codec
        self.beforeReconnect = beforeReconnect
    }

    /// Broadcast stream of decoded `WireMessage` frames delivered in strict arrival order.
    public var messages: AsyncStream<WireMessage> {
        AsyncStream { continuation in
            let id = UUID()
            messageContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeMessageContinuation(id) }
            }
        }
    }

    /// Broadcast stream of connection lifecycle transitions.
    public var connectionStates: AsyncStream<DaemonConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    public func setBeforeReconnectHook(_ hook: BeforeReconnectHook?) {
        self.beforeReconnect = hook
    }

    /// Starts the persistent connection loop (idempotent if already connecting or connected).
    public func start() async {
        switch state {
        case .connecting, .connected:
            return
        case .disconnected, .waitingToReconnect, .stopped:
            break
        }
        isStopped = false
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        openConnection()
    }

    /// Forces an immediate teardown and fresh reconnection attempt (e.g. after switching device serial).
    public func reconnect() async {
        guard !isStopped else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        failAllPendingInputs(error: DaemonClientError.notConnected)
        if let beforeReconnect {
            await beforeReconnect(0)
        }
        guard !isStopped else { return }
        openConnection()
    }

    /// Gracefully stops the client, disables automatic reconnect, and closes active streams.
    public func stop() async {
        isStopped = true
        connectionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        inboundPumpTask?.cancel()
        inboundPumpTask = nil

        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        state = .stopped
        failAllPendingInputs(error: DaemonClientError.stopped)

        let msgConts = Array(messageContinuations.values)
        messageContinuations.removeAll()
        for cont in msgConts {
            cont.finish()
        }

        let stateConts = Array(stateContinuations.values)
        stateContinuations.removeAll()
        for cont in stateConts {
            cont.finish()
        }
    }

    /// Encodes and sends a `DaemonCommand` over the active TCP connection.
    public func send(_ command: DaemonCommand) async throws {
        guard !isStopped else {
            throw DaemonClientError.stopped
        }
        guard case .connected = state, let conn = connection else {
            throw DaemonClientError.notConnected
        }
        let payload = try codec.encodeCommand(command)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DaemonClientError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func requestSnapshot() async throws {
        try await send(.snapshot)
    }

    public func ping() async throws {
        try await send(.ping)
    }

    public func setDebounce(ms: Int) async throws {
        try await send(.setDebounce(ms: ms))
    }

    public var supportsNativeInput: Bool {
        if case .connected(let hello) = state, hello?.supportsNativeInput == true {
            return true
        }
        return false
    }

    public func injectTap(x: Int, y: Int) async throws -> WireInputResultPayload {
        let id = allocateInputId()
        return try await sendInputAndAwait(id: id, command: .tap(id: id, x: x, y: y), timeoutMs: 1500)
    }

    public func injectSwipe(
        x1: Int,
        y1: Int,
        x2: Int,
        y2: Int,
        durationMs: Int,
        holdMs: Int
    ) async throws -> WireInputResultPayload {
        let id = allocateInputId()
        let timeoutMs = max(2000, max(0, durationMs) + max(0, holdMs) + 1500)
        return try await sendInputAndAwait(
            id: id,
            command: .swipe(
                id: id,
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2,
                durationMs: durationMs,
                holdMs: holdMs
            ),
            timeoutMs: timeoutMs
        )
    }

    public func injectKeyevent(keycode: Int) async throws -> WireInputResultPayload {
        let id = allocateInputId()
        return try await sendInputAndAwait(
            id: id,
            command: .keyevent(id: id, keycode: keycode),
            timeoutMs: 1500
        )
    }

    private func allocateInputId() -> UInt64 {
        let id = nextInputId
        nextInputId &+= 1
        if nextInputId == 0 {
            nextInputId = 1
        }
        return id
    }

    private func sendInputAndAwait(
        id: UInt64,
        command: DaemonCommand,
        timeoutMs: Int
    ) async throws -> WireInputResultPayload {
        guard !isStopped else {
            throw DaemonClientError.stopped
        }
        guard case .connected(let hello) = state, let conn = connection else {
            throw DaemonClientError.notConnected
        }
        guard hello?.supportsNativeInput == true else {
            throw DaemonClientError.notSupported
        }
        let payload = try codec.encodeCommand(command)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingInputWaiters[id] = continuation
                self.pendingInputTimeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    await self?.failPendingInput(id: id, error: DaemonClientError.inputTimeout)
                }
                conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task {
                            await self?.failPendingInput(
                                id: id,
                                error: DaemonClientError.sendFailed(error.localizedDescription)
                            )
                        }
                    }
                })
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPendingInput(id: id, error: CancellationError())
            }
        }
    }

    private func resolvePendingInput(_ result: WireInputResultPayload) {
        pendingInputTimeouts.removeValue(forKey: result.id)?.cancel()
        guard let cont = pendingInputWaiters.removeValue(forKey: result.id) else { return }
        if result.ok {
            cont.resume(returning: result)
        } else {
            cont.resume(throwing: DaemonClientError.inputFailed(result.error ?? "daemon_input_returned_false"))
        }
    }

    private func failPendingInput(id: UInt64, error: Error) {
        pendingInputTimeouts.removeValue(forKey: id)?.cancel()
        guard let cont = pendingInputWaiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: error)
    }

    private func failAllPendingInputs(error: Error) {
        let timeouts = pendingInputTimeouts
        pendingInputTimeouts.removeAll()
        for task in timeouts.values {
            task.cancel()
        }
        let waiters = pendingInputWaiters
        pendingInputWaiters.removeAll()
        for cont in waiters.values {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Connection Lifecycle

    private func openConnection() {
        guard !isStopped else { return }

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            state = .waitingToReconnect(attempt: reconnectAttempt + 1, delaySeconds: configuration.maxReconnectDelay, lastError: "Invalid port \(configuration.port)")
            scheduleReconnect(lastError: "Invalid port \(configuration.port)")
            return
        }

        // Tear down any previous connection cleanly
        if let prev = connection {
            connection = nil
            prev.stateUpdateHandler = nil
            prev.cancel()
        }
        watchdogTask?.cancel()
        watchdogTask = nil
        inboundPumpTask?.cancel()
        inboundPumpTask = nil

        connectionGeneration &+= 1
        let gen = connectionGeneration

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        self.lastActivityAt = Date()
        self.state = .connecting

        // Ordered pipeline stream from serial networkQueue -> actor
        let (orderedOutputStream, streamCont) = AsyncStream.makeStream(of: SerialFramePipeline.Output.self)

        let pipeline = SerialFramePipeline(
            maxFrameBytes: configuration.maxFrameBytes,
            codec: codec
        )

        inboundPumpTask = Task { [weak self] in
            for await item in orderedOutputStream {
                guard let self else { break }
                await self.handlePipelineOutput(
                    item,
                    generation: gen,
                    pipeline: pipeline,
                    outputContinuation: streamCont
                )
            }
        }

        conn.stateUpdateHandler = { nwState in
            streamCont.yield(.stateChanged(nwState))
        }

        conn.start(queue: networkQueue)
    }

    private func handleNWStateChange(
        _ nwState: NWConnection.State,
        generation: UInt64,
        pipeline: SerialFramePipeline,
        outputContinuation: AsyncStream<SerialFramePipeline.Output>.Continuation
    ) {
        guard generation == connectionGeneration, !isStopped, let conn = connection else {
            outputContinuation.finish()
            return
        }

        switch nwState {
        case .ready:
            lastActivityAt = Date()
            state = .connected(hello: nil)
            startWatchdog(generation: generation)
            let queue = networkQueue
            Self.scheduleNextReceive(
                on: conn,
                queue: queue,
                pipeline: pipeline,
                outputContinuation: outputContinuation
            )

        case .waiting(let error):
            // Localhost ADB forward can report ECONNREFUSED via .waiting instead of .failed.
            // Tear down and let the reconnect loop invoke beforeReconnect (adb forward) with backoff.
            outputContinuation.finish()
            triggerFailureReconnect(generation: generation, reason: error.localizedDescription)

        case .failed(let error):
            outputContinuation.finish()
            triggerFailureReconnect(generation: generation, reason: error.localizedDescription)

        case .cancelled:
            outputContinuation.finish()

        case .setup, .preparing:
            break

        @unknown default:
            break
        }
    }

    private nonisolated static func scheduleNextReceive(
        on conn: NWConnection,
        queue: DispatchQueue,
        pipeline: SerialFramePipeline,
        outputContinuation: AsyncStream<SerialFramePipeline.Output>.Continuation
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                let output = pipeline.processChunk(data)
                outputContinuation.yield(output)
                if case .framingError = output {
                    outputContinuation.finish()
                    return
                }
            }

            if error != nil || isComplete {
                outputContinuation.yield(.eof)
                outputContinuation.finish()
                return
            }

            scheduleNextReceive(
                on: conn,
                queue: queue,
                pipeline: pipeline,
                outputContinuation: outputContinuation
            )
        }
    }

    private func handlePipelineOutput(
        _ output: SerialFramePipeline.Output,
        generation: UInt64,
        pipeline: SerialFramePipeline,
        outputContinuation: AsyncStream<SerialFramePipeline.Output>.Continuation
    ) {
        guard generation == connectionGeneration, !isStopped else { return }

        switch output {
        case .stateChanged(let nwState):
            handleNWStateChange(
                nwState,
                generation: generation,
                pipeline: pipeline,
                outputContinuation: outputContinuation
            )

        case .messages(let msgs, let byteCount, let decodeErrors):
            let now = Date()
            lastActivityAt = now
            metrics.bytesReceived &+= UInt64(byteCount)
            metrics.decodeErrors &+= decodeErrors
            if !msgs.isEmpty {
                // Only reset backoff once the remote daemon actually delivers a valid wire message
                reconnectAttempt = 0
                metrics.framesReceived &+= UInt64(msgs.count)
                metrics.lastFrameAt = now
                for msg in msgs {
                    switch msg {
                    case .hello(let hello):
                        state = .connected(hello: hello)
                    case .inputResult(let res):
                        resolvePendingInput(res)
                    default:
                        break
                    }
                    broadcastMessage(msg)
                }
            }

        case .framingError(let error):
            triggerFailureReconnect(generation: generation, reason: "Frame error: \(error)")

        case .eof:
            triggerFailureReconnect(generation: generation, reason: "Connection closed by remote")
        }
    }

    private func startWatchdog(generation: UInt64) {
        watchdogTask?.cancel()
        let timeout = configuration.heartbeatTimeout
        let pollInterval = max(0.1, min(1.0, timeout / 3.0))

        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { break }
                let timedOut = await self.checkWatchdogTimeout(generation: generation, timeout: timeout)
                if timedOut {
                    break
                }
            }
        }
    }

    private func checkWatchdogTimeout(generation: UInt64, timeout: TimeInterval) -> Bool {
        guard generation == connectionGeneration, !isStopped else { return true }
        let silence = Date().timeIntervalSince(lastActivityAt)
        if silence > timeout {
            triggerFailureReconnect(generation: generation, reason: "Heartbeat silence timeout (\(String(format: "%.1f", silence))s)")
            return true
        }
        return false
    }

    private func triggerFailureReconnect(generation: UInt64, reason: String) {
        guard generation == connectionGeneration, !isStopped else { return }
        connectionGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
        inboundPumpTask?.cancel()
        inboundPumpTask = nil

        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }

        failAllPendingInputs(error: DaemonClientError.notConnected)
        scheduleReconnect(lastError: reason)
    }

    private func scheduleReconnect(lastError: String?) {
        guard !isStopped else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        metrics.reconnectCount &+= 1

        let attempt = reconnectAttempt
        let expDelay = configuration.initialReconnectDelay * pow(2.0, Double(min(10, attempt - 1)))
        let capped = min(configuration.maxReconnectDelay, expDelay)
        let jitterFactor = Double.random(in: 0.85...1.15)
        let delay = max(0.02, min(configuration.maxReconnectDelay, capped * jitterFactor))

        state = .waitingToReconnect(attempt: attempt, delaySeconds: delay, lastError: lastError)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.performReconnect(attempt: attempt)
        }
    }

    private func performReconnect(attempt: Int) async {
        guard !isStopped, !Task.isCancelled else { return }
        if let beforeReconnect {
            await beforeReconnect(attempt)
        }
        guard !isStopped, !Task.isCancelled else { return }
        openConnection()
    }

    // MARK: - Stream Fanout

    private func broadcastMessage(_ message: WireMessage) {
        for cont in messageContinuations.values {
            cont.yield(message)
        }
    }

    private func broadcastState(_ newState: DaemonConnectionState) {
        for cont in stateContinuations.values {
            cont.yield(newState)
        }
    }

    private func removeMessageContinuation(_ id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }
}
