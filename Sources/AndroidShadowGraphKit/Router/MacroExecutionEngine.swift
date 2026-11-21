import Foundation

/// Race-free asynchronous state-machine actor that sequentially executes `[ScreenTransitionEdge]` paths,
/// subscribing to `ShadowDOMState.updates` before dispatching each UI action and enforcing a strict settle deadline.
public actor MacroExecutionEngine {
    private let domState: ShadowDOMState
    private let graphEngine: SpatialGraphEngine
    private let executor: MacroActionExecutor
    private let hasher: ScreenLayoutHasher
    private let configuration: MacroExecutionConfiguration
    private let onEvent: (@Sendable (MacroExecutionEvent) -> Void)?

    private var isExecuting: Bool = false
    private var eventContinuations: [UUID: AsyncStream<MacroExecutionEvent>.Continuation] = [:]

    public init(
        domState: ShadowDOMState,
        graphEngine: SpatialGraphEngine,
        executor: MacroActionExecutor,
        hasher: ScreenLayoutHasher = ScreenLayoutHasher(),
        configuration: MacroExecutionConfiguration = MacroExecutionConfiguration(),
        onEvent: (@Sendable (MacroExecutionEvent) -> Void)? = nil
    ) {
        self.domState = domState
        self.graphEngine = graphEngine
        self.executor = executor
        self.hasher = hasher
        self.configuration = configuration
        self.onEvent = onEvent
    }

    deinit {
        for continuation in eventContinuations.values {
            continuation.finish()
        }
    }

    /// Broadcast stream of non-blocking execution events consumed by visual HUD overlays.
    public var events: AsyncStream<MacroExecutionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func emit(_ event: MacroExecutionEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
        onEvent?(event)
    }

    /// Executes `path` step-by-step against `serial`, awaiting `ShadowDOMState` settlement on each expected `toHash`
    /// within `configuration.stepTimeoutMs` (default 2000ms). Supports forward-skip recovery (#1), HITL confirmation (#2),
    /// reflexive push-banner swipe dismissal (#3), and `FLAG_SECURE` / biometric pauses (#7).
    public func execute(
        path: [ScreenTransitionEdge],
        serial: String
    ) async throws -> MacroExecutionReport {
        guard !isExecuting else {
            throw PathDeviationError.executionAlreadyInProgress
        }
        isExecuting = true
        defer { isExecuting = false }

        let totalStart = ContinuousClock.now
        _ = try await awaitSecureHandoffIfActive()

        guard let initialIndex = await domState.currentIndex else {
            throw PathDeviationError.shadowStreamUnavailable
        }

        let initialFp = hasher.fingerprint(for: initialIndex)
        guard let firstEdge = path.first else {
            return MacroExecutionReport(
                startHash: initialFp.layoutHash,
                finalHash: initialFp.layoutHash,
                steps: [],
                totalElapsedMs: 0
            )
        }

        // Preload expected destination vertices for all hops in the path to support forward-skip recovery (#1).
        let graphVertices = await graphEngine.vertices
        let expectedVertices: [ScreenStateVertex?] = path.map { graphVertices[$0.toHash] }

        let matchesFrom = Self.matchesVertex(
            fingerprint: initialFp,
            expectedHash: firstEdge.fromHash,
            expectedVertex: graphVertices[firstEdge.fromHash],
            threshold: configuration.settleSimilarityThreshold
        ).matched

        let matchesAnyTarget: Bool = {
            if configuration.enableForwardSkipRecovery {
                return (0..<path.count).contains { idx in
                    Self.matchesVertex(
                        fingerprint: initialFp,
                        expectedHash: path[idx].toHash,
                        expectedVertex: expectedVertices[idx],
                        threshold: configuration.settleSimilarityThreshold
                    ).matched
                }
            }
            return Self.matchesVertex(
                fingerprint: initialFp,
                expectedHash: firstEdge.toHash,
                expectedVertex: expectedVertices[0],
                threshold: configuration.settleSimilarityThreshold
            ).matched
        }()

        if !matchesFrom && !matchesAnyTarget {
            throw PathDeviationError.unexpectedStartState(
                expectedHash: firstEdge.fromHash,
                actualHash: initialFp.layoutHash,
                actualPackage: initialFp.activePackage
            )
        }

        var reports: [MacroStepReport] = []
        reports.reserveCapacity(path.count)
        var recoveredSteps: [String] = []
        var lastSettledHash = initialFp.layoutHash
        let finalTargetHash = path.last?.toHash ?? firstEdge.toHash

        emit(.executionStarted(totalSteps: path.count))

        do {
            var stepIndex = 0
            while stepIndex < path.count {
                try Task.checkCancellation()
                if try await awaitSecureHandoffIfActive() {
                    recoveredSteps.append("secure_handoff")
                }

                let edge = path[stepIndex]
                let stepFromFp: ScreenSemanticFingerprint = if let idx = await domState.currentIndex {
                    hasher.fingerprint(for: idx)
                } else {
                    initialFp
                }

                // Pre-step settlement / forward-skip scan (#1):
                // Scan furthest suffix step down to current stepIndex so apps that restore scroll/state
                // straight into node 3 or 4 skip intermediate taps cleanly.
                if let liveIndex = await domState.currentIndex {
                    let liveFp = hasher.fingerprint(for: liveIndex)
                    let scanFloor = stepIndex
                    let scanCeiling = configuration.enableForwardSkipRecovery ? (path.count - 1) : stepIndex
                    if let matchedJumpIdx = Self.furthestMatchedStepIndex(
                        fingerprint: liveFp,
                        path: path,
                        expectedVertices: expectedVertices,
                        from: scanFloor,
                        through: scanCeiling,
                        threshold: configuration.settleSimilarityThreshold
                    ) {
                        if expectedVertices[matchedJumpIdx]?.isSeed == true {
                            _ = await graphEngine.hydrateSeedVertex(
                                seedHash: path[matchedJumpIdx].toHash,
                                liveFingerprint: liveFp
                            )
                            recoveredSteps.append("seed_hydrated:skip_\(matchedJumpIdx)")
                        }
                        lastSettledHash = liveFp.layoutHash
                        if matchedJumpIdx > stepIndex {
                            let detail = "Skipped steps \(stepIndex + 1)...\(matchedJumpIdx + 1) (already at screen \(matchedJumpIdx + 1)/\(path.count))"
                            recoveredSteps.append("forward_skip:\(stepIndex)->\(matchedJumpIdx)")
                            emit(.recoveryAction(kind: "forward_skip", detail: detail))
                        }
                        for skippedIdx in scanFloor...matchedJumpIdx {
                            let skippedEdge = path[skippedIdx]
                            let matchExact = (liveFp.layoutHash == skippedEdge.toHash)
                            let stepReport = MacroStepReport(
                                stepIndex: skippedIdx,
                                edgeId: skippedEdge.id,
                                actionSignature: skippedEdge.actionSignature,
                                targetHash: skippedEdge.toHash,
                                elapsedMs: 0,
                                matchedByExactHash: matchExact,
                                wasSkipped: true
                            )
                            reports.append(stepReport)
                            if skippedIdx == matchedJumpIdx {
                                emit(.stepSettled(stepIndex: skippedIdx, totalSteps: path.count, report: stepReport))
                            }
                        }
                        stepIndex = matchedJumpIdx + 1
                        continue
                    }
                }

                guard let rawAction = edge.action else {
                    throw PathDeviationError.missingActionPayload(stepIndex: stepIndex, edgeId: edge.id)
                }

                let resolved = await resolveLiveActionWithNode(rawAction)
                var resolvedAction = resolved.action
                var matchedNode = resolved.node
                var didSmartScroll = false

                // Smart Scroll-to-Selector: if tap selector is off-screen inside a scrollable container,
                // perform bounded search scrolls (down / reverse up at bottom) to reveal & lock onto the node.
                if configuration.enableSmartScrollToSelector && matchedNode == nil && rawAction.kind == .tap {
                    if let scrolled = try await smartScrollToSelector(
                        rawAction: rawAction,
                        serial: serial,
                        recoveredSteps: &recoveredSteps
                    ) {
                        resolvedAction = scrolled.action
                        matchedNode = scrolled.node
                        didSmartScroll = true
                    }
                }

                // Calibrate seed action descriptor/selectors from the matched live node BEFORE
                // recording pendingAction so live SpatialGraphEngine.process() and hydrateSeedTransition()
                // share the exact same actionSignature and never create duplicate edges.
                if edge.isSeed, let node = matchedNode {
                    let nextText = !node.text.isEmpty ? node.text : resolvedAction.selectorText
                    let nextDesc = (node.text.isEmpty && !node.contentDesc.isEmpty) ? node.contentDesc : resolvedAction.selectorContentDesc
                    let nextTarget = !node.text.isEmpty ? node.text : (!node.contentDesc.isEmpty ? node.contentDesc : resolvedAction.targetDescription)
                    let nextRid = !node.resourceId.isEmpty ? node.resourceId : resolvedAction.selectorResourceId
                    resolvedAction = AttributedUIAction(
                        kind: resolvedAction.kind,
                        targetDescription: nextTarget,
                        x: resolvedAction.x,
                        y: resolvedAction.y,
                        endX: resolvedAction.endX,
                        endY: resolvedAction.endY,
                        durationMs: resolvedAction.durationMs,
                        textInput: resolvedAction.textInput,
                        pressEnter: resolvedAction.pressEnter,
                        selectorResourceId: nextRid,
                        selectorText: nextText,
                        selectorContentDesc: nextDesc,
                        selectorAliases: resolvedAction.selectorAliases,
                        timestamp: Date()
                    )
                }

                // Hazardous / irreversible transaction HITL check (#2, Variant A):
                // Halt right before executing the dangerous step while keeping safe prefix steps completed.
                let liveLabel = matchedNode.map { !$0.text.isEmpty ? $0.text : $0.contentDesc }
                let liveAssessment = HazardousActionClassifier.assess(
                    action: resolvedAction,
                    actionSignature: resolvedAction.signature,
                    liveLabel: liveLabel,
                    liveResourceId: matchedNode?.resourceId
                )
                let edgeAssessment = HazardousActionClassifier.assess(
                    action: edge.action,
                    actionSignature: edge.actionSignature
                )
                let isHazardous = edge.isHazardous || edgeAssessment.isHazardous || liveAssessment.isHazardous
                if isHazardous && !configuration.allowHazardousActions {
                    let category = liveAssessment.category ?? edgeAssessment.category ?? .destructive
                    let reason = !liveAssessment.reason.isEmpty
                        ? liveAssessment.reason
                        : (!edgeAssessment.reason.isEmpty ? edgeAssessment.reason : (edge.hazardReason ?? "Irreversible action requires human approval"))
                    let currentLiveHash: UInt64 = if let idx = await domState.currentIndex {
                        hasher.fingerprint(for: idx).layoutHash
                    } else {
                        lastSettledHash
                    }
                    emit(.awaitingConfirmation(
                        stepIndex: stepIndex,
                        totalSteps: path.count,
                        action: resolvedAction,
                        reason: reason
                    ))
                    throw PathDeviationError.requiresConfirmation(
                        HazardousConfirmationRequest(
                            stepIndex: stepIndex,
                            totalSteps: path.count,
                            actionSignature: resolvedAction.signature,
                            targetDescription: resolvedAction.targetDescription,
                            hazardCategory: category,
                            hazardReason: reason,
                            currentHash: currentLiveHash,
                            targetHash: finalTargetHash,
                            stepsCompleted: reports.count,
                            tapX: resolvedAction.x,
                            tapY: resolvedAction.y
                        )
                    )
                }

                // Reflexive push-notification banner swipe-up (#3) if systemui heads-up overlaps tap target
                if configuration.enableOverlaySwipeDismiss && resolvedAction.kind == .tap {
                    let updated = try await dismissOccludingSystemBannerIfPresent(
                        action: resolvedAction,
                        rawAction: rawAction,
                        serial: serial,
                        recoveredSteps: &recoveredSteps
                    )
                    resolvedAction = updated.action
                    if let updatedNode = updated.node {
                        matchedNode = updatedNode
                    }
                }

                // Suffix targets for in-flight forward-skip settle (#1)
                let targetMaxIdx = configuration.enableForwardSkipRecovery ? (path.count - 1) : stepIndex
                let suffixTargets: [SettleTarget] = (stepIndex...targetMaxIdx).reversed().map { idx in
                    SettleTarget(
                        stepIndex: idx,
                        targetHash: path[idx].toHash,
                        expectedVertex: expectedVertices[idx]
                    )
                }

                // CRITICAL RACE-FREE ORDER:
                // 1. Subscribe to ShadowDOMState.updates & secureScreenUpdates BEFORE injecting input.
                let updateStream = await domState.updates
                let secureStream = await domState.secureScreenUpdates
                await graphEngine.recordPendingAction(resolvedAction)

                // Notify visual HUD overlays immediately right before input injection.
                emit(.willExecuteAction(stepIndex: stepIndex, totalSteps: path.count, action: resolvedAction))

                let stepStart = ContinuousClock.now
                let isIntermediateScroll = (resolvedAction.kind == .swipe) && (stepIndex + 1 < path.count)
                let settleOutcome: SettleOutcome
                do {
                    settleOutcome = try await executeAndWaitForSettle(
                        stepIndex: stepIndex,
                        fromHash: lastSettledHash,
                        isIntermediateScroll: isIntermediateScroll,
                        action: resolvedAction,
                        serial: serial,
                        targets: suffixTargets,
                        updateStream: updateStream,
                        secureStream: secureStream
                    )
                } catch let deviation as PathDeviationError {
                    if case .stepTimeout = deviation, configuration.recordEdgeFailuresOnTimeout {
                        await graphEngine.recordEdgeFailure(edgeId: edge.id)
                    }
                    throw deviation
                }

                let matchedIdx: Int
                let settledHash: UInt64
                let settledExact: Bool

                switch settleOutcome {
                case .settled(let targetStepIndex, let hash, let exact):
                    matchedIdx = targetStepIndex
                    settledHash = hash
                    settledExact = exact

                case .interruptedBySecureScreen:
                    if try await awaitSecureHandoffIfActive() {
                        recoveredSteps.append("secure_handoff")
                    }
                    do {
                        let postHandoffResult = try await settleAfterSecureHandoff(
                            stepIndex: stepIndex,
                            suffixTargets: suffixTargets,
                            lastKnownHash: lastSettledHash
                        )
                        matchedIdx = postHandoffResult.matchedStepIndex
                        settledHash = postHandoffResult.hash
                        settledExact = postHandoffResult.matchedByExactHash
                    } catch let deviation as PathDeviationError {
                        if case .stepTimeout = deviation, configuration.recordEdgeFailuresOnTimeout {
                            await graphEngine.recordEdgeFailure(edgeId: edge.id)
                        }
                        throw deviation
                    }
                }

                await graphEngine.recordEdgeSuccess(edgeId: edge.id)

                let elapsedMs = Self.elapsedMilliseconds(since: stepStart)
                lastSettledHash = settledHash

                // Seed-to-Real Hydration: promote traversed seed vertices & coordinate-free seed edges
                // into real device-calibrated vertices and executable edges with exact coordinates/selectors.
                let fromWasSeed = graphVertices[edge.fromHash]?.isSeed == true
                let toWasSeed = expectedVertices[matchedIdx]?.isSeed == true
                if edge.isSeed || fromWasSeed || toWasSeed {
                    if let liveSettledIdx = await domState.currentIndex {
                        let settledFp = hasher.fingerprint(for: liveSettledIdx)
                        let hydratedAction: AttributedUIAction
                        if let node = matchedNode {
                            let nextText = !node.text.isEmpty ? node.text : resolvedAction.selectorText
                            let nextDesc = (node.text.isEmpty && !node.contentDesc.isEmpty) ? node.contentDesc : resolvedAction.selectorContentDesc
                            let nextTarget = !node.text.isEmpty ? node.text : (!node.contentDesc.isEmpty ? node.contentDesc : resolvedAction.targetDescription)
                            let nextRid = !node.resourceId.isEmpty ? node.resourceId : resolvedAction.selectorResourceId
                            // If the node was revealed only after scrolling away from `stepFromFp`,
                            // keep the hydrated edge coordinate-free so subsequent runs from the
                            // un-scrolled top screen always re-scroll instead of clicking stale (x, y).
                            let hydratedX: Int? = didSmartScroll ? nil : node.centerX
                            let hydratedY: Int? = didSmartScroll ? nil : node.centerY
                            hydratedAction = AttributedUIAction(
                                kind: resolvedAction.kind,
                                targetDescription: nextTarget,
                                x: hydratedX,
                                y: hydratedY,
                                endX: resolvedAction.endX,
                                endY: resolvedAction.endY,
                                durationMs: resolvedAction.durationMs,
                                textInput: resolvedAction.textInput,
                                pressEnter: resolvedAction.pressEnter,
                                selectorResourceId: nextRid,
                                selectorText: nextText,
                                selectorContentDesc: nextDesc,
                                selectorAliases: resolvedAction.selectorAliases,
                                timestamp: Date()
                            )
                        } else {
                            hydratedAction = resolvedAction
                        }
                        _ = await graphEngine.hydrateSeedTransition(
                            fromSeedOrRealHash: edge.fromHash,
                            toSeedOrRealHash: path[matchedIdx].toHash,
                            realFromFingerprint: stepFromFp,
                            realToFingerprint: settledFp,
                            resolvedAction: hydratedAction,
                            transitionMs: Double(elapsedMs)
                        )
                        recoveredSteps.append("seed_hydrated:step_\(stepIndex)")
                    }
                }

                let primaryReport = MacroStepReport(
                    stepIndex: stepIndex,
                    edgeId: edge.id,
                    actionSignature: resolvedAction.signature,
                    targetHash: edge.toHash,
                    elapsedMs: elapsedMs,
                    matchedByExactHash: (matchedIdx == stepIndex) ? settledExact : false,
                    wasSkipped: false
                )
                reports.append(primaryReport)
                emit(.stepSettled(stepIndex: stepIndex, totalSteps: path.count, report: primaryReport))

                if matchedIdx > stepIndex {
                    let detail = "Forward-skipped \(matchedIdx - stepIndex) intermediate step(s) after landing on step \(matchedIdx + 1)/\(path.count)"
                    recoveredSteps.append("forward_skip:\(stepIndex)->\(matchedIdx)")
                    emit(.recoveryAction(kind: "forward_skip", detail: detail))

                    for skippedIdx in (stepIndex + 1)...matchedIdx {
                        let skippedEdge = path[skippedIdx]
                        let skipReport = MacroStepReport(
                            stepIndex: skippedIdx,
                            edgeId: skippedEdge.id,
                            actionSignature: skippedEdge.actionSignature,
                            targetHash: skippedEdge.toHash,
                            elapsedMs: 0,
                            matchedByExactHash: (skippedIdx == matchedIdx) ? settledExact : false,
                            wasSkipped: true
                        )
                        reports.append(skipReport)
                        if skippedIdx == matchedIdx {
                            emit(.stepSettled(stepIndex: skippedIdx, totalSteps: path.count, report: skipReport))
                        }
                    }
                }

                stepIndex = matchedIdx + 1

                if stepIndex < path.count && configuration.postSettleQuiescenceMs > 0 {
                    // When native zero-fling daemon injection is active, ease-out + terminal hold
                    // stops RecyclerView at SCROLL_STATE_IDLE immediately (~0px drift), so tight
                    // quiescence (45-70ms) suffices. Keep conservative 280/480ms waits on ADB fallback.
                    let nextIsSwipe = path[stepIndex].action?.kind == .swipe
                    let quiescenceMs: Int
                    if resolvedAction.kind == .swipe {
                        let zeroFling = await executor.supportsZeroFlingSwipes(serial: serial)
                        let minWait = zeroFling ? (nextIsSwipe ? 60 : 85) : (nextIsSwipe ? 280 : 480)
                        quiescenceMs = max(configuration.postSettleQuiescenceMs, minWait)
                    } else {
                        quiescenceMs = configuration.postSettleQuiescenceMs
                    }
                    try await Task.sleep(for: .milliseconds(quiescenceMs))
                }
            }

            let totalElapsedMs = Self.elapsedMilliseconds(since: totalStart)
            let report = MacroExecutionReport(
                startHash: initialFp.layoutHash,
                finalHash: lastSettledHash,
                steps: reports,
                totalElapsedMs: totalElapsedMs,
                recoveredSteps: recoveredSteps
            )
            emit(.completed(report: report))
            return report
        } catch let error as PathDeviationError {
            if case .requiresConfirmation = error {
                // Keep Yellow HITL confirmation reticle & toast active rather than emitting red/orange .failed
                throw error
            }
            emit(.failed(message: error.localizedDescription))
            throw error
        } catch {
            emit(.failed(message: error.localizedDescription))
            throw error
        }
    }

    // MARK: - Private Helpers

    private struct SettleTarget: Sendable {
        let stepIndex: Int
        let targetHash: UInt64
        let expectedVertex: ScreenStateVertex?
    }

    private enum SettleOutcome: Sendable {
        case settled(matchedStepIndex: Int, hash: UInt64, matchedByExactHash: Bool)
        case interruptedBySecureScreen
    }

    private enum StepRaceEvent: Sendable {
        case actionDispatched
        case settled(matchedStepIndex: Int, hash: UInt64, matchedByExactHash: Bool)
        case secureScreenActivated(reason: String, package: String)
        case timedOut
    }

    @discardableResult
    private func awaitSecureHandoffIfActive() async throws -> Bool {
        guard await domState.isSecureScreenActive else { return false }
        let reason = await domState.secureScreenReason ?? "biometric_or_pin"
        let pkg = await domState.secureScreenPackage
        emit(.awaitingBiometrics(reason: reason, activePackage: pkg))

        let timeout = configuration.secureHandoffTimeoutSeconds
        let cleared = await domState.waitUntilSecureScreenCleared(timeoutSeconds: timeout)
        try Task.checkCancellation()
        guard cleared else {
            throw PathDeviationError.secureScreenTimeout(
                reason: reason,
                activePackage: pkg,
                timeoutSeconds: Int(timeout.rounded())
            )
        }
        emit(.biometricsCleared)
        return true
    }

    private func settleAfterSecureHandoff(
        stepIndex: Int,
        suffixTargets: [SettleTarget],
        lastKnownHash: UInt64
    ) async throws -> (matchedStepIndex: Int, hash: UInt64, matchedByExactHash: Bool) {
        if let liveIndex = await domState.currentIndex,
           !liveIndex.orderedNodes.isEmpty {
            let liveFp = hasher.fingerprint(for: liveIndex)
            for target in suffixTargets {
                let match = Self.matchesVertex(
                    fingerprint: liveFp,
                    expectedHash: target.targetHash,
                    expectedVertex: target.expectedVertex,
                    threshold: configuration.settleSimilarityThreshold
                )
                if match.matched {
                    return (target.stepIndex, liveFp.layoutHash, match.exact)
                }
            }
        }

        // Wait briefly for post-unlock screen transition frame
        let updateStream = await domState.updates
        let hasher = self.hasher
        let threshold = configuration.settleSimilarityThreshold
        let timeoutMs = configuration.stepTimeoutMs

        return try await withThrowingTaskGroup(of: SettleOutcome?.self) { group in
            group.addTask {
                for await update in updateStream {
                    try Task.checkCancellation()
                    guard !update.isSecureScreenActive else { continue }
                    let fp = hasher.fingerprint(for: update.index)
                    for target in suffixTargets {
                        let match = Self.matchesVertex(
                            fingerprint: fp,
                            expectedHash: target.targetHash,
                            expectedVertex: target.expectedVertex,
                            threshold: threshold
                        )
                        if match.matched {
                            return .settled(
                                matchedStepIndex: target.stepIndex,
                                hash: fp.layoutHash,
                                matchedByExactHash: match.exact
                            )
                        }
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }

            if let first = try await group.next(), case .settled(let idx, let hash, let exact) = first {
                group.cancelAll()
                return (idx, hash, exact)
            }
            group.cancelAll()
            let live = await domState.currentIndex
            let liveHash = live.map { hasher.fingerprint(for: $0).layoutHash } ?? lastKnownHash
            let livePkg = live?.activePackage ?? "unknown"
            let primaryTarget = suffixTargets.last?.targetHash ?? 0
            throw PathDeviationError.stepTimeout(
                stepIndex: stepIndex,
                expectedTargetHash: primaryTarget,
                lastObservedHash: liveHash,
                lastObservedPackage: livePkg,
                timeoutMs: timeoutMs
            )
        }
    }

    private func executeAndWaitForSettle(
        stepIndex: Int,
        fromHash: UInt64,
        isIntermediateScroll: Bool,
        action: AttributedUIAction,
        serial: String,
        targets: [SettleTarget],
        updateStream: AsyncStream<ShadowDOMUpdate>,
        secureStream: AsyncStream<WireSecureScreenPayload>
    ) async throws -> SettleOutcome {
        let executor = self.executor
        let hasher = self.hasher
        let threshold = configuration.settleSimilarityThreshold
        let timeoutMs = configuration.stepTimeoutMs
        let primaryTargetHash = targets.last?.targetHash ?? 0

        return try await withThrowingTaskGroup(of: StepRaceEvent.self) { group in
            // Task A: Dispatch UI action via host MacroActionExecutor
            group.addTask {
                do {
                    try await executor.execute(action: action, serial: serial)
                    return .actionDispatched
                } catch is CancellationError {
                    throw CancellationError()
                } catch let deviation as PathDeviationError {
                    if case .actionDispatchFailed(let idx, let sig, let msg) = deviation, idx < 0 {
                        throw PathDeviationError.actionDispatchFailed(
                            stepIndex: stepIndex,
                            actionSignature: sig,
                            underlyingMessage: msg
                        )
                    }
                    throw deviation
                } catch {
                    throw PathDeviationError.actionDispatchFailed(
                        stepIndex: stepIndex,
                        actionSignature: action.signature,
                        underlyingMessage: error.localizedDescription
                    )
                }
            }

            // Task B: Watch pre-subscribed ShadowDOMState update stream (checks suffixTargets furthest-first for #1 forward-skip)
            group.addTask {
                for await update in updateStream {
                    try Task.checkCancellation()
                    if update.isSecureScreenActive {
                        continue
                    }
                    let fp = hasher.fingerprint(for: update.index)
                    for target in targets {
                        // Intermediate scroll steps can shift by ±1 list row (~20px), dropping
                        // Jaccard slightly under 0.80 (e.g. 0.785) while the next tap live-retargets.
                        let effectiveThreshold: Double = (isIntermediateScroll
                            && target.stepIndex == stepIndex
                            && threshold < 1.0
                            && fp.layoutHash != fromHash)
                            ? min(threshold, 0.65)
                            : threshold
                        let match = Self.matchesVertex(
                            fingerprint: fp,
                            expectedHash: target.targetHash,
                            expectedVertex: target.expectedVertex,
                            threshold: effectiveThreshold
                        )
                        if match.matched {
                            return .settled(
                                matchedStepIndex: target.stepIndex,
                                hash: fp.layoutHash,
                                matchedByExactHash: match.exact
                            )
                        }
                    }
                }
                return .timedOut
            }

            // Task C: Hard deadline timeout guard (default 2000ms)
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                return .timedOut
            }

            // Task D: Watch FLAG_SECURE / biometric activations (#7) to pause without timing out
            group.addTask {
                for await payload in secureStream {
                    try Task.checkCancellation()
                    if payload.active {
                        return .secureScreenActivated(reason: payload.reason, package: payload.activePackage)
                    }
                }
                return .timedOut
            }

            var actionDispatched = false
            var settledOutcome: (matchedStepIndex: Int, hash: UInt64, matchedByExactHash: Bool)?

            while let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .actionDispatched:
                    actionDispatched = true
                    if let outcome = settledOutcome {
                        group.cancelAll()
                        return .settled(
                            matchedStepIndex: outcome.matchedStepIndex,
                            hash: outcome.hash,
                            matchedByExactHash: outcome.matchedByExactHash
                        )
                    }
                case .settled(let matchedIdx, let hash, let matchedByExactHash):
                    settledOutcome = (matchedIdx, hash, matchedByExactHash)
                    if actionDispatched {
                        group.cancelAll()
                        return .settled(
                            matchedStepIndex: matchedIdx,
                            hash: hash,
                            matchedByExactHash: matchedByExactHash
                        )
                    }
                case .secureScreenActivated:
                    if let outcome = settledOutcome {
                        group.cancelAll()
                        return .settled(
                            matchedStepIndex: outcome.matchedStepIndex,
                            hash: outcome.hash,
                            matchedByExactHash: outcome.matchedByExactHash
                        )
                    }
                    group.cancelAll()
                    return .interruptedBySecureScreen
                case .timedOut:
                    if let outcome = settledOutcome {
                        group.cancelAll()
                        return .settled(
                            matchedStepIndex: outcome.matchedStepIndex,
                            hash: outcome.hash,
                            matchedByExactHash: outcome.matchedByExactHash
                        )
                    }
                    if await domState.isSecureScreenActive {
                        group.cancelAll()
                        return .interruptedBySecureScreen
                    }
                    group.cancelAll()
                    let live = await domState.currentIndex
                    let liveHash = live.map { hasher.fingerprint(for: $0).layoutHash }
                    let livePkg = live?.activePackage ?? "unknown"
                    throw PathDeviationError.stepTimeout(
                        stepIndex: stepIndex,
                        expectedTargetHash: primaryTargetHash,
                        lastObservedHash: liveHash,
                        lastObservedPackage: livePkg,
                        timeoutMs: timeoutMs
                    )
                }
            }

            throw PathDeviationError.shadowStreamUnavailable
        }
    }

    /// Detects a visible `com.android.systemui` heads-up notification banner occluding `(tapX, tapY)`
    /// and dispatches a reflexive upward swipe without poisoning the Spatial Graph (#3).
    private func dismissOccludingSystemBannerIfPresent(
        action: AttributedUIAction,
        rawAction: AttributedUIAction,
        serial: String,
        recoveredSteps: inout [String]
    ) async throws -> (action: AttributedUIAction, node: ShadowUINode?) {
        var currentAction = action
        var currentNode: ShadowUINode?

        for attempt in 0..<2 {
            guard let tapX = currentAction.x, let tapY = currentAction.y,
                  let liveIndex = await domState.currentIndex,
                  let bannerRect = Self.occludingSystemBannerRect(in: liveIndex, tapX: tapX, tapY: tapY) else {
                break
            }

            let swipeX = max(1, (bannerRect.minX + bannerRect.maxX) / 2)
            let startY = max(20, bannerRect.maxY - 20)
            let endY = max(10, bannerRect.minY - 120)
            let swipeAction = AttributedUIAction(
                kind: .swipe,
                targetDescription: "Dismiss occluding notification",
                x: swipeX,
                y: startY,
                endX: swipeX,
                endY: endY,
                durationMs: 160
            )

            recoveredSteps.append("dismiss_notification_overlay_\(attempt + 1)")
            emit(.recoveryAction(kind: "dismiss_notification_overlay", detail: "Swiped up occluding system notification"))

            // Subscribe BEFORE swipe and explicitly do NOT call graphEngine.recordPendingAction(...)
            let updateStream = await domState.updates
            try await executor.execute(action: swipeAction, serial: serial)

            await waitForBannerClearance(
                tapX: tapX,
                tapY: tapY,
                updateStream: updateStream,
                timeoutMs: 450
            )

            let refreshed = await resolveLiveActionWithNode(rawAction)
            currentAction = refreshed.action
            currentNode = refreshed.node
        }

        return (currentAction, currentNode)
    }

    private func waitForBannerClearance(
        tapX: Int,
        tapY: Int,
        updateStream: AsyncStream<ShadowDOMUpdate>,
        timeoutMs: Int
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await update in updateStream {
                    if Self.occludingSystemBannerRect(in: update.index, tapX: tapX, tapY: tapY) == nil {
                        return
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    internal static func occludingSystemBannerRect(
        in index: ShadowTreeIndex,
        tapX: Int,
        tapY: Int
    ) -> ShadowTreeIndex.BoundsRect? {
        var unionRect: ShadowTreeIndex.BoundsRect?
        let hasAppNodes = index.orderedNodes.contains { node in
            node.visible && !node.packageName.isEmpty && node.packageName != "com.android.systemui"
        }
        guard hasAppNodes else { return nil }

        for node in index.orderedNodes where node.visible {
            let isSystemUI = node.packageName == "com.android.systemui" || node.resourceId.hasPrefix("com.android.systemui:")
            guard isSystemUI else { continue }
            guard let rect = ShadowTreeIndex.parseBoundsRect(node.bounds) else { continue }
            guard rect.contains(x: tapX, y: tapY) else { continue }

            let width = rect.maxX - rect.minX
            let height = rect.maxY - rect.minY
            // Ignore thin status bar at very top and full-screen lockscreen/shade overlays
            let isStatusBar = rect.minY <= 12 && rect.maxY <= 120
            let isFullScreenOverlay = height > 750
            guard !isStatusBar, !isFullScreenOverlay else { continue }

            let ridLower = node.resourceId.lowercased()
            let hasBannerHint = ridLower.contains("notification") || ridLower.contains("heads_up") || ridLower.contains("alert")
            guard (height >= 70 && width >= 250 && rect.minY < 650) || hasBannerHint else { continue }

            if let existing = unionRect {
                unionRect = ShadowTreeIndex.BoundsRect(
                    minX: min(existing.minX, rect.minX),
                    minY: min(existing.minY, rect.minY),
                    maxX: max(existing.maxX, rect.maxX),
                    maxY: max(existing.maxY, rect.maxY)
                )
            } else {
                unionRect = rect
            }
        }
        return unionRect
    }

    /// Returns `true` if `node` is a vertically scrollable container suitable for list scrolling
    /// (excluding ignored system overlays, horizontal pagers, and launcher home-screen workspaces).
    private static func isVerticalScrollContainer(
        _ node: ShadowUINode,
        skipIgnored: Bool,
        ignoredPackages: Set<String>
    ) -> Bool {
        guard node.visible, node.scrollable else { return false }
        if skipIgnored {
            if !node.packageName.isEmpty && ignoredPackages.contains(node.packageName) {
                return false
            }
            if !node.resourceId.isEmpty && ignoredPackages.contains(where: { node.resourceId.hasPrefix("\($0):") }) {
                return false
            }
        }
        // Skip horizontal-only pagers and launcher home-screen workspaces where a vertical
        // downward swipe pulls down the Android Notification Shade instead of scrolling a list.
        let clsLower = node.className.lowercased()
        if clsLower.contains("horizontalscrollview") || clsLower.contains("viewpager") {
            return false
        }
        let ridLower = node.resourceId.lowercased()
        if ridLower.hasSuffix(":id/workspace")
            || ridLower.hasSuffix("/workspace")
            || ridLower.hasSuffix(":id/hotseat")
            || ridLower.hasSuffix("/hotseat")
            || ridLower.hasSuffix(":id/smartspace_card_pager")
            || ridLower.hasSuffix("/smartspace_card_pager") {
            return false
        }
        return true
    }

    /// Finds the largest visible non-system `scrollable` container bounds on screen.
    internal static func largestScrollableRect(
        in index: ShadowTreeIndex,
        ignoredPackages: Set<String>
    ) -> ShadowTreeIndex.BoundsRect? {
        let skipIgnored = !ignoredPackages.contains(index.activePackage)
        var best: ShadowTreeIndex.BoundsRect?

        for node in index.orderedNodes where isVerticalScrollContainer(node, skipIgnored: skipIgnored, ignoredPackages: ignoredPackages) {
            guard let rect = ShadowTreeIndex.parseBoundsRect(node.bounds) else { continue }
            let width = rect.maxX - rect.minX
            let height = rect.maxY - rect.minY
            guard width >= 120, height >= 120 else { continue }
            if let currentBest = best {
                if rect.area > currentBest.area {
                    best = rect
                }
            } else {
                best = rect
            }
        }
        return best
    }

    /// Returns `true` if `node`'s tap center `(centerX, centerY)` is clipped outside (or within
    /// the razor edge inset of) a vertically scrollable ancestor container — e.g. a `RecyclerView`
    /// row peeking behind Android's bottom gesture navigation bar (`centerY > recycler.maxY`)
    /// that Accessibility still reports `visible: true`.
    internal static func isNodeClippedByScrollableAncestor(
        in index: ShadowTreeIndex,
        node: ShadowUINode,
        ignoredPackages: Set<String>
    ) -> Bool {
        let skipIgnored = !ignoredPackages.contains(index.activePackage)
        var cursor = node.parentId
        var hops = 0
        var visited: Set<Int64> = [node.nodeId]

        while let pid = cursor, hops < 16 {
            guard visited.insert(pid).inserted,
                  let parent = index.nodesById[pid] else {
                break
            }
            if isVerticalScrollContainer(parent, skipIgnored: skipIgnored, ignoredPackages: ignoredPackages),
               let rect = ShadowTreeIndex.parseBoundsRect(parent.bounds) {
                let width = rect.maxX - rect.minX
                let height = rect.maxY - rect.minY
                if width >= 120, height >= 120 {
                    let margin = height >= 200 ? min(16, max(8, height / 100)) : 0
                    if node.centerY > rect.maxY - margin || node.centerY < rect.minY + margin {
                        return true
                    }
                }
            }
            cursor = parent.parentId
            hops += 1
        }
        return false
    }

    internal struct ScrollItemSignature: Equatable, Sendable {
        let label: String
        let centerY: Int
    }

    /// Extracts an ordered signature of visible labeled items inside `container` to detect scroll movement vs boundaries.
    internal static func scrollViewportSignature(
        in index: ShadowTreeIndex,
        container: ShadowTreeIndex.BoundsRect,
        ignoredPackages: Set<String>
    ) -> [ScrollItemSignature] {
        let skipIgnored = !ignoredPackages.contains(index.activePackage)
        var items: [ScrollItemSignature] = []
        for node in index.orderedNodes where node.visible {
            if skipIgnored {
                if !node.packageName.isEmpty && ignoredPackages.contains(node.packageName) {
                    continue
                }
                if !node.resourceId.isEmpty && ignoredPackages.contains(where: { node.resourceId.hasPrefix("\($0):") }) {
                    continue
                }
            }
            guard container.contains(x: node.centerX, y: node.centerY) else { continue }
            let label = !node.text.isEmpty ? node.text : node.contentDesc
            guard !label.isEmpty else { continue }
            items.append(ScrollItemSignature(label: label, centerY: node.centerY))
        }
        return items
    }

    private enum SmartScrollStepOutcome: Sendable {
        case found(action: AttributedUIAction, node: ShadowUINode)
        case moved
        case boundaryOrUnavailable
    }

    /// Performs controlled search scrolls (up to 2 downward; if not found, reverses upward to cover
    /// items positioned above a mid-scroll or bottom-positioned viewport) when a tap selector is absent
    /// from the currently visible viewport of a scrollable container.
    private func smartScrollToSelector(
        rawAction: AttributedUIAction,
        serial: String,
        recoveredSteps: inout [String]
    ) async throws -> (action: AttributedUIAction, node: ShadowUINode)? {
        let hasText = rawAction.selectorText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasRid = rawAction.selectorResourceId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasDesc = rawAction.selectorContentDesc?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasAliases = rawAction.selectorAliases.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasText || hasRid || hasDesc || hasAliases else { return nil }

        // Coordinate-free semantic taps get a wider scroll budget (4) so deep settings
        // items like "System" or "About phone" are always discovered cleanly.
        let downBudget = (rawAction.x == nil && rawAction.y == nil) ? 4 : 2

        // Phase 1: Scroll downward (stopping early on bottom boundary).
        var downMoves = 0
        for attempt in 1...downBudget {
            try Task.checkCancellation()
            switch try await performSmartScrollStep(
                rawAction: rawAction,
                serial: serial,
                scrollingDown: true,
                attempt: attempt,
                budget: downBudget
            ) {
            case .found(let updatedAction, let foundNode):
                recoveredSteps.append("smart_scroll_to_selector:down:\(attempt)")
                return (updatedAction, foundNode)
            case .moved:
                downMoves += 1
            case .boundaryOrUnavailable:
                break
            }
            if downMoves < attempt {
                break
            }
        }

        // Phase 2: Reverse upward to recover targets above a mid-scroll or bottom viewport.
        let upBudget = min(3, max(2, downMoves + 1))
        for attempt in 1...upBudget {
            try Task.checkCancellation()
            switch try await performSmartScrollStep(
                rawAction: rawAction,
                serial: serial,
                scrollingDown: false,
                attempt: attempt,
                budget: upBudget
            ) {
            case .found(let updatedAction, let foundNode):
                recoveredSteps.append("smart_scroll_to_selector:up:\(attempt)")
                return (updatedAction, foundNode)
            case .moved:
                continue
            case .boundaryOrUnavailable:
                return nil
            }
        }

        return nil
    }

    private func performSmartScrollStep(
        rawAction: AttributedUIAction,
        serial: String,
        scrollingDown: Bool,
        attempt: Int,
        budget: Int
    ) async throws -> SmartScrollStepOutcome {
        guard let liveIndex = await domState.currentIndex,
              let scrollRect = Self.largestScrollableRect(in: liveIndex, ignoredPackages: hasher.ignoredPackages) else {
            return .boundaryOrUnavailable
        }

        let beforeHash = hasher.fingerprint(for: liveIndex).layoutHash
        let beforeSig = Self.scrollViewportSignature(
            in: liveIndex,
            container: scrollRect,
            ignoredPackages: hasher.ignoredPackages
        )

        let zeroFling = await executor.supportsZeroFlingSwipes(serial: serial)
        let cx = max(1, (scrollRect.minX + scrollRect.maxX) / 2)
        let spanY = scrollRect.maxY - scrollRect.minY
        let highPct = zeroFling ? 80 : 72
        let lowPct = zeroFling ? 18 : 28
        let swipeDurMs = zeroFling ? 145 : 500
        let yHigh = scrollRect.minY + (spanY * highPct) / 100
        let yLow = scrollRect.minY + (spanY * lowPct) / 100
        let startY = scrollingDown ? yHigh : yLow
        let endY = scrollingDown ? yLow : yHigh
        let dirLabel = scrollingDown ? "down" : "up"

        let swipeAction = AttributedUIAction(
            kind: .swipe,
            targetDescription: "Smart scroll \(dirLabel) for '\(rawAction.targetDescription)'",
            x: cx,
            y: startY,
            endX: cx,
            endY: endY,
            durationMs: swipeDurMs
        )

        emit(.recoveryAction(
            kind: "smart_scroll_to_selector",
            detail: "Scrolling \(dirLabel) (\(attempt)/\(budget)) to reveal '\(rawAction.targetDescription)'"
        ))

        // Subscribe BEFORE swipe and explicitly do NOT call graphEngine.recordPendingAction(...)
        let updateStream = await domState.updates
        try await executor.execute(action: swipeAction, serial: serial)

        let waitMs = max(150, min(800, configuration.stepTimeoutMs))
        let hasherRef = self.hasher
        let ignored = hasher.ignoredPackages
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await upd in updateStream {
                    if Task.isCancelled { return }
                    if upd.isSecureScreenActive { continue }
                    let nextHash = hasherRef.fingerprint(for: upd.index).layoutHash
                    let nextSig = Self.scrollViewportSignature(
                        in: upd.index,
                        container: scrollRect,
                        ignoredPackages: ignored
                    )
                    if nextHash != beforeHash || nextSig != beforeSig {
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

        if configuration.postSettleQuiescenceMs > 0 {
            if zeroFling {
                let quietMs = max(configuration.postSettleQuiescenceMs, 115)
                let maxDrainMs = max(quietMs, 380)
                let drainStart = Date()
                var lastSeq = await domState.currentIndex?.seq
                var lastChange = drainStart
                while true {
                    try Task.checkCancellation()
                    let now = Date()
                    let sinceStartMs = Int(now.timeIntervalSince(drainStart) * 1000.0)
                    let sinceChangeMs = Int(now.timeIntervalSince(lastChange) * 1000.0)
                    if sinceChangeMs >= quietMs || sinceStartMs >= maxDrainMs {
                        break
                    }
                    let remMs = min(quietMs - sinceChangeMs, maxDrainMs - sinceStartMs)
                    try await Task.sleep(for: .milliseconds(max(10, min(20, remMs))))
                    let currentSeq = await domState.currentIndex?.seq
                    if currentSeq != lastSeq {
                        lastSeq = currentSeq
                        lastChange = Date()
                    }
                }
            } else {
                let qMs = max(configuration.postSettleQuiescenceMs, 400)
                try await Task.sleep(for: .milliseconds(qMs))
            }
        }

        let refreshed = await resolveLiveActionWithNode(rawAction)
        if let foundNode = refreshed.node {
            return .found(action: refreshed.action, node: foundNode)
        }

        if let afterIndex = await domState.currentIndex {
            let afterHash = hasher.fingerprint(for: afterIndex).layoutHash
            let afterSig = Self.scrollViewportSignature(
                in: afterIndex,
                container: scrollRect,
                ignoredPackages: hasher.ignoredPackages
            )
            if afterHash == beforeHash && afterSig == beforeSig {
                return .boundaryOrUnavailable
            }
            return .moved
        }

        return .boundaryOrUnavailable
    }

    private func resolveLiveActionWithNode(_ action: AttributedUIAction) async -> (action: AttributedUIAction, node: ShadowUINode?) {
        guard action.kind == .tap else { return (action, nil) }

        let rid = action.selectorResourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = action.selectorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = action.selectorContentDesc?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasRid = rid?.isEmpty == false
        let hasText = text?.isEmpty == false
        let hasDesc = desc?.isEmpty == false
        let hasAliases = action.selectorAliases.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard hasRid || hasText || hasDesc || hasAliases else {
            if let x = action.x, let y = action.y, let liveNode = (await domState.currentIndex)?.resolveNode(atX: x, y: y) {
                return (action, liveNode)
            }
            return (action, nil)
        }

        let liveIndex = await domState.currentIndex
        let visibleNodes = liveIndex?.orderedNodes.filter { node in
            guard let liveIndex else { return false }
            return node.visible
                && (node.centerX > 0 || node.centerY > 0)
                && !Self.isNodeClippedByScrollableAncestor(
                    in: liveIndex,
                    node: node,
                    ignoredPackages: hasher.ignoredPackages
                )
        } ?? []

        var matchedNode: ShadowUINode?

        if !visibleNodes.isEmpty {
            // 1. Prefer a visible node matching ALL recorded selectors simultaneously.
            //    This prevents generic RecyclerView IDs (e.g. "android:id/title") from matching the wrong row.
            if hasRid || hasText || hasDesc {
                let jointCandidates = visibleNodes.filter { node in
                    if let rid, !rid.isEmpty, !Self.node(node, matchesResourceId: rid) { return false }
                    if let text, !text.isEmpty, !node.text.localizedCaseInsensitiveContains(text) { return false }
                    if let desc, !desc.isEmpty, !node.contentDesc.localizedCaseInsensitiveContains(desc) { return false }
                    return true
                }
                if !jointCandidates.isEmpty {
                    matchedNode = Self.bestLiveCandidate(in: jointCandidates, expectedText: text, expectedDesc: desc)
                }
            }

            // 2. If joint match failed, try text / contentDesc (more specific than shared ViewHolder IDs)
            if matchedNode == nil, let text, !text.isEmpty {
                let textCandidates = visibleNodes.filter { $0.text.localizedCaseInsensitiveContains(text) }
                matchedNode = Self.bestLiveCandidate(in: textCandidates, expectedText: text, expectedDesc: desc)
            }
            if matchedNode == nil, let desc, !desc.isEmpty {
                let descCandidates = visibleNodes.filter { $0.contentDesc.localizedCaseInsensitiveContains(desc) }
                matchedNode = Self.bestLiveCandidate(in: descCandidates, expectedText: text, expectedDesc: desc)
            }

            // 3. Semantic selectorAliases fallback (cross-OEM / multilingual Seed Graph selectors)
            if matchedNode == nil && hasAliases {
                let normalizedAliases = action.selectorAliases
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }

                // Pass A: exact text / contentDesc match across all aliases
                for alias in normalizedAliases {
                    let exactCands = visibleNodes.filter {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == alias
                            || $0.contentDesc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == alias
                    }
                    if !exactCands.isEmpty {
                        matchedNode = Self.bestLiveCandidate(in: exactCands, expectedText: alias, expectedDesc: alias)
                        break
                    }
                }

                // Pass B: substring match for multi-character aliases
                if matchedNode == nil {
                    for alias in normalizedAliases where alias.count >= 3 {
                        let subCands = visibleNodes.filter {
                            $0.text.lowercased().contains(alias)
                                || $0.contentDesc.lowercased().contains(alias)
                        }
                        if !subCands.isEmpty {
                            matchedNode = Self.bestLiveCandidate(in: subCands, expectedText: alias, expectedDesc: alias)
                            break
                        }
                    }
                }
            }

            // 4. Only fall back to resourceId alone if it uniquely identifies a single visible node on screen
            if matchedNode == nil, let rid, !rid.isEmpty {
                let ridCandidates = visibleNodes.filter { Self.node($0, matchesResourceId: rid) }
                if ridCandidates.count == 1 {
                    matchedNode = ridCandidates[0]
                }
            }
        }

        guard let node = matchedNode, node.visible, (node.centerX > 0 || node.centerY > 0) else {
            return (action, nil)
        }

        let updatedAction = AttributedUIAction(
            kind: action.kind,
            targetDescription: action.targetDescription,
            x: node.centerX,
            y: node.centerY,
            endX: action.endX,
            endY: action.endY,
            durationMs: action.durationMs,
            textInput: action.textInput,
            pressEnter: action.pressEnter,
            selectorResourceId: action.selectorResourceId,
            selectorText: action.selectorText,
            selectorContentDesc: action.selectorContentDesc,
            selectorAliases: action.selectorAliases,
            timestamp: Date()
        )
        return (updatedAction, node)
    }

    private static func furthestMatchedStepIndex(
        fingerprint: ScreenSemanticFingerprint,
        path: [ScreenTransitionEdge],
        expectedVertices: [ScreenStateVertex?],
        from scanFloor: Int,
        through scanCeiling: Int,
        threshold: Double
    ) -> Int? {
        guard scanFloor <= scanCeiling, scanFloor >= 0, scanCeiling < path.count else { return nil }
        for k in stride(from: scanCeiling, through: scanFloor, by: -1) {
            let match = matchesVertex(
                fingerprint: fingerprint,
                expectedHash: path[k].toHash,
                expectedVertex: expectedVertices[k],
                threshold: threshold
            )
            if match.matched {
                return k
            }
        }
        return nil
    }

    private static func node(_ node: ShadowUINode, matchesResourceId rid: String) -> Bool {
        guard !node.resourceId.isEmpty else { return false }
        if node.resourceId == rid { return true }
        let nodeLower = node.resourceId.lowercased()
        let ridLower = rid.lowercased()
        return nodeLower == ridLower
            || nodeLower.hasSuffix("/" + ridLower)
            || nodeLower.hasSuffix(":" + ridLower)
    }

    private static func bestLiveCandidate(
        in candidates: [ShadowUINode],
        expectedText: String?,
        expectedDesc: String?
    ) -> ShadowUINode? {
        let lowerText = expectedText?.lowercased()
        let lowerDesc = expectedDesc?.lowercased()
        return candidates.max { lhs, rhs in
            candidateScore(lhs, lowerText: lowerText, lowerDesc: lowerDesc)
                < candidateScore(rhs, lowerText: lowerText, lowerDesc: lowerDesc)
        }
    }

    private static func candidateScore(_ node: ShadowUINode, lowerText: String?, lowerDesc: String?) -> Int {
        var score = 0
        if node.visible { score += 16 }
        if node.enabled { score += 8 }
        if node.clickable { score += 4 }
        if let lowerText, !lowerText.isEmpty {
            let nodeText = node.text.lowercased()
            if nodeText == lowerText { score += 100 }
            else if nodeText.hasPrefix(lowerText) { score += 50 }
            else if nodeText.contains(lowerText) { score += 20 }
        }
        if let lowerDesc, !lowerDesc.isEmpty {
            let nodeDesc = node.contentDesc.lowercased()
            if nodeDesc == lowerDesc { score += 100 }
            else if nodeDesc.hasPrefix(lowerDesc) { score += 50 }
            else if nodeDesc.contains(lowerDesc) { score += 20 }
        }
        return score
    }

    private static func matchesVertex(
        fingerprint: ScreenSemanticFingerprint,
        expectedHash: UInt64,
        expectedVertex: ScreenStateVertex?,
        threshold: Double
    ) -> (matched: Bool, exact: Bool) {
        if fingerprint.layoutHash == expectedHash {
            return (true, true)
        }
        guard let expected = expectedVertex,
              fingerprint.activePackage == expected.activePackage else {
            return (false, false)
        }
        if expected.isSeed {
            let score = SeedGraphCatalog.seedMatchScore(liveFingerprint: fingerprint, seedVertex: expected)
            return (score >= SeedGraphCatalog.seedMatchThreshold, false)
        }
        guard !expected.semanticTokens.isEmpty else {
            return (false, false)
        }
        let sim = ScreenLayoutHasher.jaccardSimilarity(fingerprint.tokens, expected.semanticTokens)
        return (sim >= threshold, false)
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let millis = (duration.components.seconds * 1_000) + (duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, Int(millis))
    }
}
