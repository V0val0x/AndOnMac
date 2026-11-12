import Foundation

public final class ADBService: @unchecked Sendable {
    public static let shared = ADBService()
    
    public var adbPath: String {
        // 1. Check embedded bundle resource
        if let bundledAdb = Bundle.main.path(forResource: "adb", ofType: nil) {
            return bundledAdb
        }
        // 2. Common Homebrew and system locations
        let candidates = [
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
    
    /// Executes an ADB command asynchronously with a strict timeout to prevent indefinite hangs
    @discardableResult
    public func execute(arguments: [String], timeoutSeconds: Double = 6.0) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.adbPath)
                process.arguments = arguments
                
                var env = ProcessInfo.processInfo.environment
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
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
                        continuation.resume(throwing: NSError(
                            domain: "ADBService",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Устройство не ответило вовремя (таймаут \(Int(timeoutSeconds)) сек). Проверьте экран телефона."]
                        ))
                    }
                }
                timer.resume()
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    lock.lock()
                    defer { lock.unlock() }
                    timer.cancel()
                    
                    if !hasResumed {
                        hasResumed = true
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        
                        if process.terminationStatus == 0 {
                            continuation.resume(returning: output)
                        } else {
                            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                            let errStr = String(data: errData, encoding: .utf8) ?? ""
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
            
            if state == .ready {
                // Enrich device info asynchronously
                if let (mfr, ver, batt, charging, ip) = try? await fetchDeviceDetails(serial: serial) {
                    device.manufacturer = mfr
                    device.androidVersion = ver
                    device.batteryLevel = batt
                    device.isCharging = charging
                    device.ipAddress = ip
                }
            }
            
            devices.append(device)
        }
        
        return devices
    }
    
    /// Fetches extended battery, OS version, and network IP details
    private func fetchDeviceDetails(serial: String) async throws -> (String, String, Int?, Bool?, String?) {
        async let mfrTask = execute(arguments: ["-s", serial, "shell", "getprop", "ro.product.manufacturer"])
        async let verTask = execute(arguments: ["-s", serial, "shell", "getprop", "ro.build.version.release"])
        async let battTask = execute(arguments: ["-s", serial, "shell", "dumpsys", "battery"])
        async let ipTask = execute(arguments: ["-s", serial, "shell", "ip", "route"])
        
        let mfr = (try? await mfrTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
        let ver = (try? await verTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let battRaw = (try? await battTask) ?? ""
        let ipRaw = (try? await ipTask) ?? ""
        
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
        
        // Parse IP from route: e.g. "192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.45"
        var ipAddress: String? = nil
        if let match = ipRaw.range(of: "src ([0-9\\.]+)", options: .regularExpression) {
            let matchedStr = String(ipRaw[match])
            ipAddress = matchedStr.replacingOccurrences(of: "src ", with: "").trimmingCharacters(in: .whitespaces)
        }
        
        return (mfr, ver, level, isCharging, ipAddress)
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
    
    /// Push a local file to the device's Downloads directory (Drag and Drop support)
    public func pushFile(serial: String, localPath: String, remoteDir: String = "/sdcard/Download/") async throws -> String {
        return try await execute(arguments: ["-s", serial, "push", localPath, remoteDir])
    }
    
    /// Returns Mac's current Wi-Fi IP address in the local network
    public func getMacLocalIP() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        
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
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
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
