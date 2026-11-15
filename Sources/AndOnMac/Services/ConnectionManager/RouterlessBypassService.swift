import Foundation
import Network
import Darwin
import IOBluetooth
import AppKit

/// Detects AP/Client Isolation on public/university/corporate Wi-Fi and provides
/// 1-click routerless Direct Hotspot and Bluetooth PAN ADB bypasses.
@MainActor
public final class RouterlessBypassService: ObservableObject {
    public static let shared = RouterlessBypassService()

    public enum BypassTransport: String, Sendable {
        case directHotspot = "Direct Hotspot"
        case bluetoothPAN = "Bluetooth PAN"
    }

    @Published public private(set) var isRouterIsolationDetected: Bool = false
    @Published public private(set) var isolatedTarget: String? = nil
    @Published public private(set) var detectedHotspotGateway: String? = nil
    @Published public private(set) var isBluetoothPANAvailable: Bool = false
    @Published public private(set) var activeDirectTransport: BypassTransport? = nil

    private var lastProbedKey: String?
    private var lastProbeTime: Date = .distantPast
    private var hasAttemptedAutoBluetoothPAN: Bool = false

    private init() {}

    /// Parses the default IPv4 gateway from `netstat -rn -f inet` output (preferring `en0` / `en*`).
    public nonisolated static func parseDefaultGateway(fromNetstatOutput output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let cols = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 4, cols[0] == "default" else { continue }
            let gateway = cols[1]
            let iface = cols.last ?? ""
            if gateway.contains("."), !gateway.hasPrefix("127."), iface.hasPrefix("en") || iface.hasPrefix("bridge") {
                return gateway
            }
        }
        return nil
    }

    /// Checks whether any local interface IPv4 address belongs to Android's Bluetooth PAN subnet (`192.168.44.0/24`).
    public nonisolated static func hasBluetoothPANSubnet(inAddresses addresses: [String]) -> Bool {
        addresses.contains { $0.hasPrefix("192.168.44.") }
    }

    /// Enumerates active IPv4 addresses on `en*` / `bridge*` interfaces via `getifaddrs`.
    public nonisolated static func localInterfaceIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            if isUp, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let res = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if res == 0 {
                        result.append(String(cString: hostBuffer))
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }

    /// Non-blocking TCP reachability probe using `NWConnection`.
    /// Returns `true` if TCP handshake succeeds, `false` on timeout/failure.
    public nonisolated static func probeTCPReachability(host: String, port: Int, timeoutSeconds: Double = 1.2) async -> Bool {
        guard !host.isEmpty, (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        final class ProbeFlag: @unchecked Sendable {
            var finished = false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.andonmac.tcpprobe")
            let lock = NSLock()
            let stateFlag = ProbeFlag()

            let finish: @Sendable (Bool) -> Void = { reachable in
                lock.lock()
                defer { lock.unlock() }
                guard !stateFlag.finished else { return }
                stateFlag.finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(false)
            }
        }
    }

    /// Evaluates whether an mDNS-discovered device is blocked by AP/Client Isolation.
    public func checkReachabilityIfNeeded(host: String, port: Int) async {
        let key = "\(host):\(port)"
        if lastProbedKey == key, Date().timeIntervalSince(lastProbeTime) < 12.0 {
            return
        }
        lastProbedKey = key
        lastProbeTime = Date()

        refreshDirectLinkCapabilities()
        let reachable = await Self.probeTCPReachability(host: host, port: port, timeoutSeconds: 1.2)
        if reachable {
            isRouterIsolationDetected = false
            isolatedTarget = nil
            hasAttemptedAutoBluetoothPAN = false
        } else {
            isRouterIsolationDetected = true
            isolatedTarget = key
            if !hasAttemptedAutoBluetoothPAN {
                hasAttemptedAutoBluetoothPAN = true
                _ = await setupAndConnectBluetoothPAN(preferredDeviceNames: [])
            }
        }
    }

    public func clearIsolationWarning() {
        isRouterIsolationDetected = false
        isolatedTarget = nil
    }

    public func refreshDirectLinkCapabilities() {
        let localIPs = Self.localInterfaceIPv4Addresses()
        isBluetoothPANAvailable = Self.hasBluetoothPANSubnet(inAddresses: localIPs)
        detectedHotspotGateway = Self.resolveHotspotGatewaySync()
    }

    /// Attempts 1-click Direct Hotspot ADB connection (`<gateway_ip>:5555` or live mDNS connect port).
    public func connectDirectHotspot() async -> (Bool, String) {
        let gateway = Self.resolveHotspotGatewaySync()
        self.detectedHotspotGateway = gateway
        guard let ip = gateway, !ip.isEmpty else {
            return (false, "Hotspot gateway IP not found. Connect Mac to phone's Wi-Fi Hotspot first.")
        }

        await DiscoveryService.shared.pollAdbMdns()
        var candidatePorts: [Int] = [5555]
        if let mdnsPort = DiscoveryService.shared.getConnectPort(for: ip), mdnsPort != 5555 {
            candidatePorts.insert(mdnsPort, at: 0)
        }

        for port in candidatePorts {
            let endpoint = "\(ip):\(port)"
            if let out = try? await ADBService.shared.execute(arguments: ["connect", endpoint], timeoutSeconds: 3.0),
               ADBService.isConnectSuccess(out) {
                isRouterIsolationDetected = false
                activeDirectTransport = .directHotspot
                return (true, endpoint)
            }
        }
        return (false, "Hotspot gateway \(ip) unreachable. Connect Mac to your phone's Wi-Fi Hotspot and enable Wireless Debugging (or plug USB once).")
    }

    /// Automatically configures and connects Bluetooth PAN:
    /// 1. If a USB `serial` is provided, enables Bluetooth tethering on Android via ADB (`cmd tethering start bluetooth`).
    /// 2. Connects to the paired Android phone via `IOBluetoothDevice` and starts macOS `Bluetooth PAN` service if available.
    /// 3. Connects `adb connect 192.168.44.1:<port>`.
    public func setupAndConnectBluetoothPAN(
        serial: String? = nil,
        preferredDeviceNames: [String] = [],
        openSettingsIfUnavailable: Bool = false
    ) async -> (Bool, String) {
        // Step 1: If USB is available, ask Android to enable Bluetooth tethering
        if let serial = serial, !serial.isEmpty {
            _ = try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "cmd", "tethering", "start", "bluetooth"],
                timeoutSeconds: 3.0
            )
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Step 2: If 192.168.44.x isn't up yet, bring up paired Android Bluetooth device + PAN service on macOS
        if !Self.hasBluetoothPANSubnet(inAddresses: Self.localInterfaceIPv4Addresses()) {
            Self.bringUpMacBluetoothPAN(preferredDeviceNames: preferredDeviceNames)
            // Poll briefly (up to 2.5s) for macOS to assign 192.168.44.x
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Self.hasBluetoothPANSubnet(inAddresses: Self.localInterfaceIPv4Addresses()) {
                    break
                }
            }
        }

        let result = await connectBluetoothPAN()
        if !result.0 && openSettingsIfUnavailable {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        return result
    }

    private nonisolated static func bringUpMacBluetoothPAN(preferredDeviceNames: [String]) {
        // Connect paired phone over IOBluetooth if not already connected
        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            let target = paired.first(where: { dev in
                guard let name = dev.name else { return false }
                if preferredDeviceNames.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    return true
                }
                // Major Device Class 0x02 = Phone
                return ((dev.classOfDevice >> 8) & 0x1F) == 0x02
            })
            if let phone = target, !phone.isConnected() {
                _ = phone.openConnection()
            }
        }

        // Trigger macOS Network service "Bluetooth PAN" if present
        _ = runQuickCommand("/usr/sbin/networksetup", arguments: ["-connectpppoeservice", "Bluetooth PAN"])
        _ = runQuickCommand("/usr/sbin/scutil", arguments: ["--nc", "start", "Bluetooth PAN"])
    }

    /// Attempts routerless Bluetooth PAN ADB connection (`192.168.44.1:5555` or live mDNS connect port).
    public func connectBluetoothPAN() async -> (Bool, String) {
        let localIPs = Self.localInterfaceIPv4Addresses()
        guard Self.hasBluetoothPANSubnet(inAddresses: localIPs) else {
            return (false, "Bluetooth PAN not connected. Enable Bluetooth Tethering on Android and connect Mac to phone in System Settings → Bluetooth.")
        }

        await DiscoveryService.shared.pollAdbMdns()
        var candidatePorts: [Int] = [5555]
        if let mdnsPort = DiscoveryService.shared.getConnectPort(for: "192.168.44.1"), mdnsPort != 5555 {
            candidatePorts.insert(mdnsPort, at: 0)
        }

        for port in candidatePorts {
            let endpoint = "192.168.44.1:\(port)"
            if let out = try? await ADBService.shared.execute(arguments: ["connect", endpoint], timeoutSeconds: 3.0),
               ADBService.isConnectSuccess(out) {
                isRouterIsolationDetected = false
                activeDirectTransport = .bluetoothPAN
                return (true, endpoint)
            }
        }
        return (false, "Bluetooth PAN active, but ADB port closed on 192.168.44.1. Enable Wireless Debugging or plug USB once.")
    }

    /// Attempts to start a Wi-Fi Hotspot on the USB-connected Android device, join it from Mac (`en0`),
    /// and connect `adb connect <gateway>:5555`. Falls back to opening Android Tether Settings if OEM restricts `cmd wifi start-softap`.
    public func enableHotspotOverUSBAndConnect(serial: String) async -> (Bool, String) {
        let ssid = "AndOnMac-Direct"
        let password = Self.generateHotspotPassphrase()

        // Try Android 11+ `cmd wifi start-softap` via ADB shell
        let startOut = (try? await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "cmd", "wifi", "start-softap", ssid, "wpa2", password],
            timeoutSeconds: 4.0
        )) ?? ""

        let lower = startOut.lowercased()
        if lower.contains("securityexception") || lower.contains("permission") || lower.contains("error") || lower.contains("unknown command") {
            // Fallback: open Android Hotspot & Tethering settings on the phone
            _ = try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "am", "start", "-a", "android.settings.TETHER_SETTINGS"],
                timeoutSeconds: 3.0
            )
            isRouterIsolationDetected = true
            return (false, "Hotspot settings opened on phone. Enable Hotspot, connect Mac Wi-Fi, then click Direct Hotspot.")
        }

        // Wait for SoftAP to initialize
        try? await Task.sleep(nanoseconds: 1_800_000_000)

        // Join the phone's Hotspot from Mac's Wi-Fi interface (en0)
        _ = Self.runQuickCommand("/usr/sbin/networksetup", arguments: ["-setairportnetwork", "en0", ssid, password])
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        return await connectDirectHotspot()
    }

    private nonisolated static func generateHotspotPassphrase() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement() ?? "a" })
    }

    private nonisolated static func resolveHotspotGatewaySync() -> String? {
        if let ipconfigOut = runQuickCommand("/usr/sbin/ipconfig", arguments: ["getoption", "en0", "router"]),
           !ipconfigOut.isEmpty, ipconfigOut.contains(".") {
            return ipconfigOut
        }
        if let netstatOut = runQuickCommand("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"]) {
            return parseDefaultGateway(fromNetstatOutput: netstatOut)
        }
        return nil
    }

    private nonisolated static func runQuickCommand(_ path: String, arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
