import Foundation
import SwiftUI
import Combine
import UserNotifications
import AndroidShadowGraphKit

public enum SideDrawerMode: String, CaseIterable, Sendable {
    case gallery
    case files
}

public enum PhoneWindowScale: String, CaseIterable, Identifiable, Sendable {
    case smaller = "Smaller (75%)"
    case standard = "Standard (100%)"
    case larger = "Larger (125%)"
    
    public var id: String { rawValue }
    
    public var multiplier: CGFloat {
        switch self {
        case .smaller: return 0.8
        case .standard: return 1.0
        case .larger: return 1.2
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    public static weak var shared: AppState?
    
    @Published public var devices: [Device] = []
    @Published public var selectedDeviceId: String?
    @Published public var isMirroring: Bool = false
    @Published public var notifications: [NotificationItem] = []
    @Published public var isDemoMode: Bool = false
    @Published public var currentLanguageBadge: String = ""
    @Published public var isPhoneScreenOff: Bool = false
    @Published public var isPhoneLocked: Bool = false
    
    // Preferences
    @AppStorage(L10n.storageKey) public var appLanguage: AppLanguage = .system
    @AppStorage("turnScreenOff") public var turnScreenOff: Bool = true
    @AppStorage("forwardAudio") public var forwardAudio: Bool = true
    @AppStorage("stayAwake") public var stayAwake: Bool = true
    @AppStorage("frameStyle") public var frameStyle: PhoneFrameStyle = .auto
    @AppStorage("showFrontCamera") public var showFrontCamera: Bool = true
    @AppStorage("windowScale") public var windowScale: PhoneWindowScale = .standard
    @AppStorage("maxFps") public var maxFps: Int = 120
    @AppStorage("showPerformanceHUD") public var showPerformanceHUD: Bool = false
    @AppStorage("autoHotspotOnIsolation") public var autoHotspotOnIsolation: Bool = true
    @AppStorage("autoConnect") public var autoConnect: Bool = true
    @AppStorage("autoWirelessPromote") public var autoWirelessPromote: Bool = false
    @AppStorage("sendOnEnter") public var sendOnEnter: Bool = true
    @AppStorage("savedWirelessIPs") public var savedWirelessIPs: String = ""
    @AppStorage("knownDevicesData") private var knownDevicesData: Data = Data()
    @AppStorage("deviceProfilesData") private var deviceProfilesData: Data = Data()
    @AppStorage("hideDockIcon") public var hideDockIcon: Bool = false
    @AppStorage("continuityBridgeEnabled") public var continuityBridgeEnabled: Bool = true
    @AppStorage("mcpServerEnabled") public var mcpServerEnabled: Bool = false
    @AppStorage("mcpServerPort") public var mcpServerPort: Int = 8765
    @AppStorage("screenMemoryEnabled") public var screenMemoryEnabled: Bool = false
    @AppStorage(MCPExecutionDefaults.stepDelayKey) public var macroDefaultStepDelayMs: Int = MCPExecutionDefaults.defaultStepDelayMs
    @AppStorage(MCPExecutionDefaults.maxStepsKey) public var macroMaxSteps: Int = MCPExecutionDefaults.defaultMaxSteps
    @AppStorage(MCPExecutionDefaults.maxDurationKey) public var macroMaxTotalWaitSeconds: Int = MCPExecutionDefaults.defaultMaxDurationSeconds
    @AppStorage(MCPExecutionDefaults.selfHealingKey) public var mcpSelfHealingEnabled: Bool = MCPExecutionDefaults.defaultSelfHealingEnabled

    public var lang: AppLanguage {
        appLanguage.resolved
    }
    
    @Published public var knownDevices: [KnownDevice] = []
    @Published public var deviceProfiles: [String: DeviceProfile] = [:]
    @Published public var statusMessage: String = L10n.tr("Готов к работе", "Ready")
    @Published public var isScanning: Bool = false
    @Published public var showPairingSheet: Bool = false
    @Published public var showPhotoDrawer: Bool = false
    @Published public var drawerMode: SideDrawerMode = .gallery
    @Published public var photoTransferNotice: String? = nil
    @Published public var isRecording: Bool = false
    @Published public var isOCROverlayActive: Bool = false
    @Published public var installedApps: [AndroidAppItem] = []
    @Published public var isLoadingApps: Bool = false
    @Published public var isMCPRunning: Bool = false
    @Published public var isMCPAgentPaused: Bool = false
    @Published public var mcpAgentActivity: String? = nil
    @Published public var isVisualMCPCaptureActive: Bool = false
    @Published public var dependencyStatus: DependencyStatus?
    @Published public var isInstallingDependencies: Bool = false
    @Published public var installerLogs: String = ""
    @Published public var lastKnownWifiIP: String?
    
    /// Effective frame style resolving .auto to detected device hardware model
    public var effectiveFrameStyle: PhoneFrameStyle {
        if frameStyle == .auto {
            return PhoneFrameStyle.detect(for: selectedDevice)
        }
        return frameStyle
    }
    
    // Video streaming frame dimensions (downscaled by scrcpy max_size)
    @Published public var deviceWidth: Int = 1080
    @Published public var deviceHeight: Int = 2400

    // Android physical/override display dimensions used by Accessibility & input tap
    @Published public var physicalDisplayWidth: Int = 1080
    @Published public var physicalDisplayHeight: Int = 2400
    private var lastQueriedDisplaySizeSerial: String?
    
    public var isLandscape: Bool {
        return deviceWidth > deviceHeight
    }
    
    public var effectiveAspect: CGFloat {
        let dw = max(1, deviceWidth)
        let dh = max(1, deviceHeight)
        if isLandscape {
            let ratio = CGFloat(dw) / CGFloat(dh)
            return min(2.4, max(1.3, ratio))
        } else {
            let ratio = CGFloat(dh) / CGFloat(dw)
            return min(2.4, max(1.3, ratio))
        }
    }
    
    private var timer: Timer?
    private var hasAutoConnectedThisSession: Bool = false
    private var isRefreshing: Bool = false
    
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.processName == "xctest" ||
        NSClassFromString("XCTestCase") != nil
    }
    
    public init() {
        Self.shared = self
        self.currentLanguageBadge = KeyboardLanguageSyncService.getCurrentMacLanguage().uppercased()
        
        KeyboardLanguageSyncService.shared.onLanguageChanged = { [weak self] badge in
            Task { @MainActor in
                self?.currentLanguageBadge = badge
            }
        }
        
        loadKnownDevices()
        checkSystemDependencies()
        setupScrcpyCallbacks()
        
        guard !isRunningTests else { return }
        
        // Clean up hidden scrcpy audio helpers left by a previous crash, and make sure
        // ours never outlive the app (they would linger as stray "scrcpy" Dock icons).
        MirrorService.shared.killOrphanAudioProcesses()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MirrorService.shared.stopMirroring()
            MirrorService.shared.stopRecording()
            AndroidAppLauncherService.shared.stopAllAppWindows()
            ContinuityBridge.shared.stop()
            DiscoveryService.shared.stopBrowsing()
            MCPHTTPServer.shared.stop()
            ProcessLifecycleManager.shared.terminateAllProcesses()
        }
        loadDeviceProfiles()
        applyDockVisibility()
        syncContinuityBridgeState()
        setupMCPCallbacks()
        Task {
            await ShadowGraphManager.shared.loadPersistedGraphIfNeeded()
        }
        if mcpServerEnabled {
            syncMCPServerState()
        }
        startNotificationListener()
        startDiscoveryListener()
        setupConnectionAndPerformanceEngines()
        refreshDevices()
        startPeriodicPoll()
    }

    private func setupConnectionAndPerformanceEngines() {
        ConnectionManager.shared.onWakeReconnectRequested = { [weak self] in
            Task { @MainActor in
                self?.attemptAutoWifiReconnect()
            }
        }
        ConnectionManager.shared.startLifecycleObservers()

        PerformanceEngine.shared.onABRStepChange = { [weak self] bitRate, maxSize, reduced in
            Task { @MainActor in
                guard let self = self, self.isMirroring, let device = self.selectedDevice else { return }
                let prof = self.profile(for: device.id)
                self.statusMessage = reduced
                    ? L10n.tr("Wi-Fi перегружен — снижение битрейта (6 Мбит/с)", "Wi-Fi congested — ABR step down (6 Mbps)", lang: self.lang)
                    : L10n.tr("Связь стабильна — восстановление 120Hz (16 Мбит/с)", "Link stable — restoring 120Hz (16 Mbps)", lang: self.lang)
                try? MirrorService.shared.startMirroring(
                    for: device,
                    turnScreenOff: self.turnScreenOff,
                    forwardAudio: self.forwardAudio,
                    stayAwake: self.stayAwake,
                    maxFps: prof.maxFps,
                    bitRate: bitRate,
                    maxSize: maxSize
                ) { [weak self] in
                    Task { @MainActor in
                        self?.isMirroring = false
                        self?.syncScreenMemoryState()
                        self?.statusMessage = "Mirroring session ended"
                        KeyboardLanguageSyncService.shared.stopSync()
                    }
                }
            }
        }
    }
    
    private func startDiscoveryListener() {
        DiscoveryService.shared.startBrowsing()
        DiscoveryService.shared.onConnectFound = { [weak self] ip, port, name in
            Task { @MainActor in
                guard let self = self else { return }
                self.lastKnownWifiIP = ip
                if self.devices.isEmpty {
                    await RouterlessBypassService.shared.checkReachabilityIfNeeded(host: ip, port: port)
                }
            }
        }
    }
    
    private func setupScrcpyCallbacks() {
        ScrcpyClient.shared.onDeviceSizeKnown = { [weak self] w, h in
            Task { @MainActor in
                self?.deviceWidth = w
                self?.deviceHeight = h
            }
        }
    }
    
    private func loadKnownDevices() {
        if let decoded = try? JSONDecoder().decode([KnownDevice].self, from: knownDevicesData) {
            self.knownDevices = decoded
        }
    }
    
    public func persistKnownDevice(_ device: Device) {
        let ip: String
        let resolvedPort: Int?
        if device.connectionType == .wifi {
            if device.id.contains(":"), let colonIdx = device.id.lastIndex(of: ":") {
                ip = String(device.id[..<colonIdx])
                resolvedPort = Int(device.id[device.id.index(after: colonIdx)...]) ?? device.wirelessPort ?? 5555
            } else if let devIp = device.ipAddress, !devIp.isEmpty {
                ip = devIp
                resolvedPort = device.wirelessPort ?? DiscoveryService.shared.getConnectPort(for: devIp) ?? 5555
            } else {
                return
            }
        } else if device.connectionType == .usb, let devIp = device.ipAddress, !devIp.isEmpty {
            ip = devIp
            resolvedPort = device.wirelessPort ?? DiscoveryService.shared.getConnectPort(for: devIp)
        } else {
            return
        }
        
        self.lastKnownWifiIP = ip
        addSavedIP(ip)
        
        if let index = knownDevices.firstIndex(where: { $0.ipAddress == ip || $0.id == device.id }) {
            knownDevices[index].lastConnected = Date()
            knownDevices[index].name = device.displayName
            knownDevices[index].ipAddress = ip
            if let resolvedPort = resolvedPort {
                knownDevices[index].port = resolvedPort
            }
        } else {
            let newKnown = KnownDevice(
                id: device.id,
                name: device.displayName,
                ipAddress: ip,
                port: resolvedPort ?? 5555,
                lastConnected: Date(),
                autoConnect: true
            )
            knownDevices.append(newKnown)
        }
        if let encoded = try? JSONEncoder().encode(knownDevices) {
            knownDevicesData = encoded
        }
    }
    
    public func checkSystemDependencies() {
        self.dependencyStatus = DependencyService.shared.checkDependencies()
    }
    
    public func runAutoInstaller() {
        isInstallingDependencies = true
        installerLogs = "==> Начинаем автоматическую установку компонентов...\n"
        Task {
            let success = await DependencyService.shared.autoInstallDependencies { output in
                Task { @MainActor in
                    self.installerLogs += output
                }
            }
            Task { @MainActor in
                self.isInstallingDependencies = false
                self.checkSystemDependencies()
                if success {
                    self.statusMessage = "Компоненты успешно установлены!"
                    self.refreshDevices()
                } else {
                    self.statusMessage = "Ошибка авто-установки. Проверьте подключение к сети."
                }
            }
        }
    }
    
    public var selectedDevice: Device? {
        if isDemoMode {
            return Device(
                id: "demo-pixel-9-pro",
                model: "Pixel 9 Pro",
                manufacturer: "Google",
                androidVersion: "15",
                batteryLevel: 94,
                isCharging: true,
                connectionType: .wifi,
                state: .ready,
                ipAddress: "192.168.1.55"
            )
        }
        if let id = selectedDeviceId {
            return devices.first(where: { $0.id == id })
        }
        return devices.first
    }
    
    private func startNotificationListener() {
        NotificationService.shared.onNotificationReceived = { [weak self] item in
            Task { @MainActor in
                self?.notifications.insert(item, at: 0)
                if (self?.notifications.count ?? 0) > 50 {
                    self?.notifications.removeLast()
                }
            }
        }
        NotificationService.shared.onDeviceDiscoveredViaQR = { [weak self] clientIP in
            Task { @MainActor in
                self?.statusMessage = "Устройство найдено через QR (\(clientIP)), подключаем..."
                _ = await self?.connectWireless(host: clientIP, port: 5555)
            }
        }
        NotificationService.shared.startServer()
    }
    
    private var lastLockStateCheck: Date = .distantPast

    public func startPeriodicPoll() {
        timer?.invalidate()
        let pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isRefreshing else { return }
                self.refreshDevices()
            }
        }
        pollTimer.tolerance = 1.2
        timer = pollTimer
    }
    
    public func refreshDevices() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            defer { self.isRefreshing = false }
            let list = await ADBService.shared.listDevices()
            if self.devices != list {
                self.devices = list
            }
            if selectedDeviceId == nil || !list.contains(where: { $0.id == self.selectedDeviceId }) {
                self.selectedDeviceId = list.first?.id
            }
            // Do not override the UI state while a session is still starting up
            // (server push + socket handshake takes 1-3s); otherwise the screen flips back
            // to standby and a second click spawns a duplicate session.
            let mirrorActive = MirrorService.shared.isMirroring || MirrorService.shared.isStarting
            if self.isMirroring != mirrorActive {
                self.isMirroring = mirrorActive
            }
            
            if list.isEmpty {
                self.hasAutoConnectedThisSession = false
                self.isPhoneScreenOff = false
                self.isPhoneLocked = false
                self.lastQueriedDisplaySizeSerial = nil
                self.syncContinuityBridgeState()
                DiscoveryService.shared.setLowPowerPaused(false)
                self.attemptAutoWifiReconnect()
            } else {
                self.syncContinuityBridgeState()
                DiscoveryService.shared.setLowPowerPaused(mirrorActive && !self.showPairingSheet)
                let lockCheckInterval: TimeInterval = mirrorActive ? 4.0 : 12.0
                if let ready = list.first(where: { $0.state == .ready }) {
                    let targetSerial = self.selectedDevice?.state == .ready ? self.selectedDevice!.id : ready.id
                    await self.refreshPhysicalDisplaySizeIfNeeded(for: targetSerial)
                    if !self.isRunningTests && (mirrorActive || self.mcpServerEnabled || self.isMCPRunning) {
                        await ShadowGraphManager.shared.ensureStarted(serial: targetSerial)
                    }
                    if Date().timeIntervalSince(self.lastLockStateCheck) >= lockCheckInterval {
                        self.lastLockStateCheck = Date()
                        let lockState = await ADBService.shared.fetchScreenAndLockState(serial: ready.id)
                        if self.isPhoneScreenOff != lockState.isScreenOff {
                            self.isPhoneScreenOff = lockState.isScreenOff
                        }
                        if self.isPhoneLocked != lockState.isLocked {
                            self.isPhoneLocked = lockState.isLocked
                        }
                    }
                }
                self.handleAutomation(devices: list)
            }
        }
    }
    
    private var tcpipPromotedSerials: Set<String> = []
    private var isAttemptingWifiReconnect: Bool = false
    private var lastReconnectAttemptTime: Date = .distantPast

    public func refreshPhysicalDisplaySizeIfNeeded(for serial: String, force: Bool = false) async {
        guard !isRunningTests else { return }
        if !force && lastQueriedDisplaySizeSerial == serial {
            return
        }
        lastQueriedDisplaySizeSerial = serial
        if let size = await ADBService.shared.fetchDisplaySize(serial: serial) {
            if physicalDisplayWidth != size.width {
                physicalDisplayWidth = size.width
            }
            if physicalDisplayHeight != size.height {
                physicalDisplayHeight = size.height
            }
        }
    }
    
    private func attemptAutoWifiReconnect() {
        ConnectionManager.shared.attemptAutoReconnect(knownDevices: knownDevices) { [weak self] target in
            self?.statusMessage = "Подключено к \(target)"
            self?.refreshDevices()
        }
    }
    
    private func handleAutomation(devices: [Device]) {
        guard let device = devices.first(where: { $0.state == .ready }) else {
            return
        }
        
        // Save to persistent known devices registry
        persistKnownDevice(device)
        
        // Silent USB-to-Wi-Fi Handoff: activate TCP/IP 5555 once per USB serial when not mirroring;
        // if Wi-Fi router isolation blocks peer-to-peer traffic, auto-enable phone Hotspot when configured.
        ConnectionManager.shared.promoteUSBToWiFiIfNeeded(
            device: device,
            isMirroring: isMirroring,
            autoHotspotOnIsolation: autoHotspotOnIsolation
        ) { [weak self] message in
            self?.statusMessage = message
            self?.refreshDevices()
        }
        
        // Zero-Click Auto-Connect: Launch mirroring immediately when device is ready
        if autoConnect && !isMirroring && !hasAutoConnectedThisSession {
            hasAutoConnectedThisSession = true
            showPairingSheet = false
            toggleMirroring()
        }
    }
    
    public func addSavedIP(_ ip: String) {
        var list = savedWirelessIPs.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !list.contains(ip) {
            list.append(ip)
            savedWirelessIPs = list.joined(separator: ",")
        }
    }
    
    public func connectPaired(host: String, port: Int) async -> (Bool, String) {
        do {
            statusMessage = "Подключение к \(host):\(port)..."
            let res = try await ADBService.shared.connectPairedDevice(host: host, port: port)
            statusMessage = res.message
            if res.success {
                addSavedIP(host)
                lastKnownWifiIP = host
                refreshDevices()
            }
            return (res.success, res.message)
        } catch {
            let msg = "Ошибка: \(error.localizedDescription)"
            statusMessage = msg
            return (false, msg)
        }
    }
    
    // MARK: - Actions (1-in-1 with iPhone Mirroring in macOS Sequoia)
    
    private func recordShadowKeyEvent(_ keyName: String) {
        guard !isRunningTests else { return }
        Task {
            await ShadowGraphManager.shared.recordAction(
                AttributedUIAction(kind: .keyevent, targetDescription: keyName)
            )
        }
    }

    public func triggerHome() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(3) // KEYCODE_HOME
            recordShadowKeyEvent("HOME")
            return
        }
        guard let device = selectedDevice else { return }
        recordShadowKeyEvent("HOME")
        Task {
            await ADBService.shared.sendHome(serial: device.id)
        }
    }
    
    public func triggerBack() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendBackOrScreenOn()
            recordShadowKeyEvent("BACK")
            return
        }
        guard let device = selectedDevice else { return }
        recordShadowKeyEvent("BACK")
        Task {
            await ADBService.shared.sendBack(serial: device.id)
        }
    }
    
    public func triggerAppSwitch() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(187) // KEYCODE_APP_SWITCH
            recordShadowKeyEvent("RECENTS")
            return
        }
        guard let device = selectedDevice else { return }
        recordShadowKeyEvent("RECENTS")
        Task {
            await ADBService.shared.sendAppSwitch(serial: device.id)
        }
    }
    
    public func triggerNotifications() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(83) // KEYCODE_NOTIFICATION
            return
        }
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendNotifications(serial: device.id)
        }
    }
    
    public func triggerPower() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(26) // KEYCODE_POWER
            return
        }
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendPower(serial: device.id)
        }
    }
    
    public func triggerUnlock() {
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.unlockScreen(serial: device.id)
        }
    }
    
    public func stopMirroringOnWindowClose() {
        guard isMirroring || isRecording || MirrorService.shared.isMirroring || MirrorService.shared.isStarting else { return }
        MirrorService.shared.stopMirroring()
        MirrorService.shared.stopRecording()
        KeyboardLanguageSyncService.shared.stopSync()
        isMirroring = false
        isRecording = false
        syncScreenMemoryState()
        DiscoveryService.shared.setLowPowerPaused(false)
        statusMessage = "Mirroring stopped"
    }

    public func toggleMirroring() {
        if isMirroring || MirrorService.shared.isStarting {
            MirrorService.shared.stopMirroring()
            KeyboardLanguageSyncService.shared.stopSync()
            isMirroring = false
            syncScreenMemoryState()
            statusMessage = "Mirroring stopped"
        } else {
            guard let device = selectedDevice else {
                statusMessage = "No device selected"
                return
            }
            let prof = profile(for: device.id)
            do {
                try MirrorService.shared.startMirroring(
                    for: device,
                    turnScreenOff: turnScreenOff,
                    forwardAudio: forwardAudio,
                    stayAwake: stayAwake,
                    maxFps: prof.maxFps,
                    bitRate: prof.bitRate,
                    maxSize: prof.maxSize
                ) { [weak self] in
                    Task { @MainActor in
                        self?.isMirroring = false
                        self?.syncScreenMemoryState()
                        self?.statusMessage = "Mirroring session ended"
                        KeyboardLanguageSyncService.shared.stopSync()
                    }
                }
                isMirroring = true
                syncScreenMemoryState()
                statusMessage = "Mirroring \(device.displayName)..."
                KeyboardLanguageSyncService.shared.startSync(for: device.id)
                let serial = device.id
                Task { [weak self] in
                    await self?.refreshPhysicalDisplaySizeIfNeeded(for: serial, force: true)
                    if self?.isRunningTests == false {
                        await ShadowGraphManager.shared.ensureStarted(serial: serial, forceReconnectIfWaiting: true)
                    }
                }
            } catch {
                statusMessage = "Failed to start: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Dock Visibility, Continuity Bridge, Recording, App Launcher & Vision OCR

    public func applyDockVisibility() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    public func syncContinuityBridgeState() {
        let hasReadyDevice = devices.contains(where: { $0.state == .ready })
        if continuityBridgeEnabled && hasReadyDevice {
            ContinuityBridge.shared.onSyncEvent = { [weak self] msg in
                Task { @MainActor in
                    self?.photoTransferNotice = msg
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if self?.photoTransferNotice == msg {
                            self?.photoTransferNotice = nil
                        }
                    }
                }
            }
            ContinuityBridge.shared.start { [weak self] in
                return self?.selectedDeviceId
            }
        } else {
            ContinuityBridge.shared.stop()
        }
    }

    public func toggleRecording() {
        if isRecording || MirrorService.shared.isRecording {
            MirrorService.shared.stopRecording()
            isRecording = false
            if let url = MirrorService.shared.lastRecordingURL {
                photoTransferNotice = L10n.tr("Запись сохранена: \(url.lastPathComponent)", "Saved: \(url.lastPathComponent)", lang: lang)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    self.photoTransferNotice = nil
                }
            }
        } else {
            guard let device = selectedDevice else { return }
            let prof = profile(for: device.id)
            do {
                _ = try MirrorService.shared.startRecording(serial: device.id, maxSize: prof.maxSize, bitRate: prof.bitRate)
                isRecording = true
                photoTransferNotice = L10n.tr("Идёт запись экрана...", "Recording screen...", lang: lang)
            } catch {
                statusMessage = "Recording failed: \(error.localizedDescription)"
            }
        }
    }

    public func triggerScreenOCR() {
        guard isMirroring else {
            photoTransferNotice = L10n.tr("Сначала откройте экран телефона", "Start mirroring first", lang: lang)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.photoTransferNotice = nil
            }
            return
        }
        isOCROverlayActive.toggle()
        NSApp.activate(ignoringOtherApps: true)
    }

    public func loadInstalledApps() {
        guard let serial = selectedDevice?.id, !isLoadingApps else { return }
        isLoadingApps = true
        Task {
            do {
                let apps = try await AndroidAppLauncherService.shared.fetchInstalledApps(serial: serial)
                await MainActor.run {
                    self.installedApps = apps
                    self.isLoadingApps = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingApps = false
                }
            }
        }
    }

    public func launchStandaloneApp(_ app: AndroidAppItem) {
        guard let serial = selectedDevice?.id else { return }
        let prof = profile(for: serial)
        do {
            try AndroidAppLauncherService.shared.launchApp(
                app,
                serial: serial,
                profile: prof,
                turnScreenOff: turnScreenOff,
                stayAwake: stayAwake
            )
            statusMessage = L10n.tr("Запущено окно: \(app.displayName)", "Launched \(app.displayName)", lang: lang)
        } catch {
            statusMessage = "Failed to launch \(app.displayName): \(error.localizedDescription)"
        }
    }

    public func profile(for serial: String) -> DeviceProfile {
        deviceProfiles[serial] ?? .default
    }

    public func updateProfile(_ profile: DeviceProfile, for serial: String) {
        deviceProfiles[serial] = profile
        if let encoded = try? JSONEncoder().encode(deviceProfiles) {
            deviceProfilesData = encoded
        }
    }

    private func loadDeviceProfiles() {
        guard !deviceProfilesData.isEmpty,
              let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: deviceProfilesData) else { return }
        deviceProfiles = decoded
    }

    // MARK: - Built-in MCP Server & AI Agent Kill-Switch

    private func setupMCPCallbacks() {
        MCPServerCore.shared.onAgentActivity = { [weak self] activity in
            Task { @MainActor in
                self?.mcpAgentActivity = activity
            }
        }
        MCPSelfHealingNotifier.shared.onHealed = { [weak self] toolName, expectedLabel, matchedText, x, y in
            Task { @MainActor in
                guard let self else { return }
                let notice = L10n.tr(
                    "Self-Healing (\(toolName)): ID не найден, нажато по OCR '\(matchedText)'",
                    "Self-Healing (\(toolName)): ID missing, healed via OCR '\(matchedText)'",
                    lang: self.lang
                )
                self.photoTransferNotice = notice
                self.statusMessage = L10n.tr(
                    "Vision OCR восстановил нажатие для '\(toolName)' (\(x), \(y))",
                    "Vision OCR healed tap for '\(toolName)' at (\(x), \(y))",
                    lang: self.lang
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    if self.photoTransferNotice == notice {
                        self.photoTransferNotice = nil
                    }
                }

                if Bundle.main.bundleURL.pathExtension == "app" {
                    let content = UNMutableNotificationContent()
                    content.title = "AndOnMac Self-Healing"
                    content.body = L10n.tr(
                        "Semantic ID для '\(toolName)' не найден (ожидался '\(expectedLabel)'). Выполнено нажатие по Vision OCR: '\(matchedText)'.",
                        "Semantic ID failed for '\(toolName)' (expected '\(expectedLabel)'); healed via Vision OCR ('\(matchedText)').",
                        lang: self.lang
                    )
                    content.sound = .default
                    let req = UNNotificationRequest(
                        identifier: "mcp-heal-\(UUID().uuidString)",
                        content: content,
                        trigger: nil
                    )
                    try? await UNUserNotificationCenter.current().add(req)
                }
            }
        }
    }

    public func syncMCPServerState() {
        if mcpServerEnabled {
            let clampedPort = UInt16(max(1024, min(65535, mcpServerPort)))
            MCPHTTPServer.shared.start(port: clampedPort) { [weak self] running in
                Task { @MainActor in
                    self?.isMCPRunning = running
                    if running, self?.isRunningTests == false {
                        let serial = self?.selectedDevice?.state == .ready
                            ? self?.selectedDevice?.id
                            : self?.devices.first(where: { $0.state == .ready })?.id
                        await ShadowGraphManager.shared.ensureStarted(serial: serial)
                    }
                }
            }
        } else {
            MCPHTTPServer.shared.stop()
            isMCPRunning = false
        }
    }

    public func toggleMCPAgentPause() {
        isMCPAgentPaused.toggle()
        MCPServerCore.shared.isAgentPaused = isMCPAgentPaused
        if isMCPAgentPaused {
            mcpAgentActivity = nil
        }
    }

    // MARK: - Semantic Screen Memory (Recall)

    public func syncScreenMemoryState() {
        if screenMemoryEnabled, isMirroring, let serial = selectedDevice?.id {
            ScreenMemorySnapshotter.shared.start(serial: serial)
        } else {
            ScreenMemorySnapshotter.shared.stop()
        }
    }

    public func triggerRecallSearch() {
        RecallPanelController.shared.toggle(appState: self)
    }

    // MARK: - Visual-to-MCP Bridge

    public func triggerVisualMCPCapture() {
        guard isMirroring, selectedDevice != nil else {
            photoTransferNotice = L10n.tr("Сначала запустите трансляцию экрана", "Start screen mirroring first", lang: lang)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.photoTransferNotice = nil
            }
            return
        }
        isOCROverlayActive = false
        isVisualMCPCaptureActive.toggle()
    }

    public func copyMCPConfigToClipboard() {
        let executablePath = Bundle.main.executablePath
            ?? "/Applications/AndOnMac.app/Contents/MacOS/AndOnMac"
        let snippet = """
        {
          "mcpServers": {
            "andonmac": {
              "command": "\(executablePath)",
              "args": ["--mcp-stdio"]
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        photoTransferNotice = L10n.tr("MCP-конфиг скопирован", "MCP Config Copied", lang: lang)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.photoTransferNotice == L10n.tr("MCP-конфиг скопирован", "MCP Config Copied", lang: self.lang) {
                self.photoTransferNotice = nil
            }
        }
    }
    
    public func openDrawer(mode: SideDrawerMode) {
        if showPhotoDrawer && drawerMode == mode {
            showPhotoDrawer = false
        } else {
            drawerMode = mode
            showPhotoDrawer = true
        }
    }

    public func disconnectDevice(_ device: Device) {
        if isMirroring && selectedDeviceId == device.id {
            toggleMirroring()
        }
        guard device.connectionType == .wifi else {
            refreshDevices()
            return
        }
        Task {
            _ = try? await ADBService.shared.execute(arguments: ["disconnect", device.id], timeoutSeconds: 4.0)
            await MainActor.run {
                if self.selectedDeviceId == device.id {
                    self.selectedDeviceId = nil
                }
                self.statusMessage = L10n.tr("Отключено от \(device.displayName)", "Disconnected from \(device.displayName)", lang: self.lang)
                self.refreshDevices()
            }
        }
    }

    public func removeKnownDevice(id: String) {
        knownDevices.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(knownDevices) {
            knownDevicesData = encoded
        }
    }
    
    public func pairAndConnect(host: String, pairingPort: Int, code: String, connectPort: Int? = nil) async -> (Bool, String) {
        do {
            statusMessage = "Сопряжение с \(host):\(pairingPort)..."
            let res = try await ADBService.shared.pairAndConnect(host: host, pairingPort: pairingPort, code: code, userConnectPort: connectPort)
            statusMessage = res.message
            refreshDevices()
            return (res.success, res.message)
        } catch {
            let msg = "Ошибка: \(error.localizedDescription)"
            statusMessage = msg
            return (false, msg)
        }
    }
    
    public func pairDevice(host: String, port: Int, code: String) async -> Bool {
        let (success, _) = await pairAndConnect(host: host, pairingPort: port, code: code, connectPort: nil)
        return success
    }
    
    public func connectWireless(host: String, port: Int = 5555) async -> Bool {
        do {
            statusMessage = "Подключение к \(host):\(port)..."
            let output = try await ADBService.shared.connectWifi(ip: host, port: port)
            statusMessage = output
            let success = ADBService.isConnectSuccess(output)
            if success {
                addSavedIP(host)
                lastKnownWifiIP = host
                DiscoveryService.shared.registerConnectPort(for: host, port: port)
                refreshDevices()
            }
            return success
        } catch {
            statusMessage = "Ошибка подключения: \(error.localizedDescription)"
            return false
        }
    }
    
    @discardableResult
    public func switchSelectedToWireless() async -> (Bool, String) {
        let usbCandidate = (selectedDevice?.connectionType == .usb ? selectedDevice : nil)
            ?? devices.first(where: { $0.connectionType == .usb && $0.state == .ready })
            ?? devices.first(where: { $0.connectionType == .usb })
        guard let device = usbCandidate else {
            return (false, "Подключите телефон по кабелю USB")
        }
        guard let ip = device.ipAddress, !ip.isEmpty else {
            return (false, "На телефоне не найден IP-адрес Wi-Fi (wlan0). Проверьте, что Wi-Fi включен.")
        }
        let targetPort = device.wirelessPort ?? DiscoveryService.shared.getConnectPort(for: ip) ?? 5555
        statusMessage = "Переключение на Wi-Fi (\(ip):\(targetPort))..."
        let res = await ADBService.shared.switchToWireless(serial: device.id, ip: ip, port: 5555)
        statusMessage = res.message
        refreshDevices()
        return (res.success, res.message)
    }
    
    public func resetUSBAndADB() async {
        savedWirelessIPs = ""
        knownDevices.removeAll()
        knownDevicesData = Data()
        statusMessage = "Сброс ADB сервера и восстановление USB..."
        await ADBService.shared.resetUSBAndRestartServer()
        refreshDevices()
        statusMessage = "ADB перезапущен. Переподключите кабель или переключите «Отладку по USB» на телефоне."
    }
}
