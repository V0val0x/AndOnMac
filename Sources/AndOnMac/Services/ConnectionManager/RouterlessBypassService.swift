import Foundation
import Network
import Darwin

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
        } else {
            isRouterIsolationDetected = true
            isolatedTarget = key
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
