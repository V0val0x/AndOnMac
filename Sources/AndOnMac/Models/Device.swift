import Foundation

public enum ConnectionType: String, Codable, Sendable {
    case usb = "USB"
    case wifi = "Wi-Fi"
    case unknown = "Unknown"
}

public enum DeviceState: String, Codable, Sendable {
    case ready = "device"
    case unauthorized = "unauthorized"
    case offline = "offline"
    case mirroring = "mirroring"
    case error = "error"
}

public struct Device: Identifiable, Hashable, Sendable {
    public let id: String // Serial or IP:Port
    public var model: String
    public var manufacturer: String
    public var androidVersion: String
    public var batteryLevel: Int?
    public var isCharging: Bool?
    public var connectionType: ConnectionType
    public var state: DeviceState
    public var ipAddress: String?
    
    public init(
        id: String,
        model: String = "Android Device",
        manufacturer: String = "Unknown",
        androidVersion: String = "",
        batteryLevel: Int? = nil,
        isCharging: Bool? = nil,
        connectionType: ConnectionType = .usb,
        state: DeviceState = .ready,
        ipAddress: String? = nil
    ) {
        self.id = id
        self.model = model
        self.manufacturer = manufacturer
        self.androidVersion = androidVersion
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.connectionType = connectionType
        self.state = state
        self.ipAddress = ipAddress
    }
    
    public var displayName: String {
        if manufacturer.lowercased() == "google" || model.lowercased().contains("pixel") {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        if manufacturer.lowercased() == "unknown" || manufacturer.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        if model.lowercased().starts(with: manufacturer.lowercased()) {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        return "\(manufacturer) \(model)".replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
    
    public var isPixel: Bool {
        manufacturer.lowercased() == "google" || model.lowercased().contains("pixel")
    }
}
