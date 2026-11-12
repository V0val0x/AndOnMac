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
    @Published public var devices: [Device] = []
    @Published public var selectedDeviceId: String?
    @Published public var isMirroring: Bool = false
    @Published public var notifications: [NotificationItem] = []
    @Published public var isDemoMode: Bool = false
    
    // Preferences
    @AppStorage("turnScreenOff") public var turnScreenOff: Bool = true
    @AppStorage("forwardAudio") public var forwardAudio: Bool = true
    @AppStorage("stayAwake") public var stayAwake: Bool = true
    @AppStorage("frameStyle") public var frameStyle: PhoneFrameStyle = .pixel
    @AppStorage("windowScale") public var windowScale: PhoneWindowScale = .standard
    @AppStorage("maxFps") public var maxFps: Int = 60
    @AppStorage("autoConnect") public var autoConnect: Bool = true
    @AppStorage("autoWirelessPromote") public var autoWirelessPromote: Bool = true
    @AppStorage("savedWirelessIPs") public var savedWirelessIPs: String = ""
    @AppStorage("knownDevicesData") private var knownDevicesData: Data = Data()
    
    @Published public var knownDevices: [KnownDevice] = []
    @Published public var statusMessage: String = "Готов к работе"
    @Published public var isScanning: Bool = false
    @Published public var showPairingSheet: Bool = false
    @Published public var dependencyStatus: DependencyStatus?
    @Published public var isInstallingDependencies: Bool = false
    @Published public var installerLogs: String = ""
    
    private var timer: Timer?
    private var hasAutoConnectedThisSession: Bool = false
    
    public init() {
        loadKnownDevices()
        checkSystemDependencies()
        startNotificationListener()
        refreshDevices()
        startPeriodicPoll()
    }
    
    private func loadKnownDevices() {
        if let decoded = try? JSONDecoder().decode([KnownDevice].self, from: knownDevicesData) {
            self.knownDevices = decoded
        }
    }
    
    private func persistKnownDevice(_ device: Device) {
        guard let ip = device.ipAddress, !ip.isEmpty else { return }
        if let index = knownDevices.firstIndex(where: { $0.ipAddress == ip || $0.id == device.id }) {
            knownDevices[index].lastConnected = Date()
            knownDevices[index].name = device.displayName
        } else {
            let newKnown = KnownDevice(
                id: device.id,
                name: device.displayName,
                ipAddress: ip,
                port: 5555,
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
        // Fast 1.5s interval for instant plug-and-play response
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
            }
        }
    }
    
    public func refreshDevices() {
        Task {
            isScanning = true
            let list = await ADBService.shared.listDevices()
            self.devices = list
            if selectedDeviceId == nil || !list.contains(where: { $0.id == self.selectedDeviceId }) {
                self.selectedDeviceId = list.first?.id
            }
            self.isMirroring = MirrorService.shared.isMirroring
            isScanning = false
            
            // Automatic seamless features
            handleAutomation(devices: list)
        }
    }
    
    private func handleAutomation(devices: [Device]) {
        guard let device = devices.first(where: { $0.state == .ready }) else {
            // Background Auto-Reconnection to known devices
            if !isMirroring {
                // Try all known devices
                for known in knownDevices where known.autoConnect {
                    Task {
                        _ = await connectWireless(host: known.ipAddress, port: known.port)
                    }
                }
                // Also try saved wireless IPs
                if !savedWirelessIPs.isEmpty {
                    let ips = savedWirelessIPs.components(separatedBy: ",").filter { !$0.isEmpty }
                    for ip in ips {
                        Task {
                            _ = await connectWireless(host: ip, port: 5555)
                        }
                    }
                }
            }
            return
        }
        
        // Save to persistent known devices registry
        persistKnownDevice(device)
        
        // 1. Auto-Wireless Promotion: If device is USB connected and has IP, enable TCP/IP mode and remember it
        if autoWirelessPromote && device.connectionType == .usb, let ip = device.ipAddress, !ip.isEmpty {
            if !savedWirelessIPs.contains(ip) {
                var ips = savedWirelessIPs.components(separatedBy: ",").filter { !$0.isEmpty }
                ips.append(ip)
                savedWirelessIPs = ips.joined(separator: ",")
                
                Task {
                    _ = try? await ADBService.shared.enableTcpIp(serial: device.id, port: 5555)
                }
            }
        }
        
        // 2. Zero-Click Auto-Connect: Launch mirroring immediately when device is ready
        if autoConnect && !isMirroring && !hasAutoConnectedThisSession {
            hasAutoConnectedThisSession = true
            toggleMirroring()
        }
    }
    
    // MARK: - Actions (1-in-1 with iPhone Mirroring in macOS Sequoia)
    
    public func triggerHome() {
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendHome(serial: device.id)
        }
    }
    
    public func triggerBack() {
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendBack(serial: device.id)
        }
    }
    
    public func triggerAppSwitch() {
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendAppSwitch(serial: device.id)
        }
    }
    
    public func triggerNotifications() {
        guard let device = selectedDevice else { return }
        Task {
            await ADBService.shared.sendNotifications(serial: device.id)
        }
    }
    
    public func triggerPower() {
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
                    }
                }
                isMirroring = true
                statusMessage = "Mirroring \(device.displayName)..."
            } catch {
                statusMessage = "Failed to start: \(error.localizedDescription)"
            }
        }
    }
    
    public func pairDevice(host: String, port: Int, code: String) async -> Bool {
        do {
            statusMessage = "Pairing with \(host):\(port)..."
            let output = try await ADBService.shared.pairDevice(host: host, port: port, code: code)
            statusMessage = output.contains("Successfully") ? "Paired successfully!" : output
            refreshDevices()
            return true
        } catch {
            statusMessage = "Pairing failed: \(error.localizedDescription)"
            return false
        }
    }
    
    public func connectWireless(host: String, port: Int = 5555) async -> Bool {
        do {
            statusMessage = "Connecting to \(host):\(port)..."
            let output = try await ADBService.shared.connectWifi(ip: host, port: port)
            statusMessage = output
            refreshDevices()
            return output.contains("connected")
        } catch {
            statusMessage = "Connection failed: \(error.localizedDescription)"
            return false
        }
    }
    
    public func switchSelectedToWireless() async {
        guard let device = selectedDevice, device.connectionType == .usb else { return }
        do {
            statusMessage = "Switching to Wireless mode..."
            _ = try await ADBService.shared.enableTcpIp(serial: device.id, port: 5555)
            if let ip = device.ipAddress {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                _ = try await ADBService.shared.connectWifi(ip: ip, port: 5555)
            }
            refreshDevices()
            statusMessage = "Device switched to Wi-Fi mode!"
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }
}
