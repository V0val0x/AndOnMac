import XCTest
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
}
