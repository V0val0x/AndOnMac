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
    /// within `configuration.stepTimeoutMs` (default 2000ms). Throws `PathDeviationError` on deviation or timeout.
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

        // Verify starting state matches path[0].fromHash (or is already on path[0].toHash)
        if initialFp.layoutHash != firstEdge.fromHash && initialFp.layoutHash != firstEdge.toHash {
            let matchesBySimilarity = await matchesVertex(
                fingerprint: initialFp,
                expectedHash: firstEdge.fromHash
            )
            if !matchesBySimilarity.matched {
                throw PathDeviationError.unexpectedStartState(
                    expectedHash: firstEdge.fromHash,
                    actualHash: initialFp.layoutHash,
                    actualPackage: initialFp.activePackage
                )
            }
        }

        var reports: [MacroStepReport] = []
        reports.reserveCapacity(path.count)
        var lastSettledHash = initialFp.layoutHash

        emit(.executionStarted(totalSteps: path.count))

        do {
            for (stepIndex, edge) in path.enumerated() {
                try Task.checkCancellation()

                // Check if current live DOM already settled at edge.toHash (skip redundant input injection)
                if let liveIndex = await domState.currentIndex {
                    let liveFp = hasher.fingerprint(for: liveIndex)
                    let match = await matchesVertex(fingerprint: liveFp, expectedHash: edge.toHash)
                    if match.matched {
                        lastSettledHash = liveFp.layoutHash
                        let stepReport = MacroStepReport(
                            stepIndex: stepIndex,
                            edgeId: edge.id,
                            actionSignature: edge.actionSignature,
                            targetHash: edge.toHash,
                            elapsedMs: 0,
                            matchedByExactHash: match.exact,
                            wasSkipped: true
                        )
                        reports.append(stepReport)
                        emit(.stepSettled(stepIndex: stepIndex, totalSteps: path.count, report: stepReport))
                        continue
                    }
                }

                guard let rawAction = edge.action else {
                    throw PathDeviationError.missingActionPayload(stepIndex: stepIndex, edgeId: edge.id)
                }

                let resolvedAction = await resolveLiveAction(rawAction)
                let expectedVertex = await graphEngine.vertices[edge.toHash]

                // CRITICAL RACE-FREE ORDER:
                // 1. Subscribe to ShadowDOMState.updates BEFORE injecting input so fast (<50ms) transitions are never missed.
                let updateStream = await domState.updates
                await graphEngine.recordPendingAction(resolvedAction)

                // Notify visual HUD overlays immediately (non-blocking) right before input injection.
                emit(.willExecuteAction(stepIndex: stepIndex, totalSteps: path.count, action: resolvedAction))

                let stepStart = ContinuousClock.now
                let settleResult = try await executeAndWaitForSettle(
                    stepIndex: stepIndex,
                    action: resolvedAction,
                    serial: serial,
                    expectedTargetHash: edge.toHash,
                    expectedVertex: expectedVertex,
                    updateStream: updateStream
                )

                let elapsedMs = Self.elapsedMilliseconds(since: stepStart)
                lastSettledHash = settleResult.hash
                let stepReport = MacroStepReport(
                    stepIndex: stepIndex,
                    edgeId: edge.id,
                    actionSignature: resolvedAction.signature,
                    targetHash: edge.toHash,
                    elapsedMs: elapsedMs,
                    matchedByExactHash: settleResult.matchedByExactHash,
                    wasSkipped: false
                )
                reports.append(stepReport)
                emit(.stepSettled(stepIndex: stepIndex, totalSteps: path.count, report: stepReport))

                if stepIndex + 1 < path.count && configuration.postSettleQuiescenceMs > 0 {
                    try await Task.sleep(for: .milliseconds(configuration.postSettleQuiescenceMs))
                }
            }

            let totalElapsedMs = Self.elapsedMilliseconds(since: totalStart)
            let report = MacroExecutionReport(
                startHash: initialFp.layoutHash,
                finalHash: lastSettledHash,
                steps: reports,
                totalElapsedMs: totalElapsedMs
            )
            emit(.completed(report: report))
            return report
        } catch {
            emit(.failed(message: error.localizedDescription))
            throw error
        }
    }

    // MARK: - Private Helpers

    private enum StepRaceEvent: Sendable {
        case actionDispatched
        case settled(hash: UInt64, matchedByExactHash: Bool)
        case timedOut
    }

    private func executeAndWaitForSettle(
        stepIndex: Int,
        action: AttributedUIAction,
        serial: String,
        expectedTargetHash: UInt64,
        expectedVertex: ScreenStateVertex?,
        updateStream: AsyncStream<ShadowDOMUpdate>
    ) async throws -> (hash: UInt64, matchedByExactHash: Bool) {
        let executor = self.executor
        let hasher = self.hasher
        let threshold = configuration.settleSimilarityThreshold
        let timeoutMs = configuration.stepTimeoutMs

        return try await withThrowingTaskGroup(of: StepRaceEvent.self) { group in
            // Task A: Dispatch UI action via host MacroActionExecutor
            group.addTask {
                do {
                    try await executor.execute(action: action, serial: serial)
                    return .actionDispatched
                } catch is CancellationError {
                    throw CancellationError()
                } catch let deviation as PathDeviationError {
                    throw deviation
                } catch {
                    throw PathDeviationError.actionDispatchFailed(
                        stepIndex: stepIndex,
                        actionSignature: action.signature,
                        underlyingMessage: error.localizedDescription
                    )
                }
            }

            // Task B: Watch pre-subscribed ShadowDOMState update stream until target state settles
            group.addTask {
                for await update in updateStream {
                    try Task.checkCancellation()
                    let fp = hasher.fingerprint(for: update.index)
                    if fp.layoutHash == expectedTargetHash {
                        return .settled(hash: fp.layoutHash, matchedByExactHash: true)
                    }
                    if let expectedVertex,
                       !expectedVertex.semanticTokens.isEmpty,
                       fp.activePackage == expectedVertex.activePackage {
                        let sim = ScreenLayoutHasher.jaccardSimilarity(fp.tokens, expectedVertex.semanticTokens)
                        if sim >= threshold {
                            return .settled(hash: fp.layoutHash, matchedByExactHash: false)
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

            var actionDispatched = false
            var settledOutcome: (hash: UInt64, matchedByExactHash: Bool)?

            while let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .actionDispatched:
                    actionDispatched = true
                    if let outcome = settledOutcome {
                        group.cancelAll()
                        return outcome
                    }
                case .settled(let hash, let matchedByExactHash):
                    settledOutcome = (hash, matchedByExactHash)
                    if actionDispatched {
                        group.cancelAll()
                        return (hash, matchedByExactHash)
                    }
                case .timedOut:
                    if let outcome = settledOutcome {
                        group.cancelAll()
                        return outcome
                    }
                    group.cancelAll()
                    let live = await domState.currentIndex
                    let liveHash = live.map { hasher.fingerprint(for: $0).layoutHash }
                    let livePkg = live?.activePackage ?? "unknown"
                    throw PathDeviationError.stepTimeout(
                        stepIndex: stepIndex,
                        expectedTargetHash: expectedTargetHash,
                        lastObservedHash: liveHash,
                        lastObservedPackage: livePkg,
                        timeoutMs: timeoutMs
                    )
                }
            }

            throw PathDeviationError.shadowStreamUnavailable
        }
    }

    private func resolveLiveAction(_ action: AttributedUIAction) async -> AttributedUIAction {
        guard action.kind == .tap else { return action }

        let rid = action.selectorResourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = action.selectorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = action.selectorContentDesc?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasRid = rid?.isEmpty == false
        let hasText = text?.isEmpty == false
        let hasDesc = desc?.isEmpty == false
        guard hasRid || hasText || hasDesc else { return action }

        let visibleNodes = (await domState.currentIndex)?.orderedNodes.filter {
            $0.visible && ($0.centerX > 0 || $0.centerY > 0)
        } ?? []

        var matchedNode: ShadowUINode?

        if !visibleNodes.isEmpty {
            // 1. Prefer a visible node matching ALL recorded selectors simultaneously.
            //    This prevents generic RecyclerView IDs (e.g. "android:id/title") from matching the wrong row.
            let jointCandidates = visibleNodes.filter { node in
                if let rid, !rid.isEmpty, !Self.node(node, matchesResourceId: rid) { return false }
                if let text, !text.isEmpty, !node.text.localizedCaseInsensitiveContains(text) { return false }
                if let desc, !desc.isEmpty, !node.contentDesc.localizedCaseInsensitiveContains(desc) { return false }
                return true
            }
            if !jointCandidates.isEmpty {
                matchedNode = Self.bestLiveCandidate(in: jointCandidates, expectedText: text, expectedDesc: desc)
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

            // 3. Only fall back to resourceId alone if it uniquely identifies a single visible node on screen
            if matchedNode == nil, let rid, !rid.isEmpty {
                let ridCandidates = visibleNodes.filter { Self.node($0, matchesResourceId: rid) }
                if ridCandidates.count == 1 {
                    matchedNode = ridCandidates[0]
                }
            }
        }

        guard let node = matchedNode, node.visible, (node.centerX > 0 || node.centerY > 0) else {
            return action
        }

        return AttributedUIAction(
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
            timestamp: Date()
        )
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

    private func matchesVertex(
        fingerprint: ScreenSemanticFingerprint,
        expectedHash: UInt64
    ) async -> (matched: Bool, exact: Bool) {
        if fingerprint.layoutHash == expectedHash {
            return (true, true)
        }
        guard let expected = await graphEngine.vertices[expectedHash],
              !expected.semanticTokens.isEmpty,
              fingerprint.activePackage == expected.activePackage else {
            return (false, false)
        }
        let sim = ScreenLayoutHasher.jaccardSimilarity(fingerprint.tokens, expected.semanticTokens)
        return (sim >= configuration.settleSimilarityThreshold, false)
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let millis = (duration.components.seconds * 1_000) + (duration.components.attoseconds / 1_000_000_000_000_000)
        return max(0, Int(millis))
    }
}
