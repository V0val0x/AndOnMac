import XCTest
@testable import AndroidShadowGraphKit

final class PrivacyExploreResilienceTests: XCTestCase {
    private func mkNode(
        id: Int64,
        parentId: Int64? = nil,
        idx: Int,
        pkg: String,
        cls: String,
        rid: String = "",
        text: String = "",
        desc: String = "",
        bounds: String,
        clickable: Bool = false,
        scrollable: Bool = false,
        editable: Bool = false
    ) -> ShadowUINode {
        let rect = ShadowTreeIndex.parseBoundsRect(bounds)
        let cx = rect.map { ($0.minX + $0.maxX) / 2 } ?? 100
        let cy = rect.map { ($0.minY + $0.maxY) / 2 } ?? 50
        return ShadowUINode(
            index: idx,
            text: text,
            resourceId: rid,
            contentDesc: desc,
            className: cls,
            clickable: clickable,
            scrollable: scrollable,
            bounds: bounds,
            centerX: cx,
            centerY: cy,
            nodeId: id,
            parentId: parentId,
            windowId: 1,
            childIndex: idx,
            depth: parentId == nil ? 0 : 1,
            packageName: pkg,
            editable: editable,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
    }

    @discardableResult
    private func pushScreen(
        _ bridge: ShadowGraphBridge,
        seq: UInt64,
        pkg: String,
        nodes: [ShadowUINode]
    ) async -> UInt64 {
        let payload = WireSnapshotPayload(
            seq: seq,
            timestampMs: 1_700_000_000_000 + Int64(seq) * 100,
            reason: "test",
            activePackage: pkg,
            activeWindowId: 1,
            nodeCount: nodes.count,
            nodes: nodes,
            secureScreenActive: false
        )
        await bridge.domState.handleMessage(.snapshot(payload))
        let idx = await bridge.domState.currentIndex!
        return bridge.hasher.fingerprint(for: idx).layoutHash
    }

    @discardableResult
    private func seedScreenIntoGraph(
        _ bridge: ShadowGraphBridge,
        seq: UInt64,
        pkg: String,
        nodes: [ShadowUINode]
    ) async -> UInt64 {
        let hash = await pushScreen(bridge, seq: seq, pkg: pkg, nodes: nodes)
        let idx = await bridge.domState.currentIndex!
        await bridge.graphEngine.process(update: ShadowDOMUpdate(
            index: idx,
            isFullSnapshot: true,
            insertedCount: nodes.count,
            updatedCount: 0,
            removedCount: 0,
            eventPackage: pkg,
            isSecureScreenActive: false
        ))
        return hash
    }

    private final class ScriptedExecutor: MacroActionExecutor, @unchecked Sendable {
        private let handler: @Sendable (AttributedUIAction) async -> Void
        private let lock = NSLock()
        private var recorded: [AttributedUIAction] = []

        init(_ handler: @escaping @Sendable (AttributedUIAction) async -> Void) {
            self.handler = handler
        }

        var actions: [AttributedUIAction] {
            lock.withLock { recorded }
        }

        func execute(action: AttributedUIAction, serial: String) async throws {
            lock.withLock { recorded.append(action) }
            await handler(action)
        }
    }

    // MARK: - R1: Privacy by Design (redactPII + bit-exact parity with Rust + zero leak in shadow_graph.json)

    func testPrivacyRedactPIILuhnOTPBitExactParityWithRustAndZeroLeak() async throws {
        // 1. Valid Luhn PANs -> <CARD>
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Card 4532 0151 1283 0366"), "Card <CARD>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Pay with 4111-1111-1111-1111 now"), "Pay with <CARD> now")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Amex 378282246310005"), "Amex <CARD>")

        // 2. Invalid Luhn / repeated digits / >19 digits untouched
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Not card 4111 1111 1111 1112"), "Not card 4111 1111 1111 1112")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Zeros 0000 0000 0000 0000"), "Zeros 0000 0000 0000 0000")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Ones 1111-1111-1111-1111"), "Ones 1111-1111-1111-1111")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Long 41111111111111110000"), "Long 41111111111111110000")

        // 3. Context-anchored OTPs (EN + RU) -> <OTP>
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Your verification code is 482910"), "Your verification code is <OTP>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("482910 is your verification code"), "<OTP> is your verification code")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Код подтверждения: 592041"), "Код подтверждения: <OTP>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("482910 — ваш код подтверждения"), "<OTP> — ваш код подтверждения")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Код из СМС: 7391"), "Код из СМС: <OTP>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("2FA code 839201"), "2FA code <OTP>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("PIN: 0492"), "PIN: <OTP>")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("2026-05-12 Verification code: 482910"), "2026-05-12 Verification code: <OTP>")

        // 4. Ordinary numbers untouched
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Copyright 2026"), "Copyright 2026")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Display 1080x2400"), "Display 1080x2400")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("shipping 1234"), "shipping 1234")
        XCTAssertEqual(ScreenLayoutHasher.redactPII("Order #482910"), "Order #482910")

        // 5. normalizeLabel runs redactPII before collapsing digits
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("Card 4532 0151 1283 0366"), "Card <CARD>")
        XCTAssertEqual(ScreenLayoutHasher.normalizeLabel("Код подтверждения: 592041"), "Код подтверждения: <OTP>")

        // 6. Bit-exact FNV-1a parity with Rust DroidPath + zero PII leak in exported shadow_graph.json
        let engine = SpatialGraphEngine()
        let screenA = ShadowTreeIndex(
            seq: 1,
            timestampMs: 1000,
            activePackage: "com.bank.app",
            activeWindowId: 1,
            nodes: [
                mkNode(id: 1, idx: 0, pkg: "com.bank.app", cls: "EditText", rid: "com.bank.app:id/password", text: "***", desc: "Password", bounds: "[40,100][900,220]", clickable: true, editable: true),
                mkNode(id: 2, idx: 1, pkg: "com.bank.app", cls: "TextView", rid: "com.bank.app:id/card_number", text: "Card 4532 0151 1283 0366", bounds: "[40,260][900,360]", clickable: true),
                mkNode(id: 3, idx: 2, pkg: "com.bank.app", cls: "TextView", rid: "com.bank.app:id/otp_msg", text: "Ваш код подтверждения: 482910", bounds: "[40,400][900,500]", clickable: true)
            ]
        )
        await engine.process(update: ShadowDOMUpdate(index: screenA, isFullSnapshot: true, insertedCount: 3, updatedCount: 0, removedCount: 0))

        let hashA = await engine.currentStateHash
        XCTAssertEqual(hashA, 5_292_584_532_450_752_986, "Swift FNV-1a hash must match Rust DroidPath bit-for-bit!")

        await engine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "Card 4532 0151 1283 0366",
            x: 300,
            y: 310,
            textInput: "OTP 918273",
            selectorText: "Код подтверждения: 482910"
        ))

        let screenB = ShadowTreeIndex(
            seq: 2,
            timestampMs: 2000,
            activePackage: "com.bank.app",
            activeWindowId: 1,
            nodes: [
                mkNode(id: 10, idx: 0, pkg: "com.bank.app", cls: "TextView", rid: "com.bank.app:id/done", text: "Done", bounds: "[40,100][900,220]", clickable: true),
                mkNode(id: 11, idx: 1, pkg: "com.bank.app", cls: "TextView", rid: "com.bank.app:id/year", text: "Copyright 2026", bounds: "[40,260][900,360]")
            ]
        )
        let edge = await engine.process(update: ShadowDOMUpdate(index: screenB, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        XCTAssertEqual(edge?.actionSignature, "tap:Card <CARD>")
        let hashB = await engine.currentStateHash
        XCTAssertEqual(hashB, 12_859_422_700_238_890_943, "Swift FNV-1a hash B must match Rust DroidPath bit-for-bit!")

        let data = try await engine.exportGraphJSON(prettyPrinted: true)
        let obj = try JSONSerialization.jsonObject(with: data)
        var allStrings: [String] = []
        func walk(_ val: Any) {
            if let s = val as? String {
                allStrings.append(s)
            } else if let arr = val as? [Any] {
                for item in arr { walk(item) }
            } else if let dict = val as? [String: Any] {
                for v in dict.values { walk(v) }
            }
        }
        walk(obj)
        let joined = allStrings.joined(separator: "\n")
        for forbidden in ["4532", "0151", "1283", "0366", "482910", "918273"] {
            XCTAssertFalse(joined.contains(forbidden), "PII fragment '\(forbidden)' leaked into shadow_graph.json")
        }
        XCTAssertTrue(joined.contains("<CARD>"))
        XCTAssertTrue(joined.contains("<OTP>"))
        XCTAssertTrue(joined.contains("Copyright 2026"))
    }

    // MARK: - R2: Dynamic Fallback (exploreAndClick + autoExplore + scoring + scroll + hazard + needsSelection)

    func testExploreAndClickColdStartScrollReversePrefixHazardNeedsSelectionAndAutoExplore() async throws {
        // Case A: Cold-start empty graph -> clickable ancestor scoring -> tap + settle + DAG edge
        let bridge = ShadowGraphBridge()
        let homeNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "LinearLayout", rid: "com.android.settings:id/row1", bounds: "[0,200][1080,360]", clickable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Display", bounds: "[80,240][500,320]"),
            mkNode(id: 3, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Battery", bounds: "[80,400][500,480]", clickable: true)
        ]
        let displayNodes = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Display", bounds: "[80,120][500,200]"),
            mkNode(id: 11, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/night_light", text: "Night Light", bounds: "[80,300][500,380]", clickable: true),
            mkNode(id: 12, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/pay_btn", text: "Pay Now", bounds: "[80,600][500,680]", clickable: true)
        ]
        await pushScreen(bridge, seq: 1, pkg: "com.android.settings", nodes: homeNodes)

        let execCold = ScriptedExecutor { _ in
            try? await Task.sleep(for: .milliseconds(15))
            await self.pushScreen(bridge, seq: 2, pkg: "com.android.settings", nodes: displayNodes)
        }
        let outcome = try await bridge.exploreAndClick(
            target: "Display",
            serial: "SER1",
            executor: execCold,
            stepTimeoutMs: 800,
            postSettleQuiescenceMs: 0
        )
        if case .exploredAndClicked(let cand, let scrolls, _, _, _, let changed, let recorded, _) = outcome {
            XCTAssertEqual(cand.label, "Display")
            XCTAssertEqual(cand.score, 1100)
            XCTAssertTrue(cand.clickable)
            XCTAssertEqual(scrolls, 0)
            XCTAssertTrue(changed)
            XCTAssertTrue(recorded)
        } else {
            XCTFail("Expected exploredAndClicked, got \(outcome)")
        }
        let vCount = await bridge.graphEngine.vertexCount
        let eCount = await bridge.graphEngine.edgeCount
        XCTAssertEqual(vCount, 2)
        XCTAssertEqual(eCount, 1)

        // Case B: Hazard guard blocks unconfirmed Pay Now
        let noopExec = ScriptedExecutor { _ in }
        let hazOutcome = try await bridge.exploreAndClick(
            target: "Pay Now",
            serial: "SER1",
            executor: noopExec,
            postSettleQuiescenceMs: 0,
            confirmed: false,
            preferGraphRoute: false
        )
        if case .requiresConfirmation = hazOutcome {
            XCTAssertTrue(noopExec.actions.isEmpty)
        } else {
            XCTFail("Expected requiresConfirmation, got \(hazOutcome)")
        }

        // Case C: Scroll down hits bottom -> reverses UP -> finds & clicks target
        let bridgeScroll = ShadowGraphBridge()
        let bottomNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/list", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "System", bounds: "[80,300][600,400]", clickable: true),
            mkNode(id: 3, parentId: 1, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "About phone", bounds: "[80,450][600,550]", clickable: true)
        ]
        let topNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/list", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 4, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Network & internet", bounds: "[80,300][600,400]", clickable: true)
        ]
        let netScreen = [
            mkNode(id: 20, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Network & internet", bounds: "[80,120][600,200]"),
            mkNode(id: 21, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/wifi", text: "Internet", bounds: "[80,300][600,400]", clickable: true)
        ]
        await pushScreen(bridgeScroll, seq: 1, pkg: "com.android.settings", nodes: bottomNodes)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 2
            func next() -> UInt64 { lock.withLock { defer { value += 1 }; return value } }
        }
        let seqCounter = Counter()
        let execScroll = ScriptedExecutor { act in
            try? await Task.sleep(for: .milliseconds(15))
            if act.kind == .swipe, (act.y ?? 0) < (act.endY ?? 0) {
                await self.pushScreen(bridgeScroll, seq: seqCounter.next(), pkg: "com.android.settings", nodes: topNodes)
            } else if act.kind == .tap {
                await self.pushScreen(bridgeScroll, seq: seqCounter.next(), pkg: "com.android.settings", nodes: netScreen)
            }
        }
        let scrollOutcome = try await bridgeScroll.exploreAndClick(
            target: "Network & internet",
            serial: "SER1",
            executor: execScroll,
            maxScrolls: 3,
            stepTimeoutMs: 200,
            postSettleQuiescenceMs: 0,
            preferGraphRoute: false
        )
        if case .exploredAndClicked(let cand, let scrolls, _, _, _, let changed, let recorded, _) = scrollOutcome {
            XCTAssertEqual(cand.label, "Network & internet")
            XCTAssertEqual(scrolls, 2)
            XCTAssertTrue(changed)
            XCTAssertTrue(recorded)
        } else {
            XCTFail("Expected exploredAndClicked after scroll reverse, got \(scrollOutcome)")
        }

        // Case D: NeedsSelection capped at top-20 & PII-scrubbed + autoExplore fallback
        let bridgeSel = ShadowGraphBridge()
        var manyNodes: [ShadowUINode] = []
        for i in 0..<25 {
            let lbl: String
            if i == 0 { lbl = "Card 4532 0151 1283 0366" }
            else if i == 1 { lbl = "Code: 482910" }
            else { lbl = "Menu Item \(i)" }
            manyNodes.append(mkNode(
                id: Int64(i + 1),
                idx: i,
                pkg: "com.example.shop",
                cls: "TextView",
                rid: "com.example.shop:id/item_\(i)",
                text: lbl,
                bounds: "[40,\(100 + i * 60)][900,\(150 + i * 60)]",
                clickable: true
            ))
        }
        await pushScreen(bridgeSel, seq: 1, pkg: "com.example.shop", nodes: manyNodes)

        let autoOutcome = try await bridgeSel.routeAndExecute(
            targetHint: "NonexistentWidget",
            serial: "SER1",
            executor: noopExec,
            postSettleQuiescenceMs: 0,
            autoExplore: true
        )
        if case .explored(.needsSelection(_, _, _, _, let candidates)) = autoOutcome {
            XCTAssertEqual(candidates.count, 20)
            XCTAssertTrue(candidates.allSatisfy { !$0.label.contains("4532") && !$0.label.contains("482910") })
            XCTAssertTrue(candidates.contains(where: { $0.label.contains("<CARD>") }))
            XCTAssertTrue(candidates.contains(where: { $0.label.contains("<OTP>") }))
        } else {
            XCTFail("Expected .explored(.needsSelection), got \(autoOutcome)")
        }

        // Case E: Cold-start launcher with clickable "Settings" icon -> autoExplore MUST click it,
        // and once inside com.android.settings, repeating must return .alreadyAtTarget.
        let bridgeCold = ShadowGraphBridge()
        let launcherNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.google.android.apps.nexuslauncher", cls: "TextView", rid: "com.google.android.apps.nexuslauncher:id/icon", text: "Settings", desc: "Settings", bounds: "[100,900][240,1100]", clickable: true),
            mkNode(id: 2, idx: 1, pkg: "com.google.android.apps.nexuslauncher", cls: "TextView", rid: "com.google.android.apps.nexuslauncher:id/icon", text: "Clock", desc: "Clock", bounds: "[300,900][440,1100]", clickable: true)
        ]
        let settingsRootNodes = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Settings", bounds: "[80,100][500,180]"),
            mkNode(id: 11, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Network & internet", bounds: "[80,300][600,380]", clickable: true)
        ]
        await pushScreen(bridgeCold, seq: 1, pkg: "com.google.android.apps.nexuslauncher", nodes: launcherNodes)
        let execColdLauncher = ScriptedExecutor { _ in
            try? await Task.sleep(for: .milliseconds(15))
            await self.pushScreen(bridgeCold, seq: 2, pkg: "com.android.settings", nodes: settingsRootNodes)
        }
        let coldRes = try await bridgeCold.routeAndExecute(
            targetHint: "Settings",
            serial: "SER1",
            executor: execColdLauncher,
            stepTimeoutMs: 800,
            postSettleQuiescenceMs: 0,
            autoExplore: true
        )
        if case .explored(.exploredAndClicked(let cand, _, _, _, let pkg, let changed, let recorded, _)) = coldRes {
            XCTAssertEqual(cand.label, "Settings")
            XCTAssertTrue(changed)
            XCTAssertTrue(recorded)
            XCTAssertEqual(pkg, "com.android.settings")
        } else {
            XCTFail("Expected cold-start autoExplore to click Settings, got \(coldRes)")
        }

        let noopAfter = ScriptedExecutor { _ in }
        let alreadyIn = try await bridgeCold.routeAndExecute(
            targetHint: "Settings",
            serial: "SER1",
            executor: noopAfter,
            postSettleQuiescenceMs: 0,
            autoExplore: true
        )
        if case .alreadyAtTarget(_, let pkg) = alreadyIn {
            XCTAssertEqual(pkg, "com.android.settings")
        } else {
            XCTFail("Expected .alreadyAtTarget once inside com.android.settings, got \(alreadyIn)")
        }
        XCTAssertTrue(noopAfter.actions.isEmpty)
    }

    // MARK: - R4: Back-to-Root, Smart Scroll-to-Selector, Edge Decay & Self-Pruning

    func testRouterResilienceBackToRootSmartScrollAndEdgeDecay() async throws {
        // 1. App Task-Stack Drift (Back-to-Root)
        let bridge = ShadowGraphBridge()
        let home = [
            mkNode(id: 1, idx: 0, pkg: "com.launcher", cls: "TextView", rid: "com.launcher:id/s", text: "Settings", bounds: "[100,400][300,500]", clickable: true),
            mkNode(id: 2, idx: 1, pkg: "com.launcher", cls: "TextView", rid: "com.launcher:id/c", text: "Camera", bounds: "[400,400][600,500]", clickable: true)
        ]
        let settingsRoot = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Settings", bounds: "[80,100][500,180]"),
            mkNode(id: 11, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/display", text: "Display", bounds: "[80,300][500,380]", clickable: true),
            mkNode(id: 12, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/sound", text: "Sound", bounds: "[80,440][500,520]", clickable: true)
        ]
        let displayScreen = [
            mkNode(id: 20, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Display", bounds: "[80,100][500,180]"),
            mkNode(id: 21, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/br", text: "Brightness level", bounds: "[80,300][500,380]", clickable: true)
        ]
        let deepSub2 = [
            mkNode(id: 30, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "Legal information", bounds: "[80,100][700,180]"),
            mkNode(id: 31, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/lic", text: "Open source licenses", bounds: "[80,300][700,380]", clickable: true)
        ]
        let deepSub1 = [
            mkNode(id: 40, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "About phone", bounds: "[80,100][700,180]"),
            mkNode(id: 41, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/build", text: "Build number", bounds: "[80,300][700,380]", clickable: true)
        ]

        await seedScreenIntoGraph(bridge, seq: 1, pkg: "com.launcher", nodes: home)
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 200, y: 450))
        await seedScreenIntoGraph(bridge, seq: 2, pkg: "com.android.settings", nodes: settingsRoot)
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Display", x: 290, y: 340))
        await seedScreenIntoGraph(bridge, seq: 3, pkg: "com.android.settings", nodes: displayScreen)
        // Also seed a realistic `deepSub2 --(HOME)--> home` edge to prove `replan_from` does not
        // cycle back through Home -> Settings instead of triggering Back-to-Root.
        await seedScreenIntoGraph(bridge, seq: 4, pkg: "com.android.settings", nodes: deepSub2)
        await bridge.graphEngine.recordPendingAction(AttributedUIAction(kind: .keyevent, targetDescription: "HOME"))
        await seedScreenIntoGraph(bridge, seq: 5, pkg: "com.launcher", nodes: home)
        await pushScreen(bridge, seq: 6, pkg: "com.launcher", nodes: home)

        final class DriftState: @unchecked Sendable {
            private let lock = NSLock()
            private var seq: UInt64 = 7
            private var backs = 0
            func nextSeq() -> UInt64 { lock.withLock { defer { seq += 1 }; return seq } }
            func incBack() -> Int { lock.withLock { backs += 1; return backs } }
        }
        let st = DriftState()
        let execDrift = ScriptedExecutor { act in
            try? await Task.sleep(for: .milliseconds(15))
            let s = st.nextSeq()
            if act.kind == .tap && act.targetDescription == "Settings" {
                await self.pushScreen(bridge, seq: s, pkg: "com.android.settings", nodes: deepSub2)
            } else if act.kind == .keyevent && act.targetDescription == "BACK" {
                let n = st.incBack()
                await self.pushScreen(bridge, seq: s, pkg: "com.android.settings", nodes: n == 1 ? deepSub1 : settingsRoot)
            } else if act.kind == .tap && act.targetDescription == "Display" {
                await self.pushScreen(bridge, seq: s, pkg: "com.android.settings", nodes: displayScreen)
            }
        }

        let navRes = try await bridge.routeAndExecute(
            targetHint: "Brightness level",
            serial: "SER1",
            executor: execDrift,
            stepTimeoutMs: 200,
            postSettleQuiescenceMs: 0,
            enableAutoRecovery: true
        )
        if case .arrived(let report) = navRes {
            XCTAssertTrue(report.recoveredSteps.contains("back_to_root:2"), "Expected back_to_root:2 in \(report.recoveredSteps)")
        } else {
            XCTFail("Expected .arrived via back_to_root, got \(navRes)")
        }

        // 2. Smart Scroll-to-Selector inside MacroExecutionEngine
        let bridgeSS = ShadowGraphBridge()
        let listTop = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/rv", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Network", bounds: "[80,300][500,380]", clickable: true),
            mkNode(id: 3, parentId: 1, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Apps", bounds: "[80,440][500,520]", clickable: true)
        ]
        let listBottom = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/rv", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 4, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/about_id", text: "About phone", bounds: "[80,900][500,980]", clickable: true)
        ]
        let aboutPage = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", text: "About phone", bounds: "[80,100][500,180]"),
            mkNode(id: 11, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "com.android.settings:id/model", text: "Pixel 10a", bounds: "[80,300][500,380]")
        ]

        let startH = await seedScreenIntoGraph(bridgeSS, seq: 1, pkg: "com.android.settings", nodes: listTop)
        await bridgeSS.graphEngine.recordPendingAction(AttributedUIAction(
            kind: .tap,
            targetDescription: "About phone",
            x: 10,
            y: 10,
            selectorResourceId: "com.android.settings:id/about_id",
            selectorText: "About phone"
        ))
        let targetH = await seedScreenIntoGraph(bridgeSS, seq: 2, pkg: "com.android.settings", nodes: aboutPage)
        await pushScreen(bridgeSS, seq: 3, pkg: "com.android.settings", nodes: listTop)

        let seqSS = DriftState()
        let execSS = ScriptedExecutor { act in
            try? await Task.sleep(for: .milliseconds(15))
            let s = seqSS.nextSeq()
            if act.kind == .swipe {
                await self.pushScreen(bridgeSS, seq: s, pkg: "com.android.settings", nodes: listBottom)
            } else if act.kind == .tap && act.y == 940 {
                await self.pushScreen(bridgeSS, seq: s, pkg: "com.android.settings", nodes: aboutPage)
            }
        }
        let edges = await bridgeSS.graphEngine.neighbors(of: startH)
        let macroEngine = MacroExecutionEngine(
            domState: bridgeSS.domState,
            graphEngine: bridgeSS.graphEngine,
            executor: execSS,
            hasher: bridgeSS.hasher,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 400, postSettleQuiescenceMs: 0, enableSmartScrollToSelector: true)
        )
        let ssReport = try await macroEngine.execute(path: edges, serial: "SER1")
        XCTAssertEqual(ssReport.finalHash, targetH)
        XCTAssertTrue(ssReport.recoveredSteps.contains("smart_scroll_to_selector:down:1"))

        // 3. Edge Decay & Self-Pruning (consecutiveFailures)
        let legacyJSON = """
        {
          "rootStateHash": 1,
          "currentStateHash": 1,
          "vertices": [
            {"layoutHash": 1, "activePackage": "com.app", "sampleInteractiveLabels": ["A"], "semanticTokens": ["TextView||A"], "firstSeenAt": "2026-01-01T00:00:00Z", "lastSeenAt": "2026-01-01T00:00:00Z", "visitCount": 1, "discoveryDepth": 0},
            {"layoutHash": 2, "activePackage": "com.app", "sampleInteractiveLabels": ["B"], "semanticTokens": ["TextView||B"], "firstSeenAt": "2026-01-01T00:00:00Z", "lastSeenAt": "2026-01-01T00:00:00Z", "visitCount": 1, "discoveryParentHash": 1, "discoveryDepth": 1}
          ],
          "edges": [
            {"id": "11111111-1111-1111-1111-111111111111", "fromHash": 1, "toHash": 2, "action": {"kind": "tap", "targetDescription": "Go", "timestamp": "2026-01-01T00:00:00Z"}, "actionSignature": "tap:Go", "traversalCount": 3, "averageTransitionMs": 100.0, "isSpanningTreeEdge": true, "lastTraversedAt": "2026-01-01T00:00:00Z"}
          ],
          "spanningChildren": [1, [2]]
        }
        """
        let decayEngine = SpatialGraphEngine()
        try await decayEngine.importGraphJSON(Data(legacyJSON.utf8))
        let importedEdges = await decayEngine.neighbors(of: 1)
        XCTAssertEqual(importedEdges.first?.consecutiveFailures, 0)

        // A* decay penalty steers around 2x-failed direct edge
        let now = Date()
        let v: (UInt64, String) -> ScreenStateVertex = { h, lbl in
            ScreenStateVertex(layoutHash: h, activePackage: "com.app", sampleInteractiveLabels: [lbl], semanticTokens: ["TextView||\(lbl)"], firstSeenAt: now, lastSeenAt: now, visitCount: 1, discoveryParentHash: nil, discoveryDepth: 0)
        }
        let snap = SpatialGraphSnapshot(
            rootStateHash: 1,
            currentStateHash: 1,
            vertices: [v(1, "Start"), v(2, "Mid"), v(3, "Goal")],
            edges: [
                ScreenTransitionEdge(fromHash: 1, toHash: 3, action: AttributedUIAction(kind: .tap, targetDescription: "Direct"), actionSignature: "tap:Direct", traversalCount: 3, averageTransitionMs: 100, isSpanningTreeEdge: true, lastTraversedAt: now, consecutiveFailures: 2),
                ScreenTransitionEdge(fromHash: 1, toHash: 2, action: AttributedUIAction(kind: .tap, targetDescription: "Via"), actionSignature: "tap:Via", traversalCount: 3, averageTransitionMs: 100, lastTraversedAt: now, consecutiveFailures: 0),
                ScreenTransitionEdge(fromHash: 2, toHash: 3, action: AttributedUIAction(kind: .tap, targetDescription: "Finish"), actionSignature: "tap:Finish", traversalCount: 3, averageTransitionMs: 100, lastTraversedAt: now, consecutiveFailures: 0)
            ],
            spanningChildren: [:]
        )
        let pf = AStarPathfinder()
        let chosen = pf.findShortestPath(from: 1, to: 3, in: snap)
        XCTAssertEqual(chosen?.edges.count, 2, "A* must prefer healthy 2-hop route over 2x-decayed direct edge")

        // 5 consecutive StepTimeouts auto-prune dead edge & preserve acyclic spanning DAG
        let bridgePrune = ShadowGraphBridge()
        let s1 = [mkNode(id: 1, idx: 0, pkg: "com.app", cls: "TextView", rid: "id/go", text: "Go", bounds: "[10,10][200,100]", clickable: true)]
        let s2 = [mkNode(id: 2, idx: 0, pkg: "com.app", cls: "TextView", rid: "id/end", text: "End", bounds: "[10,10][200,100]", clickable: true)]
        let h1 = await seedScreenIntoGraph(bridgePrune, seq: 1, pkg: "com.app", nodes: s1)
        await bridgePrune.graphEngine.recordPendingAction(AttributedUIAction(kind: .tap, targetDescription: "Go", x: 100, y: 50))
        await seedScreenIntoGraph(bridgePrune, seq: 2, pkg: "com.app", nodes: s2)
        await pushScreen(bridgePrune, seq: 3, pkg: "com.app", nodes: s1)

        let deadEdges = await bridgePrune.graphEngine.neighbors(of: h1)
        XCTAssertEqual(deadEdges.count, 1)
        let deadEdgeId = deadEdges[0].id

        let failEngine = MacroExecutionEngine(
            domState: bridgePrune.domState,
            graphEngine: bridgePrune.graphEngine,
            executor: ScriptedExecutor { _ in },
            hasher: bridgePrune.hasher,
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 60, postSettleQuiescenceMs: 0)
        )

        for expectedFail in 1...4 {
            do {
                _ = try await failEngine.execute(path: deadEdges, serial: "SER1")
                XCTFail("Expected stepTimeout")
            } catch PathDeviationError.stepTimeout {
                let cur = await bridgePrune.graphEngine.neighbors(of: h1)
                XCTAssertEqual(cur.first?.consecutiveFailures, expectedFail)
            }
        }
        await bridgePrune.graphEngine.recordEdgeSuccess(edgeId: deadEdgeId)
        let resetNeighbors = await bridgePrune.graphEngine.neighbors(of: h1)
        XCTAssertEqual(resetNeighbors.first?.consecutiveFailures, 0)

        for _ in 1...5 {
            do {
                _ = try await failEngine.execute(path: deadEdges, serial: "SER1")
                XCTFail("Expected stepTimeout")
            } catch PathDeviationError.stepTimeout {
                // expected
            }
        }
        let afterPrune = await bridgePrune.graphEngine.neighbors(of: h1)
        XCTAssertTrue(afterPrune.isEmpty, "Dead edge must be pruned at consecutiveFailures >= 5")
        let isAcyclic = await bridgePrune.graphEngine.isSpanningDAGAcyclic()
        XCTAssertTrue(isAcyclic)
    }

    func testScrollDirectEdgeBridgingAcrossMidScrollFramesAndLauncherWorkspaceFilter() async throws {
        // 1. largestScrollableRect ignores horizontal pagers & launcher home workspace
        let launcherIdx = ShadowTreeIndex(
            seq: 1,
            timestampMs: 1000,
            activePackage: "com.google.android.apps.nexuslauncher",
            activeWindowId: 1,
            nodes: [
                mkNode(id: 1, idx: 0, pkg: "com.google.android.apps.nexuslauncher", cls: "ScrollView", rid: "com.google.android.apps.nexuslauncher:id/workspace", bounds: "[0,0][1080,2424]", scrollable: true),
                mkNode(id: 2, idx: 1, pkg: "com.google.android.apps.nexuslauncher", cls: "ViewPager", rid: "com.google.android.apps.nexuslauncher:id/smartspace_card_pager", desc: "At a Glance", bounds: "[50,181][1030,432]", scrollable: true),
                mkNode(id: 3, idx: 2, pkg: "com.google.android.apps.nexuslauncher", cls: "HorizontalScrollView", rid: "com.google.android.apps.nexuslauncher:id/carousel", bounds: "[0,500][1080,800]", scrollable: true)
            ]
        )
        XCTAssertNil(
            MacroExecutionEngine.largestScrollableRect(in: launcherIdx, ignoredPackages: ["com.android.systemui"]),
            "Launcher workspace, ViewPager, and HorizontalScrollView must not be vertically scrolled"
        )

        // 2. Mid-scroll deceleration frames consuming pendingAction still bridge direct swipe edge for A*
        let bridge = ShadowGraphBridge()
        let topNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/list", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Brightness", bounds: "[80,300][600,400]", clickable: true)
        ]
        let midNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/list", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 3, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Lock screen", bounds: "[80,300][600,400]", clickable: true)
        ]
        let settledNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/list", bounds: "[0,200][1080,2000]", scrollable: true),
            mkNode(id: 4, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Night Light", bounds: "[80,900][600,1000]", clickable: true)
        ]
        let goalNodes = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Use Night Light", bounds: "[80,300][600,400]", clickable: true)
        ]
        let hTop = await seedScreenIntoGraph(bridge, seq: 1, pkg: "com.android.settings", nodes: topNodes)
        actor LocalSeq {
            var v: UInt64 = 2
            func next() -> UInt64 { defer { v += 1 }; return v }
        }
        let seqBox = LocalSeq()
        let exec = ScriptedExecutor { [weak self] act in
            guard let self else { return }
            switch act.kind {
            case .swipe:
                try? await Task.sleep(for: .milliseconds(10))
                let s1 = await seqBox.next()
                _ = await self.seedScreenIntoGraph(bridge, seq: s1, pkg: "com.android.settings", nodes: midNodes)
                try? await Task.sleep(for: .milliseconds(25))
                let s2 = await seqBox.next()
                _ = await self.seedScreenIntoGraph(bridge, seq: s2, pkg: "com.android.settings", nodes: settledNodes)
            case .tap:
                try? await Task.sleep(for: .milliseconds(15))
                let s3 = await seqBox.next()
                _ = await self.seedScreenIntoGraph(bridge, seq: s3, pkg: "com.android.settings", nodes: goalNodes)
            default:
                break
            }
        }

        let outcome = try await bridge.exploreAndClick(
            target: "Night Light",
            serial: "SER1",
            executor: exec,
            maxScrolls: 2,
            stepTimeoutMs: 400,
            postSettleQuiescenceMs: 80,
            preferGraphRoute: false
        )
        guard case .exploredAndClicked(_, _, _, let hGoal, _, _, _, _) = outcome else {
            XCTFail("Expected exploredAndClicked, got \(outcome)")
            return
        }
        let snap = await bridge.graphEngine.snapshot()
        let pf = AStarPathfinder()
        let route = pf.findShortestPath(from: hTop, toAnyOf: [hGoal], in: snap)
        XCTAssertNotNil(route, "A* must find continuous executable route across bridged scroll edge")
        XCTAssertEqual(route?.edges.count, 2)
        XCTAssertTrue(route?.edges.allSatisfy { $0.action != nil } ?? false)
    }

    func testClippedScrollChildSkippedUntilScrolledAndCompactedNoopTapReportsUnchanged() async throws {
        // 1. A RecyclerView child peeking behind Android's bottom gesture bar (`centerY = 2418`
        //    when RecyclerView `maxY = 2361`) must be skipped so exploreAndClick scrolls once more
        //    instead of tapping the gesture bar. Non-scroll-child bottom dock buttons stay tappable.
        let ignored: Set<String> = ["com.android.systemui"]
        let clippedNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/recycler_view", bounds: "[0,299][1080,2361]", scrollable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "LinearLayout", bounds: "[0,2370][1080,2466]", clickable: true),
            mkNode(id: 3, parentId: 2, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Developer options", bounds: "[221,2390][593,2446]"),
            mkNode(id: 4, idx: 3, pkg: "com.android.settings", cls: "Button", rid: "com.android.settings:id/dock_btn", text: "Bottom Dock", bounds: "[400,2365][680,2415]", clickable: true)
        ]
        let clippedIdx = ShadowTreeIndex(seq: 1, timestampMs: 1000, activePackage: "com.android.settings", activeWindowId: 1, nodes: clippedNodes)
        XCTAssertTrue(
            ShadowGraphBridge.scoreLiveCandidates(in: clippedIdx, query: "Developer options", ignoredPackages: ignored).isEmpty,
            "Clipped RecyclerView child at centerY=2418 (> maxY=2361) must be skipped"
        )
        XCTAssertEqual(
            ShadowGraphBridge.scoreLiveCandidates(in: clippedIdx, query: "Bottom Dock", ignoredPackages: ignored).count,
            1,
            "Non-scroll-child bottom dock button must remain tappable"
        )

        let bridge = ShadowGraphBridge()
        _ = await seedScreenIntoGraph(bridge, seq: 1, pkg: "com.android.settings", nodes: clippedNodes)

        let centeredNodes = [
            mkNode(id: 1, idx: 0, pkg: "com.android.settings", cls: "RecyclerView", rid: "com.android.settings:id/recycler_view", bounds: "[0,299][1080,2361]", scrollable: true),
            mkNode(id: 2, parentId: 1, idx: 1, pkg: "com.android.settings", cls: "LinearLayout", bounds: "[0,1660][1080,1800]", clickable: true),
            mkNode(id: 3, parentId: 2, idx: 2, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Developer options", bounds: "[221,1702][593,1755]")
        ]
        let devOptsNodes = [
            mkNode(id: 10, idx: 0, pkg: "com.android.settings", cls: "TextView", rid: "android:id/title", text: "Use developer options", bounds: "[80,300][700,420]", clickable: true)
        ]

        actor LocalSeq {
            var v: UInt64 = 2
            func next() -> UInt64 { defer { v += 1 }; return v }
        }
        let seqBox = LocalSeq()
        let exec = ScriptedExecutor { [weak self] act in
            guard let self else { return }
            switch act.kind {
            case .swipe:
                try? await Task.sleep(for: .milliseconds(10))
                let s = await seqBox.next()
                _ = await self.seedScreenIntoGraph(bridge, seq: s, pkg: "com.android.settings", nodes: centeredNodes)
            case .tap:
                XCTAssertLessThan(act.y ?? 9999, 2300, "Tap must wait until Developer options scrolls into viewport")
                try? await Task.sleep(for: .milliseconds(10))
                let s = await seqBox.next()
                _ = await self.seedScreenIntoGraph(bridge, seq: s, pkg: "com.android.settings", nodes: devOptsNodes)
            default:
                break
            }
        }

        let outcome = try await bridge.exploreAndClick(
            target: "Developer options",
            serial: "SER1",
            executor: exec,
            maxScrolls: 2,
            stepTimeoutMs: 400,
            postSettleQuiescenceMs: 40,
            preferGraphRoute: false
        )
        guard case .exploredAndClicked(let cand, let scrolls, _, _, _, let changed, let recorded, _) = outcome else {
            XCTFail("Expected exploredAndClicked, got \(outcome)")
            return
        }
        XCTAssertEqual(scrolls, 1)
        XCTAssertEqual(cand.centerY, 1728)
        XCTAssertTrue(changed)
        XCTAssertTrue(recorded)

        // 2. Compacted canonical vertex: a no-op tap must report screenChanged == false & edgeRecorded == false
        let bridge2 = ShadowGraphBridge()
        var baseNodes: [ShadowUINode] = (0..<12).map { i in
            mkNode(
                id: Int64(100 + i),
                idx: i,
                pkg: "com.example.app",
                cls: "TextView",
                rid: "com.example.app:id/item_\(i)",
                text: "StableRow\(i)",
                bounds: "[40,\(200 + i * 100)][800,\(280 + i * 100)]",
                clickable: true
            )
        }
        let hCanon = await seedScreenIntoGraph(bridge2, seq: 1, pkg: "com.example.app", nodes: baseNodes)
        baseNodes.append(
            mkNode(id: 200, idx: 12, pkg: "com.example.app", cls: "TextView", rid: "com.example.app:id/jitter", text: "TinyJitterBadge", bounds: "[820,200][1000,260]")
        )
        _ = await seedScreenIntoGraph(bridge2, seq: 2, pkg: "com.example.app", nodes: baseNodes)
        let curHash = await bridge2.graphEngine.currentStateHash
        XCTAssertEqual(curHash, hCanon, "Jittered frame must compact into canonical vertex")

        let noopExec = ScriptedExecutor { _ in }
        let noopOutcome = try await bridge2.exploreAndClick(
            target: "StableRow0",
            serial: "SER1",
            executor: noopExec,
            maxScrolls: 0,
            stepTimeoutMs: 120,
            postSettleQuiescenceMs: 0,
            preferGraphRoute: false
        )
        guard case .exploredAndClicked(_, _, let sHash, let fHash, _, let noopChanged, let noopRecorded, _) = noopOutcome else {
            XCTFail("Expected exploredAndClicked, got \(noopOutcome)")
            return
        }
        XCTAssertEqual(sHash, hCanon)
        XCTAssertEqual(fHash, hCanon)
        XCTAssertFalse(noopChanged, "No-op tap on compacted vertex must report screenChanged=false")
        XCTAssertFalse(noopRecorded, "No-op tap on compacted vertex must not record bogus edge")
    }
}
