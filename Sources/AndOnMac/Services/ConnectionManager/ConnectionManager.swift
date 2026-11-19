import Foundation
import AppKit

/// Coordinates QR pairing, silent USB-to-Wi-Fi handoff (`adb tcpip 5555` + IP caching),
/// wake-from-sleep auto-reconnect, and router-isolation bypasses.
@MainActor
public final class ConnectionManager: ObservableObject {
    public static let shared = ConnectionManager()

    private var promotedUSBSerials: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var isReconnecting = false
    private var lastReconnectAttempt: Date = .distantPast

    public var onWakeReconnectRequested: (@Sendable () -> Void)?

    private init() {}

    /// Installs the `NSWorkspace.didWakeNotification` observer for seamless reconnect after Mac sleep.
    public func startLifecycleObservers() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastReconnectAttempt = .distantPast
                self?.onWakeReconnectRequested?()
            }
        }
    }

    /// Silently promotes a ready USB device to `adb tcpip 5555` once per session (when not actively mirroring)
    /// so unplugging the cable seamlessly transitions to Wi-Fi. If `autoHotspotOnIsolation` is enabled and the
    /// phone's Wi-Fi IP is unreachable from Mac (AP/Client Isolation), automatically starts the phone's Hotspot and connects.
    public func promoteUSBToWiFiIfNeeded(
        device: Device,
        isMirroring: Bool,
        autoHotspotOnIsolation: Bool = true,
        onStatusUpdate: (@MainActor (String) -> Void)? = nil
    ) {
        guard device.connectionType == .usb,
              device.state == .ready,
              !isMirroring,
              !promotedUSBSerials.contains(device.id) else {
            return
        }
        promotedUSBSerials.insert(device.id)
        let serial = device.id
        let wifiIP = device.ipAddress
        let deviceName = device.displayName
        Task.detached(priority: .utility) {
            _ = try? await ADBService.shared.enableTcpIp(serial: serial, port: 5555)
            guard autoHotspotOnIsolation, let ip = wifiIP, !ip.isEmpty else { return }

            // Wait briefly for adbd to restart on TCP/IP 5555, then test Wi-Fi reachability
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let reachable = await RouterlessBypassService.probeTCPReachability(host: ip, port: 5555, timeoutSeconds: 1.2)
            if !reachable {
                let (btOk, btMsg) = await RouterlessBypassService.shared.setupAndConnectBluetoothPAN(
                    serial: serial,
                    preferredDeviceNames: [deviceName]
                )
                if btOk {
                    await MainActor.run {
                        onStatusUpdate?("Bluetooth PAN connected (\(btMsg))")
                    }
                    return
                }
                let (ok, msg) = await RouterlessBypassService.shared.enableHotspotOverUSBAndConnect(serial: serial)
                await MainActor.run {
                    onStatusUpdate?(ok ? "Direct Hotspot connected (\(msg))" : msg)
                }
            }
        }
    }

    /// Attempts fast TCP/IP reconnection to cached `KnownDevice` entries and active routerless links.
    public func attemptAutoReconnect(
        knownDevices: [KnownDevice],
        onConnected: @escaping @MainActor (String) -> Void
    ) {
        guard !isReconnecting else { return }
        guard Date().timeIntervalSince(lastReconnectAttempt) > 8.0 else { return }

        let autoDevices = knownDevices.filter { $0.autoConnect }
        isReconnecting = true
        lastReconnectAttempt = Date()

        Task {
            defer { Task { @MainActor in self.isReconnecting = false } }

            // 1. Try cached KnownDevice Wi-Fi endpoints (mDNS connect port first, then cached port / 5555)
            for device in autoDevices.prefix(3) {
                let targetPort = DiscoveryService.shared.getConnectPort(for: device.ipAddress) ?? device.port
                let endpoint = "\(device.ipAddress):\(targetPort)"
                if let out = try? await ADBService.shared.execute(arguments: ["connect", endpoint], timeoutSeconds: 2.0),
                   ADBService.isConnectSuccess(out) {
                    await MainActor.run {
                        onConnected("\(device.name) (\(endpoint))")
                    }
                    return
                }
            }

            // 2. Fallback to Bluetooth PAN (auto-configure & connect if peer-to-peer Wi-Fi failed)
            let (ok, msg) = await RouterlessBypassService.shared.setupAndConnectBluetoothPAN(
                preferredDeviceNames: autoDevices.map(\.name)
            )
            if ok {
                await MainActor.run {
                    onConnected("Bluetooth PAN (\(msg))")
                }
                return
            }
        }
    }
}
