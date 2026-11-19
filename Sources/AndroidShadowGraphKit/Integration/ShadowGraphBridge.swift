import Foundation

public struct ExploreCandidate: Sendable, Codable, Equatable {
    public let nodeId: Int64
    public let label: String
    public let resourceId: String
    public let className: String
    public let centerX: Int
    public let centerY: Int
    public let clickable: Bool
    public let scrollable: Bool
    public let score: Int

    public init(
        nodeId: Int64,
        label: String,
        resourceId: String,
        className: String,
        centerX: Int,
        centerY: Int,
        clickable: Bool,
        scrollable: Bool,
        score: Int
    ) {
        self.nodeId = nodeId
        self.label = label
        self.resourceId = resourceId
        self.className = className
        self.centerX = centerX
        self.centerY = centerY
        self.clickable = clickable
        self.scrollable = scrollable
        self.score = score
    }
}

public enum ExploreOutcome: Sendable, Equatable {
    case arrivedViaGraph(
        report: MacroExecutionReport,
        alreadyAtTarget: Bool,
        activePackage: String
    )
    case exploredAndClicked(
        matchedCandidate: ExploreCandidate,
        scrollsPerformed: Int,
        startHash: UInt64,
        finalHash: UInt64,
        activePackage: String,
        screenChanged: Bool,
        edgeRecorded: Bool,
        totalElapsedMs: Int
    )
    case requiresConfirmation(HazardousConfirmationRequest)
    case secureScreenTimeout(reason: String, activePackage: String, timeoutSeconds: Int)
    case needsSelection(
        query: String,
        currentHash: UInt64,
        activePackage: String,
        scrollsPerformed: Int,
        candidates: [ExploreCandidate]
    )
}

public enum ShadowNavigationOutcome: Sendable, Equatable {
    case arrived(MacroExecutionReport)
    case alreadyAtTarget(stateHash: UInt64, activePackage: String)
    case explored(ExploreOutcome)
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
        autoExplore: Bool = false,
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
                autoExplore: autoExplore,
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
        autoExplore: Bool,
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
                if autoExplore,
                   case .targetNotFound = earlyOutcome,
                   let trimmedTarget = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmedTarget.isEmpty {
                    return try await fallbackToAutoExplore(
                        target: trimmedTarget,
                        serial: serial,
                        executor: executor,
                        stepTimeoutMs: stepTimeoutMs,
                        postSettleQuiescenceMs: postSettleQuiescenceMs,
                        settleSimilarityThreshold: settleSimilarityThreshold,
                        confirmed: confirmed,
                        secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                    )
                }
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

                if autoExplore,
                   let trimmedTarget = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmedTarget.isEmpty {
                    return try await fallbackToAutoExplore(
                        target: trimmedTarget,
                        serial: serial,
                        executor: executor,
                        stepTimeoutMs: stepTimeoutMs,
                        postSettleQuiescenceMs: postSettleQuiescenceMs,
                        settleSimilarityThreshold: settleSimilarityThreshold,
                        confirmed: confirmed,
                        secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                    )
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
                if autoExplore,
                   targetHash == nil,
                   let trimmedTarget = targetHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmedTarget.isEmpty,
                   shouldAutoExploreInsteadOfAlreadyAtTarget(
                       target: trimmedTarget,
                       startHash: startHash,
                       currentIndex: currentIndex,
                       snapshot: snapshot
                   ) {
                    return try await fallbackToAutoExplore(
                        target: trimmedTarget,
                        serial: serial,
                        executor: executor,
                        stepTimeoutMs: stepTimeoutMs,
                        postSettleQuiescenceMs: postSettleQuiescenceMs,
                        settleSimilarityThreshold: settleSimilarityThreshold,
                        confirmed: confirmed,
                        secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                    )
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
                    enableSmartScrollToSelector: enableAutoRecovery,
                    recordEdgeFailuresOnTimeout: false,
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
                let failedEdgeOpt: ScreenTransitionEdge? = (stepIdx >= 0 && stepIdx < route.edges.count)
                    ? route.edges[stepIdx]
                    : nil
                guard enableAutoRecovery, recoveryAttempt < maxRecoveryAttempts,
                      let liveIndex = await domState.currentIndex else {
                    if let failedEdge = failedEdgeOpt {
                        await graphEngine.recordEdgeFailure(edgeId: failedEdge.id)
                    }
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
                    if let failedEdge = failedEdgeOpt {
                        await graphEngine.recordEdgeSuccess(edgeId: failedEdge.id)
                    }
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
                        if let failedEdge = failedEdgeOpt {
                            await graphEngine.recordEdgeSuccess(edgeId: failedEdge.id)
                        }
                        continue
                    }
                }

                // Compute cross-package drift context up front so `replan_from` never loops
                // back through a `DeepSubScreen --(HOME)--> Home -> failedEdge` cycle.
                let crossPkgDriftCtx: (edge: ScreenTransitionEdge, expectedToPkg: String)? = {
                    guard let fe = failedEdgeOpt else { return nil }
                    let fromPkg = snapshot.vertices.first(where: { $0.layoutHash == fe.fromHash })?.activePackage ?? ""
                    let expectedToPkg = snapshot.vertices.first(where: { $0.layoutHash == fe.toHash })?.activePackage ?? ""
                    if !expectedToPkg.isEmpty && fromPkg != expectedToPkg && liveFp.activePackage == expectedToPkg {
                        return (fe, expectedToPkg)
                    }
                    return nil
                }()

                // 3. Can we re-plan from live screen / semantic alias to goal (#1)?
                if liveFp.layoutHash != startHash {
                    let canReplan = Self.hasExecutableRouteAvoidingCycle(
                        fromFingerprint: liveFp,
                        toAnyOf: topGoals,
                        in: refreshedSnapshot,
                        pathfinder: pathfinder,
                        threshold: settleSimilarityThreshold,
                        excludedEdgeId: failedEdgeOpt?.id,
                        excludedVertex: crossPkgDriftCtx?.edge.fromHash
                    )
                    if canReplan {
                        if let failedEdge = failedEdgeOpt {
                            await graphEngine.recordEdgeSuccess(edgeId: failedEdge.id)
                        }
                        recoveryAttempt += 1
                        accumulatedRecovery.append("replan_from:\(String(format: "0x%016llx", liveFp.layoutHash))")
                        emitMacroEvent(.recoveryAction(kind: "replan", detail: "Re-planning A* from live screen"))
                        continue
                    }
                }

                // 4. App Task-Stack Drift (Back-to-Root):
                // If a cross-package transition landed on a deep sub-screen inside the target package
                // with no direct in-app route, issue up to 3 safe KEYCODE_BACK presses strictly within
                // that package until a routable vertex appears.
                if let drift = crossPkgDriftCtx {
                    let backResult = try await recoverTaskStackDriftBackToRoot(
                        expectedPackage: drift.expectedToPkg,
                        initialHash: liveFp.layoutHash,
                        topGoals: topGoals,
                        graphSnapshot: refreshedSnapshot,
                        pathfinder: pathfinder,
                        settleThreshold: settleSimilarityThreshold,
                        stepTimeoutMs: stepTimeoutMs,
                        postSettleQuiescenceMs: postSettleQuiescenceMs,
                        failedEdgeId: drift.edge.id,
                        failedFromHash: drift.edge.fromHash,
                        serial: serial,
                        executor: executor
                    )
                    switch backResult {
                    case .arrivedAtGoal(let backsUsed, let finalHash):
                        await graphEngine.recordEdgeSuccess(edgeId: drift.edge.id)
                        let report = MacroExecutionReport(
                            startHash: overallStartHash ?? finalHash,
                            finalHash: finalHash,
                            steps: [],
                            totalElapsedMs: Self.elapsedMilliseconds(since: overallStartTime),
                            recoveredSteps: accumulatedRecovery + ["back_to_root:\(backsUsed)"]
                        )
                        emitMacroEvent(.completed(report: report))
                        return .arrived(report)
                    case .foundRoute(let backsUsed):
                        await graphEngine.recordEdgeSuccess(edgeId: drift.edge.id)
                        recoveryAttempt += 1
                        accumulatedRecovery.append("back_to_root:\(backsUsed)")
                        continue
                    case .notRecovered:
                        break
                    }
                }

                if let failedEdge = failedEdgeOpt {
                    await graphEngine.recordEdgeFailure(edgeId: failedEdge.id)
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
        hasExecutableRouteAvoidingCycle(
            fromFingerprint: fp,
            toAnyOf: goals,
            in: snapshot,
            pathfinder: pathfinder,
            threshold: threshold,
            excludedEdgeId: nil,
            excludedVertex: nil
        )
    }

    private static func hasExecutableRouteAvoidingCycle(
        fromFingerprint fp: ScreenSemanticFingerprint,
        toAnyOf goals: Set<UInt64>,
        in snapshot: SpatialGraphSnapshot,
        pathfinder: AStarPathfinder,
        threshold: Double,
        excludedEdgeId: UUID?,
        excludedVertex: UInt64?
    ) -> Bool {
        func isProductive(_ route: AStarSearchResult) -> Bool {
            if let eid = excludedEdgeId, route.edges.contains(where: { $0.id == eid }) {
                return false
            }
            if let vx = excludedVertex, route.edges.contains(where: { $0.fromHash == vx || $0.toHash == vx }) {
                return false
            }
            return true
        }
        if let route = pathfinder.findShortestPath(from: fp.layoutHash, toAnyOf: goals, in: snapshot),
           isProductive(route) {
            return true
        }
        for alias in semanticAliases(for: fp, excluding: fp.layoutHash, in: snapshot.vertices, threshold: threshold) {
            if let route = pathfinder.findShortestPath(from: alias.hash, toAnyOf: goals, in: snapshot),
               isProductive(route) {
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

    // MARK: - App Task-Stack Drift (Back-to-Root)

    private enum BackToRootResult: Sendable {
        case arrivedAtGoal(backsUsed: Int, finalHash: UInt64)
        case foundRoute(backsUsed: Int)
        case notRecovered
    }

    private enum SingleStreamSettleOutcome: Sendable {
        case settled(ShadowDOMUpdate)
        case secureScreen
        case timedOut
    }

    private actor SingleStreamQuiescenceTracker {
        private var matched: ShadowDOMUpdate?
        private var latest: ShadowDOMUpdate?
        private var firstMatchedAt: ContinuousClock.Instant?
        private var lastUpdateAt: ContinuousClock.Instant?

        func recordMatch(_ upd: ShadowDOMUpdate, now: ContinuousClock.Instant) {
            if matched == nil {
                matched = upd
                firstMatchedAt = now
            }
            latest = upd
            lastUpdateAt = now
        }

        func recordFollowUp(_ upd: ShadowDOMUpdate, now: ContinuousClock.Instant) {
            latest = upd
            lastUpdateAt = now
        }

        func hasMatched() -> Bool {
            matched != nil
        }

        func snapshot() -> (latest: ShadowDOMUpdate?, firstMatchedAt: ContinuousClock.Instant?, lastUpdateAt: ContinuousClock.Instant?) {
            (latest, firstMatchedAt, lastUpdateAt)
        }
    }

    /// Consumes a single pre-subscribed `updateStream` across BOTH initial settlement and
    /// quiescence debounce so fast multi-frame inflation updates are never dropped between phases.
    private func waitForSingleStreamSettleAndQuiesce(
        updateStream: AsyncStream<ShadowDOMUpdate>,
        secureStream: AsyncStream<WireSecureScreenPayload>?,
        waitMs: Int,
        quietMs: Int,
        maxCapMs: Int,
        previousPackage: String,
        isInitialMatch: @Sendable @escaping (ScreenSemanticFingerprint) -> Bool
    ) async -> SingleStreamSettleOutcome {
        let hasherRef = self.hasher
        let tracker = SingleStreamQuiescenceTracker()
        let initialDeadline = ContinuousClock.now + .milliseconds(waitMs)

        return await withTaskGroup(of: SingleStreamSettleOutcome.self) { group in
            // Single continuous stream consumer across both initial settle and quiescence debounce.
            group.addTask {
                for await upd in updateStream {
                    if Task.isCancelled { return .timedOut }
                    if upd.isSecureScreenActive { continue }
                    let fp = hasherRef.fingerprint(for: upd.index)
                    if fp.tokens.isEmpty
                        || Self.isTransientIgnoredSystemFrame(
                            index: upd.index,
                            activePackage: fp.activePackage,
                            previousPackage: previousPackage,
                            ignoredPackages: hasherRef.ignoredPackages
                        ) {
                        continue
                    }
                    if await tracker.hasMatched() {
                        await tracker.recordFollowUp(upd, now: ContinuousClock.now)
                    } else if isInitialMatch(fp) {
                        await tracker.recordMatch(upd, now: ContinuousClock.now)
                        if quietMs <= 0 {
                            return .settled(upd)
                        }
                    }
                }
                if let latest = await tracker.snapshot().latest {
                    return .settled(latest)
                }
                return .timedOut
            }

            if let secureStream {
                group.addTask {
                    for await payload in secureStream {
                        if Task.isCancelled { return .timedOut }
                        if payload.active {
                            return .secureScreen
                        }
                    }
                    return .timedOut
                }
            }

            group.addTask {
                while !Task.isCancelled {
                    let snap = await tracker.snapshot()
                    let now = ContinuousClock.now
                    if let latest = snap.latest,
                       let firstAt = snap.firstMatchedAt,
                       let lastAt = snap.lastUpdateAt {
                        if quietMs <= 0 {
                            return .settled(latest)
                        }
                        let quietDeadline = lastAt + .milliseconds(quietMs)
                        let capDeadline = firstAt + .milliseconds(maxCapMs)
                        let targetWake = quietDeadline < capDeadline ? quietDeadline : capDeadline
                        if now >= targetWake {
                            return .settled(latest)
                        }
                        let rem = targetWake - now
                        let slice = rem < .milliseconds(10) ? rem : .milliseconds(10)
                        try? await Task.sleep(for: slice)
                    } else {
                        if now >= initialDeadline {
                            return .timedOut
                        }
                        let rem = initialDeadline - now
                        let slice = rem < .milliseconds(15) ? rem : .milliseconds(15)
                        try? await Task.sleep(for: slice)
                    }
                }
                return .timedOut
            }

            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    private func recoverTaskStackDriftBackToRoot(
        expectedPackage: String,
        initialHash: UInt64,
        topGoals: Set<UInt64>,
        graphSnapshot: SpatialGraphSnapshot,
        pathfinder: AStarPathfinder,
        settleThreshold: Double,
        stepTimeoutMs: Int,
        postSettleQuiescenceMs: Int,
        failedEdgeId: UUID,
        failedFromHash: UInt64,
        serial: String,
        executor: MacroActionExecutor
    ) async throws -> BackToRootResult {
        var prevHash = initialHash

        for backAttempt in 1...3 {
            try Task.checkCancellation()
            emitMacroEvent(.recoveryAction(
                kind: "back_to_root",
                detail: "Task-stack drift in \(expectedPackage): pressing BACK (\(backAttempt)/3)"
            ))

            // Subscribe BEFORE BACK and do NOT record pending action so recovery never pollutes DAG.
            let updateStream = await domState.updates
            let backAction = AttributedUIAction(kind: .keyevent, targetDescription: "BACK")
            try await executor.execute(action: backAction, serial: serial)

            let waitMs = max(200, min(1200, stepTimeoutMs))
            let quietMs = postSettleQuiescenceMs > 0 ? max(postSettleQuiescenceMs, 220) : 0
            let maxCapMs = max(quietMs * 3, 650)
            let prevHashSnap = prevHash
            let expectedPkgSnap = expectedPackage
            let outcome = await waitForSingleStreamSettleAndQuiesce(
                updateStream: updateStream,
                secureStream: nil,
                waitMs: waitMs,
                quietMs: quietMs,
                maxCapMs: maxCapMs,
                previousPackage: expectedPackage,
                isInitialMatch: { fp in
                    fp.layoutHash != prevHashSnap || fp.activePackage != expectedPkgSnap
                }
            )

            let resolvedAfter: ScreenSemanticFingerprint?
            if case .settled(let settledUpd) = outcome {
                resolvedAfter = hasher.fingerprint(for: settledUpd.index)
            } else if let idx = await domState.currentIndex {
                let fp = hasher.fingerprint(for: idx)
                resolvedAfter = (fp.layoutHash == prevHash) ? nil : fp
            } else {
                resolvedAfter = nil
            }

            guard let afterFp = resolvedAfter else { break }
            guard afterFp.activePackage == expectedPackage else {
                // Never issue further BACK presses once outside the target package.
                break
            }

            if Self.matchesAnyGoal(
                fingerprint: afterFp,
                goals: topGoals,
                snapshot: graphSnapshot,
                threshold: settleThreshold
            ) {
                return .arrivedAtGoal(backsUsed: backAttempt, finalHash: afterFp.layoutHash)
            }

            if Self.hasExecutableRouteAvoidingCycle(
                fromFingerprint: afterFp,
                toAnyOf: topGoals,
                in: graphSnapshot,
                pathfinder: pathfinder,
                threshold: settleThreshold,
                excludedEdgeId: failedEdgeId,
                excludedVertex: failedFromHash
            ) {
                return .foundRoute(backsUsed: backAttempt)
            }

            prevHash = afterFp.layoutHash
        }

        return .notRecovered
    }

    /// Matches `SpatialGraphEngine.process`'s transient status-bar / systemui transition filter.
    private static func isTransientIgnoredSystemFrame(
        index: ShadowTreeIndex,
        activePackage: String,
        previousPackage: String,
        ignoredPackages: Set<String>
    ) -> Bool {
        ignoredPackages.contains(activePackage)
            && !ignoredPackages.contains(previousPackage)
            && !index.orderedNodes.contains(where: { $0.visible && ($0.clickable || $0.scrollable || $0.editable) })
    }

    // MARK: - Dynamic Fallback (`exploreAndClick` & `autoExplore`)

    /// Detects the cold-start / unvisited-subscreen ambiguity where `resolveTargetVertices`
    /// matched the *current* screen solely because a clickable icon/row for `target` (e.g.
    /// "Settings" on Home launcher, or "Display" on Settings root) is in its
    /// `sampleInteractiveLabels`, while the destination screen itself is not yet in the DAG.
    private func shouldAutoExploreInsteadOfAlreadyAtTarget(
        target: String,
        startHash: UInt64,
        currentIndex: ShadowTreeIndex,
        snapshot: SpatialGraphSnapshot
    ) -> Bool {
        let q = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        if currentIndex.activePackage.lowercased().contains(q) {
            return false
        }
        let arrivedViaMatchingAction = snapshot.edges.contains { edge in
            guard edge.toHash == startHash, let action = edge.action else { return false }
            let fields: [String?] = [
                action.targetDescription,
                action.selectorText,
                action.selectorContentDesc,
                action.selectorResourceId,
            ]
            return fields.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains { !$0.isEmpty && ($0 == q || $0.contains(q)) }
        }
        if arrivedViaMatchingAction {
            return false
        }
        let scored = Self.scoreLiveCandidates(
            in: currentIndex,
            query: target,
            ignoredPackages: hasher.ignoredPackages
        )
        return scored.first.map { $0.score >= 500 && $0.clickable } ?? false
    }

    private func fallbackToAutoExplore(
        target: String,
        serial: String,
        executor: MacroActionExecutor,
        stepTimeoutMs: Int,
        postSettleQuiescenceMs: Int,
        settleSimilarityThreshold: Double,
        confirmed: Bool,
        secureHandoffTimeoutSeconds: TimeInterval
    ) async throws -> ShadowNavigationOutcome {
        let outcome = try await performExploreAndClick(
            target: target,
            serial: serial,
            executor: executor,
            maxScrolls: 3,
            stepTimeoutMs: stepTimeoutMs,
            postSettleQuiescenceMs: postSettleQuiescenceMs,
            settleSimilarityThreshold: settleSimilarityThreshold,
            confirmed: confirmed,
            preferGraphRoute: false,
            allowPrefixRoute: true,
            secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
        )
        switch outcome {
        case .arrivedViaGraph(let report, let alreadyAtTarget, let activePackage):
            if alreadyAtTarget && report.steps.isEmpty {
                return .alreadyAtTarget(stateHash: report.finalHash, activePackage: activePackage)
            }
            return .arrived(report)
        case .requiresConfirmation(let req):
            return .requiresConfirmation(req)
        case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
            return .secureScreenTimeout(reason: reason, activePackage: activePackage, timeoutSeconds: timeoutSeconds)
        default:
            return .explored(outcome)
        }
    }

    /// Dynamic live-screen discovery + tap with optional A* graph/prefix routing, bounded scrolling,
    /// HITL hazard checks, heads-up banner dismissal, and DAG edge recording.
    public func exploreAndClick(
        target: String,
        serial: String,
        executor: MacroActionExecutor,
        maxScrolls: Int = 3,
        stepTimeoutMs: Int = 2000,
        postSettleQuiescenceMs: Int = 40,
        settleSimilarityThreshold: Double = 0.80,
        confirmed: Bool = false,
        preferGraphRoute: Bool = true,
        secureHandoffTimeoutSeconds: TimeInterval = 60.0
    ) async throws -> ExploreOutcome {
        guard await navigationGate.tryAcquire() else {
            throw PathDeviationError.executionAlreadyInProgress
        }

        do {
            let outcome = try await performExploreAndClick(
                target: target,
                serial: serial,
                executor: executor,
                maxScrolls: maxScrolls,
                stepTimeoutMs: stepTimeoutMs,
                postSettleQuiescenceMs: postSettleQuiescenceMs,
                settleSimilarityThreshold: settleSimilarityThreshold,
                confirmed: confirmed,
                preferGraphRoute: preferGraphRoute,
                allowPrefixRoute: preferGraphRoute,
                secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
            )
            await navigationGate.release()
            return outcome
        } catch {
            await navigationGate.release()
            throw error
        }
    }

    private func performExploreAndClick(
        target: String,
        serial: String,
        executor: MacroActionExecutor,
        maxScrolls: Int,
        stepTimeoutMs: Int,
        postSettleQuiescenceMs: Int,
        settleSimilarityThreshold: Double,
        confirmed: Bool,
        preferGraphRoute: Bool,
        allowPrefixRoute: Bool,
        secureHandoffTimeoutSeconds: TimeInterval
    ) async throws -> ExploreOutcome {
        let totalStart = ContinuousClock.now
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)

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
            throw PathDeviationError.shadowStreamUnavailable
        }

        if let timeoutOutcome = try await awaitExploreSecureScreen(timeoutSeconds: secureHandoffTimeoutSeconds) {
            return timeoutOutcome
        }

        var activeQuery = trimmedTarget

        // Step 1: Try known A* route when preferGraphRoute == true
        if preferGraphRoute && !activeQuery.isEmpty {
            if let navOutcome = try? await performRouteAndExecute(
                targetHint: activeQuery,
                targetHash: nil,
                serial: serial,
                executor: executor,
                maxSteps: 12,
                stepTimeoutMs: stepTimeoutMs,
                postSettleQuiescenceMs: postSettleQuiescenceMs,
                settleSimilarityThreshold: settleSimilarityThreshold,
                confirmed: confirmed,
                enableAutoRecovery: true,
                autoExplore: false,
                secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
            ) {
                switch navOutcome {
                case .arrived(let report):
                    let pkg = await domState.currentIndex?.activePackage ?? ""
                    return .arrivedViaGraph(report: report, alreadyAtTarget: false, activePackage: pkg)
                case .alreadyAtTarget(let stateHash, let activePackage):
                    let hasClickableMatch: Bool
                    if let idx = await domState.currentIndex {
                        let scored = Self.scoreLiveCandidates(
                            in: idx,
                            query: activeQuery,
                            ignoredPackages: hasher.ignoredPackages
                        )
                        hasClickableMatch = scored.first.map { $0.score >= 500 && $0.clickable } ?? false
                    } else {
                        hasClickableMatch = false
                    }
                    if !hasClickableMatch {
                        let report = MacroExecutionReport(
                            startHash: stateHash,
                            finalHash: stateHash,
                            steps: [],
                            totalElapsedMs: Self.elapsedMilliseconds(since: totalStart)
                        )
                        return .arrivedViaGraph(report: report, alreadyAtTarget: true, activePackage: activePackage)
                    }
                case .requiresConfirmation(let req):
                    return .requiresConfirmation(req)
                case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
                    return .secureScreenTimeout(reason: reason, activePackage: activePackage, timeoutSeconds: timeoutSeconds)
                case .noRoute, .targetNotFound, .explored, .streamUnavailable:
                    break
                }
            }
        }

        // Prefix vertex routing (e.g. "Display > Night Light")
        if allowPrefixRoute && !activeQuery.isEmpty {
            let prefixPairs = Self.extractPrefixAndLeafCandidates(activeQuery)
            let hasExplicitBreadcrumb = prefixPairs.first?.isExplicitBreadcrumb ?? false
            let alreadyHasConfidentLiveMatch: Bool
            if !hasExplicitBreadcrumb, let curIdx = await domState.currentIndex {
                let liveScored = Self.scoreLiveCandidates(
                    in: curIdx,
                    query: activeQuery,
                    ignoredPackages: hasher.ignoredPackages
                )
                alreadyHasConfidentLiveMatch = liveScored.first.map { $0.score >= 500 } ?? false
            } else {
                alreadyHasConfidentLiveMatch = false
            }

            if !alreadyHasConfidentLiveMatch {
                for pair in prefixPairs {
                    let snap = await graphEngine.snapshot()
                    let ranked = await graphEngine.resolveTargetVertices(matching: pair.prefix, limit: 4)
                    guard let bestPrefix = ranked.first, bestPrefix.score >= 500 else { continue }
                    guard let curIdx = await domState.currentIndex else { break }
                    let curFp = hasher.fingerprint(for: curIdx)
                    let pf = AStarPathfinder(configuration: AStarCostConfiguration())
                    let goals: Set<UInt64> = [bestPrefix.vertex.layoutHash]
                    var routeOpt = pf.findShortestPath(from: curFp.layoutHash, toAnyOf: goals, in: snap)
                    if routeOpt == nil {
                        for alias in Self.semanticAliases(
                            for: curFp,
                            excluding: curFp.layoutHash,
                            in: snap.vertices,
                            threshold: settleSimilarityThreshold
                        ) {
                            if let r = pf.findShortestPath(from: alias.hash, toAnyOf: goals, in: snap) {
                                routeOpt = r
                                break
                            }
                        }
                    }
                    guard let route = routeOpt else { continue }
                    if route.edges.isEmpty {
                        if pair.isExplicitBreadcrumb
                            && !shouldAutoExploreInsteadOfAlreadyAtTarget(
                                target: pair.prefix,
                                startHash: curFp.layoutHash,
                                currentIndex: curIdx,
                                snapshot: snap
                            ) {
                            activeQuery = pair.leaf
                            break
                        }
                        continue
                    }
                    let prefixNav = try? await performRouteAndExecute(
                        targetHint: nil,
                        targetHash: bestPrefix.vertex.layoutHash,
                        serial: serial,
                        executor: executor,
                        maxSteps: 12,
                        stepTimeoutMs: stepTimeoutMs,
                        postSettleQuiescenceMs: postSettleQuiescenceMs,
                        settleSimilarityThreshold: settleSimilarityThreshold,
                        confirmed: confirmed,
                        enableAutoRecovery: true,
                        autoExplore: false,
                        secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                    )
                    switch prefixNav {
                    case .arrived, .alreadyAtTarget:
                        activeQuery = pair.leaf
                    case .requiresConfirmation(let req):
                        return .requiresConfirmation(req)
                    case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
                        return .secureScreenTimeout(reason: reason, activePackage: activePackage, timeoutSeconds: timeoutSeconds)
                    default:
                        continue
                    }
                    break
                }
            }
        }

        // Steps 2–4: Score visible non-system nodes + bounded scrolling
        var scrollsPerformed = 0
        var scrollingDown = true
        var reversedDirection = false

        while true {
            try Task.checkCancellation()
            if let timeoutOutcome = try await awaitExploreSecureScreen(timeoutSeconds: secureHandoffTimeoutSeconds) {
                return timeoutOutcome
            }

            guard let currentIndex = await domState.currentIndex else {
                throw PathDeviationError.shadowStreamUnavailable
            }

            let scored = activeQuery.isEmpty
                ? []
                : Self.scoreLiveCandidates(in: currentIndex, query: activeQuery, ignoredPackages: hasher.ignoredPackages)

            if let bestCandidate = scored.first, bestCandidate.score >= 500 {
                return try await executeExploreCandidateTap(
                    candidate: bestCandidate,
                    initialIndex: currentIndex,
                    activeQuery: activeQuery,
                    scrollsPerformed: scrollsPerformed,
                    totalStart: totalStart,
                    serial: serial,
                    executor: executor,
                    stepTimeoutMs: stepTimeoutMs,
                    postSettleQuiescenceMs: postSettleQuiescenceMs,
                    confirmed: confirmed,
                    secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
                )
            }

            if scrollsPerformed >= maxScrolls {
                break
            }

            guard let scrollRect = MacroExecutionEngine.largestScrollableRect(
                in: currentIndex,
                ignoredPackages: hasher.ignoredPackages
            ) else {
                break
            }

            let beforeFp = hasher.fingerprint(for: currentIndex)
            let beforeSig = MacroExecutionEngine.scrollViewportSignature(
                in: currentIndex,
                container: scrollRect,
                ignoredPackages: hasher.ignoredPackages
            )
            let beforeHash = await seedVertexIfAbsent(index: currentIndex, rawHash: beforeFp.layoutHash)
            let scrollStart = Date()

            let cx = max(1, (scrollRect.minX + scrollRect.maxX) / 2)
            let spanY = scrollRect.maxY - scrollRect.minY
            let yHigh = scrollRect.minY + (spanY * 72) / 100
            let yLow = scrollRect.minY + (spanY * 28) / 100
            let startY = scrollingDown ? yHigh : yLow
            let endY = scrollingDown ? yLow : yHigh
            let dirLabel = scrollingDown ? "down" : "up"

            let swipeAction = AttributedUIAction(
                kind: .swipe,
                targetDescription: "explore_scroll_\(dirLabel)",
                x: cx,
                y: startY,
                endX: cx,
                endY: endY,
                durationMs: 500
            )

            emitMacroEvent(.recoveryAction(
                kind: "explore_scroll",
                detail: "Scrolling \(dirLabel) (\(scrollsPerformed + 1)/\(maxScrolls)) searching for '\(activeQuery)'"
            ))

            let updateStream = await domState.updates
            await graphEngine.recordPendingAction(swipeAction)
            try await executor.execute(action: swipeAction, serial: serial)

            let waitMs = max(150, min(1200, stepTimeoutMs))
            let hasherRef = self.hasher
            let ignored = hasher.ignoredPackages
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await upd in updateStream {
                        if Task.isCancelled { return }
                        if upd.isSecureScreenActive { continue }
                        let nextFp = hasherRef.fingerprint(for: upd.index)
                        if nextFp.tokens.isEmpty
                            || Self.isTransientIgnoredSystemFrame(
                                index: upd.index,
                                activePackage: nextFp.activePackage,
                                previousPackage: beforeFp.activePackage,
                                ignoredPackages: ignored
                            ) {
                            continue
                        }
                        let nextSig = MacroExecutionEngine.scrollViewportSignature(
                            in: upd.index,
                            container: scrollRect,
                            ignoredPackages: ignored
                        )
                        if nextFp.layoutHash != beforeFp.layoutHash || nextSig != beforeSig {
                            return
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(waitMs))
                }
                _ = await group.next()
                group.cancelAll()
            }

            if postSettleQuiescenceMs > 0 {
                try await Task.sleep(for: .milliseconds(max(postSettleQuiescenceMs, 400)))
            }

            if let afterIdx = await domState.currentIndex {
                let afterFp = hasher.fingerprint(for: afterIdx)
                // If a swipe accidentally pulled down a system overlay (e.g. notification shade),
                // abort scrolling without poisoning the DAG with a systemui transition edge.
                if afterFp.activePackage != beforeFp.activePackage
                    && hasher.ignoredPackages.contains(afterFp.activePackage) {
                    scrollsPerformed += 1
                    break
                }

                let afterUpdate = ShadowDOMUpdate(
                    index: afterIdx,
                    isFullSnapshot: false,
                    insertedCount: 0,
                    updatedCount: afterIdx.orderedNodes.count,
                    removedCount: 0,
                    eventType: nil,
                    eventPackage: afterIdx.activePackage,
                    isSecureScreenActive: false
                )
                await graphEngine.process(update: afterUpdate)

                // If mid-scroll deceleration frames consumed `pendingAction` before the list
                // settled, bridge `(beforeHash -> settledAfterHash)` directly with `swipeAction`
                // so A* has a continuous executable edge across scrolled screens (no implicit gap).
                let currentGraphHash = await graphEngine.currentStateHash
                let resolvedAfterHash: UInt64 = (afterFp.layoutHash != beforeFp.layoutHash ? currentGraphHash : nil) ?? afterFp.layoutHash
                if resolvedAfterHash != beforeHash {
                    let existing = await graphEngine.neighbors(of: beforeHash)
                    let hasDirectExec = existing.contains { $0.toHash == resolvedAfterHash && $0.action != nil }
                    if !hasDirectExec {
                        _ = await graphEngine.recordDirectEdge(
                            fromHash: beforeHash,
                            toHash: resolvedAfterHash,
                            action: swipeAction,
                            transitionMs: Date().timeIntervalSince(scrollStart) * 1000.0
                        )
                    }
                }

                let afterSig = MacroExecutionEngine.scrollViewportSignature(
                    in: afterIdx,
                    container: scrollRect,
                    ignoredPackages: hasher.ignoredPackages
                )
                scrollsPerformed += 1

                // Compare post-quiescence viewport (ignoring transient overscroll spring frames)
                if afterFp.layoutHash == beforeFp.layoutHash && afterSig == beforeSig {
                    if scrollingDown && !reversedDirection {
                        scrollingDown = false
                        reversedDirection = true
                    } else {
                        break
                    }
                }
            } else {
                scrollsPerformed += 1
                break
            }
        }

        // Step 5: Top-20 PII-scrubbed interactive candidates
        guard let finalIndex = await domState.currentIndex else {
            throw PathDeviationError.shadowStreamUnavailable
        }
        let finalFp = hasher.fingerprint(for: finalIndex)
        let candidates = Self.collectTopInteractiveCandidates(
            in: finalIndex,
            query: activeQuery,
            ignoredPackages: hasher.ignoredPackages,
            limit: 20
        )

        return .needsSelection(
            query: trimmedTarget,
            currentHash: finalFp.layoutHash,
            activePackage: finalFp.activePackage,
            scrollsPerformed: scrollsPerformed,
            candidates: candidates
        )
    }

    private func executeExploreCandidateTap(
        candidate initialCandidate: ExploreCandidate,
        initialIndex: ShadowTreeIndex,
        activeQuery: String,
        scrollsPerformed: Int,
        totalStart: ContinuousClock.Instant,
        serial: String,
        executor: MacroActionExecutor,
        stepTimeoutMs: Int,
        postSettleQuiescenceMs: Int,
        confirmed: Bool,
        secureHandoffTimeoutSeconds: TimeInterval
    ) async throws -> ExploreOutcome {
        var candidate = initialCandidate
        var liveIndex = initialIndex
        var rawNode = liveIndex.nodesById[candidate.nodeId]

        func buildAction(cand: ExploreCandidate, nodeOpt: ShadowUINode?) -> AttributedUIAction {
            let desc: String
            if !cand.label.isEmpty {
                desc = cand.label
            } else if !cand.resourceId.isEmpty {
                desc = cand.resourceId
            } else {
                desc = "(\(cand.centerX),\(cand.centerY))"
            }
            return AttributedUIAction(
                kind: .tap,
                targetDescription: desc,
                x: cand.centerX,
                y: cand.centerY,
                selectorResourceId: (nodeOpt?.resourceId.isEmpty == false)
                    ? nodeOpt?.resourceId
                    : (cand.resourceId.isEmpty ? nil : cand.resourceId),
                selectorText: (nodeOpt?.text.isEmpty == false) ? nodeOpt?.text : nil,
                selectorContentDesc: (nodeOpt?.contentDesc.isEmpty == false) ? nodeOpt?.contentDesc : nil
            )
        }

        var action = buildAction(cand: candidate, nodeOpt: rawNode)

        // Hazardous / irreversible transaction HITL check
        let rawLabel = rawNode.map { !$0.text.isEmpty ? $0.text : $0.contentDesc } ?? candidate.label
        let hazard = HazardousActionClassifier.assess(
            action: action,
            actionSignature: action.signature,
            liveLabel: rawLabel,
            liveResourceId: candidate.resourceId
        )
        if hazard.isHazardous && !confirmed {
            let currentHash = hasher.fingerprint(for: liveIndex).layoutHash
            let req = HazardousConfirmationRequest(
                stepIndex: 0,
                totalSteps: 1,
                actionSignature: action.signature,
                targetDescription: action.targetDescription,
                hazardCategory: hazard.category ?? .destructive,
                hazardReason: hazard.reason,
                currentHash: currentHash,
                targetHash: currentHash,
                stepsCompleted: 0,
                tapX: action.x,
                tapY: action.y
            )
            emitMacroEvent(.awaitingConfirmation(stepIndex: 0, totalSteps: 1, action: action, reason: req.hazardReason))
            return .requiresConfirmation(req)
        }

        // Dismiss occluding heads-up banner if present
        for attempt in 0..<2 {
            guard let bannerRect = MacroExecutionEngine.occludingSystemBannerRect(
                in: liveIndex,
                tapX: candidate.centerX,
                tapY: candidate.centerY
            ) else {
                break
            }
            let swipeX = max(1, (bannerRect.minX + bannerRect.maxX) / 2)
            let startY = max(20, bannerRect.maxY - 20)
            let endY = max(10, bannerRect.minY - 120)
            let dismissSwipe = AttributedUIAction(
                kind: .swipe,
                targetDescription: "Dismiss occluding notification",
                x: swipeX,
                y: startY,
                endX: swipeX,
                endY: endY,
                durationMs: 160
            )
            emitMacroEvent(.recoveryAction(
                kind: "dismiss_notification_overlay",
                detail: "Swiped up occluding system notification (\(attempt + 1)/2)"
            ))
            let bannerStream = await domState.updates
            try await executor.execute(action: dismissSwipe, serial: serial)
            let tapX = candidate.centerX
            let tapY = candidate.centerY
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await upd in bannerStream {
                        if MacroExecutionEngine.occludingSystemBannerRect(in: upd.index, tapX: tapX, tapY: tapY) == nil {
                            return
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(450))
                }
                _ = await group.next()
                group.cancelAll()
            }

            if let refreshedIdx = await domState.currentIndex {
                liveIndex = refreshedIdx
                if let refreshedCand = Self.scoreLiveCandidates(
                    in: liveIndex,
                    query: activeQuery,
                    ignoredPackages: hasher.ignoredPackages
                ).first, refreshedCand.score >= 500 {
                    candidate = refreshedCand
                    rawNode = liveIndex.nodesById[candidate.nodeId]
                    action = buildAction(cand: candidate, nodeOpt: rawNode)

                    if !confirmed {
                        let postRawLabel = rawNode.map { !$0.text.isEmpty ? $0.text : $0.contentDesc } ?? candidate.label
                        let postHazard = HazardousActionClassifier.assess(
                            action: action,
                            actionSignature: action.signature,
                            liveLabel: postRawLabel,
                            liveResourceId: candidate.resourceId
                        )
                        if postHazard.isHazardous {
                            let currentHash = hasher.fingerprint(for: liveIndex).layoutHash
                            let req = HazardousConfirmationRequest(
                                stepIndex: 0,
                                totalSteps: 1,
                                actionSignature: action.signature,
                                targetDescription: action.targetDescription,
                                hazardCategory: postHazard.category ?? .destructive,
                                hazardReason: postHazard.reason,
                                currentHash: currentHash,
                                targetHash: currentHash,
                                stepsCompleted: 0,
                                tapX: action.x,
                                tapY: action.y
                            )
                            emitMacroEvent(.awaitingConfirmation(stepIndex: 0, totalSteps: 1, action: action, reason: req.hazardReason))
                            return .requiresConfirmation(req)
                        }
                    }
                }
            }
        }

        let beforeFp = hasher.fingerprint(for: liveIndex)
        let beforeHash = await seedVertexIfAbsent(index: liveIndex, rawHash: beforeFp.layoutHash)
        let edgesBefore = await graphEngine.edgeCount

        let updateStream = await domState.updates
        let secureStream = await domState.secureScreenUpdates
        await graphEngine.recordPendingAction(action)
        emitMacroEvent(.willExecuteAction(stepIndex: 0, totalSteps: 1, action: action))
        try await executor.execute(action: action, serial: serial)

        let waitMs = max(100, stepTimeoutMs)
        let quietMs = postSettleQuiescenceMs > 0 ? max(postSettleQuiescenceMs, 220) : 0
        let maxCapMs = max(quietMs * 3, 750)
        let beforeFpHash = beforeFp.layoutHash
        let tapOutcome = await waitForSingleStreamSettleAndQuiesce(
            updateStream: updateStream,
            secureStream: secureStream,
            waitMs: waitMs,
            quietMs: quietMs,
            maxCapMs: maxCapMs,
            previousPackage: beforeFp.activePackage,
            isInitialMatch: { fp in
                fp.layoutHash != beforeFpHash && fp.layoutHash != beforeHash
            }
        )

        var settledUpdate: ShadowDOMUpdate?
        switch tapOutcome {
        case .settled(let u):
            settledUpdate = u
        case .secureScreen:
            if let timeoutOutcome = try await awaitExploreSecureScreen(timeoutSeconds: secureHandoffTimeoutSeconds) {
                return timeoutOutcome
            }
        case .timedOut:
            break
        }

        let liveAfter = await domState.currentIndex
        let finalIndex: ShadowTreeIndex
        if let liveAfter,
           let su = settledUpdate,
           Self.isTransientIgnoredSystemFrame(
               index: liveAfter,
               activePackage: liveAfter.activePackage,
               previousPackage: beforeFp.activePackage,
               ignoredPackages: hasher.ignoredPackages
           ) {
            finalIndex = su.index
        } else if let liveAfter {
            finalIndex = liveAfter
        } else if let su = settledUpdate {
            finalIndex = su.index
        } else {
            finalIndex = liveIndex
        }
        let finalFp = hasher.fingerprint(for: finalIndex)
        let commitUpdate = ShadowDOMUpdate(
            index: finalIndex,
            isFullSnapshot: false,
            insertedCount: 0,
            updatedCount: finalIndex.orderedNodes.count,
            removedCount: 0,
            eventType: nil,
            eventPackage: finalIndex.activePackage,
            isSecureScreenActive: false
        )
        var processedEdge = await graphEngine.process(update: commitUpdate) != nil

        let currentGraphHash = await graphEngine.currentStateHash
        let resolvedFinalHash: UInt64 = (finalFp.layoutHash != beforeFp.layoutHash ? currentGraphHash : nil) ?? finalFp.layoutHash

        // If intermediate skeleton frames consumed `pendingAction` before the final settled screen
        // finished inflating, bridge `(beforeHash -> resolvedFinalHash)` directly with `action`
        // so A* has a clean executable edge without an implicit gap.
        if resolvedFinalHash != beforeHash {
            let neighbors = await graphEngine.neighbors(of: beforeHash)
            let hasDirectExec = neighbors.contains(where: { $0.toHash == resolvedFinalHash && $0.action != nil })
            if !hasDirectExec,
               await graphEngine.recordDirectEdge(
                   fromHash: beforeHash,
                   toHash: resolvedFinalHash,
                   action: action,
                   transitionMs: Double(Self.elapsedMilliseconds(since: totalStart))
               ) != nil {
                processedEdge = true
            }
        }

        let edgesAfter = await graphEngine.edgeCount
        let edgeRecorded: Bool
        if processedEdge || edgesAfter > edgesBefore {
            edgeRecorded = true
        } else if resolvedFinalHash != beforeHash {
            let neighbors = await graphEngine.neighbors(of: beforeHash)
            edgeRecorded = neighbors.contains(where: { $0.toHash == resolvedFinalHash })
        } else {
            edgeRecorded = false
        }
        let screenChanged = (finalFp.layoutHash != beforeFp.layoutHash) || (resolvedFinalHash != beforeHash)

        return .exploredAndClicked(
            matchedCandidate: candidate,
            scrollsPerformed: scrollsPerformed,
            startHash: beforeHash,
            finalHash: resolvedFinalHash,
            activePackage: finalFp.activePackage,
            screenChanged: screenChanged,
            edgeRecorded: edgeRecorded,
            totalElapsedMs: Self.elapsedMilliseconds(since: totalStart)
        )
    }

    private func seedVertexIfAbsent(index: ShadowTreeIndex, rawHash: UInt64) async -> UInt64 {
        var effectiveHash = rawHash
        let hasVertex = await graphEngine.vertices[rawHash] != nil
        let hasCurrent = await graphEngine.currentStateHash != nil
        if !hasVertex || !hasCurrent {
            await graphEngine.process(update: ShadowDOMUpdate(
                index: index,
                isFullSnapshot: true,
                insertedCount: index.orderedNodes.count,
                updatedCount: 0,
                removedCount: 0,
                eventType: nil,
                eventPackage: index.activePackage,
                isSecureScreenActive: false
            ))
            if let cur = await graphEngine.currentStateHash {
                effectiveHash = cur
            }
        }
        return effectiveHash
    }

    private func awaitExploreSecureScreen(timeoutSeconds: TimeInterval) async throws -> ExploreOutcome? {
        guard await domState.isSecureScreenActive else { return nil }
        let reason = await domState.secureScreenReason ?? "biometric_or_pin"
        let pkg = await domState.secureScreenPackage
        emitMacroEvent(.awaitingBiometrics(reason: reason, activePackage: pkg))
        let cleared = await domState.waitUntilSecureScreenCleared(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        guard cleared else {
            let timeoutSec = Int(timeoutSeconds.rounded())
            emitMacroEvent(.failed(message: "Secure screen remained locked past \(timeoutSec)s"))
            return .secureScreenTimeout(reason: reason, activePackage: pkg, timeoutSeconds: timeoutSec)
        }
        emitMacroEvent(.biometricsCleared)
        return nil
    }

    /// Scores visible non-system UI nodes against `query`:
    /// exact = 1000, prefix = 700, resourceId suffix = 600, contains = 500,
    /// token overlap = 250–450, +100 for clickable or clickable ancestor.
    public static func scoreLiveCandidates(
        in index: ShadowTreeIndex,
        query: String,
        ignoredPackages: Set<String> = ["com.android.systemui"]
    ) -> [ExploreCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let qLower = trimmed.lowercased()
        let qTokens = tokenizeWords(qLower)
        let skipIgnored = !ignoredPackages.contains(index.activePackage)

        var scored: [(candidate: ExploreCandidate, enabled: Bool, area: Int64, index: Int)] = []

        for node in index.orderedNodes {
            guard node.visible, (node.centerX > 0 || node.centerY > 0) else { continue }
            if skipIgnored && isIgnoredNode(node, ignoredPackages: ignoredPackages) { continue }

            let area = ShadowTreeIndex.parseBoundsRect(node.bounds)?.area ?? Int64.max
            let baseScore = nodeMatchBaseScore(node, qLower: qLower, qTokens: qTokens)
            guard baseScore > 0 else { continue }

            let effectiveClickable = node.clickable || hasClickableAncestor(in: index, node: node)
            let totalScore = baseScore + (effectiveClickable ? 100 : 0)

            let rawLabel: String
            if !node.text.isEmpty {
                rawLabel = node.text
            } else if !node.contentDesc.isEmpty {
                rawLabel = node.contentDesc
            } else {
                rawLabel = ShadowTreeIndex.extractShortResourceId(node.resourceId)
            }
            let safeLabel = ScreenLayoutHasher.redactPII(rawLabel)

            scored.append((
                candidate: ExploreCandidate(
                    nodeId: node.nodeId,
                    label: safeLabel,
                    resourceId: node.resourceId,
                    className: node.className,
                    centerX: node.centerX,
                    centerY: node.centerY,
                    clickable: effectiveClickable,
                    scrollable: node.scrollable,
                    score: totalScore
                ),
                enabled: node.enabled,
                area: area,
                index: node.index
            ))
        }

        scored.sort { lhs, rhs in
            if lhs.candidate.score != rhs.candidate.score { return lhs.candidate.score > rhs.candidate.score }
            if lhs.enabled != rhs.enabled { return lhs.enabled }
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return lhs.index < rhs.index
        }
        return scored.map(\.candidate)
    }

    /// Returns up to `limit` PII-scrubbed interactive candidates on the live screen for LLM selection.
    public static func collectTopInteractiveCandidates(
        in index: ShadowTreeIndex,
        query: String,
        ignoredPackages: Set<String> = ["com.android.systemui"],
        limit: Int = 20
    ) -> [ExploreCandidate] {
        let qLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let qTokens = tokenizeWords(qLower)
        let skipIgnored = !ignoredPackages.contains(index.activePackage)

        struct DedupKey: Hashable {
            let label: String
            let x: Int
            let y: Int
        }

        var rawList: [(candidate: ExploreCandidate, index: Int)] = []
        var seenKeys = Set<DedupKey>()

        for node in index.orderedNodes {
            guard node.visible, (node.centerX > 0 || node.centerY > 0) else { continue }
            if skipIgnored && isIgnoredNode(node, ignoredPackages: ignoredPackages) { continue }

            let effectiveClickable = node.clickable || hasClickableAncestor(in: index, node: node)
            let rawLabel: String
            if !node.text.isEmpty {
                rawLabel = node.text
            } else if !node.contentDesc.isEmpty {
                rawLabel = node.contentDesc
            } else {
                rawLabel = ShadowTreeIndex.extractShortResourceId(node.resourceId)
            }
            let isInteractive = effectiveClickable || node.scrollable || node.editable
            guard isInteractive || !rawLabel.isEmpty else { continue }

            let safeLabel = String(ScreenLayoutHasher.redactPII(rawLabel).prefix(64))
            guard !safeLabel.isEmpty || !node.resourceId.isEmpty else { continue }

            let key = DedupKey(label: safeLabel, x: node.centerX, y: node.centerY)
            guard seenKeys.insert(key).inserted else { continue }

            let baseScore = qLower.isEmpty ? 0 : nodeMatchBaseScore(node, qLower: qLower, qTokens: qTokens)
            let score = baseScore > 0 ? (baseScore + (effectiveClickable ? 100 : 0)) : 0

            rawList.append((
                candidate: ExploreCandidate(
                    nodeId: node.nodeId,
                    label: safeLabel,
                    resourceId: node.resourceId,
                    className: node.className,
                    centerX: node.centerX,
                    centerY: node.centerY,
                    clickable: effectiveClickable,
                    scrollable: node.scrollable,
                    score: score
                ),
                index: node.index
            ))
        }

        rawList.sort { lhs, rhs in
            if lhs.candidate.score != rhs.candidate.score { return lhs.candidate.score > rhs.candidate.score }
            if lhs.candidate.clickable != rhs.candidate.clickable { return lhs.candidate.clickable }
            let lhsHasLabel = !lhs.candidate.label.isEmpty
            let rhsHasLabel = !rhs.candidate.label.isEmpty
            if lhsHasLabel != rhsHasLabel { return lhsHasLabel }
            return lhs.index < rhs.index
        }

        return Array(rawList.prefix(max(1, limit)).map(\.candidate))
    }

    private static func nodeMatchBaseScore(_ node: ShadowUINode, qLower: String, qTokens: [String]) -> Int {
        var best = 0

        for candidateRaw in [node.text, node.contentDesc] {
            let trimmed = candidateRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if lower == qLower {
                best = max(best, 1000)
            } else if lower.hasPrefix(qLower) {
                best = max(best, 700)
            } else if lower.contains(qLower) {
                best = max(best, 500)
            } else if !qTokens.isEmpty {
                let nTokens = tokenizeWords(lower)
                best = max(best, tokenOverlapScore(qTokens: qTokens, nTokens: nTokens))
            }
        }

        if !node.resourceId.isEmpty {
            let ridLower = node.resourceId.lowercased()
            let shortRid = ShadowTreeIndex.extractShortResourceId(ridLower)
            if ridLower == qLower || shortRid == qLower || (qLower.count >= 2 && shortRid.hasSuffix(qLower)) {
                best = max(best, 600)
            } else if !qTokens.isEmpty {
                let ridTokens = tokenizeWords(shortRid)
                best = max(best, tokenOverlapScore(qTokens: qTokens, nTokens: ridTokens))
            }
        }

        return best
    }

    private static func tokenOverlapScore(qTokens: [String], nTokens: [String]) -> Int {
        guard !qTokens.isEmpty, !nTokens.isEmpty else { return 0 }
        let nSet = Set(nTokens)
        let qSet = Set(qTokens)
        let overlap = qSet.filter { nSet.contains($0) }.count
        guard overlap > 0 else { return 0 }
        if qSet.count >= 2 && overlap == qSet.count {
            return 450
        }
        let union = qSet.count + nSet.count - overlap
        guard union > 0 else { return 0 }
        let jaccard = Double(overlap) / Double(union)
        let raw = Int((250.0 + 140.0 * jaccard).rounded())
        return min(390, max(250, raw))
    }

    private static func tokenizeWords(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func hasClickableAncestor(in index: ShadowTreeIndex, node: ShadowUINode) -> Bool {
        var cursor = node.parentId
        var hops = 0
        var visited: Set<Int64> = [node.nodeId]
        while let pid = cursor, hops < 12, visited.insert(pid).inserted {
            guard let parent = index.nodesById[pid] else { break }
            if parent.clickable { return true }
            cursor = parent.parentId
            hops += 1
        }
        return false
    }

    private static func isIgnoredNode(_ node: ShadowUINode, ignoredPackages: Set<String>) -> Bool {
        if !node.packageName.isEmpty && ignoredPackages.contains(node.packageName) {
            return true
        }
        if !node.resourceId.isEmpty {
            for pkg in ignoredPackages where node.resourceId.hasPrefix("\(pkg):") {
                return true
            }
        }
        return false
    }

    private static func extractPrefixAndLeafCandidates(_ query: String) -> [(prefix: String, leaf: String, isExplicitBreadcrumb: Bool)] {
        for sep in ["->", ">", "»", " / ", " | "] {
            if query.contains(sep) {
                let parts = query
                    .components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let leaf = parts[parts.count - 1]
                    var out: [(String, String, Bool)] = []
                    for idx in stride(from: parts.count - 2, through: 0, by: -1) {
                        out.append((parts[idx], leaf, true))
                    }
                    return out
                }
            }
        }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count >= 2 {
            var out: [(String, String, Bool)] = []
            for splitAt in stride(from: words.count - 1, through: 1, by: -1) {
                let prefix = words[0..<splitAt].joined(separator: " ")
                let leaf = words[splitAt..<words.count].joined(separator: " ")
                if !prefix.isEmpty && !leaf.isEmpty {
                    out.append((prefix, leaf, false))
                }
            }
            return out
        }
        return []
    }
}
