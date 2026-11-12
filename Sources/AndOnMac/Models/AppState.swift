import Foundation
import SwiftUI
import Combine

public enum PhoneFrameStyle: String, CaseIterable, Identifiable, Sendable {
    case pixel = "Google Pixel"
    case modernBezel = "Minimal Bezel"
    case borderless = "Borderless"
    
    public var id: String { rawValue }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var devices: [Device] = []
    @Published public var selectedDeviceId: String?
    @Published public var isMirroring: Bool = false
    @Published public var notifications: [NotificationItem] = []
    
    // Preferences
    @AppStorage("turnScreenOff") public var turnScreenOff: Bool = true
    @AppStorage("forwardAudio") public var forwardAudio: Bool = true
    @AppStorage("stayAwake") public var stayAwake: Bool = true
    @AppStorage("frameStyle") public var frameStyle: PhoneFrameStyle = .pixel
    @AppStorage("maxFps") public var maxFps: Int = 60
    
    @Published public var statusMessage: String = "Ready"
    @Published public var isScanning: Bool = false
    @Published public var showPairingSheet: Bool = false
    
    private var timer: Timer?
    
    public init() {
        startNotificationListener()
        refreshDevices()
        startPeriodicPoll()
    }
    
    public var selectedDevice: Device? {
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
        NotificationService.shared.startServer()
    }
    
    public func startPeriodicPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
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
