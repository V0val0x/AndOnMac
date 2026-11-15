import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Main Phone Chassis (Frameless Sequoia Floating Smartphone)
            PhoneMirrorFrameView(appState: appState)
            
            // Photo & File Transfer Side Drawer
            if appState.showPhotoDrawer {
                PhotoTransferDrawerView(appState: appState)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            }
        }
        .padding(28)
        .background(
            WindowConfigurator(
                showDrawer: appState.showPhotoDrawer,
                scale: appState.windowScale,
                spec: appState.effectiveHardwareSpec,
                isLandscape: appState.isLandscape,
                aspect: appState.effectiveAspect
            ) { window in
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false // DeviceFrameRenderer provides realistic shadow & Ambilight
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            }
        )
    }
}

// Configures the parent NSWindow to be transparent, floating, and smoothly animated between fixed presets & rotations
private struct WindowConfigurator: NSViewRepresentable {
    let showDrawer: Bool
    let scale: PhoneWindowScale
    let spec: DeviceHardwareSpec
    let isLandscape: Bool
    let aspect: CGFloat
    let configure: (NSWindow) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                if context.coordinator.configuredWindow !== window {
                    configure(window)
                    context.coordinator.configuredWindow = window
                }
                updateWindowSize(window: window, animated: false)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            if context.coordinator.configuredWindow !== window {
                configure(window)
                context.coordinator.configuredWindow = window
            }
            updateWindowSize(window: window, animated: true)
        }
    }
    
    private func updateWindowSize(window: NSWindow, animated: Bool) {
        let mult = spec.baseWidthMultiplier
        let phoneWidth: CGFloat
        let phoneHeight: CGFloat
        if isLandscape {
            let h = 320.0 * scale.multiplier
            phoneWidth = h * aspect * mult
            phoneHeight = h
        } else {
            phoneWidth = 320.0 * scale.multiplier * mult
            phoneHeight = (320.0 * aspect) * scale.multiplier
        }
        
        let outerPadding: CGFloat = 56 // 28pt on each side so Ambilight glow never clips
        let targetWidth = (phoneWidth + outerPadding) + (showDrawer ? 290 + 16 : 0)
        let targetHeight = phoneHeight + outerPadding
        
        let currentFrame = window.frame
        let deltaW = targetWidth - currentFrame.width
        let deltaH = targetHeight - currentFrame.height
        
        if abs(deltaW) > 2 || abs(deltaH) > 2 {
            let newOrigin = NSPoint(x: currentFrame.origin.x, y: currentFrame.origin.y - deltaH)
            let newFrame = NSRect(origin: newOrigin, size: NSSize(width: targetWidth, height: targetHeight))
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.12, 0.36, 1.0)
                    window.animator().setFrame(newFrame, display: true)
                }
            } else {
                window.setFrame(newFrame, display: true, animate: false)
            }
        }
    }
}

// MARK: - Native Window Dragging for macOS 14–27+
public struct WindowDraggableModifier: ViewModifier {
    public init() {}
    
    public func body(content: Content) -> some View {
        content
            .background(WindowDragRepresentable())
    }
}

private struct WindowDragRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }
    
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

public extension View {
    func makeWindowDraggable() -> some View {
        self.modifier(WindowDraggableModifier())
    }
}

