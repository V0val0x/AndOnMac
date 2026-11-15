import SwiftUI

public enum DeviceDisplayOrientation: String, Sendable {
    case portrait
    case landscape
}

/// Normalized hardware punch-hole geometry relative to natural portrait screen bounds.
public struct PunchHoleSpec: Equatable, Sendable {
    /// Horizontal center fraction in natural portrait orientation (0.0 ... 1.0)
    public let normalizedCenterX: CGFloat
    /// Vertical center fraction in natural portrait orientation (0.0 ... 1.0)
    public let normalizedCenterY: CGFloat
    /// Radius fraction relative to the display's short side
    public let normalizedRadius: CGFloat

    public init(normalizedCenterX: CGFloat, normalizedCenterY: CGFloat, normalizedRadius: CGFloat) {
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.normalizedRadius = normalizedRadius
    }

    /// Resolves punch-hole center point inside a display frame of `screenSize` and `orientation`.
    public func resolvedCenter(in screenSize: CGSize, orientation: DeviceDisplayOrientation) -> CGPoint {
        switch orientation {
        case .portrait:
            return CGPoint(
                x: screenSize.width * normalizedCenterX,
                y: screenSize.height * normalizedCenterY
            )
        case .landscape:
            // Standard Android 90-degree CCW landscape: portrait top edge rests along the left side.
            return CGPoint(
                x: screenSize.width * normalizedCenterY,
                y: screenSize.height * (1.0 - normalizedCenterX)
            )
        }
    }

    /// Resolves punch-hole circle radius linearly scaled by the screen short edge.
    public func resolvedRadius(in screenSize: CGSize) -> CGFloat {
        let shortEdge = max(1.0, min(screenSize.width, screenSize.height))
        return max(2.0, shortEdge * normalizedRadius)
    }
}

/// Programmatic hardware chassis finish for vector bezels.
public enum DeviceChassisFinish: String, Codable, CaseIterable, Sendable {
    case obsidian
    case porcelain
    case hazel
    case titaniumBlack
    case titaniumGray
    case chromeBlack
    case smokedGlass
    case silkyEmerald
    case armorAluminum
    case proDisplayDark

    public static func resolve(for device: Device?, spec: DeviceHardwareSpec, matchDeviceColor: Bool) -> DeviceChassisFinish {
        guard matchDeviceColor else {
            return .obsidian
        }

        if let hint = device?.deviceColorHint?.lowercased(), !hint.isEmpty {
            if hint.contains("porcelain") || hint.contains("white") || hint.contains("silver") {
                return .porcelain
            }
            if hint.contains("hazel") || hint.contains("sage") || hint.contains("jade") || hint.contains("emerald") || hint.contains("green") {
                return spec.style == .oneplus ? .silkyEmerald : .hazel
            }
            if hint.contains("titanium") || hint.contains("gray") || hint.contains("grey") || hint.contains("natural") {
                return .titaniumGray
            }
            if hint.contains("black") || hint.contains("obsidian") || hint.contains("graphite") {
                return spec.defaultFinish
            }
        }

        return spec.defaultFinish
    }

    public var chassisFill: LinearGradient {
        switch self {
        case .obsidian:
            return LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .porcelain:
            return LinearGradient(
                colors: [Color(red: 0.84, green: 0.83, blue: 0.80), Color(red: 0.65, green: 0.64, blue: 0.61)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .hazel:
            return LinearGradient(
                colors: [Color(red: 0.25, green: 0.29, blue: 0.27), Color(red: 0.13, green: 0.15, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .titaniumBlack:
            return LinearGradient(
                colors: [Color(red: 0.21, green: 0.20, blue: 0.20), Color(red: 0.10, green: 0.10, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .titaniumGray:
            return LinearGradient(
                colors: [Color(red: 0.34, green: 0.32, blue: 0.30), Color(red: 0.18, green: 0.17, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .chromeBlack:
            return LinearGradient(
                colors: [
                    Color(red: 0.32, green: 0.34, blue: 0.38),
                    Color(red: 0.11, green: 0.12, blue: 0.14),
                    Color(red: 0.26, green: 0.28, blue: 0.31)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .smokedGlass:
            return LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.19), Color(red: 0.07, green: 0.08, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .silkyEmerald:
            return LinearGradient(
                colors: [Color(red: 0.13, green: 0.20, blue: 0.18), Color(red: 0.07, green: 0.10, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .armorAluminum:
            return LinearGradient(
                colors: [Color(red: 0.21, green: 0.22, blue: 0.24), Color(red: 0.11, green: 0.11, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .proDisplayDark:
            return LinearGradient(
                colors: [Color(white: 0.19), Color(white: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    public var chassisStroke: LinearGradient {
        switch self {
        case .porcelain:
            return LinearGradient(
                colors: [Color.white.opacity(0.85), Color.white.opacity(0.35), Color.black.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .titaniumGray, .titaniumBlack:
            return LinearGradient(
                colors: [Color(red: 0.88, green: 0.82, blue: 0.74).opacity(0.55), Color.white.opacity(0.18), Color.black.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .chromeBlack:
            return LinearGradient(
                colors: [Color.white.opacity(0.70), Color.white.opacity(0.20), Color.black.opacity(0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .smokedGlass:
            return LinearGradient(
                colors: [Color.white.opacity(0.42), Color.cyan.opacity(0.15), Color.black.opacity(0.80)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .silkyEmerald:
            return LinearGradient(
                colors: [Color(red: 0.45, green: 0.82, blue: 0.70).opacity(0.38), Color.white.opacity(0.15), Color.black.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color.white.opacity(0.38), Color.white.opacity(0.12), Color.black.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Hardware display & chassis geometry metrics for programmatic vector device framing.
public struct DeviceHardwareSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let style: PhoneFrameStyle
    /// Outer corner radius at 1.0x reference width (320pt short edge)
    public let baseCornerRadius: CGFloat
    /// Physical bezel width in points at 1.0x scale
    public let baseBezelWidth: CGFloat
    /// Width multiplier relative to standard 320pt short edge (Ultra flagships are slightly wider)
    public let baseWidthMultiplier: CGFloat
    /// Normalized centered punch-hole metrics (nil = no cutout, e.g. Pro Display fallback)
    public let punchHole: PunchHoleSpec?
    public let defaultFinish: DeviceChassisFinish
    public let hasGlyphAccent: Bool

    public init(
        id: String,
        displayName: String,
        style: PhoneFrameStyle,
        baseCornerRadius: CGFloat,
        baseBezelWidth: CGFloat,
        baseWidthMultiplier: CGFloat = 1.0,
        punchHole: PunchHoleSpec?,
        defaultFinish: DeviceChassisFinish,
        hasGlyphAccent: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.style = style
        self.baseCornerRadius = baseCornerRadius
        self.baseBezelWidth = baseBezelWidth
        self.baseWidthMultiplier = baseWidthMultiplier
        self.punchHole = punchHole
        self.defaultFinish = defaultFinish
        self.hasGlyphAccent = hasGlyphAccent
    }

    public func outerCornerRadius(scale: CGFloat, showBezel: Bool) -> CGFloat {
        let scaled = baseCornerRadius * scale
        return showBezel ? scaled : max(8, scaled - baseBezelWidth * scale)
    }

    public func bezelWidth(scale: CGFloat, showBezel: Bool) -> CGFloat {
        guard showBezel else { return 0.5 }
        return baseBezelWidth * scale
    }

    public func innerCornerRadius(scale: CGFloat, showBezel: Bool) -> CGFloat {
        let outer = outerCornerRadius(scale: scale, showBezel: showBezel)
        let bezel = bezelWidth(scale: scale, showBezel: showBezel)
        return max(4, outer - bezel)
    }

    public func screenClipRadius(scale: CGFloat, showBezel: Bool) -> CGFloat {
        max(2, innerCornerRadius(scale: scale, showBezel: showBezel) - (showBezel ? 1.5 * scale : 0))
    }

    // MARK: - Hardware Specification Database

    public static let pixel11Pro = DeviceHardwareSpec(
        id: "pixel_11_pro",
        displayName: "Google Pixel 11 Pro",
        style: .pixel11Pro,
        baseCornerRadius: 45,
        baseBezelWidth: 3.0,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0235, normalizedRadius: 0.0120),
        defaultFinish: .obsidian
    )

    public static let pixel11 = DeviceHardwareSpec(
        id: "pixel_11",
        displayName: "Google Pixel 11",
        style: .pixel11,
        baseCornerRadius: 44,
        baseBezelWidth: 3.3,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0245, normalizedRadius: 0.0126),
        defaultFinish: .obsidian
    )

    public static let pixel10a = DeviceHardwareSpec(
        id: "pixel_10a",
        displayName: "Google Pixel 10a",
        style: .pixel10a,
        baseCornerRadius: 40,
        baseBezelWidth: 4.4,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0265, normalizedRadius: 0.0142),
        defaultFinish: .obsidian
    )

    /// Fixed Pixel 8 / 9 / 10 geometry (aligns cutout inside status bar across all scale presets)
    public static let pixel8_9_10 = DeviceHardwareSpec(
        id: "pixel_8_9_10",
        displayName: "Google Pixel (8/9/10)",
        style: .pixel,
        baseCornerRadius: 44,
        baseBezelWidth: 3.2,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0258, normalizedRadius: 0.0132),
        defaultFinish: .obsidian
    )

    public static let samsungS25Ultra = DeviceHardwareSpec(
        id: "galaxy_s25_ultra",
        displayName: "Samsung Galaxy S25 Ultra",
        style: .samsungUltra,
        baseCornerRadius: 14,
        baseBezelWidth: 2.5,
        baseWidthMultiplier: 1.03,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0205, normalizedRadius: 0.0108),
        defaultFinish: .titaniumGray
    )

    public static let samsungS24Ultra = DeviceHardwareSpec(
        id: "galaxy_s24_ultra",
        displayName: "Samsung Galaxy S24 Ultra",
        style: .samsungUltra,
        baseCornerRadius: 10,
        baseBezelWidth: 2.5,
        baseWidthMultiplier: 1.03,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0205, normalizedRadius: 0.0108),
        defaultFinish: .titaniumGray
    )

    public static let samsungGalaxyS = DeviceHardwareSpec(
        id: "galaxy_s24_s25",
        displayName: "Samsung Galaxy S24 / S25",
        style: .samsung,
        baseCornerRadius: 36,
        baseBezelWidth: 3.0,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0215, normalizedRadius: 0.0115),
        defaultFinish: .armorAluminum
    )

    public static let xiaomi = DeviceHardwareSpec(
        id: "xiaomi_14_15",
        displayName: "Xiaomi (14/15/Pro)",
        style: .xiaomi,
        baseCornerRadius: 38,
        baseBezelWidth: 2.5,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0215, normalizedRadius: 0.0115),
        defaultFinish: .chromeBlack
    )

    public static let nothingPhone2 = DeviceHardwareSpec(
        id: "nothing_phone_2",
        displayName: "Nothing Phone (2)",
        style: .nothing,
        baseCornerRadius: 40,
        baseBezelWidth: 3.2,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0235, normalizedRadius: 0.0125),
        defaultFinish: .smokedGlass,
        hasGlyphAccent: true
    )

    public static let onePlus12 = DeviceHardwareSpec(
        id: "oneplus_12",
        displayName: "OnePlus 12",
        style: .oneplus,
        baseCornerRadius: 38,
        baseBezelWidth: 2.8,
        punchHole: PunchHoleSpec(normalizedCenterX: 0.50, normalizedCenterY: 0.0205, normalizedRadius: 0.0112),
        defaultFinish: .silkyEmerald
    )

    /// Graceful Pro Display fallback for unknown Android devices (sleek rounded bezel, no camera hole)
    public static let proDisplay = DeviceHardwareSpec(
        id: "pro_display",
        displayName: "Pro Display",
        style: .minimal,
        baseCornerRadius: 42,
        baseBezelWidth: 3.0,
        punchHole: nil,
        defaultFinish: .proDisplayDark
    )

    public static let borderless = DeviceHardwareSpec(
        id: "borderless",
        displayName: "Borderless",
        style: .borderless,
        baseCornerRadius: 32,
        baseBezelWidth: 1.0,
        punchHole: nil,
        defaultFinish: .obsidian
    )

    public static let catalog: [DeviceHardwareSpec] = [
        pixel11Pro,
        pixel11,
        pixel10a,
        pixel8_9_10,
        samsungS25Ultra,
        samsungS24Ultra,
        samsungGalaxyS,
        xiaomi,
        nothingPhone2,
        onePlus12,
        proDisplay,
        borderless
    ]

    /// Resolves exact hardware specification from device model/vendor/codename strings or manual style override.
    public static func resolve(for device: Device?, override style: PhoneFrameStyle) -> DeviceHardwareSpec {
        if style != .auto {
            return spec(for: style, device: device)
        }

        guard let dev = device else {
            return .proDisplay
        }

        let normalized = [
            dev.model,
            dev.manufacturer,
            dev.vendor,
            dev.hardwareCodename
        ]
        .joined(separator: " ")
        .replacingOccurrences(of: "_", with: " ")
        .lowercased()

        // Highest priority: Google Pixel 11 Pro / 11 / 10a
        if normalized.contains("pixel 11 pro") {
            return .pixel11Pro
        }
        if normalized.contains("pixel 11") {
            return .pixel11
        }
        if normalized.contains("pixel 10a") || normalized.contains("stallion") {
            return .pixel10a
        }
        if normalized.contains("pixel") || dev.manufacturer.lowercased().contains("google") {
            return .pixel8_9_10
        }

        // Samsung Galaxy Ultra (S24U SM-S928, S25U SM-S938, S21U-S23U, Note)
        if normalized.contains("sm-s938") || normalized.contains("s25 ultra") {
            return .samsungS25Ultra
        }
        if normalized.contains("sm-s928") || normalized.contains("s24 ultra") ||
           ((normalized.contains("samsung") || normalized.contains("galaxy") || normalized.contains("sm-")) &&
            (normalized.contains("ultra") || normalized.contains("s918") || normalized.contains("note"))) {
            return .samsungS24Ultra
        }
        if normalized.contains("samsung") || normalized.contains("galaxy") || normalized.contains("sm-") {
            return .samsungGalaxyS
        }

        // Xiaomi / Redmi / POCO
        if normalized.contains("xiaomi") || normalized.contains("redmi") || normalized.contains("poco") || normalized.contains("mi ") {
            return .xiaomi
        }

        // Nothing Phone (2) / (2a)
        if normalized.contains("nothing") || normalized.contains("a065") || normalized.contains("a063") || normalized.contains("a142") {
            return .nothingPhone2
        }

        // OnePlus (12 / 13 / CPH25xx)
        if normalized.contains("oneplus") || normalized.contains("cph2581") || normalized.contains("cph2583") || normalized.contains("cph2573") || normalized.contains("cph") {
            return .onePlus12
        }

        // Fallback: sleek Pro Display bezel with no cutout
        return .proDisplay
    }

    public static func spec(for style: PhoneFrameStyle, device: Device? = nil) -> DeviceHardwareSpec {
        switch style {
        case .auto:
            return resolve(for: device, override: .auto)
        case .pixel11Pro:
            return .pixel11Pro
        case .pixel11:
            return .pixel11
        case .pixel10a:
            return .pixel10a
        case .pixel:
            return .pixel8_9_10
        case .samsungUltra:
            let model = (device?.model ?? "").lowercased()
            if model.contains("s25") || model.contains("s938") {
                return .samsungS25Ultra
            }
            return .samsungS24Ultra
        case .samsung:
            return .samsungGalaxyS
        case .xiaomi:
            return .xiaomi
        case .nothing:
            return .nothingPhone2
        case .oneplus:
            return .onePlus12
        case .minimal:
            return .proDisplay
        case .borderless:
            return .borderless
        }
    }
}
