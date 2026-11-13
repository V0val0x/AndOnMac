import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit

public final class ScrcpyClient: @unchecked Sendable {
    public static let shared = ScrcpyClient()
    
    // Callbacks
    public var onFrameDecoded: (@Sendable (CVPixelBuffer) -> Void)?
    public var onSessionStateChanged: (@Sendable (Bool) -> Void)?
    public var onDeviceSizeKnown: (@Sendable (Int, Int) -> Void)?
    
    private var serverProcess: Process?
    private var videoSocket: Int32 = -1
    private var controlSocket: Int32 = -1
    private var isRunning = false
    private let workQueue = DispatchQueue(label: "com.andonmac.scrcpyclient", qos: .userInteractive)
    
    // VideoToolbox
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    // Dimensions
    public private(set) var deviceWidth: Int = 1080
    public private(set) var deviceHeight: Int = 2400
    
    private init() {}
    
    public var isConnected: Bool {
        return isRunning && videoSocket >= 0
    }
    
    /// Starts embedded mirroring session using scrcpy-server 5.0.1
    public func start(
        serial: String,
        maxSize: Int = 1440,
        maxFps: Int = 60,
        bitRate: Int = 8_000_000,
        turnScreenOff: Bool = true,
        stayAwake: Bool = true
    ) async throws {
        if isRunning {
            stop()
        }
        
        // 1. Wake up screen on start so user doesn't see a black locked screen
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        
        // 2. Ensure scrcpy-server is pushed to phone
        let candidates = [
            Bundle.main.path(forResource: "scrcpy-server", ofType: nil),
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server",
            "/opt/homebrew/Cellar/scrcpy/5.0.1/share/scrcpy/scrcpy-server"
        ].compactMap { $0 }
        
        guard let serverResourcePath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "ScrcpyClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "scrcpy-server not found in bundle or homebrew"])
        }
        
        let remoteJar = "/data/local/tmp/scrcpy-server-andonmac.jar"
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "push", serverResourcePath, remoteJar])
        
        // 3. Port forwarding with unique SCID and dynamic port
        let scid = String(format: "%08x", UInt32.random(in: 0x10000000...0x7fffffff))
        let localPort = Int.random(in: 27100...27900)
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "forward", "tcp:\(localPort)", "localabstract:scrcpy_\(scid)"])
        
        // 4. Launch server process
        // Protocol: send_frame_meta=true provides 12-byte frame packet headers (zero latency, no buffering delay)
        var serverArgs = [
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
            "send_dummy_byte=false",
            "send_stream_meta=false",
            "send_frame_meta=true",
            "max_size=\(maxSize)",
            "max_fps=\(maxFps)",
            "video_bit_rate=\(bitRate)",
            "stay_awake=\(stayAwake ? "true" : "false")"
        ]
        
        if turnScreenOff {
            serverArgs.append("turn_screen_off=true")
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ADBService.shared.adbPath)
        proc.arguments = serverArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        
        try proc.run()
        self.serverProcess = proc
        self.isRunning = true
        
        // 5. Connect sockets
        try await Task.sleep(nanoseconds: 700_000_000)
        
        let vSock = try connectSocket(port: localPort)
        let cSock = try connectSocket(port: localPort)
        
        self.videoSocket = vSock
        self.controlSocket = cSock
        
        onSessionStateChanged?(true)
        
        // 6. Start reading control messages (Universal Clipboard Phone -> Mac)
        workQueue.async { [weak self] in
            self?.readControlMessages(socket: cSock)
        }
        
        // 7. Start reading raw video stream
        workQueue.async { [weak self] in
            self?.readRawVideoStream(socket: vSock)
        }
        
        // 8. Start automatic Universal Clipboard Sync (Mac -> Phone)
        DispatchQueue.main.async { [weak self] in
            self?.startClipboardSync()
        }
    }
    
    /// Stops the embedded session and cleans up sockets
    public func stop() {
        let wasRunning = isRunning
        isRunning = false
        DispatchQueue.main.async { [weak self] in
            self?.stopClipboardSync()
        }
        if videoSocket >= 0 {
            close(videoSocket)
            videoSocket = -1
        }
        if controlSocket >= 0 {
            close(controlSocket)
            controlSocket = -1
        }
        if let proc = serverProcess, proc.isRunning {
            proc.terminate()
        }
        serverProcess = nil
        
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        
        if wasRunning {
            onSessionStateChanged?(false)
        }
    }
    
    // MARK: - Socket Helper
    private func connectSocket(port: Int) throws -> Int32 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        
        // POSIX requirement: failed connect() leaves socket state unspecified.
        // Each attempt must use a freshly opened socket.
        for _ in 0..<20 {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                usleep(100_000)
                continue
            }
            
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
    private func readRawVideoStream(socket: Int32) {
        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 65536)
        
        var sps: Data?
        var pps: Data?
        
        while isRunning {
            let bytesRead = recv(socket, &temp, temp.count, 0)
            guard bytesRead > 0 else { break }
            
            buffer.append(temp, count: bytesRead)
            
            // 1. First attempt: Parse scrcpy 12-byte framed packets (send_frame_meta=true)
            // Header: 8 bytes pts_and_flags (MSB=is_config, 2nd MSB=is_keyframe, lower 62=pts) + 4 bytes packet_size
            while isRunning && buffer.count >= 12 {
                let packetSize = buffer.withUnsafeBytes { rawPtr -> UInt32 in
                    rawPtr.load(fromByteOffset: 8, as: UInt32.self).bigEndian
                }
                
                if packetSize > 0 && packetSize < 10_000_000 {
                    let totalFrameSize = 12 + Int(packetSize)
                    if buffer.count >= totalFrameSize {
                        let payload = buffer.subdata(in: 12..<totalFrameSize)
                        buffer.removeSubrange(0..<totalFrameSize)
                        
                        processPacketPayload(payload, sps: &sps, pps: &pps)
                        continue
                    } else {
                        break
                    }
                } else {
                    // Fallback to raw Annex-B NAL parser if not 12-byte framed
                    if let (nalData, nextIdx) = extractNextNAL(from: buffer) {
                        buffer.removeSubrange(0..<nextIdx)
                        handleNAL(nalData, sps: &sps, pps: &pps)
                    } else {
                        break
                    }
                }
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.stop()
        }
    }
    
    /// Reads control messages sent from Android device (e.g. Device Clipboard synchronization)
    private func readControlMessages(socket: Int32) {
        var buffer = Data()
        let tempBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tempBuf.deallocate() }
        
        while isRunning && controlSocket == socket {
            let bytesRead = recv(socket, tempBuf, 4096, 0)
            guard bytesRead > 0 else { break }
            buffer.append(tempBuf, count: bytesRead)
            
            // Parse DEVICE_MSG packets
            // Protocol: 1 byte msg_type (0 = CLIPBOARD)
            while buffer.count >= 5 {
                let msgType = buffer[0]
                if msgType == 0 { // DEVICE_MSG_TYPE_CLIPBOARD
                    let textLen = buffer.withUnsafeBytes { rawPtr -> UInt32 in
                        rawPtr.load(fromByteOffset: 1, as: UInt32.self).bigEndian
                    }
                    let totalLen = 1 + 4 + Int(textLen)
                    if buffer.count >= totalLen {
                        let textData = buffer.subdata(in: 5..<totalLen)
                        buffer.removeSubrange(0..<totalLen)
                        if let text = String(data: textData, encoding: .utf8), !text.isEmpty {
                            DispatchQueue.main.async { [weak self] in
                                if NSPasteboard.general.string(forType: .string) != text {
                                    self?.lastSyncedClipboardText = text
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                    self?.lastPasteboardChangeCount = NSPasteboard.general.changeCount
                                }
                            }
                        }
                        continue
                    } else {
                        break // wait for rest of clipboard payload
                    }
                } else if msgType == 1 { // DEVICE_MSG_TYPE_ACK_CLIPBOARD
                    if buffer.count >= 9 { // 1 byte type + 8 bytes sequence
                        buffer.removeSubrange(0..<9)
                        continue
                    } else {
                        break
                    }
                } else {
                    // Unknown control message, drop first byte to stay aligned
                    buffer.removeFirst()
                }
            }
        }
    }
    
    /// Parses all NAL units in packet payload, extracts SPS/PPS, and submits AVCC frame to VideoToolbox
    private func processPacketPayload(_ payload: Data, sps: inout Data?, pps: inout Data?) {
        guard !payload.isEmpty else { return }
        
        let nals = Self.parseAnnexBNALUnits(from: payload)
        var avccBuffer = Data()
        
        if nals.isEmpty {
            // Raw single NAL without start code
            let nalType = payload[0] & 0x1F
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
            for nal in nals {
                guard !nal.isEmpty else { continue }
                let nalType = nal[0] & 0x1F
                if nalType == 7 { // SPS
                    sps = nal
                    createDecompressionSessionIfReady(sps: sps, pps: pps)
                } else if nalType == 8 { // PPS
                    pps = nal
                    createDecompressionSessionIfReady(sps: sps, pps: pps)
                } else if nalType == 1 || nalType == 5 || nalType == 6 {
                    // Non-IDR Slice, IDR Keyframe Slice, or SEI
                    var len = UInt32(nal.count).bigEndian
                    avccBuffer.append(Data(bytes: &len, count: 4))
                    avccBuffer.append(nal)
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
                let nal = data.subdata(in: nStart..<nEnd)
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
        
        let nalPayload = data.subdata(in: payloadStart..<nextStart.index)
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
    
    private func handleNAL(_ nal: Data, sps: inout Data?, pps: inout Data?) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F
        
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
    
    private func createDecompressionSessionIfReady(sps: Data?, pps: Data?) {
        guard let sps = sps, let pps = pps else { return }
        
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
                    
                    self.setupDecompressionSession(formatDescription: format)
                }
            }
        }
    }
    
    private func setupDecompressionSession(formatDescription: CMVideoFormatDescription) {
        if let existing = decompressionSession {
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
        
        if status == noErr {
            self.decompressionSession = session
        }
    }
    
    private func decodeSlice(nal: Data) {
        var length = UInt32(nal.count).bigEndian
        var packetData = Data(bytes: &length, count: 4)
        packetData.append(nal)
        decodeAVCCBlock(packetData)
    }
    
    private func decodeAVCCBlock(_ avccData: Data) {
        guard let session = decompressionSession, let format = formatDescription else { return }
        
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
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: &flags
        ) { [weak self] decodeStatus, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in
            guard decodeStatus == noErr, let pixelBuffer = imageBuffer else { return }
            DispatchQueue.main.async {
                self?.onFrameDecoded?(pixelBuffer)
            }
        }
    }
    
    // MARK: - Direct Control Messages Injection (scrcpy protocol 5.0.1)
    
    /// Sends a binary control message to the device
    public func sendControlMessage(_ data: Data) {
        guard controlSocket >= 0 else { return }
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress else { return }
            _ = send(controlSocket, ptr, data.count, 0)
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
    
    /// Injects raw text (UTF-8)
    public func sendText(_ text: String) {
        guard let textData = text.data(using: .utf8) else { return }
        var msg = Data()
        msg.append(1) // TYPE_INJECT_TEXT
        var len = UInt32(textData.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(textData)
        sendControlMessage(msg)
    }
    
    // MARK: - Universal Real-Time Clipboard Sync
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedClipboardText: String = ""
    
    private func startClipboardSync() {
        stopClipboardSync()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
    }
    
    private func stopClipboardSync() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }
    
    /// Set clipboard content (Universal Clipboard)
    public func setClipboardText(_ text: String, paste: Bool = false) {
        guard let textData = text.data(using: .utf8) else { return }
        var msg = Data()
        msg.append(9) // TYPE_SET_CLIPBOARD
        var seq: UInt64 = 0
        msg.append(Data(bytes: &seq, count: 8))
        msg.append(paste ? 1 : 0) // paste = true/false
        var len = UInt32(textData.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(textData)
        sendControlMessage(msg)
    }
}
