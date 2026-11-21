import XCTest
@testable import AndroidShadowGraphKit

final class SeedGraphHydrationTests: XCTestCase {

    private func makeNode(
        id: Int64,
        pkg: String,
        className: String,
        resId: String,
        text: String,
        cx: Int,
        cy: Int,
        clickable: Bool,
        scrollable: Bool
    ) -> ShadowUINode {
        let bounds = scrollable
            ? "[0,180][1080,2200]"
            : "[\(max(0, cx - 200)),\(max(0, cy - 50))][\(cx + 200),\(cy + 50)]"
        return ShadowUINode(
            index: Int(id),
            text: text,
            resourceId: resId,
            contentDesc: "",
            className: className,
            clickable: clickable,
            scrollable: scrollable,
            bounds: bounds,
            centerX: cx,
            centerY: cy,
            nodeId: id,
            parentId: nil,
            windowId: 1,
            childIndex: Int(id),
            depth: 1,
            packageName: pkg,
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
    }

    private func feedScreen(
        bridge: ShadowGraphBridge,
        seq: UInt64,
        pkg: String,
        nodes: [ShadowUINode]
    ) async {
        await bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: seq,
            timestampMs: Int64(seq) * 1000,
            reason: "test",
            activePackage: pkg,
            activeWindowId: 1,
            nodeCount: nodes.count,
            nodes: nodes,
            secureScreenActive: false
        )))
    }

    private final class SeqCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64
        init(_ initial: UInt64 = 10) { self.value = initial }
        func next() -> UInt64 {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    private final class ScriptedExecutor: MacroActionExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var _recorded: [AttributedUIAction] = []
        private let onAction: @Sendable (AttributedUIAction) async -> Void

        var recorded: [AttributedUIAction] {
            lock.withLock { _recorded }
        }

        init(onAction: @escaping @Sendable (AttributedUIAction) async -> Void) {
            self.onAction = onAction
        }

        func execute(action: AttributedUIAction, serial: String) async throws {
            if action.kind == .tap && (action.x == nil || action.y == nil) {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Missing tap coordinates (x, y)."
                )
            }
            lock.withLock { _recorded.append(action) }
            await onAction(action)
        }
    }

    func testSeedGraphZeroPIINonHazardousDeterministicAndDisjointMatching() throws {
        let seed = SeedGraphCatalog.androidSettingsSeedGraph()
        let seed2 = SeedGraphCatalog.androidSettingsSeedGraph()
        XCTAssertEqual(seed, seed2)
        XCTAssertEqual(seed.vertices.count, 20)
        XCTAssertEqual(seed.edges.count, 19)

        let uniqueHashes = Set(seed.vertices.map(\.layoutHash))
        XCTAssertEqual(uniqueHashes.count, seed.vertices.count)
        let uniqueEdgeIds = Set(seed.edges.map(\.id))
        XCTAssertEqual(uniqueEdgeIds.count, seed.edges.count)

        for v in seed.vertices {
            XCTAssertTrue(v.isSeed)
            XCTAssertEqual(v.visitCount, 0)
            XCTAssertEqual(v.activePackage, SeedGraphCatalog.androidSettingsPackage)
            XCTAssertFalse(v.semanticAliases.isEmpty)
            for label in v.sampleInteractiveLabels {
                XCTAssertEqual(ScreenLayoutHasher.redactPII(label), label)
            }
            for alias in v.semanticAliases {
                XCTAssertEqual(ScreenLayoutHasher.redactPII(alias), alias)
            }
        }

        for e in seed.edges {
            XCTAssertTrue(e.isSeed)
            XCTAssertFalse(e.isHazardous)
            XCTAssertEqual(e.traversalCount, 0)
            let act = try XCTUnwrap(e.action)
            XCTAssertNil(act.x)
            XCTAssertNil(act.y)
            XCTAssertEqual(act.kind, .tap)
        }

        // Pairwise 20x20 disjointness check: every seed screen matches itself >= 0.60 and
        // never falsely matches any other seed screen >= 0.60.
        for a in seed.vertices {
            let syntheticFp = ScreenSemanticFingerprint(
                layoutHash: a.layoutHash ^ 0xDEAD_BEEF,
                activePackage: a.activePackage,
                activeWindowId: 1,
                tokens: a.semanticTokens,
                sampleInteractiveLabels: a.sampleInteractiveLabels
            )
            let selfScore = SeedGraphCatalog.seedMatchScore(liveFingerprint: syntheticFp, seedVertex: a)
            XCTAssertGreaterThanOrEqual(
                selfScore,
                SeedGraphCatalog.seedMatchThreshold,
                "Seed '\(a.sampleInteractiveLabels.first ?? "")' should match itself"
            )
            for b in seed.vertices where b.layoutHash != a.layoutHash {
                let crossScore = SeedGraphCatalog.seedMatchScore(liveFingerprint: syntheticFp, seedVertex: b)
                XCTAssertLessThan(
                    crossScore,
                    SeedGraphCatalog.seedMatchThreshold,
                    "Cross-screen false positive: '\(a.sampleInteractiveLabels.first ?? "")' matched '\(b.sampleInteractiveLabels.first ?? "")' with score \(crossScore)"
                )
            }
        }

        // Bit-exact cross-language parity with Rust droidpath_core::SeedGraphCatalog
        let rootV = try XCTUnwrap(seed.vertices.first)
        let displayV = try XCTUnwrap(seed.vertices.first(where: { $0.sampleInteractiveLabels.first == "Display & touch" }))
        let nightLightV = try XCTUnwrap(seed.vertices.first(where: { $0.sampleInteractiveLabels.first == "Night Light" }))
        let devOptsV = try XCTUnwrap(seed.vertices.first(where: { $0.sampleInteractiveLabels.first == "Developer options" }))
        XCTAssertEqual(rootV.layoutHash, 17_917_625_146_408_918_530)
        XCTAssertEqual(displayV.layoutHash, 15_415_259_099_667_022_780)
        XCTAssertEqual(nightLightV.layoutHash, 10_514_516_610_508_614_137)
        XCTAssertEqual(devOptsV.layoutHash, 8_013_951_080_013_285_371)

        // JSON roundtrip preserves isSeed, semanticAliases, selectorAliases
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(seed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SpatialGraphSnapshot.self, from: data)
        XCTAssertEqual(decoded.vertices.count, 20)
        XCTAssertEqual(decoded.edges.count, 19)
        XCTAssertTrue(decoded.vertices.allSatisfy(\.isSeed))
        XCTAssertTrue(decoded.edges.allSatisfy(\.isSeed))
    }

    func testSeedGraphCrossOEMAndMultilingualHydrationAndRealReuse() async throws {
        let bridge = ShadowGraphBridge()
        let report = await bridge.graphEngine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())
        XCTAssertEqual(report.verticesAdded, 20)
        XCTAssertEqual(report.edgesAdded, 19)

        // Idempotent second merge adds nothing
        let report2 = await bridge.graphEngine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())
        XCTAssertEqual(report2.verticesAdded, 0)
        XCTAssertEqual(report2.edgesAdded, 0)

        let ruRootNodes = [
            makeNode(id: 1, pkg: "com.android.settings", className: "TextView", resId: "", text: "Настройки", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 2, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Сеть и интернет", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 3, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Приложения", cx: 540, cy: 620, clickable: true, scrollable: false),
            makeNode(id: 4, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Батарея", cx: 540, cy: 840, clickable: true, scrollable: false),
            makeNode(id: 5, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Экран", cx: 540, cy: 1120, clickable: true, scrollable: false),
            makeNode(id: 6, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Звук и вибрация", cx: 540, cy: 1340, clickable: true, scrollable: false),
        ]

        let ruDisplayNodes = [
            makeNode(id: 10, pkg: "com.android.settings", className: "TextView", resId: "", text: "Экран", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 11, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Яркость", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 12, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Тёмная тема", cx: 540, cy: 640, clickable: true, scrollable: false),
            makeNode(id: 13, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Ночная подсветка", cx: 540, cy: 880, clickable: true, scrollable: false),
        ]

        let ruNightLightNodes = [
            makeNode(id: 20, pkg: "com.android.settings", className: "TextView", resId: "", text: "Ночная подсветка", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 21, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Включить ночную подсветку", cx: 540, cy: 420, clickable: true, scrollable: false),
            makeNode(id: 22, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Расписание", cx: 540, cy: 660, clickable: true, scrollable: false),
            makeNode(id: 23, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Интенсивность", cx: 540, cy: 900, clickable: true, scrollable: false),
        ]

        await feedScreen(bridge: bridge, seq: 1, pkg: "com.android.settings", nodes: ruRootNodes)

        let seq = SeqCounter(10)

        let executor = ScriptedExecutor { act in
            if act.y == 1120 {
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: ruDisplayNodes)
            } else if act.y == 880 {
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: ruNightLightNodes)
            }
        }

        // Run 1: English query "Night Light" on a brand-new Russian device via Seed Graph!
        let outcome1 = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "TEST_SERIAL",
            executor: executor,
            maxSteps: 6,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )

        guard case .arrived(let report1) = outcome1 else {
            return XCTFail("Expected .arrived on Run 1, got \(outcome1)")
        }
        XCTAssertEqual(report1.steps.count, 2)
        XCTAssertTrue(report1.recoveredSteps.contains(where: { $0.hasPrefix("seed_hydrated:") }))

        // Verify Seed-to-Real hydration: 3 hydrated real vertices, 17 remaining seed vertices, real calibrated edges
        let hydratedCount = await bridge.graphEngine.hydratedVertexCount
        let seedCount = await bridge.graphEngine.seedVertexCount
        XCTAssertEqual(hydratedCount, 3)
        XCTAssertEqual(seedCount, 17)
        let isAcyclic = await bridge.graphEngine.isSpanningDAGAcyclic()
        XCTAssertTrue(isAcyclic)

        // Run 2: Return to Russian Settings root and navigate again -> must take hydrated real edges with exact coordinates!
        await feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: ruRootNodes)
        let outcome2 = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "TEST_SERIAL",
            executor: executor,
            maxSteps: 6,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let report2) = outcome2 else {
            return XCTFail("Expected .arrived on Run 2, got \(outcome2)")
        }
        XCTAssertEqual(report2.steps.count, 2)
        XCTAssertFalse(
            report2.recoveredSteps.contains(where: { $0.hasPrefix("seed_hydrated:") }),
            "Second run must use already-hydrated real edges, got: \(report2.recoveredSteps)"
        )
    }

    func testSeedGraphCrossPackageLaunchAppFromHomeWithSmartScrollAndHydration() async throws {
        let bridge = ShadowGraphBridge()
        await bridge.graphEngine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())

        let homeNodes = [
            makeNode(id: 1, pkg: "com.google.android.apps.nexuslauncher", className: "TextView", resId: "workspace", text: "Home", cx: 540, cy: 300, clickable: false, scrollable: false),
            makeNode(id: 2, pkg: "com.google.android.apps.nexuslauncher", className: "TextView", resId: "icon", text: "Settings", cx: 200, cy: 900, clickable: true, scrollable: false),
            makeNode(id: 3, pkg: "com.google.android.apps.nexuslauncher", className: "TextView", resId: "icon", text: "Chrome", cx: 540, cy: 900, clickable: true, scrollable: false),
            makeNode(id: 4, pkg: "com.google.android.apps.nexuslauncher", className: "TextView", resId: "icon", text: "Camera", cx: 880, cy: 900, clickable: true, scrollable: false),
        ]

        // Settings root top viewport (System is off-screen below -> triggers smartScrollToSelector!)
        let settingsTopNodes = [
            makeNode(id: 100, pkg: "com.android.settings", className: "RecyclerView", resId: "android:id/list", text: "", cx: 540, cy: 1100, clickable: false, scrollable: true),
            makeNode(id: 101, pkg: "com.android.settings", className: "TextView", resId: "", text: "Settings", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 102, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Network & internet", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 103, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Connected devices", cx: 540, cy: 640, clickable: true, scrollable: false),
            makeNode(id: 104, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Apps", cx: 540, cy: 880, clickable: true, scrollable: false),
            makeNode(id: 105, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Battery", cx: 540, cy: 1120, clickable: true, scrollable: false),
        ]

        let settingsBottomNodes = [
            makeNode(id: 110, pkg: "com.android.settings", className: "RecyclerView", resId: "android:id/list", text: "", cx: 540, cy: 1100, clickable: false, scrollable: true),
            makeNode(id: 111, pkg: "com.android.settings", className: "TextView", resId: "", text: "Settings", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 112, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Location", cx: 540, cy: 500, clickable: true, scrollable: false),
            makeNode(id: 113, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Accessibility", cx: 540, cy: 760, clickable: true, scrollable: false),
            makeNode(id: 114, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "System", cx: 540, cy: 1020, clickable: true, scrollable: false),
            makeNode(id: 115, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "About phone", cx: 540, cy: 1280, clickable: true, scrollable: false),
        ]

        let systemNodes = [
            makeNode(id: 120, pkg: "com.android.settings", className: "TextView", resId: "", text: "System", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 121, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Languages", cx: 540, cy: 420, clickable: true, scrollable: false),
            makeNode(id: 122, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Date & time", cx: 540, cy: 720, clickable: true, scrollable: false),
            makeNode(id: 123, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Developer options", cx: 540, cy: 1060, clickable: true, scrollable: false),
        ]

        let devOptionsNodes = [
            makeNode(id: 130, pkg: "com.android.settings", className: "TextView", resId: "", text: "Developer options", cx: 200, cy: 140, clickable: false, scrollable: false),
            makeNode(id: 131, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Use developer options", cx: 540, cy: 420, clickable: true, scrollable: false),
            makeNode(id: 132, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "USB debugging", cx: 540, cy: 720, clickable: true, scrollable: false),
            makeNode(id: 133, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Wireless debugging", cx: 540, cy: 1020, clickable: true, scrollable: false),
        ]

        await feedScreen(bridge: bridge, seq: 1, pkg: "com.google.android.apps.nexuslauncher", nodes: homeNodes)

        let seq = SeqCounter(10)

        let executor = ScriptedExecutor { act in
            switch act.kind {
            case .launchApp where act.targetDescription == "com.android.settings":
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: settingsTopNodes)
            case .swipe:
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: settingsBottomNodes)
            case .tap where act.y == 1020:
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: systemNodes)
            case .tap where act.y == 1060:
                await self.feedScreen(bridge: bridge, seq: seq.next(), pkg: "com.android.settings", nodes: devOptionsNodes)
            default:
                break
            }
        }

        let outcome = try await bridge.routeAndExecute(
            targetHint: "Developer options",
            serial: "TEST_SERIAL",
            executor: executor,
            maxSteps: 6,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )

        guard case .arrived(let report) = outcome else {
            return XCTFail("Expected .arrived from Home -> Developer options, got \(outcome)")
        }
        XCTAssertEqual(report.steps.count, 3)
        XCTAssertTrue(report.recoveredSteps.contains(where: { $0.hasPrefix("smart_scroll_to_selector:") }))
        XCTAssertTrue(report.recoveredSteps.contains(where: { $0.hasPrefix("seed_hydrated:") }))
        XCTAssertEqual(executor.recorded.first?.kind, .launchApp)
        XCTAssertEqual(executor.recorded.first?.targetDescription, "com.android.settings")
    }

    func testLivePumpHydrationZeroDuplicatesPostHydrationChromeEntryAndSmartScrollRun2() async throws {
        // 1. Live graphEngine.process() race during Russian Seed-to-Real hydration:
        //    MUST NOT create duplicate real edges or double-count visitCount/traversalCount!
        let bridge = ShadowGraphBridge()
        await bridge.graphEngine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())

        let ruRoot = [
            makeNode(id: 1, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/s", text: "Поиск настроек", cx: 540, cy: 200, clickable: true, scrollable: false),
            makeNode(id: 2, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/n", text: "Сеть и интернет", cx: 540, cy: 420, clickable: true, scrollable: false),
            makeNode(id: 3, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/a", text: "Приложения", cx: 540, cy: 640, clickable: true, scrollable: false),
            makeNode(id: 4, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/d", text: "Экран", cx: 540, cy: 1120, clickable: true, scrollable: false),
        ]
        let ruDisp = [
            makeNode(id: 10, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/t", text: "Экран", cx: 240, cy: 180, clickable: false, scrollable: false),
            makeNode(id: 11, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/b", text: "Яркость", cx: 540, cy: 440, clickable: true, scrollable: false),
            makeNode(id: 12, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/nl", text: "Ночная подсветка", cx: 540, cy: 880, clickable: true, scrollable: false),
        ]
        let ruNightLight = [
            makeNode(id: 20, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/t", text: "Ночная подсветка", cx: 240, cy: 180, clickable: false, scrollable: false),
            makeNode(id: 21, pkg: "com.android.settings", className: "Switch", resId: "com.oem:id/sw", text: "Включить ночную подсветку", cx: 540, cy: 440, clickable: true, scrollable: false),
            makeNode(id: 22, pkg: "com.android.settings", className: "TextView", resId: "com.oem:id/sc", text: "Расписание", cx: 540, cy: 680, clickable: true, scrollable: false),
        ]

        let feedWithLivePump: @Sendable (ShadowGraphBridge, UInt64, String, [ShadowUINode]) async -> Void = { b, seqVal, pkg, nodes in
            await b.domState.handleMessage(.snapshot(WireSnapshotPayload(
                seq: seqVal,
                timestampMs: Int64(seqVal) * 1000,
                reason: "test",
                activePackage: pkg,
                activeWindowId: 1,
                nodeCount: nodes.count,
                nodes: nodes,
                secureScreenActive: false
            )))
            if let idx = await b.domState.currentIndex {
                await b.graphEngine.process(update: ShadowDOMUpdate(
                    index: idx,
                    isFullSnapshot: true,
                    insertedCount: nodes.count,
                    updatedCount: 0,
                    removedCount: 0
                ))
            }
        }

        await feedWithLivePump(bridge, 1, "com.android.settings", ruRoot)
        let rootIdxOpt = await bridge.domState.currentIndex
        let rootIdx = try XCTUnwrap(rootIdxOpt)
        let realRootHash = bridge.hasher.fingerprint(for: rootIdx).layoutHash

        let seq = SeqCounter(10)
        let exec = ScriptedExecutor { act in
            if act.kind == .launchApp && act.targetDescription == "com.android.settings" {
                await feedWithLivePump(bridge, seq.next(), "com.android.settings", ruRoot)
            } else if act.y == 1120 {
                await feedWithLivePump(bridge, seq.next(), "com.android.settings", ruDisp)
            } else if act.y == 880 {
                await feedWithLivePump(bridge, seq.next(), "com.android.settings", ruNightLight)
            }
        }

        let outcome = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "TEST_SERIAL",
            executor: exec,
            maxSteps: 6,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived = outcome else {
            return XCTFail("Expected .arrived on live pump Russian hydration, got \(outcome)")
        }

        let snap = await bridge.graphEngine.snapshot()
        let dispVertex = try XCTUnwrap(snap.vertices.first(where: { !$0.isSeed && $0.sampleInteractiveLabels.contains("Яркость") }))
        let edgesToDisp = await bridge.graphEngine.neighbors(of: realRootHash).filter { $0.toHash == dispVertex.layoutHash }
        XCTAssertEqual(edgesToDisp.count, 1, "Live pump + hydrateSeedTransition must not duplicate edges: \(edgesToDisp)")
        XCTAssertFalse(edgesToDisp[0].isSeed)
        XCTAssertEqual(edgesToDisp[0].traversalCount, 1)
        XCTAssertEqual(edgesToDisp[0].action?.selectorText, "Экран")
        XCTAssertEqual(dispVertex.visitCount, 1, "Must not double-count visitCount during live hydration")

        // 2. Post-hydration cross-app entry from Chrome -> ALREADY HYDRATED Night Light
        let chromeNodes = [
            makeNode(id: 99, pkg: "com.android.chrome", className: "EditText", resId: "com.android.chrome:id/url_bar", text: "example.com", cx: 540, cy: 140, clickable: true, scrollable: false),
        ]
        await feedWithLivePump(bridge, seq.next(), "com.android.chrome", chromeNodes)
        let fromChrome = try await bridge.routeAndExecute(
            targetHint: "Night Light",
            serial: "TEST_SERIAL",
            executor: exec,
            maxSteps: 6,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived(let chromeReport) = fromChrome else {
            return XCTFail("Expected .arrived from Chrome to already-hydrated Night Light, got \(fromChrome)")
        }
        XCTAssertEqual(chromeReport.steps.count, 3)

        // 3. Smart-scroll 3x down on Run 1 + Run 2 keeps hydrated edge coordinate-free and re-scrolls 3x cleanly!
        let bridge2 = ShadowGraphBridge()
        await bridge2.graphEngine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())

        let p0 = [
            makeNode(id: 10, pkg: "com.android.settings", className: "RecyclerView", resId: "rv", text: "", cx: 540, cy: 1200, clickable: false, scrollable: true),
            makeNode(id: 11, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Search settings", cx: 540, cy: 260, clickable: true, scrollable: false),
            makeNode(id: 12, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Network & internet", cx: 540, cy: 500, clickable: true, scrollable: false),
            makeNode(id: 13, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Connected devices", cx: 540, cy: 740, clickable: true, scrollable: false),
            makeNode(id: 14, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Apps", cx: 540, cy: 1020, clickable: true, scrollable: false),
        ]
        let p1 = [
            makeNode(id: 20, pkg: "com.android.settings", className: "RecyclerView", resId: "rv", text: "", cx: 540, cy: 1200, clickable: false, scrollable: true),
            makeNode(id: 21, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Notifications", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 22, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Battery", cx: 540, cy: 700, clickable: true, scrollable: false),
            makeNode(id: 23, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Storage", cx: 540, cy: 1020, clickable: true, scrollable: false),
        ]
        let p2 = [
            makeNode(id: 30, pkg: "com.android.settings", className: "RecyclerView", resId: "rv", text: "", cx: 540, cy: 1200, clickable: false, scrollable: true),
            makeNode(id: 31, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Sound & vibration", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 32, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Display & touch", cx: 540, cy: 700, clickable: true, scrollable: false),
            makeNode(id: 33, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Security & privacy", cx: 540, cy: 1020, clickable: true, scrollable: false),
        ]
        let p3 = [
            makeNode(id: 40, pkg: "com.android.settings", className: "RecyclerView", resId: "rv", text: "", cx: 540, cy: 1200, clickable: false, scrollable: true),
            makeNode(id: 41, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Location", cx: 540, cy: 400, clickable: true, scrollable: false),
            makeNode(id: 42, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Accessibility", cx: 540, cy: 700, clickable: true, scrollable: false),
            makeNode(id: 43, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "System", cx: 540, cy: 1020, clickable: true, scrollable: false),
        ]
        let sysNodes = [
            makeNode(id: 50, pkg: "com.android.settings", className: "TextView", resId: "", text: "System", cx: 240, cy: 180, clickable: false, scrollable: false),
            makeNode(id: 51, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Languages", cx: 540, cy: 480, clickable: true, scrollable: false),
            makeNode(id: 52, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Date & time", cx: 540, cy: 720, clickable: true, scrollable: false),
            makeNode(id: 53, pkg: "com.android.settings", className: "TextView", resId: "android:id/title", text: "Developer options", cx: 540, cy: 1060, clickable: true, scrollable: false),
        ]
        let pages = [p0, p1, p2, p3]
        final class PageTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func reset() { lock.withLock { value = 0 } }
            func incAndGet() -> Int { lock.withLock { value += 1; return value } }
            func get() -> Int { lock.withLock { value } }
        }
        let pageTracker = PageTracker()
        let seq2 = SeqCounter(10)
        let exec2 = ScriptedExecutor { act in
            if act.kind == .swipe {
                let idx = min(pageTracker.incAndGet(), pages.count - 1)
                await self.feedScreen(bridge: bridge2, seq: seq2.next(), pkg: "com.android.settings", nodes: pages[idx])
            } else if act.kind == .tap && act.y == 1020 && pageTracker.get() == 3 {
                await self.feedScreen(bridge: bridge2, seq: seq2.next(), pkg: "com.android.settings", nodes: sysNodes)
            }
        }

        await feedScreen(bridge: bridge2, seq: 1, pkg: "com.android.settings", nodes: p0)
        let p0IdxOpt = await bridge2.domState.currentIndex
        let p0Hash = bridge2.hasher.fingerprint(for: try XCTUnwrap(p0IdxOpt)).layoutHash
        let run1 = try await bridge2.routeAndExecute(
            targetHint: "System",
            serial: "TEST_SERIAL",
            executor: exec2,
            maxSteps: 4,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived = run1 else {
            return XCTFail("Expected .arrived on Run 1 with 3 scrolls down, got \(run1)")
        }

        let p0Neighbors = await bridge2.graphEngine.neighbors(of: p0Hash)
        let hydratedSysEdge = try XCTUnwrap(p0Neighbors.first(where: { !$0.isSeed }))
        XCTAssertNil(hydratedSysEdge.action?.x, "Smart-scrolled hydrated edge must remain coordinate-free")
        XCTAssertNil(hydratedSysEdge.action?.y, "Smart-scrolled hydrated edge must remain coordinate-free")

        // Run 2 on hydrated real edge must still scroll 3x down and succeed!
        pageTracker.reset()
        await feedScreen(bridge: bridge2, seq: seq2.next(), pkg: "com.android.settings", nodes: p0)
        let run2 = try await bridge2.routeAndExecute(
            targetHint: "System",
            serial: "TEST_SERIAL",
            executor: exec2,
            maxSteps: 4,
            stepTimeoutMs: 1500,
            postSettleQuiescenceMs: 0
        )
        guard case .arrived = run2 else {
            return XCTFail("Expected .arrived on Run 2 on hydrated smart-scrolled edge, got \(run2)")
        }
    }
}
