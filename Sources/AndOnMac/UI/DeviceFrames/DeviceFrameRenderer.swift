import SwiftUI
import AppKit
import QuartzCore

/// Vector screen silhouette with optional even-odd punch-hole cutout.
public struct DeviceScreenCutoutShape: Shape {
    public var cornerRadius: CGFloat
    public var punchHoleCenter: CGPoint?
    public var punchHoleRadius: CGFloat

    public init(cornerRadius: CGFloat, punchHoleCenter: CGPoint? = nil, punchHoleRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
        self.punchHoleCenter = punchHoleCenter
        self.punchHoleRadius = punchHoleRadius
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        if let center = punchHoleCenter, punchHoleRadius > 0 {
            let holeRect = CGRect(
                x: center.x - punchHoleRadius,
                y: center.y - punchHoleRadius,
                width: punchHoleRadius * 2.0,
                height: punchHoleRadius * 2.0
            )
            path.addEllipse(in: holeRect)
        }
        return path
    }
}

/// CoreAnimation `CAShapeLayer` vector mask builder for GPU-composited layer masking without PNG assets.
public enum CoreAnimationDeviceMask {
    public static func makeScreenMaskLayer(
        size: CGSize,
        cornerRadius: CGFloat,
        punchHoleCenter: CGPoint? = nil,
        punchHoleRadius: CGFloat = 0
    ) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.fillRule = .evenOdd

        let mutable = CGMutablePath()
        let screenRect = CGRect(origin: .zero, size: size)
        let clampedCorner = max(0, min(cornerRadius, min(size.width, size.height) * 0.5))
        mutable.addRoundedRect(in: screenRect, cornerWidth: clampedCorner, cornerHeight: clampedCorner)

        if let center = punchHoleCenter, punchHoleRadius > 0 {
            let holeRect = CGRect(
                x: center.x - punchHoleRadius,
                y: center.y - punchHoleRadius,
                width: punchHoleRadius * 2.0,
                height: punchHoleRadius * 2.0
            )
            mutable.addEllipse(in: holeRect)
        }

        layer.path = mutable
        return layer
    }
}

/// Programmatic camera lens optics overlay positioned directly inside the punch-hole cutout.
public struct DeviceCameraLensView: View {
    public let radius: CGFloat

    public init(radius: CGFloat) {
        self.radius = radius
    }

    public var body: some View {
        let diameter = max(4.0, radius * 2.0)
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: diameter + 1.2, height: diameter + 1.2)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.08, green: 0.13, blue: 0.24),
                            Color(red: 0.02, green: 0.03, blue: 0.05)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 0.5
                    )
                )
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )

            Circle()
                .fill(Color.white.opacity(0.65))
                .frame(width: max(1.2, diameter * 0.17), height: max(1.2, diameter * 0.17))
                .offset(x: -diameter * 0.20, y: -diameter * 0.20)
        }
        .allowsHitTesting(false)
    }
}

/// Vector device chassis & screen masking container with Ambilight halo, physical hardware finish, and spring resizing.
public struct DeviceFrameRenderer<ScreenContent: View>: View {
    public let spec: DeviceHardwareSpec
    public let device: Device?
    public let width: CGFloat
    public let height: CGFloat
    public let scaleMultiplier: CGFloat
    public let orientation: DeviceDisplayOrientation
    public let showDeviceBezel: Bool
    public let showCameraPunchHole: Bool
    public let matchDeviceColor: Bool
    public let enableAmbilight: Bool
    public let ambilightPalette: AmbilightPalette?
    @ViewBuilder public let screenContent: () -> ScreenContent

    public static var fluidSpring: Animation {
        .spring(response: 0.4, dampingFraction: 0.8)
    }

    public init(
        spec: DeviceHardwareSpec,
        device: Device?,
        width: CGFloat,
        height: CGFloat,
        scaleMultiplier: CGFloat,
        orientation: DeviceDisplayOrientation,
        showDeviceBezel: Bool,
        showCameraPunchHole: Bool,
        matchDeviceColor: Bool,
        enableAmbilight: Bool,
        ambilightPalette: AmbilightPalette? = nil,
        @ViewBuilder screenContent: @escaping () -> ScreenContent
    ) {
        self.spec = spec
        self.device = device
        self.width = width
        self.height = height
        self.scaleMultiplier = scaleMultiplier
        self.orientation = orientation
        self.showDeviceBezel = showDeviceBezel
        self.showCameraPunchHole = showCameraPunchHole
        self.matchDeviceColor = matchDeviceColor
        self.enableAmbilight = enableAmbilight
        self.ambilightPalette = ambilightPalette
        self.screenContent = screenContent
    }

    public var body: some View {
        let bezelEnabled = showDeviceBezel && spec.style != .borderless
        let outerRadius = spec.outerCornerRadius(scale: scaleMultiplier, showBezel: bezelEnabled)
        let bezel = spec.bezelWidth(scale: scaleMultiplier, showBezel: bezelEnabled)
        let innerRadius = spec.innerCornerRadius(scale: scaleMultiplier, showBezel: bezelEnabled)
        let screenRadius = spec.screenClipRadius(scale: scaleMultiplier, showBezel: bezelEnabled)
        let finish = DeviceChassisFinish.resolve(for: device, spec: spec, matchDeviceColor: matchDeviceColor)

        let screenSize = CGSize(
            width: max(40, width - bezel * 2.0),
            height: max(40, height - bezel * 2.0)
        )
        let activeHole = (showCameraPunchHole ? spec.punchHole : nil)
        let holeCenter = activeHole?.resolvedCenter(in: screenSize, orientation: orientation)
        let holeRadius = activeHole?.resolvedRadius(in: screenSize) ?? 0

        ZStack {
            // Adaptive Ambilight or subtle natural shadow beneath chassis
            AmbilightGlowView(
                cornerRadius: outerRadius,
                isEnabled: enableAmbilight,
                palette: ambilightPalette
            )

            // Programmatic Vector Chassis
            RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                .fill(bezelEnabled ? finish.chassisFill : LinearGradient(colors: [.black, .black], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                        .stroke(
                            bezelEnabled
                                ? finish.chassisStroke
                                : LinearGradient(colors: [Color.white.opacity(0.16), Color.clear], startPoint: .top, endPoint: .bottom),
                            lineWidth: (bezelEnabled && spec.style == .samsungUltra) ? 2.0 : (bezelEnabled ? 1.5 : 0.75)
                        )
                )
                .overlay(
                    Group {
                        if bezelEnabled && spec.hasGlyphAccent {
                            RoundedRectangle(cornerRadius: max(4, outerRadius - 1.5), style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 0.9)
                                .padding(1.5)
                        }
                    }
                )
                .shadow(color: Color.black.opacity(enableAmbilight ? 0.40 : 0.50), radius: 22, x: 0, y: 12)
                .makeWindowDraggable()

            // Inner Display Substrate + Hardware Corner Clip + Camera Optics
            ZStack {
                RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                    .fill(Color.black)

                screenContent()
                    .frame(width: screenSize.width, height: screenSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                    .overlay {
                        if let center = holeCenter, holeRadius > 0 {
                            DeviceCameraLensView(radius: holeRadius)
                                .position(center)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(bezel)
        }
        .frame(width: width, height: height)
        .animation(Self.fluidSpring, value: width)
        .animation(Self.fluidSpring, value: height)
        .animation(Self.fluidSpring, value: orientation)
        .animation(Self.fluidSpring, value: spec.id)
        .animation(Self.fluidSpring, value: showDeviceBezel)
    }
}
