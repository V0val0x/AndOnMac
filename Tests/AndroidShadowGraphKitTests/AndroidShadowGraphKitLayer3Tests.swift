import XCTest
@testable import AndroidShadowGraphKit

final class AndroidShadowGraphKitLayer3Tests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        nodeId: Int64,
        index: Int,
        packageName: String = "com.android.settings",
        className: String = "Button",
        resourceId: String = "",
        text: String = "",
        contentDesc: String = "",
        bounds: String? = nil,
        centerX: Int = 100,
        centerY: Int = 200,
        clickable: Bool = true,
        visible: Bool = true
    ) -> ShadowUINode {
        ShadowUINode(
            index: index,
            text: text,
            resourceId: resourceId,
            contentDesc: contentDesc,
            className: className,
            clickable: clickable,
            scrollable: false,
            bounds: bounds ?? "[\(max(0, centerX - 50)),\(max(0, centerY - 25))][\(centerX + 50),\(centerY + 25)]",
            centerX: centerX,
            centerY: centerY,
            nodeId: nodeId,
            parentId: nil,
            windowId: 1,
            childIndex: index,
            depth: 1,
            packageName: packageName,
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: visible
        )
    }

    private func makeSnapshotPayload(
        seq: UInt64,
        package: String,
        nodes: [ShadowUINode]
    ) -> WireMessage {
        .snapshot(WireSnapshotPayload(
            seq: seq,
            timestampMs: Int64(seq * 100),
            reason: "test",
            activePackage: package,
            activeWindowId: 1,
            nodeCount: nodes.count,
            nodes: nodes
        ))
    }

    private func makeUpdate(
        seq: UInt64,
        package: String,
        nodes: [ShadowUINode]
    ) -> ShadowDOMUpdate {
        let index = ShadowTreeIndex(
            seq: seq,
            timestampMs: Int64(seq * 100),
            activePackage: package,
            activeWindowId: 1,
            nodes: nodes
        )
        return ShadowDOMUpdate(
            index: index,
            isFullSnapshot: true,
            insertedCount: nodes.count,
            updatedCount: 0,
            removedCount: 0
        )
    }

    // MARK: - 1. BinaryHeapPriorityQueue Tests

    func testBinaryHeapPriorityQueueOrderingDuplicatesAndStress() {
        var pq = BinaryHeapPriorityQueue<Int>(sort: <)
        XCTAssertTrue(pq.isEmpty)
        XCTAssertEqual(pq.count, 0)
        XCTAssertNil(pq.peek())
        XCTAssertNil(pq.popMin())

        pq.reserveCapacity(64)
        let inputs = [42, 7, 19, 7, 100, 1, 19, 0, -5, 7, 88]
        for val in inputs {
            pq.push(val)
        }
        XCTAssertEqual(pq.count, inputs.count)
        XCTAssertEqual(pq.peek(), -5)

        var popped: [Int] = []
        while let next = pq.popMin() {
            popped.append(next)
        }
        XCTAssertEqual(popped, inputs.sorted())
        XCTAssertTrue(pq.isEmpty)

        // Randomized stress check (500 elements)
        var rng = SystemRandomNumberGenerator()
        var randomValues: [Int] = []
        randomValues.reserveCapacity(500)
        for _ in 0..<500 {
            let v = Int.random(in: -10_000...10_000, using: &rng)
            randomValues.append(v)
            pq.push(v)
        }

        var sortedPopped: [Int] = []
        sortedPopped.reserveCapacity(500)
        while let next = pq.popMin() {
            sortedPopped.append(next)
        }
        XCTAssertEqual(sortedPopped, randomValues.sorted())

        pq.push(1)
        pq.push(2)
        pq.removeAll()
        XCTAssertTrue(pq.isEmpty)
        XCTAssertNil(pq.popMin())
    }

    // MARK: - 2. Backward-Compatible Models & Jaccard Similarity Tests

    func testScreenGraphModelsBackwardCompatibleJSONAndExtendedPayloads() throws {
        // Legacy Layer 2 JSON without semanticTokens or extended AttributedUIAction fields
        let legacyVertexJSON = """
        {
          "layoutHash": 123456789,
          "activePackage": "com.android.settings",
          "sampleInteractiveLabels": ["Display", "Battery"],
          "firstSeenAt": "2026-11-15T12:00:00Z",
          "lastSeenAt": "2026-11-15T12:01:00Z",
          "visitCount": 3,
          "discoveryParentHash": null,
          "discoveryDepth": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedVertex = try decoder.decode(ScreenStateVertex.self, from: Data(legacyVertexJSON.utf8))
        XCTAssertEqual(decodedVertex.layoutHash, 123456789)
        XCTAssertTrue(decodedVertex.semanticTokens.isEmpty)

        let legacyActionJSON = """
        {
          "kind": "tap",
          "targetDescription": "Display",
          "x": 300,
          "y": 500,
          "timestamp": "2026-11-15T12:00:00Z"
        }
        """
        let decodedLegacyAction = try decoder.decode(AttributedUIAction.self, from: Data(legacyActionJSON.utf8))
        XCTAssertNil(decodedLegacyAction.endX)
        XCTAssertNil(decodedLegacyAction.textInput)
        XCTAssertNil(decodedLegacyAction.selectorResourceId)

        // Extended Layer 3 action round-trip
        let fullAction = AttributedUIAction(
            kind: .swipe,
            targetDescription: "up",
            x: 540,
            y: 1700,
            endX: 540,
            endY: 600,
            durationMs: 280,
            textInput: nil,
            pressEnter: nil,
            selectorResourceId: "com.app:id/list",
            selectorText: "Scroll",
            selectorContentDesc: "Scroll list"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(fullAction)
        let roundTripped = try decoder.decode(AttributedUIAction.self, from: encoded)
        XCTAssertEqual(roundTripped.endX, 540)
        XCTAssertEqual(roundTripped.endY, 600)
        XCTAssertEqual(roundTripped.durationMs, 280)
        XCTAssertEqual(roundTripped.selectorResourceId, "com.app:id/list")
        XCTAssertEqual(roundTripped.selectorText, "Scroll")
        XCTAssertEqual(roundTripped.selectorContentDesc, "Scroll list")
    }

    func testJaccardSimilarityEdgeCases() {
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity([], []), 1.0)
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity(["a"], []), 0.0)
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity([], ["a"]), 0.0)
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity(["a", "b"], ["c", "d"]), 0.0)
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity(["a", "b"], ["a", "b"]), 1.0)
        XCTAssertEqual(ScreenLayoutHasher.jaccardSimilarity(["a", "b", "c"], ["b", "c", "d"]), 0.5, accuracy: 0.0001)

        XCTAssertEqual(
            ScreenLayoutHasher.similarity(packageA: "com.a", tokensA: ["x"], packageB: "com.b", tokensB: ["x"]),
            0.0
        )
    }

    // MARK: - 3. SpatialGraphEngine Extensions (tokens, importSnapshot, resolveTargetVertices)

    func testSpatialGraphEngineRetainsTokensImportsSnapshotAndRanksTargets() async throws {
        let engine = SpatialGraphEngine()

        let settingsNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", className: "TextView", text: "Settings", clickable: false),
            makeNode(nodeId: 2, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Connected devices", clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.android.settings", resourceId: "android:id/title", text: "Battery", clickable: true)
        ]
        let connectedNodes = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", className: "TextView", text: "Connected devices", clickable: false),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", resourceId: "com.android.settings:id/pref", text: "Connection preferences", clickable: true),
            makeNode(nodeId: 12, index: 2, packageName: "com.android.settings", resourceId: "com.android.settings:id/pair", text: "Pair new device", clickable: true)
        ]
        let prefsNodes = [
            makeNode(nodeId: 20, index: 0, packageName: "com.android.settings", className: "TextView", text: "Connection preferences", clickable: false),
            makeNode(nodeId: 21, index: 1, packageName: "com.android.settings", resourceId: "com.android.settings:id/bt", text: "Bluetooth", clickable: true),
            makeNode(nodeId: 22, index: 2, packageName: "com.android.settings", resourceId: "com.android.settings:id/nfc", text: "NFC", clickable: true)
        ]

        await engine.process(update: makeUpdate(seq: 1, package: "com.android.settings", nodes: settingsNodes))
        let settingsHash = await engine.currentStateHash!

        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Connected devices", x: 100, y: 200, selectorText: "Connected devices"))
        await engine.process(update: makeUpdate(seq: 2, package: "com.android.settings", nodes: connectedNodes))
        let connectedHash = await engine.currentStateHash!

        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Connection preferences", x: 100, y: 300, selectorText: "Connection preferences"))
        await engine.process(update: makeUpdate(seq: 3, package: "com.android.settings", nodes: prefsNodes))
        let prefsHash = await engine.currentStateHash!

        // Verify semanticTokens were persisted on every vertex
        let prefsVertex = await engine.vertices[prefsHash]
        XCTAssertFalse(prefsVertex?.semanticTokens.isEmpty ?? true)

        // When searching "Connected devices", the actual Connected devices screen must rank strictly #1 above Settings!
        let rankedConnected = await engine.resolveTargetVertices(matching: "Connected devices")
        XCTAssertEqual(rankedConnected.first?.vertex.layoutHash, connectedHash)
        XCTAssertGreaterThan(rankedConnected[0].score, rankedConnected.last?.score ?? 0)

        // Substring/resource-id search
        let rankedBT = await engine.resolveTargetVertices(matching: "Bluetooth")
        XCTAssertEqual(rankedBT.first?.vertex.layoutHash, prefsHash)

        // Snapshot export -> reset -> importSnapshot restores everything
        let exportedSnapshot = await engine.snapshot()
        await engine.reset()
        let countAfterReset = await engine.vertexCount
        XCTAssertEqual(countAfterReset, 0)

        await engine.importSnapshot(exportedSnapshot)
        let countAfterImport = await engine.vertexCount
        let edgeCountAfterImport = await engine.edgeCount
        let restoredCurrent = await engine.currentStateHash
        XCTAssertEqual(countAfterImport, 3)
        XCTAssertEqual(edgeCountAfterImport, 2)
        XCTAssertEqual(restoredCurrent, prefsHash)
        XCTAssertNotEqual(settingsHash, connectedHash)
    }

    // MARK: - 4. AStarPathfinder Tests

    func testAStarPathfinderOptimalRoutingEdgeFilteringMaxStepsAndHeuristicSteering() {
        let now = Date()
        func v(_ hash: UInt64, pkg: String = "com.app", tokens: Set<String> = [], labels: [String] = []) -> ScreenStateVertex {
            ScreenStateVertex(
                layoutHash: hash,
                activePackage: pkg,
                sampleInteractiveLabels: labels,
                semanticTokens: tokens,
                firstSeenAt: now,
                lastSeenAt: now,
                visitCount: 1,
                discoveryParentHash: nil,
                discoveryDepth: 0
            )
        }
        func e(_ from: UInt64, _ to: UInt64, label: String?, ms: Double = 50, count: Int = 3, spanning: Bool = false) -> ScreenTransitionEdge {
            let action = label.map { AttributedUIAction(kind: .tap, targetDescription: $0, x: 100, y: 100) }
            return ScreenTransitionEdge(
                fromHash: from,
                toHash: to,
                action: action,
                actionSignature: action?.signature ?? "implicit",
                traversalCount: count,
                averageTransitionMs: ms,
                isSpanningTreeEdge: spanning,
                lastTraversedAt: now
            )
        }

        // Graph topology:
        // 1 -> 2 (cost ~1.0025) -> 5 (cost ~1.0025) [2 executable hops]
        // 1 -> 3 -> 4 -> 5 [3 executable hops]
        // 1 -> 5 (action == nil, implicit!) [MUST BE FILTERED OUT]
        // 1 -> 1 (self-loop with action) [MUST BE FILTERED OUT]
        let vertices = [
            v(1, tokens: ["a", "b"]),
            v(2, tokens: ["b", "c", "goal"]),
            v(3, tokens: ["d"]),
            v(4, tokens: ["e"]),
            v(5, tokens: ["b", "c", "goal", "target"])
        ]
        let edges = [
            e(1, 5, label: nil, ms: 10),                   // unattributed -> must skip!
            e(1, 1, label: "Refresh", ms: 10),             // self-loop -> must skip!
            e(1, 2, label: "Fast", ms: 50, spanning: true),
            e(2, 5, label: "Finish", ms: 50, spanning: true),
            e(1, 3, label: "Detour", ms: 50),
            e(3, 4, label: "Mid", ms: 50),
            e(4, 5, label: "End", ms: 50)
        ]
        let snapshot = SpatialGraphSnapshot(
            rootStateHash: 1,
            currentStateHash: 1,
            vertices: vertices,
            edges: edges,
            spanningChildren: [1: [2], 2: [5]]
        )

        let pathfinder = AStarPathfinder()
        let result = pathfinder.findShortestPath(from: 1, to: 5, in: snapshot)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.edges.map(\.toHash), [2, 5])
        XCTAssertTrue(result?.edges.allSatisfy { $0.action != nil } == true)

        // maxSteps = 1 must return nil since the 1-hop edge 1->5 has action == nil
        let capped = AStarPathfinder(configuration: AStarCostConfiguration(maxSteps: 1))
            .findShortestPath(from: 1, to: 5, in: snapshot)
        XCTAssertNil(capped)

        // Start == Goal returns empty path with 0 cost
        let already = pathfinder.findShortestPath(from: 5, to: 5, in: snapshot)
        XCTAssertEqual(already?.edges, [])
        XCTAssertEqual(already?.totalCost, 0.0)

        // Spanning DAG path works over spanning edges
        let spanning = pathfinder.findSpanningDAGPath(from: 1, to: 5, in: snapshot)
        XCTAssertEqual(spanning?.edges.map(\.toHash), [2, 5])

        // Heuristic steering test:
        // Branch A (1 -> 10 -> 11) shares tokens with goal 11, Branch B (1 -> 20 -> 21) shares none.
        // Because Branch A shares semantic tokens with the goal (h = 0.25 vs h = 1.0),
        // f(10) = 1.2525 while f(20) = 2.04 -> A* finds 1->10->11 (f=2.005) and never expands 20!
        let treeVertices = [
            v(1, tokens: ["root"]),
            v(10, tokens: ["shared1", "shared2", "shared3"]),
            v(20, tokens: ["unrelated"]),
            v(11, tokens: ["shared1", "shared2", "shared3", "dest"]),
            v(21, tokens: ["deadend"])
        ]
        let treeEdges = [
            e(1, 20, label: "BranchB", ms: 800), // intentionally listed first
            e(20, 21, label: "DeepB", ms: 50),
            e(1, 10, label: "BranchA", ms: 50),
            e(10, 11, label: "Goal", ms: 50)
        ]
        let treeSnap = SpatialGraphSnapshot(rootStateHash: 1, currentStateHash: 1, vertices: treeVertices, edges: treeEdges, spanningChildren: [:])
        let steered = pathfinder.findShortestPath(from: 1, to: 11, in: treeSnap)
        XCTAssertEqual(steered?.edges.map(\.toHash), [10, 11])
        XCTAssertEqual(steered?.expandedNodeCount, 2)
    }

    // MARK: - 5. MacroExecutionEngine Tests

    func testMacroExecutionEngineMultiHopPreSubscribeRaceSelectorRetargetAndSkip() async throws {
        actor MockExecutor: MacroActionExecutor {
            var executedActions: [AttributedUIAction] = []
            private let onExecute: @Sendable (AttributedUIAction) async throws -> Void

            init(onExecute: @escaping @Sendable (AttributedUIAction) async throws -> Void) {
                self.onExecute = onExecute
            }

            func execute(action: AttributedUIAction, serial: String) async throws {
                executedActions.append(action)
                try await onExecute(action)
            }
        }

        let dom = ShadowDOMState()
        let graph = SpatialGraphEngine()
        let hasher = ScreenLayoutHasher()

        let screen0Nodes = [
            makeNode(nodeId: 1, index: 0, resourceId: "com.app:id/btn_settings", text: "Settings", centerX: 200, centerY: 400)
        ]
        let screen1NodesRecorded = [
            makeNode(nodeId: 2, index: 0, resourceId: "com.app:id/btn_display", text: "Display", centerX: 300, centerY: 700)
        ]
        // Live version of screen1 has Display shifted from (300,700) to (340,920) -> same semantic tokens & hash, moved coords!
        let screen1NodesMoved = [
            makeNode(nodeId: 2, index: 0, resourceId: "com.app:id/btn_display", text: "Display", centerX: 340, centerY: 920)
        ]
        let screen2Nodes = [
            makeNode(nodeId: 3, index: 0, resourceId: "com.app:id/brightness", text: "Brightness level", centerX: 500, centerY: 600)
        ]

        let idx0 = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.app", activeWindowId: 1, nodes: screen0Nodes)
        let idx1 = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.app", activeWindowId: 1, nodes: screen1NodesRecorded)
        let idx2 = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.app", activeWindowId: 1, nodes: screen2Nodes)

        let h0 = hasher.fingerprint(for: idx0).layoutHash
        let h1 = hasher.fingerprint(for: idx1).layoutHash
        let h2 = hasher.fingerprint(for: idx2).layoutHash

        await graph.process(update: ShadowDOMUpdate(index: idx0, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await graph.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Settings",
            x: 200,
            y: 400,
            selectorResourceId: "com.app:id/btn_settings",
            selectorText: "Settings"
        ))
        let edge0 = await graph.process(update: ShadowDOMUpdate(index: idx1, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!
        await graph.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Display",
            x: 300,
            y: 700,
            selectorResourceId: "com.app:id/btn_display",
            selectorText: "Display"
        ))
        let edge1 = await graph.process(update: ShadowDOMUpdate(index: idx2, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!

        // Start live ShadowDOM at screen0
        await dom.handleMessage(makeSnapshotPayload(seq: 10, package: "com.app", nodes: screen0Nodes))

        let executor = MockExecutor { action in
            if action.selectorText == "Settings" {
                // Emit screen1 BEFORE execute even returns (tests pre-subscribe race safety!)
                await dom.handleMessage(WireMessage.snapshot(WireSnapshotPayload(
                    seq: 11,
                    timestampMs: 200,
                    reason: "fast",
                    activePackage: "com.app",
                    activeWindowId: 1,
                    nodeCount: 1,
                    nodes: screen1NodesMoved
                )))
            } else if action.selectorText == "Display" {
                // Emit screen2 slightly asynchronously
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000)
                    await dom.handleMessage(WireMessage.snapshot(WireSnapshotPayload(
                        seq: 12,
                        timestampMs: 300,
                        reason: "async",
                        activePackage: "com.app",
                        activeWindowId: 1,
                        nodeCount: 1,
                        nodes: screen2Nodes
                    )))
                }
            }
        }

        let engine = MacroExecutionEngine(
            domState: dom,
            graphEngine: graph,
            executor: executor,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 1000, postSettleQuiescenceMs: 5)
        )

        let report = try await engine.execute(path: [edge0, edge1], serial: "MOCK-SERIAL")
        XCTAssertEqual(report.startHash, h0)
        XCTAssertEqual(report.finalHash, h2)
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertTrue(report.steps[0].matchedByExactHash)
        XCTAssertTrue(report.steps[1].matchedByExactHash)

        // Verify live selector re-targeting used (340, 920) instead of stale (300, 700)
        let dispatched = await executor.executedActions
        XCTAssertEqual(dispatched.count, 2)
        XCTAssertEqual(dispatched[1].x, 340)
        XCTAssertEqual(dispatched[1].y, 920)

        // Step-skipping check: if we pass a path whose edge0.toHash == current state (h2), edge0 is skipped
        let skipEdge = ScreenTransitionEdge(
            fromHash: h2,
            toHash: h2,
            action: AttributedUIAction(kind: .tap, targetDescription: "NoOp", x: 1, y: 1),
            actionSignature: "tap:NoOp"
        )
        let skipReport = try await engine.execute(path: [skipEdge], serial: "MOCK-SERIAL")
        XCTAssertEqual(skipReport.steps.first?.wasSkipped, true)
        let countAfterSkip = await executor.executedActions.count
        XCTAssertEqual(countAfterSkip, 2)
        XCTAssertNotEqual(h1, h2)
    }

    func testMacroExecutionEngineTimeoutThrowsPathDeviationAndDoesNotLockActor() async throws {
        struct UnresponsiveExecutor: MacroActionExecutor {
            func execute(action: AttributedUIAction, serial: String) async throws {
                // Intentionally emits wrong/popup screen instead of expected target
            }
        }

        let dom = ShadowDOMState()
        let graph = SpatialGraphEngine()
        let hasher = ScreenLayoutHasher()

        let startNodes = [makeNode(nodeId: 1, index: 0, text: "Home")]
        let targetNodes = [makeNode(nodeId: 2, index: 0, text: "Target")]
        let popupNodes = [makeNode(nodeId: 9, index: 0, packageName: "com.popup", text: "Unexpected Popup")]

        let startIdx = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.app", activeWindowId: 1, nodes: startNodes)
        let targetIdx = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.app", activeWindowId: 1, nodes: targetNodes)

        let startHash = hasher.fingerprint(for: startIdx).layoutHash
        let targetHash = hasher.fingerprint(for: targetIdx).layoutHash

        await graph.process(update: ShadowDOMUpdate(index: startIdx, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await graph.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Go", x: 100, y: 200))
        let edge = await graph.process(update: ShadowDOMUpdate(index: targetIdx, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!

        // Seed live DOM at start screen
        await dom.handleMessage(makeSnapshotPayload(seq: 1, package: "com.app", nodes: startNodes))

        // Emit popup asynchronously while waiting
        Task {
            try? await Task.sleep(nanoseconds: 25_000_000)
            await dom.handleMessage(makeSnapshotPayload(seq: 2, package: "com.popup", nodes: popupNodes))
        }

        let engine = MacroExecutionEngine(
            domState: dom,
            graphEngine: graph,
            executor: UnresponsiveExecutor(),
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 120, postSettleQuiescenceMs: 0)
        )

        let t0 = ContinuousClock.now
        do {
            _ = try await engine.execute(path: [edge], serial: "MOCK")
            XCTFail("Expected PathDeviationError.stepTimeout")
        } catch let error as PathDeviationError {
            guard case .stepTimeout(let stepIndex, let expected, let observedHash, let observedPkg, let timeoutMs) = error else {
                return XCTFail("Expected .stepTimeout, got \(error)")
            }
            XCTAssertEqual(stepIndex, 0)
            XCTAssertEqual(expected, targetHash)
            XCTAssertNotNil(observedHash)
            XCTAssertEqual(observedPkg, "com.popup")
            XCTAssertEqual(timeoutMs, 120)
        }
        let elapsed = ContinuousClock.now - t0
        XCTAssertLessThan(elapsed, .milliseconds(1000))

        // Crucial resilience check: actor MUST NOT be locked after timeout; a subsequent empty-path or valid execution succeeds!
        await dom.handleMessage(makeSnapshotPayload(seq: 3, package: "com.app", nodes: startNodes))
        let recoveryReport = try await engine.execute(path: [], serial: "MOCK")
        XCTAssertEqual(recoveryReport.startHash, startHash)
    }

    func testMacroExecutionEngineErrorPathsAndConcurrencyGuard() async throws {
        actor SlowExecutor: MacroActionExecutor {
            func execute(action: AttributedUIAction, serial: String) async throws {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        let dom = ShadowDOMState()
        let graph = SpatialGraphEngine()
        let engine = MacroExecutionEngine(
            domState: dom,
            graphEngine: graph,
            executor: SlowExecutor(),
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 500, postSettleQuiescenceMs: 0)
        )

        // 1. shadowStreamUnavailable when no snapshot exists
        do {
            _ = try await engine.execute(path: [], serial: "MOCK")
            XCTFail("Expected shadowStreamUnavailable")
        } catch let err as PathDeviationError {
            XCTAssertEqual(err, .shadowStreamUnavailable)
        }

        // 2. unexpectedStartState
        let aNodes = [makeNode(nodeId: 1, index: 0, text: "ScreenA")]
        await dom.handleMessage(makeSnapshotPayload(seq: 1, package: "com.app", nodes: aNodes))
        let badEdge = ScreenTransitionEdge(
            fromHash: 999_999,
            toHash: 888_888,
            action: AttributedUIAction(kind: .tap, targetDescription: "Tap", x: 10, y: 20),
            actionSignature: "tap:Tap"
        )
        do {
            _ = try await engine.execute(path: [badEdge], serial: "MOCK")
            XCTFail("Expected unexpectedStartState")
        } catch let err as PathDeviationError {
            guard case .unexpectedStartState(let expected, _, let pkg) = err else {
                return XCTFail("Expected unexpectedStartState, got \(err)")
            }
            XCTAssertEqual(expected, 999_999)
            XCTAssertEqual(pkg, "com.app")
        }

        // 3. missingActionPayload
        let actualHash = ScreenLayoutHasher().fingerprint(for: await dom.currentIndex!).layoutHash
        let implicitEdge = ScreenTransitionEdge(
            fromHash: actualHash,
            toHash: 777_777,
            action: nil,
            actionSignature: "implicit"
        )
        do {
            _ = try await engine.execute(path: [implicitEdge], serial: "MOCK")
            XCTFail("Expected missingActionPayload")
        } catch let err as PathDeviationError {
            XCTAssertEqual(err, .missingActionPayload(stepIndex: 0, edgeId: implicitEdge.id))
        }

        // 4. Concurrent execution throws executionAlreadyInProgress without corrupting first run
        let validEdge = ScreenTransitionEdge(
            fromHash: actualHash,
            toHash: 777_777,
            action: AttributedUIAction(kind: .tap, targetDescription: "Next", x: 10, y: 20),
            actionSignature: "tap:Next"
        )
        let firstTask = Task {
            try? await engine.execute(path: [validEdge], serial: "MOCK")
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        do {
            _ = try await engine.execute(path: [validEdge], serial: "MOCK")
            XCTFail("Expected executionAlreadyInProgress")
        } catch let err as PathDeviationError {
            XCTAssertEqual(err, .executionAlreadyInProgress)
        }
        _ = await firstTask.value
    }

    // MARK: - 6. ShadowGraphBridge routeAndExecute End-to-End Test

    func testShadowGraphBridgeRouteAndExecuteOutcomes() async throws {
        let bridge = ShadowGraphBridge()
        let s1Nodes = [makeNode(nodeId: 1, index: 0, text: "Launcher")]
        let s2Nodes = [makeNode(nodeId: 2, index: 0, packageName: "com.android.settings", text: "Display")]

        struct BridgeMockExecutor: MacroActionExecutor {
            let bridge: ShadowGraphBridge
            let destNodes: [ShadowUINode]
            func execute(action: AttributedUIAction, serial: String) async throws {
                await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                    seq: 20,
                    timestampMs: 500,
                    reason: "nav",
                    activePackage: "com.android.settings",
                    activeWindowId: 1,
                    nodeCount: destNodes.count,
                    nodes: destNodes
                )))
            }
        }

        // Unconnected / no snapshot -> streamUnavailable
        let unavail = try await bridge.routeAndExecute(
            targetHint: "Display",
            serial: "MOCK",
            executor: BridgeMockExecutor(bridge: bridge, destNodes: s2Nodes)
        )
        XCTAssertEqual(unavail, .streamUnavailable)

        // Seed graph with s1 -> s2
        await bridge.graphEngine.process(update: makeUpdate(seq: 1, package: "com.launcher", nodes: s1Nodes))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Display", x: 100, y: 200))
        await bridge.graphEngine.process(update: makeUpdate(seq: 2, package: "com.android.settings", nodes: s2Nodes))

        // Seed live DOM back at s1
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.launcher", nodes: s1Nodes))

        // Unknown target -> targetNotFound
        let notFound = try await bridge.routeAndExecute(
            targetHint: "NonExistentScreen",
            serial: "MOCK",
            executor: BridgeMockExecutor(bridge: bridge, destNodes: s2Nodes)
        )
        guard case .targetNotFound(let query, let knownCount) = notFound else {
            return XCTFail("Expected .targetNotFound, got \(notFound)")
        }
        XCTAssertEqual(query, "NonExistentScreen")
        XCTAssertEqual(knownCount, 2)

        // Valid route -> arrived
        let arrived = try await bridge.routeAndExecute(
            targetHint: "Display",
            serial: "MOCK",
            executor: BridgeMockExecutor(bridge: bridge, destNodes: s2Nodes),
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report) = arrived else {
            return XCTFail("Expected .arrived, got \(arrived)")
        }
        XCTAssertEqual(report.steps.count, 1)

        // Already on Display -> alreadyAtTarget
        let already = try await bridge.routeAndExecute(
            targetHint: "Display",
            serial: "MOCK",
            executor: BridgeMockExecutor(bridge: bridge, destNodes: s2Nodes)
        )
        guard case .alreadyAtTarget(_, let pkg) = already else {
            return XCTFail("Expected .alreadyAtTarget, got \(already)")
        }
        XCTAssertEqual(pkg, "com.android.settings")

        // No route back from Display to Launcher (only 1-way edge recorded) -> noRoute
        let noRoute = try await bridge.routeAndExecute(
            targetHint: "Launcher",
            serial: "MOCK",
            executor: BridgeMockExecutor(bridge: bridge, destNodes: s1Nodes)
        )
        guard case .noRoute(_, _, let candidates, let reachable, let known) = noRoute else {
            return XCTFail("Expected .noRoute, got \(noRoute)")
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(reachable, 1)
        XCTAssertEqual(known, 2)
    }

    // MARK: - 7. Regression Tests (Shared ViewHolder IDs, Ranking Without Edge Boost, Tight maxSteps)

    func testMacroExecutionEngineSharedRecyclerViewResourceIdResolvesCorrectRowAndUniqueIdHealsDynamicText() async throws {
        actor CaptureExecutor: MacroActionExecutor {
            var actions: [AttributedUIAction] = []
            private let handler: @Sendable (AttributedUIAction) async -> Void
            init(handler: @escaping @Sendable (AttributedUIAction) async -> Void) { self.handler = handler }
            func execute(action: AttributedUIAction, serial: String) async throws {
                actions.append(action)
                await handler(action)
            }
        }

        let dom = ShadowDOMState()
        let graph = SpatialGraphEngine()

        // Settings-like list where MULTIPLE rows share "android:id/title"
        let settingsLive = [
            makeNode(nodeId: 1, index: 0, resourceId: "android:id/title", text: "Google", centerX: 400, centerY: 500, clickable: false),
            makeNode(nodeId: 2, index: 1, resourceId: "android:id/title", text: "Network & internet", centerX: 400, centerY: 700, clickable: false),
            makeNode(nodeId: 3, index: 2, resourceId: "android:id/title", text: "Connected devices", centerX: 400, centerY: 980, clickable: false)
        ]
        let connectedLive = [
            makeNode(nodeId: 10, index: 0, className: "TextView", resourceId: "", text: "Connected devices", centerX: 300, centerY: 200, clickable: false),
            // Unique resourceId whose text dynamically changed from "Battery 85%" to "Battery 84%"
            makeNode(nodeId: 11, index: 1, resourceId: "com.android.settings:id/unique_batt", text: "Battery 84%", centerX: 520, centerY: 1150, clickable: true)
        ]
        let batteryLive = [
            makeNode(nodeId: 20, index: 0, className: "TextView", resourceId: "", text: "Battery usage", centerX: 300, centerY: 200, clickable: false)
        ]

        let idx0 = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.android.settings", activeWindowId: 1, nodes: settingsLive)
        let idx1 = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: connectedLive)
        let idx2 = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.android.settings", activeWindowId: 1, nodes: batteryLive)

        await graph.process(update: ShadowDOMUpdate(index: idx0, isFullSnapshot: true, insertedCount: 3, updatedCount: 0, removedCount: 0))
        await graph.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Connected devices",
            x: 400,
            y: 940, // shifted slightly from 980
            selectorResourceId: "android:id/title",
            selectorText: "Connected devices"
        ))
        let edge0 = await graph.process(update: ShadowDOMUpdate(index: idx1, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))!

        await graph.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Battery 85%",
            x: 500,
            y: 1100,
            selectorResourceId: "com.android.settings:id/unique_batt",
            selectorText: "Battery 85%"
        ))
        let edge1 = await graph.process(update: ShadowDOMUpdate(index: idx2, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!

        await dom.handleMessage(makeSnapshotPayload(seq: 10, package: "com.android.settings", nodes: settingsLive))

        let exec = CaptureExecutor { action in
            if action.x == 400 && action.y == 980 {
                await dom.handleMessage(self.makeSnapshotPayload(seq: 11, package: "com.android.settings", nodes: connectedLive))
            } else if action.x == 520 && action.y == 1150 {
                await dom.handleMessage(self.makeSnapshotPayload(seq: 12, package: "com.android.settings", nodes: batteryLive))
            }
        }

        let engine = MacroExecutionEngine(
            domState: dom,
            graphEngine: graph,
            executor: exec,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 500, postSettleQuiescenceMs: 5)
        )
        let report = try await engine.execute(path: [edge0, edge1], serial: "MOCK")
        XCTAssertEqual(report.steps.count, 2)
        let captured = await exec.actions
        XCTAssertEqual(captured[0].x, 400)
        XCTAssertEqual(captured[0].y, 980, "Must tap Connected devices (400,980), NOT Google (400,500) sharing android:id/title")
        XCTAssertEqual(captured[1].x, 520)
        XCTAssertEqual(captured[1].y, 1150, "Unique resourceId must still heal dynamic text changes")
    }

    func testResolveTargetVerticesPrefersDestinationTitleOverSourceButtonEvenWithoutEdgeLabelBoost() async {
        let engine = SpatialGraphEngine()
        let settingsNodes = [
            makeNode(nodeId: 1, index: 0, resourceId: "android:id/title", text: "Connected devices", clickable: false)
        ]
        let connectedNodes = [
            makeNode(nodeId: 10, index: 0, className: "TextView", resourceId: "", text: "Connected devices", clickable: false),
            makeNode(nodeId: 11, index: 1, resourceId: "android:id/title", text: "Pair new device", clickable: false)
        ]
        await engine.process(update: makeUpdate(seq: 1, package: "com.android.settings", nodes: settingsNodes))
        // Recorded by raw coordinates (no label on the edge!)
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "(100,200)", x: 100, y: 200))
        await engine.process(update: makeUpdate(seq: 2, package: "com.android.settings", nodes: connectedNodes))
        let connectedHash = await engine.currentStateHash!

        let ranked = await engine.resolveTargetVertices(matching: "Connected devices")
        XCTAssertEqual(ranked.first?.vertex.layoutHash, connectedHash)
    }

    func testAStarPathfinderTightMaxStepsDoesNotPruneValidShorterHopPathThroughCheaperLongerHopIntermediate() {
        let now = Date()
        func v(_ hash: UInt64) -> ScreenStateVertex {
            ScreenStateVertex(
                layoutHash: hash,
                activePackage: "com.app",
                sampleInteractiveLabels: [],
                semanticTokens: ["t\(hash)"],
                firstSeenAt: now,
                lastSeenAt: now,
                visitCount: 1,
                discoveryParentHash: nil,
                discoveryDepth: 0
            )
        }
        func e(_ from: UInt64, _ to: UInt64, ms: Double) -> ScreenTransitionEdge {
            ScreenTransitionEdge(
                fromHash: from,
                toHash: to,
                action: AttributedUIAction(kind: .tap, targetDescription: "\(from)->\(to)", x: 10, y: 10),
                actionSignature: "tap:\(from)->\(to)",
                traversalCount: 3,
                averageTransitionMs: ms,
                isSpanningTreeEdge: false,
                lastTraversedAt: now
            )
        }

        // Start=1, Goal=6, maxSteps=3.
        // 1->2->3->4 reaches node 4 in 3 hops at g=3.00 (cannot continue to 6 because hop==maxSteps).
        // 1->5->4 reaches node 4 in 2 hops at g=3.02 (slow 1000ms edges), which CAN continue 4->6 in 3 total hops!
        let snapshot = SpatialGraphSnapshot(
            rootStateHash: 1,
            currentStateHash: 1,
            vertices: [v(1), v(2), v(3), v(4), v(5), v(6)],
            edges: [
                e(1, 2, ms: 0), e(2, 3, ms: 0), e(3, 4, ms: 0),
                e(1, 5, ms: 2000), e(5, 4, ms: 2000),
                e(4, 6, ms: 0)
            ],
            spanningChildren: [:]
        )

        let pathfinder = AStarPathfinder(configuration: AStarCostConfiguration(maxSteps: 3))
        let result = pathfinder.findShortestPath(from: 1, to: 6, in: snapshot)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.edges.map(\.toHash), [5, 4, 6])
    }

    func testShadowGraphBridgeToleratesDynamicScreenDriftDuringSettleAndStartAliasing() async throws {
        let bridge = ShadowGraphBridge()
        let settingsNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", text: "Settings"),
            makeNode(nodeId: 2, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Connected devices", centerX: 400, centerY: 1100, clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.android.settings", resourceId: "android:id/title", text: "Apps", centerX: 400, centerY: 1300, clickable: true)
        ]
        // Original recorded Connected devices screen (8 static items)
        let connectedRecorded = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", text: "Connected devices"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", text: "Other devices"),
            makeNode(nodeId: 12, index: 2, packageName: "com.android.settings", text: "USB"),
            makeNode(nodeId: 13, index: 3, packageName: "com.android.settings", text: "File transfer"),
            makeNode(nodeId: 14, index: 4, packageName: "com.android.settings", text: "Pair new device"),
            makeNode(nodeId: 15, index: 5, packageName: "com.android.settings", text: "Saved devices"),
            makeNode(nodeId: 16, index: 6, packageName: "com.android.settings", text: "OnePlus Buds Pro 2"),
            makeNode(nodeId: 17, index: 7, packageName: "com.android.settings", resourceId: "android:id/title", text: "Connection preferences", centerX: 327, centerY: 1900, clickable: true)
        ]
        // Live drifted Connected devices screen: 1 dynamic Bluetooth device ("MacBook Pro") appeared, shifting layoutHash!
        let connectedDrifted = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", text: "Connected devices"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", text: "Other devices"),
            makeNode(nodeId: 99, index: 2, packageName: "com.android.settings", text: "MacBook Pro"),
            makeNode(nodeId: 12, index: 3, packageName: "com.android.settings", text: "USB"),
            makeNode(nodeId: 13, index: 4, packageName: "com.android.settings", text: "File transfer"),
            makeNode(nodeId: 14, index: 5, packageName: "com.android.settings", text: "Pair new device"),
            makeNode(nodeId: 15, index: 6, packageName: "com.android.settings", text: "Saved devices"),
            makeNode(nodeId: 16, index: 7, packageName: "com.android.settings", text: "OnePlus Buds Pro 2"),
            makeNode(nodeId: 17, index: 8, packageName: "com.android.settings", resourceId: "android:id/title", text: "Connection preferences", centerX: 327, centerY: 2050, clickable: true)
        ]
        let prefsNodes = [
            makeNode(nodeId: 30, index: 0, packageName: "com.android.settings", text: "Connection preferences"),
            makeNode(nodeId: 31, index: 1, packageName: "com.android.settings", text: "Bluetooth")
        ]

        // Record Settings -> Connected devices (original) -> Connection preferences
        await bridge.graphEngine.process(update: makeUpdate(seq: 1, package: "com.android.settings", nodes: settingsNodes))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Connected devices",
            x: 400,
            y: 1100,
            selectorResourceId: "android:id/title",
            selectorText: "Connected devices"
        ))
        await bridge.graphEngine.process(update: makeUpdate(seq: 2, package: "com.android.settings", nodes: connectedRecorded))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Connection preferences",
            x: 327,
            y: 1900,
            selectorResourceId: "android:id/title",
            selectorText: "Connection preferences"
        ))
        await bridge.graphEngine.process(update: makeUpdate(seq: 3, package: "com.android.settings", nodes: prefsNodes))

        struct DriftMockExecutor: MacroActionExecutor {
            let bridge: ShadowGraphBridge
            let connectedDrifted: [ShadowUINode]
            let prefsNodes: [ShadowUINode]
            func execute(action: AttributedUIAction, serial: String) async throws {
                if action.selectorText == "Connected devices" {
                    let payload = WireSnapshotPayload(
                        seq: 20, timestampMs: 200, reason: "nav", activePackage: "com.android.settings",
                        activeWindowId: 1, nodeCount: connectedDrifted.count, nodes: connectedDrifted
                    )
                    await bridge.domState.handleMessage(WireMessage.snapshot(payload))
                    let idx = ShadowTreeIndex(seq: 20, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: connectedDrifted)
                    await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx, isFullSnapshot: true, insertedCount: connectedDrifted.count, updatedCount: 0, removedCount: 0))
                } else if action.selectorText == "Connection preferences" {
                    let payload = WireSnapshotPayload(
                        seq: 21, timestampMs: 300, reason: "nav", activePackage: "com.android.settings",
                        activeWindowId: 1, nodeCount: prefsNodes.count, nodes: prefsNodes
                    )
                    await bridge.domState.handleMessage(WireMessage.snapshot(payload))
                    let idx = ShadowTreeIndex(seq: 21, timestampMs: 300, activePackage: "com.android.settings", activeWindowId: 1, nodes: prefsNodes)
                    await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx, isFullSnapshot: true, insertedCount: prefsNodes.count, updatedCount: 0, removedCount: 0))
                }
            }
        }

        // Start back on Settings homepage; step 0 lands on connectedDrifted (new hash, >=0.85 Jaccard), step 1 still completes!
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.android.settings", nodes: settingsNodes))
        let outcome = try await bridge.routeAndExecute(
            targetHint: "Connection preferences",
            serial: "MOCK",
            executor: DriftMockExecutor(bridge: bridge, connectedDrifted: connectedDrifted, prefsNodes: prefsNodes),
            stepTimeoutMs: 1000,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived despite dynamic list drift, got \(outcome)")
        }
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertFalse(report.steps[0].matchedByExactHash)
        XCTAssertTrue(report.steps[1].matchedByExactHash)

        // Now start on a SECOND drifted variant ("Pixel Buds" appeared, brand-new vertex with NO outgoing edges of its own) -> semantic alias routes to Connection preferences!
        let connectedDriftedVariant2 = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", text: "Connected devices"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", text: "Other devices"),
            makeNode(nodeId: 98, index: 2, packageName: "com.android.settings", text: "Pixel Buds"),
            makeNode(nodeId: 12, index: 3, packageName: "com.android.settings", text: "USB"),
            makeNode(nodeId: 13, index: 4, packageName: "com.android.settings", text: "File transfer"),
            makeNode(nodeId: 14, index: 5, packageName: "com.android.settings", text: "Pair new device"),
            makeNode(nodeId: 15, index: 6, packageName: "com.android.settings", text: "Saved devices"),
            makeNode(nodeId: 16, index: 7, packageName: "com.android.settings", text: "OnePlus Buds Pro 2"),
            makeNode(nodeId: 17, index: 8, packageName: "com.android.settings", resourceId: "android:id/title", text: "Connection preferences", centerX: 327, centerY: 2050, clickable: true)
        ]
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 30, package: "com.android.settings", nodes: connectedDriftedVariant2))
        let aliasOutcome = try await bridge.routeAndExecute(
            targetHint: "Connection preferences",
            serial: "MOCK",
            executor: DriftMockExecutor(bridge: bridge, connectedDrifted: connectedDrifted, prefsNodes: prefsNodes),
            stepTimeoutMs: 1000,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let aliasReport) = aliasOutcome else {
            return XCTFail("Expected semantic start-vertex aliasing to succeed, got \(aliasOutcome)")
        }
        XCTAssertEqual(aliasReport.steps.count, 1)
    }

    // MARK: - 10. MacroExecutionEngine & ShadowGraphBridge Event Stream Tests

    func testMacroExecutionEngineAndBridgeEmitHUDTelemetryEvents() async throws {
        let bridge = ShadowGraphBridge()
        let screenA = [
            makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", text: "Settings"),
            makeNode(nodeId: 2, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Battery", centerX: 540, centerY: 900, clickable: true)
        ]
        let screenB = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", text: "Battery"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Battery Share", centerX: 540, centerY: 1450, clickable: true)
        ]
        let screenC = [
            makeNode(nodeId: 20, index: 0, packageName: "com.android.settings", text: "Battery Share"),
            makeNode(nodeId: 21, index: 1, packageName: "com.android.settings", text: "Use Battery Share")
        ]

        await bridge.graphEngine.process(update: makeUpdate(seq: 1, package: "com.android.settings", nodes: screenA))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Battery",
            x: 540,
            y: 900,
            selectorResourceId: "android:id/title",
            selectorText: "Battery"
        ))
        await bridge.graphEngine.process(update: makeUpdate(seq: 2, package: "com.android.settings", nodes: screenB))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Battery Share",
            x: 540,
            y: 1450,
            selectorResourceId: "android:id/title",
            selectorText: "Battery Share"
        ))
        await bridge.graphEngine.process(update: makeUpdate(seq: 3, package: "com.android.settings", nodes: screenC))

        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.android.settings", nodes: screenA))

        let eventStream = bridge.macroExecutionEvents
        actor EventRecorder {
            var events: [MacroExecutionEvent] = []
            func append(_ event: MacroExecutionEvent) { events.append(event) }
            func snapshot() -> [MacroExecutionEvent] { events }
        }
        let recorder = EventRecorder()
        let listenerTask = Task {
            for await event in eventStream {
                await recorder.append(event)
                if case .completed = event { break }
                if case .failed = event { break }
            }
        }
        // Yield briefly so listener task begins awaiting the stream before routeAndExecute emits
        await Task.yield()

        struct TelemetryMockExecutor: MacroActionExecutor {
            let bridge: ShadowGraphBridge
            let screenB: [ShadowUINode]
            let screenC: [ShadowUINode]
            func execute(action: AttributedUIAction, serial: String) async throws {
                let targetNodes = (action.selectorText == "Battery") ? screenB : screenC
                let nextSeq: UInt64 = (action.selectorText == "Battery") ? 11 : 12
                let payload = WireSnapshotPayload(
                    seq: nextSeq,
                    timestampMs: Int64(nextSeq * 100),
                    reason: "nav",
                    activePackage: "com.android.settings",
                    activeWindowId: 1,
                    nodeCount: targetNodes.count,
                    nodes: targetNodes
                )
                await bridge.domState.handleMessage(.snapshot(payload))
            }
        }

        let outcome = try await bridge.routeAndExecute(
            targetHint: "Battery Share",
            serial: "61061JEA307110",
            executor: TelemetryMockExecutor(bridge: bridge, screenB: screenB, screenC: screenC),
            stepTimeoutMs: 1000,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report) = outcome else {
            listenerTask.cancel()
            return XCTFail("Expected .arrived, got \(outcome)")
        }
        XCTAssertEqual(report.steps.count, 2)

        await listenerTask.value
        let events = await recorder.snapshot()

        XCTAssertTrue(events.contains(.pathComputed(totalSteps: 2, targetHint: "Battery Share")))
        XCTAssertTrue(events.contains(.executionStarted(totalSteps: 2)))
        let actionSteps = events.compactMap { event -> (Int, Int, Int?)? in
            if case .willExecuteAction(let idx, let total, let action) = event {
                return (idx, total, action.y)
            }
            return nil
        }
        XCTAssertEqual(actionSteps.count, 2)
        XCTAssertEqual(actionSteps[0].0, 0)
        XCTAssertEqual(actionSteps[0].2, 900)
        XCTAssertEqual(actionSteps[1].0, 1)
        XCTAssertEqual(actionSteps[1].2, 1450)
        XCTAssertEqual(events.last, .completed(report: report))
    }

    func testMacroExecutionEngineDirectStreamEmitsFailedOnTimeout() async throws {
        let domState = ShadowDOMState()
        let graphEngine = SpatialGraphEngine()
        let screenA = [makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", text: "Screen A")]
        let screenB = [makeNode(nodeId: 2, index: 0, packageName: "com.android.settings", text: "Screen B")]

        await domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.android.settings", nodes: screenA))
        let fpA = ScreenLayoutHasher().fingerprint(for: await domState.currentIndex!)
        let idxB = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: screenB)
        let fpB = ScreenLayoutHasher().fingerprint(for: idxB)

        struct NoOpExecutor: MacroActionExecutor {
            func execute(action: AttributedUIAction, serial: String) async throws {}
        }

        let engine = MacroExecutionEngine(
            domState: domState,
            graphEngine: graphEngine,
            executor: NoOpExecutor(),
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 80, postSettleQuiescenceMs: 0)
        )
        let stream = await engine.events
        actor EventBox {
            var events: [MacroExecutionEvent] = []
            func append(_ e: MacroExecutionEvent) { events.append(e) }
            func all() -> [MacroExecutionEvent] { events }
        }
        let box = EventBox()
        let consumer = Task {
            for await event in stream {
                await box.append(event)
                if case .failed = event { break }
            }
        }
        await Task.yield()

        let edge = ScreenTransitionEdge(
            fromHash: fpA.layoutHash,
            toHash: fpB.layoutHash,
            action: AttributedUIAction(kind: .tap, targetDescription: "Next", x: 100, y: 200),
            actionSignature: "tap:Next"
        )

        do {
            _ = try await engine.execute(path: [edge], serial: "MOCK")
            XCTFail("Expected stepTimeout error")
        } catch PathDeviationError.stepTimeout {
            // Expected
        }

        await consumer.value
        let collected = await box.all()
        XCTAssertTrue(collected.contains(.executionStarted(totalSteps: 1)))
        XCTAssertTrue(collected.contains { event in
            if case .failed = event { return true }
            return false
        })
    }

    func testShadowTreeIndexResolveNodeAndAttributedTapAction() {
        let bg = ShadowUINode(
            index: 0,
            text: "",
            resourceId: "android:id/content",
            contentDesc: "",
            className: "android.widget.FrameLayout",
            clickable: false,
            scrollable: false,
            bounds: "[0,0][1080,2424]",
            centerX: 540,
            centerY: 1212,
            nodeId: 1,
            parentId: nil,
            windowId: 1,
            childIndex: 0,
            depth: 0,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        let row = ShadowUINode(
            index: 1,
            text: "",
            resourceId: "",
            contentDesc: "",
            className: "android.widget.LinearLayout",
            clickable: true,
            scrollable: false,
            bounds: "[0,300][1080,480]",
            centerX: 540,
            centerY: 390,
            nodeId: 10,
            parentId: 1,
            windowId: 1,
            childIndex: 0,
            depth: 1,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        let title = ShadowUINode(
            index: 2,
            text: "Display & touch",
            resourceId: "android:id/title",
            contentDesc: "",
            className: "android.widget.TextView",
            clickable: false,
            scrollable: false,
            bounds: "[60,340][500,420]",
            centerX: 280,
            centerY: 380,
            nodeId: 11,
            parentId: 10,
            windowId: 1,
            childIndex: 0,
            depth: 2,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        let offscreen = ShadowUINode(
            index: 3,
            text: "Offscreen",
            resourceId: "",
            contentDesc: "",
            className: "android.widget.TextView",
            clickable: true,
            scrollable: false,
            bounds: "[-50,10][80,80]",
            centerX: 15,
            centerY: 45,
            nodeId: 12,
            parentId: 1,
            windowId: 1,
            childIndex: 1,
            depth: 1,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )

        let index = ShadowTreeIndex(
            seq: 1,
            timestampMs: 100,
            activePackage: "com.android.settings",
            activeWindowId: 1,
            nodes: [bg, row, title, offscreen]
        )

        // Direct hit on TextView label
        let directTap = index.attributedTapAction(atX: 200, y: 380)
        XCTAssertEqual(directTap.kind, .tap)
        XCTAssertEqual(directTap.selectorText, "Display & touch")
        XCTAssertEqual(directTap.selectorResourceId, "android:id/title")

        // Hit on clickable row padding (outside TextView) resolves descendant title
        let rowPaddingTap = index.attributedTapAction(atX: 900, y: 380)
        XCTAssertEqual(rowPaddingTap.selectorText, "Display & touch")
        XCTAssertEqual(rowPaddingTap.selectorResourceId, "android:id/title")

        // Negative bounds coordinate parsing
        let negativeTap = index.attributedTapAction(atX: 10, y: 40)
        XCTAssertEqual(negativeTap.selectorText, "Offscreen")

        // Empty non-clickable background returns coordinate fallback without selectors
        XCTAssertNil(index.resolveNode(atX: 900, y: 2000))
        let bgTap = index.attributedTapAction(atX: 900, y: 2000)
        XCTAssertNil(bgTap.selectorText)
        XCTAssertNil(bgTap.selectorResourceId)
        XCTAssertNil(bgTap.selectorContentDesc)
        XCTAssertEqual(bgTap.targetDescription, "(900,2000)")
    }

    func testShadowGraphBridgeEmitsFailedEventOnRouteFailures() async throws {
        struct NoOpExecutor: MacroActionExecutor {
            func execute(action: AttributedUIAction, serial: String) async throws {}
        }

        let bridge = ShadowGraphBridge()
        actor EventRecorder {
            var events: [MacroExecutionEvent] = []
            func append(_ e: MacroExecutionEvent) { events.append(e) }
            func all() -> [MacroExecutionEvent] { events }
        }
        let recorder = EventRecorder()
        let stream = bridge.macroExecutionEvents
        let listener = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        await Task.yield()

        // 1. Stream unavailable
        let unavailableOutcome = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "MOCK",
            executor: NoOpExecutor()
        )
        XCTAssertEqual(unavailableOutcome, .streamUnavailable)

        // 2. Populate Screen A so stream is fresh, test targetNotFound
        let screenA = [makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", text: "Home")]
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.google.android.apps.nexuslauncher", nodes: screenA))
        let idxA = await bridge.domState.currentIndex!
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxA, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        let notFoundOutcome = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "MOCK",
            executor: NoOpExecutor()
        )
        if case .targetNotFound(let query, _) = notFoundOutcome {
            XCTAssertEqual(query, "Night Light")
        } else {
            XCTFail("Expected .targetNotFound, got \(notFoundOutcome)")
        }

        // 3. Populate unreachable Screen B containing "Night Light", then return to Screen A without an executable edge -> .noRoute
        let screenB = [makeNode(nodeId: 2, index: 0, packageName: "com.android.settings", text: "Night Light")]
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 2, package: "com.android.settings", nodes: screenB))
        let idxB = await bridge.domState.currentIndex!
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxB, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 3, package: "com.google.android.apps.nexuslauncher", nodes: screenA))
        let idxA2 = await bridge.domState.currentIndex!
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxA2, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        let noRouteOutcome = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "MOCK",
            executor: NoOpExecutor()
        )
        if case .noRoute = noRouteOutcome {
            // Expected
        } else {
            XCTFail("Expected .noRoute, got \(noRouteOutcome)")
        }

        try await Task.sleep(for: .milliseconds(30))
        listener.cancel()
        let events = await recorder.all()
        let failedMessages = events.compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failedMessages.count, 3)
        XCTAssertEqual(failedMessages[0], "Shadow DOM stream unavailable")
        XCTAssertTrue(failedMessages[1].contains("Target 'Night Light' not found"))
        XCTAssertTrue(failedMessages[2].contains("No route to 'Night Light'"))
    }

    func testShadowDOMStateFreshIndexSnapshotCacheLifecycle() async throws {
        let domState = ShadowDOMState()
        XCTAssertNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))

        let node1 = makeNode(
            nodeId: 101,
            index: 0,
            packageName: "com.android.settings",
            text: "Display",
            centerX: 200,
            centerY: 180
        )
        await domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.android.settings", nodes: [node1]))
        let cached1 = domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0)
        XCTAssertNotNil(cached1)
        XCTAssertEqual(cached1?.resolveNode(atX: 200, y: 180)?.text, "Display")

        // Age expiry gating
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 0.01))
        XCTAssertNotNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))

        // Diff updates cached snapshot synchronously
        let node2 = makeNode(
            nodeId: 102,
            index: 1,
            packageName: "com.android.settings",
            text: "Night Light",
            centerX: 200,
            centerY: 380
        )
        let diff = WireMessage.diff(WireDiffPayload(
            baseSeq: 1,
            seq: 2,
            timestampMs: 2000,
            activePackage: "com.android.settings",
            activeWindowId: 1,
            inserted: [node2]
        ))
        await domState.handleMessage(diff)
        let cached2 = domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0)
        XCTAssertEqual(cached2?.resolveNode(atX: 200, y: 380)?.text, "Night Light")

        // Hello clears stale snapshot cache until new snapshot arrives
        let hello = WireMessage.hello(WireHelloPayload(
            protocolVersion: 1,
            format: "ndjson",
            sdkInt: 34,
            deviceModel: "Pixel",
            pid: 999
        ))
        await domState.handleMessage(hello)
        XCTAssertNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))

        // Re-populate then markDisconnected invalidates cache
        await domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.android.settings", nodes: [node1]))
        XCTAssertNotNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))
        await domState.markDisconnected()
        XCTAssertNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))

        // Re-populate then reset invalidates cache
        await domState.handleMessage(makeSnapshotPayload(seq: 2, package: "com.android.settings", nodes: [node1]))
        XCTAssertNotNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))
        await domState.reset()
        XCTAssertNil(domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0))
    }

    func testShadowGraphBridgeEmitsFailedEventOnTargetHashAndEmptyQuery() async throws {
        struct NoOpExecutor: MacroActionExecutor {
            func execute(action: AttributedUIAction, serial: String) async throws {}
        }

        let bridge = ShadowGraphBridge()
        actor EventRecorder {
            var events: [MacroExecutionEvent] = []
            func append(_ e: MacroExecutionEvent) { events.append(e) }
            func all() -> [MacroExecutionEvent] { events }
        }
        let recorder = EventRecorder()
        let stream = bridge.macroExecutionEvents
        let listener = Task {
            for await event in stream {
                await recorder.append(event)
            }
        }
        await Task.yield()

        let screenA = [makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", text: "Home")]
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.google.android.apps.nexuslauncher", nodes: screenA))
        let idxA = await bridge.domState.currentIndex!
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxA, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        let hashOutcome = try await bridge.routeAndExecute(
            targetHint: nil,
            targetHash: 0xdeadbeef,
            serial: "MOCK",
            executor: NoOpExecutor()
        )
        if case .targetNotFound = hashOutcome {
            // Expected
        } else {
            XCTFail("Expected .targetNotFound for missing hash, got \(hashOutcome)")
        }

        let emptyOutcome = try await bridge.routeAndExecute(
            targetHint: "   ",
            targetHash: nil,
            serial: "MOCK",
            executor: NoOpExecutor()
        )
        if case .targetNotFound = emptyOutcome {
            // Expected
        } else {
            XCTFail("Expected .targetNotFound for empty query, got \(emptyOutcome)")
        }

        try await Task.sleep(for: .milliseconds(30))
        listener.cancel()

        let failedMessages = await recorder.all().compactMap { event -> String? in
            if case .failed(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(failedMessages.count, 2)
        XCTAssertTrue(failedMessages[0].contains("0x00000000deadbeef"))
        XCTAssertTrue(failedMessages[1].contains("Empty navigation target"))
    }

    func testSpatialGraphEngineExportImportJSONRoundTripAndTopologyCallback() async throws {
        actor CallbackCounter {
            var count = 0
            func increment() { count += 1 }
            func value() -> Int { count }
        }

        let counter = CallbackCounter()
        let engine = SpatialGraphEngine()
        await engine.setOnTopologyChanged {
            await counter.increment()
        }

        let homeNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", text: "Home"),
            makeNode(nodeId: 2, index: 1, packageName: "com.google.android.apps.nexuslauncher", text: "Settings", centerX: 200, centerY: 400, clickable: true)
        ]
        let settingsNodes = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", className: "TextView", text: "Settings"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Display & touch", centerX: 500, centerY: 700, clickable: true)
        ]
        let displayNodes = [
            makeNode(nodeId: 20, index: 0, packageName: "com.android.settings", className: "TextView", text: "Display & touch"),
            makeNode(nodeId: 21, index: 1, packageName: "com.android.settings", resourceId: "android:id/title", text: "Night Light", centerX: 500, centerY: 800, clickable: true)
        ]

        // 1. Cold start root -> fires topology callback once
        await engine.process(update: makeUpdate(seq: 1, package: "com.google.android.apps.nexuslauncher", nodes: homeNodes))
        let homeHash = await engine.currentStateHash!

        // 2. Duplicate same-screen frame -> must NOT fire topology callback
        await engine.process(update: makeUpdate(seq: 2, package: "com.google.android.apps.nexuslauncher", nodes: homeNodes))

        // 3. New nodes/edges -> fire topology callback
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 200, y: 400, selectorText: "Settings"))
        await engine.process(update: makeUpdate(seq: 3, package: "com.android.settings", nodes: settingsNodes))
        let settingsHash = await engine.currentStateHash!

        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Display & touch", x: 500, y: 700, selectorText: "Display & touch"))
        await engine.process(update: makeUpdate(seq: 4, package: "com.android.settings", nodes: displayNodes))
        let displayHash = await engine.currentStateHash!

        // Wait briefly for detached callback tasks
        try await Task.sleep(for: .milliseconds(50))
        let callbackCount = await counter.value()
        XCTAssertEqual(callbackCount, 3)

        let jsonData = try await engine.exportGraphJSON()

        // Invalid JSON must throw without wiping existing graph
        do {
            try await engine.importGraphJSON(Data("{not valid json".utf8))
            XCTFail("Expected importGraphJSON to throw on malformed JSON")
        } catch {
            // Expected
        }
        let intactCount = await engine.vertexCount
        XCTAssertEqual(intactCount, 3)

        // Fresh engine imports exported JSON and routes identically
        let restored = SpatialGraphEngine()
        try await restored.importGraphJSON(jsonData)

        let restoredVertexCount = await restored.vertexCount
        let restoredEdgeCount = await restored.edgeCount
        let restoredRoot = await restored.rootStateHash
        let restoredCurrent = await restored.currentStateHash
        let restoredAcyclic = await restored.isSpanningDAGAcyclic()
        XCTAssertEqual(restoredVertexCount, 3)
        XCTAssertEqual(restoredEdgeCount, 2)
        XCTAssertEqual(restoredRoot, homeHash)
        XCTAssertEqual(restoredCurrent, displayHash)
        XCTAssertTrue(restoredAcyclic)

        let ranked = await restored.resolveTargetVertices(matching: "Night Light")
        XCTAssertEqual(ranked.first?.vertex.layoutHash, displayHash)

        let snapshot = await restored.snapshot()
        let route = AStarPathfinder().findShortestPath(from: homeHash, to: displayHash, in: snapshot)
        XCTAssertEqual(route?.edges.map(\.toHash), [settingsHash, displayHash])
    }

    func testShadowGraphBridgeDaemonRecoveryHookRecoversDisconnectedStream() async throws {
        let bridge = ShadowGraphBridge()
        let homeNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", text: "Home"),
            makeNode(nodeId: 2, index: 1, packageName: "com.google.android.apps.nexuslauncher", text: "Settings", centerX: 200, centerY: 400, clickable: true)
        ]
        let settingsNodes = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", className: "TextView", text: "Settings")
        ]

        // Seed graph while disconnected (simulating loaded persisted graph)
        let homeIdx = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.google.android.apps.nexuslauncher", activeWindowId: 1, nodes: homeNodes)
        let settingsIdx = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: settingsNodes)
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: homeIdx, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 200, y: 400, selectorText: "Settings"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: settingsIdx, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        let settingsHash = await bridge.graphEngine.vertices.values.first(where: { $0.activePackage == "com.android.settings" })!.layoutHash

        final class MockRecoveryExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let settingsNodes: [ShadowUINode]
            init(bridge: ShadowGraphBridge, settingsNodes: [ShadowUINode]) {
                self.bridge = bridge
                self.settingsNodes = settingsNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                    seq: 101,
                    timestampMs: 2000,
                    reason: "settled",
                    activePackage: "com.android.settings",
                    activeWindowId: 1,
                    nodeCount: settingsNodes.count,
                    nodes: settingsNodes
                )))
            }
        }

        // First test failing recovery hook -> .streamUnavailable
        bridge.setDaemonRecoveryHook { _, _ in false }
        let unavail = try await bridge.routeAndExecute(
            targetHint: "Settings",
            serial: "MOCK",
            executor: MockRecoveryExecutor(bridge: bridge, settingsNodes: settingsNodes)
        )
        XCTAssertEqual(unavail, .streamUnavailable)

        // Now test succeeding recovery hook delivering initial snapshot
        actor HookFlag {
            var called = false
            func mark() { called = true }
            func wasCalled() -> Bool { called }
        }
        let flag = HookFlag()
        bridge.setDaemonRecoveryHook { serial, _ in
            XCTAssertEqual(serial, "MOCK")
            await flag.mark()
            await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                seq: 100,
                timestampMs: 1000,
                reason: "recovered",
                activePackage: "com.google.android.apps.nexuslauncher",
                activeWindowId: 1,
                nodeCount: homeNodes.count,
                nodes: homeNodes
            )))
            return true
        }

        let outcome = try await bridge.routeAndExecute(
            targetHint: "Settings",
            serial: "MOCK",
            executor: MockRecoveryExecutor(bridge: bridge, settingsNodes: settingsNodes)
        )
        let called = await flag.wasCalled()
        XCTAssertTrue(called)
        if case .arrived(let report) = outcome {
            XCTAssertEqual(report.finalHash, settingsHash)
            XCTAssertEqual(report.steps.count, 1)
        } else {
            XCTFail("Expected .arrived after daemon recovery, got \(outcome)")
        }
    }

    func testShadowGraphBridgeEnsureShadowStreamReadyRejectsDisconnectedStartedClient() async throws {
        let bridge = ShadowGraphBridge(configuration: DaemonEndpointConfiguration(
            host: "127.0.0.1",
            port: 59997,
            initialReconnectDelay: 5.0,
            maxReconnectDelay: 5.0
        ))
        // Start bridge against closed port -> client transitions to .waitingToReconnect
        await bridge.start()
        try await Task.sleep(for: .milliseconds(80))

        // Even if domState is manually populated (simulating utility statePumpTask lag),
        // ensureShadowStreamReady must return false when the started client is not connected/connecting.
        let homeNodes = [makeNode(nodeId: 1, index: 0, packageName: "com.launcher", text: "Home")]
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 1, package: "com.launcher", nodes: homeNodes))

        let ready = await bridge.ensureShadowStreamReady(maxWaitSeconds: 0.05, maxAgeSeconds: 15.0)
        XCTAssertFalse(ready)
        await bridge.stop()
    }

    // MARK: - Resilience, Safety HITL & Auto-Recovery Tests (#1, #2, #3, #4, #7)

    private actor AsyncEventCollector {
        private var events: [MacroExecutionEvent] = []
        func append(_ event: MacroExecutionEvent) { events.append(event) }
        func snapshot() -> [MacroExecutionEvent] { events }
    }

    func testMacroExecutionEngineForwardSkipRecoveryAndOffPathScrollReplan() async throws {
        // #1: 4-hop path S0 -> S1 -> S2 -> S3 -> S4 where app remembers scroll state and tapping S0 lands straight on S3
        let bridge = ShadowGraphBridge()
        let nodes0 = [makeNode(nodeId: 1, index: 0, packageName: "com.settings", text: "Open List", centerX: 200, centerY: 300, clickable: true)]
        let nodes1 = [makeNode(nodeId: 2, index: 0, packageName: "com.settings", text: "Scroll Section Alpha")]
        let nodes2 = [makeNode(nodeId: 3, index: 0, packageName: "com.settings", text: "Scroll Section Beta")]
        let nodes3 = [makeNode(nodeId: 4, index: 0, packageName: "com.settings", text: "Deep Option", centerX: 300, centerY: 900, clickable: true)]
        let nodes4 = [makeNode(nodeId: 5, index: 0, packageName: "com.settings", text: "Night Light Arrived")]

        let idx0 = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.settings", activeWindowId: 1, nodes: nodes0)
        let idx1 = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.settings", activeWindowId: 1, nodes: nodes1)
        let idx2 = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.settings", activeWindowId: 1, nodes: nodes2)
        let idx3 = ShadowTreeIndex(seq: 4, timestampMs: 400, activePackage: "com.settings", activeWindowId: 1, nodes: nodes3)
        let idx4 = ShadowTreeIndex(seq: 5, timestampMs: 500, activePackage: "com.settings", activeWindowId: 1, nodes: nodes4)

        let h0 = ScreenLayoutHasher().fingerprint(for: idx0).layoutHash
        let h1 = ScreenLayoutHasher().fingerprint(for: idx1).layoutHash
        let h2 = ScreenLayoutHasher().fingerprint(for: idx2).layoutHash
        let h3 = ScreenLayoutHasher().fingerprint(for: idx3).layoutHash
        let h4 = ScreenLayoutHasher().fingerprint(for: idx4).layoutHash

        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx0, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Open List", x: 200, y: 300, selectorText: "Open List"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx1, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .swipe, targetDescription: "Scroll 1", x: 500, y: 1800, endX: 500, endY: 800, durationMs: 200))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx2, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .swipe, targetDescription: "Scroll 2", x: 500, y: 1800, endX: 500, endY: 800, durationMs: 200))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx3, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Deep Option", x: 300, y: 900, selectorText: "Deep Option"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idx4, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Start back at idx0
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.settings", nodes: nodes0))

        final class SkipExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let nodes3: [ShadowUINode]
            let nodes4: [ShadowUINode]
            var dispatched: [String] = []
            init(bridge: ShadowGraphBridge, nodes3: [ShadowUINode], nodes4: [ShadowUINode]) {
                self.bridge = bridge; self.nodes3 = nodes3; self.nodes4 = nodes4
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                dispatched.append(action.signature)
                if dispatched.count == 1 {
                    // Tapping S0 jumps straight to S3 (app restored scroll position, skipping S1 and S2)
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 11, timestampMs: 1100, reason: "step", activePackage: "com.settings", activeWindowId: 1, nodeCount: nodes3.count, nodes: nodes3
                    )))
                } else {
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 1200, reason: "step", activePackage: "com.settings", activeWindowId: 1, nodeCount: nodes4.count, nodes: nodes4
                    )))
                }
            }
        }

        let exec = SkipExecutor(bridge: bridge, nodes3: nodes3, nodes4: nodes4)
        let outcome = try await bridge.routeAndExecute(
            targetHash: h4,
            serial: "61061JEA307110",
            executor: exec,
            stepTimeoutMs: 500,
            postSettleQuiescenceMs: 0
        )

        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived with forward-skip recovery, got \(outcome)")
        }
        XCTAssertEqual(report.finalHash, h4)
        XCTAssertEqual(exec.dispatched, ["tap:Open List", "tap:Deep Option"])
        XCTAssertEqual(report.steps.count, 4)
        if report.steps.count == 4 {
            XCTAssertFalse(report.steps[0].wasSkipped)
            XCTAssertTrue(report.steps[1].wasSkipped)
            XCTAssertTrue(report.steps[2].wasSkipped)
            XCTAssertFalse(report.steps[3].wasSkipped)
            XCTAssertEqual(report.steps[0].targetHash, h1)
            XCTAssertEqual(report.steps[1].targetHash, h2)
            XCTAssertEqual(report.steps[2].targetHash, h3)
            XCTAssertEqual(report.steps[3].targetHash, h4)
        }
        XCTAssertTrue(report.recoveredSteps.contains(where: { $0.hasPrefix("forward_skip:") }))
        _ = h0
    }

    func testShadowGraphBridgeOffPathScrollStateRecoveryReplansAStar() async throws {
        // #1 Part 2: Executing step 0 lands on an off-path remembered-scroll vertex S_alt (not on the initial path)
        // which has its own path to the goal -> ShadowGraphBridge recovers from stepTimeout and replans A*!
        let bridge = ShadowGraphBridge()
        let nStart = [makeNode(nodeId: 1, index: 0, packageName: "com.shop", text: "Open Catalog", centerX: 200, centerY: 300, clickable: true)]
        let nExpected1 = [makeNode(nodeId: 2, index: 0, packageName: "com.shop", text: "Top of Catalog", centerX: 200, centerY: 400, clickable: true)]
        let nAltScroll = [makeNode(nodeId: 3, index: 0, packageName: "com.shop", text: "Restored Scroll Mid", centerX: 200, centerY: 700, clickable: true)]
        let nGoal = [makeNode(nodeId: 4, index: 0, packageName: "com.shop", text: "Target Item Details")]

        let idxStart = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.shop", activeWindowId: 1, nodes: nStart)
        let idxExpected1 = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.shop", activeWindowId: 1, nodes: nExpected1)
        let idxAltScroll = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.shop", activeWindowId: 1, nodes: nAltScroll)
        let idxGoal = ShadowTreeIndex(seq: 4, timestampMs: 400, activePackage: "com.shop", activeWindowId: 1, nodes: nGoal)
        let hGoal = ScreenLayoutHasher().fingerprint(for: idxGoal).layoutHash

        // Chain 1: Start -> Expected1 -> Goal
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxStart, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Open Catalog", x: 200, y: 300, selectorText: "Open Catalog"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxExpected1, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Item from top", x: 200, y: 400, selectorText: "Top of Catalog"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxGoal, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Alternate known branch: AltScroll -> Goal
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 5, package: "com.shop", nodes: nAltScroll))
        _ = await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxAltScroll, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Item from scroll", x: 200, y: 700, selectorText: "Restored Scroll Mid"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxGoal, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Reset live screen to Start
        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.shop", nodes: nStart))

        final class ScrollRestoreExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let nAltScroll: [ShadowUINode]
            let nGoal: [ShadowUINode]
            var calls: [String] = []
            init(bridge: ShadowGraphBridge, nAltScroll: [ShadowUINode], nGoal: [ShadowUINode]) {
                self.bridge = bridge; self.nAltScroll = nAltScroll; self.nGoal = nGoal
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                calls.append(action.signature)
                if calls.count == 1 {
                    // Opening Catalog opens at remembered scrolled state (nAltScroll) instead of nExpected1!
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 11, timestampMs: 1100, reason: "restored_scroll", activePackage: "com.shop", activeWindowId: 1, nodeCount: nAltScroll.count, nodes: nAltScroll
                    )))
                } else {
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 1200, reason: "goal", activePackage: "com.shop", activeWindowId: 1, nodeCount: nGoal.count, nodes: nGoal
                    )))
                }
            }
        }

        let exec = ScrollRestoreExecutor(bridge: bridge, nAltScroll: nAltScroll, nGoal: nGoal)
        let outcome = try await bridge.routeAndExecute(
            targetHash: hGoal,
            serial: "61061JEA307110",
            executor: exec,
            stepTimeoutMs: 150,
            postSettleQuiescenceMs: 0
        )

        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived after off-path scroll recovery replan, got \(outcome)")
        }
        XCTAssertEqual(report.finalHash, hGoal)
        XCTAssertEqual(exec.calls, ["tap:Open Catalog", "tap:Item from scroll"])
        XCTAssertTrue(report.recoveredSteps.contains(where: { $0.hasPrefix("replan_from:") }))
    }

    func testHazardousActionHITLPausesBeforeDangerousStepAndResumesWithConfirmedTrue() async throws {
        // #2 Variant A: Safe prefix executes -> halts right before "Оплатить" with requires_confirmation -> confirmed: true completes
        let bridge = ShadowGraphBridge()
        let homeNodes = [makeNode(nodeId: 1, index: 0, packageName: "com.shop", text: "Checkout", centerX: 300, centerY: 400, clickable: true)]
        let checkoutNodes = [
            makeNode(nodeId: 2, index: 0, packageName: "com.shop", text: "Order Summary"),
            makeNode(nodeId: 3, index: 1, packageName: "com.shop", resourceId: "com.shop:id/btn_pay", text: "Оплатить 15.99€", centerX: 540, centerY: 2100, clickable: true)
        ]
        let receiptNodes = [makeNode(nodeId: 4, index: 0, packageName: "com.shop", text: "Receipt Confirmed")]

        let idxHome = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.shop", activeWindowId: 1, nodes: homeNodes)
        let idxCheckout = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.shop", activeWindowId: 1, nodes: checkoutNodes)
        let idxReceipt = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.shop", activeWindowId: 1, nodes: receiptNodes)
        let hashCheckout = ScreenLayoutHasher().fingerprint(for: idxCheckout).layoutHash
        let hashReceipt = ScreenLayoutHasher().fingerprint(for: idxReceipt).layoutHash

        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxHome, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Checkout", x: 300, y: 400, selectorText: "Checkout"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxCheckout, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Оплатить 15.99€", x: 540, y: 2100, selectorResourceId: "com.shop:id/btn_pay", selectorText: "Оплатить 15.99€"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxReceipt, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Also verify importSnapshot classifies persisted hazardous edges automatically
        let exported = try await bridge.graphEngine.exportGraphJSON(prettyPrinted: false)
        let reimportedEngine = SpatialGraphEngine()
        try await reimportedEngine.importGraphJSON(exported)
        let checkoutEdges = await reimportedEngine.neighbors(of: hashCheckout)
        XCTAssertEqual(checkoutEdges.first?.isHazardous, true)

        await bridge.domState.handleMessage(makeSnapshotPayload(seq: 10, package: "com.shop", nodes: homeNodes))

        let collectedEvents = AsyncEventCollector()
        let subTask = Task {
            for await ev in bridge.macroExecutionEvents {
                await collectedEvents.append(ev)
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        final class PayExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let checkoutNodes: [ShadowUINode]
            let receiptNodes: [ShadowUINode]
            var calls: [String] = []
            init(bridge: ShadowGraphBridge, checkoutNodes: [ShadowUINode], receiptNodes: [ShadowUINode]) {
                self.bridge = bridge; self.checkoutNodes = checkoutNodes; self.receiptNodes = receiptNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                calls.append(action.signature)
                if action.signature.contains("Checkout") {
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 11, timestampMs: 200, reason: "step", activePackage: "com.shop", activeWindowId: 1, nodeCount: checkoutNodes.count, nodes: checkoutNodes
                    )))
                } else {
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 300, reason: "step", activePackage: "com.shop", activeWindowId: 1, nodeCount: receiptNodes.count, nodes: receiptNodes
                    )))
                }
            }
        }

        let exec = PayExecutor(bridge: bridge, checkoutNodes: checkoutNodes, receiptNodes: receiptNodes)
        let firstOutcome = try await bridge.routeAndExecute(
            targetHash: hashReceipt,
            serial: "61061JEA307110",
            executor: exec,
            stepTimeoutMs: 500,
            postSettleQuiescenceMs: 0,
            confirmed: false
        )

        guard case .requiresConfirmation(let req) = firstOutcome else {
            return XCTFail("Expected .requiresConfirmation on unconfirmed payment, got \(firstOutcome)")
        }
        XCTAssertEqual(exec.calls, ["tap:Checkout"])
        XCTAssertEqual(req.hazardCategory, .payment)
        XCTAssertEqual(req.stepIndex, 1)
        XCTAssertEqual(req.stepsCompleted, 1)
        XCTAssertEqual(req.currentHash, hashCheckout)
        XCTAssertEqual(req.tapX, 540)
        XCTAssertEqual(req.tapY, 2100)

        try await Task.sleep(for: .milliseconds(20))
        let eventsSoFar = await collectedEvents.snapshot()
        XCTAssertTrue(eventsSoFar.contains(where: { if case .awaitingConfirmation = $0 { return true }; return false }))
        XCTAssertFalse(eventsSoFar.contains(where: { if case .failed = $0 { return true }; return false }))

        // Now confirm in chat and re-invoke with confirmed: true from current Checkout screen
        let confirmedOutcome = try await bridge.routeAndExecute(
            targetHash: hashReceipt,
            serial: "61061JEA307110",
            executor: exec,
            stepTimeoutMs: 500,
            postSettleQuiescenceMs: 0,
            confirmed: true
        )
        guard case .arrived(let confirmedReport) = confirmedOutcome else {
            return XCTFail("Expected .arrived with confirmed: true, got \(confirmedOutcome)")
        }
        XCTAssertEqual(confirmedReport.finalHash, hashReceipt)
        XCTAssertEqual(exec.calls.count, 2)
        subTask.cancel()
    }

    func testReflexiveSwipeDismissesOccludingPushBannerWithoutPoisoningGraph() async throws {
        // #3: Heads-up notification covers target tap -> upward swipe without recording graph edge -> tap succeeds
        let domState = ShadowDOMState()
        let graphEngine = SpatialGraphEngine()

        let startWithBannerNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.app", text: "Compose", centerX: 500, centerY: 200, clickable: true),
            makeNode(nodeId: 900, index: 1, packageName: "com.android.systemui", className: "FrameLayout", resourceId: "com.android.systemui:id/expandableNotificationRow", text: "Push Alert", bounds: "[40,120][1040,320]", centerX: 540, centerY: 220, clickable: true)
        ]
        let cleanStartNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.app", text: "Compose", centerX: 500, centerY: 200, clickable: true)
        ]
        let targetNodes = [
            makeNode(nodeId: 2, index: 0, packageName: "com.app", text: "New Draft")
        ]

        let idxStartClean = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.app", activeWindowId: 1, nodes: cleanStartNodes)
        let idxTarget = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.app", activeWindowId: 1, nodes: targetNodes)
        let hStart = ScreenLayoutHasher().fingerprint(for: idxStartClean).layoutHash
        let hTarget = ScreenLayoutHasher().fingerprint(for: idxTarget).layoutHash

        await graphEngine.process(update: ShadowDOMUpdate(index: idxStartClean, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Compose", x: 500, y: 200, selectorText: "Compose"))
        let edge = await graphEngine.process(update: ShadowDOMUpdate(index: idxTarget, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!
        let edgeCountBefore = await graphEngine.edgeCount

        await domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10, timestampMs: 1000, reason: "init", activePackage: "com.app", activeWindowId: 1, nodeCount: startWithBannerNodes.count, nodes: startWithBannerNodes
        )))

        final class BannerAwareExecutor: MacroActionExecutor, @unchecked Sendable {
            let domState: ShadowDOMState
            let cleanStartNodes: [ShadowUINode]
            let targetNodes: [ShadowUINode]
            var actions: [AttributedUIAction] = []
            init(domState: ShadowDOMState, cleanStartNodes: [ShadowUINode], targetNodes: [ShadowUINode]) {
                self.domState = domState; self.cleanStartNodes = cleanStartNodes; self.targetNodes = targetNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                actions.append(action)
                if action.kind == .swipe {
                    await domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 11, timestampMs: 1100, reason: "banner_gone", activePackage: "com.app", activeWindowId: 1, nodeCount: cleanStartNodes.count, nodes: cleanStartNodes
                    )))
                } else {
                    await domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 1200, reason: "settled", activePackage: "com.app", activeWindowId: 1, nodeCount: targetNodes.count, nodes: targetNodes
                    )))
                }
            }
        }

        let exec = BannerAwareExecutor(domState: domState, cleanStartNodes: cleanStartNodes, targetNodes: targetNodes)
        let engine = MacroExecutionEngine(
            domState: domState,
            graphEngine: graphEngine,
            executor: exec,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 600, postSettleQuiescenceMs: 0)
        )
        let report = try await engine.execute(path: [edge], serial: "61061JEA307110")
        XCTAssertEqual(report.finalHash, hTarget)
        XCTAssertEqual(exec.actions.count, 2)
        XCTAssertEqual(exec.actions[0].kind, .swipe)
        XCTAssertGreaterThan(exec.actions[0].y ?? 0, exec.actions[0].endY ?? 9999) // upward swipe
        XCTAssertEqual(exec.actions[1].kind, .tap)
        let edgeCountAfter = await graphEngine.edgeCount
        XCTAssertEqual(edgeCountAfter, edgeCountBefore)
        XCTAssertTrue(report.recoveredSteps.contains(where: { $0.hasPrefix("dismiss_notification_overlay") }))
        _ = hStart
    }

    func testUniversalDismissClosesPromoPopupAndRefusesHazardousButtons() async throws {
        // #4 Universal Dismiss safety check: must never treat "Удалить" or "Close account" as a popup dismiss
        let dangerIndex = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.app", activeWindowId: 1, nodes: [
            makeNode(nodeId: 1, index: 0, packageName: "com.app", text: "Close account", centerX: 500, centerY: 1200, clickable: true),
            makeNode(nodeId: 2, index: 1, packageName: "com.app", text: "Удалить профиль", centerX: 500, centerY: 1400, clickable: true)
        ])
        XCTAssertNil(UniversalDismissDetector.findDismissCandidate(in: dangerIndex))

        // Full ShadowGraphBridge recovery: land on unknown promo splash -> Universal Dismiss -> re-plan A* -> arrive
        let bridge = ShadowGraphBridge()
        let catalogNodes = [makeNode(nodeId: 1, index: 0, packageName: "com.shop", text: "Open Profile", centerX: 300, centerY: 400, clickable: true)]
        let profileNodes = [makeNode(nodeId: 2, index: 0, packageName: "com.shop", text: "Profile Ready")]
        let promoPopupNodes = [
            makeNode(nodeId: 10, index: 0, packageName: "com.shop", text: "Subscribe 50% OFF!"),
            makeNode(nodeId: 11, index: 1, packageName: "com.shop", resourceId: "com.shop:id/btn_dismiss", text: "Не сейчас", centerX: 540, centerY: 1800, clickable: true)
        ]

        let idxCatalog = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.shop", activeWindowId: 1, nodes: catalogNodes)
        let idxProfile = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.shop", activeWindowId: 1, nodes: profileNodes)
        let hProfile = ScreenLayoutHasher().fingerprint(for: idxProfile).layoutHash

        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxCatalog, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Open Profile", x: 300, y: 400, selectorText: "Open Profile"))
        await bridge.graphEngine.process(update: ShadowDOMUpdate(index: idxProfile, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Put live device onto unknown Promo Popup screen (not in graph -> would otherwise fail with noRoute)
        await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10, timestampMs: 500, reason: "promo", activePackage: "com.shop", activeWindowId: 2, nodeCount: promoPopupNodes.count, nodes: promoPopupNodes
        )))

        final class PromoDismissExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let catalogNodes: [ShadowUINode]
            let profileNodes: [ShadowUINode]
            var taps: [(Int, Int)] = []
            init(bridge: ShadowGraphBridge, catalogNodes: [ShadowUINode], profileNodes: [ShadowUINode]) {
                self.bridge = bridge; self.catalogNodes = catalogNodes; self.profileNodes = profileNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                taps.append((action.x ?? -1, action.y ?? -1))
                if taps.count == 1 {
                    // Dismissing popup reveals Catalog
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 11, timestampMs: 600, reason: "dismissed", activePackage: "com.shop", activeWindowId: 1, nodeCount: catalogNodes.count, nodes: catalogNodes
                    )))
                } else {
                    await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 700, reason: "settled", activePackage: "com.shop", activeWindowId: 1, nodeCount: profileNodes.count, nodes: profileNodes
                    )))
                }
            }
        }

        let exec = PromoDismissExecutor(bridge: bridge, catalogNodes: catalogNodes, profileNodes: profileNodes)
        let outcome = try await bridge.routeAndExecute(
            targetHash: hProfile,
            serial: "61061JEA307110",
            executor: exec,
            stepTimeoutMs: 600,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived after Universal Dismiss recovery, got \(outcome)")
        }
        XCTAssertEqual(exec.taps.count, 2)
        XCTAssertEqual(exec.taps[0].0, 540)
        XCTAssertEqual(exec.taps[0].1, 1800)
        XCTAssertEqual(report.finalHash, hProfile)
        XCTAssertTrue(report.recoveredSteps.contains("universal_dismiss:Не сейчас"))
    }

    func testMacroExecutionEnginePausesOnSecureScreenAndResumesOnClear() async throws {
        // #7 FLAG_SECURE / biometric lock pauses step timeout and resumes cleanly once unlocked
        let domState = ShadowDOMState()
        let graphEngine = SpatialGraphEngine()

        let startNodes = [makeNode(nodeId: 1, index: 0, packageName: "com.bank", text: "Transfer", centerX: 300, centerY: 400, clickable: true)]
        let vaultNodes = [makeNode(nodeId: 2, index: 0, packageName: "com.bank", text: "Vault Unlocked")]
        let idxStart = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.bank", activeWindowId: 1, nodes: startNodes)
        let idxVault = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.bank", activeWindowId: 1, nodes: vaultNodes)
        let hVault = ScreenLayoutHasher().fingerprint(for: idxVault).layoutHash

        await graphEngine.process(update: ShadowDOMUpdate(index: idxStart, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        await graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Transfer", x: 300, y: 400, selectorText: "Transfer"))
        let edge = await graphEngine.process(update: ShadowDOMUpdate(index: idxVault, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))!

        await domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10, timestampMs: 1000, reason: "init", activePackage: "com.bank", activeWindowId: 1, nodeCount: startNodes.count, nodes: startNodes
        )))

        final class BiometricExecutor: MacroActionExecutor, @unchecked Sendable {
            let domState: ShadowDOMState
            let vaultNodes: [ShadowUINode]
            init(domState: ShadowDOMState, vaultNodes: [ShadowUINode]) {
                self.domState = domState; self.vaultNodes = vaultNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                // Immediately trigger SECURE_SCREEN_ACTIVE (longer than the 120ms normal stepTimeoutMs!)
                await domState.handleMessage(.secureScreen(WireSecureScreenPayload(
                    code: "SECURE_SCREEN_ACTIVE",
                    active: true,
                    reason: "biometric_prompt",
                    activePackage: "com.bank",
                    timestampMs: 1100
                )))
                Task {
                    try? await Task.sleep(for: .milliseconds(240))
                    await domState.handleMessage(.secureScreen(WireSecureScreenPayload(
                        code: "SECURE_SCREEN_CLEARED",
                        active: false,
                        reason: "tree_restored",
                        activePackage: "com.bank",
                        timestampMs: 1340
                    )))
                    await domState.handleMessage(.snapshot(WireSnapshotPayload(
                        seq: 12, timestampMs: 1350, reason: "unlocked", activePackage: "com.bank", activeWindowId: 1, nodeCount: vaultNodes.count, nodes: vaultNodes, secureScreenActive: false
                    )))
                }
            }
        }

        let collector = AsyncEventCollector()
        let engine = MacroExecutionEngine(
            domState: domState,
            graphEngine: graphEngine,
            executor: BiometricExecutor(domState: domState, vaultNodes: vaultNodes),
            configuration: MacroExecutionConfiguration(
                stepTimeoutMs: 120,
                postSettleQuiescenceMs: 0,
                allowHazardousActions: true,
                secureHandoffTimeoutSeconds: 5.0
            ),
            onEvent: { ev in
                Task { await collector.append(ev) }
            }
        )

        let report = try await engine.execute(path: [edge], serial: "61061JEA307110")
        XCTAssertEqual(report.finalHash, hVault)
        XCTAssertTrue(report.recoveredSteps.contains("secure_handoff"))

        try await Task.sleep(for: .milliseconds(30))
        let events = await collector.snapshot()
        XCTAssertTrue(events.contains(where: { if case .awaitingBiometrics = $0 { return true }; return false }))
        XCTAssertTrue(events.contains(where: { if case .biometricsCleared = $0 { return true }; return false }))
    }

    func testSuppressedSamePackageFrameBetweenSignificanceAndSettleThresholdsDoesNotThrowUnexpectedStartState() async throws {
        // Reproduce live Pixel 10a bug: SpatialGraphEngine.significanceThreshold (0.72) < settleSimilarityThreshold (0.80).
        // When a scrolled screen in the same package has Jaccard in [0.72, 0.80) vs currentStateHash,
        // process(update:) keeps currentStateHash on prevVertex without creating the new vertex.
        // ShadowGraphBridge must NOT force-adopt prevVertex (which would throw unexpectedStartState).
        let baseLabels = ["Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta"]
        let prevLabels = ["Alpha"] + baseLabels                 // 8 tokens
        let scrolledLabels = baseLabels + ["Iota"]              // vs prev: 7/9 = 0.7778 in [0.72, 0.80)
        let aliasLabels = baseLabels + ["Iota", "Subheader"]    // vs scrolled: 8/9 = 0.8889 >= 0.80

        let prevNodes = prevLabels.enumerated().map { idx, txt in
            makeNode(nodeId: Int64(10 + idx), index: idx, packageName: "com.android.settings", text: txt, centerX: 300, centerY: 200 + idx * 100)
        }
        let scrolledNodes = scrolledLabels.enumerated().map { idx, txt in
            makeNode(nodeId: Int64(30 + idx), index: idx, packageName: "com.android.settings", text: txt, centerX: 300, centerY: 200 + idx * 100)
        }
        let aliasNodes = aliasLabels.enumerated().map { idx, txt in
            makeNode(nodeId: Int64(50 + idx), index: idx, packageName: "com.android.settings", text: txt, centerX: 300, centerY: 200 + idx * 100)
        }
        let destNodes = [
            makeNode(nodeId: 90, index: 0, packageName: "com.android.settings", text: "Connection preferences"),
            makeNode(nodeId: 91, index: 1, packageName: "com.android.settings", text: "Bluetooth")
        ]

        let idxPrev = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.android.settings", activeWindowId: 1, nodes: prevNodes)
        let idxAlias = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: aliasNodes)
        let idxDest = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.android.settings", activeWindowId: 1, nodes: destNodes)
        let hDest = ScreenLayoutHasher().fingerprint(for: idxDest).layoutHash

        // Part 1: Only prev -> dest edge exists, while live DOM is scrolled (0.7778 vs prev): must return .noRoute, NOT throw unexpectedStartState.
        let bridgeNoAlias = ShadowGraphBridge()
        await bridgeNoAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxPrev, isFullSnapshot: true, insertedCount: prevNodes.count, updatedCount: 0, removedCount: 0))
        await bridgeNoAlias.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Alpha", x: 300, y: 200, selectorText: "Alpha"))
        await bridgeNoAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxDest, isFullSnapshot: true, insertedCount: destNodes.count, updatedCount: 0, removedCount: 0))
        await bridgeNoAlias.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Back", x: 50, y: 100))
        await bridgeNoAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxPrev, isFullSnapshot: true, insertedCount: prevNodes.count, updatedCount: 0, removedCount: 0))

        await bridgeNoAlias.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10, timestampMs: 1000, reason: "scrolled", activePackage: "com.android.settings", activeWindowId: 1, nodeCount: scrolledNodes.count, nodes: scrolledNodes
        )))

        final class NoOpExec: MacroActionExecutor, @unchecked Sendable {
            func execute(action: AttributedUIAction, serial: String) async throws {}
        }

        let noAliasOutcome = try await bridgeNoAlias.routeAndExecute(
            targetHash: hDest,
            serial: "61061JEA307110",
            executor: NoOpExec(),
            stepTimeoutMs: 400,
            postSettleQuiescenceMs: 0
        )
        guard case .noRoute = noAliasOutcome else {
            return XCTFail("Expected clean .noRoute instead of unexpectedStartState/wrong alias, got \(noAliasOutcome)")
        }

        // Part 2: When a valid >= 0.80 semantic alias (idxAlias) DOES exist, route through idxAlias and arrive cleanly.
        let bridgeWithAlias = ShadowGraphBridge()
        await bridgeWithAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxAlias, isFullSnapshot: true, insertedCount: aliasNodes.count, updatedCount: 0, removedCount: 0))
        await bridgeWithAlias.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Iota", x: 300, y: 900, selectorText: "Iota"))
        await bridgeWithAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxDest, isFullSnapshot: true, insertedCount: destNodes.count, updatedCount: 0, removedCount: 0))
        // Move currentStateHash onto idxPrev (0.7778 similarity with scrolledNodes) so process(update: scrolled) stays suppressed on idxPrev
        await bridgeWithAlias.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "PrevScreen", x: 100, y: 100))
        await bridgeWithAlias.graphEngine.process(update: ShadowDOMUpdate(index: idxPrev, isFullSnapshot: true, insertedCount: prevNodes.count, updatedCount: 0, removedCount: 0))
        await bridgeWithAlias.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Alpha", x: 300, y: 200, selectorText: "Alpha"))
        // Give idxPrev a dummy vertex or direct edge to ensure currentStateHash is idxPrev with scrolled suppressed
        await bridgeWithAlias.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 20, timestampMs: 2000, reason: "scrolled", activePackage: "com.android.settings", activeWindowId: 1, nodeCount: scrolledNodes.count, nodes: scrolledNodes
        )))

        final class DestSettleExec: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let destNodes: [ShadowUINode]
            init(bridge: ShadowGraphBridge, destNodes: [ShadowUINode]) {
                self.bridge = bridge; self.destNodes = destNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                    seq: 21, timestampMs: 2100, reason: "arrived", activePackage: "com.android.settings", activeWindowId: 1, nodeCount: destNodes.count, nodes: destNodes
                )))
            }
        }

        let aliasOutcome = try await bridgeWithAlias.routeAndExecute(
            targetHash: hDest,
            serial: "61061JEA307110",
            executor: DestSettleExec(bridge: bridgeWithAlias, destNodes: destNodes),
            stepTimeoutMs: 500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report) = aliasOutcome else {
            return XCTFail("Expected .arrived via semantic alias when canonicalStart had similarity < 0.80, got \(aliasOutcome)")
        }
        XCTAssertEqual(report.finalHash, hDest)
    }
}
