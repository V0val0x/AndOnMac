import XCTest
import Network
@testable import AndroidShadowGraphKit

final class AndroidShadowGraphKitTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        nodeId: Int64,
        parentId: Int64? = nil,
        windowId: Int = 1,
        index: Int,
        childIndex: Int = 0,
        depth: Int = 1,
        packageName: String = "com.example.app",
        className: String = "Button",
        resourceId: String = "",
        text: String = "",
        contentDesc: String = "",
        bounds: String = "[0,0][100,100]",
        centerX: Int = 50,
        centerY: Int = 50,
        clickable: Bool = false,
        scrollable: Bool = false,
        editable: Bool = false,
        focused: Bool = false,
        checked: Bool = false,
        enabled: Bool = true,
        visible: Bool = true
    ) -> ShadowUINode {
        ShadowUINode(
            index: index,
            text: text,
            resourceId: resourceId,
            contentDesc: contentDesc,
            className: className,
            clickable: clickable,
            scrollable: scrollable,
            bounds: bounds,
            centerX: centerX,
            centerY: centerY,
            nodeId: nodeId,
            parentId: parentId,
            windowId: windowId,
            childIndex: childIndex,
            depth: depth,
            packageName: packageName,
            editable: editable,
            focused: focused,
            checked: checked,
            enabled: enabled,
            visible: visible
        )
    }

    // MARK: - 1. NdjsonWireCodec Tests

    func testNdjsonWireCodecDecodesAllMessageTypesAndEncodesCommands() throws {
        let codec = NdjsonWireCodec()

        // 1. hello
        let helloLine = #"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":36,"device_model":"Pixel 10a","pid":4242}"#
        let helloMsg = try codec.decodeFrame(Data(helloLine.utf8))
        guard case .hello(let hello) = helloMsg else {
            return XCTFail("Expected .hello")
        }
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertEqual(hello.format, "ndjson/1")
        XCTAssertEqual(hello.sdkInt, 36)
        XCTAssertEqual(hello.deviceModel, "Pixel 10a")
        XCTAssertEqual(hello.pid, 4242)

        // 2. snapshot
        let snapLine = #"{"type":"snapshot","seq":10,"ts_ms":1700000000,"reason":"initial","package":"com.android.settings","window_id":7,"node_count":1,"nodes":[{"index":0,"text":"Display","resource_id":"com.android.settings:id/title","content_desc":"","class":"TextView","clickable":true,"scrollable":false,"bounds":"[40,200][500,300]","center_x":270,"center_y":250,"node_id":999,"parent_id":null,"window_id":7,"child_index":0,"depth":1,"package_name":"com.android.settings","editable":false,"focused":false,"checked":false,"enabled":true,"visible":true}]}"#
        let snapMsg = try codec.decodeFrame(Data(snapLine.utf8))
        guard case .snapshot(let snap) = snapMsg else {
            return XCTFail("Expected .snapshot")
        }
        XCTAssertEqual(snap.seq, 10)
        XCTAssertEqual(snap.activePackage, "com.android.settings")
        XCTAssertEqual(snap.nodes.count, 1)
        XCTAssertEqual(snap.nodes[0].nodeId, 999)
        XCTAssertNil(snap.nodes[0].parentId)
        XCTAssertEqual(snap.nodes[0].toCompactNode().resource_id, "com.android.settings:id/title")

        // 3. diff with explicit "parent_id": null vs omitted "parent_id"
        let diffLine = #"{"type":"diff","base_seq":10,"seq":11,"ts_ms":1700000050,"package":"com.android.settings","window_id":7,"event_type":2048,"event_package":"com.android.settings","inserted":[],"updated":[{"node_id":999,"mask":5,"parent_id":null,"text":"Brightness"},{"node_id":1000,"mask":4,"text":"Auto"}],"removed":[555]}"#
        let diffMsg = try codec.decodeFrame(Data(diffLine.utf8))
        guard case .diff(let diff) = diffMsg else {
            return XCTFail("Expected .diff")
        }
        XCTAssertEqual(diff.baseSeq, 10)
        XCTAssertEqual(diff.seq, 11)
        XCTAssertEqual(diff.removed, [555])
        XCTAssertEqual(diff.updated.count, 2)
        XCTAssertTrue(diff.updated[0].hasParentIdKey)
        XCTAssertNil(diff.updated[0].parentId)
        XCTAssertEqual(diff.updated[0].text, "Brightness")
        XCTAssertFalse(diff.updated[1].hasParentIdKey)
        XCTAssertEqual(diff.updated[1].text, "Auto")

        // 4. heartbeat, pong, error, and reordered-key JSON fallback
        guard case .heartbeat(let hb) = try codec.decodeFrame(Data(#"{"type":"heartbeat","seq":11,"ts_ms":100,"uptime_ms":500,"package":"com.android.settings","window_id":7,"clients":1}"#.utf8)) else {
            return XCTFail("Expected .heartbeat")
        }
        XCTAssertEqual(hb.clients, 1)

        guard case .pong(let pong) = try codec.decodeFrame(Data(#"{"seq":11,"ts_ms":123,"type":"pong"}"#.utf8)) else {
            return XCTFail("Expected .pong via fallback key order")
        }
        XCTAssertEqual(pong.timestampMs, 123)

        guard case .error(let err) = try codec.decodeFrame(Data(#"{"type":"error","code":"invalid_command","message":"bad","ts_ms":125}"#.utf8)) else {
            return XCTFail("Expected .error")
        }
        XCTAssertEqual(err.code, "invalid_command")

        // Error cases
        XCTAssertThrowsError(try codec.decodeFrame(Data()))
        XCTAssertThrowsError(try codec.decodeFrame(Data(#"{"type":"unknown_msg"}"#.utf8)))

        // Command encoding
        XCTAssertEqual(String(data: try codec.encodeCommand(.snapshot), encoding: .utf8), "{\"cmd\":\"snapshot\"}\n")
        XCTAssertEqual(String(data: try codec.encodeCommand(.ping), encoding: .utf8), "{\"cmd\":\"ping\"}\n")
        XCTAssertEqual(String(data: try codec.encodeCommand(.shutdown), encoding: .utf8), "{\"cmd\":\"shutdown\"}\n")
        XCTAssertEqual(String(data: try codec.encodeCommand(.setDebounce(ms: 30)), encoding: .utf8), "{\"cmd\":\"set_debounce\",\"ms\":30}\n")
        XCTAssertThrowsError(try codec.encodeCommand(.setDebounce(ms: -1)))
        XCTAssertThrowsError(try codec.encodeCommand(.setDebounce(ms: 9999)))
    }

    // MARK: - 2. LineFramer Tests

    func testLineFramerHandlesFragmentsUTF8SplitsCRLFAndMaxFrameLimit() throws {
        var framer = LineFramer(maxFrameBytes: 64)

        // Multi-byte UTF-8 Cyrillic + Emoji split right in the middle of codepoints
        let line1 = "{\"text\":\"Привет 🚀\"}"
        let line2 = "{\"ok\":true}"
        let combined = Data((line1 + "\r\n" + "\n" + line2 + "\n" + "{\"tail\":1").utf8)

        // Feed byte-by-byte / small uneven slices (including non-zero startIndex slices)
        var collected: [Data] = []
        var offset = 0
        let stepSizes = [3, 5, 2, 7, 4, 1, 8, 50]
        var stepIdx = 0
        while offset < combined.count {
            let step = stepSizes[stepIdx % stepSizes.count]
            stepIdx += 1
            let end = min(combined.count, offset + step)
            let slice = combined[offset..<end] // deliberately non-zero startIndex after first iteration
            collected.append(contentsOf: try framer.append(slice))
            offset = end
        }

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(String(data: collected[0], encoding: .utf8), line1)
        XCTAssertEqual(String(data: collected[1], encoding: .utf8), line2)
        XCTAssertEqual(framer.bufferedByteCount, "{\"tail\":1".utf8.count)

        // Complete the trailing frame
        let tailFrames = try framer.append(Data("}\n".utf8))
        XCTAssertEqual(tailFrames.count, 1)
        XCTAssertEqual(String(data: tailFrames[0], encoding: .utf8), "{\"tail\":1}")
        XCTAssertEqual(framer.bufferedByteCount, 0)

        // Oversized line must throw and immediately purge buffered bytes
        let oversized = Data(repeating: UInt8(ascii: "a"), count: 65)
        XCTAssertThrowsError(try framer.append(oversized)) { error in
            guard case LineFramerError.frameTooLarge(let byteCount, let limit) = error else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertEqual(byteCount, 65)
            XCTAssertEqual(limit, 64)
        }
        XCTAssertEqual(framer.bufferedByteCount, 0)

        // Works cleanly again after overflow reset
        let recovered = try framer.append(Data("{\"recovered\":1}\n".utf8))
        XCTAssertEqual(recovered.count, 1)
    }

    // MARK: - 3. ShadowDOMState Tests

    func testShadowDOMStateSnapshotDiffQueriesAndGapResync() async {
        actor ResyncCounter {
            var count = 0
            func inc() { count += 1 }
        }
        let counter = ResyncCounter()
        let dom = ShadowDOMState(resyncCooldownSeconds: 0.0) {
            await counter.inc()
        }

        // Cold diff before snapshot triggers resync
        await dom.handleMessage(.diff(WireDiffPayload(
            baseSeq: 1,
            seq: 2,
            timestampMs: 100,
            activePackage: "com.test",
            activeWindowId: 1
        )))
        let countAfterColdDiff = await counter.count
        XCTAssertEqual(countAfterColdDiff, 1)

        // Initial snapshot
        let root = makeNode(
            nodeId: 1,
            parentId: nil,
            index: 0,
            className: "FrameLayout",
            resourceId: "com.test:id/root",
            text: ""
        )
        let label = makeNode(
            nodeId: 2,
            parentId: 1,
            index: 1,
            className: "TextView",
            resourceId: "com.test:id/label_confirm",
            text: "Confirm",
            clickable: false
        )
        let btn = makeNode(
            nodeId: 3,
            parentId: 1,
            index: 2,
            className: "Button",
            resourceId: "com.test:id/btn_confirm",
            text: "Confirm",
            clickable: true
        )
        let oldBanner = makeNode(
            nodeId: 4,
            parentId: 1,
            index: 3,
            className: "TextView",
            resourceId: "com.test:id/banner",
            text: "Old Banner"
        )

        await dom.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10,
            timestampMs: 1000,
            reason: "initial",
            activePackage: "com.test",
            activeWindowId: 1,
            nodeCount: 4,
            nodes: [root, label, btn, oldBanner]
        )))

        let tree = await dom.getCurrentTree()
        XCTAssertEqual(tree.count, 4)
        let compact = await dom.getCompactTree()
        XCTAssertEqual(compact.count, 4)

        // O(1) lookup + clickable preference
        let foundConfirm = await dom.findNode(byText: "Confirm", mode: .containsCaseInsensitive, preferClickable: true)
        XCTAssertEqual(foundConfirm?.nodeId, 3)

        let foundByShortId = await dom.findNode(byResourceID: "btn_confirm")
        XCTAssertEqual(foundByShortId?.nodeId, 3)

        let childIds = await dom.children(ofId: 1).map(\.nodeId)
        XCTAssertEqual(childIds, [2, 3, 4])

        // Apply valid diff (seq 10 -> 11): patch btn text & clear parent_id explicitly to nil, remove node 4, insert node 5
        let newNode = makeNode(
            nodeId: 5,
            parentId: 1,
            index: 4,
            className: "ImageButton",
            resourceId: "com.test:id/fab",
            contentDesc: "Create New Item",
            clickable: true
        )
        let patchMask = ShadowPatchMask.parent.rawValue | ShadowPatchMask.text.rawValue | ShadowPatchMask.bounds.rawValue
        let patch = WireNodePatch(
            nodeId: 3,
            mask: patchMask,
            parentId: nil,
            hasParentIdKey: true,
            text: "Submit Order",
            bounds: "[100,200][300,300]",
            centerX: 200,
            centerY: 250
        )

        await dom.handleMessage(.diff(WireDiffPayload(
            baseSeq: 10,
            seq: 11,
            timestampMs: 1050,
            activePackage: "com.test",
            activeWindowId: 1,
            inserted: [newNode],
            updated: [patch],
            removed: [4]
        )))

        let removedLookup = await dom.node(forId: 4)
        XCTAssertNil(removedLookup)

        let patchedBtn = await dom.node(forId: 3)
        XCTAssertEqual(patchedBtn?.text, "Submit Order")
        XCTAssertNil(patchedBtn?.parentId)
        XCTAssertEqual(patchedBtn?.centerX, 200)

        let descMatch = await dom.findNode(byContentDesc: "create new")
        XCTAssertEqual(descMatch?.nodeId, 5)

        // Sequence gap (baseSeq 99 != current 11) must trigger resync without corrupting current state
        await dom.handleMessage(.diff(WireDiffPayload(
            baseSeq: 99,
            seq: 100,
            timestampMs: 2000,
            activePackage: "com.test",
            activeWindowId: 1
        )))
        let countAfterGap = await counter.count
        XCTAssertEqual(countAfterGap, 2)
        let meta = await dom.getSnapshotMetadata()
        XCTAssertEqual(meta?.seq, 11)
    }

    // MARK: - 4. SpatialGraphEngine Tests

    func testSpatialGraphEngineJitterStabilityAndCyclicMultigraphWithAcyclicSpanningDAG() async throws {
        let engine = SpatialGraphEngine(significanceThreshold: 0.72)

        func makeScreenUpdate(
            seq: UInt64,
            package: String,
            clockText: String,
            items: [(id: String, text: String, clickable: Bool)]
        ) -> ShadowDOMUpdate {
            var nodes: [ShadowUINode] = [
                makeNode(
                    nodeId: 1,
                    index: 0,
                    packageName: "com.android.systemui",
                    className: "TextView",
                    resourceId: "com.android.systemui:id/clock",
                    text: clockText
                )
            ]
            for (idx, item) in items.enumerated() {
                nodes.append(makeNode(
                    nodeId: Int64(idx + 10),
                    index: idx + 1,
                    packageName: package,
                    className: item.clickable ? "Button" : "TextView",
                    resourceId: item.id,
                    text: item.text,
                    clickable: item.clickable
                ))
            }
            let index = ShadowTreeIndex(
                seq: seq,
                timestampMs: Int64(seq * 100),
                activePackage: package,
                activeWindowId: 1,
                nodes: nodes
            )
            return ShadowDOMUpdate(index: index, isFullSnapshot: true, insertedCount: nodes.count, updatedCount: 0, removedCount: 0)
        }

        // Screen A: Home
        let home1 = makeScreenUpdate(seq: 1, package: "com.launcher", clockText: "13:49", items: [
            ("com.launcher:id/settings", "Settings", true),
            ("com.launcher:id/camera", "Camera", true),
            ("com.launcher:id/phone", "Phone", true)
        ])
        let edge1 = await engine.process(update: home1)
        XCTAssertNil(edge1)
        let homeHash = await engine.currentStateHash!

        // Clock tick + systemui noise on Home -> must stay same hash & zero new vertices
        let homeClockTick = makeScreenUpdate(seq: 2, package: "com.launcher", clockText: "13:50", items: [
            ("com.launcher:id/settings", "Settings", true),
            ("com.launcher:id/camera", "Camera", true),
            ("com.launcher:id/phone", "Phone", true)
        ])
        let edgeTick = await engine.process(update: homeClockTick)
        XCTAssertNil(edgeTick)
        let vCount1 = await engine.vertexCount
        XCTAssertEqual(vCount1, 1)

        // Screen B: Settings (attributed tap)
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 200, y: 400))
        let settings = makeScreenUpdate(seq: 3, package: "com.android.settings", clockText: "13:50", items: [
            ("com.android.settings:id/network", "Network & internet", true),
            ("com.android.settings:id/display", "Display & touch", true),
            ("com.android.settings:id/battery", "Battery", true)
        ])
        let eHomeToSettings = await engine.process(update: settings)
        XCTAssertNotNil(eHomeToSettings)
        XCTAssertEqual(eHomeToSettings?.action?.targetDescription, "Settings")
        XCTAssertTrue(eHomeToSettings?.isSpanningTreeEdge == true)
        let settingsHash = await engine.currentStateHash!

        // Screen C: Display
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Display & touch", x: 300, y: 700))
        let display = makeScreenUpdate(seq: 4, package: "com.android.settings", clockText: "13:51", items: [
            ("com.android.settings:id/brightness", "Brightness level", true),
            ("com.android.settings:id/dark_theme", "Dark theme", true),
            ("com.android.settings:id/timeout", "Screen timeout", true)
        ])
        let eSettingsToDisplay = await engine.process(update: display)
        XCTAssertNotNil(eSettingsToDisplay)
        let displayHash = await engine.currentStateHash!

        // Cyclic return: Display -> Settings -> Home via BACK
        await engine.recordPendingAction(AttributedUIAction(kind: .keyevent, targetDescription: "BACK"))
        _ = await engine.process(update: settings)
        await engine.recordPendingAction(AttributedUIAction(kind: .keyevent, targetDescription: "HOME"))
        _ = await engine.process(update: home1)

        // Revisit Home -> Settings with same action aggregates traversalCount instead of duplicating vertex/edge
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 200, y: 400))
        let revisitedEdge = await engine.process(update: settings)
        XCTAssertEqual(revisitedEdge?.traversalCount, 2)

        // Revisit Settings -> Home with a DIFFERENT action creates a parallel multigraph edge
        await engine.recordPendingAction(AttributedUIAction(kind: .swipe, targetDescription: "up"))
        _ = await engine.process(update: display)
        await engine.recordPendingAction(AttributedUIAction(kind: .keyevent, targetDescription: "BACK"))
        _ = await engine.process(update: settings)
        let settingsNeighbors = await engine.neighbors(of: settingsHash)
        XCTAssertGreaterThanOrEqual(settingsNeighbors.count, 2)

        let finalVertexCount = await engine.vertexCount
        XCTAssertEqual(finalVertexCount, 3)

        let acyclic = await engine.isSpanningDAGAcyclic()
        XCTAssertTrue(acyclic, "First-discovery spanning DAG must remain strictly acyclic despite UI cycles")

        let path = await engine.spanningPathFromRoot(to: displayHash)
        XCTAssertEqual(path, [homeHash, settingsHash, displayHash])

        let json = try await engine.exportGraphJSON()
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("com.android.settings"))
    }

    // MARK: - 5. DaemonTCPClient + ShadowGraphBridge Loopback Tests

    func testDaemonTCPClientAndShadowGraphBridgeLiveLoopbackStreamingAndRecovery() async throws {
        // Bind ephemeral loopback NWListener simulating Layer 1 android-daemon
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        let listenerQueue = DispatchQueue(label: "test.mock.daemon.listener")

        final class ServerHarness: @unchecked Sendable {
            let lock = NSLock()
            var connections: [NWConnection] = []
            var receivedCommands: [String] = []
            var connectionCount = 0
        }
        let harness = ServerHarness()

        let readyExp = expectation(description: "NWListener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readyExp.fulfill()
            }
        }

        listener.newConnectionHandler = { conn in
            let idx: Int = harness.lock.withLock {
                harness.connectionCount += 1
                harness.connections.append(conn)
                return harness.connectionCount
            }
            conn.start(queue: listenerQueue)

            let hello = #"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":36,"device_model":"MockPixel","pid":101}"# + "\n"
            let snap = #"{"type":"snapshot","seq":1,"ts_ms":1000,"reason":"initial","package":"com.demo","window_id":1,"node_count":1,"nodes":[{"index":0,"text":"Live Item","resource_id":"com.demo:id/item","content_desc":"","class":"TextView","clickable":true,"scrollable":false,"bounds":"[10,20][110,120]","center_x":60,"center_y":70,"node_id":77,"parent_id":null,"window_id":1,"child_index":0,"depth":1,"package_name":"com.demo","editable":false,"focused":false,"checked":false,"enabled":true,"visible":true}]}"# + "\n"

            // Send fragmented across two writes on connection #1 to exercise NWConnection + LineFramer
            let fullBytes = Data((hello + snap).utf8)
            let splitPoint = fullBytes.count / 2
            conn.send(content: fullBytes.subdata(in: 0..<splitPoint), completion: .contentProcessed { _ in
                conn.send(content: fullBytes.subdata(in: splitPoint..<fullBytes.count), completion: .contentProcessed { _ in })
            })

            func readLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        let text = String(decoding: data, as: UTF8.self)
                        harness.lock.withLock {
                            harness.receivedCommands.append(text)
                        }
                        if text.contains("\"ping\"") {
                            let pong = "{\"type\":\"pong\",\"ts_ms\":2000,\"seq\":\(idx)}\n"
                            conn.send(content: Data(pong.utf8), completion: .contentProcessed { _ in })
                        }
                    }
                    if !isComplete && error == nil {
                        readLoop()
                    }
                }
            }
            readLoop()
        }

        listener.start(queue: listenerQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        defer { listener.cancel() }

        let boundPort = try XCTUnwrap(listener.port?.rawValue)

        actor ReconnectTracker {
            var attempts: [Int] = []
            func record(_ attempt: Int) { attempts.append(attempt) }
        }
        let reconnectTracker = ReconnectTracker()

        let config = DaemonEndpointConfiguration(
            host: "127.0.0.1",
            port: boundPort,
            initialReconnectDelay: 0.05,
            maxReconnectDelay: 0.2,
            heartbeatTimeout: 5.0
        )
        let bridge = ShadowGraphBridge(configuration: config) { attempt in
            await reconnectTracker.record(attempt)
        }

        // Before start: bridge must return nil immediately (0ms fallback signal)
        let t0 = Date()
        let preStartNodes = await bridge.fastCompactTreeIfFresh(maxWaitSeconds: 0.5)
        XCTAssertNil(preStartNodes)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1)

        await bridge.start()

        // Wait for initial snapshot via ShadowDOMState
        let index = await bridge.domState.waitForSnapshot(timeoutSeconds: 2.0)
        XCTAssertNotNil(index)

        // Sub-millisecond cached read
        let fastNodes = await bridge.fastCompactTreeIfFresh(maxWaitSeconds: 0.1)
        XCTAssertEqual(fastNodes?.count, 1)
        XCTAssertEqual(fastNodes?.first?.text, "Live Item")

        // Send ping command and verify server received it
        try await bridge.client.ping()
        for _ in 0..<20 {
            let cmds = harness.lock.withLock { harness.receivedCommands }
            if cmds.contains(where: { $0.contains("\"ping\"") }) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let cmds = harness.lock.withLock { harness.receivedCommands }
        XCTAssertTrue(cmds.contains(where: { $0.contains("\"ping\"") }))

        // Force disconnect on server connection #1 and verify beforeReconnect + automatic recovery on #2
        harness.lock.withLock {
            harness.connections.first?.cancel()
        }
        for _ in 0..<40 {
            let count = harness.lock.withLock { harness.connectionCount }
            let isConn = await bridge.client.state.isConnected
            if count >= 2 && isConn { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let finalConnCount = harness.lock.withLock { harness.connectionCount }
        let reconnects = await reconnectTracker.attempts
        XCTAssertGreaterThanOrEqual(finalConnCount, 2)
        XCTAssertFalse(reconnects.isEmpty)

        await bridge.stop()
        let stoppedState = await bridge.client.state
        XCTAssertEqual(stoppedState, .stopped)
    }

    // MARK: - 6. Additional Edge Cases (Timeouts, Watchdog, Buffer Shrink, TTL)

    func testLineFramerEdgeCasesEmptyChunksSplitCRLFLargeSnapshotShrink() throws {
        var framer = LineFramer(maxFrameBytes: 512 * 1024)
        XCTAssertTrue(try framer.append(Data()).isEmpty)
        XCTAssertTrue(try framer.append(Data("\n\r\n\n".utf8)).isEmpty)

        // Split CRLF across chunk boundary: chunk 1 ends with \r, chunk 2 starts with \n
        XCTAssertTrue(try framer.append(Data("{\"a\":1}\r".utf8)).isEmpty)
        let splitFrames = try framer.append(Data("\n".utf8))
        XCTAssertEqual(splitFrames.count, 1)
        XCTAssertEqual(String(data: splitFrames[0], encoding: .utf8), "{\"a\":1}")

        // 4-byte emoji split 1 byte at a time
        let emojiBytes = Data("{\"e\":\"🥳\"}\n".utf8)
        var out: [Data] = []
        for i in 0..<emojiBytes.count {
            out.append(contentsOf: try framer.append(emojiBytes[i..<(i + 1)]))
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(String(data: out[0], encoding: .utf8), "{\"e\":\"🥳\"}")

        // Large frame (>256 KB) resets cleanly without holding buffer
        let large = Data(repeating: UInt8(ascii: "x"), count: 300 * 1024) + Data("\n".utf8)
        let largeFrames = try framer.append(large)
        XCTAssertEqual(largeFrames.count, 1)
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    func testShadowDOMStateWaiterCancellationDisconnectAndMissingPatchNode() async {
        actor Counter {
            var resyncs = 0
            func inc() { resyncs += 1 }
        }
        let counter = Counter()
        let dom = ShadowDOMState(resyncCooldownSeconds: 0) {
            await counter.inc()
        }

        // Timeout returns nil cleanly without hanging
        let timedOut = await dom.waitForSnapshot(timeoutSeconds: 0.05)
        XCTAssertNil(timedOut)

        // Cancellation returns cleanly
        let waitTask = Task {
            await dom.waitForSnapshot(timeoutSeconds: 5.0)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waitTask.cancel()
        let cancelledResult = await waitTask.value
        XCTAssertNil(cancelledResult)

        // Seed snapshot seq 5
        let node1 = makeNode(nodeId: 1, index: 0, text: "Item")
        await dom.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 5,
            timestampMs: 100,
            reason: "initial",
            activePackage: "com.test",
            activeWindowId: 1,
            nodeCount: 1,
            nodes: [node1]
        )))
        let freshBeforeDisconnect = await dom.isFresh(maxAgeSeconds: 10.0)
        XCTAssertTrue(freshBeforeDisconnect)

        // Stale diff seq <= 5 ignored without resync
        await dom.handleMessage(.diff(WireDiffPayload(
            baseSeq: 4,
            seq: 5,
            timestampMs: 110,
            activePackage: "com.test",
            activeWindowId: 1
        )))
        let resyncsAfterStale = await counter.resyncs
        XCTAssertEqual(resyncsAfterStale, 0)

        // Diff patching non-existent node_id 999 triggers resync and preserves node 1
        await dom.handleMessage(.diff(WireDiffPayload(
            baseSeq: 5,
            seq: 6,
            timestampMs: 120,
            activePackage: "com.test",
            activeWindowId: 1,
            updated: [WireNodePatch(nodeId: 999, mask: ShadowPatchMask.text.rawValue, text: "Ghost")]
        )))
        let resyncsAfterMissingNode = await counter.resyncs
        XCTAssertEqual(resyncsAfterMissingNode, 1)
        let retained = await dom.node(forId: 1)
        XCTAssertEqual(retained?.text, "Item")

        await dom.markDisconnected()
        let freshAfterDisconnect = await dom.isFresh(maxAgeSeconds: 10.0)
        XCTAssertFalse(freshAfterDisconnect)
    }

    func testDaemonTCPClientHeartbeatWatchdogTriggersReconnectAndRejectsDisconnectedSends() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        let queue = DispatchQueue(label: "test.watchdog.listener")

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            var conns: [NWConnection] = []
        }
        let box = Box()
        let readyExp = expectation(description: "listener ready")
        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            box.lock.withLock {
                box.count += 1
                box.conns.append(conn)
            }
            conn.start(queue: queue)
            // Intentionally send nothing -> triggers heartbeatTimeout watchdog!
        }
        listener.start(queue: queue)
        await fulfillment(of: [readyExp], timeout: 2.0)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = DaemonTCPClient(configuration: DaemonEndpointConfiguration(
            host: "127.0.0.1",
            port: port,
            initialReconnectDelay: 0.05,
            maxReconnectDelay: 0.1,
            heartbeatTimeout: 0.5
        ))

        do {
            try await client.ping()
            XCTFail("Expected notConnected before start")
        } catch let err as DaemonClientError {
            XCTAssertEqual(err, .notConnected)
        }

        await client.start()
        for _ in 0..<40 {
            if box.lock.withLock({ box.count }) >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(box.lock.withLock({ box.count }), 2, "Watchdog should reconnect on silent connection")

        await client.stop()
        do {
            try await client.ping()
            XCTFail("Expected stopped after stop()")
        } catch let err as DaemonClientError {
            XCTAssertEqual(err, .stopped)
        }
    }

    func testSpatialGraphEngineExpiredPendingActionAndReset() async {
        let engine = SpatialGraphEngine(significanceThreshold: 0.72, pendingActionTTL: 0.1)
        let s1 = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.a", activeWindowId: 1, nodes: [
            makeNode(nodeId: 1, index: 0, packageName: "com.a", resourceId: "com.a:id/one", text: "One", clickable: true)
        ])
        let s2 = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.b", activeWindowId: 2, nodes: [
            makeNode(nodeId: 2, index: 0, packageName: "com.b", resourceId: "com.b:id/two", text: "Two", clickable: true)
        ])

        await engine.process(update: ShadowDOMUpdate(index: s1, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))

        // Record an action already expired in the past
        await engine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Stale",
            timestamp: Date().addingTimeInterval(-10.0)
        ))
        let edge = await engine.process(update: ShadowDOMUpdate(index: s2, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        XCTAssertNotNil(edge)
        XCTAssertNil(edge?.action)
        XCTAssertEqual(edge?.actionSignature, "implicit")

        let predecessors = await engine.predecessors(of: edge!.toHash)
        XCTAssertEqual(predecessors.count, 1)

        await engine.reset()
        let vCount = await engine.vertexCount
        let eCount = await engine.edgeCount
        XCTAssertEqual(vCount, 0)
        XCTAssertEqual(eCount, 0)
    }

    func testShadowDOMStateRejectsStalePreDisconnectSnapshotAfterHelloUntilNewSnapshotArrives() async {
        let dom = ShadowDOMState()
        let oldNode = makeNode(nodeId: 1, index: 0, text: "Stale Screen")
        await dom.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 10,
            timestampMs: 100,
            reason: "initial",
            activePackage: "com.old",
            activeWindowId: 1,
            nodeCount: 1,
            nodes: [oldNode]
        )))
        let fresh1 = await dom.isFresh(maxAgeSeconds: 10.0)
        XCTAssertTrue(fresh1)

        // Disconnect clears session snapshot freshness and wakes any pending waiters immediately
        let waiterTask = Task { () -> ShadowTreeIndex? in
            await dom.markDisconnected()
            return await dom.waitForSnapshot(timeoutSeconds: 5.0)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await dom.markDisconnected()
        let t0 = Date()
        let woken = await waiterTask.value
        XCTAssertNil(woken)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)

        // Receiving .hello on reconnect must NOT mark stale pre-disconnect tree as fresh
        await dom.handleMessage(.hello(WireHelloPayload(
            protocolVersion: 1,
            format: "ndjson/1",
            sdkInt: 37,
            deviceModel: "Pixel 10a",
            pid: 999
        )))
        let freshAfterHello = await dom.isFresh(maxAgeSeconds: 10.0)
        XCTAssertFalse(freshAfterHello)

        // waitForSnapshot must actually wait for the NEW snapshot instead of returning oldNode immediately
        let newNode = makeNode(nodeId: 2, index: 0, text: "Fresh Screen")
        let waitForNewTask = Task {
            await dom.waitForSnapshot(timeoutSeconds: 2.0)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await dom.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 1,
            timestampMs: 200,
            reason: "initial",
            activePackage: "com.new",
            activeWindowId: 2,
            nodeCount: 1,
            nodes: [newNode]
        )))
        let resolvedNew = await waitForNewTask.value
        XCTAssertEqual(resolvedNew?.activePackage, "com.new")
        XCTAssertEqual(resolvedNew?.orderedNodes.first?.text, "Fresh Screen")
    }

    func testDaemonTCPClientDoesNotResetBackoffOnImmediateEOFWithoutValidFrames() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        let queue = DispatchQueue(label: "test.immediate.eof.listener")

        let readyExp = expectation(description: "listener ready")
        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            // Simulate adb forward when daemon isn't listening on device: accept TCP then immediately close!
            conn.cancel()
        }
        listener.start(queue: queue)
        await fulfillment(of: [readyExp], timeout: 2.0)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        actor AttemptBox {
            var attempts: [Int] = []
            func append(_ a: Int) { attempts.append(a) }
        }
        let box = AttemptBox()

        let client = DaemonTCPClient(
            configuration: DaemonEndpointConfiguration(
                host: "127.0.0.1",
                port: port,
                initialReconnectDelay: 0.05,
                maxReconnectDelay: 0.5,
                heartbeatTimeout: 2.0
            ),
            beforeReconnect: { attempt in
                await box.append(attempt)
            }
        )
        await client.start()
        for _ in 0..<30 {
            if await box.attempts.count >= 3 { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        await client.stop()

        let attempts = await box.attempts
        XCTAssertGreaterThanOrEqual(attempts.count, 3)
        XCTAssertEqual(Array(attempts.prefix(3)), [1, 2, 3], "Backoff attempt must monotonically increment on immediate EOF")
    }

    func testSpatialGraphEnginePreservesPendingActionAcrossJitterEmptyAndTransientSystemUIFrames() async {
        let engine = SpatialGraphEngine(significanceThreshold: 0.72, pendingActionTTL: 5.0)

        let screenA = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.android.settings", activeWindowId: 1, nodes: [
            makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", resourceId: "com.android.settings:id/a", text: "Network and Internet", clickable: true),
            makeNode(nodeId: 2, index: 1, packageName: "com.android.settings", resourceId: "com.android.settings:id/b", text: "Connected devices", clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.android.settings", resourceId: "com.android.settings:id/c", text: "Apps", clickable: true),
            makeNode(nodeId: 4, index: 3, packageName: "com.android.settings", resourceId: "com.android.settings:id/d", text: "Battery", clickable: true)
        ])
        await engine.process(update: ShadowDOMUpdate(index: screenA, isFullSnapshot: true, insertedCount: 4, updatedCount: 0, removedCount: 0))

        // Record tap action, then emit: (1) jitter frame, (2) empty-token diff frame, (3) transient non-interactive systemui frame
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Network and Internet", x: 400, y: 700))

        // Jaccard 4/5 = 0.80 >= 0.72 so it's suppressed as jitter
        let jitterAHigh = ShadowTreeIndex(seq: 2, timestampMs: 110, activePackage: "com.android.settings", activeWindowId: 1, nodes: [
            makeNode(nodeId: 1, index: 0, packageName: "com.android.settings", resourceId: "com.android.settings:id/a", text: "Network and Internet", clickable: true),
            makeNode(nodeId: 2, index: 1, packageName: "com.android.settings", resourceId: "com.android.settings:id/b", text: "Connected devices", clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.android.settings", resourceId: "com.android.settings:id/c", text: "Apps", clickable: true),
            makeNode(nodeId: 4, index: 3, packageName: "com.android.settings", resourceId: "com.android.settings:id/d", text: "Battery", clickable: true),
            makeNode(nodeId: 5, index: 4, packageName: "com.android.settings", resourceId: "com.android.settings:id/e", text: "Ripple", clickable: false)
        ])
        let eJitter = await engine.process(update: ShadowDOMUpdate(index: jitterAHigh, isFullSnapshot: false, insertedCount: 1, updatedCount: 0, removedCount: 0))
        XCTAssertNil(eJitter)

        let emptyTransition = ShadowTreeIndex(seq: 3, timestampMs: 120, activePackage: "com.android.settings", activeWindowId: 1, nodes: [
            makeNode(nodeId: 90, index: 0, packageName: "com.android.systemui", resourceId: "com.android.systemui:id/clock", text: "14:04", clickable: false)
        ])
        let eEmpty = await engine.process(update: ShadowDOMUpdate(index: emptyTransition, isFullSnapshot: false, insertedCount: 0, updatedCount: 0, removedCount: 5))
        XCTAssertNil(eEmpty)

        let transientSystemUI = ShadowTreeIndex(seq: 4, timestampMs: 130, activePackage: "com.android.systemui", activeWindowId: 2, nodes: [
            makeNode(nodeId: 91, index: 0, packageName: "com.android.systemui", resourceId: "com.android.systemui:id/status_bar", text: "", clickable: false)
        ])
        let eSysUI = await engine.process(update: ShadowDOMUpdate(index: transientSystemUI, isFullSnapshot: true, insertedCount: 1, updatedCount: 0, removedCount: 0))
        XCTAssertNil(eSysUI)

        // Now actual destination screen B arrives -> must still receive the attributed tap edge directly from A!
        let screenB = ShadowTreeIndex(seq: 5, timestampMs: 160, activePackage: "com.android.settings", activeWindowId: 3, nodes: [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", resourceId: "com.android.settings:id/internet", text: "Internet", clickable: true),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", resourceId: "com.android.settings:id/sims", text: "SIMs", clickable: true),
            makeNode(nodeId: 12, index: 2, packageName: "com.android.settings", resourceId: "com.android.settings:id/airplane", text: "Aeroplane mode", clickable: true)
        ])
        let eDest = await engine.process(update: ShadowDOMUpdate(index: screenB, isFullSnapshot: true, insertedCount: 3, updatedCount: 0, removedCount: 0))
        XCTAssertNotNil(eDest)
        XCTAssertEqual(eDest?.action?.targetDescription, "Network and Internet")
        let rootHash = await engine.rootStateHash
        XCTAssertEqual(eDest?.fromHash, rootHash)
        let vertexCount = await engine.vertexCount
        XCTAssertEqual(vertexCount, 2)
    }

    func testScreenLayoutHasherNormalizesClocksTimesDatesAndProtectsNonDateStrings() {
        // 24h / 12h / seconds / narrow non-breaking space / AM-PM / Cyrillic AM-PM
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("16:19"), "<TIME>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("16:19:05"), "<TIME>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("5:54\u{202F}pm"), "<TIME>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("11:59 a.m."), "<TIME>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("12:00am"), "<TIME>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("12:00 дп"), "<TIME>")

        // Weekday / month / year / time rollovers
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("Sun, 15 Nov"),
            ScreenLayoutHasher.normalizeLabel("Mon, 1 Dec")
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("Sun, May 15"),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("Sun, Mar. 15"),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("Sun, 15. Nov"),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("May, 15"),
            "<DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("Sunday, 15 Nov, 5:54\u{202F}pm"),
            ScreenLayoutHasher.normalizeLabel("Wednesday, December 2, 11:05 AM")
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("15 May"),
            ScreenLayoutHasher.normalizeLabel("3 March")
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("May 15"),
            ScreenLayoutHasher.normalizeLabel("Mar. 3")
        )

        // Russian date & time formats (including ICU short months февр., июн., июл.)
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("воскресенье, 15 ноября"),
            ScreenLayoutHasher.normalizeLabel("пт, 4 дек.")
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("вс, 15 февр."),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("пн, 16 июн."),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("вт, 17 июл."),
            "<DAY>, <DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("15 нояб. 2026 г."),
            "<DATE>"
        )
        XCTAssertEqual(
            ScreenLayoutHasher.normalizeLabel("сегодня, 12:30"),
            ScreenLayoutHasher.normalizeLabel("завтра, 08:05:19")
        )

        // Non-date / non-clock text must not be falsely collapsed
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("5 things you may like"), "# things you may like")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("March"), "March")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("Sunny"), "Sunny")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("59 %"), "# %")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("42 unread"), "# unread")
    }

    func testHomeScreenClockAndDateChangesProduceIdenticalHashAndZeroNewNodes() async {
        let hasher = ScreenLayoutHasher()
        let engine = SpatialGraphEngine(hasher: hasher)

        func makeHomeIndex(
            seq: UInt64,
            statusTime: String,
            emptyPkgStatusTime: String,
            launcherDate: String,
            deskClockA11y: String,
            textClockText: String
        ) -> ShadowTreeIndex {
            ShadowTreeIndex(
                seq: seq,
                timestampMs: Int64(seq * 1000),
                activePackage: "com.google.android.apps.nexuslauncher",
                activeWindowId: 10,
                nodes: [
                    // Status bar clock with systemui package
                    makeNode(
                        nodeId: 1, index: 0,
                        packageName: "com.android.systemui",
                        className: "android.widget.TextView",
                        resourceId: "com.android.systemui:id/clock",
                        text: statusTime,
                        clickable: false
                    ),
                    // Status bar clock where Android Accessibility leaves packageName empty
                    makeNode(
                        nodeId: 2, index: 1,
                        packageName: "",
                        className: "android.widget.TextView",
                        resourceId: "com.android.systemui:id/clock",
                        text: emptyPkgStatusTime,
                        clickable: false
                    ),
                    // Pixel Launcher smartspace date
                    makeNode(
                        nodeId: 3, index: 2,
                        packageName: "com.google.android.apps.nexuslauncher",
                        className: "android.widget.TextView",
                        resourceId: "com.google.android.apps.nexuslauncher:id/date",
                        text: launcherDate,
                        clickable: true
                    ),
                    // DeskClock widget (Pixel 10a)
                    makeNode(
                        nodeId: 4, index: 3,
                        packageName: "com.google.android.deskclock",
                        className: "android.widget.TextView",
                        resourceId: "com.google.android.deskclock:id/a11y_clock",
                        contentDesc: deskClockA11y,
                        clickable: true
                    ),
                    // Generic TextClock view
                    makeNode(
                        nodeId: 5, index: 4,
                        packageName: "com.google.android.deskclock",
                        className: "android.widget.TextClock",
                        resourceId: "com.google.android.deskclock:id/digital_clock",
                        text: textClockText,
                        clickable: true
                    ),
                    // Static launcher icons
                    makeNode(
                        nodeId: 6, index: 5,
                        packageName: "com.google.android.apps.nexuslauncher",
                        className: "android.widget.TextView",
                        resourceId: "com.google.android.apps.nexuslauncher:id/icon",
                        text: "Chrome",
                        clickable: true
                    ),
                    makeNode(
                        nodeId: 7, index: 6,
                        packageName: "com.google.android.apps.nexuslauncher",
                        className: "android.widget.TextView",
                        resourceId: "com.google.android.apps.nexuslauncher:id/icon",
                        text: "Phone",
                        clickable: true
                    ),
                    makeNode(
                        nodeId: 8, index: 7,
                        packageName: "com.google.android.apps.nexuslauncher",
                        className: "android.widget.TextView",
                        resourceId: "com.google.android.apps.nexuslauncher:id/icon",
                        text: "Camera",
                        clickable: true
                    )
                ]
            )
        }

        let frames = [
            makeHomeIndex(seq: 1, statusTime: "16:19", emptyPkgStatusTime: "16:19:01", launcherDate: "Sun, 15 Nov", deskClockA11y: "Sunday, 15 Nov, 4:19\u{202F}pm", textClockText: "16:19"),
            makeHomeIndex(seq: 2, statusTime: "16:20", emptyPkgStatusTime: "16:20:59", launcherDate: "Sun, 15 Nov", deskClockA11y: "Sunday, 15 Nov, 4:20\u{202F}pm", textClockText: "4:20 PM"),
            makeHomeIndex(seq: 3, statusTime: "00:00", emptyPkgStatusTime: "00:00:00", launcherDate: "Mon, 16 Nov", deskClockA11y: "Monday, 16 Nov, 12:00\u{202F}am", textClockText: "12:00 a.m."),
            makeHomeIndex(seq: 4, statusTime: "09:05", emptyPkgStatusTime: "09:05:12", launcherDate: "Tue, 1 Dec", deskClockA11y: "Tuesday, 1 Dec, 9:05\u{202F}am", textClockText: "09:05:12")
        ]

        let fp0 = hasher.fingerprint(for: frames[0])
        // Non-temporal interactive labels must come before temporal widget labels
        XCTAssertEqual(Array(fp0.sampleInteractiveLabels.prefix(3)), ["Chrome", "Phone", "Camera"])

        for (i, frame) in frames.enumerated() {
            let fp = hasher.fingerprint(for: frame)
            XCTAssertEqual(fp.layoutHash, fp0.layoutHash, "Frame \(i) hash drifted due to time/date change")
            XCTAssertEqual(fp.tokens, fp0.tokens, "Frame \(i) tokens drifted due to time/date change")

            let edge = await engine.process(update: ShadowDOMUpdate(index: frame, isFullSnapshot: i == 0, insertedCount: i == 0 ? 8 : 0, updatedCount: i == 0 ? 0 : 4, removedCount: 0))
            XCTAssertNil(edge)
        }

        let vertexCount = await engine.vertexCount
        let edgeCount = await engine.edgeCount
        XCTAssertEqual(vertexCount, 1)
        XCTAssertEqual(edgeCount, 0)

        // Live ShadowDOMState must still expose exact live clock text for agent reads
        XCTAssertEqual(frames.last?.nodesById[3]?.text, "Tue, 1 Dec")
        XCTAssertEqual(frames.last?.nodesById[5]?.text, "09:05:12")
    }

    func testLockscreenSystemUIClockTicksProduceIdenticalHash() async {
        let hasher = ScreenLayoutHasher()
        let engine = SpatialGraphEngine(hasher: hasher)

        func makeLockscreen(seq: UInt64, clock: String, date: String) -> ShadowTreeIndex {
            ShadowTreeIndex(
                seq: seq,
                timestampMs: Int64(seq * 1000),
                activePackage: "com.android.systemui",
                activeWindowId: 1,
                nodes: [
                    makeNode(nodeId: 1, index: 0, packageName: "com.android.systemui", className: "android.widget.TextClock", resourceId: "com.android.systemui:id/keyguard_clock", text: clock, clickable: false),
                    makeNode(nodeId: 2, index: 1, packageName: "com.android.systemui", className: "android.widget.TextView", resourceId: "com.android.systemui:id/keyguard_date", text: date, clickable: false),
                    makeNode(nodeId: 3, index: 2, packageName: "com.android.systemui", className: "android.widget.ImageView", resourceId: "com.android.systemui:id/lock_icon", contentDesc: "Unlock", clickable: true)
                ]
            )
        }

        let lock1 = makeLockscreen(seq: 1, clock: "11:59", date: "Sun, 15 Nov")
        let lock2 = makeLockscreen(seq: 2, clock: "12:00 pm", date: "Mon, 1 Dec")

        XCTAssertEqual(hasher.fingerprint(for: lock1).layoutHash, hasher.fingerprint(for: lock2).layoutHash)
        _ = await engine.process(update: ShadowDOMUpdate(index: lock1, isFullSnapshot: true, insertedCount: 3, updatedCount: 0, removedCount: 0))
        let edge = await engine.process(update: ShadowDOMUpdate(index: lock2, isFullSnapshot: false, insertedCount: 0, updatedCount: 2, removedCount: 0))
        XCTAssertNil(edge)
        let count = await engine.vertexCount
        XCTAssertEqual(count, 1)
    }

    func testSpatialGraphEngineDeduplicatesCanonicalHomeScreenAcrossAppReturnAndColdStartImport() async {
        let engine = SpatialGraphEngine()

        var homeNodes: [ShadowUINode] = [
            makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", resourceId: "com.google.android.apps.nexuslauncher:id/date", text: "Sun, 15 Nov", clickable: true),
            makeNode(nodeId: 2, index: 1, packageName: "com.google.android.deskclock", className: "android.widget.TextView", resourceId: "com.google.android.deskclock:id/a11y_clock", contentDesc: "Sunday, 15 Nov, 5:54\u{202F}pm", clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Phone", clickable: true),
            makeNode(nodeId: 4, index: 3, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Messages", clickable: true),
            makeNode(nodeId: 5, index: 4, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Chrome", clickable: true),
            makeNode(nodeId: 6, index: 5, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Camera", clickable: true),
            makeNode(nodeId: 7, index: 6, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Photos", clickable: true),
            makeNode(nodeId: 8, index: 7, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Gmail", clickable: true),
            makeNode(nodeId: 9, index: 8, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Settings", clickable: true),
            makeNode(nodeId: 10, index: 9, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", text: "Calendar", clickable: true),
            makeNode(nodeId: 11, index: 10, packageName: "com.google.android.apps.nexuslauncher", className: "android.view.View", resourceId: "com.google.android.apps.nexuslauncher:id/accessibility_action_view", text: "Home", clickable: false)
        ]

        let homeFull = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.google.android.apps.nexuslauncher", activeWindowId: 1, nodes: homeNodes)
        _ = await engine.process(update: ShadowDOMUpdate(index: homeFull, isFullSnapshot: true, insertedCount: homeNodes.count, updatedCount: 0, removedCount: 0))
        let canonicalHomeHash = await engine.rootStateHash!

        // Navigate to Settings
        await engine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings"))
        let settings = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 2, nodes: [
            makeNode(nodeId: 20, index: 0, packageName: "com.android.settings", text: "Network and Internet", clickable: true),
            makeNode(nodeId: 21, index: 1, packageName: "com.android.settings", text: "Connected devices", clickable: true)
        ])
        let edgeToSettings = await engine.process(update: ShadowDOMUpdate(index: settings, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        XCTAssertNotNil(edgeToSettings)
        let settingsHash = await engine.currentStateHash!
        XCTAssertNotEqual(settingsHash, canonicalHomeHash)

        // Return to Home after time changes AND 1 transient accessibility node is absent (10/11 = 0.909 >= 0.90)
        homeNodes[0] = makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", className: "android.widget.TextView", resourceId: "com.google.android.apps.nexuslauncher:id/date", text: "Mon, 16 Nov", clickable: true)
        homeNodes[1] = makeNode(nodeId: 2, index: 1, packageName: "com.google.android.deskclock", className: "android.widget.TextView", resourceId: "com.google.android.deskclock:id/a11y_clock", contentDesc: "Monday, 16 Nov, 8:03\u{202F}am", clickable: true)
        let homeMinusOneNodes = Array(homeNodes.dropLast()) // 10 of 11 tokens match canonicalHomeHash
        let homeReturn = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.google.android.apps.nexuslauncher", activeWindowId: 3, nodes: homeMinusOneNodes)

        await engine.recordPendingAction(AttributedUIAction(kind: .keyevent, targetDescription: "HOME"))
        let returnEdge = await engine.process(update: ShadowDOMUpdate(index: homeReturn, isFullSnapshot: true, insertedCount: homeMinusOneNodes.count, updatedCount: 0, removedCount: 0))

        XCTAssertNotNil(returnEdge)
        XCTAssertEqual(returnEdge?.toHash, canonicalHomeHash)
        let currentHash = await engine.currentStateHash
        XCTAssertEqual(currentHash, canonicalHomeHash)
        let vertexCount = await engine.vertexCount
        XCTAssertEqual(vertexCount, 2, "Returning to slightly-drifted Home screen must snap to canonical Home vertex")

        // Verify cold-start imported graph with currentStateHash == nil also snaps to canonical Home vertex
        let exported = await engine.snapshot()
        let clearedCursor = SpatialGraphSnapshot(
            rootStateHash: exported.rootStateHash,
            currentStateHash: nil,
            vertices: exported.vertices,
            edges: exported.edges,
            spanningChildren: exported.spanningChildren
        )
        let reimported = SpatialGraphEngine()
        await reimported.importSnapshot(clearedCursor)
        _ = await reimported.process(update: ShadowDOMUpdate(index: homeReturn, isFullSnapshot: true, insertedCount: homeMinusOneNodes.count, updatedCount: 0, removedCount: 0))
        let reimportedCurrent = await reimported.currentStateHash
        let reimportedVertices = await reimported.vertexCount
        // Reimported canonical Home screen must also snap when starting from legacy unnormalized tokens
        XCTAssertEqual(reimportedCurrent, canonicalHomeHash)
        XCTAssertEqual(reimportedVertices, 2)
    }

    func testLegacyPersistedHomeVertexCanonicalizesTokensAndRoutesWithoutSpawningDuplicateNode() async throws {
        let now = Date()
        let legacyHomeHash: UInt64 = 8_953_385_719_302_104_229
        let legacySettingsHash: UInt64 = 12_849_829_987_381_651_668

        // Exactly mirrors V00 in shadow_graph.json where 2 of 26 tokens were uncanonicalized clock/date strings
        // (24/28 = 0.8571 Jaccard without canonicalization, which previously failed the 0.90 threshold).
        let legacyHomeTokens: Set<String> = [
            "TextView|com.google.android.deskclock:id/a11y_clock|Sunday, # Nov, #:# pm",
            "TextView|com.google.android.apps.nexuslauncher:id/date|Sun, # Nov",
            "FrameLayout|com.google.android.deskclock:id/widget_frame|",
            "TextView||Settings",
            "TextView||Phone",
            "TextView||Messages",
            "TextView||Chrome",
            "TextView||Camera",
            "TextView||Photos",
            "TextView||Gmail",
            "TextView||YouTube",
            "TextView||Play Store",
            "TextView||Telegram",
            "ViewPager|com.google.android.apps.nexuslauncher:id/smartspace_card_pager|At a Glance",
            "ScrollView|com.google.android.apps.nexuslauncher:id/workspace|",
            "LauncherAppWidgetHostView||Analogue",
            "LauncherAppWidgetHostView|com.google.android.apps.nexuslauncher:id/search_container_hotseat|Google",
            "ImageView||Google app",
            "ImageView||AI Mode",
            "ImageView||Voice search",
            "ImageView||Camera search",
            "LinearLayout||Google Search",
            "FrameLayout|com.google.android.googlequicksearchbox:id/glance_view_id_000|",
            "ViewGroup|com.google.android.apps.nexuslauncher:id/base_template_card_with_date|",
            "FrameLayout||",
            "View|com.google.android.apps.nexuslauncher:id/accessibility_action_view|Home"
        ]
        XCTAssertEqual(legacyHomeTokens.count, 26)

        let settingsTokens: Set<String> = [
            "TextView|android:id/title|Display and touch",
            "TextView|com.android.settings:id/search_bar_title|Search Settings",
            "ScrollView|com.android.settings:id/settings_homepage_container|"
        ]

        let legacySnapshot = SpatialGraphSnapshot(
            rootStateHash: legacyHomeHash,
            currentStateHash: legacySettingsHash,
            vertices: [
                ScreenStateVertex(
                    layoutHash: legacyHomeHash,
                    activePackage: "com.google.android.apps.nexuslauncher",
                    sampleInteractiveLabels: ["At a Glance", "Sun, 15 Nov", "Settings"],
                    semanticTokens: legacyHomeTokens,
                    firstSeenAt: now.addingTimeInterval(-600),
                    lastSeenAt: now.addingTimeInterval(-300),
                    visitCount: 8,
                    discoveryParentHash: nil,
                    discoveryDepth: 0
                ),
                ScreenStateVertex(
                    layoutHash: legacySettingsHash,
                    activePackage: "com.android.settings",
                    sampleInteractiveLabels: ["Display and touch", "Search Settings"],
                    semanticTokens: settingsTokens,
                    firstSeenAt: now.addingTimeInterval(-500),
                    lastSeenAt: now.addingTimeInterval(-100),
                    visitCount: 4,
                    discoveryParentHash: legacyHomeHash,
                    discoveryDepth: 1
                )
            ],
            edges: [
                ScreenTransitionEdge(
                    fromHash: legacyHomeHash,
                    toHash: legacySettingsHash,
                    action: AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 158, y: 1146, selectorText: "Settings"),
                    actionSignature: "tap:Settings",
                    traversalCount: 3,
                    averageTransitionMs: 300,
                    isSpanningTreeEdge: true,
                    lastTraversedAt: now.addingTimeInterval(-100)
                )
            ],
            spanningChildren: [legacyHomeHash: [legacySettingsHash]]
        )

        let bridge = ShadowGraphBridge()
        await bridge.graphEngine.importSnapshot(legacySnapshot)

        // Feed live Home screen at a completely different time/day/month ("Mon, 16 Feb, 8:03 am")
        let liveHomeNodes: [ShadowUINode] = [
            makeNode(nodeId: 1, index: 0, packageName: "com.google.android.deskclock", className: "TextView", resourceId: "com.google.android.deskclock:id/a11y_clock", text: "Monday, 16 Feb, 8:03\u{202F}am", clickable: false),
            makeNode(nodeId: 2, index: 1, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", resourceId: "com.google.android.apps.nexuslauncher:id/date", text: "Mon, 16 Feb", clickable: true),
            makeNode(nodeId: 3, index: 2, packageName: "com.google.android.deskclock", className: "FrameLayout", resourceId: "com.google.android.deskclock:id/widget_frame", clickable: true),
            makeNode(nodeId: 4, index: 3, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Settings", centerX: 158, centerY: 1146, clickable: true),
            makeNode(nodeId: 5, index: 4, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Phone", clickable: true),
            makeNode(nodeId: 6, index: 5, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Messages", clickable: true),
            makeNode(nodeId: 7, index: 6, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Chrome", clickable: true),
            makeNode(nodeId: 8, index: 7, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Camera", clickable: true),
            makeNode(nodeId: 9, index: 8, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Photos", clickable: true),
            makeNode(nodeId: 10, index: 9, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Gmail", clickable: true),
            makeNode(nodeId: 11, index: 10, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "YouTube", clickable: true),
            makeNode(nodeId: 12, index: 11, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Play Store", clickable: true),
            makeNode(nodeId: 13, index: 12, packageName: "com.google.android.apps.nexuslauncher", className: "TextView", text: "Telegram", clickable: true),
            makeNode(nodeId: 14, index: 13, packageName: "com.google.android.apps.nexuslauncher", className: "ViewPager", resourceId: "com.google.android.apps.nexuslauncher:id/smartspace_card_pager", contentDesc: "At a Glance", clickable: false),
            makeNode(nodeId: 15, index: 14, packageName: "com.google.android.apps.nexuslauncher", className: "ScrollView", resourceId: "com.google.android.apps.nexuslauncher:id/workspace", clickable: false),
            makeNode(nodeId: 16, index: 15, packageName: "com.google.android.apps.nexuslauncher", className: "LauncherAppWidgetHostView", contentDesc: "Analogue", clickable: false),
            makeNode(nodeId: 17, index: 16, packageName: "com.google.android.apps.nexuslauncher", className: "LauncherAppWidgetHostView", resourceId: "com.google.android.apps.nexuslauncher:id/search_container_hotseat", contentDesc: "Google", clickable: false),
            makeNode(nodeId: 18, index: 17, packageName: "com.google.android.googlequicksearchbox", className: "ImageView", contentDesc: "Google app", clickable: false),
            makeNode(nodeId: 19, index: 18, packageName: "com.google.android.googlequicksearchbox", className: "ImageView", contentDesc: "AI Mode", clickable: false),
            makeNode(nodeId: 20, index: 19, packageName: "com.google.android.googlequicksearchbox", className: "ImageView", contentDesc: "Voice search", clickable: false),
            makeNode(nodeId: 21, index: 20, packageName: "com.google.android.googlequicksearchbox", className: "ImageView", contentDesc: "Camera search", clickable: false),
            makeNode(nodeId: 22, index: 21, packageName: "com.google.android.googlequicksearchbox", className: "LinearLayout", contentDesc: "Google Search", clickable: false),
            makeNode(nodeId: 23, index: 22, packageName: "com.google.android.googlequicksearchbox", className: "FrameLayout", resourceId: "com.google.android.googlequicksearchbox:id/glance_view_id_000", clickable: true),
            makeNode(nodeId: 24, index: 23, packageName: "com.google.android.apps.nexuslauncher", className: "ViewGroup", resourceId: "com.google.android.apps.nexuslauncher:id/base_template_card_with_date", clickable: true),
            makeNode(nodeId: 25, index: 24, packageName: "com.google.android.googlequicksearchbox", className: "FrameLayout", clickable: true),
            makeNode(nodeId: 26, index: 25, packageName: "com.google.android.apps.nexuslauncher", className: "View", resourceId: "com.google.android.apps.nexuslauncher:id/accessibility_action_view", contentDesc: "Home", clickable: false)
        ]

        await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 1,
            timestampMs: 1000,
            reason: "initial",
            activePackage: "com.google.android.apps.nexuslauncher",
            activeWindowId: 752,
            nodeCount: liveHomeNodes.count,
            nodes: liveHomeNodes
        )))

        // Also feed the update into graphEngine directly and verify zero new vertices were created
        let liveIndex = await bridge.domState.currentIndex!
        _ = await bridge.graphEngine.process(update: ShadowDOMUpdate(
            index: liveIndex,
            isFullSnapshot: true,
            insertedCount: liveHomeNodes.count,
            updatedCount: 0,
            removedCount: 0
        ))

        let vCount = await bridge.graphEngine.vertexCount
        let currentHash = await bridge.graphEngine.currentStateHash
        XCTAssertEqual(vCount, 2, "Must snap to legacy V00 Home vertex rather than spawning a duplicate Home vertex")
        XCTAssertEqual(currentHash, legacyHomeHash)

        // Verify ShadowGraphBridge.routeAndExecute routes directly from snapped legacyHomeHash even with settleSimilarityThreshold == 1.0
        final class MockSettingsExecutor: MacroActionExecutor, @unchecked Sendable {
            let bridge: ShadowGraphBridge
            let settingsNodes: [ShadowUINode]
            init(bridge: ShadowGraphBridge, settingsNodes: [ShadowUINode]) {
                self.bridge = bridge
                self.settingsNodes = settingsNodes
            }
            func execute(action: AttributedUIAction, serial: String) async throws {
                await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                    seq: 2,
                    timestampMs: 2000,
                    reason: "settled",
                    activePackage: "com.android.settings",
                    activeWindowId: 753,
                    nodeCount: settingsNodes.count,
                    nodes: settingsNodes
                )))
            }
        }

        let liveSettingsNodes = [
            makeNode(nodeId: 30, index: 0, packageName: "com.android.settings", className: "TextView", resourceId: "android:id/title", text: "Display and touch", clickable: true),
            makeNode(nodeId: 31, index: 1, packageName: "com.android.settings", className: "TextView", resourceId: "com.android.settings:id/search_bar_title", text: "Search Settings", clickable: false),
            makeNode(nodeId: 32, index: 2, packageName: "com.android.settings", className: "ScrollView", resourceId: "com.android.settings:id/settings_homepage_container", scrollable: true)
        ]

        let outcome = try await bridge.routeAndExecute(
            targetHash: legacySettingsHash,
            serial: "61061JEA307110",
            executor: MockSettingsExecutor(bridge: bridge, settingsNodes: liveSettingsNodes),
            stepTimeoutMs: 1000,
            postSettleQuiescenceMs: 0,
            settleSimilarityThreshold: 1.0
        )

        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived from snapped legacy Home vertex, got \(outcome)")
        }
        XCTAssertEqual(report.steps.count, 1)
        XCTAssertEqual(report.steps[0].targetHash, legacySettingsHash)
        XCTAssertEqual(report.steps[0].actionSignature, "tap:Settings")
        let finalVertexCount = await bridge.graphEngine.vertexCount
        XCTAssertEqual(finalVertexCount, 2)
    }

    func testImportSnapshotCompactsDuplicateVerticesAndStitchesDisconnectedChains() async throws {
        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

        let homeHash: UInt64 = 0x1001
        let settingsAHash: UInt64 = 0x2001
        let settingsBHash: UInt64 = 0x2002
        let displayAHash: UInt64 = 0x3001
        let displayBHash: UInt64 = 0x3002
        let displayScrolledHash: UInt64 = 0x4001
        let nightLightHash: UInt64 = 0x5001
        let lowSimSettingsHash: UInt64 = 0x6001
        let otherPkgDisplayHash: UInt64 = 0x7001

        func alphaSuffix(_ idx: Int) -> String {
            let first = UnicodeScalar(65 + (idx / 26))!
            let second = UnicodeScalar(65 + (idx % 26))!
            return "\(Character(first))\(Character(second))"
        }

        let homeTokens: Set<String> = Set((0..<12).map { "TextView|home_\(alphaSuffix($0))|Home \(alphaSuffix($0))" })
        let settingsBaseTokens = (0..<25).map { "TextView|android:id/title|Setting \(alphaSuffix($0))" }
        let settingsATokens = Set(settingsBaseTokens)
        let settingsBTokens = Set(settingsBaseTokens + ["TextView|com.android.settings:id/badge|New"]) // 25/26 = 0.9615 >= 0.90

        let displayBaseTokens = (0..<27).map { "TextView|android:id/title|Display Option \(alphaSuffix($0))" }
        let displayATokens = Set(displayBaseTokens + ["TextView|com.android.settings:id/summary|Extra"]) // 28 tokens
        let displayBTokens = Set(displayBaseTokens) // 27/28 = 0.9643 >= 0.90

        let displayScrolledTokens: Set<String> = Set((10..<32).map { "TextView|android:id/title|Display Scrolled \(alphaSuffix($0))" })
        let nightLightTokens: Set<String> = ["TextView|android:id/title|Night Light", "Switch|android:id/switch_widget|Off"]
        // 10/29 = 0.345 < 0.90
        let lowSimSettingsTokens = Set(displayBaseTokens.prefix(10) + ["TextView|com.android.settings:id/other|Unique"])

        let vertices: [ScreenStateVertex] = [
            ScreenStateVertex(
                layoutHash: homeHash,
                activePackage: "com.google.android.apps.nexuslauncher",
                sampleInteractiveLabels: ["Settings"],
                semanticTokens: homeTokens,
                firstSeenAt: baseTime,
                lastSeenAt: baseTime.addingTimeInterval(100),
                visitCount: 10,
                discoveryParentHash: nil,
                discoveryDepth: 0
            ),
            ScreenStateVertex(
                layoutHash: settingsAHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Display and touch"],
                semanticTokens: settingsATokens,
                firstSeenAt: baseTime.addingTimeInterval(10),
                lastSeenAt: baseTime.addingTimeInterval(110),
                visitCount: 14,
                discoveryParentHash: homeHash,
                discoveryDepth: 1
            ),
            ScreenStateVertex(
                layoutHash: settingsBHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Display and touch"],
                semanticTokens: settingsBTokens,
                firstSeenAt: baseTime.addingTimeInterval(20),
                lastSeenAt: baseTime.addingTimeInterval(120),
                visitCount: 11,
                discoveryParentHash: homeHash,
                discoveryDepth: 1
            ),
            ScreenStateVertex(
                layoutHash: displayAHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Display and touch", "Brightness"],
                semanticTokens: displayATokens,
                firstSeenAt: baseTime.addingTimeInterval(30),
                lastSeenAt: baseTime.addingTimeInterval(130),
                visitCount: 7,
                discoveryParentHash: settingsAHash,
                discoveryDepth: 2
            ),
            ScreenStateVertex(
                layoutHash: displayBHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Display and touch", "Brightness"],
                semanticTokens: displayBTokens,
                firstSeenAt: baseTime.addingTimeInterval(40),
                lastSeenAt: baseTime.addingTimeInterval(140),
                visitCount: 6,
                discoveryParentHash: displayAHash,
                discoveryDepth: 3
            ),
            ScreenStateVertex(
                layoutHash: displayScrolledHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Enhanced HDR brightness"],
                semanticTokens: displayScrolledTokens,
                firstSeenAt: baseTime.addingTimeInterval(50),
                lastSeenAt: baseTime.addingTimeInterval(150),
                visitCount: 1,
                discoveryParentHash: displayBHash,
                discoveryDepth: 4
            ),
            ScreenStateVertex(
                layoutHash: nightLightHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Night Light"],
                semanticTokens: nightLightTokens,
                firstSeenAt: baseTime.addingTimeInterval(60),
                lastSeenAt: baseTime.addingTimeInterval(160),
                visitCount: 1,
                discoveryParentHash: displayScrolledHash,
                discoveryDepth: 5
            ),
            ScreenStateVertex(
                layoutHash: lowSimSettingsHash,
                activePackage: "com.android.settings",
                sampleInteractiveLabels: ["Unique"],
                semanticTokens: lowSimSettingsTokens,
                firstSeenAt: baseTime.addingTimeInterval(70),
                lastSeenAt: baseTime.addingTimeInterval(170),
                visitCount: 1,
                discoveryParentHash: settingsAHash,
                discoveryDepth: 2
            ),
            // Identical tokens to displayA, but in a DIFFERENT package -> must NOT merge
            ScreenStateVertex(
                layoutHash: otherPkgDisplayHash,
                activePackage: "com.example.other",
                sampleInteractiveLabels: ["Display and touch"],
                semanticTokens: displayATokens,
                firstSeenAt: baseTime.addingTimeInterval(80),
                lastSeenAt: baseTime.addingTimeInterval(180),
                visitCount: 1,
                discoveryParentHash: homeHash,
                discoveryDepth: 1
            )
        ]

        let tapSettings = AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 150, y: 900, selectorText: "Settings")
        let tapDisplay = AttributedUIAction(kind: .tap, targetDescription: "Display and touch", x: 300, y: 700, selectorText: "Display and touch")
        let swipe1 = AttributedUIAction(kind: .swipe, targetDescription: "manual swipe (353,1938)->(350,1292)", x: 353, y: 1938, endX: 350, endY: 1292)
        let swipe2 = AttributedUIAction(kind: .swipe, targetDescription: "manual swipe (326,1999)->(357,1345)", x: 326, y: 1999, endX: 357, endY: 1345)

        let edges: [ScreenTransitionEdge] = [
            // Chain 1: Home -> SettingsA -> DisplayA
            ScreenTransitionEdge(fromHash: homeHash, toHash: settingsAHash, action: tapSettings, actionSignature: tapSettings.signature, traversalCount: 2, averageTransitionMs: 200, isSpanningTreeEdge: true, lastTraversedAt: baseTime),
            ScreenTransitionEdge(fromHash: settingsAHash, toHash: displayAHash, action: tapDisplay, actionSignature: tapDisplay.signature, traversalCount: 1, averageTransitionMs: 100, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(1)),
            // Parallel edge from duplicate SettingsB -> DisplayA (collides with SettingsA -> DisplayA after merge)
            ScreenTransitionEdge(fromHash: settingsBHash, toHash: displayAHash, action: tapDisplay, actionSignature: tapDisplay.signature, traversalCount: 2, averageTransitionMs: 250, isSpanningTreeEdge: false, lastTraversedAt: baseTime.addingTimeInterval(2)),
            // Unattributed (action == nil) transition between DisplayA and DisplayB -> MUST be dropped
            ScreenTransitionEdge(fromHash: displayAHash, toHash: displayBHash, action: nil, actionSignature: "implicit", traversalCount: 4, averageTransitionMs: 50, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(3)),
            // Action edge between merged DisplayB -> DisplayA -> MUST be dropped as merge-induced self-loop
            ScreenTransitionEdge(fromHash: displayBHash, toHash: displayAHash, action: tapDisplay, actionSignature: tapDisplay.signature, traversalCount: 1, averageTransitionMs: 50, isSpanningTreeEdge: false, lastTraversedAt: baseTime.addingTimeInterval(4)),
            // Original self-loop on Home -> MUST be dropped
            ScreenTransitionEdge(fromHash: homeHash, toHash: homeHash, action: AttributedUIAction(kind: .tap, targetDescription: "Refresh"), actionSignature: "tap:Refresh", traversalCount: 1, averageTransitionMs: 20, isSpanningTreeEdge: false, lastTraversedAt: baseTime.addingTimeInterval(5)),
            // Disconnected Chain 2: DisplayB -> DisplayScrolled -> NightLight
            ScreenTransitionEdge(fromHash: displayBHash, toHash: displayScrolledHash, action: swipe1, actionSignature: swipe1.signature, traversalCount: 1, averageTransitionMs: 300, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(6)),
            ScreenTransitionEdge(fromHash: displayScrolledHash, toHash: nightLightHash, action: swipe2, actionSignature: swipe2.signature, traversalCount: 1, averageTransitionMs: 320, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(7)),
            // Unmerged vertices edges
            ScreenTransitionEdge(fromHash: settingsAHash, toHash: lowSimSettingsHash, action: AttributedUIAction(kind: .tap, targetDescription: "Unique"), actionSignature: "tap:Unique", traversalCount: 1, averageTransitionMs: 120, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(8)),
            ScreenTransitionEdge(fromHash: homeHash, toHash: otherPkgDisplayHash, action: AttributedUIAction(kind: .tap, targetDescription: "OtherApp"), actionSignature: "tap:OtherApp", traversalCount: 1, averageTransitionMs: 150, isSpanningTreeEdge: true, lastTraversedAt: baseTime.addingTimeInterval(9))
        ]

        let uncompactedSnapshot = SpatialGraphSnapshot(
            rootStateHash: homeHash,
            currentStateHash: displayBHash,
            vertices: vertices,
            edges: edges,
            spanningChildren: [
                homeHash: [settingsAHash, settingsBHash, otherPkgDisplayHash],
                settingsAHash: [displayAHash, lowSimSettingsHash],
                displayAHash: [displayBHash],
                displayBHash: [displayScrolledHash],
                displayScrolledHash: [nightLightHash]
            ]
        )

        // Confirm raw uncompacted snapshot has NO executable route from Home to NightLight
        let pathfinder = AStarPathfinder()
        XCTAssertNil(pathfinder.findShortestPath(from: homeHash, to: nightLightHash, in: uncompactedSnapshot))

        // Import into SpatialGraphEngine -> triggers compaction
        let engine = SpatialGraphEngine()
        await engine.importSnapshot(uncompactedSnapshot)

        let compactedCount = await engine.vertexCount
        let compactedEdgeCount = await engine.edgeCount
        let remappedCurrent = await engine.currentStateHash
        let isAcyclic = await engine.isSpanningDAGAcyclic()
        let compactedSnapshot = await engine.snapshot()

        // 9 -> 7 vertices (settingsB -> settingsA, displayB -> displayA; otherPkgDisplay & lowSimSettings stay separate)
        XCTAssertEqual(compactedCount, 7)
        // 10 edges -> 6 valid unique edges (dropped: implicit displayA->displayB, self-loop displayB->displayA, self-loop home->home; aggregated settings->display)
        XCTAssertEqual(compactedEdgeCount, 6)
        XCTAssertEqual(remappedCurrent, displayAHash, "currentStateHash pointing to merged vertex must remap to canonical vertex")
        XCTAssertTrue(isAcyclic, "Spanning DAG must remain strictly acyclic after compaction")

        // Verify visitCount aggregation on canonical vertices
        let canonicalSettings = await engine.vertices[settingsAHash]
        let canonicalDisplay = await engine.vertices[displayAHash]
        XCTAssertEqual(canonicalSettings?.visitCount, 25) // 14 + 11
        XCTAssertEqual(canonicalDisplay?.visitCount, 13)  // 7 + 6

        // Verify zero self-loops and zero action == nil edges remain
        XCTAssertTrue(compactedSnapshot.edges.allSatisfy { $0.fromHash != $0.toHash })
        XCTAssertTrue(compactedSnapshot.edges.allSatisfy { $0.action != nil })

        // Verify collided settingsA -> displayA edge aggregated traversalCount & weighted latency
        let settingsToDisplay = compactedSnapshot.edges.first { $0.fromHash == settingsAHash && $0.toHash == displayAHash }
        XCTAssertEqual(settingsToDisplay?.traversalCount, 3)
        XCTAssertEqual(settingsToDisplay?.averageTransitionMs ?? 0, 200.0, accuracy: 0.001)

        // Verify A* now routes seamlessly from Home through Settings -> Display -> DisplayScrolled -> NightLight!
        let route = pathfinder.findShortestPath(from: homeHash, to: nightLightHash, in: compactedSnapshot)
        XCTAssertNotNil(route, "Compaction must stitch disconnected chains through Jaccard >= 0.90 vertices")
        XCTAssertEqual(route?.edges.map(\.toHash), [settingsAHash, displayAHash, displayScrolledHash, nightLightHash])
        XCTAssertEqual(route?.edges.map(\.actionSignature), [
            tapSettings.signature,
            tapDisplay.signature,
            swipe1.signature,
            swipe2.signature
        ])

        // Verify spanning tree path & findSpanningDAGPath also work consistently
        let spanningPath = await engine.spanningPathFromRoot(to: nightLightHash)
        XCTAssertEqual(spanningPath, [homeHash, settingsAHash, displayAHash, displayScrolledHash, nightLightHash])
        let spanningRoute = pathfinder.findSpanningDAGPath(from: homeHash, to: nightLightHash, in: compactedSnapshot)
        XCTAssertEqual(spanningRoute?.edges.map(\.toHash), [settingsAHash, displayAHash, displayScrolledHash, nightLightHash])

        // Verify idempotency on re-import
        let secondEngine = SpatialGraphEngine()
        await secondEngine.importSnapshot(compactedSnapshot)
        let secondVCount = await secondEngine.vertexCount
        let secondECount = await secondEngine.edgeCount
        let secondAcyclic = await secondEngine.isSpanningDAGAcyclic()
        XCTAssertEqual(secondVCount, compactedCount)
        XCTAssertEqual(secondECount, compactedEdgeCount)
        XCTAssertTrue(secondAcyclic)
    }

    func testImportSnapshotCompactionExactThresholdBoundaryEmptyTokensAndCycleSafety() async {
        let now = Date()
        let startHash: UInt64 = 10
        let v1Hash: UInt64 = 20
        let v2Hash: UInt64 = 21
        let belowThresholdHash: UInt64 = 22
        let goalHash: UInt64 = 30
        let empty1Hash: UInt64 = 40
        let empty2Hash: UInt64 = 41

        // v1 has 9 tokens, v2 has 10 tokens sharing all 9 -> Jaccard = 9/10 = 0.90 (exact boundary -> MUST merge)
        // belowThreshold shares 8 tokens + 2 unique = 8/11 = 0.727 < 0.90
        let nineTokens = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"]
            .map { "TextView||Item \($0)" }
        let v1Tokens = Set(nineTokens) // 9 tokens
        let v2Tokens = Set(nineTokens + ["TextView||ExtraV2"]) // 9/10 = 0.90 vs v1
        let belowTokens = Set(nineTokens.prefix(8) + ["TextView||OtherA", "TextView||OtherB"]) // 8/11 = 0.727 vs v1, 8/12 = 0.667 vs v2

        // Intentionally give v2 higher visitCount than v1, and arrange spanning parent cycle risk:
        // start -> v1 -> goal, and v2 -> v1 in original spanning parents, while start->v1 and v2->goal are executable chains!
        let vertices = [
            ScreenStateVertex(layoutHash: startHash, activePackage: "com.test", sampleInteractiveLabels: ["Start"], semanticTokens: ["Button||StartA", "Button||StartB", "Button||StartC", "Button||StartD"], firstSeenAt: now, lastSeenAt: now, visitCount: 3, discoveryParentHash: nil, discoveryDepth: 0),
            ScreenStateVertex(layoutHash: v1Hash, activePackage: "com.test", sampleInteractiveLabels: ["Mid"], semanticTokens: v1Tokens, firstSeenAt: now.addingTimeInterval(1), lastSeenAt: now, visitCount: 2, discoveryParentHash: startHash, discoveryDepth: 1),
            ScreenStateVertex(layoutHash: v2Hash, activePackage: "com.test", sampleInteractiveLabels: ["Mid"], semanticTokens: v2Tokens, firstSeenAt: now.addingTimeInterval(2), lastSeenAt: now, visitCount: 5, discoveryParentHash: goalHash, discoveryDepth: 3),
            ScreenStateVertex(layoutHash: belowThresholdHash, activePackage: "com.test", sampleInteractiveLabels: ["Below"], semanticTokens: belowTokens, firstSeenAt: now.addingTimeInterval(3), lastSeenAt: now, visitCount: 1, discoveryParentHash: startHash, discoveryDepth: 1),
            ScreenStateVertex(layoutHash: goalHash, activePackage: "com.test", sampleInteractiveLabels: ["Goal"], semanticTokens: ["Button||GoalA", "Button||GoalB", "Button||GoalC", "Button||GoalD"], firstSeenAt: now.addingTimeInterval(4), lastSeenAt: now, visitCount: 1, discoveryParentHash: v1Hash, discoveryDepth: 2),
            // Empty-token legacy vertices must NEVER merge
            ScreenStateVertex(layoutHash: empty1Hash, activePackage: "com.test", sampleInteractiveLabels: ["Legacy1"], semanticTokens: [], firstSeenAt: now.addingTimeInterval(5), lastSeenAt: now, visitCount: 1, discoveryParentHash: nil, discoveryDepth: 0),
            ScreenStateVertex(layoutHash: empty2Hash, activePackage: "com.test", sampleInteractiveLabels: ["Legacy2"], semanticTokens: [], firstSeenAt: now.addingTimeInterval(6), lastSeenAt: now, visitCount: 1, discoveryParentHash: nil, discoveryDepth: 0)
        ]

        let step1 = AttributedUIAction(kind: .tap, targetDescription: "ToMid")
        let step2 = AttributedUIAction(kind: .tap, targetDescription: "ToGoal")
        let edges = [
            ScreenTransitionEdge(fromHash: startHash, toHash: v1Hash, action: step1, actionSignature: step1.signature, isSpanningTreeEdge: true),
            ScreenTransitionEdge(fromHash: v2Hash, toHash: goalHash, action: step2, actionSignature: step2.signature, isSpanningTreeEdge: true),
            // Unattributed action == nil edge between v1 and belowThreshold (touched by merge of v1->v2)
            ScreenTransitionEdge(fromHash: v1Hash, toHash: belowThresholdHash, action: nil, actionSignature: "implicit")
        ]

        let snap = SpatialGraphSnapshot(
            rootStateHash: startHash,
            currentStateHash: v1Hash,
            vertices: vertices,
            edges: edges,
            spanningChildren: [startHash: [v1Hash, belowThresholdHash], v1Hash: [goalHash], goalHash: [v2Hash]]
        )

        let engine = SpatialGraphEngine()
        await engine.importSnapshot(snap)

        // v1 (visits=2) merged into v2 (visits=5) -> 6 vertices total (start, v2, belowThreshold, goal, empty1, empty2)
        let vCount = await engine.vertexCount
        XCTAssertEqual(vCount, 6)
        let curHash = await engine.currentStateHash
        XCTAssertEqual(curHash, v2Hash)
        let acyclic = await engine.isSpanningDAGAcyclic()
        XCTAssertTrue(acyclic, "Cycle risk from merged discoveryParentHash must be resolved cleanly")

        let compacted = await engine.snapshot()
        let route = AStarPathfinder().findShortestPath(from: startHash, to: goalHash, in: compacted)
        XCTAssertEqual(route?.edges.map(\.toHash), [v2Hash, goalHash])
        XCTAssertEqual(compacted.edges.count, 2, "action == nil transition touching merged vertex must be dropped")
    }

    func testImportSnapshotRebuildSpanningDAGPrefersLongerExecutablePathOverShorterImplicitEdge() async {
        let now = Date()
        let rootHash: UInt64 = 100
        let shortcutHubHash: UInt64 = 101
        let settingsHash: UInt64 = 102
        let displayHash: UInt64 = 103
        let screenTimeoutHash: UInt64 = 104
        let implicitLeafHash: UInt64 = 105
        let postImplicitExecHash: UInt64 = 106

        func makeTokens(_ prefix: String) -> Set<String> {
            Set((0..<10).map { "TextView||\(prefix)_\($0)" })
        }

        // Topology:
        // - Shorter 2-hop path with an unattributed (action == nil) edge:
        //   root -> shortcutHub (tap) -> screenTimeout (action == nil)
        // - Longer 3-hop all-executable path:
        //   root -> settings (tap) -> display (tap) -> screenTimeout (tap)
        // - Plus an unreachable-by-action subtree reached via action == nil:
        //   root -> implicitLeaf (action == nil) -> postImplicitExec (tap)
        // Also corrupt spanningChildren/isSpanningTreeEdge so rebuildSpanningDAG runs.
        let vertices = [
            ScreenStateVertex(layoutHash: rootHash, activePackage: "com.launcher", sampleInteractiveLabels: ["Home"], semanticTokens: makeTokens("Home"), firstSeenAt: now, lastSeenAt: now, visitCount: 5, discoveryParentHash: nil, discoveryDepth: 0),
            ScreenStateVertex(layoutHash: shortcutHubHash, activePackage: "com.settings", sampleInteractiveLabels: ["Hub"], semanticTokens: makeTokens("Hub"), firstSeenAt: now.addingTimeInterval(1), lastSeenAt: now, visitCount: 1, discoveryParentHash: rootHash, discoveryDepth: 1),
            ScreenStateVertex(layoutHash: settingsHash, activePackage: "com.settings", sampleInteractiveLabels: ["Settings"], semanticTokens: makeTokens("Settings"), firstSeenAt: now.addingTimeInterval(2), lastSeenAt: now, visitCount: 4, discoveryParentHash: rootHash, discoveryDepth: 1),
            ScreenStateVertex(layoutHash: displayHash, activePackage: "com.settings", sampleInteractiveLabels: ["Display"], semanticTokens: makeTokens("Display"), firstSeenAt: now.addingTimeInterval(3), lastSeenAt: now, visitCount: 3, discoveryParentHash: settingsHash, discoveryDepth: 2),
            ScreenStateVertex(layoutHash: screenTimeoutHash, activePackage: "com.settings", sampleInteractiveLabels: ["Screen timeout"], semanticTokens: makeTokens("Timeout"), firstSeenAt: now.addingTimeInterval(4), lastSeenAt: now, visitCount: 2, discoveryParentHash: shortcutHubHash, discoveryDepth: 2),
            ScreenStateVertex(layoutHash: implicitLeafHash, activePackage: "com.settings", sampleInteractiveLabels: ["ImplicitLeaf"], semanticTokens: makeTokens("ImplicitLeaf"), firstSeenAt: now.addingTimeInterval(5), lastSeenAt: now, visitCount: 1, discoveryParentHash: rootHash, discoveryDepth: 1),
            ScreenStateVertex(layoutHash: postImplicitExecHash, activePackage: "com.settings", sampleInteractiveLabels: ["PostImplicit"], semanticTokens: makeTokens("PostImplicit"), firstSeenAt: now.addingTimeInterval(6), lastSeenAt: now, visitCount: 1, discoveryParentHash: implicitLeafHash, discoveryDepth: 2)
        ]

        let tapHub = AttributedUIAction(kind: .tap, targetDescription: "Hub")
        let tapSettings = AttributedUIAction(kind: .tap, targetDescription: "Settings")
        let tapDisplay = AttributedUIAction(kind: .tap, targetDescription: "Display")
        let tapTimeout = AttributedUIAction(kind: .tap, targetDescription: "Screen timeout")
        let tapPostImplicit = AttributedUIAction(kind: .tap, targetDescription: "PostImplicit")

        let edges = [
            ScreenTransitionEdge(fromHash: rootHash, toHash: shortcutHubHash, action: tapHub, actionSignature: tapHub.signature, isSpanningTreeEdge: true),
            ScreenTransitionEdge(fromHash: shortcutHubHash, toHash: screenTimeoutHash, action: nil, actionSignature: "implicit", isSpanningTreeEdge: true),
            ScreenTransitionEdge(fromHash: rootHash, toHash: settingsHash, action: tapSettings, actionSignature: tapSettings.signature, isSpanningTreeEdge: true),
            ScreenTransitionEdge(fromHash: settingsHash, toHash: displayHash, action: tapDisplay, actionSignature: tapDisplay.signature, isSpanningTreeEdge: true),
            ScreenTransitionEdge(fromHash: displayHash, toHash: screenTimeoutHash, action: tapTimeout, actionSignature: tapTimeout.signature, isSpanningTreeEdge: false),
            ScreenTransitionEdge(fromHash: rootHash, toHash: implicitLeafHash, action: nil, actionSignature: "implicit", isSpanningTreeEdge: false),
            ScreenTransitionEdge(fromHash: implicitLeafHash, toHash: postImplicitExecHash, action: tapPostImplicit, actionSignature: tapPostImplicit.signature, isSpanningTreeEdge: false)
        ]

        let snap = SpatialGraphSnapshot(
            rootStateHash: rootHash,
            currentStateHash: rootHash,
            vertices: vertices,
            edges: edges,
            spanningChildren: [
                rootHash: [shortcutHubHash, settingsHash],
                shortcutHubHash: [screenTimeoutHash],
                settingsHash: [displayHash]
            ]
        )

        let engine = SpatialGraphEngine()
        await engine.importSnapshot(snap)

        let acyclic = await engine.isSpanningDAGAcyclic()
        XCTAssertTrue(acyclic)

        let rebuilt = await engine.snapshot()
        let pathfinder = AStarPathfinder()
        let spanningPathToTimeout = pathfinder.findSpanningDAGPath(from: rootHash, to: screenTimeoutHash, in: rebuilt)
        XCTAssertEqual(
            spanningPathToTimeout?.edges.map(\.toHash),
            [settingsHash, displayHash, screenTimeoutHash],
            "Spanning DAG rebuild must exhaust executable paths before taking shorter action == nil shortcuts"
        )
        let rootSpanningPath = await engine.spanningPathFromRoot(to: screenTimeoutHash)
        XCTAssertEqual(rootSpanningPath, [rootHash, settingsHash, displayHash, screenTimeoutHash])

        // Verify post-implicit subtree is still connected in the spanning DAG
        let implicitSubtreePath = await engine.spanningPathFromRoot(to: postImplicitExecHash)
        XCTAssertEqual(implicitSubtreePath, [rootHash, implicitLeafHash, postImplicitExecHash])
    }

    // MARK: - 7. Live Pixel 10a End-to-End Verification (opt-in via SHADOWGRAPH_LIVE_TEST=1)

    func testLivePixel10aDaemonEndToEndStreamingAndSubMillisecondReads() async throws {
        guard ProcessInfo.processInfo.environment["SHADOWGRAPH_LIVE_TEST"] == "1" else {
            return
        }

        let bridge = ShadowGraphBridge()
        await bridge.start()
        defer {
            Task { await bridge.stop() }
        }

        let snap = await bridge.domState.waitForSnapshot(timeoutSeconds: 5.0)
        XCTAssertNotNil(snap, "Expected live snapshot from android-daemon on 127.0.0.1:27189")
        let hello = await bridge.domState.lastHello
        XCTAssertNotNil(hello)
        XCTAssertEqual(hello?.format, "ndjson/1")

        let tree = await bridge.getCurrentTree()
        XCTAssertFalse(tree.isEmpty, "Expected live Android UI tree to contain nodes")

        // Measure 50 consecutive fastCompactTreeIfFresh() reads
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<50 {
            let nodes = await bridge.fastCompactTreeIfFresh(maxWaitSeconds: 0.1, maxAgeSeconds: 15.0)
            XCTAssertNotNil(nodes)
            XCTAssertFalse(nodes?.isEmpty ?? true)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        let avgMs = elapsedMs / 50.0
        print("[LiveTest] device=\(hello?.deviceModel ?? "?") sdk=\(hello?.sdkInt ?? 0) nodes=\(tree.count) pkg=\(snap?.activePackage ?? "?") avgReadMs=\(String(format: "%.3f", avgMs))")
        XCTAssertLessThan(avgMs, 5.0, "Shadow DOM reads should average < 5 ms")

        // Verify bidirectional ping + snapshot command against real daemon
        try await bridge.client.ping()
        try await bridge.client.requestSnapshot()
        try await Task.sleep(nanoseconds: 250_000_000)

        let graphSnap = await bridge.graphEngine.snapshot()
        XCTAssertGreaterThanOrEqual(graphSnap.vertices.count, 1)
        let isAcyclic = await bridge.graphEngine.isSpanningDAGAcyclic()
        XCTAssertTrue(isAcyclic)

        await bridge.stop()
    }

    func testLivePixel10aHomeClockStabilityAgainstPersistedGraph() async throws {
        guard ProcessInfo.processInfo.environment["SHADOWGRAPH_LIVE_TEST"] == "1" else {
            return
        }

        let bridge = ShadowGraphBridge()
        await bridge.start()
        defer {
            Task { await bridge.stop() }
        }

        guard let snap = await bridge.domState.waitForSnapshot(timeoutSeconds: 5.0),
              let liveIndex = await bridge.domState.currentIndex else {
            return XCTFail("Expected live snapshot from android-daemon on 127.0.0.1:27189")
        }

        let hasher = ScreenLayoutHasher()
        let fp1 = hasher.fingerprint(for: liveIndex)

        // Mutate every live clock/date node in the real Pixel 10a tree across time, weekday, month, and AM/PM
        let rolledNodes = liveIndex.orderedNodes.map { node -> ShadowUINode in
            var text = node.text
            var desc = node.contentDesc
            if node.resourceId.hasSuffix(":id/clock") || node.resourceId.hasSuffix(":id/a11y_clock") {
                if !text.isEmpty { text = "Wednesday, 14 May, 7:05\u{202F}am" }
                if !desc.isEmpty { desc = "Wednesday, 14 May, 7:05\u{202F}am" }
            } else if node.resourceId.hasSuffix(":id/date") {
                if !text.isEmpty { text = "Wed, 14 May" }
                if !desc.isEmpty { desc = "Wed, 14 May" }
            }
            return ShadowUINode(
                index: node.index,
                text: text,
                resourceId: node.resourceId,
                contentDesc: desc,
                className: node.className,
                clickable: node.clickable,
                scrollable: node.scrollable,
                bounds: node.bounds,
                centerX: node.centerX,
                centerY: node.centerY,
                nodeId: node.nodeId,
                parentId: node.parentId,
                windowId: node.windowId,
                childIndex: node.childIndex,
                depth: node.depth,
                packageName: node.packageName,
                editable: node.editable,
                focused: node.focused,
                checked: node.checked,
                enabled: node.enabled,
                visible: node.visible
            )
        }
        let rolledIndex = ShadowTreeIndex(
            seq: liveIndex.seq + 1,
            timestampMs: liveIndex.timestampMs + 60_000,
            activePackage: liveIndex.activePackage,
            activeWindowId: liveIndex.activeWindowId,
            nodes: rolledNodes
        )
        let fp2 = hasher.fingerprint(for: rolledIndex)
        XCTAssertEqual(fp1.layoutHash, fp2.layoutHash, "Live Pixel 10a screen hash must remain identical across clock/date rollover")

        // Verify against persisted shadow_graph.json (read-only) if present on disk
        let graphURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AndOnMac/shadow_graph.json")
        if FileManager.default.fileExists(atPath: graphURL.path) {
            let data = try Data(contentsOf: graphURL)
            let persistedEngine = SpatialGraphEngine()
            try await persistedEngine.importGraphJSON(data)
            let beforeCount = await persistedEngine.vertexCount
            _ = await persistedEngine.process(update: ShadowDOMUpdate(
                index: liveIndex,
                isFullSnapshot: true,
                insertedCount: liveIndex.orderedNodes.count,
                updatedCount: 0,
                removedCount: 0
            ))
            let afterLiveCount = await persistedEngine.vertexCount
            _ = await persistedEngine.process(update: ShadowDOMUpdate(
                index: rolledIndex,
                isFullSnapshot: false,
                insertedCount: 0,
                updatedCount: 3,
                removedCount: 0
            ))
            let afterRollCount = await persistedEngine.vertexCount
            let snappedHash = await persistedEngine.currentStateHash
            print("[LiveGraphCheck] pkg=\(snap.activePackage) nodes=\(liveIndex.orderedNodes.count) before=\(beforeCount) afterLive=\(afterLiveCount) afterRoll=\(afterRollCount) snappedHash=\(snappedHash ?? 0)")
            if snap.activePackage == "com.google.android.apps.nexuslauncher" {
                XCTAssertEqual(afterLiveCount, beforeCount, "Live Pixel 10a Home screen must snap to persisted Home vertex without creating a duplicate node")
            }
            XCTAssertEqual(afterRollCount, afterLiveCount, "Clock/date rollover on live Pixel 10a tree must create zero new nodes")
        }

        await bridge.stop()
    }
}
