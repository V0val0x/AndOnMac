import Foundation
import CryptoKit
import AndroidShadowGraphKit

/// Host coordinator wrapping `ShadowGraphBridge` for `AndOnMac` (GUI app + embedded MCP server).
public final class ShadowGraphManager: @unchecked Sendable {
    public static let shared = ShadowGraphManager()

    public static var defaultGraphStorageURL: URL {
        if let overridePath = ProcessInfo.processInfo.environment["ANDONMAC_GRAPH_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: false)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("AndOnMac", isDirectory: true)
            .appendingPathComponent("shadow_graph.json", isDirectory: false)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.processName == "xctest" ||
        NSClassFromString("XCTestCase") != nil
    }

    private actor LifecycleCoordinator {
        private var tailTask: Task<Void, Never>?
        private var tailToken: UInt64 = 0

        func runSerialized(_ operation: @Sendable @escaping () async -> Void) async {
            let previous = tailTask
            tailToken &+= 1
            let myToken = tailToken
            let current = Task {
                await previous?.value
                await operation()
            }
            tailTask = current
            await current.value
            if tailToken == myToken {
                tailTask = nil
            }
        }
    }

    private actor GraphPersistenceCoordinator {
        private let storageURL: URL?
        private let seedDefaultGraph: Bool
        private var initTask: Task<Void, Never>?
        private var isSaving = false
        private var needsAnotherSave = false
        private var activeSaveTask: Task<Void, Never>?
        private var lastSavedRevision: UInt64 = 0

        init(storageURL: URL?, seedDefaultGraph: Bool = false) {
            self.storageURL = storageURL
            self.seedDefaultGraph = seedDefaultGraph
        }

        func ensureInitialized(engine: SpatialGraphEngine) async {
            if let existing = initTask {
                await existing.value
                return
            }
            let task = Task {
                await self.performInitialization(engine: engine)
            }
            initTask = task
            await task.value
        }

        private func performInitialization(engine: SpatialGraphEngine) async {
            if let storageURL,
               FileManager.default.fileExists(atPath: storageURL.path),
               await engine.vertexCount == 0 {
                do {
                    let data = try Data(contentsOf: storageURL)
                    try await engine.importGraphJSON(data)
                    lastSavedRevision = await engine.topologyRevision
                } catch {
                    ShadowGraphManager.logStderr("Failed to load persisted shadow graph from \(storageURL.path): \(error.localizedDescription)")
                }
            }
            let envDisabled = ProcessInfo.processInfo.environment["ANDONMAC_DISABLE_SEED_GRAPH"] == "1"
            if seedDefaultGraph && !envDisabled {
                _ = await engine.mergeSeedGraph(SeedGraphCatalog.androidSettingsSeedGraph())
                // Do not bump lastSavedRevision / touch disk until real device activity mutates topology
                lastSavedRevision = await engine.topologyRevision
            }
            await engine.setOnTopologyChanged { [weak self] in
                await self?.scheduleSave(engine: engine)
            }
        }

        func scheduleSave(engine: SpatialGraphEngine) async {
            guard let storageURL else { return }
            await ensureInitialized(engine: engine)
            if isSaving {
                needsAnotherSave = true
                return
            }
            isSaving = true
            let task = Task {
                await self.runSaveLoop(engine: engine, storageURL: storageURL)
            }
            activeSaveTask = task
            await task.value
        }

        private func runSaveLoop(engine: SpatialGraphEngine, storageURL: URL) async {
            repeat {
                needsAnotherSave = false
                do {
                    let rev = await engine.topologyRevision
                    let data = try await engine.exportGraphJSON(prettyPrinted: true)
                    let dir = storageURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: storageURL, options: [.atomic])
                    lastSavedRevision = rev
                } catch {
                    ShadowGraphManager.logStderr("Failed to save shadow graph to \(storageURL.path): \(error.localizedDescription)")
                }
            } while needsAnotherSave
            isSaving = false
            activeSaveTask = nil
        }

        func flush(engine: SpatialGraphEngine) async {
            await ensureInitialized(engine: engine)
            if let activeSaveTask {
                await activeSaveTask.value
            }
            guard storageURL != nil else { return }
            let currentRev = await engine.topologyRevision
            if currentRev > lastSavedRevision {
                await scheduleSave(engine: engine)
            }
        }
    }

    public let bridge: ShadowGraphBridge
    private let portForwarder: (@Sendable (String?, UInt16) async -> Void)?
    private let daemonLauncher: (@Sendable (String, UInt16) async throws -> Void)?
    private let persistence: GraphPersistenceCoordinator
    private let lifecycle = LifecycleCoordinator()
    private let lock = NSLock()
    private var activeSerial: String?
    private var hasStarted = false

    private convenience init() {
        let storageURL: URL? = Self.isRunningTests ? nil : Self.defaultGraphStorageURL
        self.init(
            bridge: ShadowGraphBridge(),
            portForwarder: nil,
            daemonLauncher: nil,
            graphStorageURL: storageURL,
            seedDefaultGraph: !Self.isRunningTests
        )
    }

    internal init(
        bridge: ShadowGraphBridge = ShadowGraphBridge(),
        portForwarder: (@Sendable (String?, UInt16) async -> Void)? = nil,
        daemonLauncher: (@Sendable (String, UInt16) async throws -> Void)? = nil,
        graphStorageURL: URL? = nil,
        seedDefaultGraph: Bool = false
    ) {
        self.bridge = bridge
        self.portForwarder = portForwarder
        self.daemonLauncher = daemonLauncher
        self.persistence = GraphPersistenceCoordinator(
            storageURL: graphStorageURL,
            seedDefaultGraph: seedDefaultGraph
        )

        bridge.setDaemonRecoveryHook { [weak self] serial, port in
            guard let self else { return false }
            return await self.recoverDaemonAndAwaitStream(serial: serial, port: port)
        }
        Task.detached(priority: .utility) { [weak self] in
            await self?.loadPersistedGraphIfNeeded()
        }
    }

    public func loadPersistedGraphIfNeeded() async {
        await persistence.ensureInitialized(engine: bridge.graphEngine)
    }

    public func flushPersistedGraph() async {
        await persistence.flush(engine: bridge.graphEngine)
    }

    /// Updates the target device serial used for `adb forward` recovery and starts the bridge if not yet running.
    public func ensureStarted(serial: String? = nil) async {
        await ensureStarted(serial: serial, forceReconnectIfWaiting: false)
    }

    public func ensureStarted(
        serial: String?,
        forceReconnectIfWaiting: Bool
    ) async {
        await loadPersistedGraphIfNeeded()
        await lifecycle.runSerialized {
            let validSerial = (serial?.isEmpty == false && ADBService.validateSerial(serial!)) ? serial : nil
            let (shouldConfigureAndStart, serialChanged, acquiredInitialSerial): (Bool, Bool, Bool) = self.lock.withLock {
                let prevSerial = self.activeSerial
                if let validSerial {
                    self.activeSerial = validSerial
                }
                if !self.hasStarted {
                    self.hasStarted = true
                    return (true, false, false)
                }
                let changed = (validSerial != nil && prevSerial != nil && prevSerial != validSerial)
                let acquired = (validSerial != nil && prevSerial == nil)
                return (false, changed, acquired)
            }

            if shouldConfigureAndStart {
                let port = self.bridge.client.configuration.port
                await self.bridge.setBeforeReconnectHook { [weak self] _ in
                    await self?.forwardDaemonPort(port: port)
                }
                await self.forwardDaemonPort(port: port)
                await self.bridge.start()
            } else {
                let state = await self.bridge.client.state
                switch state {
                case .stopped, .disconnected:
                    let port = self.bridge.client.configuration.port
                    await self.forwardDaemonPort(port: port)
                    await self.bridge.start()
                case .waitingToReconnect:
                    if serialChanged || acquiredInitialSerial || forceReconnectIfWaiting {
                        await self.bridge.reconnect()
                    }
                case .connecting, .connected:
                    if serialChanged || (acquiredInitialSerial && !state.isConnected) {
                        await self.bridge.reconnect()
                    }
                }
            }
        }
    }

    private func forwardDaemonPort(port: UInt16, explicitSerial: String? = nil) async {
        let targetSerial = explicitSerial ?? lock.withLock { activeSerial }
        if let portForwarder {
            await portForwarder(targetSerial, port)
            return
        }
        var args: [String] = []
        if let targetSerial, !targetSerial.isEmpty {
            args.append(contentsOf: ["-s", targetSerial])
        }
        args.append(contentsOf: ["forward", "tcp:\(port)", "tcp:\(port)"])
        _ = try? await ADBService.shared.execute(arguments: args, timeoutSeconds: 1.5)
    }

    public func stop() async {
        let pendingLiveIndex: ShadowTreeIndex? = if await bridge.domState.hasSessionSnapshot {
            await bridge.domState.currentIndex
        } else {
            nil
        }
        await lifecycle.runSerialized {
            self.lock.withLock {
                self.hasStarted = false
            }
            await self.bridge.stop()
        }
        if let pendingLiveIndex {
            let fp = bridge.hasher.fingerprint(for: pendingLiveIndex)
            let currentHash = await bridge.graphEngine.currentStateHash
            if currentHash != fp.layoutHash && (!fp.tokens.isEmpty || !pendingLiveIndex.orderedNodes.isEmpty) {
                await bridge.graphEngine.process(update: ShadowDOMUpdate(
                    index: pendingLiveIndex,
                    isFullSnapshot: true,
                    insertedCount: pendingLiveIndex.orderedNodes.count,
                    updatedCount: 0,
                    removedCount: 0
                ))
            }
        }
        await flushPersistedGraph()
    }

    public func fastCompactTreeIfFresh(
        maxWaitSeconds: TimeInterval = 0.25,
        maxAgeSeconds: TimeInterval = 15.0
    ) async -> [ShadowCompactNode]? {
        await bridge.fastCompactTreeIfFresh(
            maxWaitSeconds: maxWaitSeconds,
            maxAgeSeconds: maxAgeSeconds
        )
    }

    public func findNode(
        byText query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive,
        preferClickable: Bool = true
    ) async -> ShadowUINode? {
        guard await bridge.domState.isFresh(maxAgeSeconds: 15.0) else { return nil }
        return await bridge.findNode(byText: query, mode: mode, preferClickable: preferClickable)
    }

    public func findNode(
        byResourceID resourceId: String,
        mode: ShadowTreeMatchMode = .suffixOrExactResourceId
    ) async -> ShadowUINode? {
        guard await bridge.domState.isFresh(maxAgeSeconds: 15.0) else { return nil }
        return await bridge.findNode(byResourceID: resourceId, mode: mode)
    }

    public func findNode(
        byContentDesc query: String,
        mode: ShadowTreeMatchMode = .containsCaseInsensitive
    ) async -> ShadowUINode? {
        guard await bridge.domState.isFresh(maxAgeSeconds: 15.0) else { return nil }
        return await bridge.findNode(byContentDesc: query, mode: mode)
    }

    public var macroExecutionEvents: AsyncStream<MacroExecutionEvent> {
        bridge.macroExecutionEvents
    }

    public var secureScreenEvents: AsyncStream<WireSecureScreenPayload> {
        bridge.secureScreenEvents
    }

    public func recordAction(_ action: AttributedUIAction) async {
        await bridge.recordAction(action)
    }

    public func resolveTapActionSync(
        atX x: Int,
        y: Int,
        timestamp: Date = Date()
    ) -> AttributedUIAction {
        if let index = bridge.domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0) {
            return index.attributedTapAction(atX: x, y: y, timestamp: timestamp)
        }
        return AttributedUIAction(
            kind: .tap,
            targetDescription: "manual tap at (\(x),\(y))",
            x: x,
            y: y,
            timestamp: timestamp
        )
    }

    public func resolveTapAction(
        atX x: Int,
        y: Int,
        timestamp: Date = Date()
    ) async -> AttributedUIAction {
        if let index = bridge.domState.freshIndexSnapshotIfAvailable(maxAgeSeconds: 15.0) {
            return index.attributedTapAction(atX: x, y: y, timestamp: timestamp)
        }
        if await bridge.domState.isFresh(maxAgeSeconds: 15.0),
           let index = await bridge.domState.currentIndex {
            return index.attributedTapAction(atX: x, y: y, timestamp: timestamp)
        }
        return AttributedUIAction(
            kind: .tap,
            targetDescription: "manual tap at (\(x),\(y))",
            x: x,
            y: y,
            timestamp: timestamp
        )
    }

    public var currentActiveSerial: String? {
        lock.withLock { activeSerial }
    }

    public func actionExecutor() -> ADBMacroActionExecutor {
        ADBMacroActionExecutor(
            daemonClient: bridge.client,
            activeSerialProvider: { [weak self] in self?.currentActiveSerial }
        )
    }

    public func navigateToNode(
        serial: String,
        target: String?,
        targetHash: UInt64?,
        maxSteps: Int = 12,
        stepTimeoutMs: Int = 2000,
        confirmed: Bool = false,
        autoExplore: Bool = false,
        secureHandoffTimeoutSeconds: TimeInterval = 60.0,
        executor: MacroActionExecutor? = nil
    ) async throws -> ShadowNavigationOutcome {
        await loadPersistedGraphIfNeeded()
        await ensureStarted(serial: serial, forceReconnectIfWaiting: true)
        let activeExecutor = executor ?? actionExecutor()
        let outcome = try await bridge.routeAndExecute(
            targetHint: target,
            targetHash: targetHash,
            serial: serial,
            executor: activeExecutor,
            maxSteps: maxSteps,
            stepTimeoutMs: stepTimeoutMs,
            confirmed: confirmed,
            autoExplore: autoExplore,
            secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
        )
        switch outcome {
        case .arrived, .explored:
            await flushPersistedGraph()
        default:
            break
        }
        return outcome
    }

    public func exploreAndClick(
        serial: String,
        target: String,
        maxScrolls: Int = 3,
        stepTimeoutMs: Int = 2000,
        confirmed: Bool = false,
        preferGraphRoute: Bool = true,
        secureHandoffTimeoutSeconds: TimeInterval = 60.0,
        executor: MacroActionExecutor? = nil
    ) async throws -> ExploreOutcome {
        await loadPersistedGraphIfNeeded()
        await ensureStarted(serial: serial, forceReconnectIfWaiting: true)
        let activeExecutor = executor ?? actionExecutor()
        let outcome = try await bridge.exploreAndClick(
            target: target,
            serial: serial,
            executor: activeExecutor,
            maxScrolls: maxScrolls,
            stepTimeoutMs: stepTimeoutMs,
            confirmed: confirmed,
            preferGraphRoute: preferGraphRoute,
            secureHandoffTimeoutSeconds: secureHandoffTimeoutSeconds
        )
        switch outcome {
        case .exploredAndClicked, .arrivedViaGraph:
            await flushPersistedGraph()
        default:
            break
        }
        return outcome
    }

    // MARK: - Daemon Auto-Recovery

    internal func recoverDaemonAndAwaitStream(serial: String, port: UInt16) async -> Bool {
        guard ADBService.validateSerial(serial) else { return false }

        await ensureStarted(serial: serial, forceReconnectIfWaiting: false)

        if await bridge.ensureShadowStreamReady(maxWaitSeconds: 0.25, maxAgeSeconds: 15.0),
           await bridge.domState.currentIndex != nil {
            return true
        }

        do {
            if let daemonLauncher {
                try await daemonLauncher(serial, port)
            } else {
                try await Self.launchDaemonOnDevice(serial: serial, port: port)
            }
        } catch is CancellationError {
            return false
        } catch {
            Self.logStderr("Daemon auto-recovery launch failed for \(serial): \(error.localizedDescription)")
            return false
        }

        await forwardDaemonPort(port: port, explicitSerial: serial)
        if await bridge.client.state == .stopped {
            await bridge.start()
        } else {
            await bridge.reconnect()
        }

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if Task.isCancelled { return false }
            let state = await bridge.client.state
            if state == .stopped { return false }

            let slice = min(1.0, max(0.1, deadline.timeIntervalSinceNow))
            if await bridge.ensureShadowStreamReady(maxWaitSeconds: slice, maxAgeSeconds: 15.0),
               await bridge.domState.currentIndex != nil {
                return true
            }

            if Task.isCancelled { return false }
            let currentState = await bridge.client.state
            if case .waitingToReconnect = currentState {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return false }
                await forwardDaemonPort(port: port, explicitSerial: serial)
                await bridge.reconnect()
            } else if currentState == .disconnected {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return false }
                await forwardDaemonPort(port: port, explicitSerial: serial)
                await bridge.reconnect()
            }
        }

        let ready = await bridge.ensureShadowStreamReady(maxWaitSeconds: 0.1, maxAgeSeconds: 15.0)
        let hasIndex = await bridge.domState.currentIndex != nil
        return ready && hasIndex
    }

    public static func resolveDaemonJarPath() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/android-daemon.jar").path,
            Bundle.main.resourceURL?.appendingPathComponent("android-daemon.jar").path,
            Bundle.main.path(forResource: "android-daemon", ofType: "jar"),
            cwd + "/android-daemon/build/dist/android-daemon.jar",
            cwd + "/dist/AndOnMac.app/Contents/Resources/bin/android-daemon.jar",
            cwd + "/dist/AndOnMac.app/Contents/Resources/android-daemon.jar",
            "/Applications/AndOnMac.app/Contents/Resources/bin/android-daemon.jar",
            "/Applications/AndOnMac.app/Contents/Resources/android-daemon.jar"
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func launchDaemonOnDevice(serial: String, port: UInt16) async throws {
        let remoteJar = "/data/local/tmp/android-daemon.jar"
        let remoteLog = "/data/local/tmp/android-daemon.log"

        if let localJar = resolveDaemonJarPath() {
            let jarData = try Data(contentsOf: URL(fileURLWithPath: localJar))
            let localSha = SHA256.hash(data: jarData).map { String(format: "%02x", $0) }.joined()
            let remoteShaRaw = (try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "sha256sum '\(remoteJar)' 2>/dev/null || toybox sha256sum '\(remoteJar)' 2>/dev/null"],
                timeoutSeconds: 3.0
            )) ?? ""
            let remoteSha = remoteShaRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""

            if remoteSha != localSha {
                _ = try await ADBService.shared.execute(
                    arguments: ["-s", serial, "push", localJar, remoteJar],
                    timeoutSeconds: 12.0
                )
                _ = try? await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "chmod", "644", remoteJar],
                    timeoutSeconds: 3.0
                )
            }
        } else {
            let existsOut = (try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "test -f '\(remoteJar)' && echo OK"],
                timeoutSeconds: 3.0
            )) ?? ""
            guard existsOut.contains("OK") else {
                throw NSError(
                    domain: "ShadowGraphManager",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "android-daemon.jar not found locally or at \(remoteJar)."]
                )
            }
        }

        let killCmd = "pkill -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1 || true; i=0; while [ $i -lt 15 ]; do pgrep -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1 || break; sleep 0.05; i=$((i+1)); done; pkill -9 -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1 || true"
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", killCmd], timeoutSeconds: 4.0)

        let daemonCmd = "env CLASSPATH='\(remoteJar)' app_process / com.shadowgraph.daemon.DaemonMain --port=\(Int(port)) --debounce-ms=20 --max-depth=48 --heartbeat-ms=5000 --no-stdin-watchdog"
        let launchCmd = "rm -f '\(remoteLog)'; if command -v setsid >/dev/null 2>&1; then (setsid \(daemonCmd) </dev/null >'\(remoteLog)' 2>&1 &) </dev/null >/dev/null 2>&1; else (nohup \(daemonCmd) </dev/null >'\(remoteLog)' 2>&1 &) </dev/null >/dev/null 2>&1; fi"
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", launchCmd], timeoutSeconds: 4.0)

        let readyDeadline = Date().addingTimeInterval(4.0)
        var isReady = false
        while Date() < readyDeadline {
            try Task.checkCancellation()
            let checkCmd = "if grep -q 'SHADOWGRAPH_DAEMON_READY' '\(remoteLog)' 2>/dev/null; then echo READY; elif grep -q 'Fatal startup error' '\(remoteLog)' 2>/dev/null; then echo FAILED; fi"
            let out = (try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", checkCmd], timeoutSeconds: 2.0)) ?? ""
            if out.contains("READY") {
                isReady = true
                break
            }
            if out.contains("FAILED") {
                let errLog = (try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cat '\(remoteLog)' 2>/dev/null"], timeoutSeconds: 2.0)) ?? ""
                throw NSError(
                    domain: "ShadowGraphManager",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "android-daemon failed to start: \(errLog)"]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard isReady else {
            let tailLog = (try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cat '\(remoteLog)' 2>/dev/null"], timeoutSeconds: 2.0)) ?? ""
            let suffix = tailLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " Log: \(tailLog)"
            throw NSError(
                domain: "ShadowGraphManager",
                code: 504,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for SHADOWGRAPH_DAEMON_READY.\(suffix)"]
            )
        }
    }

    private static func logStderr(_ message: String) {
        if let data = "[ShadowGraphManager] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

public struct ADBMacroActionExecutor: MacroActionExecutor {
    public static let defaultDaemonSwipeDurationMs = 145
    public static let defaultZeroFlingHoldMs = 25

    private let daemonClient: DaemonTCPClient?
    private let activeSerialProvider: (@Sendable () -> String?)?

    public init(
        daemonClient: DaemonTCPClient? = nil,
        activeSerialProvider: (@Sendable () -> String?)? = nil
    ) {
        self.daemonClient = daemonClient
        self.activeSerialProvider = activeSerialProvider
    }

    private func daemonClientForSerial(_ serial: String) async -> DaemonTCPClient? {
        guard let daemonClient else { return nil }
        if let boundSerial = activeSerialProvider?(), !boundSerial.isEmpty, boundSerial != serial {
            return nil
        }
        return await daemonClient.supportsNativeInput ? daemonClient : nil
    }

    public func supportsZeroFlingSwipes(serial: String) async -> Bool {
        await daemonClientForSerial(serial) != nil
    }

    public func dispatchTap(serial: String, x: Int, y: Int) async throws {
        try Task.checkCancellation()
        if let client = await daemonClientForSerial(serial) {
            do {
                _ = try await client.injectTap(x: x, y: y)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to ADB on daemon error / disconnect / timeout
            }
        }
        try Task.checkCancellation()
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"],
            timeoutSeconds: 5.0
        )
    }

    public func dispatchSwipe(
        serial: String,
        x1: Int,
        y1: Int,
        x2: Int,
        y2: Int,
        durationMs: Int?,
        holdMs: Int = defaultZeroFlingHoldMs
    ) async throws {
        try Task.checkCancellation()
        if let client = await daemonClientForSerial(serial) {
            let daemonDur = max(20, min(5000, durationMs ?? Self.defaultDaemonSwipeDurationMs))
            let clampedHold = max(0, min(1000, holdMs))
            do {
                _ = try await client.injectSwipe(
                    x1: x1,
                    y1: y1,
                    x2: x2,
                    y2: y2,
                    durationMs: daemonDur,
                    holdMs: clampedHold
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to ADB on daemon error / disconnect / timeout
            }
        }
        try Task.checkCancellation()
        let duration = max(50, min(3000, durationMs ?? 300))
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)"],
            timeoutSeconds: 6.0
        )
    }

    public func dispatchKeyeventCode(serial: String, keyCode: String) async throws {
        try Task.checkCancellation()
        if let kcNum = Int(keyCode), let client = await daemonClientForSerial(serial) {
            do {
                _ = try await client.injectKeyevent(keycode: kcNum)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to ADB on daemon error / disconnect / timeout
            }
        }
        try Task.checkCancellation()
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "keyevent", keyCode],
            timeoutSeconds: 4.0
        )
    }

    public func execute(action: AttributedUIAction, serial: String) async throws {
        switch action.kind {
        case .tap:
            guard let x = action.x, let y = action.y else {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Missing tap coordinates (x, y)."
                )
            }
            try await dispatchTap(serial: serial, x: x, y: y)

        case .swipe:
            guard let x1 = action.x, let y1 = action.y, let x2 = action.endX, let y2 = action.endY else {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Missing swipe coordinates (x, y, endX, endY)."
                )
            }
            let isBannerDismiss = action.targetDescription.hasPrefix("Dismiss occluding notification")
            let holdMs = isBannerDismiss ? 0 : Self.defaultZeroFlingHoldMs
            let isRecordedScroll = action.targetDescription.hasPrefix("explore_scroll_")
                || action.targetDescription.hasPrefix("Smart scroll ")
            let daemonReady = await daemonClientForSerial(serial) != nil
            let effectiveDuration: Int?
            if daemonReady && isRecordedScroll {
                effectiveDuration = max(50, min(155, action.durationMs ?? Self.defaultDaemonSwipeDurationMs))
            } else {
                effectiveDuration = action.durationMs
            }
            try await dispatchSwipe(
                serial: serial,
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2,
                durationMs: effectiveDuration,
                holdMs: holdMs
            )

        case .keyevent:
            guard let keyCode = Self.resolveKeyCode(action.targetDescription) else {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Unsupported keyevent '\(action.targetDescription)'."
                )
            }
            try await dispatchKeyeventCode(serial: serial, keyCode: keyCode)

        case .typeText:
            let text = action.textInput ?? action.targetDescription
            guard !text.isEmpty else {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Missing textInput payload."
                )
            }
            let cmd = AndroidMCPTools.buildSafeTypeTextCommand(text)
            if !cmd.useClipboard {
                _ = try await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg],
                    timeoutSeconds: 6.0
                )
            } else {
                _ = try await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", "text", cmd.quotedArg],
                    timeoutSeconds: 4.0
                )
                try await dispatchKeyeventCode(serial: serial, keyCode: "279")
            }
            if action.pressEnter == true {
                try await dispatchKeyeventCode(serial: serial, keyCode: "66")
            }

        case .launchApp:
            let pkg = action.targetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ADBService.validatePackageName(pkg) else {
                throw PathDeviationError.actionDispatchFailed(
                    stepIndex: -1,
                    actionSignature: action.signature,
                    underlyingMessage: "Invalid package name '\(pkg)'."
                )
            }
            _ = try await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"],
                timeoutSeconds: 6.0
            )
        }
    }

    internal static func resolveKeyCode(_ raw: String) -> String? {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmed = upper.hasPrefix("KEYCODE_") ? String(upper.dropFirst("KEYCODE_".count)) : upper
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber) {
            return trimmed
        }
        let map: [String: String] = [
            "BACK": "4",
            "HOME": "3",
            "RECENTS": "187",
            "APP_SWITCH": "187",
            "ENTER": "66",
            "DELETE": "67",
            "VOLUME_UP": "24",
            "VOLUME_DOWN": "25",
            "WAKEUP": "224",
            "NOTIFICATION": "83",
            "PASTE": "279"
        ]
        return map[trimmed]
    }
}
