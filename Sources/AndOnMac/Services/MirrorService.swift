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
        // Detach the previous session's callback first so tearing it down
        // cannot fire a stale "session ended" into the new session.
        ScrcpyClient.shared.onSessionStateChanged = nil
        stopMirroring()
        self.activeDeviceSerial = device.id
        setStarting(true)
        
        ScrcpyClient.shared.onSessionStateChanged = { [weak self] active in
            self?.setStarting(false)
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
                    bitRate: bitRate,
                    turnScreenOff: turnScreenOff,
                    stayAwake: stayAwake
                )
            } catch {
                print("Failed to start ScrcpyClient: \(error)")
                self.setStarting(false)
                // Tear down the half-started server/forward so the next attempt starts clean
                ScrcpyClient.shared.onSessionStateChanged = nil
                ScrcpyClient.shared.stop()
                self.stopBackgroundAudio()
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
        setStarting(false)
        ScrcpyClient.shared.stop()
        stopBackgroundAudio()
        activeDeviceSerial = nil
    }
    
    // MARK: - Starting state (thread-safe)
    private let stateLock = NSLock()
    private var _isStarting = false
    
    /// True between `startMirroring` and the first session state callback (socket handshake in progress)
    public var isStarting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isStarting
    }
    
    private func setStarting(_ value: Bool) {
        stateLock.lock(); _isStarting = value; stateLock.unlock()
    }
    
    /// Kills scrcpy audio forwarders left over from previous runs / crashes of AndOnMac
    public func killOrphanAudioProcesses() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "scrcpy .*--no-video --no-control"]
        pkill.standardOutput = Pipe()
        pkill.standardError = Pipe()
        try? pkill.run()
        pkill.waitUntilExit()
    }
    
    private func startBackgroundAudio(serial: String) {
        stopBackgroundAudio()
        killOrphanAudioProcesses()
        let binary = scrcpyPath
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-s", serial,
            "--no-video",
            "--no-control",
            "--no-window",          // never create an SDL window
            "--audio-buffer=40"
        ]
        
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["ADB"] = ADBService.shared.adbPath
        // Run SDL as a background (accessory) app: no Dock icon, no menu bar takeover
        env["SDL_MAC_BACKGROUND_APP"] = "1"
        env["SDL_VIDEO_MAC_BACKGROUND_APP"] = "1"
        if let serverPath = Bundle.main.path(forResource: "scrcpy-server", ofType: nil) {
            env["SCRCPY_SERVER_PATH"] = serverPath
        }
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
