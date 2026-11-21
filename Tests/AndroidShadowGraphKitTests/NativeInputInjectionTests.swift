import Foundation
import Network
import XCTest
@testable import AndroidShadowGraphKit

final class NativeInputInjectionTests: XCTestCase {
    func testCodecEncodesInputCommandsAndDecodesCapabilitiesAndInputResult() throws {
        let codec = NdjsonWireCodec()

        // Legacy hello without capabilities
        let legacyHello = Data(#"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":36,"device_model":"Pixel","pid":42}"#.utf8)
        guard case .hello(let hLegacy) = try codec.decodeFrame(legacyHello) else {
            return XCTFail("Expected .hello")
        }
        XCTAssertFalse(hLegacy.supportsNativeInput)

        // New hello with input capability
        let newHello = Data(#"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":37,"device_model":"Pixel 10a","pid":42,"capabilities":["input"]}"#.utf8)
        guard case .hello(let hNew) = try codec.decodeFrame(newHello) else {
            return XCTFail("Expected .hello")
        }
        XCTAssertTrue(hNew.supportsNativeInput)

        // input_result ok & error
        let okFrame = Data(#"{"type":"input_result","id":9,"cmd":"tap","ok":true,"elapsed_ms":11,"ts_ms":1700000000000}"#.utf8)
        guard case .inputResult(let okRes) = try codec.decodeFrame(okFrame) else {
            return XCTFail("Expected .inputResult")
        }
        XCTAssertEqual(okRes.id, 9)
        XCTAssertEqual(okRes.cmd, "tap")
        XCTAssertTrue(okRes.ok)
        XCTAssertNil(okRes.error)
        XCTAssertEqual(okRes.elapsedMs, 11)

        let errFrame = Data(#"{"type":"input_result","id":10,"cmd":"swipe","ok":false,"error":"uia_null","elapsed_ms":1,"ts_ms":1700000000001}"#.utf8)
        guard case .inputResult(let errRes) = try codec.decodeFrame(errFrame) else {
            return XCTFail("Expected .inputResult")
        }
        XCTAssertFalse(errRes.ok)
        XCTAssertEqual(errRes.error, "uia_null")

        // Encode commands
        let tapBytes = try codec.encodeCommand(.tap(id: 1, x: 540, y: 1200))
        XCTAssertEqual(String(decoding: tapBytes, as: UTF8.self), "{\"cmd\":\"tap\",\"id\":1,\"x\":540,\"y\":1200}\n")

        let swipeBytes = try codec.encodeCommand(.swipe(id: 2, x1: 540, y1: 1900, x2: 540, y2: 450, durationMs: 145, holdMs: 25))
        XCTAssertEqual(
            String(decoding: swipeBytes, as: UTF8.self),
            "{\"cmd\":\"swipe\",\"id\":2,\"x1\":540,\"y1\":1900,\"x2\":540,\"y2\":450,\"duration_ms\":145,\"hold_ms\":25}\n"
        )

        let keyBytes = try codec.encodeCommand(.keyevent(id: 3, keycode: 4))
        XCTAssertEqual(String(decoding: keyBytes, as: UTF8.self), "{\"cmd\":\"keyevent\",\"id\":3,\"keycode\":4}\n")

        // Bounds validation
        XCTAssertThrowsError(try codec.encodeCommand(.tap(id: 1, x: -1, y: 10)))
        XCTAssertThrowsError(try codec.encodeCommand(.swipe(id: 2, x1: 0, y1: 0, x2: 10, y2: 10, durationMs: 5, holdMs: 25)))
        XCTAssertThrowsError(try codec.encodeCommand(.keyevent(id: 3, keycode: 0)))
    }

    func testTCPClientRoutesNativeInputHandlesErrorsLegacyDaemonsAndDisconnects() async throws {
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params, on: .any)
        let queue = DispatchQueue(label: "test.native.input.listener")

        final class MockHarness: @unchecked Sendable {
            let lock = NSLock()
            var receivedLines: [String] = []
            var buffer = Data()
        }
        let harness = MockHarness()

        let readyExp = expectation(description: "listener ready")
        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            let hello = #"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":37,"device_model":"MockPixel","pid":77,"capabilities":["input"]}"# + "\n"
            conn.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })

            func readLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        var linesToProcess: [String] = []
                        harness.lock.withLock {
                            harness.buffer.append(data)
                            while let nl = harness.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                                let lineData = harness.buffer.prefix(upTo: nl)
                                harness.buffer.removeSubrange(...nl)
                                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !line.isEmpty {
                                    harness.receivedLines.append(line)
                                    linesToProcess.append(line)
                                }
                            }
                        }
                        for line in linesToProcess {
                            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                                  let cmd = obj["cmd"] as? String else { continue }
                            let id = (obj["id"] as? NSNumber)?.uint64Value ?? 0
                            if cmd == "keyevent" {
                                conn.cancel()
                                return
                            }
                            let hb = #"{"type":"heartbeat","seq":1,"ts_ms":1000,"uptime_ms":50,"package":"com.android.settings","window_id":1,"clients":1}"# + "\n"
                            let ack: String
                            if cmd == "swipe" {
                                ack = "{\"type\":\"input_result\",\"id\":\(id),\"cmd\":\"swipe\",\"ok\":false,\"error\":\"injected_failure\",\"elapsed_ms\":2,\"ts_ms\":1002}\n"
                            } else {
                                ack = "{\"type\":\"input_result\",\"id\":\(id),\"cmd\":\"\(cmd)\",\"ok\":true,\"elapsed_ms\":6,\"ts_ms\":1001}\n"
                            }
                            conn.send(content: Data((hb + ack).utf8), completion: .contentProcessed { _ in })
                        }
                    }
                    if !isComplete && error == nil {
                        readLoop()
                    }
                }
            }
            readLoop()
        }

        listener.start(queue: queue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = DaemonTCPClient(configuration: DaemonEndpointConfiguration(host: "127.0.0.1", port: port))
        await client.start()
        defer { Task { await client.stop() } }

        // Wait for hello with capabilities
        for _ in 0..<80 {
            if await client.supportsNativeInput { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let supported = await client.supportsNativeInput
        XCTAssertTrue(supported)

        let tapAck = try await client.injectTap(x: 540, y: 1200)
        XCTAssertTrue(tapAck.ok)
        XCTAssertEqual(tapAck.cmd, "tap")

        do {
            _ = try await client.injectSwipe(x1: 540, y1: 1900, x2: 540, y2: 450, durationMs: 145, holdMs: 25)
            XCTFail("Expected inputFailed error")
        } catch let err as DaemonClientError {
            XCTAssertEqual(err, .inputFailed("injected_failure"))
        }

        // Keyevent causes server to drop socket -> must fail promptly without waiting 1.5s timeout
        let t0 = Date()
        do {
            _ = try await client.injectKeyevent(keycode: 4)
            XCTFail("Expected notConnected error on disconnect")
        } catch let err as DaemonClientError {
            XCTAssertEqual(err, .notConnected)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.8)

        await client.stop()
    }

    func testExploreAndMacroUseWideFastZeroFlingScrollAndTightQuiescence() async throws {
        final class ZeroFlingMockExecutor: MacroActionExecutor, @unchecked Sendable {
            let zeroFling: Bool
            let lock = NSLock()
            var recorded: [AttributedUIAction] = []
            let onAction: @Sendable (AttributedUIAction) async -> Void

            init(zeroFling: Bool, onAction: @escaping @Sendable (AttributedUIAction) async -> Void) {
                self.zeroFling = zeroFling
                self.onAction = onAction
            }

            func supportsZeroFlingSwipes(serial: String) async -> Bool { zeroFling }

            func execute(action: AttributedUIAction, serial: String) async throws {
                lock.withLock { recorded.append(action) }
                await onAction(action)
            }
        }

        func mkNode(_ id: Int64, parent: Int64?, text: String, bounds: String, clickable: Bool, scrollable: Bool) -> ShadowUINode {
            let rect = ShadowTreeIndex.parseBoundsRect(bounds)!
            return ShadowUINode(
                index: Int(id),
                text: text,
                resourceId: "com.android.settings:id/n_\(id)",
                contentDesc: "",
                className: scrollable ? "RecyclerView" : "TextView",
                clickable: clickable,
                scrollable: scrollable,
                bounds: bounds,
                centerX: (rect.minX + rect.maxX) / 2,
                centerY: (rect.minY + rect.maxY) / 2,
                nodeId: id,
                parentId: parent,
                windowId: 1,
                childIndex: Int(id),
                depth: parent == nil ? 0 : 1,
                packageName: "com.android.settings",
                editable: false,
                focused: false,
                checked: false,
                enabled: true,
                visible: true
            )
        }

        let beforeNodes = [
            mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true),
            mkNode(2, parent: 1, text: "Apps", bounds: "[40,500][1000,620]", clickable: true, scrollable: false)
        ]
        let afterScrollNodes = [
            mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true),
            mkNode(3, parent: 1, text: "System", bounds: "[40,1400][1000,1520]", clickable: true, scrollable: false)
        ]
        let systemScreenNodes = [
            mkNode(4, parent: nil, text: "Developer options", bounds: "[40,800][1000,920]", clickable: true, scrollable: false)
        ]

        let feed: @Sendable (ShadowGraphBridge, UInt64, [ShadowUINode]) async -> Void = { bridge, seq, nodes in
            await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                seq: seq,
                timestampMs: 1_700_000_000_000 + Int64(seq) * 50,
                reason: "test",
                activePackage: "com.android.settings",
                activeWindowId: 1,
                nodeCount: nodes.count,
                nodes: nodes,
                secureScreenActive: false
            )))
        }

        let bridge = ShadowGraphBridge()
        await feed(bridge, 1, beforeNodes)

        let exec = ZeroFlingMockExecutor(zeroFling: true) { action in
            if action.kind == .swipe {
                await feed(bridge, 2, afterScrollNodes)
            } else if action.kind == .tap {
                await feed(bridge, 3, systemScreenNodes)
            }
        }

        let outcome = try await bridge.exploreAndClick(
            target: "System",
            serial: "SER1",
            executor: exec,
            maxScrolls: 2,
            stepTimeoutMs: 400,
            postSettleQuiescenceMs: 40,
            preferGraphRoute: false
        )
        guard case .exploredAndClicked(_, let scrolls, _, _, _, _, _, _) = outcome else {
            return XCTFail("Expected exploredAndClicked, got \(outcome)")
        }
        XCTAssertEqual(scrolls, 1)

        let actions = exec.lock.withLock { exec.recorded }
        let swipe = try XCTUnwrap(actions.first(where: { $0.kind == .swipe }))
        // Container [0,400][1080,2400], span=2000 -> 80%=2000, 18%=760, dur=145ms
        XCTAssertEqual(swipe.y, 2000)
        XCTAssertEqual(swipe.endY, 760)
        XCTAssertEqual(swipe.durationMs, 145)

        // MacroExecutionEngine post-swipe quiescence timing with zeroFling=true (<320ms, not >=480ms)
        let bridge2 = ShadowGraphBridge()
        await feed(bridge2, 10, beforeNodes)
        let h1 = bridge2.hasher.fingerprint(for: await bridge2.domState.currentIndex!).layoutHash
        await feed(bridge2, 11, afterScrollNodes)
        let h2 = bridge2.hasher.fingerprint(for: await bridge2.domState.currentIndex!).layoutHash
        await feed(bridge2, 12, systemScreenNodes)
        let h3 = bridge2.hasher.fingerprint(for: await bridge2.domState.currentIndex!).layoutHash
        await feed(bridge2, 13, beforeNodes)

        let path = [
            ScreenTransitionEdge(
                fromHash: h1,
                toHash: h2,
                action: AttributedUIAction(
                    kind: .swipe,
                    targetDescription: "explore_scroll_down",
                    x: 540,
                    y: 2000,
                    endX: 540,
                    endY: 760,
                    durationMs: 145
                ),
                actionSignature: "swipe:scroll"
            ),
            ScreenTransitionEdge(
                fromHash: h2,
                toHash: h3,
                action: AttributedUIAction(kind: .tap, targetDescription: "System", x: 520, y: 1460),
                actionSignature: "tap:System"
            )
        ]

        let fastExec = ZeroFlingMockExecutor(zeroFling: true) { action in
            if action.kind == .swipe {
                await feed(bridge2, 14, afterScrollNodes)
            } else {
                await feed(bridge2, 15, systemScreenNodes)
            }
        }
        let engine = MacroExecutionEngine(
            domState: bridge2.domState,
            graphEngine: bridge2.graphEngine,
            executor: fastExec,
            hasher: bridge2.hasher,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 500, postSettleQuiescenceMs: 40)
        )
        let t0 = Date()
        let report = try await engine.execute(path: path, serial: "SER1")
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertLessThan(elapsed, 0.35, "Expected zero-fling swipe->tap quiescence (~85ms), took \(elapsed)s")
    }

    func testIntermediateScrollSettlesOnOneRowShiftAndExploreDrainsMidSwipeFrames() async throws {
        final class ZeroFlingMockExecutor: MacroActionExecutor, @unchecked Sendable {
            let onAction: @Sendable (AttributedUIAction) async -> Void
            init(onAction: @escaping @Sendable (AttributedUIAction) async -> Void) {
                self.onAction = onAction
            }
            func supportsZeroFlingSwipes(serial: String) async -> Bool { true }
            func execute(action: AttributedUIAction, serial: String) async throws {
                await onAction(action)
            }
        }

        func mkNode(_ id: Int64, parent: Int64?, text: String, bounds: String, clickable: Bool, scrollable: Bool) -> ShadowUINode {
            let rect = ShadowTreeIndex.parseBoundsRect(bounds)!
            return ShadowUINode(
                index: Int(id),
                text: text,
                resourceId: "com.android.settings:id/n_\(id)",
                contentDesc: "",
                className: scrollable ? "RecyclerView" : "TextView",
                clickable: clickable,
                scrollable: scrollable,
                bounds: bounds,
                centerX: (rect.minX + rect.maxX) / 2,
                centerY: (rect.minY + rect.maxY) / 2,
                nodeId: id,
                parentId: parent,
                windowId: 1,
                childIndex: Int(id),
                depth: parent == nil ? 0 : 1,
                packageName: "com.android.settings",
                editable: false,
                focused: false,
                checked: false,
                enabled: true,
                visible: true
            )
        }

        let feed: @Sendable (ShadowGraphBridge, UInt64, [ShadowUINode]) async -> Void = { bridge, seq, nodes in
            await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
                seq: seq,
                timestampMs: 1_700_000_000_000 + Int64(seq) * 50,
                reason: "test",
                activePackage: "com.android.settings",
                activeWindowId: 1,
                nodeCount: nodes.count,
                nodes: nodes,
                secureScreenActive: false
            )))
        }

        // Part 1: exploreAndClick drains early mid-swipe frame and settles on delayed post-UP frame.
        let bridge = ShadowGraphBridge()
        let topNodes = [
            mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true),
            mkNode(2, parent: 1, text: "Network", bounds: "[40,500][1000,620]", clickable: true, scrollable: false)
        ]
        let midSwipeNodes = [
            mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true),
            mkNode(3, parent: 1, text: "Notifications", bounds: "[40,500][1000,620]", clickable: true, scrollable: false)
        ]
        let settledNodes = [
            mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true),
            mkNode(4, parent: 1, text: "System", bounds: "[40,1400][1000,1520]", clickable: true, scrollable: false)
        ]
        let systemNodes = [
            mkNode(5, parent: nil, text: "Developer options", bounds: "[40,600][1000,720]", clickable: true, scrollable: false)
        ]
        await feed(bridge, 1, topNodes)

        let exploreExec = ZeroFlingMockExecutor { action in
            if action.kind == .swipe {
                Task {
                    await feed(bridge, 2, midSwipeNodes)
                    try? await Task.sleep(for: .milliseconds(65))
                    await feed(bridge, 3, settledNodes)
                }
            } else if action.kind == .tap {
                await feed(bridge, 4, systemNodes)
            }
        }
        let outcome = try await bridge.exploreAndClick(
            target: "System",
            serial: "SER1",
            executor: exploreExec,
            maxScrolls: 2,
            stepTimeoutMs: 500,
            postSettleQuiescenceMs: 40,
            preferGraphRoute: false
        )
        guard case .exploredAndClicked(_, let scrolls, _, _, _, _, _, _) = outcome else {
            return XCTFail("Expected exploredAndClicked after draining mid-swipe frame, got \(outcome)")
        }
        XCTAssertEqual(scrolls, 1)

        // Part 2: Intermediate scroll landing 1 row off (Jaccard 7/9 = 0.7778 in [0.65, 0.80))
        // settles cleanly and lets the following tap complete.
        let shared = ["RowB", "RowC", "RowD", "RowE", "RowF", "RowG", "System"]
        let recordedLabels = ["RowA"] + shared
        let shiftedLabels = shared + ["RowH"]
        func mkList(_ baseId: Int64, _ labels: [String]) -> [ShadowUINode] {
            var out = [mkNode(1, parent: nil, text: "", bounds: "[0,400][1080,2400]", clickable: false, scrollable: true)]
            for (i, lbl) in labels.enumerated() {
                let y0 = 450 + i * 140
                let bounds = "[40,\(y0)][1000,\(y0 + 110)]"
                let rect = ShadowTreeIndex.parseBoundsRect(bounds)!
                out.append(ShadowUINode(
                    index: Int(baseId) + i,
                    text: lbl,
                    resourceId: "android:id/title",
                    contentDesc: "",
                    className: "TextView",
                    clickable: true,
                    scrollable: false,
                    bounds: bounds,
                    centerX: (rect.minX + rect.maxX) / 2,
                    centerY: (rect.minY + rect.maxY) / 2,
                    nodeId: baseId + Int64(i),
                    parentId: 1,
                    windowId: 1,
                    childIndex: i,
                    depth: 1,
                    packageName: "com.android.settings",
                    editable: false,
                    focused: false,
                    checked: false,
                    enabled: true,
                    visible: true
                ))
            }
            return out
        }

        let startNodes = mkList(10, ["Header1", "Header2", "Header3"])
        let recScrollNodes = mkList(30, recordedLabels)
        let shiftedScrollNodes = mkList(50, shiftedLabels)
        let goalNodes = [mkNode(99, parent: nil, text: "GoalScreen", bounds: "[40,500][1000,620]", clickable: true, scrollable: false)]

        let bridge2 = ShadowGraphBridge()
        await feed(bridge2, 10, startNodes)
        let hStart = bridge2.hasher.fingerprint(for: await bridge2.domState.currentIndex!).layoutHash
        await feed(bridge2, 11, recScrollNodes)
        let recIdx = await bridge2.domState.currentIndex!
        let hRecScroll = bridge2.hasher.fingerprint(for: recIdx).layoutHash
        await bridge2.graphEngine.process(update: ShadowDOMUpdate(
            index: recIdx,
            isFullSnapshot: true,
            insertedCount: recScrollNodes.count,
            updatedCount: 0,
            removedCount: 0
        ))
        await feed(bridge2, 12, goalNodes)
        let hGoal = bridge2.hasher.fingerprint(for: await bridge2.domState.currentIndex!).layoutHash
        await feed(bridge2, 13, startNodes)

        let path = [
            ScreenTransitionEdge(
                fromHash: hStart,
                toHash: hRecScroll,
                action: AttributedUIAction(kind: .swipe, targetDescription: "explore_scroll_down", x: 540, y: 2000, endX: 540, endY: 760, durationMs: 145),
                actionSignature: "swipe:scroll"
            ),
            ScreenTransitionEdge(
                fromHash: hRecScroll,
                toHash: hGoal,
                action: AttributedUIAction(kind: .tap, targetDescription: "System", x: 520, y: 1350),
                actionSignature: "tap:System"
            )
        ]

        let shiftExec = ZeroFlingMockExecutor { action in
            if action.kind == .swipe {
                await feed(bridge2, 14, shiftedScrollNodes)
            } else {
                await feed(bridge2, 15, goalNodes)
            }
        }
        let engine = MacroExecutionEngine(
            domState: bridge2.domState,
            graphEngine: bridge2.graphEngine,
            executor: shiftExec,
            hasher: bridge2.hasher,
            configuration: MacroExecutionConfiguration(
                stepTimeoutMs: 600,
                postSettleQuiescenceMs: 20,
                settleSimilarityThreshold: 0.80
            )
        )
        let report = try await engine.execute(path: path, serial: "SER1")
        XCTAssertEqual(report.steps.count, 2)
        XCTAssertEqual(report.finalHash, hGoal)
    }

    func testTCPClientCancellationFailsFastWithoutSendingAndWaitForHelloEnablesColdStart() async throws {
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params, on: .any)
        let queue = DispatchQueue(label: "test.native.input.cancel.listener")

        final class MockHarness: @unchecked Sendable {
            let lock = NSLock()
            var receivedLines: [String] = []
            var buffer = Data()
        }
        let harness = MockHarness()

        let readyExp = expectation(description: "listener ready")
        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            let hello = #"{"type":"hello","protocol_version":1,"format":"ndjson/1","sdk_int":37,"device_model":"MockPixel","pid":88,"capabilities":["input"]}"# + "\n"
            conn.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })

            // Record inbound lines without replying so mid-flight cancellation can be tested deterministically
            func readLoop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        harness.lock.withLock {
                            harness.buffer.append(data)
                            while let nl = harness.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                                let lineData = harness.buffer.prefix(upTo: nl)
                                harness.buffer.removeSubrange(...nl)
                                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !line.isEmpty {
                                    harness.receivedLines.append(line)
                                }
                            }
                        }
                    }
                    if !isComplete && error == nil {
                        readLoop()
                    }
                }
            }
            readLoop()
        }

        listener.start(queue: queue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        defer { listener.cancel() }

        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = DaemonTCPClient(configuration: DaemonEndpointConfiguration(host: "127.0.0.1", port: port))
        await client.start()
        defer { Task { await client.stop() } }

        // 1. waitForHello unlocks cold-start native input promptly
        let gotHello = await client.waitForHello(maxWaitMs: 500)
        XCTAssertTrue(gotHello)
        let supported = await client.supportsNativeInput
        XCTAssertTrue(supported)

        // 2. Pre-cancelled Task must throw CancellationError immediately WITHOUT sending any frame over TCP
        let preCancelled = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await client.injectTap(x: 111, y: 222)
        }
        let t0 = Date()
        do {
            try await preCancelled.value
            XCTFail("Expected CancellationError on pre-cancelled task")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(
            harness.lock.withLock { harness.receivedLines.isEmpty },
            "Pre-cancelled injectTap must never write a command to the socket"
        )

        // 3. Mid-flight cancellation while daemon has not replied must throw CancellationError promptly (<300ms)
        let inFlight = Task<Void, Error> {
            _ = try await client.injectTap(x: 333, y: 444)
        }
        try await Task.sleep(for: .milliseconds(40))
        let t1 = Date()
        inFlight.cancel()
        do {
            try await inFlight.value
            XCTFail("Expected CancellationError on cancelled in-flight tap")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.3)

        await client.stop()

        // 4. waitForHello on closed port fails fast
        let closedParams = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        closedParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let closedListener = try NWListener(using: closedParams, on: .any)
        closedListener.newConnectionHandler = { $0.cancel() }
        let closedExp = expectation(description: "closed listener ready")
        closedListener.stateUpdateHandler = { st in
            if case .ready = st { closedExp.fulfill() }
        }
        closedListener.start(queue: queue)
        await fulfillment(of: [closedExp], timeout: 3.0)
        let closedPort = try XCTUnwrap(closedListener.port?.rawValue)
        closedListener.cancel()

        let deadClient = DaemonTCPClient(configuration: DaemonEndpointConfiguration(host: "127.0.0.1", port: closedPort))
        await deadClient.start()
        let deadHello = await deadClient.waitForHello(maxWaitMs: 300)
        XCTAssertFalse(deadHello)
        await deadClient.stop()
    }
}
