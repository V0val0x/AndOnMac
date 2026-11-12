import Foundation

public final class MirrorService: @unchecked Sendable {
    public static let shared = MirrorService()
    
    private var currentProcess: Process?
    private var activeDeviceSerial: String?
    
    public var isMirroring: Bool {
        return currentProcess?.isRunning == true
    }
    
    public var scrcpyPath: String {
        // 1. Check embedded bundle resource
        if let bundled = Bundle.main.path(forResource: "scrcpy", ofType: nil) {
            return bundled
        }
        // 2. Check Homebrew or standard locations
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "scrcpy"
    }
    
    private init() {}
    
    /// Starts mirroring with native Apple-like flags
    public func startMirroring(
        for device: Device,
        turnScreenOff: Bool = true,
        forwardAudio: Bool = true,
        stayAwake: Bool = true,
        maxFps: Int = 60,
        bitRate: Int = 8_000_000,
        onTermination: (@Sendable () -> Void)? = nil
    ) throws {
        stopMirroring()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpyPath)
        
        var args = [
            "-s", device.id,
            "--window-title", "AndOnMac — \(device.displayName)",
            "--max-fps", String(maxFps),
            "--video-bit-rate", String(bitRate),
            "--prefer-text"
        ]
        
        if turnScreenOff {
            args.append("--turn-screen-off")
        }
        if stayAwake {
            args.append("--stay-awake")
        }
        if !forwardAudio {
            args.append("--no-audio")
        }
        
        // Environment with adb path
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + existingPath
        process.environment = env
        process.arguments = args
        
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.activeDeviceSerial = nil
                self?.currentProcess = nil
                onTermination?()
            }
        }
        
        try process.run()
        self.currentProcess = process
        self.activeDeviceSerial = device.id
    }
    
    /// Stops the active mirroring session
    public func stopMirroring() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
        currentProcess = nil
        activeDeviceSerial = nil
    }
}
