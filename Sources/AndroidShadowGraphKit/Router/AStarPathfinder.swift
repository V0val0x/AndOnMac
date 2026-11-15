import Foundation

public struct AStarCostConfiguration: Sendable, Equatable {
    public let minStepCost: Double
    public let latencyWeightPerSecond: Double
    public let maxSteps: Int
    public let maxNodeExpansions: Int

    public init(
        minStepCost: Double = 1.0,
        latencyWeightPerSecond: Double = 0.05,
        maxSteps: Int = 12,
        maxNodeExpansions: Int = 2048
    ) {
        self.minStepCost = max(0.01, minStepCost)
        self.latencyWeightPerSecond = max(0.0, latencyWeightPerSecond)
        self.maxSteps = max(1, maxSteps)
        self.maxNodeExpansions = max(1, maxNodeExpansions)
    }
}

public struct AStarSearchResult: Sendable, Equatable {
    public let startHash: UInt64
    public let targetHash: UInt64
    public let edges: [ScreenTransitionEdge]
    public let totalCost: Double
    public let expandedNodeCount: Int

    public init(
        startHash: UInt64,
        targetHash: UInt64,
        edges: [ScreenTransitionEdge],
        totalCost: Double,
        expandedNodeCount: Int
    ) {
        self.startHash = startHash
        self.targetHash = targetHash
        self.edges = edges
        self.totalCost = totalCost
        self.expandedNodeCount = expandedNodeCount
    }
}

private struct AStarStateKey: Hashable {
    let vertexHash: UInt64
    let hopCount: Int
}

private struct AStarOpenNode {
    let vertexHash: UInt64
    let gScore: Double
    let hScore: Double
    let fScore: Double
    let hopCount: Int

    static func precedes(_ lhs: AStarOpenNode, _ rhs: AStarOpenNode) -> Bool {
        if lhs.fScore != rhs.fScore { return lhs.fScore < rhs.fScore }
        if lhs.hScore != rhs.hScore { return lhs.hScore < rhs.hScore }
        if lhs.hopCount != rhs.hopCount { return lhs.hopCount < rhs.hopCount }
        return lhs.vertexHash < rhs.vertexHash
    }
}

/// Deterministic A* pathfinder over `SpatialGraphSnapshot` using a binary min-heap priority queue
/// and an admissible, consistent Jaccard token-similarity heuristic.
public struct AStarPathfinder: Sendable {
    public let configuration: AStarCostConfiguration

    public init(configuration: AStarCostConfiguration = AStarCostConfiguration()) {
        self.configuration = configuration
    }

    public func findShortestPath(
        from startHash: UInt64,
        to targetHash: UInt64,
        in graph: SpatialGraphSnapshot
    ) -> AStarSearchResult? {
        findShortestPath(from: startHash, toAnyOf: [targetHash], in: graph)
    }

    /// Finds the optimal executable route in the directed multigraph (strictly filtering `action != nil` and self-loops),
    /// supporting multiple candidate goal vertices.
    public func findShortestPath(
        from startHash: UInt64,
        toAnyOf targetHashes: Set<UInt64>,
        in graph: SpatialGraphSnapshot
    ) -> AStarSearchResult? {
        search(
            from: startHash,
            toAnyOf: targetHashes,
            in: graph,
            spanningTreeOnly: false
        )
    }

    /// Fallback search restricted to first-discovery acyclic spanning DAG edges (`isSpanningTreeEdge == true`, `action != nil`).
    public func findSpanningDAGPath(
        from startHash: UInt64,
        to targetHash: UInt64,
        in graph: SpatialGraphSnapshot
    ) -> AStarSearchResult? {
        search(
            from: startHash,
            toAnyOf: [targetHash],
            in: graph,
            spanningTreeOnly: true
        )
    }

    /// Counts how many vertices are reachable from `startHash` using executable (`action != nil`) non-self-loop edges.
    public func reachableExecutableVertexCount(from startHash: UInt64, in graph: SpatialGraphSnapshot) -> Int {
        var outgoing: [UInt64: [UInt64]] = [:]
        for edge in graph.edges {
            guard edge.action != nil, edge.toHash != edge.fromHash else { continue }
            outgoing[edge.fromHash, default: []].append(edge.toHash)
        }
        var visited: Set<UInt64> = [startHash]
        var queue: [UInt64] = [startHash]
        var idx = 0
        while idx < queue.count {
            let current = queue[idx]
            idx += 1
            for next in outgoing[current] ?? [] where visited.insert(next).inserted {
                queue.append(next)
            }
        }
        return visited.count
    }

    // MARK: - Core A* Search

    private func search(
        from startHash: UInt64,
        toAnyOf targetHashes: Set<UInt64>,
        in graph: SpatialGraphSnapshot,
        spanningTreeOnly: Bool
    ) -> AStarSearchResult? {
        guard !targetHashes.isEmpty else { return nil }

        var verticesByHash: [UInt64: ScreenStateVertex] = Dictionary(minimumCapacity: graph.vertices.count)
        for vertex in graph.vertices {
            verticesByHash[vertex.layoutHash] = vertex
        }
        guard verticesByHash[startHash] != nil else { return nil }

        let validTargets = targetHashes.filter { verticesByHash[$0] != nil }
        guard !validTargets.isEmpty else { return nil }

        if validTargets.contains(startHash) {
            return AStarSearchResult(
                startHash: startHash,
                targetHash: startHash,
                edges: [],
                totalCost: 0.0,
                expandedNodeCount: 0
            )
        }

        // Build deterministic adjacency list filtering out unattributed (action == nil) edges and self-loops
        var outgoing: [UInt64: [ScreenTransitionEdge]] = [:]
        for edge in graph.edges {
            guard edge.action != nil, edge.toHash != edge.fromHash else { continue }
            if spanningTreeOnly && !edge.isSpanningTreeEdge { continue }
            outgoing[edge.fromHash, default: []].append(edge)
        }
        for key in outgoing.keys {
            outgoing[key]?.sort { lhs, rhs in
                if lhs.actionSignature != rhs.actionSignature {
                    return lhs.actionSignature < rhs.actionSignature
                }
                if lhs.toHash != rhs.toHash {
                    return lhs.toHash < rhs.toHash
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }

        // Precompute normalized goal descriptors once per search
        let goalDescriptors: [(package: String, tokens: Set<String>)] = validTargets
            .sorted()
            .compactMap { hash in
                guard let vertex = verticesByHash[hash] else { return nil }
                return (vertex.activePackage, Self.effectiveTokens(for: vertex))
            }

        var hCache: [UInt64: Double] = Dictionary(minimumCapacity: min(64, verticesByHash.count))
        func heuristic(_ vertexHash: UInt64) -> Double {
            if validTargets.contains(vertexHash) { return 0.0 }
            if let cached = hCache[vertexHash] { return cached }
            guard let vertex = verticesByHash[vertexHash] else {
                hCache[vertexHash] = configuration.minStepCost
                return configuration.minStepCost
            }
            let uPkg = vertex.activePackage
            let uTokens = Self.effectiveTokens(for: vertex)

            var bestSimilarity = 0.0
            for goal in goalDescriptors where goal.package == uPkg {
                if uTokens.isEmpty && goal.tokens.isEmpty {
                    bestSimilarity = 1.0
                    break
                }
                if uTokens.isEmpty || goal.tokens.isEmpty {
                    continue
                }
                let minCount = min(uTokens.count, goal.tokens.count)
                let maxCount = max(uTokens.count, goal.tokens.count)
                if Double(minCount) / Double(maxCount) <= bestSimilarity {
                    continue
                }
                let sim = ScreenLayoutHasher.jaccardSimilarity(uTokens, goal.tokens)
                if sim > bestSimilarity {
                    bestSimilarity = sim
                    if bestSimilarity >= 1.0 { break }
                }
            }

            let h = (1.0 - bestSimilarity) * configuration.minStepCost
            hCache[vertexHash] = h
            return h
        }

        var openQueue = BinaryHeapPriorityQueue<AStarOpenNode>(sort: AStarOpenNode.precedes)
        openQueue.reserveCapacity(min(128, verticesByHash.count))

        let startKey = AStarStateKey(vertexHash: startHash, hopCount: 0)
        var bestG: [AStarStateKey: Double] = [startKey: 0.0]
        var paretoFront: [UInt64: [(g: Double, hop: Int)]] = [startHash: [(0.0, 0)]]
        var cameFrom: [AStarStateKey: ScreenTransitionEdge] = [:]
        var closed = Set<AStarStateKey>()

        let startH = heuristic(startHash)
        openQueue.push(AStarOpenNode(
            vertexHash: startHash,
            gScore: 0.0,
            hScore: startH,
            fScore: startH,
            hopCount: 0
        ))

        var expandedCount = 0

        while let current = openQueue.popMin() {
            let currentKey = AStarStateKey(vertexHash: current.vertexHash, hopCount: current.hopCount)
            if closed.contains(currentKey) { continue }
            if current.gScore > (bestG[currentKey] ?? .infinity) { continue }

            if validTargets.contains(current.vertexHash) {
                let path = reconstructPath(from: startHash, to: currentKey, cameFrom: cameFrom)
                return AStarSearchResult(
                    startHash: startHash,
                    targetHash: current.vertexHash,
                    edges: path,
                    totalCost: current.gScore,
                    expandedNodeCount: expandedCount
                )
            }

            closed.insert(currentKey)
            guard expandedCount < configuration.maxNodeExpansions else { break }
            expandedCount += 1

            guard current.hopCount < configuration.maxSteps else { continue }
            guard let edges = outgoing[current.vertexHash] else { continue }

            let nextHop = current.hopCount + 1
            for edge in edges {
                let nextHash = edge.toHash
                guard verticesByHash[nextHash] != nil else { continue }

                let nextKey = AStarStateKey(vertexHash: nextHash, hopCount: nextHop)
                if closed.contains(nextKey) { continue }

                let stepCost = edgeCost(edge)
                let tentativeG = current.gScore + stepCost

                let front = paretoFront[nextHash] ?? []
                if front.contains(where: { $0.g <= tentativeG && $0.hop <= nextHop }) {
                    continue
                }

                var updatedFront = front.filter { !(tentativeG <= $0.g && nextHop <= $0.hop) }
                updatedFront.append((tentativeG, nextHop))
                paretoFront[nextHash] = updatedFront

                bestG[nextKey] = tentativeG
                cameFrom[nextKey] = edge
                let h = heuristic(nextHash)
                openQueue.push(AStarOpenNode(
                    vertexHash: nextHash,
                    gScore: tentativeG,
                    hScore: h,
                    fScore: tentativeG + h,
                    hopCount: nextHop
                ))
            }
        }

        return nil
    }

    private func edgeCost(_ edge: ScreenTransitionEdge) -> Double {
        let cappedMs = max(0.0, min(edge.averageTransitionMs, 10_000.0))
        let latencyTerm = configuration.latencyWeightPerSecond * (cappedMs / 1000.0)
        // Slight smoothing preference for battle-tested edges without ever going below minStepCost
        let reliabilityTerm = edge.traversalCount >= 3 ? 0.0 : (0.03 / Double(max(1, edge.traversalCount)))
        return configuration.minStepCost + latencyTerm + reliabilityTerm
    }

    private static func effectiveTokens(for vertex: ScreenStateVertex) -> Set<String> {
        if !vertex.semanticTokens.isEmpty {
            return vertex.semanticTokens
        }
        // Fallback for legacy imported vertices lacking persisted semanticTokens
        var fallback = Set<String>()
        fallback.reserveCapacity(vertex.sampleInteractiveLabels.count + 1)
        if !vertex.activePackage.isEmpty {
            fallback.insert("pkg|\(vertex.activePackage)")
        }
        for label in vertex.sampleInteractiveLabels where !label.isEmpty {
            fallback.insert("lbl|\(ScreenLayoutHasher.normalizeLabel(label))")
        }
        return fallback
    }

    private func reconstructPath(
        from startHash: UInt64,
        to targetKey: AStarStateKey,
        cameFrom: [AStarStateKey: ScreenTransitionEdge]
    ) -> [ScreenTransitionEdge] {
        var reversed: [ScreenTransitionEdge] = []
        var visited = Set<AStarStateKey>()
        var cursor = targetKey
        while !(cursor.vertexHash == startHash && cursor.hopCount == 0), visited.insert(cursor).inserted {
            guard let edge = cameFrom[cursor] else { break }
            reversed.append(edge)
            cursor = AStarStateKey(vertexHash: edge.fromHash, hopCount: cursor.hopCount - 1)
        }
        return reversed.reversed()
    }
}
