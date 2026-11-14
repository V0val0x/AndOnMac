import SwiftUI

// MARK: - Motion Tokens
public enum AndMotion {
    /// Crisp, responsive spring for HUD, floating capsules, and toasts
    public static let hudSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Tactile spring for button presses, hover highlights, and Home bar pulse
    public static let microSpring = Animation.spring(response: 0.22, dampingFraction: 0.74)
    /// Smooth spring for side drawer presentation and layout transitions
    public static let drawerSpring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// Sliding pill indicator spring for tabs and category filters
    public static let pillSlide = Animation.spring(response: 0.30, dampingFraction: 0.84)
    /// Gentle spring for Home bar bounce feedback
    public static let homePulseSpring = Animation.spring(response: 0.26, dampingFraction: 0.62)
}

// MARK: - Geometry & Spacing Tokens
public enum AndRadius {
    public static let xs: CGFloat = 6
    public static let control: CGFloat = 10
    public static let thumb: CGFloat = 10
    public static let card: CGFloat = 16
    public static let drawer: CGFloat = 24
    public static let pill: CGFloat = 999
}

public enum AndSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
}

// MARK: - Hairline Glass Surfaces
public struct AndGlassCapsuleModifier: ViewModifier {
    var cornerRadius: CGFloat = AndRadius.pill
    var tintOpacity: Double = 0.22
    var shadowRadius: CGFloat = 10

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(tintOpacity))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: shadowRadius, x: 0, y: 4)
    }
}

public struct AndGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = AndRadius.card
    var shadowRadius: CGFloat = 12

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.26),
                                Color.white.opacity(0.06)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(0.14), radius: shadowRadius, x: 0, y: 5)
    }
}

public extension View {
    func andonGlassCapsule(cornerRadius: CGFloat = AndRadius.pill, tintOpacity: Double = 0.22, shadowRadius: CGFloat = 10) -> some View {
        modifier(AndGlassCapsuleModifier(cornerRadius: cornerRadius, tintOpacity: tintOpacity, shadowRadius: shadowRadius))
    }

    func andonGlassCard(cornerRadius: CGFloat = AndRadius.card, shadowRadius: CGFloat = 12) -> some View {
        modifier(AndGlassCardModifier(cornerRadius: cornerRadius, shadowRadius: shadowRadius))
    }
}

// MARK: - Interactive Button Styles
public struct AndonHUDIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.24 : (isHovered ? 0.14 : 0.0)))
            )
            .scaleEffect(configuration.isPressed ? 0.90 : (isHovered ? 1.06 : 1.0))
            .animation(AndMotion.microSpring, value: configuration.isPressed)
            .animation(AndMotion.microSpring, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct AndonTactileScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96

    public init(pressedScale: CGFloat = 0.96) {
        self.pressedScale = pressedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(AndMotion.microSpring, value: configuration.isPressed)
    }
}
