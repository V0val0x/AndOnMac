import SwiftUI

public enum PhoneFrameStyle: String, CaseIterable, Identifiable, Sendable {
    case auto = "Автоопределение"
    case pixel = "Google Pixel (8/9/10)"
    case samsungUltra = "Samsung Galaxy S Ultra (S24/S25)"
    case samsung = "Samsung Galaxy S (S24/S25)"
    case xiaomi = "Xiaomi (14/15/Pro)"
    case nothing = "Nothing Phone (2/2a)"
    case oneplus = "OnePlus (12/13)"
    case minimal = "Минимальная рамка"
    case borderless = "Без рамки"
    
    public var id: String { rawValue }
    
    public var displayName: String { rawValue }
    
    public var shortName: String {
        switch self {
        case .auto: return "Авто"
        case .pixel: return "Pixel"
        case .samsungUltra: return "Galaxy Ultra"
        case .samsung: return "Galaxy S"
        case .xiaomi: return "Xiaomi"
        case .nothing: return "Nothing"
        case .oneplus: return "OnePlus"
        case .minimal: return "Минимум"
        case .borderless: return "Без рамки"
        }
    }
    
    public var iconName: String {
        switch self {
        case .auto: return "sparkles"
        case .pixel: return "g.circle"
        case .samsungUltra: return "square"
        case .samsung: return "rectangle.roundedtop"
        case .xiaomi: return "bolt.circle"
        case .nothing: return "circle.dotted"
        case .oneplus: return "1.circle"
        case .minimal: return "iphone"
        case .borderless: return "rectangle"
        }
    }
    
    /// Outer chassis corner radius in points
    public var cornerRadius: CGFloat {
        switch self {
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
        switch self {
        case .borderless: return 1.0
        case .samsungUltra, .xiaomi: return 2.5
        case .minimal: return 2.8
        default: return 3.2
        }
    }
    
    /// Inner screen display corner radius
    public var innerCornerRadius: CGFloat {
        max(4, cornerRadius - bezelWidth)
    }
    
    /// Screen clipping radius
    public var screenClipRadius: CGFloat {
        max(2, innerCornerRadius - 2)
    }
    
    /// Base phone width multiplier (Galaxy Ultra is slightly wider in hand)
    public var baseWidthMultiplier: CGFloat {
        switch self {
        case .samsungUltra: return 1.03
        default: return 1.0
        }
    }
    
    /// Whether this model features a centered punch-hole camera
    public var hasPunchHole: Bool {
        switch self {
        case .minimal, .borderless: return false
        default: return true
        }
    }
    
    /// Punch hole camera diameter in points
    public var punchHoleDiameter: CGFloat {
        switch self {
        case .samsungUltra, .xiaomi: return 7.5
        case .samsung, .oneplus: return 8.0
        default: return 8.8
        }
    }
    
    /// Distance from screen top to punch hole center
    public var punchHoleTopPadding: CGFloat {
        switch self {
        case .samsungUltra: return 9.5
        case .xiaomi: return 10.0
        case .samsung: return 10.5
        default: return 11.5
        }
    }
    
    /// Outer metal chassis fill gradient
    public var chassisFill: LinearGradient {
        switch self {
        case .samsungUltra:
            // Brushed Aerospace Titanium (Warm titanium tones)
            return LinearGradient(
                colors: [
                    Color(red: 0.23, green: 0.22, blue: 0.21),
                    Color(red: 0.13, green: 0.12, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .xiaomi:
            // High-gloss mirror-polished chrome
            return LinearGradient(
                colors: [
                    Color(red: 0.32, green: 0.34, blue: 0.38),
                    Color(red: 0.11, green: 0.12, blue: 0.14),
                    Color(red: 0.26, green: 0.28, blue: 0.31)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .nothing:
            // Smoked dark glass chassis
            return LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.17, blue: 0.19),
                    Color(red: 0.07, green: 0.08, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .oneplus:
            // Silky emerald / dark metallic
            return LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.18, blue: 0.17),
                    Color(red: 0.08, green: 0.10, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .samsung:
            // Flat Armor Aluminum
            return LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.21, blue: 0.23),
                    Color(red: 0.10, green: 0.11, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .borderless:
            return LinearGradient(
                colors: [Color.black, Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
        case .auto, .pixel, .minimal:
            // Satin Obsidian / Matte Titanium
            return LinearGradient(
                colors: [
                    Color(white: 0.18),
                    Color(white: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    /// Outer edge highlight stroke
    public var chassisStroke: LinearGradient {
        switch self {
        case .samsungUltra:
            // Diamond-cut chamfered titanium rim
            return LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.82, blue: 0.74).opacity(0.55),
                    Color.white.opacity(0.18),
                    Color.black.opacity(0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .xiaomi:
            // Mirror-polished chrome specular reflections
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.70),
                    Color.white.opacity(0.20),
                    Color.black.opacity(0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .nothing:
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.40),
                    Color.cyan.opacity(0.15),
                    Color.black.opacity(0.80)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .oneplus:
            return LinearGradient(
                colors: [
                    Color(red: 0.45, green: 0.80, blue: 0.70).opacity(0.35),
                    Color.white.opacity(0.15),
                    Color.black.opacity(0.80)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .borderless:
            return LinearGradient(
                colors: [Color.white.opacity(0.15), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        default:
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.35),
                    Color.white.opacity(0.10),
                    Color.black.opacity(0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    /// Auto-detects phone style based on device manufacturer and model strings
    public static func detect(for device: Device?) -> PhoneFrameStyle {
        guard let dev = device else { return .pixel }
        let model = dev.model.lowercased()
        let mfr = dev.manufacturer.lowercased()
        
        // Google Pixel
        if mfr.contains("google") || model.contains("pixel") {
            return .pixel
        }
        
        // Samsung Galaxy Ultra (S21U, S22U, S23U, S24U, S25U, Note)
        if (mfr.contains("samsung") || model.contains("sm-") || model.contains("galaxy")) &&
           (model.contains("ultra") || model.contains("s918") || model.contains("s928") || model.contains("s938") || model.contains("note")) {
            return .samsungUltra
        }
        
        // Samsung Galaxy S standard / plus / FE
        if mfr.contains("samsung") || model.contains("sm-") || model.contains("galaxy") {
            return .samsung
        }
        
        // Xiaomi / Redmi / POCO
        if mfr.contains("xiaomi") || mfr.contains("redmi") || mfr.contains("poco") || model.contains("mi ") || model.contains("xiaomi") {
            return .xiaomi
        }
        
        // Nothing Phone
        if mfr.contains("nothing") || model.contains("nothing") || model.contains("a06") || model.contains("a142") {
            return .nothing
        }
        
        // OnePlus
        if mfr.contains("oneplus") || model.contains("oneplus") || model.contains("cph") {
            return .oneplus
        }
        
        return .pixel
    }
}
