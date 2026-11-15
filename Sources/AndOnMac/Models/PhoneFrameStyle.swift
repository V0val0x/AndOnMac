import SwiftUI

public enum PhoneFrameStyle: String, CaseIterable, Identifiable, Sendable {
    case auto = "Автоопределение"
    case pixel11Pro = "Google Pixel 11 Pro"
    case pixel11 = "Google Pixel 11"
    case pixel10a = "Google Pixel 10a"
    case pixel = "Google Pixel (8/9/10)"
    case samsungUltra = "Samsung Galaxy S Ultra (S24/S25)"
    case samsung = "Samsung Galaxy S (S24/S25)"
    case xiaomi = "Xiaomi (14/15/Pro)"
    case nothing = "Nothing Phone (2/2a)"
    case oneplus = "OnePlus (12/13)"
    case minimal = "Pro Display (Универсальная)"
    case borderless = "Без рамки"
    
    public var id: String { rawValue }
    
    public var displayName: String { rawValue }
    
    public var shortName: String {
        switch self {
        case .auto: return "Авто"
        case .pixel11Pro: return "Pixel 11 Pro"
        case .pixel11: return "Pixel 11"
        case .pixel10a: return "Pixel 10a"
        case .pixel: return "Pixel"
        case .samsungUltra: return "Galaxy Ultra"
        case .samsung: return "Galaxy S"
        case .xiaomi: return "Xiaomi"
        case .nothing: return "Nothing"
        case .oneplus: return "OnePlus"
        case .minimal: return "Pro Display"
        case .borderless: return "Без рамки"
        }
    }
    
    public var iconName: String {
        switch self {
        case .auto: return "sparkles"
        case .pixel11Pro, .pixel11, .pixel10a, .pixel: return "g.circle"
        case .samsungUltra: return "square"
        case .samsung: return "rectangle.roundedtop"
        case .xiaomi: return "bolt.circle"
        case .nothing: return "circle.dotted"
        case .oneplus: return "1.circle"
        case .minimal: return "display"
        case .borderless: return "rectangle"
        }
    }
    
    /// Outer chassis corner radius in points (calibrated to real hardware proportions at 320pt width)
    public var cornerRadius: CGFloat {
        switch self {
        case .pixel11Pro: return 45
        case .pixel11: return 44
        case .pixel10a: return 40
        case .auto, .pixel: return 44
        case .samsungUltra: return 12 // Signature sharp industrial Galaxy Ultra silhouette
        case .samsung: return 36
        case .xiaomi: return 38
        case .nothing: return 40
        case .oneplus: return 38
        case .minimal: return 42
        case .borderless: return 32
        }
    }
    
    /// Outer frame width in points (hardware bezel)
    public var bezelWidth: CGFloat {
        DeviceHardwareSpec.spec(for: self).baseBezelWidth
    }
    
    /// Inner screen display corner radius
    public var innerCornerRadius: CGFloat {
        max(4, cornerRadius - bezelWidth)
    }
    
    /// Screen clipping radius
    public var screenClipRadius: CGFloat {
        max(2, innerCornerRadius - 2)
    }
    
    /// Base screen width multiplier (1.0 preserves exact deviceWidth:deviceHeight without distortion)
    public var baseWidthMultiplier: CGFloat {
        DeviceHardwareSpec.spec(for: self).baseWidthMultiplier
    }
    
    /// Whether this model features a centered punch-hole camera
    public var hasPunchHole: Bool {
        DeviceHardwareSpec.spec(for: self).punchHole != nil
    }
    
    /// Punch hole camera diameter in points at 1.0x scale
    public var punchHoleDiameter: CGFloat {
        guard let hole = DeviceHardwareSpec.spec(for: self).punchHole else { return 0 }
        return hole.resolvedRadius(in: CGSize(width: 320, height: 711)) * 2.0
    }
    
    /// Distance from screen top to punch hole center at 1.0x scale
    public var punchHoleTopPadding: CGFloat {
        guard let hole = DeviceHardwareSpec.spec(for: self).punchHole else { return 0 }
        return hole.resolvedCenter(in: CGSize(width: 320, height: 711), orientation: .portrait).y
    }
    
    /// Outer metal chassis fill gradient
    public var chassisFill: LinearGradient {
        if self == .borderless {
            return LinearGradient(colors: [.black, .black], startPoint: .top, endPoint: .bottom)
        }
        return DeviceHardwareSpec.spec(for: self).defaultFinish.chassisFill
    }
    
    /// Outer edge highlight stroke
    public var chassisStroke: LinearGradient {
        if self == .borderless {
            return LinearGradient(colors: [Color.white.opacity(0.15), .clear], startPoint: .top, endPoint: .bottom)
        }
        return DeviceHardwareSpec.spec(for: self).defaultFinish.chassisStroke
    }
    
    /// Auto-detects phone style based on device manufacturer, vendor, codename, and model strings
    public static func detect(for device: Device?) -> PhoneFrameStyle {
        return DeviceHardwareSpec.resolve(for: device, override: .auto).style
    }
}
