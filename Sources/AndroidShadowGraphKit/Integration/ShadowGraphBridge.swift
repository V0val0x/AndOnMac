import Foundation

public enum ShadowNavigationOutcome: Sendable, Equatable {
    case arrived(MacroExecutionReport)
    case alreadyAtTarget(stateHash: UInt64, activePackage: String)
    case requiresConfirmation(HazardousConfirmationRequest)
    case secureScreenTimeout(reason: String, activePackage: String, timeoutSeconds: Int)
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

    /// Broadcast stream of Layer 1 `FLAG_SECURE` / biometric lock state transitions.
    public var secureScreenEvents: AsyncStream<WireSecureScreenPayload> {
        let dom = self.domState
        return AsyncStream { continuation in
            let task = Task {
                let stream = await dom.secureScreenUpdates
                for await payload in stream {
                    continuation.yield(payload)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
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
    /// and autonomously executes it through `MacroExecutionEngine` with HITL & auto-recovery support.
    public func routeAndExecute(
        targetHint: String? = nil,
        targetHash: UInt64? = nil,
        serial: String,
        executor: MacroActionExecutor,
        maxSteps: Int = 12,
        stepTimeoutMs: Int = 2000,
        postSettleQuiescenceMs: Int = 40,
        settleSimilarityThreshold: Double = 0.80,
        confirmed: Bool = false,
        enableAutoRecovery: Bool = true,
        secureHandoffTimeoutSeconds: TimeInterval = 60.0
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
                settleSimilarityThreshold: settleSimilarityThreshold,
                confirmed: confirmed,
                enableAutoRecovery: enableAutoRecovery,
                secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
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
        settleSimilarityThreshold: Double,
        confirmed: Bool,
        enableAutoRecovery: Bool,
        secureHandoffTimeoutSeconds: TimeInterval
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

        guard streamReady, resolvedIndex != nil else {
            emitMacroEvent(.failed(message: "Shadow DOM stream unavailable"))
            return .streamUnavailable
        }

        let maxRecoveryAttempts = enableAutoRecovery ? 2 : 0
        var recoveryAttempt = 0
        var dismissedNodeIds = Set<Int64>()
        var accumulatedRecovery: [String] = []
        var overallStartHash: UInt64?
        let overallStartTime = ContinuousClock.now

        while true {
            try Task.checkCancellation()

            // If a biometric / FLAG_SECURE screen is active before planning, wait for manual unlock (#7)
            if await domState.isSecureScreenActive {
                let reason = await domState.secureScreenReason ?? "biometric_or_pin"
                let pkg = await domState.secureScreenPackage
                emitMacroEvent(.awaitingBiometrics(reason: reason, activePackage: pkg))
                let cleared = await domState.waitUntilSecureScreenCleared(timeoutSeconds: secureHandoffTimeoutSeconds)
                try Task.checkCancellation()
                guard cleared else {
                    let timeoutSec = Int(secureHandoffTimeoutSeconds.rounded())
                    emitMacroEvent(.failed(message: "Secure screen remained locked past \(timeoutSec)s"))
                    return .secureScreenTimeout(reason: reason, activePackage: pkg, timeoutSeconds: timeoutSec)
                }
                accumulatedRecovery.append("secure_handoff")
                emitMacroEvent(.biometricsCleared)
            }

            guard let currentIndex = await domState.currentIndex else {
                emitMacroEvent(.failed(message: "Shadow DOM stream unavailable"))
                return .streamUnavailable
            }

            let currentFp = hasher.fingerprint(for: currentIndex)
            var startHash = currentFp.layoutHash
            if overallStartHash == nil {
                overallStartHash = startHash
            }

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
                   canonicalVertex.activePackage == currentFp.activePackage,
                   canonicalStart == startHash || (!canonicalVertex.semanticTokens.isEmpty && ScreenLayoutHasher.jaccardSimilarity(currentFp.tokens, canonicalVertex.semanticTokens) >= settleSimilarityThreshold) {
                    startHash = canonicalStart
                }
            }

            let snapshot = await graphEngine.snapshot()
            let (topGoals, allGoals, emptyOrMissingResult) = try await resolveGoals(
                targetHint: targetHint,
                targetHash: targetHash,
                snapshot: snapshot
            )
            if let earlyOutcome = emptyOrMissingResult {
                return earlyOutcome
            }

            let pathfinder = AStarPathfinder(configuration: AStarCostConfiguration(maxSteps: maxSteps))
            var searchResult = pathfinder.findShortestPath(from: startHash, toAnyOf: topGoals, in: snapshot)

            // Semantic aliasing fallback when dynamic items shift the live hash
            if searchResult == nil && !currentFp.tokens.isEmpty {
                let semanticAliases = Self.semanticAliases(
                    for: currentFp,
                    excluding: startHash,
                    in: snapshot.vertices,
                    threshold: settleSimilarityThreshold
                )

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

            // Universal Dismiss Auto-Recovery on no_route (#4)
            guard let route = searchResult else {
                if enableAutoRecovery && recoveryAttempt < maxRecoveryAttempts,
                   let dismiss = UniversalDismissDetector.findDismissCandidate(
                       in: currentIndex,
                       excludingNodeIds: dismissedNodeIds,
                       ignoredPackages: hasher.ignoredPackages
                   ) {
                    dismissedNodeIds.insert(dismiss.nodeId)
                    recoveryAttempt += 1
                    accumulatedRecovery.append("universal_dismiss:\(dismiss.label)")
                    let dismissed = try await executeUniversalDismiss(
                        candidate: dismiss,
                        previousHash: currentFp.layoutHash,
                        serial: serial,
                        executor: executor
                    )
                    if dismissed {
                        continue
                    }
                }

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
                if !accumulatedRecovery.isEmpty {
                    let report = MacroExecutionReport(
                        startHash: overallStartHash ?? startHash,
                        finalHash: startHash,
                        steps: [],
                        totalElapsedMs: Self.elapsedMilliseconds(since: overallStartTime),
                        recoveredSteps: accumulatedRecovery
                    )
                    emitMacroEvent(.completed(report: report))
                    return .arrived(report)
                }
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
                    settleSimilarityThreshold: settleSimilarityThreshold,
                    allowHazardousActions: confirmed,
                    enableForwardSkipRecovery: enableAutoRecovery,
                    enableOverlaySwipeDismiss: enableAutoRecovery,
                    secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                ),
                onEvent: { [weak self] event in
                    self?.emitMacroEvent(event)
                }
            )

            do {
                let report = try await engine.execute(path: route.edges, serial: serial)
                if accumulatedRecovery.isEmpty {
                    return .arrived(report)
                }
                let combinedReport = MacroExecutionReport(
                    startHash: overallStartHash ?? report.startHash,
                    finalHash: report.finalHash,
                    steps: report.steps,
                    totalElapsedMs: Self.elapsedMilliseconds(since: overallStartTime),
                    recoveredSteps: accumulatedRecovery + report.recoveredSteps
                )
                return .arrived(combinedReport)
            } catch PathDeviationError.requiresConfirmation(let req) {
                return .requiresConfirmation(req)
            } catch PathDeviationError.secureScreenTimeout(let reason, let pkg, let timeoutSec) {
                return .secureScreenTimeout(reason: reason, activePackage: pkg, timeoutSeconds: timeoutSec)
            } catch PathDeviationError.unexpectedStartState(let expectedHash, let actualHash, let actualPkg) {
                guard enableAutoRecovery, recoveryAttempt < maxRecoveryAttempts,
                      let liveIndex = await domState.currentIndex else {
                    throw PathDeviationError.unexpectedStartState(
                        expectedHash: expectedHash,
                        actualHash: actualHash,
                        actualPackage: actualPkg
                    )
                }
                let liveFp = hasher.fingerprint(for: liveIndex)
                let refreshedSnapshot = await graphEngine.snapshot()
                if liveFp.layoutHash != startHash,
                   Self.hasExecutableRoute(
                       fromFingerprint: liveFp,
                       toAnyOf: topGoals,
                       in: refreshedSnapshot,
                       pathfinder: pathfinder,
                       threshold: settleSimilarityThreshold
                   ) {
                    recoveryAttempt += 1
                    accumulatedRecovery.append("replan_unexpected_start")
                    emitMacroEvent(.recoveryAction(kind: "replan", detail: "Re-planning A* after start-state shift"))
                    continue
                }
                throw PathDeviationError.unexpectedStartState(
                    expectedHash: expectedHash,
                    actualHash: actualHash,
                    actualPackage: actualPkg
                )
            } catch PathDeviationError.stepTimeout(let stepIdx, let expectedHash, let lastHash, let lastPkg, let timeoutMs) {
                guard enableAutoRecovery, recoveryAttempt < maxRecoveryAttempts,
                      let liveIndex = await domState.currentIndex else {
                    throw PathDeviationError.stepTimeout(
                        stepIndex: stepIdx,
                        expectedTargetHash: expectedHash,
                        lastObservedHash: lastHash,
                        lastObservedPackage: lastPkg,
                        timeoutMs: timeoutMs
                    )
                }

                let liveFp = hasher.fingerprint(for: liveIndex)
                let refreshedSnapshot = await graphEngine.snapshot()

                // 1. Did we actually already reach any target vertex semantically?
                if Self.matchesAnyGoal(
                    fingerprint: liveFp,
                    goals: topGoals,
                    snapshot: refreshedSnapshot,
                    threshold: settleSimilarityThreshold
                ) {
                    let report = MacroExecutionReport(
                        startHash: overallStartHash ?? liveFp.layoutHash,
                        finalHash: liveFp.layoutHash,
                        steps: [],
                        totalElapsedMs: Self.elapsedMilliseconds(since: overallStartTime),
                        recoveredSteps: accumulatedRecovery + ["arrived_on_recheck"]
                    )
                    emitMacroEvent(.completed(report: report))
                    return .arrived(report)
                }

                // 2. Did an in-app popup / promo splash hijack execution mid-route (#4)?
                if let dismiss = UniversalDismissDetector.findDismissCandidate(
                    in: liveIndex,
                    excludingNodeIds: dismissedNodeIds,
                    ignoredPackages: hasher.ignoredPackages
                ) {
                    dismissedNodeIds.insert(dismiss.nodeId)
                    recoveryAttempt += 1
                    accumulatedRecovery.append("universal_dismiss:\(dismiss.label)")
                    if try await executeUniversalDismiss(
                        candidate: dismiss,
                        previousHash: liveFp.layoutHash,
                        serial: serial,
                        executor: executor
                    ) {
                        continue
                    }
                }

                // 3. Can we re-plan from live screen / semantic alias to goal (#1)?
                if liveFp.layoutHash != startHash {
                    let canReplan = Self.hasExecutableRoute(
                        fromFingerprint: liveFp,
                        toAnyOf: topGoals,
                        in: refreshedSnapshot,
                        pathfinder: pathfinder,
                        threshold: settleSimilarityThreshold
                    )
                    if canReplan {
                        recoveryAttempt += 1
                        accumulatedRecovery.append("replan_from:\(String(format: "0x%016llx", liveFp.layoutHash))")
                        emitMacroEvent(.recoveryAction(kind: "replan", detail: "Re-planning A* from live screen"))
                        continue
                    }
                }

                throw PathDeviationError.stepTimeout(
                    stepIndex: stepIdx,
                    expectedTargetHash: expectedHash,
                    lastObservedHash: lastHash,
                    lastObservedPackage: lastPkg,
                    timeoutMs: timeoutMs
                )
            }
        }
    }

    private func resolveGoals(
        targetHint: String?,
        targetHash: UInt64?,
        snapshot: SpatialGraphSnapshot
    ) async throws -> (topGoals: Set<UInt64>, allGoals: Set<UInt64>, earlyOutcome: ShadowNavigationOutcome?) {
        if let targetHash {
            let hex = String(format: "0x%016llx", targetHash)
            guard snapshot.vertices.contains(where: { $0.layoutHash == targetHash }) else {
                let count = snapshot.vertices.count
                emitMacroEvent(.failed(message: "Target \(hex) not found (\(count) screens)"))
                return ([], [], .targetNotFound(query: hex, knownVertexCount: count))
            }
            return ([targetHash], [targetHash], nil)
        } else if let trimmed = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            let ranked = await graphEngine.resolveTargetVertices(matching: trimmed, limit: 12)
            guard let best = ranked.first else {
                let count = snapshot.vertices.count
                emitMacroEvent(.failed(message: "Target '\(trimmed)' not found (\(count) screens)"))
                return ([], [], .targetNotFound(query: trimmed, knownVertexCount: count))
            }
            let top = Set(ranked.filter { $0.score == best.score }.map { $0.vertex.layoutHash })
            let all = Set(ranked.map { $0.vertex.layoutHash })
            return (top, all, nil)
        } else {
            let count = snapshot.vertices.count
            emitMacroEvent(.failed(message: "Empty navigation target (\(count) screens)"))
            return ([], [], .targetNotFound(query: "", knownVertexCount: count))
        }
    }

    private func executeUniversalDismiss(
        candidate: DismissCandidate,
        previousHash: UInt64,
        serial: String,
        executor: MacroActionExecutor
    ) async throws -> Bool {
        emitMacroEvent(.recoveryAction(kind: "universal_dismiss", detail: "Dismissing popup '\(candidate.label)'"))

        let updateStream = await domState.updates
        let tapAction = AttributedUIAction(
            kind: .tap,
            targetDescription: "Dismiss '\(candidate.label)'",
            x: candidate.tapX,
            y: candidate.tapY
        )
        // Do NOT call graphEngine.recordPendingAction so transient popup dismissal never pollutes graph
        try await executor.execute(action: tapAction, serial: serial)

        let hasher = self.hasher
        let settled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in updateStream {
                    if Task.isCancelled { return false }
                    let newHash = hasher.fingerprint(for: update.index).layoutHash
                    if newHash != previousHash || update.index.nodesById[candidate.nodeId] == nil {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(1200))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return settled
    }

    private static func semanticAliases(
        for currentFp: ScreenSemanticFingerprint,
        excluding startHash: UInt64,
        in vertices: [ScreenStateVertex],
        threshold: Double
    ) -> [(hash: UInt64, similarity: Double)] {
        vertices
            .compactMap { vertex -> (hash: UInt64, similarity: Double)? in
                guard vertex.layoutHash != startHash,
                      vertex.activePackage == currentFp.activePackage,
                      !vertex.semanticTokens.isEmpty else {
                    return nil
                }
                let sim = ScreenLayoutHasher.jaccardSimilarity(currentFp.tokens, vertex.semanticTokens)
                guard sim >= threshold else { return nil }
                return (vertex.layoutHash, sim)
            }
            .sorted { lhs, rhs in
                if lhs.similarity != rhs.similarity {
                    return lhs.similarity > rhs.similarity
                }
                return lhs.hash < rhs.hash
            }
    }

    private static func matchesAnyGoal(
        fingerprint: ScreenSemanticFingerprint,
        goals: Set<UInt64>,
        snapshot: SpatialGraphSnapshot,
        threshold: Double
    ) -> Bool {
        if goals.contains(fingerprint.layoutHash) {
            return true
        }
        for vertex in snapshot.vertices where goals.contains(vertex.layoutHash) {
            guard vertex.activePackage == fingerprint.activePackage,
                  !vertex.semanticTokens.isEmpty else { continue }
            if ScreenLayoutHasher.jaccardSimilarity(fingerprint.tokens, vertex.semanticTokens) >= threshold {
                return true
            }
        }
        return false
    }

    private static func hasExecutableRoute(
        fromFingerprint fp: ScreenSemanticFingerprint,
        toAnyOf goals: Set<UInt64>,
        in snapshot: SpatialGraphSnapshot,
        pathfinder: AStarPathfinder,
        threshold: Double
    ) -> Bool {
        if pathfinder.findShortestPath(from: fp.layoutHash, toAnyOf: goals, in: snapshot) != nil {
            return true
        }
        for alias in semanticAliases(for: fp, excluding: fp.layoutHash, in: snapshot.vertices, threshold: threshold) {
            if pathfinder.findShortestPath(from: alias.hash, toAnyOf: goals, in: snapshot) != nil {
                return true
            }
        }
        return false
    }

    private static func reindexedSteps(_ steps: [MacroStepReport]) -> [MacroStepReport] {
        steps.enumerated().map { idx, step in
            MacroStepReport(
                stepIndex: idx,
                edgeId: step.edgeId,
                actionSignature: step.actionSignature,
                targetHash: step.targetHash,
                elapsedMs: step.elapsedMs,
                matchedByExactHash: step.matchedByExactHash,
                wasSkipped: step.wasSkipped
            )
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let millis = (duration.components.seconds * 1_000) + (duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, Int(millis))
    }
}
