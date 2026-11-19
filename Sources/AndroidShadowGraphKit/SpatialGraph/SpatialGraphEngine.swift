import Foundation

/// Builds a persistent canonical directed multigraph of deduplicated `ScreenStateVertex` nodes
/// while simultaneously maintaining a first-discovery acyclic spanning DAG for deterministic A* planning.
public actor SpatialGraphEngine {
    public private(set) var rootStateHash: UInt64?
    public private(set) var currentStateHash: UInt64?
    public private(set) var vertices: [UInt64: ScreenStateVertex] = [:]
    public private(set) var outgoingEdges: [UInt64: [ScreenTransitionEdge]] = [:]
    public private(set) var spanningChildren: [UInt64: [UInt64]] = [:]
    public private(set) var topologyRevision: UInt64 = 0

    private static let defaultCanonicalSimilarityThreshold: Double = 0.90
    private static let minimumCanonicalTokenCount: Int = 4

    private let hasher: ScreenLayoutHasher
    private let significanceThreshold: Double
    private let pendingActionTTL: TimeInterval

    private var currentFingerprint: ScreenSemanticFingerprint?
    private var lastStateTransitionAt: Date?
    private var pendingAction: AttributedUIAction?
    private var onTopologyChanged: (@Sendable () async -> Void)?

    public init(
        hasher: ScreenLayoutHasher = ScreenLayoutHasher(),
        significanceThreshold: Double = 0.72,
        pendingActionTTL: TimeInterval = 5.0
    ) {
        self.hasher = hasher
        self.significanceThreshold = max(0.0, min(1.0, significanceThreshold))
        self.pendingActionTTL = max(0.1, pendingActionTTL)
    }

    public func setOnTopologyChanged(_ handler: (@Sendable () async -> Void)?) {
        onTopologyChanged = handler
    }

    public var vertexCount: Int { vertices.count }
    public var edgeCount: Int { outgoingEdges.values.reduce(0) { $0 + $1.count } }

    /// Records the user/agent UI action just dispatched so the next significant screen shift labels the edge.
    public func recordPendingAction(_ action: AttributedUIAction) {
        pendingAction = action
    }

    /// Evaluates a committed `ShadowDOMUpdate`, deduplicating states and recording transitions.
    @discardableResult
    public func process(update: ShadowDOMUpdate) -> ScreenTransitionEdge? {
        if update.isSecureScreenActive {
            return nil
        }
        let now = Date()
        let fp = hasher.fingerprint(for: update.index)

        // 1. Cold start: establish root vertex of the spanning DAG (or snap into an imported graph)
        guard let prevHash = currentStateHash, let prevFp = currentFingerprint else {
            // Avoid seeding root with an empty transient frame if nodes are temporarily absent
            if fp.tokens.isEmpty && update.index.orderedNodes.isEmpty {
                return nil
            }
            if var exact = vertices[fp.layoutHash] {
                exact.lastSeenAt = now
                exact.visitCount += 1
                vertices[exact.layoutHash] = exact
                if rootStateHash == nil { rootStateHash = exact.layoutHash }
                currentStateHash = exact.layoutHash
                currentFingerprint = canonicalFingerprint(from: exact, fallbackActiveWindowId: fp.activeWindowId)
                lastStateTransitionAt = now
                pendingAction = nil
                return nil
            }
            if let canonical = bestCanonicalMatch(for: fp) {
                var updated = canonical
                updated.lastSeenAt = now
                updated.visitCount += 1
                vertices[updated.layoutHash] = updated
                if rootStateHash == nil { rootStateHash = updated.layoutHash }
                currentStateHash = updated.layoutHash
                currentFingerprint = canonicalFingerprint(from: updated, fallbackActiveWindowId: fp.activeWindowId)
                lastStateTransitionAt = now
                pendingAction = nil
                return nil
            }
            let root = ScreenStateVertex(
                layoutHash: fp.layoutHash,
                activePackage: fp.activePackage,
                sampleInteractiveLabels: fp.sampleInteractiveLabels,
                semanticTokens: fp.tokens,
                firstSeenAt: now,
                lastSeenAt: now,
                visitCount: 1,
                discoveryParentHash: nil,
                discoveryDepth: 0
            )
            vertices[fp.layoutHash] = root
            if rootStateHash == nil { rootStateHash = fp.layoutHash }
            currentStateHash = fp.layoutHash
            currentFingerprint = fp
            lastStateTransitionAt = now
            pendingAction = nil
            notifyTopologyChanged()
            return nil
        }

        // 2. Identical layout hash: remain on current vertex
        if fp.layoutHash == prevHash {
            vertices[prevHash]?.lastSeenAt = now
            currentFingerprint = fp
            return nil
        }

        // 3. Ignore transient empty/status-bar-only transition frames without consuming pendingAction
        if fp.tokens.isEmpty {
            return nil
        }
        if hasher.ignoredPackages.contains(fp.activePackage),
           !hasher.ignoredPackages.contains(prevFp.activePackage),
           !update.index.orderedNodes.contains(where: { $0.visible && ($0.clickable || $0.scrollable || $0.editable) }) {
            return nil
        }

        // 4. Check if destination hash already exists in the canonical multigraph (cyclic revisit)
        let isAlreadyKnownVertex = vertices[fp.layoutHash] != nil

        // 5. For brand-new hashes in the same app, suppress minor layout jitter above significanceThreshold
        //    (must happen BEFORE consuming pendingAction so ripple/scroll frames don't drop action attribution)
        if !isAlreadyKnownVertex && fp.activePackage == prevFp.activePackage {
            let sim = ScreenLayoutHasher.similarity(prevFp, fp)
            if sim >= significanceThreshold {
                vertices[prevHash]?.lastSeenAt = now
                return nil
            }
        }

        // 6. Cross-app / post-transition canonical deduplication:
        //    If returning to a previously seen screen (e.g. Home screen after Settings or a mixed transition frame)
        //    whose structural token set matches an existing same-package vertex at >= canonicalSimilarityThreshold,
        //    snap to that canonical vertex instead of spawning a duplicate node.
        var resolvedFingerprint = fp
        if !isAlreadyKnownVertex, let canonical = bestCanonicalMatch(for: fp) {
            if canonical.layoutHash == prevHash {
                vertices[prevHash]?.lastSeenAt = now
                return nil
            }
            resolvedFingerprint = canonicalFingerprint(
                from: canonical,
                fallbackActiveWindowId: fp.activeWindowId
            )
        }

        let attributedAction = consumeValidPendingAction(now: now)
        let transitionMs = max(0, (now.timeIntervalSince(attributedAction?.timestamp ?? lastStateTransitionAt ?? now)) * 1000.0)

        let isNewDiscovery: Bool
        var didUpgradeTokens = false
        if var existing = vertices[resolvedFingerprint.layoutHash] {
            existing.lastSeenAt = now
            existing.visitCount += 1
            if existing.semanticTokens.isEmpty && !resolvedFingerprint.tokens.isEmpty {
                existing.semanticTokens = resolvedFingerprint.tokens
                didUpgradeTokens = true
            }
            vertices[resolvedFingerprint.layoutHash] = existing
            isNewDiscovery = false
        } else {
            let parentDepth = vertices[prevHash]?.discoveryDepth ?? 0
            let vertex = ScreenStateVertex(
                layoutHash: resolvedFingerprint.layoutHash,
                activePackage: resolvedFingerprint.activePackage,
                sampleInteractiveLabels: resolvedFingerprint.sampleInteractiveLabels,
                semanticTokens: resolvedFingerprint.tokens,
                firstSeenAt: now,
                lastSeenAt: now,
                visitCount: 1,
                discoveryParentHash: prevHash,
                discoveryDepth: parentDepth + 1
            )
            vertices[resolvedFingerprint.layoutHash] = vertex
            spanningChildren[prevHash, default: []].append(resolvedFingerprint.layoutHash)
            isNewDiscovery = true
        }

        let actionSig = attributedAction?.signature ?? "implicit"
        let hazard = HazardousActionClassifier.assess(action: attributedAction, actionSignature: actionSig)
        var edges = outgoingEdges[prevHash, default: []]
        let committedEdge: ScreenTransitionEdge
        let isNewEdge: Bool

        if let existingIdx = edges.firstIndex(where: { $0.toHash == resolvedFingerprint.layoutHash && $0.actionSignature == actionSig }) {
            var edge = edges[existingIdx]
            let prevCount = Double(edge.traversalCount)
            edge.traversalCount += 1
            edge.averageTransitionMs = ((edge.averageTransitionMs * prevCount) + transitionMs) / Double(edge.traversalCount)
            edge.lastTraversedAt = now
            if hazard.isHazardous && !edge.isHazardous {
                edge.isHazardous = true
                edge.hazardReason = hazard.reason
            }
            edges[existingIdx] = edge
            committedEdge = edge
            isNewEdge = false
        } else {
            let edge = ScreenTransitionEdge(
                fromHash: prevHash,
                toHash: resolvedFingerprint.layoutHash,
                action: attributedAction,
                actionSignature: actionSig,
                traversalCount: 1,
                averageTransitionMs: transitionMs,
                isSpanningTreeEdge: isNewDiscovery,
                lastTraversedAt: now,
                isHazardous: hazard.isHazardous,
                hazardReason: hazard.isHazardous ? hazard.reason : nil
            )
            edges.append(edge)
            committedEdge = edge
            isNewEdge = true
        }
        outgoingEdges[prevHash] = edges

        currentStateHash = resolvedFingerprint.layoutHash
        currentFingerprint = resolvedFingerprint
        lastStateTransitionAt = now
        if isNewDiscovery || isNewEdge || didUpgradeTokens {
            notifyTopologyChanged()
        }
        return committedEdge
    }

    private func canonicalFingerprint(
        from vertex: ScreenStateVertex,
        fallbackActiveWindowId: Int
    ) -> ScreenSemanticFingerprint {
        ScreenSemanticFingerprint(
            layoutHash: vertex.layoutHash,
            activePackage: vertex.activePackage,
            activeWindowId: fallbackActiveWindowId,
            tokens: vertex.semanticTokens,
            sampleInteractiveLabels: vertex.sampleInteractiveLabels
        )
    }

    private func bestCanonicalMatch(for fp: ScreenSemanticFingerprint) -> ScreenStateVertex? {
        guard fp.tokens.count >= Self.minimumCanonicalTokenCount else { return nil }
        let threshold = max(Self.defaultCanonicalSimilarityThreshold, significanceThreshold)
        var bestVertex: ScreenStateVertex?
        var bestSim: Double = 0.0

        for vertex in vertices.values {
            guard vertex.activePackage == fp.activePackage,
                  !vertex.semanticTokens.isEmpty else { continue }
            let sim = ScreenLayoutHasher.jaccardSimilarity(vertex.semanticTokens, fp.tokens)
            guard sim >= threshold else { continue }
            if let currentBest = bestVertex {
                if sim > bestSim
                    || (sim == bestSim && vertex.visitCount > currentBest.visitCount)
                    || (sim == bestSim && vertex.visitCount == currentBest.visitCount && vertex.layoutHash < currentBest.layoutHash) {
                    bestVertex = vertex
                    bestSim = sim
                }
            } else {
                bestVertex = vertex
                bestSim = sim
            }
        }
        return bestVertex
    }

    public func neighbors(of stateHash: UInt64) -> [ScreenTransitionEdge] {
        outgoingEdges[stateHash] ?? []
    }

    public func predecessors(of stateHash: UInt64) -> [ScreenTransitionEdge] {
        var result: [ScreenTransitionEdge] = []
        for edges in outgoingEdges.values {
            for edge in edges where edge.toHash == stateHash {
                result.append(edge)
            }
        }
        return result
    }

    public func spanningDAGChildren(of stateHash: UInt64) -> [UInt64] {
        spanningChildren[stateHash] ?? []
    }

    /// Returns the deterministic path from `rootStateHash` down to `stateHash` along the first-discovery spanning DAG.
    public func spanningPathFromRoot(to stateHash: UInt64) -> [UInt64] {
        guard vertices[stateHash] != nil else { return [] }
        var reversedPath: [UInt64] = []
        var visited = Set<UInt64>()
        var cursor: UInt64? = stateHash

        while let hash = cursor, visited.insert(hash).inserted {
            reversedPath.append(hash)
            cursor = vertices[hash]?.discoveryParentHash
        }
        return reversedPath.reversed()
    }

    /// Verifies that the first-discovery spanning parent links form a strict acyclic tree.
    public func isSpanningDAGAcyclic() -> Bool {
        for (parent, children) in spanningChildren {
            for child in children {
                guard let childVertex = vertices[child], childVertex.discoveryParentHash == parent else {
                    return false
                }
            }
        }
        for hash in vertices.keys {
            var seen = Set<UInt64>()
            var cursor: UInt64? = hash
            while let current = cursor {
                if !seen.insert(current).inserted {
                    return false
                }
                cursor = vertices[current]?.discoveryParentHash
            }
        }
        return true
    }

    public func snapshot() -> SpatialGraphSnapshot {
        let sortedVertices = vertices.values.sorted { $0.firstSeenAt < $1.firstSeenAt }
        let allEdges = outgoingEdges.values.flatMap { $0 }.sorted { $0.lastTraversedAt < $1.lastTraversedAt }
        return SpatialGraphSnapshot(
            rootStateHash: rootStateHash,
            currentStateHash: currentStateHash,
            vertices: sortedVertices,
            edges: allEdges,
            spanningChildren: spanningChildren
        )
    }

    public func exportGraphJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.withoutEscapingSlashes]
        }
        return try encoder.encode(snapshot())
    }

    public func importGraphJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SpatialGraphSnapshot.self, from: data)
        importSnapshot(snapshot)
    }

    private struct RewiredEdgeKey: Hashable {
        let fromHash: UInt64
        let toHash: UInt64
        let actionSignature: String
    }

    public func importSnapshot(_ snapshot: SpatialGraphSnapshot) {
        reset()

        // 1. Canonicalize persisted tokens and deduplicate exact layoutHash collisions
        var rawVerticesByHash: [UInt64: ScreenStateVertex] = Dictionary(minimumCapacity: snapshot.vertices.count)
        for var vertex in snapshot.vertices {
            if !vertex.semanticTokens.isEmpty {
                let canonicalized = Set(
                    vertex.semanticTokens.map {
                        ScreenLayoutHasher.canonicalizeToken($0, activePackage: vertex.activePackage)
                    }
                )
                let pruned = canonicalized.filter { !ScreenLayoutHasher.isUnanchoredImageToken($0) }
                vertex.semanticTokens = pruned.count >= Self.minimumCanonicalTokenCount ? pruned : canonicalized
            }
            if let existing = rawVerticesByHash[vertex.layoutHash] {
                let earliestFirst = min(existing.firstSeenAt, vertex.firstSeenAt)
                let latestLast = max(existing.lastSeenAt, vertex.lastSeenAt)
                let mergedLabels = existing.sampleInteractiveLabels.isEmpty ? vertex.sampleInteractiveLabels : existing.sampleInteractiveLabels
                let mergedTokens = existing.semanticTokens.isEmpty ? vertex.semanticTokens : existing.semanticTokens
                let keepExistingDiscovery = existing.firstSeenAt <= vertex.firstSeenAt
                rawVerticesByHash[vertex.layoutHash] = ScreenStateVertex(
                    layoutHash: existing.layoutHash,
                    activePackage: existing.activePackage,
                    sampleInteractiveLabels: mergedLabels,
                    semanticTokens: mergedTokens,
                    firstSeenAt: earliestFirst,
                    lastSeenAt: latestLast,
                    visitCount: existing.visitCount + max(0, vertex.visitCount),
                    discoveryParentHash: keepExistingDiscovery ? existing.discoveryParentHash : vertex.discoveryParentHash,
                    discoveryDepth: keepExistingDiscovery ? existing.discoveryDepth : vertex.discoveryDepth
                )
            } else {
                rawVerticesByHash[vertex.layoutHash] = vertex
            }
        }

        // 2. Sort deterministically by canonical priority and compact duplicate vertices (Jaccard >= threshold)
        let threshold = max(Self.defaultCanonicalSimilarityThreshold, significanceThreshold)
        let sortedVertices = rawVerticesByHash.values.sorted { lhs, rhs in
            let lhsIsRoot = (lhs.layoutHash == snapshot.rootStateHash)
            let rhsIsRoot = (rhs.layoutHash == snapshot.rootStateHash)
            if lhsIsRoot != rhsIsRoot { return lhsIsRoot }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            if lhs.firstSeenAt != rhs.firstSeenAt { return lhs.firstSeenAt < rhs.firstSeenAt }
            if lhs.semanticTokens.count != rhs.semanticTokens.count {
                return lhs.semanticTokens.count > rhs.semanticTokens.count
            }
            return lhs.layoutHash < rhs.layoutHash
        }

        var canonicalMap: [UInt64: UInt64] = Dictionary(minimumCapacity: sortedVertices.count)
        var canonicalVertices: [UInt64: ScreenStateVertex] = Dictionary(minimumCapacity: sortedVertices.count)
        var leadersByPackage: [String: [UInt64]] = [:]
        var mergedVertexCount = 0

        for vertex in sortedVertices {
            var matchedLeaderHash: UInt64?
            var bestSimilarity: Double = 0.0

            if !vertex.semanticTokens.isEmpty, let packageLeaders = leadersByPackage[vertex.activePackage] {
                for leaderHash in packageLeaders {
                    guard let leader = canonicalVertices[leaderHash],
                          !leader.semanticTokens.isEmpty else { continue }
                    let sim = ScreenLayoutHasher.jaccardSimilarity(leader.semanticTokens, vertex.semanticTokens)
                    let isEligible = (min(leader.semanticTokens.count, vertex.semanticTokens.count) >= Self.minimumCanonicalTokenCount && sim >= threshold)
                        || sim == 1.0
                    guard isEligible else { continue }
                    if matchedLeaderHash == nil || sim > bestSimilarity {
                        matchedLeaderHash = leaderHash
                        bestSimilarity = sim
                    }
                }
            }

            if let leaderHash = matchedLeaderHash, let leader = canonicalVertices[leaderHash] {
                canonicalMap[vertex.layoutHash] = leaderHash
                mergedVertexCount += 1
                let mergedLabels = leader.sampleInteractiveLabels.isEmpty ? vertex.sampleInteractiveLabels : leader.sampleInteractiveLabels
                canonicalVertices[leaderHash] = ScreenStateVertex(
                    layoutHash: leader.layoutHash,
                    activePackage: leader.activePackage,
                    sampleInteractiveLabels: mergedLabels,
                    semanticTokens: leader.semanticTokens,
                    firstSeenAt: min(leader.firstSeenAt, vertex.firstSeenAt),
                    lastSeenAt: max(leader.lastSeenAt, vertex.lastSeenAt),
                    visitCount: leader.visitCount + max(0, vertex.visitCount),
                    discoveryParentHash: leader.discoveryParentHash,
                    discoveryDepth: leader.discoveryDepth
                )
            } else {
                canonicalMap[vertex.layoutHash] = vertex.layoutHash
                canonicalVertices[vertex.layoutHash] = vertex
                leadersByPackage[vertex.activePackage, default: []].append(vertex.layoutHash)
            }
        }

        vertices = canonicalVertices

        if let rawRoot = snapshot.rootStateHash {
            let mappedRoot = canonicalMap[rawRoot] ?? rawRoot
            rootStateHash = vertices[mappedRoot] != nil ? mappedRoot : nil
        } else {
            rootStateHash = nil
        }

        if let rawCurrent = snapshot.currentStateHash {
            let mappedCurrent = canonicalMap[rawCurrent] ?? rawCurrent
            currentStateHash = vertices[mappedCurrent] != nil ? mappedCurrent : nil
        } else {
            currentStateHash = nil
        }

        // 3. Rewire valid edges onto canonical vertices, dropping self-loops and action == nil transitions between merged vertices
        var deduplicatedEdges: [RewiredEdgeKey: ScreenTransitionEdge] = [:]
        var orderedEdgeKeys: [RewiredEdgeKey] = []
        var droppedOrMergedEdgeCount = 0

        for edge in snapshot.edges {
            guard let mappedFrom = canonicalMap[edge.fromHash],
                  let mappedTo = canonicalMap[edge.toHash],
                  vertices[mappedFrom] != nil,
                  vertices[mappedTo] != nil else {
                droppedOrMergedEdgeCount += 1
                continue
            }

            guard mappedFrom != mappedTo else {
                droppedOrMergedEdgeCount += 1
                continue
            }

            let wasEndpointMerged = (mappedFrom != edge.fromHash) || (mappedTo != edge.toHash)
            if edge.action == nil && wasEndpointMerged {
                droppedOrMergedEdgeCount += 1
                continue
            }

            let key = RewiredEdgeKey(
                fromHash: mappedFrom,
                toHash: mappedTo,
                actionSignature: edge.actionSignature
            )

            if let existing = deduplicatedEdges[key] {
                droppedOrMergedEdgeCount += 1
                let existingCount = max(0, existing.traversalCount)
                let incomingCount = max(0, edge.traversalCount)
                let totalCount = existingCount + incomingCount
                let mergedAvgMs: Double
                if totalCount > 0 {
                    mergedAvgMs = ((existing.averageTransitionMs * Double(existingCount)) + (edge.averageTransitionMs * Double(incomingCount))) / Double(totalCount)
                } else {
                    mergedAvgMs = existing.averageTransitionMs
                }
                let newerAction: AttributedUIAction?
                if edge.lastTraversedAt >= existing.lastTraversedAt {
                    newerAction = edge.action ?? existing.action
                } else {
                    newerAction = existing.action ?? edge.action
                }
                let hazard = HazardousActionClassifier.assess(action: newerAction, actionSignature: edge.actionSignature)
                let mergedHazardous = existing.isHazardous || edge.isHazardous || hazard.isHazardous
                let mergedReason = existing.hazardReason ?? edge.hazardReason ?? (hazard.isHazardous ? hazard.reason : nil)
                deduplicatedEdges[key] = ScreenTransitionEdge(
                    id: existing.id,
                    fromHash: mappedFrom,
                    toHash: mappedTo,
                    action: newerAction,
                    actionSignature: edge.actionSignature,
                    traversalCount: max(1, totalCount),
                    averageTransitionMs: mergedAvgMs,
                    isSpanningTreeEdge: existing.isSpanningTreeEdge || edge.isSpanningTreeEdge,
                    lastTraversedAt: max(existing.lastTraversedAt, edge.lastTraversedAt),
                    isHazardous: mergedHazardous,
                    hazardReason: mergedHazardous ? mergedReason : nil
                )
            } else {
                let hazard = HazardousActionClassifier.assess(action: edge.action, actionSignature: edge.actionSignature)
                let isHaz = edge.isHazardous || hazard.isHazardous
                let hazReason = edge.hazardReason ?? (hazard.isHazardous ? hazard.reason : nil)
                deduplicatedEdges[key] = ScreenTransitionEdge(
                    id: edge.id,
                    fromHash: mappedFrom,
                    toHash: mappedTo,
                    action: edge.action,
                    actionSignature: edge.actionSignature,
                    traversalCount: edge.traversalCount,
                    averageTransitionMs: edge.averageTransitionMs,
                    isSpanningTreeEdge: edge.isSpanningTreeEdge,
                    lastTraversedAt: edge.lastTraversedAt,
                    isHazardous: isHaz,
                    hazardReason: isHaz ? hazReason : nil
                )
                orderedEdgeKeys.append(key)
            }
        }

        for key in orderedEdgeKeys {
            if let edge = deduplicatedEdges[key] {
                outgoingEdges[edge.fromHash, default: []].append(edge)
            }
        }

        // 4. Preserve or rebuild acyclic spanning DAG invariants
        let filteredSnapshotSpanningChildren = snapshot.spanningChildren.filter { !$0.value.isEmpty }
        if mergedVertexCount == 0
            && droppedOrMergedEdgeCount == 0
            && hasValidSpanningTree(candidateSpanningChildren: filteredSnapshotSpanningChildren) {
            spanningChildren = filteredSnapshotSpanningChildren
        } else {
            rebuildSpanningDAG()
        }

        if let curHash = currentStateHash, let curVertex = vertices[curHash] {
            currentFingerprint = ScreenSemanticFingerprint(
                layoutHash: curVertex.layoutHash,
                activePackage: curVertex.activePackage,
                activeWindowId: 0,
                tokens: curVertex.semanticTokens,
                sampleInteractiveLabels: curVertex.sampleInteractiveLabels
            )
        }
    }

    private func hasValidSpanningTree(candidateSpanningChildren: [UInt64: [UInt64]]) -> Bool {
        var expectedChildren: [UInt64: Set<UInt64>] = [:]
        for (hash, vertex) in vertices {
            if let parent = vertex.discoveryParentHash {
                guard parent != hash, let parentVertex = vertices[parent] else {
                    return false
                }
                guard vertex.discoveryDepth == parentVertex.discoveryDepth + 1 else {
                    return false
                }
                guard outgoingEdges[parent]?.contains(where: { $0.toHash == hash && $0.isSpanningTreeEdge }) == true else {
                    return false
                }
                expectedChildren[parent, default: []].insert(hash)
            } else if vertex.discoveryDepth != 0 {
                return false
            }
        }

        for (fromHash, edges) in outgoingEdges {
            for edge in edges where edge.isSpanningTreeEdge {
                guard expectedChildren[fromHash]?.contains(edge.toHash) == true else {
                    return false
                }
            }
        }

        for (parent, children) in candidateSpanningChildren {
            guard vertices[parent] != nil else { return false }
            let uniqueChildren = Set(children)
            guard uniqueChildren.count == children.count else { return false }
            for child in children {
                guard vertices[child]?.discoveryParentHash == parent else { return false }
            }
            if !children.isEmpty {
                guard expectedChildren[parent] == uniqueChildren else { return false }
            }
        }

        for (parent, childSet) in expectedChildren where !childSet.isEmpty {
            let actual = Set(candidateSpanningChildren[parent] ?? [])
            guard actual == childSet else { return false }
        }

        return isSpanningDAGAcyclic()
    }

    private func rebuildSpanningDAG() {
        var newSpanningChildren: [UInt64: [UInt64]] = [:]
        var visited = Set<UInt64>()
        visited.reserveCapacity(vertices.count)
        var spanningEdgeIDs = Set<UUID>()

        var sortedOutgoing: [UInt64: [ScreenTransitionEdge]] = [:]
        sortedOutgoing.reserveCapacity(outgoingEdges.count)
        for (fromHash, edges) in outgoingEdges {
            sortedOutgoing[fromHash] = edges.sorted { lhs, rhs in
                let lhsExecutable = lhs.action != nil
                let rhsExecutable = rhs.action != nil
                if lhsExecutable != rhsExecutable { return lhsExecutable }
                if lhs.isSpanningTreeEdge != rhs.isSpanningTreeEdge { return lhs.isSpanningTreeEdge }
                if lhs.traversalCount != rhs.traversalCount { return lhs.traversalCount > rhs.traversalCount }
                if lhs.actionSignature != rhs.actionSignature { return lhs.actionSignature < rhs.actionSignature }
                if lhs.toHash != rhs.toHash { return lhs.toHash < rhs.toHash }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }

        func bfsFromComponentRoot(_ startHash: UInt64) {
            guard let startVertex = vertices[startHash], visited.insert(startHash).inserted else { return }
            vertices[startHash] = ScreenStateVertex(
                layoutHash: startVertex.layoutHash,
                activePackage: startVertex.activePackage,
                sampleInteractiveLabels: startVertex.sampleInteractiveLabels,
                semanticTokens: startVertex.semanticTokens,
                firstSeenAt: startVertex.firstSeenAt,
                lastSeenAt: startVertex.lastSeenAt,
                visitCount: startVertex.visitCount,
                discoveryParentHash: nil,
                discoveryDepth: 0
            )

            var componentVisitedOrder: [UInt64] = [startHash]
            var executableQueue: [UInt64] = [startHash]
            var head = 0

            func visitChild(_ v: UInt64, from u: UInt64, via edge: ScreenTransitionEdge) {
                let uDepth = vertices[u]?.discoveryDepth ?? 0
                guard let vVertex = vertices[v] else { return }
                vertices[v] = ScreenStateVertex(
                    layoutHash: vVertex.layoutHash,
                    activePackage: vVertex.activePackage,
                    sampleInteractiveLabels: vVertex.sampleInteractiveLabels,
                    semanticTokens: vVertex.semanticTokens,
                    firstSeenAt: vVertex.firstSeenAt,
                    lastSeenAt: vVertex.lastSeenAt,
                    visitCount: vVertex.visitCount,
                    discoveryParentHash: u,
                    discoveryDepth: uDepth + 1
                )
                newSpanningChildren[u, default: []].append(v)
                spanningEdgeIDs.insert(edge.id)
                componentVisitedOrder.append(v)
                executableQueue.append(v)
            }

            func drainExecutableBFS() {
                while head < executableQueue.count {
                    let u = executableQueue[head]
                    head += 1
                    for edge in sortedOutgoing[u] ?? [] {
                        guard edge.action != nil else { continue }
                        let v = edge.toHash
                        guard v != u, vertices[v] != nil, visited.insert(v).inserted else { continue }
                        visitChild(v, from: u, via: edge)
                    }
                }
            }

            // 1. Exhaust all executable (`action != nil`) paths from `startHash` before traversing
            //    any `action == nil` edges so `findSpanningDAGPath` never gets blocked by shorter implicit edges.
            drainExecutableBFS()

            // 2. Bridge across `action == nil` edges only for vertices unreachable via executable paths,
            //    draining executable descendants immediately after each bridge.
            var implicitScanIndex = 0
            while implicitScanIndex < componentVisitedOrder.count {
                let u = componentVisitedOrder[implicitScanIndex]
                implicitScanIndex += 1
                for edge in sortedOutgoing[u] ?? [] {
                    guard edge.action == nil else { continue }
                    let v = edge.toHash
                    guard v != u, vertices[v] != nil, visited.insert(v).inserted else { continue }
                    visitChild(v, from: u, via: edge)
                    drainExecutableBFS()
                }
            }
        }

        if let root = rootStateHash, vertices[root] != nil {
            bfsFromComponentRoot(root)
        }

        while visited.count < vertices.count {
            var remainingInDegree: [UInt64: Int] = [:]
            for hash in vertices.keys where !visited.contains(hash) {
                remainingInDegree[hash] = 0
            }
            for (fromHash, edges) in sortedOutgoing where !visited.contains(fromHash) {
                for edge in edges where edge.toHash != fromHash && !visited.contains(edge.toHash) {
                    remainingInDegree[edge.toHash, default: 0] += 1
                }
            }

            guard let nextRoot = remainingInDegree.keys.min(by: { lhs, rhs in
                let lhsIn = remainingInDegree[lhs] ?? 0
                let rhsIn = remainingInDegree[rhs] ?? 0
                if (lhsIn == 0) != (rhsIn == 0) { return lhsIn == 0 }
                let lhsV = vertices[lhs]!
                let rhsV = vertices[rhs]!
                if lhsV.firstSeenAt != rhsV.firstSeenAt { return lhsV.firstSeenAt < rhsV.firstSeenAt }
                return lhs < rhs
            }) else {
                break
            }
            bfsFromComponentRoot(nextRoot)
        }

        spanningChildren = newSpanningChildren

        for (fromHash, edges) in outgoingEdges {
            outgoingEdges[fromHash] = edges.map { edge in
                let isSpanning = spanningEdgeIDs.contains(edge.id)
                guard edge.isSpanningTreeEdge != isSpanning else { return edge }
                return ScreenTransitionEdge(
                    id: edge.id,
                    fromHash: edge.fromHash,
                    toHash: edge.toHash,
                    action: edge.action,
                    actionSignature: edge.actionSignature,
                    traversalCount: edge.traversalCount,
                    averageTransitionMs: edge.averageTransitionMs,
                    isSpanningTreeEdge: isSpanning,
                    lastTraversedAt: edge.lastTraversedAt
                )
            }
        }
    }

    public func resolveTargetVertices(matching query: String, limit: Int = 12) -> [RankedVertexMatch] {
        Self.resolveTargetVertices(
            matching: query,
            vertices: vertices.values,
            edges: outgoingEdges.values.joined(),
            limit: limit
        )
    }

    public static func resolveTargetVertices<V: Sequence, E: Sequence>(
        matching query: String,
        vertices: V,
        edges: E,
        limit: Int = 12
    ) -> [RankedVertexMatch] where V.Element == ScreenStateVertex, E.Element == ScreenTransitionEdge {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let q = trimmed.lowercased()
        let normalizedQ = ScreenLayoutHasher.normalizeLabel(trimmed).lowercased()

        // Track incoming executable edges whose action label/selector matches the query
        var incomingScoreBoost: [UInt64: Int] = [:]
        for edge in edges {
            guard let action = edge.action else { continue }
            let candidates = [
                action.targetDescription,
                action.selectorText ?? "",
                action.selectorResourceId ?? "",
                action.selectorContentDesc ?? ""
            ]
            var boost = 0
            for raw in candidates where !raw.isEmpty {
                let lower = raw.lowercased()
                if lower == q {
                    boost = max(boost, 350)
                } else if lower.hasPrefix(q) {
                    boost = max(boost, 200)
                } else if lower.contains(q) {
                    boost = max(boost, 100)
                }
            }
            if boost > 0 {
                incomingScoreBoost[edge.toHash] = max(incomingScoreBoost[edge.toHash] ?? 0, boost)
            }
        }

        var matches: [RankedVertexMatch] = []
        for vertex in vertices {
            var baseScore = 0

            // 1. Active package match
            let pkg = vertex.activePackage.lowercased()
            if pkg == q {
                baseScore = max(baseScore, 1000)
            } else if pkg.hasPrefix(q) {
                baseScore = max(baseScore, 500)
            } else if pkg.contains(q) {
                baseScore = max(baseScore, 220)
            }

            // 2. Sample interactive labels match (outbound clickable/resourceId elements)
            for (idx, label) in vertex.sampleInteractiveLabels.enumerated() where !label.isEmpty {
                let lower = label.lowercased()
                let firstItemBonus = (idx == 0) ? 20 : 0
                if lower == q {
                    baseScore = max(baseScore, 780 + firstItemBonus)
                } else if lower.hasPrefix(q) {
                    baseScore = max(baseScore, 440 + firstItemBonus)
                } else if lower.contains(q) {
                    baseScore = max(baseScore, 190 + firstItemBonus)
                }
            }

            // 3. Semantic tokens match (format: className|resourceId|normalizedLabel)
            for token in vertex.semanticTokens {
                let parts = token.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                let className = parts.count > 0 ? parts[0] : Substring("")
                let resId = parts.count > 1 ? parts[1].lowercased() : ""
                let tokLabel = parts.count > 2 ? parts[2].lowercased() : ""
                let isTextViewTitle = (className == "TextView" || className.hasSuffix(".TextView")) && resId.isEmpty
                let titleBonus = isTextViewTitle ? 60 : 0

                if !tokLabel.isEmpty {
                    if tokLabel == q || (!normalizedQ.isEmpty && tokLabel == normalizedQ) {
                        baseScore = max(baseScore, 800 + titleBonus)
                    } else if tokLabel.hasPrefix(q) || (!normalizedQ.isEmpty && tokLabel.hasPrefix(normalizedQ)) {
                        baseScore = max(baseScore, 420)
                    } else if tokLabel.contains(q) || (!normalizedQ.isEmpty && tokLabel.contains(normalizedQ)) {
                        baseScore = max(baseScore, 160)
                    }
                }

                if !resId.isEmpty {
                    let shortId: String
                    if let range = resId.range(of: ":id/") {
                        shortId = String(resId[range.upperBound...])
                    } else if let slash = resId.lastIndex(of: "/") {
                        shortId = String(resId[resId.index(after: slash)...])
                    } else {
                        shortId = resId
                    }

                    if resId == q || shortId == q {
                        baseScore = max(baseScore, 820)
                    } else if shortId.hasPrefix(q) || resId.hasPrefix(q) {
                        baseScore = max(baseScore, 420)
                    } else if resId.contains(q) {
                        baseScore = max(baseScore, 180)
                    }
                }
            }

            let edgeBoost = incomingScoreBoost[vertex.layoutHash] ?? 0
            let totalScore: Int
            if baseScore > 0 {
                totalScore = baseScore + edgeBoost
            } else if edgeBoost >= 350 {
                totalScore = 600
            } else {
                totalScore = edgeBoost
            }

            if totalScore > 0 {
                matches.append(RankedVertexMatch(vertex: vertex, score: totalScore))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.vertex.visitCount != rhs.vertex.visitCount { return lhs.vertex.visitCount > rhs.vertex.visitCount }
            if lhs.vertex.lastSeenAt != rhs.vertex.lastSeenAt { return lhs.vertex.lastSeenAt > rhs.vertex.lastSeenAt }
            return lhs.vertex.layoutHash < rhs.vertex.layoutHash
        }

        return Array(matches.prefix(max(1, limit)))
    }

    public func reset() {
        rootStateHash = nil
        currentStateHash = nil
        currentFingerprint = nil
        lastStateTransitionAt = nil
        pendingAction = nil
        vertices.removeAll()
        outgoingEdges.removeAll()
        spanningChildren.removeAll()
    }

    private func consumeValidPendingAction(now: Date) -> AttributedUIAction? {
        guard let pending = pendingAction else { return nil }
        pendingAction = nil
        if now.timeIntervalSince(pending.timestamp) <= pendingActionTTL {
            return pending
        }
        return nil
    }

    private func notifyTopologyChanged() {
        topologyRevision &+= 1
        guard let handler = onTopologyChanged else { return }
        Task.detached(priority: .utility) {
            await handler()
        }
    }
}
