import Foundation
import Darwin

public final class MirrorService: @unchecked Sendable {
    public static let shared = MirrorService()
    
    private var audioProcess: Process?
    private var recordingProcess: Process?
    private var activeDeviceSerial: String?
    private let audioLifecycleLock = NSLock()
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
    
    /// Starts embedded native mirroring inside AndOnMac window with 120Hz HEVC + automatic H.264 fallback.
    public func startMirroring(
        for device: Device,
        turnScreenOff: Bool = true,
        forwardAudio: Bool = true,
        stayAwake: Bool = true,
        maxFps: Int = 120,
        bitRate: Int = 16_000_000,
        maxSize: Int = 1440,
        videoCodec: ScrcpyVideoCodec = .h265,
        onTermination: (@Sendable () -> Void)? = nil
    ) throws {
        // Detach the previous session's callback first so tearing it down
        // cannot fire a stale "session ended" into the new session.
        ScrcpyClient.shared.onSessionStateChanged = nil
        stopMirroring()
        self.activeDeviceSerial = device.id
        setStarting(true)

        awaitMainBeginSession(device: device, codec: videoCodec == .h265 ? .hevc : .h264)
        
        ScrcpyClient.shared.onSessionStateChanged = { [weak self] active in
            self?.setStarting(false)
            if !active {
                Task { @MainActor in
                    PerformanceEngine.shared.endMirroringSession()
                }
                DispatchQueue.main.async {
                    onTermination?()
                }
            }
        }
        
        Task {
            do {
                try await ScrcpyClient.shared.start(
                    serial: device.id,
                    maxSize: maxSize,
                    maxFps: maxFps,
                    bitRate: bitRate,
                    videoCodec: videoCodec,
                    turnScreenOff: turnScreenOff,
                    stayAwake: stayAwake
                )

                // If HEVC was selected, verify at least one decoded frame arrives within 2.5s;
                // otherwise fall back automatically to H.264 for SoCs lacking 120fps HEVC hardware encoding.
                if videoCodec == .h265 {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if ScrcpyClient.shared.isConnected && !ScrcpyClient.shared.hasDecodedAnyFrame {
                        ScrcpyClient.shared.onSessionStateChanged = nil
                        ScrcpyClient.shared.stop()
                        try await ScrcpyClient.shared.start(
                            serial: device.id,
                            maxSize: maxSize,
                            maxFps: maxFps,
                            bitRate: bitRate,
                            videoCodec: .h264,
                            turnScreenOff: turnScreenOff,
                            stayAwake: stayAwake
                        )
                        await MainActor.run {
                            PerformanceEngine.shared.updateActiveCodec(.h264)
                        }
                        ScrcpyClient.shared.onSessionStateChanged = { [weak self] active in
                            self?.setStarting(false)
                            if !active {
                                Task { @MainActor in
                                    PerformanceEngine.shared.endMirroringSession()
                                }
                                DispatchQueue.main.async {
                                    onTermination?()
                                }
                            }
                        }
                    }
                }

                // Launch background headless audio forwarder AFTER video/control session has connected
                // so two concurrent scrcpy-server pushes/starts do not contend on the ADB transport.
                if forwardAudio && ScrcpyClient.shared.isConnected {
                    self.startBackgroundAudio(serial: device.id)
                }
            } catch {
                if videoCodec == .h265 {
                    do {
                        try await ScrcpyClient.shared.start(
                            serial: device.id,
                            maxSize: maxSize,
                            maxFps: maxFps,
                            bitRate: bitRate,
                            videoCodec: .h264,
                            turnScreenOff: turnScreenOff,
                            stayAwake: stayAwake
                        )
                        await MainActor.run {
                            PerformanceEngine.shared.updateActiveCodec(.h264)
                        }
                        if forwardAudio && ScrcpyClient.shared.isConnected {
                            self.startBackgroundAudio(serial: device.id)
                        }
                        return
                    } catch {
                        // Fall through to cleanup
                    }
                }
                print("Failed to start ScrcpyClient: \(error)")
                self.setStarting(false)
                // Tear down the half-started server/forward so the next attempt starts clean
                ScrcpyClient.shared.onSessionStateChanged = nil
                ScrcpyClient.shared.stop()
                self.stopBackgroundAudio()
                Task { @MainActor in
                    PerformanceEngine.shared.endMirroringSession()
                }
                DispatchQueue.main.async {
                    onTermination?()
                }
            }
        }
    }

    private func awaitMainBeginSession(device: Device, codec: PerformanceEngine.CodecLabel) {
        Task { @MainActor in
            PerformanceEngine.shared.beginMirroringSession(device: device, codec: codec)
        }
    }
    
    /// Stops the active mirroring session
    public func stopMirroring() {
        setStarting(false)
        ScrcpyClient.shared.stop()
        stopBackgroundAudio()
        activeDeviceSerial = nil
        Task { @MainActor in
            PerformanceEngine.shared.endMirroringSession()
        }
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
            self.audioLifecycleLock.lock()
            defer { self.audioLifecycleLock.unlock() }
            self.killOrphanAudioProcessesLocked()
        }
        if waitUntilExit {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    private func killOrphanAudioProcessesLocked() {
        let pgrep = Process()
        let outPipe = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "scrcpy .*--no-video --no-control"]
        pgrep.standardOutput = outPipe
        pgrep.standardError = FileHandle.nullDevice
        let trackedId = ProcessLifecycleManager.shared.register(pgrep, tag: "cleanup-pgrep")
        let timeoutItem = DispatchWorkItem {
            if pgrep.isRunning {
                ProcessLifecycleManager.shared.terminateProcess(pgrep, gracePeriodMs: 150)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0, execute: timeoutItem)
        defer {
            timeoutItem.cancel()
            ProcessLifecycleManager.shared.unregister(trackedId)
        }
        do {
            try pgrep.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if pgrep.isRunning {
                pgrep.waitUntilExit()
            }
            guard let output = String(data: data, encoding: .utf8) else { return }
            stateLock.lock()
            let activePid = (audioProcess?.isRunning == true) ? audioProcess?.processIdentifier : nil
            stateLock.unlock()
            for token in output.split(whereSeparator: \.isNewline) {
                if let pid = Int32(token.trimmingCharacters(in: .whitespaces)),
                   pid > 1,
                   pid != activePid {
                    Darwin.kill(pid, SIGTERM)
                }
            }
        } catch {
            // Best-effort orphan cleanup
        }
    }

    /// Toggles audio forwarding on an active mirroring session without restarting the video stream.
    public func setAudioForwardingEnabled(_ enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard ScrcpyClient.shared.isConnected else { return }
            self.stateLock.lock()
            let serial = self.activeDeviceSerial
            self.stateLock.unlock()
            if enabled, let serial {
                self.startBackgroundAudio(serial: serial)
            } else {
                self.stopBackgroundAudio()
            }
        }
    }
    
    private func startBackgroundAudio(serial: String) {
        audioLifecycleLock.lock()
        defer { audioLifecycleLock.unlock() }
        stopBackgroundAudio()
        killOrphanAudioProcessesLocked()
        guard ADBService.validateSerial(serial) else { return }
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
        
        do {
            try proc.run()
            ProcessLifecycleManager.shared.register(proc, tag: "scrcpy-audio")
            stateLock.lock()
            self.audioProcess = proc
            stateLock.unlock()
        } catch {
            self.audioProcess = nil
        }
    }
    
    private func stopBackgroundAudio() {
        stateLock.lock()
        let proc = audioProcess
        audioProcess = nil
        stateLock.unlock()
        if let proc {
            ProcessLifecycleManager.shared.terminateProcess(proc)
        }
        ProcessLifecycleManager.shared.terminateProcesses(withTag: "scrcpy-audio")
    }

    /// Starts headless MP4 screen recording via `scrcpy --no-video-playback --no-control --record=...`.
    @discardableResult
    public func startRecording(serial: String, maxSize: Int = 1440, bitRate: Int = 8_000_000) throws -> URL {
        guard ADBService.validateSerial(serial) else {
            throw NSError(domain: "MirrorService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid ADB device serial."])
        }
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
        ProcessLifecycleManager.shared.register(proc, tag: "scrcpy-recording")
        stateLock.lock()
        recordingProcess = proc
        lastRecordingURL = outputURL
        stateLock.unlock()
        return outputURL
    }

    /// Stops active screen recording gracefully (`SIGINT` so MP4 moov atom is finalized, with `SIGTERM`/`SIGKILL` fallback).
    public func stopRecording() {
        stateLock.lock()
        let proc = recordingProcess
        recordingProcess = nil
        stateLock.unlock()
        if let proc, proc.isRunning {
            proc.interrupt()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                if proc.isRunning {
                    ProcessLifecycleManager.shared.terminateProcess(proc, gracePeriodMs: 250)
                }
            }
        }
    }
}
