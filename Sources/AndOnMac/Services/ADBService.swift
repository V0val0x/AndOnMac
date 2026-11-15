import Foundation

public final class ADBService: @unchecked Sendable {
    public static let shared = ADBService()
    
    public var adbPath: String {
        // 1. Check embedded bundle Resources/bin/adb, then Resources/adb
        if let binAdb = Bundle.main.resourceURL?.appendingPathComponent("bin/adb").path,
           FileManager.default.isExecutableFile(atPath: binAdb) {
            return binAdb
        }
        if let bundledAdb = Bundle.main.path(forResource: "adb", ofType: nil) {
            return bundledAdb
        }
        // 2. Common Homebrew and system locations
        let candidates = [
            FileManager.default.currentDirectoryPath + "/dist/AndOnMac.app/Contents/Resources/bin/adb",
            FileManager.default.currentDirectoryPath + "/dist/AndOnMac.app/Contents/Resources/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "adb"
    }
    
    private init() {}

    /// Validates an ADB device serial or `host:port` target to prevent flag injection or malformed endpoints.
    public static func validateSerial(_ serial: String) -> Bool {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-[]")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validates a `host:port` TCP/TLS endpoint for `adb connect` / `adb pair`.
    public static func validateTargetEndpoint(_ endpoint: String) -> Bool {
        guard validateSerial(endpoint) else { return false }
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        return !parts[0].isEmpty
    }
    
    /// Executes an ADB command asynchronously with a strict timeout to prevent indefinite hangs
    @discardableResult
    public func execute(arguments: [String], timeoutSeconds: Double = 6.0) async throws -> String {
        if let sIdx = arguments.firstIndex(of: "-s"), sIdx + 1 < arguments.count {
            guard Self.validateSerial(arguments[sIdx + 1]) else {
                throw NSError(domain: "ADBService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid ADB device serial."])
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.adbPath)
                process.arguments = arguments
                
                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
                env["ADB_MDNS_OPENSCREEN"] = "1"
                process.environment = env
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                let lock = NSLock()
                var hasResumed = false
                
                // Watchdog timer
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    lock.lock()
                    defer { lock.unlock() }
                    if !hasResumed {
                        hasResumed = true
                        if process.isRunning {
                            process.terminate()
                        }
                        try? stdoutPipe.fileHandleForReading.close()
                        try? stderrPipe.fileHandleForReading.close()
                        continuation.resume(throwing: NSError(
                            domain: "ADBService",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: Self.timeoutErrorMessage(for: arguments, timeoutSeconds: timeoutSeconds)]
                        ))
                    }
                }
                timer.resume()
                
                do {
                    try process.run()
                    
                    var stdoutData = Data()
                    var stderrData = Data()
                    let readGroup = DispatchGroup()
                    
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    
                    readGroup.enter()
                    DispatchQueue.global().async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        readGroup.leave()
                    }
                    
                    process.waitUntilExit()
                    readGroup.wait()
                    
                    lock.lock()
                    defer { lock.unlock() }
                    timer.cancel()
                    
                    if !hasResumed {
                        hasResumed = true
                        let output = String(decoding: stdoutData, as: UTF8.self)
                        
                        if process.terminationStatus == 0 {
                            continuation.resume(returning: output)
                        } else {
                            let errStr = String(decoding: stderrData, as: UTF8.self)
                            continuation.resume(throwing: NSError(
                                domain: "ADBService",
                                code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: errStr.isEmpty ? output : errStr]
                            ))
                        }
                    }
                } catch {
                    lock.lock()
                    defer { lock.unlock() }
                    timer.cancel()
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    public static func timeoutErrorMessage(for arguments: [String], timeoutSeconds: Double) -> String {
        let secs = Int(timeoutSeconds)
        if arguments.contains("connect") || arguments.contains("pair") {
            return "Превышено время ожидания сети (\(secs) сек). Убедитесь, что Mac и телефон в одной сети Wi-Fi и роутер не блокирует соединение между устройствами (AP Client Isolation)."
        }
        return "Устройство не ответило вовремя (таймаут \(secs) сек). Проверьте экран телефона и кабель USB."
    }
    
    /// Extracts active Wireless Debugging TLS port (`tls_port=39787` or `tls_port: 39787`) from `dumpsys adb`
    public static func parseWirelessTlsPort(from dumpsysOutput: String) -> Int? {
        let pattern = "tls_port\\s*[=:]\\s*([0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(dumpsysOutput.startIndex..<dumpsysOutput.endIndex, in: dumpsysOutput)
        guard let match = regex.firstMatch(in: dumpsysOutput, options: [], range: nsRange),
              match.numberOfRanges >= 2,
              let portRange = Range(match.range(at: 1), in: dumpsysOutput),
              let port = Int(dumpsysOutput[portRange]),
              (1...65535).contains(port) else {
            return nil
        }
        return port
    }
    
    /// Parses Android power wakefulness and keyguard lock state from `dumpsys power` and `dumpsys window policy`
    public static func parsePowerAndLockState(powerDump: String, policyDump: String) -> (isScreenOff: Bool, isLocked: Bool) {
        let lowerPower = powerDump.lowercased()
        let isScreenOff = lowerPower.contains("mwakefulness=asleep") || lowerPower.contains("mwakefulness=dozing")
        let lowerPolicy = policyDump.lowercased()
        let isLocked = lowerPolicy.contains("showing=true") || lowerPolicy.contains("mdreaminglockscreen=true")
        return (isScreenOff, isLocked)
    }
    
    /// Queries whether the connected Android device currently has its screen off or keyguard locked
    public func fetchScreenAndLockState(serial: String) async -> (isScreenOff: Bool, isLocked: Bool) {
        async let powerTask = execute(
            arguments: ["-s", serial, "shell", "dumpsys power | grep -E 'mWakefulness='"],
            timeoutSeconds: 2.0
        )
        async let policyTask = execute(
            arguments: ["-s", serial, "shell", "dumpsys window policy | grep -E 'showing=|mDreamingLockscreen='"],
            timeoutSeconds: 2.0
        )
        let powerOut = (try? await powerTask) ?? ""
        let policyOut = (try? await policyTask) ?? ""
        return Self.parsePowerAndLockState(powerDump: powerOut, policyDump: policyOut)
    }
    
    /// Lists all connected Android devices with metadata
    public func listDevices() async -> [Device] {
        guard let output = try? await execute(arguments: ["devices", "-l"]) else {
            return []
        }
        
        var devices: [Device] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.starts(with: "List of devices") || trimmed.starts(with: "*") {
                continue
            }
            
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            
            let serial = parts[0]
            let rawState = parts[1]
            
            let state: DeviceState
            switch rawState {
            case "device": state = .ready
            case "unauthorized": state = .unauthorized
            default: state = .offline
            }
            
            var model = "Android"
            var product = ""
            for part in parts.dropFirst(2) {
                if part.starts(with: "model:") {
                    model = String(part.dropFirst(6))
                } else if part.starts(with: "product:") {
                    product = String(part.dropFirst(8))
                }
            }
            
            let isWifi = serial.contains(":") // IP:port
            let connType: ConnectionType = isWifi ? .wifi : .usb
            
            var device = Device(
                id: serial,
                model: model.isEmpty ? product : model,
                connectionType: connType,
                state: state
            )
            
            if isWifi, let colonIdx = serial.lastIndex(of: ":"),
               let port = Int(serial[serial.index(after: colonIdx)...]),
               (1...65535).contains(port) {
                device.wirelessPort = port
            }
            
            if state == .ready {
                // Enrich device info asynchronously
                if let (mfr, ver, batt, charging, ip, tlsPort) = try? await fetchDeviceDetails(serial: serial) {
                    device.manufacturer = mfr
                    device.androidVersion = ver
                    device.batteryLevel = batt
                    device.isCharging = charging
                    device.ipAddress = ip
                    if let tlsPort = tlsPort {
                        device.wirelessPort = tlsPort
                    }
                }
            }
            
            devices.append(device)
        }
        
        return devices
    }
    
    /// Fetches extended battery, OS version, network IP, and Wireless Debugging `tls_port` details
    private func fetchDeviceDetails(serial: String) async throws -> (String, String, Int?, Bool?, String?, Int?) {
        async let mfrTask = execute(arguments: ["-s", serial, "shell", "getprop", "ro.product.manufacturer"])
        async let verTask = execute(arguments: ["-s", serial, "shell", "getprop", "ro.build.version.release"])
        async let battTask = execute(arguments: ["-s", serial, "shell", "dumpsys", "battery"])
        async let ipTask = execute(arguments: ["-s", serial, "shell", "ip", "route"])
        async let adbDumpTask = execute(arguments: ["-s", serial, "shell", "dumpsys", "adb"])
        
        let mfr = (try? await mfrTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        let ver = (try? await verTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let battRaw = (try? await battTask) ?? ""
        let ipRaw = (try? await ipTask) ?? ""
        let adbDumpRaw = (try? await adbDumpTask) ?? ""
        
        // Parse battery
        var level: Int? = nil
        var isCharging: Bool? = nil
        for line in battRaw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "level:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count == 2 {
                    level = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            } else if trimmed.starts(with: "status:") {
                // 2 = Charging, 5 = Full
                let parts = trimmed.components(separatedBy: ":")
                if parts.count == 2, let status = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    isCharging = (status == 2 || status == 5)
                }
            }
        }
        
        // Parse Wi-Fi IP only from wlan interface lines (avoid cellular rmnet_data)
        var ipAddress: String? = nil
        for line in ipRaw.components(separatedBy: .newlines) where line.contains("wlan") {
            if let match = line.range(of: "src ([0-9\\.]+)", options: .regularExpression) {
                let matchedStr = String(line[match])
                ipAddress = matchedStr.replacingOccurrences(of: "src ", with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        let tlsPort = Self.parseWirelessTlsPort(from: adbDumpRaw)
        if let ip = ipAddress, let port = tlsPort {
            DiscoveryService.shared.registerConnectPort(for: ip, port: port)
        }
        
        return (mfr, ver, level, isCharging, ipAddress, tlsPort)
    }
    
    /// Verifies `adb connect` actually succeeded rather than returning "failed to connect" / "cannot connect"
    public static func isConnectSuccess(_ output: String) -> Bool {
        let lower = output.lowercased()
        return (lower.contains("connected to") || lower.contains("already connected"))
            && !lower.contains("failed")
            && !lower.contains("unable")
            && !lower.contains("cannot")
            && !lower.contains("refused")
            && !lower.contains("timed out")
    }
    
    /// Enable TCP/IP mode for wireless connection
    public func enableTcpIp(serial: String, port: Int = 5555) async throws -> String {
        return try await execute(arguments: ["-s", serial, "tcpip", String(port)])
    }
    
    /// Connect to a device wirelessly via IP:Port
    public func connectWifi(ip: String, port: Int = 5555) async throws -> String {
        return try await execute(arguments: ["connect", "\(ip):\(port)"])
    }
    
    /// Pair with device using Android 11+ Wireless Debugging code
    public func pairDevice(host: String, port: Int, code: String) async throws -> String {
        return try await execute(arguments: ["pair", "\(host):\(port)", code])
    }
    
    /// Parse `adb mdns services` to find dynamic connect port for an IP
    public func findMdnsConnectPort(for host: String) async -> Int? {
        guard let output = try? await execute(arguments: ["mdns", "services"], timeoutSeconds: 3.0) else {
            return nil
        }
        for line in output.components(separatedBy: .newlines) {
            if line.contains(host) && line.contains("_adb-tls-connect") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if let endpoint = parts.last(where: { $0.contains(":") }) {
                    let portStr = endpoint.components(separatedBy: ":").last ?? ""
                    if let port = Int(portStr) {
                        return port
                    }
                }
            }
        }
        return nil
    }
    
    /// Complete Pair and Connect sequence
    public func pairAndConnect(host: String, pairingPort: Int, code: String, userConnectPort: Int? = nil) async throws -> (success: Bool, message: String) {
        // Step 1: Pair
        let pairOutput = try await execute(arguments: ["pair", "\(host):\(pairingPort)", code], timeoutSeconds: 6.0)
        let isPaired = pairOutput.lowercased().contains("success") || pairOutput.lowercased().contains("paired")
        guard isPaired else {
            return (false, "Ошибка сопряжения: \(pairOutput)")
        }
        
        // Short pause for Android daemon to settle
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Step 2: Determine Connect Port
        var connectPortToUse: Int? = userConnectPort
        
        // Check Bonjour discovery cache
        if connectPortToUse == nil {
            connectPortToUse = DiscoveryService.shared.getConnectPort(for: host)
        }
        
        // Check ADB's own mDNS services
        if connectPortToUse == nil {
            connectPortToUse = await findMdnsConnectPort(for: host)
        }
        
        // Candidate ports to try
        var portsToTry: [Int] = []
        if let p = connectPortToUse {
            portsToTry.append(p)
        }
        if !portsToTry.contains(5555) {
            portsToTry.append(5555)
        }
        
        // Try connecting
        for port in portsToTry {
            if let connectOutput = try? await execute(arguments: ["connect", "\(host):\(port)"], timeoutSeconds: 4.0),
               Self.isConnectSuccess(connectOutput) {
                DiscoveryService.shared.registerConnectPort(for: host, port: port)
                return (true, "Успешно подключено к \(host):\(port)")
            }
        }
        
        // Pairing succeeded, but automatic connect did not complete yet — keep pairing sheet open so user can enter connect port!
        return (false, "Сопряжение выполнено! Теперь укажите порт подключения из главного экрана «Беспроводная отладка» в поле выше и нажмите «Подключить телефон».")
    }
    
    /// Switches a USB-connected device to Wi-Fi mode (trying active `adb_wifi` `tls_port` first, then TCP/IP `port`)
    public func switchToWireless(serial: String, ip: String, port: Int = 5555) async -> (success: Bool, message: String) {
        // 1. Check if Android 11+ Wireless Debugging (`adb_wifi`) already has an active `tls_port` in `dumpsys adb`
        var activeTlsPort: Int? = nil
        if let adbDump = try? await execute(arguments: ["-s", serial, "shell", "dumpsys", "adb"], timeoutSeconds: 3.0),
           let tlsPort = Self.parseWirelessTlsPort(from: adbDump) {
            activeTlsPort = tlsPort
            DiscoveryService.shared.registerConnectPort(for: ip, port: tlsPort)
        } else if let cachedPort = DiscoveryService.shared.getConnectPort(for: ip) {
            activeTlsPort = cachedPort
        }
        
        if let tlsPort = activeTlsPort {
            if let output = try? await execute(arguments: ["connect", "\(ip):\(tlsPort)"], timeoutSeconds: 4.0),
               Self.isConnectSuccess(output) {
                return (true, "Wi-Fi режим активирован (\(ip):\(tlsPort))! Теперь можно отключить кабель.")
            }
        }
        
        // 2. Fallback: Enable TCP/IP port on device over USB and test reachability from Mac
        do {
            _ = try await enableTcpIp(serial: serial, port: port)
        } catch {
            return (false, "Не удалось открыть порт \(port) по USB: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        
        if let output = try? await execute(arguments: ["connect", "\(ip):\(port)"], timeoutSeconds: 4.0),
           Self.isConnectSuccess(output) {
            return (true, "Wi-Fi режим активирован (\(ip):\(port))! Теперь можно отключить кабель.")
        }
        
        return (false, "Порт \(port) открыт на телефоне (\(ip)), но Mac не может достучаться до устройства по Wi-Fi (возможна изоляция клиентов AP Client Isolation в сети Wi-Fi). Оставайтесь на кабеле USB или используйте общую домашнюю сеть / точку доступа.")
    }
    
    /// Connect to an already-paired device (Android 11+ Wireless Debugging or TCP/IP 5555)
    public func connectPairedDevice(host: String, port: Int) async throws -> (success: Bool, message: String) {
        let output = try await execute(arguments: ["connect", "\(host):\(port)"], timeoutSeconds: 5.0)
        let success = Self.isConnectSuccess(output)
        if success {
            DiscoveryService.shared.registerConnectPort(for: host, port: port)
        }
        return (success, success ? "Успешно подключено к \(host):\(port)" : Self.formatConnectFailureMessage(host: host, port: port, rawOutput: output))
    }

    /// Formats a clear diagnostic message when `adb connect` fails (e.g. unpaired device or hotspot client isolation).
    public static func formatConnectFailureMessage(host: String, port: Int, rawOutput: String, lang: AppLanguage? = nil) -> String {
        let cleaned = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if lower.contains("failed to connect") || lower.contains("connection refused") || lower.contains("cannot connect") || lower.contains("timed out") {
            return L10n.tr(
                "Не удалось подключиться к \(host):\(port).\nЕсли это новый телефон — сначала выполните «Сопряжение по PIN» (вкладка Wi-Fi).\nЕсли Mac подключён к точке доступа другого телефона, Android-хотспот часто блокирует прямое соединение между клиентами — используйте общую сеть Wi-Fi или кабель USB.",
                "Could not connect to \(host):\(port).\nIf this is a new phone, complete \"PIN Pairing\" in the Wi-Fi tab first.\nIf your Mac is on another phone's hotspot, Android hotspots often block client-to-client connections — use a shared Wi-Fi router or USB cable.",
                lang: lang
            )
        }
        return cleaned.isEmpty ? L10n.tr("Не удалось подключиться к \(host):\(port)", "Could not connect to \(host):\(port)", lang: lang) : cleaned
    }
    
    /// Disables stale Wi-Fi connections, resets USB mode, and restarts the local ADB server
    public func resetUSBAndRestartServer() async {
        _ = try? await execute(arguments: ["disconnect"], timeoutSeconds: 3.0)
        _ = try? await execute(arguments: ["usb"], timeoutSeconds: 3.0)
        _ = try? await execute(arguments: ["kill-server"], timeoutSeconds: 3.0)
        _ = try? await execute(arguments: ["start-server"], timeoutSeconds: 5.0)
    }
    
    /// Push a local file to the device's Downloads directory (Drag and Drop support)
    public func pushFile(serial: String, localPath: String, remoteDir: String = "/sdcard/Download/") async throws -> String {
        return try await execute(arguments: ["-s", serial, "push", localPath, remoteDir])
    }
    
    /// Returns Mac's current Wi-Fi IP address in the local network
    public func getMacLocalIP() -> String {
        return getMacNetworkInfo().ip
    }
    
    /// Returns Mac's Wi-Fi network information (IP, netmask, and subnet prefix)
    public func getMacNetworkInfo() -> (ip: String, netmask: String, prefix: String) {
        var ip = "127.0.0.1"
        var netmask = "255.255.255.0"
        var prefix = "10.36."
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (ip, netmask, prefix) }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    ip = String(cString: hostname)
                    
                    if let netmaskPtr = interface.ifa_netmask {
                        var maskname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(netmaskPtr, socklen_t(netmaskPtr.pointee.sa_len),
                                    &maskname, socklen_t(maskname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        netmask = String(cString: maskname)
                    }
                    
                    let parts = ip.components(separatedBy: ".")
                    if parts.count >= 2 {
                        if netmask == "255.255.255.0" && parts.count == 4 {
                            prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
                        } else {
                            prefix = "\(parts[0]).\(parts[1])."
                        }
                    }
                    break
                }
            }
        }
        return (ip, netmask, prefix)
    }
    
    /// Launch an application by package name (e.g. when user clicks a notification)
    public func launchApp(serial: String, packageName: String) async throws {
        _ = try await execute(arguments: ["-s", serial, "shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"])
    }
    
    // MARK: - Navigation & Gesture Actions (1-in-1 with macOS Sequoia iPhone Mirroring)
    
    /// Trigger Home (Cmd+1 / Click on Home Bar)
    public func sendHome(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_HOME"])
    }
    
    /// Trigger Back (Cmd+Backspace / Esc / Right-click)
    public func sendBack(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_BACK"])
    }
    
    /// Trigger App Switcher / Recent Apps (Cmd+2 / Swipe up and hold)
    public func sendAppSwitch(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_APP_SWITCH"])
    }
    
    /// Expand Notification Shade (Cmd+3)
    public func sendNotifications(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "cmd", "statusbar", "expand-notifications"])
    }
    
    /// Toggle Power / Sleep / Wake
    public func sendPower(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_POWER"])
    }
    
    /// Unlock screen (swipe up from lockscreen)
    public func unlockScreen(serial: String) async {
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        _ = try? await execute(arguments: ["-s", serial, "shell", "input", "swipe", "500", "1800", "500", "400", "200"])
    }
    
    /// Simulate swipe gesture
    public func sendSwipe(serial: String, fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int = 250) async {
        _ = try? await execute(arguments: [
            "-s", serial, "shell", "input", "swipe",
            String(fromX), String(fromY), String(toX), String(toY), String(durationMs)
        ])
    }
}
