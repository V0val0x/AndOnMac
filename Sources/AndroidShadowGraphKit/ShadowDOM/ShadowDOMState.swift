import Foundation

/// Thread-safe source of truth holding the absolute latest Android Shadow DOM.
/// All reads execute purely in memory in O(1) or bounded scan without ever blocking the main thread or spawning ADB.
public actor ShadowDOMState {
    public private(set) var currentIndex: ShadowTreeIndex?
    public private(set) var lastHello: WireHelloPayload?
    public private(set) var lastHeartbeat: WireHeartbeatPayload?
    public private(set) var lastError: WireErrorPayload?
    public private(set) var lastReceivedAt: Date?
    public private(set) var isDisconnected: Bool = true
    public private(set) var hasSessionSnapshot: Bool = false
    public private(set) var resyncRequestCount: UInt64 = 0

    private let resyncHandler: (@Sendable () async -> Void)?
    private let resyncCooldownSeconds: TimeInterval
    private var lastResyncRequestedAt: Date?

    private final class SnapshotCacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var index: ShadowTreeIndex?
        private var lastReceivedAt: Date?
        private var isDisconnected: Bool = true
        private var hasSessionSnapshot: Bool = false

        func update(
            index: ShadowTreeIndex?,
            lastReceivedAt: Date?,
            isDisconnected: Bool,
            hasSessionSnapshot: Bool
        ) {
            lock.lock()
            self.index = index
            self.lastReceivedAt = lastReceivedAt
            self.isDisconnected = isDisconnected
            self.hasSessionSnapshot = hasSessionSnapshot
            lock.unlock()
        }

        func freshIndex(maxAgeSeconds: TimeInterval) -> ShadowTreeIndex? {
            lock.lock()
            let idx = index
            let receivedAt = lastReceivedAt
            let disconnected = isDisconnected
            let hasSnap = hasSessionSnapshot
            lock.unlock()

            guard !disconnected, hasSnap, let idx, let receivedAt else {
                return nil
            }
            guard Date().timeIntervalSince(receivedAt) <= maxAgeSeconds else {
                return nil
            }
            return idx
        }
    }

    private nonisolated let snapshotCache = SnapshotCacheBox()
    private var updateContinuations: [UUID: AsyncStream<ShadowDOMUpdate>.Continuation] = [:]
    private var snapshotWaiters: [UUID: CheckedContinuation<ShadowTreeIndex?, Never>] = [:]

    public init(
        resyncCooldownSeconds: TimeInterval = 0.25,
        resyncHandler: (@Sendable () async -> Void)? = nil
    ) {
        self.resyncCooldownSeconds = max(0, resyncCooldownSeconds)
        self.resyncHandler = resyncHandler
    }

    /// Broadcast stream of committed Shadow DOM updates consumed by `SpatialGraphEngine` or UI overlays.
    public var updates: AsyncStream<ShadowDOMUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id) }
            }
        }
    }

    // MARK: - Ingestion

    public func handleMessage(_ message: WireMessage) async {
        let now = Date()

        switch message {
        case .hello(let payload):
            lastHello = payload
            hasSessionSnapshot = false
            syncSnapshotCache()

        case .snapshot(let snap):
            lastReceivedAt = now
            isDisconnected = false
            hasSessionSnapshot = true
            let index = ShadowTreeIndex(
                seq: snap.seq,
                timestampMs: snap.timestampMs,
                activePackage: snap.activePackage,
                activeWindowId: snap.activeWindowId,
                nodes: snap.nodes
            )
            currentIndex = index
            syncSnapshotCache()
            fulfillSnapshotWaiters(with: index)
            let update = ShadowDOMUpdate(
                index: index,
                isFullSnapshot: true,
                insertedCount: index.orderedNodes.count,
                updatedCount: 0,
                removedCount: 0,
                eventType: nil,
                eventPackage: nil
            )
            broadcastUpdate(update)

        case .diff(let diff):
            lastReceivedAt = now
            isDisconnected = false
            syncSnapshotCache()
            guard let current = currentIndex else {
                await triggerResyncIfNeeded(now: now)
                return
            }
            if diff.seq <= current.seq {
                // Stale or duplicate frame
                return
            }
            guard diff.baseSeq == current.seq else {
                await triggerResyncIfNeeded(now: now)
                return
            }

            var nextById = current.nodesById
            for removedId in diff.removed {
                nextById.removeValue(forKey: removedId)
            }

            for patch in diff.updated {
                guard var existing = nextById[patch.nodeId] else {
                    // Tree diverged (missing target node for patch) -> request snapshot resync
                    await triggerResyncIfNeeded(now: now)
                    return
                }
                Self.applyPatch(patch, to: &existing)
                nextById[patch.nodeId] = existing
            }

            for insertedNode in diff.inserted {
                nextById[insertedNode.nodeId] = insertedNode
            }

            let nextIndex = ShadowTreeIndex(
                seq: diff.seq,
                timestampMs: diff.timestampMs,
                activePackage: diff.activePackage,
                activeWindowId: diff.activeWindowId,
                nodes: Array(nextById.values)
            )
            currentIndex = nextIndex
            hasSessionSnapshot = true
            syncSnapshotCache()
            fulfillSnapshotWaiters(with: nextIndex)

            let update = ShadowDOMUpdate(
                index: nextIndex,
                isFullSnapshot: false,
                insertedCount: diff.inserted.count,
                updatedCount: diff.updated.count,
                removedCount: diff.removed.count,
                eventType: diff.eventType,
                eventPackage: diff.eventPackage
            )
            broadcastUpdate(update)

        case .heartbeat(let hb):
            lastHeartbeat = hb
            if hasSessionSnapshot {
                lastReceivedAt = now
                isDisconnected = false
                syncSnapshotCache()
            }

        case .error(let err):
            lastError = err

        case .pong:
            if hasSessionSnapshot {
                lastReceivedAt = now
                isDisconnected = false
                syncSnapshotCache()
            }
        }
    }

    /// Marks the transport disconnected while retaining the last snapshot for diagnostics.
    public func markDisconnected() {
        isDisconnected = true
        hasSessionSnapshot = false
        syncSnapshotCache()
        fulfillSnapshotWaiters(with: nil)
    }

    public func reset() {
        currentIndex = nil
        lastHello = nil
        lastHeartbeat = nil
        lastError = nil
        lastReceivedAt = nil
        isDisconnected = true
        hasSessionSnapshot = false
        lastResyncRequestedAt = nil
        syncSnapshotCache()
        fulfillSnapshotWaiters(with: nil)
    }

    // MARK: - Instant Non-Blocking Read APIs

    /// Returns the latest live tree in O(1).
    public func getCurrentTree() -> [ShadowUINode] {
        currentIndex?.orderedNodes ?? []
    }

    /// Returns pre-built token-efficient `ShadowCompactNode` records in O(1).
    public func getCompactTree() -> [ShadowCompactNode] {
        currentIndex?.compactNodes ?? []
    }

    public func getSnapshotMetadata() -> (seq: UInt64, package: String, windowId: Int, ageMs: Int)? {
        guard let index = currentIndex, let receivedAt = lastReceivedAt else { return nil }
        let ageMs = max(0, Int((Date().timeIntervalSince(receivedAt) * 1000.0).rounded()))
        return (index.seq, index.activePackage, index.activeWindowId, ageMs)
    }

    public func isFresh(maxAgeSeconds: TimeInterval = 15.0) -> Bool {
        guard !isDisconnected, hasSessionSnapshot, currentIndex != nil, let receivedAt = lastReceivedAt else {
            return false
        }
        return Date().timeIntervalSince(receivedAt) <= maxAgeSeconds
    }

    /// Lock-protected synchronous snapshot read so GUI tap handlers can resolve selectors without awaiting the actor.
    public nonisolated func freshIndexSnapshotIfAvailable(maxAgeSeconds: TimeInterval = 15.0) -> ShadowTreeIndex? {
        snapshotCache.freshIndex(maxAgeSeconds: maxAgeSeconds)
    }

    private func syncSnapshotCache() {
        snapshotCache.update(
            index: currentIndex,
            lastReceivedAt: lastReceivedAt,
            isDisconnected: isDisconnected,
            hasSessionSnapshot: hasSessionSnapshot
        )
    }

    public func node(forId nodeId: Int64) -> ShadowUINode? {
        currentIndex?.nodesById[nodeId]
    }

    public func children(ofId parentId: Int64) -> [ShadowUINode] {
        guard let index = currentIndex,
              let childIds = index.childrenByParentId[parentId] else {
            return []
        }
        return childIds.compactMap { index.nodesById[$0] }
    }

    public func findNode(
        byText query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive,
        preferClickable: Bool = true
    ) -> ShadowUINode? {
        guard let index = currentIndex, !query.isEmpty else { return nil }
        let lowered = query.lowercased()

        // O(1) exact index check first
        if let exactCandidates = index.exactLowercasedTextNodes(for: lowered) {
            if mode == .exact {
                let caseMatched = exactCandidates.filter { $0.text == query }
                if let best = bestCandidate(in: caseMatched, preferClickable: preferClickable) {
                    return best
                }
                return nil
            }
            if let best = bestCandidate(in: exactCandidates, preferClickable: preferClickable) {
                return best
            }
        } else if mode == .exact {
            return nil
        }

        // Substring scan across bounded active UI nodes
        var bestNode: ShadowUINode?
        var bestScore = Int.min
        for node in index.orderedNodes where !node.text.isEmpty {
            let nodeLower = node.text.lowercased()
            guard nodeLower.contains(lowered) else { continue }
            var score = 0
            if nodeLower == lowered { score += 100 }
            else if nodeLower.hasPrefix(lowered) { score += 50 }
            else { score += 20 }
            score += commonNodeScore(node, preferClickable: preferClickable)
            if score > bestScore {
                bestScore = score
                bestNode = node
            }
        }
        return bestNode
    }

    public func findNode(
        byResourceID resourceId: String,
        mode: ShadowTreeMatchMode = .suffixOrExactResourceId
    ) -> ShadowUINode? {
        guard let index = currentIndex, !resourceId.isEmpty else { return nil }

        // O(1) exact resource_id match
        if let exact = index.exactNodes(forResourceId: resourceId),
           let best = bestCandidate(in: exact, preferClickable: true) {
            return best
        }
        if mode == .exact {
            return nil
        }

        // O(1) short resource_id match (e.g., "btn_confirm" -> "com.app:id/btn_confirm")
        if mode == .suffixOrExactResourceId,
           let shortHits = index.shortIdNodes(forShortResourceId: resourceId),
           let best = bestCandidate(in: shortHits, preferClickable: true) {
            return best
        }

        // Bounded case-insensitive suffix / substring fallback
        let lowered = resourceId.lowercased()
        var bestNode: ShadowUINode?
        var bestScore = Int.min
        for node in index.orderedNodes where !node.resourceId.isEmpty {
            let ridLower = node.resourceId.lowercased()
            let matched: Bool
            var score = 0
            if ridLower == lowered {
                matched = true
                score += 120
            } else if ridLower.hasSuffix("/" + lowered) || ridLower.hasSuffix(":" + lowered) || ridLower.hasSuffix(lowered) {
                matched = true
                score += 80
            } else if mode == .containsCaseInsensitive && ridLower.contains(lowered) {
                matched = true
                score += 30
            } else {
                matched = false
            }
            if matched {
                score += commonNodeScore(node, preferClickable: true)
                if score > bestScore {
                    bestScore = score
                    bestNode = node
                }
            }
        }
        return bestNode
    }

    public func findNode(
        byContentDesc query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive
    ) -> ShadowUINode? {
        guard let index = currentIndex, !query.isEmpty else { return nil }
        let lowered = query.lowercased()

        if let exactCandidates = index.exactLowercasedDescNodes(for: lowered) {
            if mode == .exact {
                let caseMatched = exactCandidates.filter { $0.contentDesc == query }
                return bestCandidate(in: caseMatched, preferClickable: true)
            }
            if let best = bestCandidate(in: exactCandidates, preferClickable: true) {
                return best
            }
        } else if mode == .exact {
            return nil
        }

        var bestNode: ShadowUINode?
        var bestScore = Int.min
        for node in index.orderedNodes where !node.contentDesc.isEmpty {
            let descLower = node.contentDesc.lowercased()
            guard descLower.contains(lowered) else { continue }
            var score = 0
            if descLower == lowered { score += 100 }
            else if descLower.hasPrefix(lowered) { score += 50 }
            else { score += 20 }
            score += commonNodeScore(node, preferClickable: true)
            if score > bestScore {
                bestScore = score
                bestNode = node
            }
        }
        return bestNode
    }

    /// Waits up to `timeoutSeconds` for a current-session snapshot if none is cached/fresh yet; returns immediately if already warm.
    public func waitForSnapshot(timeoutSeconds: TimeInterval = 0.5) async -> ShadowTreeIndex? {
        if hasSessionSnapshot, !isDisconnected, let currentIndex {
            return currentIndex
        }
        guard timeoutSeconds > 0 else { return nil }

        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ShadowTreeIndex?, Never>) in
                if self.hasSessionSnapshot, !self.isDisconnected, let currentIndex = self.currentIndex {
                    continuation.resume(returning: currentIndex)
                    return
                }
                self.snapshotWaiters[waiterId] = continuation

                Task { [weak self] in
                    let ns = UInt64(max(0.001, timeoutSeconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: ns)
                    await self?.resolveWaiter(id: waiterId, index: nil)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveWaiter(id: waiterId, index: nil)
            }
        }
    }

    // MARK: - Helpers

    private func triggerResyncIfNeeded(now: Date) async {
        if let last = lastResyncRequestedAt,
           now.timeIntervalSince(last) < resyncCooldownSeconds {
            return
        }
        lastResyncRequestedAt = now
        resyncRequestCount &+= 1
        await resyncHandler?()
    }

    private func resolveWaiter(id: UUID, index: ShadowTreeIndex?) {
        guard let cont = snapshotWaiters.removeValue(forKey: id) else { return }
        cont.resume(returning: index)
    }

    private func fulfillSnapshotWaiters(with index: ShadowTreeIndex?) {
        guard !snapshotWaiters.isEmpty else { return }
        let waiters = Array(snapshotWaiters.values)
        snapshotWaiters.removeAll()
        for cont in waiters {
            cont.resume(returning: index)
        }
    }

    private func broadcastUpdate(_ update: ShadowDOMUpdate) {
        for cont in updateContinuations.values {
            cont.yield(update)
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    private func bestCandidate(in candidates: [ShadowUINode], preferClickable: Bool) -> ShadowUINode? {
        candidates.max { lhs, rhs in
            commonNodeScore(lhs, preferClickable: preferClickable) < commonNodeScore(rhs, preferClickable: preferClickable)
        }
    }

    private func commonNodeScore(_ node: ShadowUINode, preferClickable: Bool) -> Int {
        var score = 0
        if node.visible { score += 16 }
        if node.enabled { score += 8 }
        if preferClickable && node.clickable { score += 4 }
        return score
    }

    private static func applyPatch(_ patch: WireNodePatch, to node: inout ShadowUINode) {
        let mask = ShadowPatchMask(rawValue: patch.mask)
        if patch.hasParentIdKey {
            node.parentId = patch.parentId
        }
        if mask.contains(.order) {
            if let v = patch.index { node.index = v }
            if let v = patch.childIndex { node.childIndex = v }
            if let v = patch.depth { node.depth = v }
        }
        if mask.contains(.text), let v = patch.text {
            node.text = v
        }
        if mask.contains(.contentDesc), let v = patch.contentDesc {
            node.contentDesc = v
        }
        if mask.contains(.resourceId), let v = patch.resourceId {
            node.resourceId = v
        }
        if mask.contains(.nodeClass) {
            if let v = patch.className { node.className = v }
            if let v = patch.packageName { node.packageName = v }
        }
        if mask.contains(.bounds) {
            if let v = patch.bounds { node.bounds = v }
            if let v = patch.centerX { node.centerX = v }
            if let v = patch.centerY { node.centerY = v }
        }
        if mask.contains(.flags) {
            if let v = patch.clickable { node.clickable = v }
            if let v = patch.scrollable { node.scrollable = v }
            if let v = patch.editable { node.editable = v }
            if let v = patch.focused { node.focused = v }
            if let v = patch.checked { node.checked = v }
            if let v = patch.enabled { node.enabled = v }
            if let v = patch.visible { node.visible = v }
        }
    }
}
