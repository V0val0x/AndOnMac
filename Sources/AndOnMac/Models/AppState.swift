import Foundation
import SwiftUI
import Combine

public enum PhoneFrameStyle: String, CaseIterable, Identifiable, Sendable {
    case pixel = "Google Pixel"
    case modernBezel = "Minimal Bezel"
    case borderless = "Borderless"
    
    public var id: String { rawValue }
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
    
    // Preferences
    @AppStorage("turnScreenOff") public var turnScreenOff: Bool = true
    @AppStorage("forwardAudio") public var forwardAudio: Bool = true
    @AppStorage("stayAwake") public var stayAwake: Bool = true
    @AppStorage("frameStyle") public var frameStyle: PhoneFrameStyle = .pixel
    @AppStorage("windowScale") public var windowScale: PhoneWindowScale = .standard
    @AppStorage("maxFps") public var maxFps: Int = 60
    @AppStorage("autoConnect") public var autoConnect: Bool = true
    @AppStorage("autoWirelessPromote") public var autoWirelessPromote: Bool = false
    @AppStorage("savedWirelessIPs") public var savedWirelessIPs: String = ""
    @AppStorage("knownDevicesData") private var knownDevicesData: Data = Data()
    
    @Published public var knownDevices: [KnownDevice] = []
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var isScanning: Bool = false
    @Published public var showPairingSheet: Bool = false
    @Published public var showPhotoDrawer: Bool = false
    @Published public var photoTransferNotice: String? = nil
    @Published public var dependencyStatus: DependencyStatus?
    @Published public var isInstallingDependencies: Bool = false
    @Published public var installerLogs: String = ""
    
    // Video streaming frame dimensions
    @Published public var deviceWidth: Int = 1080
    @Published public var deviceHeight: Int = 2400
    
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
        startNotificationListener()
        setupScrcpyCallbacks()
        refreshDevices()
        startPeriodicPoll()
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
    
    private func persistKnownDevice(_ device: Device) {
        // Only persist active Wi-Fi connections to avoid saving unreachable cellular IPs
        guard device.connectionType == .wifi else { return }
        let ip: String
        let port: Int
        if device.id.contains(":"), let colonIdx = device.id.lastIndex(of: ":") {
            ip = String(device.id[..<colonIdx])
            port = Int(device.id[device.id.index(after: colonIdx)...]) ?? 5555
        } else if let devIp = device.ipAddress, !devIp.isEmpty {
            ip = devIp
            port = 5555
        } else {
            return
        }
        
        if let index = knownDevices.firstIndex(where: { $0.ipAddress == ip || $0.id == device.id }) {
            knownDevices[index].lastConnected = Date()
            knownDevices[index].name = device.displayName
            knownDevices[index].port = port
        } else {
            let newKnown = KnownDevice(
                id: device.id,
                name: device.displayName,
                ipAddress: ip,
                port: port,
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
    
    public func startPeriodicPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isRefreshing else { return }
                self.refreshDevices()
            }
        }
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
            let mirrorActive = MirrorService.shared.isMirroring
            if self.isMirroring != mirrorActive {
                self.isMirroring = mirrorActive
            }
            
            if list.isEmpty {
                self.hasAutoConnectedThisSession = false
            } else {
                handleAutomation(devices: list)
            }
        }
    }
    
    private func handleAutomation(devices: [Device]) {
        guard let device = devices.first(where: { $0.state == .ready }) else {
            return
        }
        
        // Save to persistent known devices registry (only active Wi-Fi connections)
        persistKnownDevice(device)
        
        // Zero-Click Auto-Connect: Launch mirroring immediately when device is ready
        if autoConnect && !isMirroring && !hasAutoConnectedThisSession {
            hasAutoConnectedThisSession = true
            showPairingSheet = false
            toggleMirroring()
        }
    }
    
    // MARK: - Actions (1-in-1 with iPhone Mirroring in macOS Sequoia)
    
    public func triggerHome() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(3) // KEYCODE_HOME
            return
        }
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendHome(serial: device.id)
        }
    }
    
    public func triggerBack() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendBackOrScreenOn()
            return
        }
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendBack(serial: device.id)
        }
    }
    
    public func triggerAppSwitch() {
        if ScrcpyClient.shared.isConnected {
            ScrcpyClient.shared.sendKeycode(187) // KEYCODE_APP_SWITCH
            return
        }
        guard let device = selectedDevice else { return }
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
    
    public func toggleMirroring() {
        if isMirroring {
            MirrorService.shared.stopMirroring()
            KeyboardLanguageSyncService.shared.stopSync()
            isMirroring = false
            statusMessage = "Mirroring stopped"
        } else {
            guard let device = selectedDevice else {
                statusMessage = "No device selected"
                return
            }
            do {
                try MirrorService.shared.startMirroring(
                    for: device,
                    turnScreenOff: turnScreenOff,
                    forwardAudio: forwardAudio,
                    stayAwake: stayAwake,
                    maxFps: maxFps
                ) { [weak self] in
                    Task { @MainActor in
                        self?.isMirroring = false
                        self?.statusMessage = "Mirroring session ended"
                        KeyboardLanguageSyncService.shared.stopSync()
                    }
                }
                isMirroring = true
                statusMessage = "Mirroring \(device.displayName)..."
                KeyboardLanguageSyncService.shared.startSync(for: device.id)
            } catch {
                statusMessage = "Failed to start: \(error.localizedDescription)"
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
        guard let device = selectedDevice, device.connectionType == .usb else {
            return (false, "Подключите телефон по кабелю USB")
        }
        guard let ip = device.ipAddress, !ip.isEmpty else {
            return (false, "На телефоне не найден IP-адрес Wi-Fi (wlan0). Проверьте, что Wi-Fi включен.")
        }
        statusMessage = "Переключение на Wi-Fi (\(ip):5555)..."
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
