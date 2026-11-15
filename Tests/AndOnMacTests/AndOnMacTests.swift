import XCTest
import SwiftUI
import AppKit
import Network
@testable import AndOnMac
import AndroidShadowGraphKit

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

        let currentSubtypeOutput = "      mCurrentSubtype=android.view.inputmethod.InputMethodSubtype@9442b7f9"
        XCTAssertEqual(KeyboardLanguageSyncService.parseCurrentSubtype(from: currentSubtypeOutput), -1807566855)
        XCTAssertEqual(
            KeyboardLanguageSyncService.parseSubtypes(from: "mSubtypeId=0 mSubtypeLocale=fr_FR mSubtypeHashCode=-123456")["fr"],
            -123456
        )
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
        XCTAssertEqual(PhoneFrameStyle.pixel.cornerRadius, 44)
        XCTAssertTrue(PhoneFrameStyle.pixel.hasPunchHole)
        
        // Samsung Ultra
        let ultra1 = Device(id: "2", model: "SM-S928B", manufacturer: "Samsung") // S24 Ultra
        XCTAssertEqual(PhoneFrameStyle.detect(for: ultra1), .samsungUltra)
        XCTAssertEqual(PhoneFrameStyle.samsungUltra.cornerRadius, 12) // Sharp signature Ultra corners
        XCTAssertEqual(PhoneFrameStyle.samsungUltra.baseWidthMultiplier, 1.03)
        
        let ultra2 = Device(id: "3", model: "Galaxy S25 Ultra", manufacturer: "Samsung")
        XCTAssertEqual(PhoneFrameStyle.detect(for: ultra2), .samsungUltra)
        
        // Samsung Standard
        let s24 = Device(id: "4", model: "SM-S921B", manufacturer: "Samsung") // S24 Base
        XCTAssertEqual(PhoneFrameStyle.detect(for: s24), .samsung)
        XCTAssertEqual(PhoneFrameStyle.samsung.cornerRadius, 36)
        
        // Xiaomi
        let xiaomi = Device(id: "5", model: "Xiaomi 14", manufacturer: "Xiaomi")
        XCTAssertEqual(PhoneFrameStyle.detect(for: xiaomi), .xiaomi)
        XCTAssertEqual(PhoneFrameStyle.xiaomi.cornerRadius, 38)
        
        // Nothing Phone
        let nothing = Device(id: "6", model: "Phone (2)", manufacturer: "Nothing")
        XCTAssertEqual(PhoneFrameStyle.detect(for: nothing), .nothing)
        XCTAssertEqual(PhoneFrameStyle.nothing.cornerRadius, 40)
        
        // OnePlus
        let oneplus = Device(id: "7", model: "CPH2581", manufacturer: "OnePlus")
        XCTAssertEqual(PhoneFrameStyle.detect(for: oneplus), .oneplus)
        XCTAssertEqual(PhoneFrameStyle.oneplus.cornerRadius, 38)
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
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.89), endNormalized: CGPoint(x: 0.5, y: 0.72)),
            .home
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.89), endNormalized: CGPoint(x: 0.5, y: 0.45)),
            .appSwitcher
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.95), endNormalized: CGPoint(x: 0.5, y: 0.78), held: false),
            .home
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.95), endNormalized: CGPoint(x: 0.5, y: 0.78), held: true),
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

    func testHomeBarDragClassificationAndNonDraggableArea() {
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -5), .none)
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -10), .home)
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -41), .home)
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -42), .appSwitcher)
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -20, holdDuration: 0.22), .appSwitcher)
        XCTAssertEqual(PhoneMirrorFrameView.classifyHomeBarDrag(translationHeight: -90), .appSwitcher)
        XCTAssertFalse(NonDraggableNSView().mouseDownCanMoveWindow)
        XCTAssertFalse(HomeBarInteractiveNSView().mouseDownCanMoveWindow)
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

    func testADBDeviceFingerprintParsing() {
        let raw = """
        model=Pixel 11 Pro
        mfr=Google
        vendor=google
        vendor_model=Pixel 11 Pro
        vendor_brand=google
        vendor_device=mustang
        color=obsidian
        ver=17
        """
        let fp = ADBService.parseFingerprintOutput(raw)
        XCTAssertEqual(fp.model, "Pixel 11 Pro")
        XCTAssertEqual(fp.manufacturer, "Google")
        XCTAssertEqual(fp.vendor, "google")
        XCTAssertEqual(fp.codename, "mustang")
        XCTAssertEqual(fp.colorHint, "obsidian")
        XCTAssertEqual(fp.androidVersion, "17")
    }

    func testDeviceHardwareSpecsAndFallback() {
        let pixel11Pro = Device(id: "p11p", model: "Pixel 11 Pro", manufacturer: "Google", vendor: "google")
        let spec11Pro = DeviceHardwareSpec.resolve(for: pixel11Pro, override: .auto)
        XCTAssertEqual(spec11Pro.id, "pixel_11_pro")
        XCTAssertNotNil(spec11Pro.punchHole)

        let pixel11 = Device(id: "p11", model: "Pixel 11", manufacturer: "Google")
        XCTAssertEqual(DeviceHardwareSpec.resolve(for: pixel11, override: .auto).id, "pixel_11")

        let pixel10a = Device(id: "p10a", model: "Pixel 10a", manufacturer: "Google")
        XCTAssertEqual(DeviceHardwareSpec.resolve(for: pixel10a, override: .auto).id, "pixel_10a")

        let pixel9 = Device(id: "p9", model: "Pixel 9", manufacturer: "Google")
        let spec9 = DeviceHardwareSpec.resolve(for: pixel9, override: .auto)
        XCTAssertEqual(spec9.id, "pixel_8_9_10")
        XCTAssertEqual(spec9.punchHole?.normalizedCenterY ?? 0, 0.0258, accuracy: 0.0001)

        let s25u = Device(id: "s25u", model: "SM-S938B", manufacturer: "Samsung")
        XCTAssertEqual(DeviceHardwareSpec.resolve(for: s25u, override: .auto).id, "galaxy_s25_ultra")

        let s24u = Device(id: "s24u", model: "SM-S928U", manufacturer: "Samsung")
        XCTAssertEqual(DeviceHardwareSpec.resolve(for: s24u, override: .auto).id, "galaxy_s24_ultra")

        let nothing = Device(id: "np2", model: "A065", manufacturer: "Nothing")
        let npSpec = DeviceHardwareSpec.resolve(for: nothing, override: .auto)
        XCTAssertEqual(npSpec.id, "nothing_phone_2")
        XCTAssertTrue(npSpec.hasGlyphAccent)

        let op12 = Device(id: "op12", model: "CPH2581", manufacturer: "OnePlus")
        XCTAssertEqual(DeviceHardwareSpec.resolve(for: op12, override: .auto).id, "oneplus_12")

        // Unknown hardware falls back cleanly to Pro Display with no camera cutout
        let unknown = Device(id: "unk", model: "Fairphone 5", manufacturer: "Fairphone")
        let fallbackSpec = DeviceHardwareSpec.resolve(for: unknown, override: .auto)
        XCTAssertEqual(fallbackSpec.id, "pro_display")
        XCTAssertNil(fallbackSpec.punchHole)
    }

    func testPunchHoleCoordinatesAcrossScalesAndOrientations() {
        let hole = DeviceHardwareSpec.pixel11Pro.punchHole!
        let portrait100 = CGSize(width: 314, height: 698)
        let portrait125 = CGSize(width: 392.5, height: 872.5)
        let c100 = hole.resolvedCenter(in: portrait100, orientation: .portrait)
        let c125 = hole.resolvedCenter(in: portrait125, orientation: .portrait)
        XCTAssertEqual(c100.x, portrait100.width * 0.5, accuracy: 0.01)
        XCTAssertEqual(c125.y / portrait125.height, c100.y / portrait100.height, accuracy: 0.0001)
        XCTAssertGreaterThan(hole.resolvedRadius(in: portrait125), hole.resolvedRadius(in: portrait100))

        // Landscape rotation moves portrait top camera cleanly onto left edge
        let landscapeSize = CGSize(width: 698, height: 314)
        let cLand = hole.resolvedCenter(in: landscapeSize, orientation: .landscape)
        XCTAssertEqual(cLand.x, landscapeSize.width * hole.normalizedCenterY, accuracy: 0.01)
        XCTAssertEqual(cLand.y, landscapeSize.height * 0.5, accuracy: 0.01)
    }

    func testDeviceChassisFinishAndMatchDeviceColorToggle() {
        let porcelainPixel = Device(id: "p11p", model: "Pixel 11 Pro", manufacturer: "Google", deviceColorHint: "porcelain")
        let spec = DeviceHardwareSpec.pixel11Pro
        XCTAssertEqual(DeviceChassisFinish.resolve(for: porcelainPixel, spec: spec, matchDeviceColor: true), .porcelain)
        XCTAssertEqual(DeviceChassisFinish.resolve(for: porcelainPixel, spec: spec, matchDeviceColor: false), .obsidian)
    }

    func testCoreAnimationEvenOddScreenMaskLayer() {
        let layer = CoreAnimationDeviceMask.makeScreenMaskLayer(
            size: CGSize(width: 314, height: 698),
            cornerRadius: 42,
            punchHoleCenter: CGPoint(x: 157, y: 16.4),
            punchHoleRadius: 3.8
        )
        XCTAssertEqual(layer.fillRule, .evenOdd)
        XCTAssertNotNil(layer.path)
        XCTAssertEqual(layer.frame.size.width, 314, accuracy: 0.01)
    }

    func testAmbilightCoreImagePerimeterExtraction() {
        let topBlue = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1.0))
            .cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        let bottomRed = CIImage(color: CIColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1.0))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let composite = topBlue.composited(over: bottomRed)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        let palette = AmbilightEngine.extractPalette(from: composite, context: context)
        XCTAssertGreaterThan(palette.top.b, palette.top.r)
        XCTAssertGreaterThan(palette.bottom.r, palette.bottom.b)
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

    func testTrackpadFourEdgeGestureClassificationAndNaturalScrollingDeltas() {
        // Natural Scrolling ON (inverted): sliding fingers UP gives negative scrollingDeltaY -> positive upwardDelta
        XCTAssertEqual(ScrcpyDisplayNSView.upwardTrackpadDelta(scrollingDeltaY: -24, isDirectionInverted: true), 24)
        XCTAssertEqual(ScrcpyDisplayNSView.upwardTrackpadDelta(scrollingDeltaY: 24, isDirectionInverted: false), 24)
        XCTAssertEqual(ScrcpyDisplayNSView.horizontalTrackpadFingerDelta(scrollingDeltaX: 25, isDirectionInverted: true), 25)
        XCTAssertEqual(ScrcpyDisplayNSView.horizontalTrackpadFingerDelta(scrollingDeltaX: -25, isDirectionInverted: false), 25)

        // Edge intents differentiate edge gesture vs normal scrolling near bottom/side edges
        XCTAssertEqual(
            ScrcpyDisplayNSView.classifyTrackpadEdgeIntent(startNormalized: CGPoint(x: 0.5, y: 0.90), accumulatedUpwardDelta: 10, accumulatedFingerX: 0),
            .bottomHomeSwitcher
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.classifyTrackpadEdgeIntent(startNormalized: CGPoint(x: 0.5, y: 0.90), accumulatedUpwardDelta: -14, accumulatedFingerX: 0),
            .pan
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.classifyTrackpadEdgeIntent(startNormalized: CGPoint(x: 0.04, y: 0.5), accumulatedUpwardDelta: 0, accumulatedFingerX: 12),
            .edgeGesture
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.classifyTrackpadEdgeIntent(startNormalized: CGPoint(x: 0.96, y: 0.5), accumulatedUpwardDelta: 0, accumulatedFingerX: -12),
            .edgeGesture
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.classifyTrackpadEdgeIntent(startNormalized: CGPoint(x: 0.5, y: 0.04), accumulatedUpwardDelta: -12, accumulatedFingerX: 0),
            .edgeGesture
        )

        // Edge Back & Notifications triggers
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectTrackpadEdgeGesture(startNormalized: CGPoint(x: 0.03, y: 0.5), accumulatedUpwardDelta: 2, accumulatedFingerX: 24),
            .back
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectTrackpadEdgeGesture(startNormalized: CGPoint(x: 0.96, y: 0.5), accumulatedUpwardDelta: -2, accumulatedFingerX: -24),
            .back
        )
        XCTAssertEqual(
            ScrcpyDisplayNSView.detectTrackpadEdgeGesture(startNormalized: CGPoint(x: 0.5, y: 0.04), accumulatedUpwardDelta: -26, accumulatedFingerX: 3),
            .notifications
        )
    }

    @MainActor
    func testBottomTrackpadSwipeTrackerHomeVsAppSwitcher() async {
        // 1. Quick upward flick fires Home ONLY on finger lift (.ended), never mid-gesture
        var homeCount = 0
        var appSwitchCount = 0
        let tracker = BottomTrackpadSwipeTracker()
        tracker.onHomeTriggered = { homeCount += 1 }
        tracker.onAppSwitcherTriggered = { appSwitchCount += 1 }

        tracker.process(upwardDelta: 6, fingerDeltaX: 0, phase: .began, momentumPhase: [])
        tracker.process(upwardDelta: 24, fingerDeltaX: 0, phase: .changed, momentumPhase: [])
        XCTAssertEqual(homeCount, 0, "Must not fire Home prematurely during upward swipe before lift")
        XCTAssertEqual(appSwitchCount, 0)
        tracker.process(upwardDelta: 0, fingerDeltaX: 0, phase: .ended, momentumPhase: [])
        XCTAssertEqual(homeCount, 1)
        XCTAssertEqual(appSwitchCount, 0)

        // 2. Tall upward swipe fires App Switcher immediately without triggering Home
        tracker.process(upwardDelta: 10, fingerDeltaX: 0, phase: .began, momentumPhase: [])
        tracker.process(upwardDelta: 82, fingerDeltaX: 0, phase: .changed, momentumPhase: [])
        XCTAssertEqual(appSwitchCount, 1)
        XCTAssertEqual(homeCount, 1)
        tracker.process(upwardDelta: 0, fingerDeltaX: 0, phase: .ended, momentumPhase: [])
        XCTAssertEqual(homeCount, 1, "Must not fire Home after App Switcher already triggered")

        // 3. Upward swipe + stationary pause (~0.25s) fires App Switcher without firing Home
        tracker.process(upwardDelta: 6, fingerDeltaX: 0, phase: .began, momentumPhase: [])
        tracker.process(upwardDelta: 22, fingerDeltaX: 0, phase: .changed, momentumPhase: [])
        try? await Task.sleep(nanoseconds: 280_000_000)
        XCTAssertEqual(appSwitchCount, 2, "Pausing fingers during upward trackpad swipe should trigger App Switcher")
        tracker.process(upwardDelta: 0, fingerDeltaX: 0, phase: .ended, momentumPhase: [])
        XCTAssertEqual(homeCount, 1)
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

        let queryActivitiesOutput = """
        priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false
            com.google.android.youtube/.app.honeycomb.Shell$HomeActivity
            com.google.android.apps.youtube.music/.activities.MusicActivity
        """
        let launchable = AndroidAppLauncherService.parsePackageList(queryActivitiesOutput)
        XCTAssertEqual(launchable.count, 2)
        XCTAssertTrue(launchable.contains(where: { $0.packageName == "com.google.android.youtube" && $0.displayName == "YouTube" }))
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
        XCTAssertEqual(tools?.count, 10)
        XCTAssertTrue(tools?.contains(where: { ($0["name"] as? String) == "android_navigate_to_node" }) == true)

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
        let samplePin = String(repeating: "0", count: 8)
        let payload = QRPairingService.buildQRPayload(serviceName: "ADB_WIFI_A1B2C3D4", password: samplePin)
        XCTAssertEqual(payload, "WIFI:T:ADB;S:ADB_WIFI_A1B2C3D4;P:\(samplePin);;")
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

    func testFrameChangeDetectorDetectsStaticVsChangedFrames() throws {
        let detector = FrameChangeDetector()

        func makeSolidImage(gray: UInt8) throws -> CGImage {
            var pixels = [UInt8](repeating: gray, count: 64 * 64)
            let cs = CGColorSpaceCreateDeviceGray()
            let ctx = try XCTUnwrap(CGContext(
                data: &pixels,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 64,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            return try XCTUnwrap(ctx.makeImage())
        }

        let dark = try makeSolidImage(gray: 20)
        let darkAgain = try makeSolidImage(gray: 20)
        let bright = try makeSolidImage(gray: 220)

        XCTAssertTrue(detector.hasFrameChanged(dark))
        XCTAssertFalse(detector.hasFrameChanged(darkAgain))
        XCTAssertTrue(detector.hasFrameChanged(bright))

        detector.reset()
        XCTAssertTrue(detector.hasFrameChanged(bright))
    }

    func testScreenMemoryDatabaseFTS5SearchAndRetentionPruning() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andonmac-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = ScreenMemoryDatabase(baseDirectoryURL: tmpDir)
        let oldThumb = "old.jpg"
        let recentThumb = "recent.jpg"
        try Data("old".utf8).write(to: db.thumbnailsDirectoryURL.appendingPathComponent(oldThumb))
        try Data("recent".utf8).write(to: db.thumbnailsDirectoryURL.appendingPathComponent(recentThumb))

        let now = Date()
        let tenDaysAgo = now.addingTimeInterval(-10 * 86_400)

        XCTAssertNotNil(db.insertSnapshot(
            timestamp: tenDaysAgo,
            appPackageName: "com.old.app",
            extractedText: "Archived invoice 9012",
            thumbnailFilename: oldThumb,
            frameHash: 111
        ))
        XCTAssertNotNil(db.insertSnapshot(
            timestamp: now,
            appPackageName: "com.bank.app",
            extractedText: "Checking account balance is $4,250.00",
            thumbnailFilename: recentThumb,
            frameHash: 222
        ))

        let hits = db.search(query: "bal")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.appPackageName, "com.bank.app")
        XCTAssertTrue(hits.first?.highlightedSnippet.contains("«balance»") == true)

        let pruned = db.pruneRetention(now: now, olderThanDays: 7)
        XCTAssertEqual(pruned, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.thumbnailsDirectoryURL.appendingPathComponent(oldThumb).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.thumbnailsDirectoryURL.appendingPathComponent(recentThumb).path))
        XCTAssertEqual(db.stats().count, 1)

        db.clearAll()
        XCTAssertEqual(db.stats().count, 0)
    }

    func testScreenMemoryForegroundPackageParser() {
        let dumpsys = """
        mCurrentFocus=Window{9a1b2c u0 com.whatsapp/com.whatsapp.HomeActivity}
        mFocusedApp=ActivityRecord{12345 u0 com.whatsapp/.HomeActivity t19}
        """
        XCTAssertEqual(ScreenMemorySnapshotter.parseForegroundPackage(from: dumpsys), "com.whatsapp")
        XCTAssertEqual(ScreenMemorySnapshotter.parseForegroundPackage(from: "nothing here"), "unknown")
    }

    func testVisualNodeMatcherMapsUIAutomatorNodeAndFallback() {
        let xml = """
        <hierarchy rotation="0">
          <node index="0" text="" resource-id="" class="android.widget.LinearLayout" content-desc="" clickable="false" scrollable="false" bounds="[0,0][1080,2400]">
            <node index="1" text="$4,250.00" resource-id="com.bank.app:id/balance_amount" class="android.widget.TextView" content-desc="Account balance" clickable="false" scrollable="false" bounds="[100,400][540,520]" />
            <node index="2" text="Transfer" resource-id="com.bank.app:id/btn_transfer" class="android.widget.Button" content-desc="" clickable="true" scrollable="false" bounds="[600,400][980,520]" />
          </node>
        </hierarchy>
        """
        let nodes = AndroidUITreeParser.parse(xmlString: xml)
        // Drag box over the balance TextView (~x: 0.1..0.5, y: 0.16..0.22 on 1080x2400)
        let normRect = CGRect(x: 0.09, y: 0.165, width: 0.41, height: 0.055)
        let matched = VisualNodeMatcher.matchBestNode(
            normalizedRect: normRect,
            deviceWidth: 1080,
            deviceHeight: 2400,
            nodes: nodes
        )
        XCTAssertEqual(matched.node?.resource_id, "com.bank.app:id/balance_amount")
        XCTAssertEqual(matched.node?.text, "$4,250.00")
        XCTAssertEqual(matched.node?.class, "TextView")
        XCTAssertGreaterThan(matched.iouScore, 0.7)

        // Out-of-bounds drag should fall back to pixel center without matching a node
        let emptyArea = CGRect(x: 0.1, y: 0.85, width: 0.2, height: 0.05)
        let fallback = VisualNodeMatcher.matchBestNode(
            normalizedRect: emptyArea,
            deviceWidth: 1080,
            deviceHeight: 2400,
            nodes: nodes
        )
        XCTAssertNil(fallback.node)
        XCTAssertEqual(fallback.fallbackCenterX, 216)
        XCTAssertEqual(fallback.fallbackCenterY, 2100)
    }

    func testCustomMCPToolSchemaValidationAndJSONRPCDefinition() throws {
        XCTAssertTrue(CustomMCPToolSchema.isValidToolName("get_bank_balance"))
        XCTAssertFalse(CustomMCPToolSchema.isValidToolName("android_tap_element"))
        XCTAssertFalse(CustomMCPToolSchema.isValidToolName("Bad Name!"))
        XCTAssertFalse(CustomMCPToolSchema.isValidParameterName("serial"))
        XCTAssertTrue(CustomMCPToolSchema.isValidParameterName("account_id"))

        let schema = CustomMCPToolSchema(
            name: "tap_transfer",
            description: "Tap the Transfer button",
            isEnabled: true,
            action: .tapElement,
            target: VisualNodeTarget(
                resourceId: "com.bank.app:id/btn_transfer",
                className: "Button",
                text: "Transfer",
                contentDesc: nil,
                fallbackX: 790,
                fallbackY: 460,
                normalizedRect: [0.55, 0.16, 0.35, 0.05]
            ),
            parameters: [
                CustomMCPParameter(name: "amount", type: "integer", description: "Transfer amount", required: true)
            ]
        )
        try schema.validate()
        let def = schema.toMCPToolDefinition()
        XCTAssertEqual(def.name, "tap_transfer")
        let props = def.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(props?["serial"])
        XCTAssertNotNil(props?["amount"])
        if case .array(let reqValues) = def.inputSchema.objectValue?["required"] {
            XCTAssertEqual(reqValues.compactMap(\.stringValue), ["amount"])
        } else {
            XCTFail("Expected required array in inputSchema")
        }
    }

    func testCustomMCPToolRegistryPersistenceAndImportExport() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andonmac-mcptools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = CustomMCPToolRegistry(directoryURL: tmpDir)
        XCTAssertTrue(registry.allToolsSnapshot().isEmpty)

        let schema = CustomMCPToolSchema(
            name: "get_bank_balance",
            description: "Read current balance",
            isEnabled: true,
            action: .readTextUIAutomator,
            target: VisualNodeTarget(
                resourceId: "com.bank.app:id/balance_amount",
                className: "TextView",
                text: "$4,250.00",
                contentDesc: nil,
                fallbackX: 320,
                fallbackY: 460,
                normalizedRect: [0.09, 0.16, 0.41, 0.05]
            )
        )
        try registry.saveTool(schema)
        XCTAssertEqual(registry.enabledMCPDefinitions().map(\.name), ["get_bank_balance"])

        let exported = try registry.exportJSON(name: "get_bank_balance")
        try registry.setEnabled(name: "get_bank_balance", enabled: false)
        XCTAssertTrue(registry.enabledMCPDefinitions().isEmpty)

        try registry.deleteTool(name: "get_bank_balance")
        XCTAssertTrue(registry.allToolsSnapshot().isEmpty)

        let imported = try registry.importFromJSON(exported)
        XCTAssertEqual(imported.name, "get_bank_balance")
        XCTAssertTrue(imported.isEnabled)
    }

    func testMCPServerCoreAdvertisesListChangedAndLoadsTools() async throws {
        let initReq = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}".utf8)
        let initResp = await MCPServerCore.shared.handleRawRequestData(initReq)
        let initText = try XCTUnwrap(initResp.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(initText.contains("\"listChanged\":true"))

        let listReq = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8)
        let listResp = await MCPServerCore.shared.handleRawRequestData(listReq)
        let listText = try XCTUnwrap(listResp.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(listText.contains("android_tap_element"))
        XCTAssertTrue(listText.contains("android_navigate_to_node"))
    }

    func testAndroidNavigateToNodeHashParsingAndOutcomeFormatting() throws {
        XCTAssertEqual(try AndroidMCPTools.parseLayoutHash(.string("0x1a2b3c4d")), 0x1a2b3c4d)
        XCTAssertEqual(try AndroidMCPTools.parseLayoutHash(.string("123456789")), 123456789)
        XCTAssertEqual(try AndroidMCPTools.parseLayoutHash(.string("deadbeef")), 0xdeadbeef)
        XCTAssertNil(try AndroidMCPTools.parseLayoutHash(.string("   ")))
        XCTAssertThrowsError(try AndroidMCPTools.parseLayoutHash(.string("not_a_hash")))

        let devRes = AndroidMCPTools.formatPathDeviationResult(.stepTimeout(
            stepIndex: 1,
            expectedTargetHash: 0xABCD,
            lastObservedHash: 0x1234,
            lastObservedPackage: "com.popup",
            timeoutMs: 2000
        ))
        XCTAssertTrue(devRes.isError)
        let text = AndroidMCPTools.formatNavigationOutcome(.noRoute(
            startHash: 0x1111,
            activePackage: "com.launcher",
            candidateTargetHashes: [0x2222],
            reachableVertexCount: 3,
            knownVertexCount: 5
        ))
        XCTAssertTrue(text.isError)
    }

    func testMultiStepMacroSchemaAutoParametersAndOverrides() throws {
        let searchTarget = VisualNodeTarget(
            resourceId: "com.chat:id/search_btn",
            className: "ImageButton",
            text: "Search",
            contentDesc: "Search chats",
            fallbackX: 900,
            fallbackY: 160,
            normalizedRect: [0.8, 0.05, 0.1, 0.05]
        )
        let inputTarget = VisualNodeTarget(
            resourceId: "com.chat:id/composer",
            className: "EditText",
            text: nil,
            contentDesc: "Message",
            fallbackX: 400,
            fallbackY: 2200,
            normalizedRect: [0.1, 0.88, 0.7, 0.06]
        )
        let sendTarget = VisualNodeTarget(
            resourceId: "com.chat:id/send_btn",
            className: "ImageButton",
            text: "Send",
            contentDesc: nil,
            fallbackX: 980,
            fallbackY: 2200,
            normalizedRect: [0.85, 0.88, 0.1, 0.06]
        )

        let macro = CustomMCPToolSchema(
            name: "send_chat_macro",
            description: "Search contact and send a message",
            isEnabled: true,
            action: .macro,
            target: searchTarget,
            parameters: [],
            steps: [
                VisualMacroStep(action: .tapElement, target: searchTarget, delayAfterMs: 300),
                VisualMacroStep(action: .typeText, target: inputTarget, textTemplate: "{{contact_name}}", delayAfterMs: 500),
                VisualMacroStep(action: .typeText, target: inputTarget, textTemplate: "{{message_body}}", delayAfterMs: 350),
                VisualMacroStep(action: .tapElement, target: sendTarget, delayAfterMs: 250)
            ],
            defaultStepDelayMs: 650,
            maxSteps: 12,
            maxDurationSeconds: 25,
            selfHealingEnabled: true
        )
        try macro.validate()

        // Verify {{contact_name}} and {{message_body}} auto-exposed in JSON-RPC MCP schema
        let def = macro.toMCPToolDefinition()
        let props = def.inputSchema.objectValue?["properties"]?.objectValue
        XCTAssertNotNil(props?["contact_name"])
        XCTAssertNotNil(props?["message_body"])

        let interpolated = CustomMCPToolSchema.interpolateTemplate(
            "Hello {{contact_name}}: {{message_body}}",
            arguments: [
                "contact_name": .string("Alex"),
                "message_body": .string("See you at 5")
            ]
        )
        XCTAssertEqual(interpolated, "Hello Alex: See you at 5")

        // Verify per-tool overrides take precedence over global UserDefaults
        XCTAssertEqual(macro.effectiveStepDelayMs(), 650)
        XCTAssertEqual(macro.effectiveMaxSteps(), 12)
        XCTAssertEqual(macro.effectiveMaxDurationSeconds(), 25)
        XCTAssertTrue(macro.effectiveSelfHealingEnabled())

        // Verify legacy single-action JSON decodes cleanly with nil macro/override fields
        let legacyJSON = """
        {
          "name": "legacy_tap",
          "description": "Legacy tool",
          "isEnabled": true,
          "action": "tap_element",
          "target": {
            "resourceId": "com.app:id/ok",
            "fallbackX": 500,
            "fallbackY": 1000,
            "normalizedRect": [0.4, 0.4, 0.2, 0.1]
          },
          "parameters": [],
          "createdAt": "2026-11-15T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLegacy = try decoder.decode(CustomMCPToolSchema.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decodedLegacy.steps)
        XCTAssertNil(decodedLegacy.defaultStepDelayMs)
    }

    func testSelfHealingThreeTierTapResolution() async {
        let target = VisualNodeTarget(
            resourceId: "com.bank.app:id/old_transfer_btn",
            className: "Button",
            text: "Transfer",
            contentDesc: nil,
            fallbackX: 100,
            fallbackY: 200,
            normalizedRect: [0.1, 0.1, 0.2, 0.05]
        )

        // Tier 1: Exact resource-id found -> uses XML node coordinates, never calls Vision OCR
        let matchingNode = AndroidUINode(
            index: 0,
            text: "Transfer",
            resource_id: "com.bank.app:id/old_transfer_btn",
            content_desc: "",
            class: "Button",
            clickable: true,
            scrollable: false,
            bounds: "[250,580][450,660]",
            center_x: 350,
            center_y: 620
        )
        let tier1 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [matchingNode],
            target: target,
            selfHealingEnabled: true
        ) { _ in
            XCTFail("Vision OCR should not be called when resource-id matches")
            return nil
        }
        XCTAssertEqual(tier1.strategy, .resourceId)
        XCTAssertEqual(tier1.x, 350)
        XCTAssertEqual(tier1.y, 620)

        // Tier 2: App updated its resource-id, so XML lacks old ID -> Vision OCR heals it
        let updatedNodeDifferentText = AndroidUINode(
            index: 1,
            text: "Home",
            resource_id: "com.bank.app:id/nav_home",
            content_desc: "",
            class: "Button",
            clickable: true,
            scrollable: false,
            bounds: "[60,2150][180,2250]",
            center_x: 120,
            center_y: 2200
        )
        let tier2 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [updatedNodeDifferentText],
            target: target,
            selfHealingEnabled: true
        ) { query in
            XCTAssertEqual(query, "Transfer")
            return (x: 780, y: 1450, matchedText: "Transfer")
        }
        XCTAssertEqual(tier2.strategy, .visionOCRHealed)
        XCTAssertEqual(tier2.x, 780)
        XCTAssertEqual(tier2.y, 1450)
        XCTAssertEqual(tier2.healedText, "Transfer")

        // Tier 3: Self-Healing disabled -> falls back directly without Vision OCR
        let tier3 = await CustomMCPToolExecutor.resolveTapStrategy(
            nodes: [updatedNodeDifferentText],
            target: target,
            selfHealingEnabled: false
        ) { _ in
            XCTFail("Vision OCR must not run when selfHealingEnabled is false")
            return nil
        }
        XCTAssertEqual(tier3.strategy, .coordinateFallback)
        XCTAssertEqual(tier3.x, 100)
        XCTAssertEqual(tier3.y, 200)
    }

    func testProcessLifecycleManagerRegistrationAndCleanup() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["5"]
        try proc.run()
        let trackedId = ProcessLifecycleManager.shared.register(proc, tag: "unit-test")
        XCTAssertGreaterThanOrEqual(ProcessLifecycleManager.shared.activeCount, 1)
        ProcessLifecycleManager.shared.terminateProcess(proc, gracePeriodMs: 100)
        proc.waitUntilExit()
        ProcessLifecycleManager.shared.unregister(trackedId)
        XCTAssertFalse(proc.isRunning)
    }

    func testAgenticHUDCoordinateMapperHandlesAspectFitLetterboxPillarboxAndEndXY() {
        // Exact 9:20 fit -> videoRect matches bounds
        let exactRect = AgenticHUDCoordinateMapper.videoRect(
            in: CGSize(width: 320, height: 711.1111),
            deviceWidth: 1080,
            deviceHeight: 2400
        )
        XCTAssertEqual(exactRect.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(exactRect.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(exactRect.width, 320, accuracy: 0.5)

        // Pillarbox (wide view for portrait phone)
        let pillarRect = AgenticHUDCoordinateMapper.videoRect(
            in: CGSize(width: 400, height: 400),
            deviceWidth: 1000,
            deviceHeight: 2000
        )
        XCTAssertEqual(pillarRect.width, 200, accuracy: 0.01)
        XCTAssertEqual(pillarRect.origin.x, 100, accuracy: 0.01)
        XCTAssertEqual(pillarRect.origin.y, 0, accuracy: 0.01)

        let centerPt = AgenticHUDCoordinateMapper.viewPoint(
            deviceX: 500,
            deviceY: 1000,
            in: CGSize(width: 400, height: 400),
            deviceWidth: 1000,
            deviceHeight: 2000
        )
        XCTAssertEqual(centerPt.x, 200, accuracy: 0.01)
        XCTAssertEqual(centerPt.y, 200, accuracy: 0.01)

        // Letterbox (tall view for wide landscape phone)
        let letterRect = AgenticHUDCoordinateMapper.videoRect(
            in: CGSize(width: 400, height: 400),
            deviceWidth: 2000,
            deviceHeight: 1000
        )
        XCTAssertEqual(letterRect.height, 200, accuracy: 0.01)
        XCTAssertEqual(letterRect.origin.y, 100, accuracy: 0.01)

        // Zero-size defensive edge case
        let zeroRect = AgenticHUDCoordinateMapper.videoRect(in: .zero, deviceWidth: 0, deviceHeight: 0)
        XCTAssertEqual(zeroRect, .zero)

        // Target coordinate extraction: prefers (endX, endY), falls back to (x, y)
        let swipe = AttributedUIAction(kind: .swipe, targetDescription: "Scroll", x: 540, y: 1800, endX: 540, endY: 620)
        let swipeTarget = AgenticHUDCoordinateMapper.targetCoordinates(for: swipe)
        XCTAssertEqual(swipeTarget?.x, 540)
        XCTAssertEqual(swipeTarget?.y, 620)

        let tap = AttributedUIAction(kind: .tap, targetDescription: "Battery Share", x: 312, y: 1140)
        let tapTarget = AgenticHUDCoordinateMapper.targetCoordinates(for: tap)
        XCTAssertEqual(tapTarget?.x, 312)
        XCTAssertEqual(tapTarget?.y, 1140)

        let key = AttributedUIAction(kind: .keyevent, targetDescription: "BACK")
        XCTAssertNil(AgenticHUDCoordinateMapper.targetCoordinates(for: key))
    }

    @MainActor
    func testAgenticHUDViewModelTransitionsAndCrosshairHitTesting() async {
        let vm = AgenticHUDViewModel()
        XCTAssertNil(vm.toastTitle)
        XCTAssertEqual(vm.toastPhase, .idle)
        XCTAssertNil(vm.activeReticle)

        vm.handle(event: .pathComputed(totalSteps: 4, targetHint: "Battery Share"))
        XCTAssertEqual(vm.toastTitle, "🤖 A* Path Computed: 4 steps. Executing...")
        XCTAssertEqual(vm.toastSubtitle, "Target: Battery Share")
        XCTAssertEqual(vm.toastPhase, .executing)

        let action = AttributedUIAction(
            kind: .tap,
            targetDescription: "Battery Share",
            x: 540,
            y: 1200,
            endX: 545,
            endY: 1210
        )
        vm.handle(event: .willExecuteAction(stepIndex: 1, totalSteps: 4, action: action))
        XCTAssertEqual(vm.activeReticle?.x, 545)
        XCTAssertEqual(vm.activeReticle?.y, 1210)
        XCTAssertEqual(vm.toastPhase, .executing)

        let report = MacroExecutionReport(startHash: 1, finalHash: 2, steps: [], totalElapsedMs: 142)
        vm.handle(event: .completed(report: report))
        XCTAssertEqual(vm.toastPhase, .completed)
        XCTAssertEqual(vm.toastTitle, "🤖 Arrived in 142ms (0 steps)")

        vm.handle(event: .failed(message: "Timeout"))
        XCTAssertEqual(vm.toastPhase, .failed)
        XCTAssertEqual(vm.toastSubtitle, "Timeout")

        // Verify AgenticCrosshairNSView is top-left flipped and never intercepts mouse events
        let crosshairView = AgenticCrosshairNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        XCTAssertTrue(crosshairView.isFlipped)
        XCTAssertNil(crosshairView.hitTest(NSPoint(x: 160, y: 350)))
        crosshairView.update(reticle: vm.activeReticle, deviceWidth: 1080, deviceHeight: 2400)
        crosshairView.layout()
        crosshairView.update(reticle: nil, deviceWidth: 1080, deviceHeight: 2400)

        vm.clear()
        XCTAssertEqual(vm.toastPhase, .idle)
        XCTAssertNil(vm.activeReticle)
    }

    @MainActor
    func testAgenticHUDViewModelStreamsFromMacroExecutionEngineWithoutBlocking() async throws {
        let domState = ShadowDOMState()
        let graphEngine = SpatialGraphEngine()

        let nodeA = ShadowUINode(
            index: 0, text: "Settings", resourceId: "", contentDesc: "", className: "TextView",
            clickable: false, scrollable: false, bounds: "[0,0][200,100]", centerX: 100, centerY: 50,
            nodeId: 1, parentId: nil, windowId: 1, childIndex: 0, depth: 1,
            packageName: "com.android.settings", editable: false, focused: false, checked: false,
            enabled: true, visible: true
        )
        let nodeB = ShadowUINode(
            index: 0, text: "Battery Share", resourceId: "", contentDesc: "", className: "TextView",
            clickable: true, scrollable: false, bounds: "[100,1100][500,1300]", centerX: 300, centerY: 1200,
            nodeId: 2, parentId: nil, windowId: 1, childIndex: 0, depth: 1,
            packageName: "com.android.settings", editable: false, focused: false, checked: false,
            enabled: true, visible: true
        )

        await domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 1, timestampMs: 100, reason: "init", activePackage: "com.android.settings",
            activeWindowId: 1, nodeCount: 1, nodes: [nodeA]
        )))
        let fpA = ScreenLayoutHasher().fingerprint(for: await domState.currentIndex!)
        let idxB = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: [nodeB])
        let fpB = ScreenLayoutHasher().fingerprint(for: idxB)

        struct LiveMockExecutor: MacroActionExecutor {
            let domState: ShadowDOMState
            let nodeB: ShadowUINode
            func execute(action: AttributedUIAction, serial: String) async throws {
                await domState.handleMessage(.snapshot(WireSnapshotPayload(
                    seq: 2, timestampMs: 200, reason: "step", activePackage: "com.android.settings",
                    activeWindowId: 1, nodeCount: 1, nodes: [nodeB]
                )))
            }
        }

        let engine = MacroExecutionEngine(
            domState: domState,
            graphEngine: graphEngine,
            executor: LiveMockExecutor(domState: domState, nodeB: nodeB),
            configuration: MacroExecutionConfiguration(stepTimeoutMs: 1000, postSettleQuiescenceMs: 0)
        )

        let vm = AgenticHUDViewModel()
        vm.attach(to: engine)
        try await Task.sleep(for: .milliseconds(20))

        let edge = ScreenTransitionEdge(
            fromHash: fpA.layoutHash,
            toHash: fpB.layoutHash,
            action: AttributedUIAction(kind: .tap, targetDescription: "Battery Share", x: 300, y: 1200),
            actionSignature: "tap:Battery Share"
        )
        let report = try await engine.execute(path: [edge], serial: "61061JEA307110")
        XCTAssertEqual(report.steps.count, 1)

        // Allow MainActor stream task to drain the queued events
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.toastPhase, .completed)
        XCTAssertEqual(vm.activeReticle?.x, 300)
        XCTAssertEqual(vm.activeReticle?.y, 1200)
        vm.stopListening()
    }

    func testADBServiceParseDisplaySizeHandlesPhysicalOverrideAndInvalidOutput() {
        let physicalOnly = """
        Physical size: 1080x2424
        """
        let physical = ADBService.parseDisplaySize(from: physicalOnly)
        XCTAssertEqual(physical?.width, 1080)
        XCTAssertEqual(physical?.height, 2424)

        let withOverride = """
        Physical size: 1080x2424
        Override size: 720x1616
        """
        let overridden = ADBService.parseDisplaySize(from: withOverride)
        XCTAssertEqual(overridden?.width, 720)
        XCTAssertEqual(overridden?.height, 1616)

        XCTAssertNil(ADBService.parseDisplaySize(from: "error: no devices/emulators found"))
        XCTAssertNil(ADBService.parseDisplaySize(from: "Physical size: 0x2424"))
    }

    func testAgenticHUDCoordinateMapperDecouplesDownscaledVideoFromPhysicalInputDimensions() {
        // Pixel 10a: scrcpy stream downscaled to 640x1440 (max_size=1440),
        // while ADB input/ShadowUINode coordinates remain in physical 1080x2424.
        let viewSize = CGSize(width: 400, height: 900)
        let portraitPoint = AgenticHUDCoordinateMapper.viewPoint(
            deviceX: 540,
            deviceY: 1450,
            in: viewSize,
            videoWidth: 640,
            videoHeight: 1440,
            inputWidth: 1080,
            inputHeight: 2424
        )
        XCTAssertEqual(portraitPoint.x, 200, accuracy: 0.5)
        // 1450 / 2424 * 900 = 538.37pt (NOT clamped to 900 as it would be if divided by 1440!)
        XCTAssertEqual(portraitPoint.y, CGFloat(1450.0 / 2424.0 * 900.0), accuracy: 1.0)

        // Landscape rotation: video becomes 1440x640, physical input 1080x2424 must auto-orient to 2424x1080
        let landscapeView = CGSize(width: 900, height: 400)
        let landscapePoint = AgenticHUDCoordinateMapper.viewPoint(
            deviceX: 1212,
            deviceY: 540,
            in: landscapeView,
            videoWidth: 1440,
            videoHeight: 640,
            inputWidth: 1080,
            inputHeight: 2424
        )
        XCTAssertEqual(landscapePoint.x, 450, accuracy: 0.5)
        XCTAssertEqual(landscapePoint.y, 200, accuracy: 0.5)

        let nsView = AgenticCrosshairNSView(frame: NSRect(origin: .zero, size: viewSize))
        nsView.update(
            reticle: AgenticTargetReticle(
                id: UUID(),
                x: 540,
                y: 1450,
                startX: nil,
                startY: nil,
                kind: .tap,
                label: "Tap"
            ),
            deviceWidth: 640,
            deviceHeight: 1440,
            inputWidth: 1080,
            inputHeight: 2424
        )
        nsView.layoutSubtreeIfNeeded()
        XCTAssertFalse(nsView.isHidden)
    }

    @MainActor
    func testAgenticHUDViewModelListenCancelsCleanlyWithTask() async throws {
        let vm = AgenticHUDViewModel()
        var continuationRef: AsyncStream<MacroExecutionEvent>.Continuation?
        let stream = AsyncStream<MacroExecutionEvent> { cont in
            continuationRef = cont
        }

        let listenTask = Task { @MainActor in
            await vm.listen(to: stream)
        }
        try await Task.sleep(for: .milliseconds(20))
        continuationRef?.yield(.pathComputed(totalSteps: 3, targetHint: "Battery Share"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(vm.toastPhase, .executing)
        XCTAssertEqual(vm.toastTitle, "🤖 A* Path Computed: 3 steps. Executing...")

        listenTask.cancel()
        await listenTask.value
        continuationRef?.finish()
    }

    func testScrcpyDisplayNSViewPhysicalDisplayPointMapping() {
        // Portrait: downscaled video 640x1440 with physical 1080x2424 display
        let center = ScrcpyDisplayNSView.physicalDisplayPoint(
            normalized: CGPoint(x: 0.5, y: 0.5),
            inputWidth: 1080,
            inputHeight: 2424,
            videoWidth: 640,
            videoHeight: 1440
        )
        XCTAssertEqual(center?.x, 540)
        XCTAssertEqual(center?.y, 1212)

        let maxCorner = ScrcpyDisplayNSView.physicalDisplayPoint(
            normalized: CGPoint(x: 1.0, y: 1.0),
            inputWidth: 1080,
            inputHeight: 2424,
            videoWidth: 640,
            videoHeight: 1440
        )
        XCTAssertEqual(maxCorner?.x, 1079)
        XCTAssertEqual(maxCorner?.y, 2423)

        // Landscape rotation: video 1440x640 auto-orients physical 1080x2424 -> 2424x1080
        let landscapeCenter = ScrcpyDisplayNSView.physicalDisplayPoint(
            normalized: CGPoint(x: 0.5, y: 0.5),
            inputWidth: 1080,
            inputHeight: 2424,
            videoWidth: 1440,
            videoHeight: 640
        )
        XCTAssertEqual(landscapeCenter?.x, 1212)
        XCTAssertEqual(landscapeCenter?.y, 540)

        // Missing both physical and video dimensions returns nil
        XCTAssertNil(
            ScrcpyDisplayNSView.physicalDisplayPoint(
                normalized: CGPoint(x: 0.5, y: 0.5),
                inputWidth: nil,
                inputHeight: nil,
                videoWidth: 0,
                videoHeight: 0
            )
        )
    }

    @MainActor
    func testScrcpyDisplayNSViewRecordsManualTapSwipeAndBackActions() async throws {
        let viewSize = CGSize(width: 400, height: 800)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = ScrcpyDisplayNSView(frame: NSRect(origin: .zero, size: viewSize))
        window.contentView = view
        view.inputWidth = 1080
        view.inputHeight = 2424
        view.videoSizeProvider = { (640, 1440) }
        view.setHasRenderedFrameForTesting(true)

        let nightLightNode = ShadowUINode(
            index: 0,
            text: "Night Light",
            resourceId: "android:id/title",
            contentDesc: "",
            className: "android.widget.TextView",
            clickable: true,
            scrollable: false,
            bounds: "[400,1150][700,1270]",
            centerX: 550,
            centerY: 1210,
            nodeId: 42,
            parentId: nil,
            windowId: 1,
            childIndex: 0,
            depth: 1,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        let shadowIndex = ShadowTreeIndex(
            seq: 10,
            timestampMs: 500,
            activePackage: "com.android.settings",
            activeWindowId: 1,
            nodes: [nightLightNode]
        )
        view.shadowIndexProvider = { shadowIndex }

        var recorded: [AttributedUIAction] = []
        view.onRecordAction = { action in
            recorded.append(action)
        }

        // 1. Click center of view -> (200, 400) in flipped view = (200, 400) in 400x800 window -> physical (540, 1212) -> hits Night Light
        let downEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 200, y: 400),
            modifierFlags: [],
            timestamp: 1.0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ))
        let upEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 200, y: 400),
            modifierFlags: [],
            timestamp: 1.05,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
        ))
        view.mouseDown(with: downEvent)
        view.mouseUp(with: upEvent)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].kind, .tap)
        XCTAssertEqual(recorded[0].selectorText, "Night Light")
        XCTAssertEqual(recorded[0].selectorResourceId, "android:id/title")

        // 2. Drag upward in middle of screen -> swipe
        let swipeDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: 2.0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1.0
        ))
        let swipeUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 200, y: 500),
            modifierFlags: [],
            timestamp: 2.2,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 4,
            clickCount: 1,
            pressure: 0.0
        ))
        view.mouseDown(with: swipeDown)
        view.mouseUp(with: swipeUp)
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[1].kind, .swipe)
        XCTAssertEqual(recorded[1].x, 540)
        XCTAssertEqual(recorded[1].endX, 540)
        XCTAssertNotEqual(recorded[1].y, recorded[1].endY)

        // 3. Right click -> BACK
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 200, y: 400),
            modifierFlags: [],
            timestamp: 3.0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 5,
            clickCount: 1,
            pressure: 1.0
        ))
        view.rightMouseDown(with: rightClick)
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded[2].kind, .keyevent)
        XCTAssertEqual(recorded[2].targetDescription, "BACK")

        // 4. Escape key -> BACK
        let escKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 4.0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 53
        ))
        view.keyDown(with: escKey)
        XCTAssertEqual(recorded.count, 4)
        XCTAssertEqual(recorded[3].kind, .keyevent)
        XCTAssertEqual(recorded[3].targetDescription, "BACK")
    }

    @MainActor
    func testAgenticHUDViewModelDisplaysFailedToastOnNoRouteEvent() async throws {
        let vm = AgenticHUDViewModel()
        var continuationRef: AsyncStream<MacroExecutionEvent>.Continuation?
        let stream = AsyncStream<MacroExecutionEvent> { cont in
            continuationRef = cont
        }

        let listenTask = Task { @MainActor in
            await vm.listen(to: stream)
        }
        try await Task.sleep(for: .milliseconds(20))
        continuationRef?.yield(.failed(message: "No route to 'Night Light' (1/20 reachable)"))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(vm.toastPhase, .failed)
        XCTAssertEqual(vm.toastTitle, "🤖 Path Execution Stopped")
        XCTAssertEqual(vm.toastSubtitle, "No route to 'Night Light' (1/20 reachable)")

        listenTask.cancel()
        await listenTask.value
        continuationRef?.finish()
    }

    func testShadowGraphManagerConcurrentEnsureStartedAndResolveTapActionSync() async throws {
        actor ForwardRecorder {
            var calls: [(serial: String?, port: UInt16)] = []
            func record(serial: String?, port: UInt16) {
                calls.append((serial, port))
            }
            func all() -> [(serial: String?, port: UInt16)] { calls }
        }

        let recorder = ForwardRecorder()
        let bridge = ShadowGraphBridge()
        let manager = ShadowGraphManager(bridge: bridge) { serial, port in
            try? await Task.sleep(for: .milliseconds(25))
            await recorder.record(serial: serial, port: port)
        }

        async let first: Void = manager.ensureStarted(serial: nil)
        try await Task.sleep(for: .milliseconds(5))
        async let second: Void = manager.ensureStarted(serial: "61061JEA307110")
        _ = await (first, second)

        let calls = await recorder.all()
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertNil(calls.first?.serial)
        XCTAssertTrue(calls.contains(where: { $0.serial == "61061JEA307110" }))

        let node = ShadowUINode(
            index: 0,
            text: "Night Light",
            resourceId: "android:id/title",
            contentDesc: "",
            className: "android.widget.TextView",
            clickable: true,
            scrollable: false,
            bounds: "[100,200][500,350]",
            centerX: 300,
            centerY: 275,
            nodeId: 42,
            parentId: nil,
            windowId: 1,
            childIndex: 0,
            depth: 0,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        let snapshot = WireMessage.snapshot(WireSnapshotPayload(
            seq: 1,
            timestampMs: 1000,
            reason: "test",
            activePackage: "com.android.settings",
            activeWindowId: 1,
            nodeCount: 1,
            nodes: [node]
        ))
        await bridge.domState.handleMessage(snapshot)

        let resolved = manager.resolveTapActionSync(atX: 300, y: 275)
        XCTAssertEqual(resolved.kind, .tap)
        XCTAssertEqual(resolved.selectorText, "Night Light")
        XCTAssertEqual(resolved.selectorResourceId, "android:id/title")

        await bridge.domState.markDisconnected()
        let fallback = manager.resolveTapActionSync(atX: 300, y: 275)
        XCTAssertNil(fallback.selectorText)
        XCTAssertEqual(fallback.targetDescription, "manual tap at (300,275)")

        await manager.stop()
        let finalState = await bridge.client.state
        XCTAssertEqual(finalState, .stopped)
    }

    @MainActor
    func testScrcpyDisplayNSViewTapUsesSyncShadowGraphManagerWithoutProvider() async throws {
        let domState = ShadowGraphManager.shared.bridge.domState
        await domState.reset()
        addTeardownBlock {
            Task { await domState.reset() }
        }

        let node = ShadowUINode(
            index: 0,
            text: "Display & touch",
            resourceId: "com.android.settings:id/display_item",
            contentDesc: "",
            className: "android.widget.LinearLayout",
            clickable: true,
            scrollable: false,
            bounds: "[0,400][1080,600]",
            centerX: 540,
            centerY: 500,
            nodeId: 77,
            parentId: nil,
            windowId: 1,
            childIndex: 0,
            depth: 0,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        await domState.handleMessage(WireMessage.snapshot(WireSnapshotPayload(
            seq: 1,
            timestampMs: 1000,
            reason: "test",
            activePackage: "com.android.settings",
            activeWindowId: 1,
            nodeCount: 1,
            nodes: [node]
        )))

        let view = ScrcpyDisplayNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        view.setHasRenderedFrameForTesting(true)
        view.videoSizeProvider = { (width: 1080, height: 2400) }
        view.inputWidth = 1080
        view.inputHeight = 2400

        var recorded: [AttributedUIAction] = []
        view.onRecordAction = { recorded.append($0) }

        // y = 500/2400 = 0.2083 normalized from top -> AppKit y = 600 * (1 - 0.2083) = 475
        let pt = CGPoint(x: 150, y: 475)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pt,
            modifierFlags: [],
            timestamp: 10.0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pt,
            modifierFlags: [],
            timestamp: 10.05,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
        )!

        view.mouseDown(with: down)
        view.mouseUp(with: up)

        // Recorded synchronously before mouseUp returned, with no shadowIndexProvider async hop
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].kind, .tap)
        XCTAssertEqual(recorded[0].selectorText, "Display & touch")
        XCTAssertEqual(recorded[0].selectorResourceId, "com.android.settings:id/display_item")

        await domState.reset()
    }

    @MainActor
    func testScrcpyDisplayNSViewScrollWheelAndThreeFingerSwipeActions() throws {
        final class SyntheticSwipeEvent: NSEvent {
            private let _deltaX: CGFloat
            private let _deltaY: CGFloat
            private let _location: NSPoint

            init(deltaX: CGFloat, deltaY: CGFloat, location: NSPoint = .zero) {
                self._deltaX = deltaX
                self._deltaY = deltaY
                self._location = location
                super.init()
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            override var type: NSEvent.EventType { .swipe }
            override var deltaX: CGFloat { _deltaX }
            override var deltaY: CGFloat { _deltaY }
            override var locationInWindow: NSPoint { _location }
        }

        final class SyntheticScrollEvent: NSEvent {
            private let _scrollingDeltaX: CGFloat
            private let _scrollingDeltaY: CGFloat
            private let _phase: NSEvent.Phase
            private let _momentumPhase: NSEvent.Phase
            private let _location: NSPoint
            private let _timestamp: TimeInterval

            init(
                scrollingDeltaX: CGFloat,
                scrollingDeltaY: CGFloat,
                phase: NSEvent.Phase,
                momentumPhase: NSEvent.Phase = [],
                location: NSPoint,
                timestamp: TimeInterval
            ) {
                self._scrollingDeltaX = scrollingDeltaX
                self._scrollingDeltaY = scrollingDeltaY
                self._phase = phase
                self._momentumPhase = momentumPhase
                self._location = location
                self._timestamp = timestamp
                super.init()
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            override var type: NSEvent.EventType { .scrollWheel }
            override var hasPreciseScrollingDeltas: Bool { true }
            override var isDirectionInvertedFromDevice: Bool { false }
            override var scrollingDeltaX: CGFloat { _scrollingDeltaX }
            override var scrollingDeltaY: CGFloat { _scrollingDeltaY }
            override var phase: NSEvent.Phase { _phase }
            override var momentumPhase: NSEvent.Phase { _momentumPhase }
            override var locationInWindow: NSPoint { _location }
            override var timestamp: TimeInterval { _timestamp }
        }

        let view = ScrcpyDisplayNSView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        view.setHasRenderedFrameForTesting(true)
        view.videoSizeProvider = { (width: 1080, height: 2400) }
        view.inputWidth = 1080
        view.inputHeight = 2400

        var recorded: [AttributedUIAction] = []
        view.onRecordAction = { recorded.append($0) }

        // 1. Trackpad two-finger precise pan -> .swipe
        let centerLoc = CGPoint(x: 150, y: 300)
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .began, location: centerLoc, timestamp: 1.0))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: -120, phase: .changed, location: centerLoc, timestamp: 1.1))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .ended, location: centerLoc, timestamp: 1.2))

        XCTAssertTrue(recorded.contains(where: {
            $0.kind == .swipe && $0.targetDescription.hasPrefix("trackpad swipe")
        }), "Expected trackpad pan .swipe, got \(recorded)")

        // 2. Bottom-edge upward flick (< 85) -> HOME keyevent; deep upward swipe (>= 85) -> RECENTS
        recorded.removeAll()
        let bottomLoc = CGPoint(x: 150, y: 30) // normalizedY = 1 - 30/600 = 0.95 >= 0.85
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .began, location: bottomLoc, timestamp: 2.0))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 40, phase: .changed, location: bottomLoc, timestamp: 2.05))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .ended, location: bottomLoc, timestamp: 2.1))

        XCTAssertTrue(recorded.contains(where: {
            $0.kind == .keyevent && $0.targetDescription == "HOME"
        }), "Expected bottom-scroll HOME keyevent, got \(recorded)")

        recorded.removeAll()
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .began, location: bottomLoc, timestamp: 2.2))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 95, phase: .changed, location: bottomLoc, timestamp: 2.25))
        view.scrollWheel(with: SyntheticScrollEvent(scrollingDeltaX: 0, scrollingDeltaY: 0, phase: .ended, location: bottomLoc, timestamp: 2.3))

        XCTAssertTrue(recorded.contains(where: {
            $0.kind == .keyevent && $0.targetDescription == "RECENTS"
        }), "Expected deep bottom-scroll RECENTS keyevent, got \(recorded)")

        // 3. Three-finger swipes -> BACK, HOME, Notifications swipe
        recorded.removeAll()
        view.swipe(with: SyntheticSwipeEvent(deltaX: -1.0, deltaY: 0.0))
        view.swipe(with: SyntheticSwipeEvent(deltaX: 0.0, deltaY: 1.0))
        view.swipe(with: SyntheticSwipeEvent(deltaX: 0.0, deltaY: -1.0))

        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded[0].kind, .keyevent)
        XCTAssertEqual(recorded[0].targetDescription, "BACK")
        XCTAssertEqual(recorded[1].kind, .keyevent)
        XCTAssertEqual(recorded[1].targetDescription, "HOME")
        XCTAssertEqual(recorded[2].kind, .swipe)
        XCTAssertTrue(recorded[2].targetDescription.hasPrefix("3-finger swipe Notifications"))
    }

    func testShadowGraphManagerPersistsGraphAcrossRestartAndAutoRecoversDaemon() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andonmac-shadow-graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storageURL = tempDir.appendingPathComponent("shadow_graph.json", isDirectory: false)

        func makeNode(
            nodeId: Int64,
            index: Int,
            packageName: String,
            className: String = "android.widget.TextView",
            text: String,
            clickable: Bool = false,
            centerX: Int = 100,
            centerY: Int = 100
        ) -> ShadowUINode {
            ShadowUINode(
                index: index,
                text: text,
                resourceId: "",
                contentDesc: "",
                className: className,
                clickable: clickable,
                scrollable: false,
                bounds: "[\(centerX - 40),\(centerY - 20)][\(centerX + 40),\(centerY + 20)]",
                centerX: centerX,
                centerY: centerY,
                nodeId: nodeId,
                parentId: nil,
                windowId: 1,
                childIndex: index,
                depth: 0,
                packageName: packageName,
                editable: false,
                focused: false,
                checked: false,
                enabled: true,
                visible: true
            )
        }

        let homeNodes = [
            makeNode(nodeId: 1, index: 0, packageName: "com.google.android.apps.nexuslauncher", text: "Home"),
            makeNode(nodeId: 2, index: 1, packageName: "com.google.android.apps.nexuslauncher", text: "Settings", clickable: true, centerX: 250, centerY: 450)
        ]
        let settingsNodes = [
            makeNode(nodeId: 10, index: 0, packageName: "com.android.settings", text: "Settings"),
            makeNode(nodeId: 11, index: 1, packageName: "com.android.settings", text: "Display & touch", clickable: true, centerX: 500, centerY: 700)
        ]
        let displayNodes = [
            makeNode(nodeId: 20, index: 0, packageName: "com.android.settings", text: "Display & touch"),
            makeNode(nodeId: 21, index: 1, packageName: "com.android.settings", text: "Night Light", clickable: true, centerX: 500, centerY: 850)
        ]

        // Session 1: explore Home -> Settings -> Display & touch and verify passive save to disk
        let manager1 = ShadowGraphManager(
            bridge: ShadowGraphBridge(),
            portForwarder: { _, _ in },
            graphStorageURL: storageURL
        )
        await manager1.loadPersistedGraphIfNeeded()

        let homeIdx = ShadowTreeIndex(seq: 1, timestampMs: 100, activePackage: "com.google.android.apps.nexuslauncher", activeWindowId: 1, nodes: homeNodes)
        let settingsIdx = ShadowTreeIndex(seq: 2, timestampMs: 200, activePackage: "com.android.settings", activeWindowId: 1, nodes: settingsNodes)
        let displayIdx = ShadowTreeIndex(seq: 3, timestampMs: 300, activePackage: "com.android.settings", activeWindowId: 1, nodes: displayNodes)

        await manager1.bridge.graphEngine.process(update: ShadowDOMUpdate(index: homeIdx, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        await manager1.recordAction(AttributedUIAction(kind: .tap, targetDescription: "Settings", x: 250, y: 450, selectorText: "Settings"))
        await manager1.bridge.graphEngine.process(update: ShadowDOMUpdate(index: settingsIdx, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))
        await manager1.recordAction(AttributedUIAction(kind: .tap, targetDescription: "Display & touch", x: 500, y: 700, selectorText: "Display & touch"))
        await manager1.bridge.graphEngine.process(update: ShadowDOMUpdate(index: displayIdx, isFullSnapshot: true, insertedCount: 2, updatedCount: 0, removedCount: 0))

        await manager1.flushPersistedGraph()
        await manager1.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path), "Expected shadow_graph.json to be passively saved")

        // Bind a mock daemon NWListener on an ephemeral port (stopped/not listening until daemonLauncher starts it)
        final class MockDaemonServer: @unchecked Sendable {
            let queue = DispatchQueue(label: "test.shadowgraph.recovery.daemon")
            let lock = NSLock()
            var listener: NWListener?
            var connections: [NWConnection] = []
            var launchCount = 0
            let port: UInt16

            init() throws {
                let probe = try NWListener(using: .tcp, on: .any)
                probe.cancel()
                // Choose a high port and retry if busy
                self.port = UInt16.random(in: 38_000...55_000)
            }

            static func encodeHelloLine() -> Data {
                let obj: [String: Any] = [
                    "type": "hello",
                    "protocol_version": 1,
                    "format": "ndjson/1",
                    "sdk_int": 35,
                    "device_model": "Pixel 10a",
                    "pid": 9999
                ]
                var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                data.append(0x0A)
                return data
            }

            static func encodeSnapshotLine(seq: UInt64, reason: String, package: String, nodes: [ShadowUINode]) -> Data {
                let nodesData = (try? JSONEncoder().encode(nodes)) ?? Data("[]".utf8)
                let nodesObj = (try? JSONSerialization.jsonObject(with: nodesData)) ?? []
                let obj: [String: Any] = [
                    "type": "snapshot",
                    "seq": seq,
                    "ts_ms": Int64(seq) * 1000,
                    "reason": reason,
                    "package": package,
                    "window_id": 1,
                    "node_count": nodes.count,
                    "nodes": nodesObj
                ]
                var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                data.append(0x0A)
                return data
            }

            func startServing(initialPackage: String, initialNodes: [ShadowUINode]) throws {
                lock.withLock { launchCount += 1 }
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let nwPort = NWEndpoint.Port(rawValue: port)!
                let listener = try NWListener(using: params, on: nwPort)
                let readySem = DispatchSemaphore(value: 0)
                listener.stateUpdateHandler = { state in
                    if case .ready = state {
                        readySem.signal()
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    guard let self else { return }
                    self.lock.withLock { self.connections.append(conn) }
                    conn.start(queue: self.queue)

                    var bytes = Self.encodeHelloLine()
                    bytes.append(Self.encodeSnapshotLine(
                        seq: 1,
                        reason: "initial",
                        package: initialPackage,
                        nodes: initialNodes
                    ))
                    conn.send(content: bytes, completion: .contentProcessed { _ in })
                }
                self.listener = listener
                listener.start(queue: queue)
                _ = readySem.wait(timeout: .now() + 2.0)
            }

            func broadcastSnapshot(seq: UInt64, package: String, nodes: [ShadowUINode]) {
                let bytes = Self.encodeSnapshotLine(
                    seq: seq,
                    reason: "settled",
                    package: package,
                    nodes: nodes
                )
                let conns = lock.withLock { connections }
                for conn in conns {
                    conn.send(content: bytes, completion: .contentProcessed { _ in })
                }
            }

            func stop() {
                listener?.cancel()
                listener = nil
                let conns = lock.withLock { () -> [NWConnection] in
                    let copy = connections
                    connections.removeAll()
                    return copy
                }
                for conn in conns {
                    conn.cancel()
                }
            }
        }

        let mockDaemon = try MockDaemonServer()
        defer { mockDaemon.stop() }

        // Session 2: simulated Mac app restart (new ShadowGraphManager, disconnected daemon initially)
        let bridge2 = ShadowGraphBridge(configuration: DaemonEndpointConfiguration(
            host: "127.0.0.1",
            port: mockDaemon.port,
            initialReconnectDelay: 0.05,
            maxReconnectDelay: 0.25,
            heartbeatTimeout: 5.0
        ))
        let manager2 = ShadowGraphManager(
            bridge: bridge2,
            portForwarder: { _, _ in },
            daemonLauncher: { _, _ in
                try mockDaemon.startServing(
                    initialPackage: "com.google.android.apps.nexuslauncher",
                    initialNodes: homeNodes
                )
            },
            graphStorageURL: storageURL
        )

        // Verify startup load populates the persisted 3-screen DAG before any connection
        await manager2.loadPersistedGraphIfNeeded()
        let restoredVertices = await manager2.bridge.graphEngine.vertexCount
        let restoredEdges = await manager2.bridge.graphEngine.edgeCount
        XCTAssertEqual(restoredVertices, 3)
        XCTAssertEqual(restoredEdges, 2)

        final class MockTapExecutor: MacroActionExecutor, @unchecked Sendable {
            let server: MockDaemonServer
            let settingsNodes: [ShadowUINode]
            let displayNodes: [ShadowUINode]
            var nextSeq: UInt64 = 2
            var dispatchedTargets: [String] = []

            init(server: MockDaemonServer, settingsNodes: [ShadowUINode], displayNodes: [ShadowUINode]) {
                self.server = server
                self.settingsNodes = settingsNodes
                self.displayNodes = displayNodes
            }

            func execute(action: AttributedUIAction, serial: String) async throws {
                dispatchedTargets.append(action.targetDescription)
                let seq = nextSeq
                nextSeq += 1
                if action.targetDescription == "Settings" {
                    server.broadcastSnapshot(seq: seq, package: "com.android.settings", nodes: settingsNodes)
                } else if action.targetDescription == "Display & touch" {
                    server.broadcastSnapshot(seq: seq, package: "com.android.settings", nodes: displayNodes)
                }
            }
        }

        let executor = MockTapExecutor(server: mockDaemon, settingsNodes: settingsNodes, displayNodes: displayNodes)

        // Call navigateToNode while daemon is DOWN -> must auto-recover daemon, wait for TCP + UI tree, and execute macro!
        let outcome = try await manager2.navigateToNode(
            serial: "61061JEA307110",
            target: "Night Light",
            targetHash: nil,
            maxSteps: 6,
            stepTimeoutMs: 2000,
            executor: executor
        )

        let launches = mockDaemon.lock.withLock { mockDaemon.launchCount }
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(executor.dispatchedTargets, ["Settings", "Display & touch"])
        if case .arrived(let report) = outcome {
            XCTAssertEqual(report.steps.count, 2)
        } else {
            XCTFail("Expected .arrived after auto-recovery + persisted graph load, got \(outcome)")
        }

        await manager2.stop()
    }

    func testShadowGraphManagerResolvesWorkspaceDaemonJarPath() {
        let jarPath = ShadowGraphManager.resolveDaemonJarPath()
        XCTAssertNotNil(jarPath)
        XCTAssertTrue(jarPath?.hasSuffix("android-daemon.jar") == true)
    }

    func testShadowGraphManagerStopFlushesLatestDOMAndHandlesCorruptedJSON() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andonmac-shadow-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storageURL = tempDir.appendingPathComponent("shadow_graph.json", isDirectory: false)

        // Write corrupted JSON to disk before startup
        try Data("{\"vertices\": [truncated".utf8).write(to: storageURL)

        let manager = ShadowGraphManager(
            bridge: ShadowGraphBridge(),
            portForwarder: { _, _ in },
            graphStorageURL: storageURL
        )
        await manager.loadPersistedGraphIfNeeded()

        let emptyCount = await manager.bridge.graphEngine.vertexCount
        XCTAssertEqual(emptyCount, 0)

        let node = ShadowUINode(
            index: 0,
            text: "Display and touch",
            resourceId: "android:id/title",
            contentDesc: "",
            className: "android.widget.TextView",
            clickable: true,
            scrollable: false,
            bounds: "[0,100][500,200]",
            centerX: 250,
            centerY: 150,
            nodeId: 101,
            parentId: nil,
            windowId: 1,
            childIndex: 0,
            depth: 0,
            packageName: "com.android.settings",
            editable: false,
            focused: false,
            checked: false,
            enabled: true,
            visible: true
        )
        // Simulate snapshot delivered right before immediate stop() without waiting for utility graphPumpTask
        await manager.bridge.domState.handleMessage(.snapshot(WireSnapshotPayload(
            seq: 1,
            timestampMs: 1000,
            reason: "immediate_before_exit",
            activePackage: "com.android.settings",
            activeWindowId: 1,
            nodeCount: 1,
            nodes: [node]
        )))

        // stop() alone (without explicit flushPersistedGraph) must commit & flush to disk
        await manager.stop()

        let savedData = try Data(contentsOf: storageURL)
        let verifier = SpatialGraphEngine()
        try await verifier.importGraphJSON(savedData)
        let savedVertexCount = await verifier.vertexCount
        XCTAssertEqual(savedVertexCount, 1)
        let matches = await verifier.resolveTargetVertices(matching: "Display and touch")
        XCTAssertEqual(matches.count, 1)
    }
}
