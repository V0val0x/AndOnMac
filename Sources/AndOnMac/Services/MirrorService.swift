import Foundation

public final class MirrorService: @unchecked Sendable {
    public static let shared = MirrorService()
    
    private var audioProcess: Process?
    private var activeDeviceSerial: String?
    
    public var isMirroring: Bool {
        return ScrcpyClient.shared.isConnected
    }
    
    public var scrcpyPath: String {
        if let bundled = Bundle.main.path(forResource: "scrcpy", ofType: nil) {
            return bundled
        }
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
    
    /// Starts embedded native mirroring inside AndOnMac window
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
        self.activeDeviceSerial = device.id
        
        ScrcpyClient.shared.onSessionStateChanged = { active in
            if !active {
                DispatchQueue.main.async {
                    onTermination?()
                }
            }
        }
        
        Task {
            do {
                try await ScrcpyClient.shared.start(
                    serial: device.id,
                    maxSize: 1440,
                    maxFps: maxFps,
                    bitRate: bitRate
                )
            } catch {
                print("Failed to start ScrcpyClient: \(error)")
                DispatchQueue.main.async {
                    onTermination?()
                }
            }
        }
        
        // Background headless audio forwarder if audio enabled
        if forwardAudio {
            startBackgroundAudio(serial: device.id)
        }
    }
    
    /// Stops the active mirroring session
    public func stopMirroring() {
        ScrcpyClient.shared.stop()
        stopBackgroundAudio()
        activeDeviceSerial = nil
    }
    
    private func startBackgroundAudio(serial: String) {
        let binary = scrcpyPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-s", serial,
            "--no-video",
            "--no-control",
            "--audio-buffer=40"
        ]
        
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["ADB"] = ADBService.shared.adbPath
        proc.environment = env
        
        // Suppress stdout/stderr
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        
        try? proc.run()
        self.audioProcess = proc
    }
    
    private func stopBackgroundAudio() {
        if let proc = audioProcess, proc.isRunning {
            proc.terminate()
        }
        audioProcess = nil
    }
}
