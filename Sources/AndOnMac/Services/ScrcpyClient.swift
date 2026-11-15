import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit

public enum ScrcpyVideoCodec: String, Sendable {
    case h265 = "h265"
    case h264 = "h264"
}

public final class ScrcpyClient: @unchecked Sendable {
    public static let shared = ScrcpyClient()
    
    // Callbacks
    public var onFrameDecoded: (@Sendable (CVPixelBuffer) -> Void)?
    public var onFrameImageDecoded: (@Sendable (CGImage) -> Void)?
    public var onSessionStateChanged: (@Sendable (Bool) -> Void)?
    public var onDeviceSizeKnown: (@Sendable (Int, Int) -> Void)?
    
    private var serverProcess: Process?
    private var videoSocket: Int32 = -1
    private var controlSocket: Int32 = -1
    private var isRunning = false
    private var sessionGeneration: UInt64 = 0
    private var clipboardSequence: UInt64 = 0
    private var activeLocalPort: Int?
    private var activeSerial: String?
    private var didTurnScreenOff = false
    public private(set) var activeCodec: ScrcpyVideoCodec = .h265
    public private(set) var hasDecodedAnyFrame: Bool = false
    private var pendingDecodeFrames: Int = 0
    public static let maxVideoBufferBytes = 16 * 1024 * 1024

    private let videoQueue = DispatchQueue(label: "com.andonmac.scrcpyclient.video", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.andonmac.scrcpyclient.control", qos: .userInitiated)
    private let decoderLock = NSLock()
    private let socketLock = NSLock()
    
    // VideoToolbox
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var activeVPS: Data?
    private var activeSPS: Data?
    private var activePPS: Data?
    public private(set) var latestFrameImage: CGImage?
    
    // Dimensions
    public private(set) var deviceWidth: Int = 1080
    public private(set) var deviceHeight: Int = 2400
    
    private init() {}
    
    /// Resolves the `scrcpy-server` binary path from `Contents/Resources/bin`, `Contents/Resources`, or Homebrew.
    public static func resolveScrcpyServerPath() -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/scrcpy-server").path,
            Bundle.main.path(forResource: "scrcpy-server", ofType: nil),
            FileManager.default.currentDirectoryPath + "/dist/AndOnMac.app/Contents/Resources/bin/scrcpy-server",
            FileManager.default.currentDirectoryPath + "/dist/AndOnMac.app/Contents/Resources/scrcpy-server",
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server",
            "/opt/homebrew/Cellar/scrcpy/5.0.1/share/scrcpy/scrcpy-server"
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    public var isConnected: Bool {
        socketLock.lock()
        defer { socketLock.unlock() }
        return isRunning && videoSocket >= 0
    }
    
    /// Starts embedded mirroring session using scrcpy-server 5.0.1
    public func start(
        serial: String,
        maxSize: Int = 1440,
        maxFps: Int = 120,
        bitRate: Int = 16_000_000,
        videoCodec: ScrcpyVideoCodec = .h265,
        turnScreenOff: Bool = true,
        stayAwake: Bool = true
    ) async throws {
        guard ADBService.validateSerial(serial) else {
            throw NSError(domain: "ScrcpyClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid ADB device serial."])
        }
        stop()
        sessionGeneration &+= 1
        let myGen = sessionGeneration
        self.activeCodec = videoCodec
        self.hasDecodedAnyFrame = false
        self.pendingDecodeFrames = 0
        
        // 1. Wake up screen on start so user doesn't see a black locked screen
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        guard sessionGeneration == myGen else { throw CancellationError() }
        
        // 2. Ensure scrcpy-server is pushed to phone
        guard let serverResourcePath = Self.resolveScrcpyServerPath() else {
            throw NSError(domain: "ScrcpyClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "scrcpy-server not found in bundle or homebrew"])
        }
        
        let remoteJar = "/data/local/tmp/scrcpy-server-andonmac.jar"
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "push", serverResourcePath, remoteJar])
        guard sessionGeneration == myGen else { throw CancellationError() }
        
        // 3. Port forwarding with unique SCID and dynamic port
        let scid = String(format: "%08x", UInt32.random(in: 0x10000000...0x7fffffff))
        let localPort = Int.random(in: 27100...27900)
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "forward", "tcp:\(localPort)", "localabstract:scrcpy_\(scid)"])
        guard sessionGeneration == myGen else {
            _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "forward", "--remove", "tcp:\(localPort)"], timeoutSeconds: 2.0)
            throw CancellationError()
        }
        
        // 4. Launch server process
        // Protocol: send_frame_meta=true provides 12-byte frame packet headers (zero latency, no buffering delay)
        // send_dummy_byte=true allows verifying the adb forward tunnel is actually accepted by scrcpy-server
        let serverArgs = [
            "-s", serial, "shell",
            "CLASSPATH=\(remoteJar)",
            "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1",
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "control=true",
            "video=true",
            "clipboard_autosync=true",
            "send_device_meta=false",
            "send_dummy_byte=true",
            "send_stream_meta=false",
            "send_frame_meta=true",
            "max_size=\(maxSize)",
            "max_fps=\(maxFps)",
            "video_bit_rate=\(bitRate)",
            "video_codec=\(videoCodec.rawValue)",
            "stay_awake=\(stayAwake ? "true" : "false")"
        ]
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ADBService.shared.adbPath)
        proc.arguments = serverArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        
        try proc.run()
        ProcessLifecycleManager.shared.register(proc, tag: "scrcpy-server")
        self.serverProcess = proc
        self.activeSerial = serial
        self.activeLocalPort = localPort
        self.didTurnScreenOff = turnScreenOff
        self.isRunning = true
        
        // 5. Connect sockets: wait for 1 dummy byte on videoSocket before connecting controlSocket
        try await Task.sleep(nanoseconds: 250_000_000)
        guard sessionGeneration == myGen && isRunning else {
            throw CancellationError()
        }
        try connectAndStartStreams(port: localPort, turnScreenOff: turnScreenOff, codec: videoCodec)
    }
    
    /// Connects videoSocket (verifying 1 dummy byte) and controlSocket on `127.0.0.1:port` and starts concurrent stream readers.
    public func connectAndStartStreams(port: Int, turnScreenOff: Bool = false, codec: ScrcpyVideoCodec = .h264) throws {
        self.activeCodec = codec
        socketLock.lock()
        self.isRunning = true
        socketLock.unlock()

        let vSock: Int32
        let cSock: Int32
        do {
            vSock = try connectVideoSocket(port: port)
            do {
                cSock = try connectSocket(port: port)
            } catch {
                close(vSock)
                throw error
            }
        } catch {
            socketLock.lock()
            self.isRunning = false
            socketLock.unlock()
            throw error
        }

        socketLock.lock()
        let oldVSock = videoSocket
        let oldCSock = controlSocket
        self.videoSocket = vSock
        self.controlSocket = cSock
        socketLock.unlock()

        if oldVSock >= 0 {
            Darwin.shutdown(oldVSock, SHUT_RDWR)
            close(oldVSock)
        }
        if oldCSock >= 0 {
            Darwin.shutdown(oldCSock, SHUT_RDWR)
            close(oldCSock)
        }
        
        onSessionStateChanged?(true)
        
        // 6. Start reading control messages on dedicated controlQueue (Universal Clipboard Phone -> Mac)
        controlQueue.async { [weak self] in
            self?.readControlMessages(socket: cSock)
        }
        
        // 7. Start reading raw video stream on dedicated videoQueue
        videoQueue.async { [weak self] in
            self?.readRawVideoStream(socket: vSock)
        }
        
        // 8. Start automatic Universal Clipboard Sync (Mac -> Phone)
        DispatchQueue.main.async { [weak self] in
            self?.startClipboardSync()
        }
        
        if turnScreenOff {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.isConnected else { return }
                self.setScreenPowerMode(false)
            }
        }
    }
    
    /// Stops the embedded session and cleans up sockets
    public func stop() {
        socketLock.lock()
        let wasRunning = isRunning
        isRunning = false
        sessionGeneration &+= 1
        let shouldRestorePower = controlSocket >= 0 && didTurnScreenOff
        if shouldRestorePower {
            didTurnScreenOff = false
        }
        let vSock = videoSocket
        videoSocket = -1
        let cSock = controlSocket
        controlSocket = -1
        socketLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.stopClipboardSync()
        }
        
        // Restore screen power mode before closing controlSocket
        if shouldRestorePower && cSock >= 0 {
            let msg = Data([10, 2]) // TYPE_SET_SCREEN_POWER_MODE = 10, POWER_MODE_NORMAL = 2
            msg.withUnsafeBytes { rawPtr in
                if let ptr = rawPtr.baseAddress {
                    _ = send(cSock, ptr, msg.count, 0)
                }
            }
        }
        
        if vSock >= 0 {
            Darwin.shutdown(vSock, SHUT_RDWR)
            close(vSock)
        }
        
        if cSock >= 0 {
            Darwin.shutdown(cSock, SHUT_RDWR)
            close(cSock)
        }
        
        if let proc = serverProcess {
            ProcessLifecycleManager.shared.terminateProcess(proc)
        }
        serverProcess = nil
        
        if let port = activeLocalPort {
            let serial = activeSerial
            activeLocalPort = nil
            activeSerial = nil
            Task.detached {
                if let serial = serial {
                    _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeoutSeconds: 2.0)
                } else {
                    _ = try? await ADBService.shared.execute(arguments: ["forward", "--remove", "tcp:\(port)"], timeoutSeconds: 2.0)
                }
            }
        }
        
        decoderLock.lock()
        let session = decompressionSession
        decompressionSession = nil
        formatDescription = nil
        activeVPS = nil
        activeSPS = nil
        activePPS = nil
        latestFrameImage = nil
        pendingDecodeFrames = 0
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decoderLock.unlock()
        
        if wasRunning {
            onSessionStateChanged?(false)
        }
    }
    
    // MARK: - Socket Helpers
    
    /// Connects the primary video socket and waits for the 1 dummy byte (`0x00`) sent by `scrcpy-server`
    /// once `LocalServerSocket` on the device actually accepts the forwarded connection.
    private func connectVideoSocket(port: Int) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        
        for _ in 0..<40 {
            guard isRunning else { break }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                usleep(100_000)
                continue
            }
            
            var noSigPipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            
            var rcvTimeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
            
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if res == 0 {
                var dummy: UInt8 = 0
                let n = recv(sock, &dummy, 1, 0)
                if n == 1 {
                    var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
                    return sock
                }
            }
            close(sock)
            usleep(100_000)
        }
        
        throw NSError(domain: "ScrcpyClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to scrcpy video socket at port \(port)"])
    }
    
    private func connectSocket(port: Int) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        
        // POSIX requirement: failed connect() leaves socket state unspecified.
        // Each attempt must use a freshly opened socket.
        for _ in 0..<25 {
            guard isRunning else { break }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                usleep(100_000)
                continue
            }
            
            var noSigPipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if res == 0 {
                return sock
            }
            close(sock)
            usleep(100_000)
        }
        
        throw NSError(domain: "ScrcpyClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to scrcpy socket at port \(port)"])
    }
    
    // MARK: - Video Stream Reader & Low-Latency Frame Parser
    /// Caps the video stream buffer at `maxBytes` to prevent unbounded memory growth on malformed streams.
    @discardableResult
    public static func trimOversizedStreamBuffer(_ buffer: inout Data, maxBytes: Int = maxVideoBufferBytes) -> Bool {
        guard buffer.count > maxBytes else { return false }
        buffer.removeAll(keepingCapacity: false)
        return true
    }

    private func readRawVideoStream(socket: Int32) {
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 65536)
        
        var vps: Data?
        var sps: Data?
        var pps: Data?
        
        while isRunning && videoSocket == socket {
            let bytesRead = recv(socket, &temp, temp.count, 0)
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                break
            }
            guard bytesRead > 0 else { break }
            
            buffer.append(temp, count: bytesRead)
            if Self.trimOversizedStreamBuffer(&buffer) {
                continue
            }
            
            // 1. First attempt: Parse scrcpy 12-byte framed packets (send_frame_meta=true)
            // Header: 8 bytes pts_and_flags (MSB=is_config, 2nd MSB=is_keyframe, lower 62=pts) + 4 bytes packet_size
            while isRunning && videoSocket == socket && buffer.count >= 12 {
                let packetSize = buffer.withUnsafeBytes { rawPtr -> UInt32 in
                    rawPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian
                }
                
                if packetSize > 0 && packetSize < 10_000_000 {
                    let totalFrameSize = 12 + Int(packetSize)
                    if buffer.count >= totalFrameSize {
                        let payload = Data(buffer.dropFirst(12).prefix(Int(packetSize)))
                        buffer = Data(buffer.dropFirst(totalFrameSize))
                        
                        // Note: Never drop compressed P-frame packets before VideoToolbox decoding,
                        // as dropping inter-frames breaks reference chains and freezes video until next IDR.
                        // Frame-queue lag is eliminated post-decode by presenting only the newest CVPixelBuffer.
                        processPacketPayload(payload, vps: &vps, sps: &sps, pps: &pps)
                        continue
                    } else {
                        break
                    }
                } else {
                    // Fallback to raw Annex-B NAL parser if not 12-byte framed
                    if let (nalData, nextIdx) = extractNextNAL(from: buffer) {
                        buffer = Data(buffer.dropFirst(nextIdx))
                        handleNAL(nalData, vps: &vps, sps: &sps, pps: &pps)
                    } else {
                        break
                    }
                }
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.videoSocket == socket else { return }
            self.stop()
        }
    }
    
    public enum DeviceControlMessage: Equatable, Sendable {
        case clipboard(String)
        case ackClipboard(UInt64)
        case unknown(UInt8)
    }
    
    /// Safely parses and removes the next device control message from `buffer` without unaligned pointer loads or non-zero `startIndex` traps.
    public static func consumeNextControlMessage(from buffer: inout Data) -> DeviceControlMessage? {
        if buffer.startIndex != 0 {
            buffer = Data(buffer)
        }
        guard buffer.count >= 5 else { return nil }
        let msgType = buffer[buffer.startIndex]
        if msgType == 0 { // DEVICE_MSG_TYPE_CLIPBOARD
            let textLen = buffer.withUnsafeBytes { rawPtr -> UInt32 in
                rawPtr.loadUnaligned(fromByteOffset: 1, as: UInt32.self).bigEndian
            }
            if textLen > 1_048_576 {
                buffer = Data(buffer.dropFirst(1))
                return .unknown(msgType)
            }
            let totalLen = 1 + 4 + Int(textLen)
            guard buffer.count >= totalLen else { return nil }
            let textData = Data(buffer.dropFirst(5).prefix(Int(textLen)))
            buffer = Data(buffer.dropFirst(totalLen))
            let text = String(data: textData, encoding: .utf8) ?? ""
            return .clipboard(text)
        } else if msgType == 1 { // DEVICE_MSG_TYPE_ACK_CLIPBOARD
            guard buffer.count >= 9 else { return nil }
            let seq = buffer.withUnsafeBytes { rawPtr -> UInt64 in
                rawPtr.loadUnaligned(fromByteOffset: 1, as: UInt64.self).bigEndian
            }
            buffer = Data(buffer.dropFirst(9))
            return .ackClipboard(seq)
        } else if msgType == 2 { // DEVICE_MSG_TYPE_UHID_OUTPUT
            let size = buffer.withUnsafeBytes { rawPtr -> UInt16 in
                rawPtr.loadUnaligned(fromByteOffset: 3, as: UInt16.self).bigEndian
            }
            let totalLen = 5 + Int(size)
            guard buffer.count >= totalLen else { return nil }
            buffer = Data(buffer.dropFirst(totalLen))
            return .unknown(msgType)
        } else {
            buffer = Data(buffer.dropFirst(1))
            return .unknown(msgType)
        }
    }
    
    /// Reads control messages sent from Android device (e.g. Device Clipboard synchronization)
    private func readControlMessages(socket: Int32) {
        var buffer = Data()
        let tempBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tempBuf.deallocate() }
        
        while isRunning && controlSocket == socket {
            let bytesRead = recv(socket, tempBuf, 4096, 0)
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                break
            }
            guard bytesRead > 0 else { break }
            buffer.append(tempBuf, count: bytesRead)
            
            while let msg = Self.consumeNextControlMessage(from: &buffer) {
                if case .clipboard(let text) = msg, !text.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        if NSPasteboard.general.string(forType: .string) != text {
                            self?.lastSyncedClipboardText = text
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            self?.lastPasteboardChangeCount = NSPasteboard.general.changeCount
                        }
                    }
                }
            }
        }
    }
    
    /// Extracts HEVC NAL unit type (`(header >> 1) & 0x3F`).
    public static func hevcNALType(for nal: Data) -> UInt8? {
        guard let first = nal.first else { return nil }
        return (first >> 1) & 0x3F
    }

    /// Parses all NAL units in packet payload, extracts parameter sets (H.264 SPS/PPS or HEVC VPS/SPS/PPS), and submits AVCC/HVCC frame to VideoToolbox
    private func processPacketPayload(_ payload: Data, vps: inout Data?, sps: inout Data?, pps: inout Data?) {
        guard !payload.isEmpty else { return }
        
        let nals = Self.parseAnnexBNALUnits(from: payload)
        var avccBuffer = Data()
        
        if activeCodec == .h265 {
            if nals.isEmpty {
                if let nalType = Self.hevcNALType(for: payload) {
                    if nalType == 32 {
                        vps = payload
                        createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
                    } else if nalType == 33 {
                        sps = payload
                        createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
                    } else if nalType == 34 {
                        pps = payload
                        createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
                    } else {
                        var len = UInt32(payload.count).bigEndian
                        avccBuffer.append(Data(bytes: &len, count: 4))
                        avccBuffer.append(payload)
                    }
                }
            } else {
                var paramUpdated = false
                for nal in nals {
                    guard let nalType = Self.hevcNALType(for: nal) else { continue }
                    if nalType == 32 {
                        vps = nal
                        paramUpdated = true
                    } else if nalType == 33 {
                        sps = nal
                        paramUpdated = true
                    } else if nalType == 34 {
                        pps = nal
                        paramUpdated = true
                    } else {
                        if paramUpdated {
                            createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
                            paramUpdated = false
                        }
                        var len = UInt32(nal.count).bigEndian
                        avccBuffer.append(Data(bytes: &len, count: 4))
                        avccBuffer.append(nal)
                    }
                }
                if paramUpdated {
                    createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
                }
            }
        } else {
            if nals.isEmpty {
                // Raw single NAL without start code
                let nalType = payload[payload.startIndex] & 0x1F
                if nalType == 7 {
                    sps = payload
                    createDecompressionSessionIfReady(sps: sps, pps: pps)
                } else if nalType == 8 {
                    pps = payload
                    createDecompressionSessionIfReady(sps: sps, pps: pps)
                } else {
                    var len = UInt32(payload.count).bigEndian
                    avccBuffer.append(Data(bytes: &len, count: 4))
                    avccBuffer.append(payload)
                }
            } else {
                var spsOrPpsUpdated = false
                for nal in nals {
                    guard !nal.isEmpty else { continue }
                    let nalType = nal[nal.startIndex] & 0x1F
                    if nalType == 7 { // SPS
                        sps = nal
                        spsOrPpsUpdated = true
                    } else if nalType == 8 { // PPS
                        pps = nal
                        spsOrPpsUpdated = true
                    } else if nalType == 1 || nalType == 5 || nalType == 6 {
                        // Non-IDR Slice, IDR Keyframe Slice, or SEI
                        if spsOrPpsUpdated {
                            createDecompressionSessionIfReady(sps: sps, pps: pps)
                            spsOrPpsUpdated = false
                        }
                        var len = UInt32(nal.count).bigEndian
                        avccBuffer.append(Data(bytes: &len, count: 4))
                        avccBuffer.append(nal)
                    }
                }
                if spsOrPpsUpdated {
                    createDecompressionSessionIfReady(sps: sps, pps: pps)
                }
            }
        }
        
        if !avccBuffer.isEmpty {
            decodeAVCCBlock(avccBuffer)
        }
    }
    
    static func parseAnnexBNALUnits(from data: Data) -> [Data] {
        var nals: [Data] = []
        var offset = 0
        while let start = findStartCode(in: data, startingAt: offset) {
            let nStart = start.index + start.length
            let nEnd: Int
            if let nextStart = findStartCode(in: data, startingAt: nStart) {
                nEnd = nextStart.index
            } else {
                nEnd = data.count
            }
            if nEnd > nStart {
                let nal = Data(data.dropFirst(nStart).prefix(nEnd - nStart))
                nals.append(nal)
            }
            offset = nEnd
        }
        return nals
    }
    
    private func extractNextNAL(from data: Data) -> (Data, Int)? {
        guard data.count > 4 else { return nil }
        
        // Find first start code
        guard let firstStart = Self.findStartCode(in: data, startingAt: 0) else { return nil }
        let payloadStart = firstStart.index + firstStart.length
        
        // Find second start code (end of current NAL)
        guard let nextStart = Self.findStartCode(in: data, startingAt: payloadStart) else {
            return nil
        }
        
        let nalPayload = Data(data.dropFirst(payloadStart).prefix(nextStart.index - payloadStart))
        return (nalPayload, nextStart.index)
    }
    
    static func findStartCode(in data: Data, startingAt offset: Int) -> (index: Int, length: Int)? {
        guard offset + 3 <= data.count else { return nil }
        
        return data.withUnsafeBytes { rawBuffer -> (Int, Int)? in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = data.count
            var i = offset
            while i + 3 <= count {
                if ptr[i] == 0 && ptr[i+1] == 0 {
                    if ptr[i+2] == 1 {
                        return (i, 3)
                    } else if i + 4 <= count && ptr[i+2] == 0 && ptr[i+3] == 1 {
                        return (i, 4)
                    }
                }
                i += 1
            }
            return nil
        }
    }
    
    private func handleNAL(_ nal: Data, vps: inout Data?, sps: inout Data?, pps: inout Data?) {
        guard !nal.isEmpty else { return }
        if activeCodec == .h265 {
            guard let nalType = Self.hevcNALType(for: nal) else { return }
            switch nalType {
            case 32:
                vps = nal
                createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
            case 33:
                sps = nal
                createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
            case 34:
                pps = nal
                createHEVCDecompressionSessionIfReady(vps: vps, sps: sps, pps: pps)
            default:
                decodeSlice(nal: nal)
            }
            return
        }

        let nalType = nal[nal.startIndex] & 0x1F
        switch nalType {
        case 7: // SPS
            sps = nal
            createDecompressionSessionIfReady(sps: sps, pps: pps)
        case 8: // PPS
            pps = nal
            createDecompressionSessionIfReady(sps: sps, pps: pps)
        case 1, 5: // Non-IDR Slice (1) or IDR Slice (5)
            decodeSlice(nal: nal)
        default:
            break
        }
    }

    private func createHEVCDecompressionSessionIfReady(vps: Data?, sps: Data?, pps: Data?) {
        guard let vps = vps, let sps = sps, let pps = pps else { return }
        decoderLock.lock()
        defer { decoderLock.unlock() }
        guard isRunning else { return }
        if decompressionSession != nil && activeVPS == vps && activeSPS == sps && activePPS == pps {
            return
        }

        var formatDesc: CMVideoFormatDescription?
        let vpsBytes = [UInt8](vps)
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)

        vpsBytes.withUnsafeBufferPointer { vpsBuf in
            spsBytes.withUnsafeBufferPointer { spsBuf in
                ppsBytes.withUnsafeBufferPointer { ppsBuf in
                    guard let vBase = vpsBuf.baseAddress,
                          let sBase = spsBuf.baseAddress,
                          let pBase = ppsBuf.baseAddress else { return }
                    let pointers: [UnsafePointer<UInt8>] = [vBase, sBase, pBase]
                    let sizes: [Int] = [vpsBuf.count, spsBuf.count, ppsBuf.count]

                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )

                    if status == noErr, let format = formatDesc {
                        self.formatDescription = format
                        let dim = CMVideoFormatDescriptionGetDimensions(format)
                        self.deviceWidth = Int(dim.width)
                        self.deviceHeight = Int(dim.height)

                        DispatchQueue.main.async {
                            self.onDeviceSizeKnown?(Int(dim.width), Int(dim.height))
                        }

                        if self.setupDecompressionSession(formatDescription: format) {
                            self.activeVPS = vps
                            self.activeSPS = sps
                            self.activePPS = pps
                        }
                    }
                }
            }
        }
    }
    
    private func createDecompressionSessionIfReady(sps: Data?, pps: Data?) {
        guard let sps = sps, let pps = pps else { return }
        decoderLock.lock()
        defer { decoderLock.unlock() }
        guard isRunning else { return }
        if decompressionSession != nil && activeSPS == sps && activePPS == pps {
            return
        }
        
        var formatDesc: CMVideoFormatDescription?
        let spsPointer = [UInt8](sps)
        let ppsPointer = [UInt8](pps)
        
        var parameterSetPointers: [UnsafePointer<UInt8>] = []
        var parameterSetSizes: [Int] = []
        
        spsPointer.withUnsafeBufferPointer { spsBuf in
            ppsPointer.withUnsafeBufferPointer { ppsBuf in
                parameterSetPointers = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                parameterSetSizes = [spsBuf.count, ppsBuf.count]
                
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                
                if status == noErr, let format = formatDesc {
                    self.formatDescription = format
                    let dim = CMVideoFormatDescriptionGetDimensions(format)
                    self.deviceWidth = Int(dim.width)
                    self.deviceHeight = Int(dim.height)
                    
                    DispatchQueue.main.async {
                        self.onDeviceSizeKnown?(Int(dim.width), Int(dim.height))
                    }
                    
                    if self.setupDecompressionSession(formatDescription: format) {
                        self.activeSPS = sps
                        self.activePPS = pps
                    }
                }
            }
        }
    }
    
    @discardableResult
    private func setupDecompressionSession(formatDescription: CMVideoFormatDescription) -> Bool {
        if let existing = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(existing)
            VTDecompressionSessionInvalidate(existing)
            decompressionSession = nil
        }
        
        let destinationPixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            decompressionSessionOut: &session
        )
        
        if status == noErr, let session = session {
            self.decompressionSession = session
            return true
        }
        return false
    }
    
    private func decodeSlice(nal: Data) {
        var length = UInt32(nal.count).bigEndian
        var packetData = Data(bytes: &length, count: 4)
        packetData.append(nal)
        decodeAVCCBlock(packetData)
    }
    
    private func decodeAVCCBlock(_ avccData: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        guard isRunning, let session = decompressionSession, let format = formatDescription else { return }
        
        let count = avccData.count
        guard let memoryBlock = malloc(count) else { return }
        avccData.copyBytes(to: memoryBlock.assumingMemoryBound(to: UInt8.self), count: count)
        
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: count,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let buffer = blockBuffer else {
            free(memoryBlock)
            return
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [count]
        
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }
        
        var flags: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._1xRealTimePlayback, ._EnableAsynchronousDecompression],
            infoFlagsOut: &flags
        ) { [weak self] decodeStatus, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard decodeStatus == noErr, let pixelBuffer = imageBuffer else { return }
            self?.hasDecodedAnyFrame = true
            PerformanceEngine.recordPresentedFrame()
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if let cgImage = cgImage {
                self?.latestFrameImage = cgImage
            }
            nonisolated(unsafe) let pb = pixelBuffer
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFrameDecoded?(pb)
                if let cgImage = cgImage {
                    self.onFrameImageDecoded?(cgImage)
                }
            }
        }
    }
    
    // MARK: - Direct Control Messages Injection (scrcpy protocol 5.0.1)
    
    /// Sends a binary control message to the device
    public func sendControlMessage(_ data: Data) {
        socketLock.lock()
        let sock = controlSocket
        socketLock.unlock()
        guard sock >= 0 else { return }
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress else { return }
            _ = send(sock, ptr, data.count, 0)
        }
    }
    
    /// Injects Touch Event: action (0=down, 1=up, 2=move), x/y normalized (0.0 ... 1.0)
    public func sendTouchEvent(action: UInt8, pointerId: UInt64 = 0, normalizedX: CGFloat, normalizedY: CGFloat, pressure: Float = 1.0) {
        let x = Int32(max(0, min(1.0, normalizedX)) * CGFloat(deviceWidth))
        let y = Int32(max(0, min(1.0, normalizedY)) * CGFloat(deviceHeight))
        
        var msg = Data()
        msg.append(2) // TYPE_INJECT_TOUCH_EVENT
        msg.append(action)
        
        var pId = pointerId.bigEndian
        msg.append(Data(bytes: &pId, count: 8))
        
        var posX = x.bigEndian
        var posY = y.bigEndian
        var screenW = UInt16(deviceWidth).bigEndian
        var screenH = UInt16(deviceHeight).bigEndian
        
        msg.append(Data(bytes: &posX, count: 4))
        msg.append(Data(bytes: &posY, count: 4))
        msg.append(Data(bytes: &screenW, count: 2))
        msg.append(Data(bytes: &screenH, count: 2))
        
        // Pressure as uint16
        var pVal = UInt16(max(0.0, min(1.0, pressure)) * 65535.0).bigEndian
        msg.append(Data(bytes: &pVal, count: 2))
        
        // Buttons: primary=1
        let actionButton: UInt32 = 1
        let buttons: UInt32 = 1
        var abBig = actionButton.bigEndian
        var bBig = buttons.bigEndian
        msg.append(Data(bytes: &abBig, count: 4))
        msg.append(Data(bytes: &bBig, count: 4))
        
        sendControlMessage(msg)
    }
    
    /// Injects Trackpad / Mouse Scroll Event
    public func sendScrollEvent(normalizedX: CGFloat, normalizedY: CGFloat, deltaH: Float, deltaV: Float) {
        let x = Int32(max(0, min(1.0, normalizedX)) * CGFloat(deviceWidth))
        let y = Int32(max(0, min(1.0, normalizedY)) * CGFloat(deviceHeight))
        
        var msg = Data()
        msg.append(3) // TYPE_INJECT_SCROLL_EVENT
        
        var posX = x.bigEndian
        var posY = y.bigEndian
        var screenW = UInt16(deviceWidth).bigEndian
        var screenH = UInt16(deviceHeight).bigEndian
        msg.append(Data(bytes: &posX, count: 4))
        msg.append(Data(bytes: &posY, count: 4))
        msg.append(Data(bytes: &screenW, count: 2))
        msg.append(Data(bytes: &screenH, count: 2))
        
        // float to int16 (-1.0...1.0)
        let clampedH = max(-1.0, min(1.0, deltaH))
        let clampedV = max(-1.0, min(1.0, deltaV))
        var h16 = Int16(clampedH * 32767.0).bigEndian
        var v16 = Int16(clampedV * 32767.0).bigEndian
        msg.append(Data(bytes: &h16, count: 2))
        msg.append(Data(bytes: &v16, count: 2))
        
        let buttons: UInt32 = 0
        var bBig = buttons.bigEndian
        msg.append(Data(bytes: &bBig, count: 4))
        
        sendControlMessage(msg)
    }
    
    /// Injects Keycode with optional modifier state (e.g. Back, Home, App Switch, or Ctrl+Enter for sending messages)
    public func sendKeycode(_ keycode: UInt32, action: UInt8 = 0, metaState: UInt32 = 0) {
        var msg = Data()
        msg.append(0) // TYPE_INJECT_KEYCODE
        msg.append(action) // 0=down, 1=up
        var kc = keycode.bigEndian
        var repeatCount: UInt32 = 0
        var meta = metaState.bigEndian
        msg.append(Data(bytes: &kc, count: 4))
        msg.append(Data(bytes: &repeatCount, count: 4))
        msg.append(Data(bytes: &meta, count: 4))
        sendControlMessage(msg)
        
        if action == 0 {
            // Send key up immediately
            var msgUp = Data()
            msgUp.append(0)
            msgUp.append(1)
            msgUp.append(Data(bytes: &kc, count: 4))
            msgUp.append(Data(bytes: &repeatCount, count: 4))
            msgUp.append(Data(bytes: &meta, count: 4))
            sendControlMessage(msgUp)
        }
    }
    
    /// Back or Screen On (Right click / Esc)
    public func sendBackOrScreenOn() {
        let msg = Data([4, 0]) // TYPE_BACK_OR_SCREEN_ON
        sendControlMessage(msg)
        let msgUp = Data([4, 1])
        sendControlMessage(msgUp)
    }

    /// Expands the Android notification shade
    public func expandNotificationsPanel() {
        sendControlMessage(Data([5])) // TYPE_EXPAND_NOTIFICATION_PANEL
    }
    
    /// Returns true if text contains non-ASCII characters (e.g. Cyrillic) that scrcpy's
    /// TYPE_INJECT_TEXT KeyCharacterMap drops and must instead be injected via clipboard paste.
    public static func shouldUseClipboardPaste(for text: String) -> Bool {
        return !text.isEmpty && !text.allSatisfy { $0.isASCII }
    }

    /// Injects raw text (UTF-8), routing non-ASCII text through clipboard paste so Cyrillic works.
    public func sendText(_ text: String) {
        if Self.shouldUseClipboardPaste(for: text) {
            setClipboardText(text, paste: true)
            return
        }
        guard let textData = text.data(using: .utf8) else { return }
        var msg = Data()
        msg.append(1) // TYPE_INJECT_TEXT
        var len = UInt32(textData.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(textData)
        sendControlMessage(msg)
    }
    
    /// Controls device screen power mode (false = screen off while mirroring continues, true = screen on)
    public func setScreenPowerMode(_ on: Bool) {
        var msg = Data()
        msg.append(10) // TYPE_SET_SCREEN_POWER_MODE
        msg.append(on ? 2 : 0) // 0 = POWER_MODE_OFF, 2 = POWER_MODE_NORMAL
        sendControlMessage(msg)
    }
    
    // MARK: - Universal Real-Time Clipboard Sync
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedClipboardText: String = ""
    
    private func startClipboardSync() {
        stopClipboardSync()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            let currentCount = NSPasteboard.general.changeCount
            if currentCount != self.lastPasteboardChangeCount {
                self.lastPasteboardChangeCount = currentCount
                if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty, str != self.lastSyncedClipboardText {
                    self.lastSyncedClipboardText = str
                    self.setClipboardText(str, paste: false)
                }
            }
        }
        timer.tolerance = 0.2
        clipboardTimer = timer
    }
    
    private func stopClipboardSync() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }
    
    /// Set clipboard content (Universal Clipboard)
    public func setClipboardText(_ text: String, paste: Bool = false) {
        guard let textData = text.data(using: .utf8) else { return }
        clipboardSequence &+= 1
        var msg = Data()
        msg.append(9) // TYPE_SET_CLIPBOARD
        var seq = clipboardSequence.bigEndian
        msg.append(Data(bytes: &seq, count: 8))
        msg.append(paste ? 1 : 0) // paste = true/false
        var len = UInt32(textData.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(textData)
        sendControlMessage(msg)
    }
}
