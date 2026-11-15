import XCTest
import SwiftUI
import AppKit
@testable import AndOnMac

final class AndOnMacTests: XCTestCase {
    func testDeviceInitialization() {
        let pixelDevice = Device(
            id: "192.168.1.100:5555",
            model: "Pixel 8 Pro",
            manufacturer: "Google",
            androidVersion: "15",
            batteryLevel: 85,
            isCharging: true,
            connectionType: .wifi,
            state: .ready,
            ipAddress: "192.168.1.100"
        )
        
        XCTAssertEqual(pixelDevice.displayName, "Pixel 8 Pro")
        XCTAssertTrue(pixelDevice.isPixel)
        XCTAssertEqual(pixelDevice.connectionType, .wifi)
        XCTAssertEqual(pixelDevice.batteryLevel, 85)
        XCTAssertEqual(pixelDevice.isCharging, true)
    }
    
    func testGenericAndroidDevice() {
        let samsungDevice = Device(
            id: "RF8N123456",
            model: "SM-S918B",
            manufacturer: "Samsung",
            connectionType: .usb,
            state: .ready
        )
        
        XCTAssertEqual(samsungDevice.displayName, "Samsung SM-S918B")
        XCTAssertFalse(samsungDevice.isPixel)
        XCTAssertEqual(samsungDevice.connectionType, .usb)
        
        // Edge cases
        let unknownMfr = Device(id: "123", model: "Pixel_10a", manufacturer: "Unknown")
        XCTAssertEqual(unknownMfr.displayName, "Pixel 10a")
        
        let duplicateBrand = Device(id: "456", model: "Xiaomi_14_Pro", manufacturer: "Xiaomi")
        XCTAssertEqual(duplicateBrand.displayName, "Xiaomi 14 Pro")
    }
    
    func testPhotoItemModel() {
        let photo = PhotoItem(
            id: "/sdcard/DCIM/Camera/IMG_20261113.jpg",
            name: "IMG_20261113.jpg",
            remotePath: "/sdcard/DCIM/Camera/IMG_20261113.jpg",
            isScreenshot: false
        )
        XCTAssertEqual(photo.id, "/sdcard/DCIM/Camera/IMG_20261113.jpg")
        XCTAssertEqual(photo.name, "IMG_20261113.jpg")
        XCTAssertFalse(photo.isScreenshot)
        XCTAssertNil(photo.localURL)
        
        let screenshot = PhotoItem(
            id: "/sdcard/Pictures/Screenshots/Screenshot_01.png",
            name: "Screenshot_01.png",
            remotePath: "/sdcard/Pictures/Screenshots/Screenshot_01.png",
            isScreenshot: true
        )
        XCTAssertTrue(screenshot.isScreenshot)
        
        // Uppercase extension tests (typical Samsung / Xiaomi / Pixel naming)
        let uppercasePhoto = PhotoItem(
            id: "/sdcard/DCIM/Camera/IMG_20261113.JPG",
            name: "IMG_20261113.JPG",
            remotePath: "/sdcard/DCIM/Camera/IMG_20261113.JPG",
            isScreenshot: false
        )
        XCTAssertEqual(uppercasePhoto.name, "IMG_20261113.JPG")
        XCTAssertTrue(uppercasePhoto.name.lowercased().hasSuffix(".jpg"))
    }
    
    func testDeviceAspectRatioCalculation() {
        // Pixel / modern phone ~20:9
        let h20_9 = 2400.0 / 1080.0
        XCTAssertGreaterThan(h20_9, 2.0)
        XCTAssertLessThan(h20_9, 2.3)
        
        // Samsung 19.5:9
        let h19_5_9 = 2340.0 / 1080.0
        XCTAssertGreaterThan(h19_5_9, 2.1)
    }
    
    func testWindowScaleMultipliers() {
        XCTAssertEqual(PhoneWindowScale.smaller.multiplier, 0.8)
        XCTAssertEqual(PhoneWindowScale.standard.multiplier, 1.0)
        XCTAssertEqual(PhoneWindowScale.larger.multiplier, 1.2)
    }
    
    @MainActor
    func testAppStateInitialState() {
        let appState = AppState()
        XCTAssertFalse(appState.showPhotoDrawer)
        XCTAssertNil(appState.photoTransferNotice)
        XCTAssertFalse(appState.isMirroring)
        XCTAssertFalse(appState.isLandscape)
        XCTAssertGreaterThan(appState.effectiveAspect, 1.3)
    }
    
    func testADBConnectSuccessParsing() {
        XCTAssertTrue(ADBService.isConnectSuccess("connected to 192.168.1.55:5555"))
        XCTAssertTrue(ADBService.isConnectSuccess("already connected to 192.168.1.55:5555"))
        XCTAssertFalse(ADBService.isConnectSuccess("failed to connect to 192.168.1.55:5555"))
        XCTAssertFalse(ADBService.isConnectSuccess("cannot connect to 192.168.1.55:5555: Connection refused"))
        XCTAssertFalse(ADBService.isConnectSuccess("Connection timed out"))
    }
    
    func testAnnexBNALUnitParsing() {
        // Typical scrcpy config packet: 4-byte start code + SPS (0x67...), 4-byte start code + PPS (0x68...)
        var stream = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x28, 0xDA]) // SPS (nalType = 7)
        stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80]) // PPS (nalType = 8)
        
        let nals = ScrcpyClient.parseAnnexBNALUnits(from: stream)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(nals[0][0] & 0x1F, 7) // SPS
        XCTAssertEqual(nals[1][0] & 0x1F, 8) // PPS
        
        // 3-byte start code test
        let stream3Byte = Data([0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x00]) // IDR (nalType = 5)
        let nals3 = ScrcpyClient.parseAnnexBNALUnits(from: stream3Byte)
        XCTAssertEqual(nals3.count, 1)
        XCTAssertEqual(nals3[0][0] & 0x1F, 5) // IDR Slice
    }
    
    func testKeyboardSubtypeParsing() {
        let sampleDumpsys = """
        mSubtypeNameOverride=English (US) mSubtypeShortLabel=US mLayoutLabelNonLocalized= mPkLanguageTag= mPkLayoutType=qwerty mSubtypeId=1594443099 mSubtypeLocale=en_US mSubtypeLanguageTag=en-US mSubtypeMode=keyboard
        mSubtypeNameOverride=Русский (Россия) mSubtypeShortLabel=РУ mLayoutLabelNonLocalized= mPkLanguageTag= mPkLayoutType= mSubtypeId=-1807566855 mSubtypeLocale=ru_RU mSubtypeLanguageTag=ru-RU mSubtypeMode=keyboard
        mSubtypeNameOverride=Deutsch (Österreich) mSubtypeShortLabel=DE mLayoutLabelNonLocalized= mPkLanguageTag= mPkLayoutType=qwertz mSubtypeId=979167277 mSubtypeLocale=de_AT mSubtypeLanguageTag=de-AT mSubtypeMode=keyboard
        """
        
        let map = KeyboardLanguageSyncService.parseSubtypes(from: sampleDumpsys)
        XCTAssertEqual(map["en"], 1594443099)
        XCTAssertEqual(map["ru"], -1807566855)
        XCTAssertEqual(map["de"], 979167277)
    }
    
    @MainActor
    func testSendOnEnterPreference() {
        let appState = AppState()
        XCTAssertTrue(appState.sendOnEnter)
    }
    
    func testPhoneFrameStyleDetection() {
        // Pixel
        let pixel = Device(id: "1", model: "Pixel 9 Pro", manufacturer: "Google")
        XCTAssertEqual(PhoneFrameStyle.detect(for: pixel), .pixel)
        XCTAssertEqual(PhoneFrameStyle.pixel.cornerRadius, 28)
        XCTAssertTrue(PhoneFrameStyle.pixel.hasPunchHole)
        
        // Samsung Ultra
        let ultra1 = Device(id: "2", model: "SM-S928B", manufacturer: "Samsung") // S24 Ultra
        XCTAssertEqual(PhoneFrameStyle.detect(for: ultra1), .samsungUltra)
        XCTAssertEqual(PhoneFrameStyle.samsungUltra.cornerRadius, 10) // Sharp signature Ultra corners
        XCTAssertEqual(PhoneFrameStyle.samsungUltra.baseWidthMultiplier, 1.0)
        
        let ultra2 = Device(id: "3", model: "Galaxy S25 Ultra", manufacturer: "Samsung")
        XCTAssertEqual(PhoneFrameStyle.detect(for: ultra2), .samsungUltra)
        
        // Samsung Standard
        let s24 = Device(id: "4", model: "SM-S921B", manufacturer: "Samsung") // S24 Base
        XCTAssertEqual(PhoneFrameStyle.detect(for: s24), .samsung)
        XCTAssertEqual(PhoneFrameStyle.samsung.cornerRadius, 24)
        
        // Xiaomi
        let xiaomi = Device(id: "5", model: "Xiaomi 14", manufacturer: "Xiaomi")
        XCTAssertEqual(PhoneFrameStyle.detect(for: xiaomi), .xiaomi)
        XCTAssertEqual(PhoneFrameStyle.xiaomi.cornerRadius, 26)
        
        // Nothing Phone
        let nothing = Device(id: "6", model: "Phone (2)", manufacturer: "Nothing")
        XCTAssertEqual(PhoneFrameStyle.detect(for: nothing), .nothing)
        XCTAssertEqual(PhoneFrameStyle.nothing.cornerRadius, 28)
        
        // OnePlus
        let oneplus = Device(id: "7", model: "CPH2581", manufacturer: "OnePlus")
        XCTAssertEqual(PhoneFrameStyle.detect(for: oneplus), .oneplus)
        XCTAssertEqual(PhoneFrameStyle.oneplus.cornerRadius, 26)
    }
    
    @MainActor
    func testEffectiveFrameStyleAutoResolution() {
        let appState = AppState()
        appState.frameStyle = .auto
        
        // With demo device (Pixel 9 Pro)
        appState.isDemoMode = true
        XCTAssertEqual(appState.effectiveFrameStyle, .pixel)
        
        // Manual override
        appState.frameStyle = .samsungUltra
        XCTAssertEqual(appState.effectiveFrameStyle, .samsungUltra)
        
        appState.frameStyle = .nothing
        XCTAssertEqual(appState.effectiveFrameStyle, .nothing)
    }
    
    func testPairingTabNames() {
        XCTAssertEqual(PairingTab.wifiPin.rawValue, "Wi-Fi")
        XCTAssertEqual(PairingTab.usbSetup.rawValue, "Кабель USB")
        XCTAssertEqual(PairingTab.savedDevices.rawValue, "История")
    }
    
    func testDiscoveryServiceAdbMdnsParsing() {
        let sampleOutput = """
        List of discovered mdns services
        adb-phone1-xyz    _adb-tls-connect._tcp    10.36.201.171:38195
        adb-phone1-abc    _adb-tls-pairing._tcp    10.36.201.171:41893
        """
        
        let discovery = DiscoveryService.shared
        discovery.parseAdbMdnsOutput(sampleOutput)
        
        XCTAssertEqual(discovery.getConnectPort(for: "10.36.201.171"), 38195)
    }
    
    func testScrcpyClientStopWhenNotRunningDoesNotEmitStateFalse() {
        final class StateBox: @unchecked Sendable {
            var emitted = false
        }
        let box = StateBox()
        let client = ScrcpyClient.shared
        client.stop()
        
        client.onSessionStateChanged = { _ in
            box.emitted = true
        }
        
        client.stop()
        XCTAssertFalse(box.emitted, "stop() when not running must not emit onSessionStateChanged(false)")
    }
    
    func testUnalignedControlMessageParsingAndStartIndexSafety() {
        var buffer = Data()
        // 1. Unknown control byte (0x99) that previously caused buffer.removeFirst() to shift startIndex to 1
        buffer.append(0x99)
        
        // 2. DEVICE_MSG_TYPE_CLIPBOARD (type = 0, 4-byte unaligned length at offset 1, UTF-8 text)
        let text = "Привет из Pixel 11 Pro!"
        let textBytes = Data(text.utf8)
        buffer.append(0x00)
        var lenBE = UInt32(textBytes.count).bigEndian
        buffer.append(Data(bytes: &lenBE, count: 4))
        buffer.append(textBytes)
        
        // 3. DEVICE_MSG_TYPE_ACK_CLIPBOARD (type = 1, 8-byte unaligned sequence at offset 1)
        buffer.append(0x01)
        var seqBE = UInt64(42_000_123).bigEndian
        buffer.append(Data(bytes: &seqBE, count: 8))
        
        // First message: unknown(0x99)
        let msg1 = ScrcpyClient.consumeNextControlMessage(from: &buffer)
        XCTAssertEqual(msg1, .unknown(0x99))
        XCTAssertEqual(buffer.startIndex, 0, "buffer.startIndex must remain 0 after dropping unknown byte")
        
        // Second message: clipboard with unaligned 4-byte length at offset 1
        let msg2 = ScrcpyClient.consumeNextControlMessage(from: &buffer)
        XCTAssertEqual(msg2, .clipboard(text))
        XCTAssertEqual(buffer.startIndex, 0)
        
        // Third message: ackClipboard with unaligned 8-byte sequence at offset 1
        let msg3 = ScrcpyClient.consumeNextControlMessage(from: &buffer)
        XCTAssertEqual(msg3, .ackClipboard(42_000_123))
        XCTAssertTrue(buffer.isEmpty)
        
        // Incomplete packet should return nil without mutating buffer
        var partial = Data([0x00, 0x00, 0x00, 0x00, 0x0A, 0x41, 0x42])
        XCTAssertNil(ScrcpyClient.consumeNextControlMessage(from: &partial))
        XCTAssertEqual(partial.count, 7)
    }
    
    func testParseWirelessTlsPortFromDumpsysAdb() {
        let activeDumpsys = """
        ADB MANAGER STATE (dumpsys adb):
          debugging_manager:
            connected_to_adb: true
            adb_wifi_enabled: true
            tls_port=39787
        """
        XCTAssertEqual(ADBService.parseWirelessTlsPort(from: activeDumpsys), 39787)
        
        let colonFormat = "  tls_port: 41523\n"
        XCTAssertEqual(ADBService.parseWirelessTlsPort(from: colonFormat), 41523)
        
        let disabledDumpsys = "  tls_port=-1\n"
        XCTAssertNil(ADBService.parseWirelessTlsPort(from: disabledDumpsys))
        
        let zeroPort = "  tls_port=0\n"
        XCTAssertNil(ADBService.parseWirelessTlsPort(from: zeroPort))
    }
    
    func testADBTimeoutErrorMessageContextAwareness() {
        let connectMsg = ADBService.timeoutErrorMessage(for: ["connect", "10.36.206.3:39787"], timeoutSeconds: 4.0)
        XCTAssertTrue(connectMsg.contains("AP Client Isolation"))
        
        let pairMsg = ADBService.timeoutErrorMessage(for: ["pair", "10.36.206.3:41234", "123456"], timeoutSeconds: 6.0)
        XCTAssertTrue(pairMsg.contains("AP Client Isolation"))
        
        let usbMsg = ADBService.timeoutErrorMessage(for: ["-s", "67280DLKX006GT", "shell", "dumpsys", "battery"], timeoutSeconds: 6.0)
        XCTAssertTrue(usbMsg.contains("Проверьте экран телефона"))
    }
    
    @MainActor
    func testPersistKnownDevicePreservesWirelessPortOverUSB() {
        let appState = AppState()
        let testIP = "10.36.206.3"
        let testSerial = "67280DLKX006GT"
        appState.removeKnownDevice(id: testSerial)
        
        // 1. Device connected via USB with wirelessPort = 39787 from dumpsys adb
        let usbWithTls = Device(
            id: testSerial,
            model: "Pixel 11 Pro",
            manufacturer: "Google",
            connectionType: .usb,
            state: .ready,
            ipAddress: testIP,
            wirelessPort: 39787
        )
        appState.persistKnownDevice(usbWithTls)
        XCTAssertEqual(appState.knownDevices.first(where: { $0.ipAddress == testIP })?.port, 39787)
        
        // 2. Subsequent USB poll where wirelessPort is nil must NOT clobber 39787 with 5555
        let usbWithoutTls = Device(
            id: testSerial,
            model: "Pixel 11 Pro",
            manufacturer: "Google",
            connectionType: .usb,
            state: .ready,
            ipAddress: testIP,
            wirelessPort: nil
        )
        // Clear DiscoveryService cache for a clean test of fallback preservation
        let savedBefore = appState.knownDevices.first(where: { $0.ipAddress == testIP })?.port
        XCTAssertEqual(savedBefore, 39787)
        appState.persistKnownDevice(usbWithoutTls)
        XCTAssertEqual(appState.knownDevices.first(where: { $0.ipAddress == testIP })?.port, 39787)
    }
    
    @MainActor
    func testScrcpyDisplayNSViewInitialStateAllowsWindowDrag() {
        let view = ScrcpyDisplayNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        XCTAssertFalse(view.hasRenderedFrame)
        XCTAssertTrue(view.mouseDownCanMoveWindow)
    }
    
    @MainActor
    func testWindowDraggableAndTopHUDHitTesting() {
        let appState = AppState()
        appState.devices = []
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 360, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = true
        let standbyHosting = NSHostingView(rootView: PhoneMirrorFrameView(appState: appState))
        standbyHosting.frame = NSRect(x: 0, y: 0, width: 360, height: 760)
        window.contentView = standbyHosting
        standbyHosting.layoutSubtreeIfNeeded()
        
        // 1. Standby view hit-testing allows moving window
        for y in stride(from: 60.0, through: 700.0, by: 80.0) {
            let hit = standbyHosting.hitTest(NSPoint(x: 180, y: y))
            XCTAssertNotNil(hit)
            XCTAssertTrue(hit?.mouseDownCanMoveWindow ?? false)
        }
        
        // 2. Live mirroring view hit-testing reaches ScrcpyDisplayNSView in the center and top drag region
        appState.isMirroring = true
        let mirrorHosting = NSHostingView(rootView: PhoneMirrorFrameView(appState: appState))
        mirrorHosting.frame = NSRect(x: 0, y: 0, width: 360, height: 760)
        window.contentView = mirrorHosting
        mirrorHosting.layoutSubtreeIfNeeded()
        
        let centerHit = mirrorHosting.hitTest(NSPoint(x: 180, y: 380))
        XCTAssertTrue(centerHit is ScrcpyDisplayNSView, "Center of live screen must hit ScrcpyDisplayNSView")
        let topBarPassThroughHit = mirrorHosting.hitTest(NSPoint(x: 180, y: 728))
        XCTAssertTrue(topBarPassThroughHit is ScrcpyDisplayNSView, "Top drag strip outside HUD buttons must hit ScrcpyDisplayNSView")
    }
    
    func testLivePhoneMirroringAndADBDetailsIfConnected() async throws {
        let devices = await ADBService.shared.listDevices()
        guard let usbDevice = devices.first(where: { $0.state == .ready }) else {
            return
        }
        
        // Run two consecutive start/stop cycles to verify both frame rendering and VTDecompressionSession teardown safety
        for _ in 0..<2 {
            let displayView = await MainActor.run {
                let v = ScrcpyDisplayNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
                v.bindFrameCallback()
                return v
            }
            try await ScrcpyClient.shared.start(
                serial: usbDevice.id,
                maxSize: 1440,
                maxFps: 60,
                bitRate: 8_000_000,
                turnScreenOff: false,
                stayAwake: true
            )
            for _ in 0..<40 {
                let rendered = await MainActor.run { displayView.hasRenderedFrame }
                if rendered { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let hasRendered = await MainActor.run { displayView.hasRenderedFrame }
            let width = ScrcpyClient.shared.deviceWidth
            let height = ScrcpyClient.shared.deviceHeight
            let cachedImage = ScrcpyClient.shared.latestFrameImage
            ScrcpyClient.shared.stop()
            
            XCTAssertTrue(hasRendered, "Expected ScrcpyDisplayNSView to decode and render at least 1 real frame from connected phone \(usbDevice.id)")
            XCTAssertNotNil(cachedImage, "Expected ScrcpyClient.latestFrameImage to be cached")
            XCTAssertGreaterThan(width, 0)
            XCTAssertGreaterThan(height, 0)
        }
    }
    
    func testScrcpyClientConcurrentVideoAndControlSocketHandshake() async throws {
        let testPort = Int.random(in: 28100...28900)
        let listenSock = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenSock, 0)
        defer { close(listenSock) }
        
        var reuse: Int32 = 1
        setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(testPort).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRes, 0)
        XCTAssertEqual(listen(listenSock, 8), 0)
        
        final class SizeBox: @unchecked Sendable {
            var width = 0
            var height = 0
        }
        let sizeBox = SizeBox()
        ScrcpyClient.shared.onDeviceSizeKnown = { w, h in
            sizeBox.width = w
            sizeBox.height = h
        }
        
        // Spawn mock scrcpy-server on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. Simulate early adb forward race: accept and immediately close 1st connection without dummy byte
            let earlyConn = accept(listenSock, nil, nil)
            if earlyConn >= 0 {
                close(earlyConn)
            }
            
            // 2. Accept real videoSocket and send 1 dummy byte (0x00)
            let vConn = accept(listenSock, nil, nil)
            guard vConn >= 0 else { return }
            var dummy: UInt8 = 0x00
            _ = send(vConn, &dummy, 1, 0)
            
            // 3. Accept controlSocket and keep it open (blocking on recv on client side)
            let cConn = accept(listenSock, nil, nil)
            guard cConn >= 0 else {
                close(vConn)
                return
            }
            
            // 4. Send a 12-byte scrcpy framed H.264 config packet (valid SPS + PPS for 128x96 baseline)
            let sps: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2]
            let pps: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80]
            let payload = sps + pps
            var packet = Data(repeating: 0, count: 8) // 8-byte pts_and_flags
            var lenBE = UInt32(payload.count).bigEndian
            packet.append(Data(bytes: &lenBE, count: 4))
            packet.append(contentsOf: payload)
            
            packet.withUnsafeBytes { rawPtr in
                if let base = rawPtr.baseAddress {
                    _ = send(vConn, base, packet.count, 0)
                }
            }
            
            usleep(300_000)
            close(vConn)
            close(cConn)
        }
        
        try ScrcpyClient.shared.connectAndStartStreams(port: testPort, turnScreenOff: false)
        XCTAssertTrue(ScrcpyClient.shared.isConnected)
        
        for _ in 0..<25 {
            if ScrcpyClient.shared.deviceWidth == 128 || sizeBox.width == 128 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        
        let parsedW = ScrcpyClient.shared.deviceWidth
        let parsedH = ScrcpyClient.shared.deviceHeight
        ScrcpyClient.shared.stop()
        XCTAssertEqual(parsedW, 128, "Expected video stream reader to parse H.264 SPS width=128 concurrently while control socket is open")
        XCTAssertEqual(parsedH, 96, "Expected video stream reader to parse H.264 SPS height=96 concurrently while control socket is open")
    }
    
    func testParsePowerAndLockState() {
        let awakeUnlocked = ADBService.parsePowerAndLockState(
            powerDump: "  mWakefulness=Awake\n",
            policyDump: "    KeyguardServiceDelegate\n      showing=false\n"
        )
        XCTAssertFalse(awakeUnlocked.isScreenOff)
        XCTAssertFalse(awakeUnlocked.isLocked)
        
        let asleepLocked = ADBService.parsePowerAndLockState(
            powerDump: "  mWakefulness=Asleep\n",
            policyDump: "    KeyguardServiceDelegate\n      showing=true\n"
        )
        XCTAssertTrue(asleepLocked.isScreenOff)
        XCTAssertTrue(asleepLocked.isLocked)
        
        let dozingDreamLock = ADBService.parsePowerAndLockState(
            powerDump: "  mWakefulness=Dozing\n",
            policyDump: "  mShowingDream=false mDreamingLockscreen=true\n"
        )
        XCTAssertTrue(dozingDreamLock.isScreenOff)
        XCTAssertTrue(dozingDreamLock.isLocked)
    }

    func testShouldUseClipboardPasteForCyrillicAndASCII() {
        XCTAssertFalse(ScrcpyClient.shouldUseClipboardPaste(for: ""))
        XCTAssertFalse(ScrcpyClient.shouldUseClipboardPaste(for: "Hello, world! 123"))
        XCTAssertTrue(ScrcpyClient.shouldUseClipboardPaste(for: "Привет"))
        XCTAssertTrue(ScrcpyClient.shouldUseClipboardPaste(for: "а"))
        XCTAssertTrue(ScrcpyClient.shouldUseClipboardPaste(for: "Test Привет"))
    }

    func testFormatConnectFailureMessage() {
        let refusedRu = ADBService.formatConnectFailureMessage(
            host: "10.242.11.23",
            port: 41051,
            rawOutput: "failed to connect to '10.242.11.23:41051': Connection refused",
            lang: .russian
        )
        XCTAssertTrue(refusedRu.contains("10.242.11.23:41051"))
        XCTAssertTrue(refusedRu.contains("Сопряжение по PIN"))
        XCTAssertTrue(refusedRu.contains("хотспот"))

        let refusedEn = ADBService.formatConnectFailureMessage(
            host: "10.242.11.23",
            port: 41051,
            rawOutput: "failed to connect to '10.242.11.23:41051': Connection refused",
            lang: .english
        )
        XCTAssertTrue(refusedEn.contains("PIN Pairing"))
        XCTAssertTrue(refusedEn.contains("hotspot"))

        let empty = ADBService.formatConnectFailureMessage(host: "192.168.1.5", port: 5555, rawOutput: "   ", lang: .russian)
        XCTAssertEqual(empty, "Не удалось подключиться к 192.168.1.5:5555")
    }

    func testAppLanguageSystemResolutionAndLocalization() {
        XCTAssertEqual(AppLanguage.resolveSystemLanguage(preferredLanguages: ["ru-RU", "en-US"]), .russian)
        XCTAssertEqual(AppLanguage.resolveSystemLanguage(preferredLanguages: ["en-US", "ru-RU"]), .english)
        XCTAssertEqual(AppLanguage.resolveSystemLanguage(preferredLanguages: ["de-DE"]), .english)
        XCTAssertEqual(L10n.tr("Привет", "Hello", lang: .russian), "Привет")
        XCTAssertEqual(L10n.tr("Привет", "Hello", lang: .english), "Hello")
        XCTAssertEqual(KeyboardLanguageSyncService.formatInputLanguageNotice(code: "ru", uiLang: .english), "🌐 Input Language: Русский (RU)")
        XCTAssertEqual(KeyboardLanguageSyncService.formatInputLanguageNotice(code: "en", uiLang: .russian), "🌐 Язык ввода: English (EN)")
    }

    func testPhotoTransferParseMediaLinesAndFilters() {
        var lines: [String] = []
        for i in 1...60 {
            lines.append("179468526\(i)|/sdcard/DCIM/Camera/IMG_\(i).jpg")
        }
        lines.append("1794685000|/sdcard/Pictures/Screenshots/Screenshot_1.png")
        lines.append("1794684999|/sdcard/Download/photo_dl.webp")
        lines.append("1794684998|/sdcard/Movies/clip.mp4")
        let raw = lines.joined(separator: "\n")

        let all = PhotoTransferService.parseMediaLines(raw, folder: .all, limit: 500)
        XCTAssertEqual(all.count, 63, "Gallery should not truncate at 24 items")
        XCTAssertEqual(PhotoTransferService.parseMediaLines(raw, folder: .camera, limit: 500).count, 60)
        XCTAssertEqual(PhotoTransferService.parseMediaLines(raw, folder: .screenshots, limit: 500), ["/sdcard/Pictures/Screenshots/Screenshot_1.png"])
        XCTAssertEqual(PhotoTransferService.parseMediaLines(raw, folder: .downloads, limit: 500), ["/sdcard/Download/photo_dl.webp"])
        XCTAssertEqual(PhotoTransferService.parseMediaLines(raw, folder: .videos, limit: 500), ["/sdcard/Movies/clip.mp4"])
    }

    func testSmartphoneEdgeGestureDetection() {
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.02, y: 0.5), endNormalized: CGPoint(x: 0.18, y: 0.52)),
            .back
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.97, y: 0.5), endNormalized: CGPoint(x: 0.80, y: 0.51)),
            .back
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.96), endNormalized: CGPoint(x: 0.51, y: 0.82)),
            .home
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.96), endNormalized: CGPoint(x: 0.5, y: 0.65)),
            .home
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.96), endNormalized: CGPoint(x: 0.5, y: 0.35)),
            .appSwitcher
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.04), endNormalized: CGPoint(x: 0.5, y: 0.20)),
            .notifications
        )
        XCTAssertNil(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.5), endNormalized: CGPoint(x: 0.7, y: 0.5))
        )
    }

    func testTrackpadDragAndMouseWheelClamping() {
        let huge = ScrcpyDisplayNSView.trackpadDragDelta(scrollingDeltaX: 500, scrollingDeltaY: -500, viewSize: CGSize(width: 320, height: 700))
        XCTAssertEqual(huge.x, 0.08, accuracy: 0.0001)
        XCTAssertEqual(huge.y, -0.08, accuracy: 0.0001)

        let gentle = ScrcpyDisplayNSView.trackpadDragDelta(scrollingDeltaX: 16, scrollingDeltaY: 0, viewSize: CGSize(width: 320, height: 700))
        XCTAssertEqual(gentle.x, (16.0 * 0.75) / 320.0, accuracy: 0.0001)

        let wheel = ScrcpyDisplayNSView.clampedMouseWheelScroll(deltaX: -20, deltaY: 20)
        XCTAssertEqual(wheel.h, 0.35, accuracy: 0.0001)
        XCTAssertEqual(wheel.v, 0.35, accuracy: 0.0001)
    }

    func testFileBrowserParsingSortingAndEscaping() {
        XCTAssertEqual(FileBrowserService.shellEscape("/sdcard/My Folder/a'b.txt"), "'/sdcard/My Folder/a'\\''b.txt'")

        let sample = """
        regular file|2048|1794685000|/sdcard/notes.txt
        directory|4096|1794684000|/sdcard/DCIM
        regular file|512|1794686000|/sdcard/.nomedia
        regular file|1024000|1794685500|/sdcard/archive.zip
        """

        let visibleByName = FileBrowserService.parseStatListing(sample, includeHidden: false, sortOrder: .name)
        XCTAssertEqual(visibleByName.map(\.name), ["DCIM", "archive.zip", "notes.txt"])
        XCTAssertTrue(visibleByName[0].isDirectory)
        XCTAssertEqual(visibleByName[1].sfSymbolName, "doc.zipper")

        let withHiddenBySize = FileBrowserService.parseStatListing(sample, includeHidden: true, sortOrder: .size)
        XCTAssertEqual(withHiddenBySize.map(\.name), ["DCIM", "archive.zip", "notes.txt", ".nomedia"])
    }

    func testScrollHomeTriggerAtBottomEdge() {
        XCTAssertTrue(
            ScrcpyDisplayNSView.shouldTriggerScrollHome(
                startNormalizedY: 0.90,
                accumulatedUpwardDelta: 26,
                horizontalDelta: 4
            )
        )
        XCTAssertFalse(
            ScrcpyDisplayNSView.shouldTriggerScrollHome(
                startNormalizedY: 0.50,
                accumulatedUpwardDelta: 40,
                horizontalDelta: 0
            )
        )
        XCTAssertFalse(
            ScrcpyDisplayNSView.shouldTriggerScrollHome(
                startNormalizedY: 0.92,
                accumulatedUpwardDelta: 12,
                horizontalDelta: 0
            )
        )
        XCTAssertFalse(
            ScrcpyDisplayNSView.shouldTriggerScrollHome(
                startNormalizedY: 0.92,
                accumulatedUpwardDelta: 24,
                horizontalDelta: 25
            )
        )
    }

    // MARK: - Security, Concurrency & Resource Safety Tests

    func testFileBrowserPathSecurityAndDataLossPrevention() throws {
        // Traversal & null-byte injection must be rejected
        XCTAssertThrowsError(try FileBrowserService.validateRemotePath("/sdcard/../../etc/passwd"))
        XCTAssertThrowsError(try FileBrowserService.validateRemotePath("/sdcard/test\0.txt"))
        XCTAssertThrowsError(try FileBrowserService.validateRemotePath("relative/path"))

        // Destructive deletion on protected roots must be blocked
        let protectedRoots = [
            "/",
            "/sdcard",
            "/sdcard/",
            "/sdcard/DCIM",
            "/sdcard/Download",
            "/sdcard/Pictures",
            "/storage/emulated/0",
            "/system"
        ]
        for root in protectedRoots {
            XCTAssertThrowsError(
                try FileBrowserService.validateRemotePath(root, forDeletion: true),
                "Expected deletion of protected root \(root) to throw"
            )
        }

        // Valid user-level paths succeed
        XCTAssertEqual(try FileBrowserService.validateRemotePath("/sdcard/Download/photo.jpg"), "/sdcard/Download/photo.jpg")
        XCTAssertEqual(try FileBrowserService.validateRemotePath("/sdcard/Download/photo.jpg", forDeletion: true), "/sdcard/Download/photo.jpg")
    }

    func testADBSerialAndEndpointValidation() {
        XCTAssertTrue(ADBService.validateSerial("61061JEA307110"))
        XCTAssertTrue(ADBService.validateSerial("192.168.1.42:5555"))
        XCTAssertTrue(ADBService.validateSerial("adb-61061JEA307110-abc._adb-tls-connect._tcp"))

        XCTAssertFalse(ADBService.validateSerial(""))
        XCTAssertFalse(ADBService.validateSerial("-H"))
        XCTAssertFalse(ADBService.validateSerial("--help"))
        XCTAssertFalse(ADBService.validateSerial("12345;rm -rf /"))

        XCTAssertTrue(ADBService.validateTargetEndpoint("192.168.0.10:5555"))
        XCTAssertTrue(ADBService.validateTargetEndpoint("pixel.local:37123"))
        XCTAssertFalse(ADBService.validateTargetEndpoint("192.168.0.10"))
        XCTAssertFalse(ADBService.validateTargetEndpoint("-s 192.168.0.10:5555"))
        XCTAssertFalse(ADBService.validateTargetEndpoint("192.168.0.10:99999"))
    }

    func testADBTimeoutDoesNotHangAndCancelsCleanly() async {
        // Executing a non-existent or hanging command with a short timeout must return promptly
        let start = Date()
        do {
            _ = try await ADBService.shared.execute(arguments: ["wait-for-device"], timeoutSeconds: 0.25)
        } catch {
            // Expected timeout or adb-not-found error
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.5, "ADB watchdog timeout should not hang")
    }

    func testScrcpyVideoBufferCapPreventsOOM() {
        var normalBuffer = Data(repeating: 0xAA, count: 1024)
        XCTAssertFalse(ScrcpyClient.trimOversizedStreamBuffer(&normalBuffer, maxBytes: 4096))
        XCTAssertEqual(normalBuffer.count, 1024)

        var oversizedBuffer = Data(repeating: 0xBB, count: 8192)
        XCTAssertTrue(ScrcpyClient.trimOversizedStreamBuffer(&oversizedBuffer, maxBytes: 4096))
        XCTAssertEqual(oversizedBuffer.count, 0)
    }

    func testScrcpyConcurrentStartStopStressSafety() async {
        let client = ScrcpyClient.shared
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    if i % 2 == 0 {
                        client.sendControlMessage(Data([5]))
                    } else {
                        client.stop()
                    }
                    _ = client.isConnected
                }
            }
        }
        XCTAssertFalse(client.isConnected)
    }

    func testNotificationPayloadBoundsAndSanitization() throws {
        // Oversized payload (> 64 KB) must be rejected before decoding
        let oversized = Data(repeating: 0x20, count: NotificationService.maxIncomingPayloadBytes + 1)
        XCTAssertNil(NotificationService.parseNotificationPayload(oversized))

        // Long strings inside valid JSON must be truncated safely
        let longTitle = String(repeating: "A", count: 500)
        let longText = String(repeating: "B", count: 2500)
        let item = NotificationItem(
            packageName: "com.example.chat",
            appName: String(repeating: "App", count: 100),
            title: longTitle,
            text: longText,
            iconBase64: String(repeating: "X", count: 40_000)
        )
        let encoded = try JSONEncoder().encode(item)
        let parsed = NotificationService.parseNotificationPayload(encoded)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.appName.count, 200)
        XCTAssertEqual(parsed?.title.count, 200)
        XCTAssertEqual(parsed?.text.count, 1000)
        XCTAssertNil(parsed?.iconBase64)
    }

    func testPhotoCacheFilenameSanitization() {
        XCTAssertEqual(PhotoTransferService.sanitizedCacheFilename("../../etc/passwd"), "passwd")
        XCTAssertEqual(PhotoTransferService.sanitizedCacheFilename("IMG_001\0.jpg"), "IMG_001.jpg")
        XCTAssertTrue(PhotoTransferService.sanitizedCacheFilename("..").hasPrefix("file_"))
        XCTAssertEqual(PhotoTransferService.sanitizedCacheFilename("vacation.heic"), "vacation.heic")
    }

    func testAndroidAppLauncherParsingAndFriendlyNames() {
        let raw = """
        package:com.whatsapp
        package:org.telegram.messenger
        package:com.example.my_custom_notes
        package:com.whatsapp
        """
        let apps = AndroidAppLauncherService.parsePackageList(raw)
        XCTAssertEqual(apps.count, 3)
        XCTAssertTrue(apps.contains(where: { $0.packageName == "com.whatsapp" && $0.displayName == "WhatsApp" }))
        XCTAssertTrue(apps.contains(where: { $0.packageName == "org.telegram.messenger" && $0.displayName == "Telegram" }))
        XCTAssertTrue(apps.contains(where: { $0.packageName == "com.example.my_custom_notes" && $0.displayName == "My Custom Notes" }))
    }

    func testVisionOCRPixelCropRectAndContinuityImageEncoding() {
        let crop = VisionOCRService.pixelCropRect(
            normalizedRect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
            imageWidth: 1080,
            imageHeight: 2400
        )
        XCTAssertEqual(crop, CGRect(x: 270, y: 1200, width: 540, height: 600))

        // Out-of-bounds crop must clamp safely
        let clamped = VisionOCRService.pixelCropRect(
            normalizedRect: CGRect(x: -0.5, y: 0.9, width: 2.0, height: 0.5),
            imageWidth: 1000,
            imageHeight: 2000
        )
        XCTAssertEqual(clamped.origin.x, 0)
        XCTAssertLessThanOrEqual(clamped.maxX, 1000)
        XCTAssertLessThanOrEqual(clamped.maxY, 2000)

        // TIFF -> PNG conversion for ContinuityBridge
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        let tiff = rep?.tiffRepresentation
        let png = ContinuityBridge.encodePasteboardImageAsPNG(pngData: nil, tiffData: tiff)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png?.count ?? 0, 8)
    }

    @MainActor
    func testDeviceProfilePersistenceAndDefaults() {
        let appState = AppState()
        let serial = "test-serial-profile-\(UUID().uuidString)"
        XCTAssertEqual(appState.profile(for: serial), .default)

        let custom = DeviceProfile(bitRate: 16_000_000, maxFps: 120, maxSize: 1080)
        appState.updateProfile(custom, for: serial)
        XCTAssertEqual(appState.profile(for: serial), custom)
    }

    // MARK: - Built-in MCP Server & Android UI Tree Tests

    func testMCPServerInitializeToolsListAndKillSwitch() async throws {
        let core = MCPServerCore.shared
        core.isAgentPaused = false

        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#
        let initRespData = await core.handleRawRequestData(Data(initReq.utf8))
        XCTAssertNotNil(initRespData)
        let initJSON = try JSONSerialization.jsonObject(with: initRespData!) as? [String: Any]
        let initResult = initJSON?["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2024-11-05")

        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let listRespData = await core.handleRawRequestData(Data(listReq.utf8))
        XCTAssertNotNil(listRespData)
        let listJSON = try JSONSerialization.jsonObject(with: listRespData!) as? [String: Any]
        let listResult = listJSON?["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 9)

        // Kill-switch must block tool calls while paused
        core.isAgentPaused = true
        defer { core.isAgentPaused = false }
        let callReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"android_list_devices","arguments":{}}}"#
        let callRespData = await core.handleRawRequestData(Data(callReq.utf8))
        let callJSON = try JSONSerialization.jsonObject(with: callRespData!) as? [String: Any]
        let callResult = callJSON?["result"] as? [String: Any]
        XCTAssertEqual(callResult?["isError"] as? Bool, true)
    }

    func testAndroidUITreeParserStripsContainersAndComputesCenters() {
        let xml = """
        UI hierchary dumped to: /dev/tty
        <hierarchy rotation="0">
          <node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,2400]">
            <node index="1" text="Confirm" resource-id="com.app:id/btn_confirm" class="android.widget.Button" content-desc="" clickable="true" scrollable="false" bounds="[100,200][500,300]" />
            <node index="2" text="" resource-id="" class="android.view.ViewGroup" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,200]" />
          </node>
        </hierarchy>
        """
        let nodes = AndroidUITreeParser.parse(xmlString: xml)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].text, "Confirm")
        XCTAssertEqual(nodes[0].resource_id, "com.app:id/btn_confirm")
        XCTAssertEqual(nodes[0].class, "Button")
        XCTAssertEqual(nodes[0].center_x, 300)
        XCTAssertEqual(nodes[0].center_y, 250)
    }

    func testMCPNotificationsParser() {
        let dumpsys = """
        NotificationRecord(0x1234: pkg=org.telegram.messenger user=UserHandle{0} id=42)
          when=1731624000000
          android.title=String (Alice)
          android.text=String (Your code is 482910)
        NotificationRecord(0x5678: pkg=com.android.systemui user=UserHandle{0} id=1)
        """
        let parsed = AndroidMCPTools.parseNotifications(from: dumpsys)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].package, "org.telegram.messenger")
        XCTAssertEqual(parsed[0].title, "Alice")
        XCTAssertEqual(parsed[0].text, "Your code is 482910")
    }

    func testQRPairingPayloadFormat() {
        let payload = QRPairingService.buildQRPayload(serviceName: "ADB_WIFI_A1B2C3D4", password: "XYZ98765")
        XCTAssertEqual(payload, "WIFI:T:ADB;S:ADB_WIFI_A1B2C3D4;P:XYZ98765;;")
    }

    func testRouterlessBypassGatewayAndBluetoothPAN() {
        let netstat = """
        Routing tables
        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.43.1       UGScg                 en0
        127.0.0.1          127.0.0.1          UH                    lo0
        """
        XCTAssertEqual(RouterlessBypassService.parseDefaultGateway(fromNetstatOutput: netstat), "192.168.43.1")
        XCTAssertTrue(RouterlessBypassService.hasBluetoothPANSubnet(inAddresses: ["10.0.0.5", "192.168.44.128"]))
        XCTAssertFalse(RouterlessBypassService.hasBluetoothPANSubnet(inAddresses: ["192.168.1.50"]))
    }

    func testHEVCNALTypeDetection() {
        // HEVC NAL header byte: (nalType << 1)
        XCTAssertEqual(ScrcpyClient.hevcNALType(for: Data([32 << 1, 0x01])), 32) // VPS
        XCTAssertEqual(ScrcpyClient.hevcNALType(for: Data([33 << 1, 0x01])), 33) // SPS
        XCTAssertEqual(ScrcpyClient.hevcNALType(for: Data([34 << 1, 0x01])), 34) // PPS
        XCTAssertEqual(ScrcpyClient.hevcNALType(for: Data([19 << 1, 0x01])), 19) // IDR
    }

    @MainActor
    func testPerformanceEngineABRStepDownAndRecovery() {
        let engine = PerformanceEngine.shared
        engine.endMirroringSession()

        // 3 high-RTT samples should not trigger ABR yet
        for _ in 0..<3 {
            let res = engine.ingestProbeSample(rttMs: 145)
            XCTAssertFalse(res.changed)
            XCTAssertFalse(engine.isABRReduced)
        }
        // 4th consecutive sample >120ms (>2s) triggers step-down to 6M / 1280
        let stepDown = engine.ingestProbeSample(rttMs: 150)
        XCTAssertTrue(stepDown.changed)
        XCTAssertEqual(stepDown.bitRate, 6_000_000)
        XCTAssertEqual(stepDown.maxSize, 1280)
        XCTAssertTrue(engine.isABRReduced)

        // 7 low-RTT samples should not restore yet
        for _ in 0..<7 {
            let res = engine.ingestProbeSample(rttMs: 25)
            XCTAssertFalse(res.changed)
            XCTAssertTrue(engine.isABRReduced)
        }
        // 8th consecutive sample <60ms (4s) restores 16M / 1440
        let restore = engine.ingestProbeSample(rttMs: 22)
        XCTAssertTrue(restore.changed)
        XCTAssertEqual(restore.bitRate, 16_000_000)
        XCTAssertEqual(restore.maxSize, 1440)
        XCTAssertFalse(engine.isABRReduced)
        engine.endMirroringSession()
    }

    func testCommandInjectionResistanceAndPackageValidation() {
        // Package name validation
        XCTAssertTrue(ADBService.validatePackageName("com.whatsapp"))
        XCTAssertTrue(ADBService.validatePackageName("org.telegram.messenger"))
        XCTAssertFalse(ADBService.validatePackageName("com.whatsapp; id"))
        XCTAssertFalse(ADBService.validatePackageName("com.whatsapp$(reboot)"))
        XCTAssertFalse(ADBService.validatePackageName("-rf"))
        XCTAssertFalse(ADBService.validatePackageName("nodot"))
        XCTAssertFalse(ADBService.validatePackageName(""))

        // POSIX shell quoting
        let malicious = "hello'; rm -rf /; echo $(id) `uname` | cat > /tmp/x\0"
        let quoted = ADBService.shellQuote(malicious)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertFalse(quoted.contains("\0"))
        XCTAssertEqual(quoted, "'hello'\\''; rm -rf /; echo $(id) `uname` | cat > /tmp/x'")

        // android_type_text command builder
        let asciiInject = AndroidMCPTools.buildSafeTypeTextCommand("hi; id > /sdcard/pwn")
        XCTAssertFalse(asciiInject.useClipboard)
        XCTAssertEqual(asciiInject.quotedArg, "'hi;%sid%s>%s/sdcard/pwn'")

        let unicodeInject = AndroidMCPTools.buildSafeTypeTextCommand("Привет; $(reboot)\n")
        XCTAssertTrue(unicodeInject.useClipboard)
        XCTAssertEqual(unicodeInject.quotedArg, "'Привет; $(reboot)\n'")
    }

    func testMCPHTTPServerOriginHostAndBearerSecurity() async throws {
        // Loopback Host & Origin allowed
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n"))
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: [::1]:8765\r\n"))
        XCTAssertTrue(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: localhost:8765\r\nOrigin: http://localhost:3000\r\n"))

        // External Origin, prefix-spoofed Origin, or DNS-rebinding Host rejected
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: evil.com:8765\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: https://evil.com\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://localhost.evil.com\r\n"))
        XCTAssertFalse(MCPHTTPServer.validateOriginAndHost(headers: "POST /message HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nOrigin: http://127.0.0.1.evil.com\r\n"))

        // Bearer token validation
        let headersWithToken = "POST /message HTTP/1.1\r\nAuthorization: Bearer secret-session-token\r\n"
        XCTAssertTrue(MCPHTTPServer.validateBearerToken(headers: headersWithToken, expectedToken: "secret-session-token"))
        XCTAssertFalse(MCPHTTPServer.validateBearerToken(headers: headersWithToken, expectedToken: "wrong-token"))
        XCTAssertFalse(MCPHTTPServer.validateBearerToken(headers: "POST /message HTTP/1.1\r\n", expectedToken: "secret-session-token"))

        // Live NWListener socket integration test with Bearer token
        let server = MCPHTTPServer.shared
        let testPort: UInt16 = 18765
        let testToken = "live-session-secret-\(UUID().uuidString)"
        server.bearerToken = testToken

        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                return true
            }
        }
        let resumeOnce = ResumeOnce()
        let started = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            server.start(port: testPort) { isRunning in
                if resumeOnce.tryResume() {
                    cont.resume(returning: isRunning)
                }
            }
        }
        defer {
            server.bearerToken = nil
            server.stop()
        }
        XCTAssertTrue(started, "MCPHTTPServer should bind to 127.0.0.1:\(testPort)")

        let url = URL(string: "http://127.0.0.1:\(testPort)/")!

        // 1. Missing Bearer token -> 401
        var unauthReq = URLRequest(url: url)
        unauthReq.httpMethod = "GET"
        let (_, unauthResp) = try await URLSession.shared.data(for: unauthReq)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)

        // 2. Spoofed Origin -> 403
        var badOriginReq = URLRequest(url: url)
        badOriginReq.httpMethod = "GET"
        badOriginReq.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        badOriginReq.setValue("http://localhost.evil.com", forHTTPHeaderField: "Origin")
        let (_, badOriginResp) = try await URLSession.shared.data(for: badOriginReq)
        XCTAssertEqual((badOriginResp as? HTTPURLResponse)?.statusCode, 403)

        // 3. Valid Bearer token + loopback -> 200
        var okReq = URLRequest(url: url)
        okReq.httpMethod = "GET"
        okReq.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        let (_, okResp) = try await URLSession.shared.data(for: okReq)
        XCTAssertEqual((okResp as? HTTPURLResponse)?.statusCode, 200)
    }

    func testADBTaskCancellationAbortsImmediately() async {
        let start = Date()
        let task = Task {
            try await ADBService.shared.execute(arguments: ["wait-for-device"], timeoutSeconds: 10.0)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        _ = await task.result
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5, "Cancelling Task must abort ADBService.execute immediately without waiting for 10s timeout")
    }

    func testProcessLifecycleManagerTerminatesChildCleanly() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try? proc.run()
        XCTAssertTrue(proc.isRunning)

        ProcessLifecycleManager.shared.register(proc, tag: "test-sleep")
        ProcessLifecycleManager.shared.terminateProcesses(withTag: "test-sleep", gracePeriodMs: 100)

        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(proc.isRunning)
    }
}
