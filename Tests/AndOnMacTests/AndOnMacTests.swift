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
}
