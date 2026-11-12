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
    }
}
