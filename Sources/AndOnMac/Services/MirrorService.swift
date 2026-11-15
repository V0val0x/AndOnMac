import Foundation

public final class MirrorService: @unchecked Sendable {
    public static let shared = MirrorService()
    
    private var audioProcess: Process?
    private var recordingProcess: Process?
    private var activeDeviceSerial: String?
    public private(set) var lastRecordingURL: URL?

    public var isMirroring: Bool {
        return ScrcpyClient.shared.isConnected
    }

    public var isRecording: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return recordingProcess?.isRunning == true
    }
    
    public var scrcpyPath: String {
        if let binScrcpy = Bundle.main.resourceURL?.appendingPathComponent("bin/scrcpy").path,
           FileManager.default.isExecutableFile(atPath: binScrcpy) {
            return binScrcpy
        }
        if let bundled = Bundle.main.path(forResource: "scrcpy", ofType: nil) {
            return bundled
        }
        let candidates = [
            FileManager.default.currentDirectoryPath + "/dist/AndOnMac.app/Contents/Resources/bin/scrcpy",
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
                // Launch background headless audio forwarder AFTER video/control session has connected
                // so two concurrent scrcpy-server pushes/starts do not contend on the ADB transport.
                if forwardAudio && ScrcpyClient.shared.isConnected {
                    self.startBackgroundAudio(serial: device.id)
                }
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
    
    /// Kills scrcpy audio forwarders left over from previous runs / crashes of AndOnMac without blocking @MainActor
    public func killOrphanAudioProcesses(waitUntilExit: Bool = false) {
        let work = {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-f", "scrcpy .*--no-video --no-control"]
            pkill.standardOutput = FileHandle.nullDevice
            pkill.standardError = FileHandle.nullDevice
            try? pkill.run()
            if waitUntilExit {
                pkill.waitUntilExit()
            }
        }
        if waitUntilExit {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }
    
    private func startBackgroundAudio(serial: String) {
        stopBackgroundAudio()
        killOrphanAudioProcesses(waitUntilExit: true)
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
        if let serverPath = ScrcpyClient.resolveScrcpyServerPath() {
            env["SCRCPY_SERVER_PATH"] = serverPath
        }
        proc.environment = env
        
        // Suppress stdout/stderr without leaking unread Pipe file descriptors
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
        try? proc.run()
        self.audioProcess = proc
    }
    
    private func stopBackgroundAudio() {
        if let proc = audioProcess, proc.isRunning {
            proc.terminate()
        }
        audioProcess = nil
    }

    /// Starts headless MP4 screen recording via `scrcpy --no-video-playback --no-control --record=...`.
    @discardableResult
    public func startRecording(serial: String, maxSize: Int = 1440, bitRate: Int = 8_000_000) throws -> URL {
        stopRecording()
        let binary = scrcpyPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw NSError(domain: "MirrorService", code: 10, userInfo: [NSLocalizedDescriptionKey: "scrcpy binary not found"])
        }

        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let outputURL = moviesDir.appendingPathComponent("AndOnMac_\(formatter.string(from: Date())).mp4")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-s", serial,
            "--no-video-playback",
            "--no-control",
            "--no-window",
            "--max-size=\(maxSize)",
            "--video-bit-rate=\(bitRate)",
            "--record=\(outputURL.path)"
        ]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["ADB"] = ADBService.shared.adbPath
        env["SDL_MAC_BACKGROUND_APP"] = "1"
        env["SDL_VIDEO_MAC_BACKGROUND_APP"] = "1"
        if let serverPath = ScrcpyClient.resolveScrcpyServerPath() {
            env["SCRCPY_SERVER_PATH"] = serverPath
        }
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        stateLock.lock()
        recordingProcess = proc
        lastRecordingURL = outputURL
        stateLock.unlock()
        return outputURL
    }

    /// Stops active screen recording gracefully (`SIGINT` so MP4 moov atom is finalized).
    public func stopRecording() {
        stateLock.lock()
        let proc = recordingProcess
        recordingProcess = nil
        stateLock.unlock()
        if let proc, proc.isRunning {
            proc.interrupt()
        }
    }
}
