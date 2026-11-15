import Foundation

public enum ShadowNavigationOutcome: Sendable, Equatable {
    case arrived(MacroExecutionReport)
    case alreadyAtTarget(stateHash: UInt64, activePackage: String)
    case noRoute(
        startHash: UInt64,
        activePackage: String,
        candidateTargetHashes: [UInt64],
        reachableVertexCount: Int,
        knownVertexCount: Int
    )
    case targetNotFound(query: String, knownVertexCount: Int)
    case streamUnavailable
}

private actor NavigationExecutionGate {
    private var isActive = false

    func tryAcquire() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func release() {
        isActive = false
    }
}

/// Coordinates `DaemonTCPClient -> ShadowDOMState -> SpatialGraphEngine` and conforms to `ShadowTreeProviding`
/// for seamless consumption by `AndroidMCPKit` and `AndOnMac`.
public final class ShadowGraphBridge: ShadowTreeProviding, @unchecked Sendable {
    public typealias DaemonRecoveryHook = @Sendable (_ serial: String, _ port: UInt16) async -> Bool

    public let client: DaemonTCPClient
    public let domState: ShadowDOMState
    public let graphEngine: SpatialGraphEngine
    public let hasher: ScreenLayoutHasher

    private let navigationGate = NavigationExecutionGate()
    private let lifecycleLock = NSLock()
    private let macroEventLock = NSLock()
    private var macroEventContinuations: [UUID: AsyncStream<MacroExecutionEvent>.Continuation] = [:]
    private var messagePumpTask: Task<Void, Never>?
    private var statePumpTask: Task<Void, Never>?
    private var graphPumpTask: Task<Void, Never>?
    private var isStarted: Bool = false
    private var daemonRecoveryHook: DaemonRecoveryHook?

    /// Broadcast stream of Layer 3 path computation & macro execution events for visual HUD overlays.
    public var macroExecutionEvents: AsyncStream<MacroExecutionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            macroEventLock.lock()
            macroEventContinuations[id] = continuation
            macroEventLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeMacroEventContinuation(id)
            }
        }
    }

    private func removeMacroEventContinuation(_ id: UUID) {
        macroEventLock.lock()
        macroEventContinuations.removeValue(forKey: id)
        macroEventLock.unlock()
    }

    private func emitMacroEvent(_ event: MacroExecutionEvent) {
        macroEventLock.lock()
        let continuations = Array(macroEventContinuations.values)
        macroEventLock.unlock()
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    public init(
        configuration: DaemonEndpointConfiguration = DaemonEndpointConfiguration(),
        codec: WireCodec = NdjsonWireCodec(),
        hasher: ScreenLayoutHasher = ScreenLayoutHasher(),
        significanceThreshold: Double = 0.72,
        beforeReconnect: DaemonTCPClient.BeforeReconnectHook? = nil
    ) {
        let client = DaemonTCPClient(
            configuration: configuration,
            codec: codec,
            beforeReconnect: beforeReconnect
        )
        self.client = client
        self.hasher = hasher
        self.domState = ShadowDOMState {
            try? await client.requestSnapshot()
        }
        self.graphEngine = SpatialGraphEngine(
            hasher: hasher,
            significanceThreshold: significanceThreshold
        )
    }

    public func setBeforeReconnectHook(_ hook: DaemonTCPClient.BeforeReconnectHook?) async {
        await client.setBeforeReconnectHook(hook)
    }

    public func setDaemonRecoveryHook(_ hook: DaemonRecoveryHook?) {
        lifecycleLock.withLock {
            daemonRecoveryHook = hook
        }
    }

    private func currentDaemonRecoveryHook() -> DaemonRecoveryHook? {
        lifecycleLock.withLock {
            daemonRecoveryHook
        }
    }

    /// Starts the background message pump, state watcher, spatial graph updater, and TCP client.
    public func start() async {
        let shouldStart: Bool = lifecycleLock.withLock {
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard shouldStart else { return }

        let messageStream = await client.messages
        let stateStream = await client.connectionStates
        let domUpdates = await domState.updates

        let dom = self.domState
        let graph = self.graphEngine

        let msgTask = Task.detached(priority: .userInitiated) {
            for await message in messageStream {
                await dom.handleMessage(message)
            }
        }

        let stTask = Task.detached(priority: .utility) { [weak client = self.client] in
            for await connState in stateStream {
                switch connState {
                case .disconnected, .waitingToReconnect, .stopped:
                    if let client {
                        let current = await client.state
                        if current == .connecting || current.isConnected {
                            continue
                        }
                    }
                    await dom.markDisconnected()
                case .connecting, .connected:
                    break
                }
            }
        }

        let grTask = Task.detached(priority: .utility) {
            for await update in domUpdates {
                await graph.process(update: update)
            }
        }

        lifecycleLock.withLock {
            self.messagePumpTask = msgTask
            self.statePumpTask = stTask
            self.graphPumpTask = grTask
        }

        await client.start()
    }

    /// Stops all background tasks and closes the daemon TCP connection.
    public func stop() async {
        let tasks: [Task<Void, Never>?] = lifecycleLock.withLock {
            isStarted = false
            let existing = [messagePumpTask, statePumpTask, graphPumpTask]
            messagePumpTask = nil
            statePumpTask = nil
            graphPumpTask = nil
            return existing
        }
        for t in tasks {
            t?.cancel()
        }
        await client.stop()
        await domState.markDisconnected()
    }

    /// Forces an immediate reconnection (e.g. after switching target ADB device serial).
    public func reconnect() async {
        await domState.markDisconnected()
        await client.reconnect()
    }

    // MARK: - ShadowTreeProviding

    public func getCurrentTree() async -> [ShadowUINode] {
        await domState.getCurrentTree()
    }

    public func getCompactTree() async -> [ShadowCompactNode] {
        await domState.getCompactTree()
    }

    public func ensureShadowStreamReady(
        maxWaitSeconds: TimeInterval = 0.5,
        maxAgeSeconds: TimeInterval = 15.0
    ) async -> Bool {
        let isBridgeStarted = lifecycleLock.withLock { isStarted }
        let connState = await client.state
        if isBridgeStarted {
            switch connState {
            case .disconnected, .waitingToReconnect, .stopped:
                return false
            case .connecting, .connected:
                break
            }
        }
        if await domState.isFresh(maxAgeSeconds: maxAgeSeconds) {
            return true
        }
        switch connState {
        case .connecting, .connected:
            if maxWaitSeconds > 0 {
                _ = await domState.waitForSnapshot(timeoutSeconds: maxWaitSeconds)
                return await domState.isFresh(maxAgeSeconds: maxAgeSeconds)
            }
            return false
        case .disconnected, .waitingToReconnect, .stopped:
            return false
        }
    }

    /// Returns cached compact nodes in <1 ms if the Shadow DOM stream is fresh,
    /// waiting briefly only when actively connecting/connected without an initial snapshot yet.
    /// Returns `nil` immediately when the daemon is offline so ADB fallback incurs zero delay.
    public func fastCompactTreeIfFresh(
        maxWaitSeconds: TimeInterval = 0.5,
        maxAgeSeconds: TimeInterval = 15.0
    ) async -> [ShadowCompactNode]? {
        if await domState.isFresh(maxAgeSeconds: maxAgeSeconds) {
            let compact = await domState.getCompactTree()
            if !compact.isEmpty {
                return compact
            }
        }

        let connState = await client.state
        switch connState {
        case .connecting, .connected:
            if maxWaitSeconds > 0 {
                _ = await domState.waitForSnapshot(timeoutSeconds: maxWaitSeconds)
                if await domState.isFresh(maxAgeSeconds: maxAgeSeconds) {
                    let compact = await domState.getCompactTree()
                    if !compact.isEmpty {
                        return compact
                    }
                }
            }
            return nil
        case .disconnected, .waitingToReconnect, .stopped:
            return nil
        }
    }

    public func findNode(
        byText query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive,
        preferClickable: Bool = true
    ) async -> ShadowUINode? {
        await domState.findNode(byText: query, mode: mode, preferClickable: preferClickable)
    }

    public func findNode(
        byResourceID resourceId: String,
        mode: ShadowTreeMatchMode = .suffixOrExactResourceId
    ) async -> ShadowUINode? {
        await domState.findNode(byResourceID: resourceId, mode: mode)
    }

    public func findNode(
        byContentDesc query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive
    ) async -> ShadowUINode? {
        await domState.findNode(byContentDesc: query, mode: mode)
    }

    public func recordAction(_ action: AttributedUIAction) async {
        await graphEngine.recordPendingAction(action)
    }

    // MARK: - Layer 3 Autonomous Routing & Execution

    /// Resolves a target semantic hint (or exact `targetHash`) against `SpatialGraphEngine`,
    /// computes the optimal executable path from the live screen via `AStarPathfinder`,
    /// and autonomously executes it through `MacroExecutionEngine`.
    public func routeAndExecute(
        targetHint: String? = nil,
        targetHash: UInt64? = nil,
        serial: String,
        executor: MacroActionExecutor,
        maxSteps: Int = 12,
        stepTimeoutMs: Int = 2000,
        postSettleQuiescenceMs: Int = 40,
        settleSimilarityThreshold: Double = 0.80
    ) async throws -> ShadowNavigationOutcome {
        guard await navigationGate.tryAcquire() else {
            throw PathDeviationError.executionAlreadyInProgress
        }

        do {
            let outcome = try await performRouteAndExecute(
                targetHint: targetHint,
                targetHash: targetHash,
                serial: serial,
                executor: executor,
                maxSteps: maxSteps,
                stepTimeoutMs: stepTimeoutMs,
                postSettleQuiescenceMs: postSettleQuiescenceMs,
                settleSimilarityThreshold: settleSimilarityThreshold
            )
            await navigationGate.release()
            return outcome
        } catch {
            await navigationGate.release()
            throw error
        }
    }

    private func performRouteAndExecute(
        targetHint: String?,
        targetHash: UInt64?,
        serial: String,
        executor: MacroActionExecutor,
        maxSteps: Int,
        stepTimeoutMs: Int,
        postSettleQuiescenceMs: Int,
        settleSimilarityThreshold: Double
    ) async throws -> ShadowNavigationOutcome {
        var streamReady = await ensureShadowStreamReady(maxWaitSeconds: 0.75, maxAgeSeconds: 15.0)
        var resolvedIndex = streamReady ? await domState.currentIndex : nil

        if (!streamReady || resolvedIndex == nil), let recoveryHook = currentDaemonRecoveryHook() {
            let recovered = await recoveryHook(serial, client.configuration.port)
            try Task.checkCancellation()
            if recovered {
                streamReady = await ensureShadowStreamReady(maxWaitSeconds: 0.75, maxAgeSeconds: 15.0)
                resolvedIndex = streamReady ? await domState.currentIndex : nil
            }
        }

        guard streamReady, let currentIndex = resolvedIndex else {
            emitMacroEvent(.failed(message: "Shadow DOM stream unavailable"))
            return .streamUnavailable
        }

        let currentFp = hasher.fingerprint(for: currentIndex)
        var startHash = currentFp.layoutHash

        // Ensure the live screen vertex exists in graphEngine before snapshotting;
        // if process(update:) snapped to an existing canonical vertex, route from that canonical hash.
        if await graphEngine.vertices[startHash] == nil {
            await graphEngine.process(update: ShadowDOMUpdate(
                index: currentIndex,
                isFullSnapshot: true,
                insertedCount: currentIndex.orderedNodes.count,
                updatedCount: 0,
                removedCount: 0
            ))
            if let canonicalStart = await graphEngine.currentStateHash,
               let canonicalVertex = await graphEngine.vertices[canonicalStart],
               canonicalVertex.activePackage == currentFp.activePackage {
                startHash = canonicalStart
            }
        }

        let snapshot = await graphEngine.snapshot()

        let topGoals: Set<UInt64>
        let allGoals: Set<UInt64>

        if let targetHash {
            let hex = String(format: "0x%016llx", targetHash)
            guard snapshot.vertices.contains(where: { $0.layoutHash == targetHash }) else {
                let count = snapshot.vertices.count
                emitMacroEvent(.failed(message: "Target \(hex) not found (\(count) screens)"))
                return .targetNotFound(
                    query: hex,
                    knownVertexCount: count
                )
            }
            topGoals = [targetHash]
            allGoals = [targetHash]
        } else if let trimmed = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            let ranked = await graphEngine.resolveTargetVertices(matching: trimmed, limit: 12)
            guard let best = ranked.first else {
                let count = snapshot.vertices.count
                emitMacroEvent(.failed(message: "Target '\(trimmed)' not found (\(count) screens)"))
                return .targetNotFound(query: trimmed, knownVertexCount: count)
            }
            topGoals = Set(ranked.filter { $0.score == best.score }.map { $0.vertex.layoutHash })
            allGoals = Set(ranked.map { $0.vertex.layoutHash })
        } else {
            let count = snapshot.vertices.count
            emitMacroEvent(.failed(message: "Empty navigation target (\(count) screens)"))
            return .targetNotFound(query: "", knownVertexCount: count)
        }

        let pathfinder = AStarPathfinder(configuration: AStarCostConfiguration(maxSteps: maxSteps))
        var searchResult = pathfinder.findShortestPath(from: startHash, toAnyOf: topGoals, in: snapshot)

        // If exact startHash has no route (e.g. a dynamic item appeared/disappeared on the current screen),
        // check semantically equivalent vertices (>= settleSimilarityThreshold) before falling back to lower-ranked goals.
        if searchResult == nil && !currentFp.tokens.isEmpty {
            let semanticAliases = snapshot.vertices
                .compactMap { vertex -> (hash: UInt64, similarity: Double)? in
                    guard vertex.layoutHash != startHash,
                          vertex.activePackage == currentFp.activePackage,
                          !vertex.semanticTokens.isEmpty else {
                        return nil
                    }
                    let sim = ScreenLayoutHasher.jaccardSimilarity(currentFp.tokens, vertex.semanticTokens)
                    guard sim >= settleSimilarityThreshold else { return nil }
                    return (vertex.layoutHash, sim)
                }
                .sorted { lhs, rhs in
                    if lhs.similarity != rhs.similarity {
                        return lhs.similarity > rhs.similarity
                    }
                    return lhs.hash < rhs.hash
                }

            for alias in semanticAliases {
                if let route = pathfinder.findShortestPath(from: alias.hash, toAnyOf: topGoals, in: snapshot) {
                    searchResult = route
                    break
                }
            }

            if searchResult == nil && allGoals != topGoals {
                let fallbackGoals = allGoals.subtracting([startHash])
                if !fallbackGoals.isEmpty {
                    searchResult = pathfinder.findShortestPath(from: startHash, toAnyOf: fallbackGoals, in: snapshot)
                    if searchResult == nil {
                        for alias in semanticAliases {
                            let aliasFallback = fallbackGoals.subtracting([alias.hash])
                            if !aliasFallback.isEmpty,
                               let route = pathfinder.findShortestPath(from: alias.hash, toAnyOf: aliasFallback, in: snapshot) {
                                searchResult = route
                                break
                            }
                        }
                    }
                }
            }
        } else if searchResult == nil && allGoals != topGoals {
            let fallbackGoals = allGoals.subtracting([startHash])
            if !fallbackGoals.isEmpty {
                searchResult = pathfinder.findShortestPath(from: startHash, toAnyOf: fallbackGoals, in: snapshot)
            }
        }

        guard let route = searchResult else {
            let reachable = pathfinder.reachableExecutableVertexCount(from: startHash, in: snapshot)
            let known = snapshot.vertices.count
            let targetLabel: String
            if let trimmed = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                targetLabel = "'\(trimmed)'"
            } else if let targetHash {
                targetLabel = String(format: "0x%016llx", targetHash)
            } else {
                targetLabel = "target"
            }
            emitMacroEvent(.failed(message: "No route to \(targetLabel) (\(reachable)/\(known) reachable)"))
            return .noRoute(
                startHash: startHash,
                activePackage: currentIndex.activePackage,
                candidateTargetHashes: Array(allGoals).sorted(),
                reachableVertexCount: reachable,
                knownVertexCount: known
            )
        }

        if route.edges.isEmpty {
            return .alreadyAtTarget(stateHash: startHash, activePackage: currentIndex.activePackage)
        }

        emitMacroEvent(.pathComputed(totalSteps: route.edges.count, targetHint: targetHint))

        let engine = MacroExecutionEngine(
            domState: domState,
            graphEngine: graphEngine,
            executor: executor,
            hasher: hasher,
            configuration: MacroExecutionConfiguration(
                stepTimeoutMs: stepTimeoutMs,
                postSettleQuiescenceMs: postSettleQuiescenceMs,
                settleSimilarityThreshold: settleSimilarityThreshold
            ),
            onEvent: { [weak self] event in
                self?.emitMacroEvent(event)
            }
        )
        let report = try await engine.execute(path: route.edges, serial: serial)
        return .arrived(report)
    }
}
