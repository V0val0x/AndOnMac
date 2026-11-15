import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @State private var drawerExpanded: Bool = false
    
    public init(appState: AppState) {
        self.appState = appState
    }
    
    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Main Phone Chassis (Frameless Sequoia Floating Smartphone)
            PhoneMirrorFrameView(appState: appState)
                .zIndex(1)
            
            // Photo & File Transfer Side Drawer
            if drawerExpanded {
                PhotoTransferDrawerView(appState: appState)
                    .zIndex(0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                            removal: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity)
                        )
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(AndSpacing.xl)
        .onChange(of: appState.showPhotoDrawer) { _, newValue in
            if !newValue {
                withAnimation(AndMotion.drawerSpring) {
                    drawerExpanded = false
                }
            }
        }
        .background(
            WindowConfigurator(
                showDrawer: appState.showPhotoDrawer,
                scale: appState.windowScale,
                style: appState.effectiveFrameStyle,
                isLandscape: appState.isLandscape,
                aspect: appState.effectiveAspect,
                onDrawerWindowExpanded: {
                    withAnimation(AndMotion.drawerSpring) {
                        drawerExpanded = true
                    }
                }
            ) { window in
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false // PhoneMirrorFrameView provides realistic shadow
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

// Configures the parent NSWindow to be transparent, floating, and dynamically sized
private struct WindowConfigurator: NSViewRepresentable {
    let showDrawer: Bool
    let scale: PhoneWindowScale
    let style: PhoneFrameStyle
    let isLandscape: Bool
    let aspect: CGFloat
    let onDrawerWindowExpanded: () -> Void
    let configure: (NSWindow) -> Void
    
    final class Coordinator {
        var lastShowDrawer: Bool?
        var pendingShrinkWorkItem: DispatchWorkItem?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.lastShowDrawer = showDrawer
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                updateWindowSize(window: window, animated: false)
                if showDrawer {
                    onDrawerWindowExpanded()
                }
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        let previousShowDrawer = context.coordinator.lastShowDrawer
        context.coordinator.lastShowDrawer = showDrawer

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window)

            if let previous = previousShowDrawer, previous != showDrawer {
                context.coordinator.pendingShrinkWorkItem?.cancel()
                context.coordinator.pendingShrinkWorkItem = nil

                if showDrawer {
                    // Expand invisible transparent NSWindow bounds first, then spring-reveal the drawer
                    // so the phone chassis stays rock-solid at origin.x with zero sideways jump.
                    updateWindowSize(window: window, animated: false)
                    onDrawerWindowExpanded()
                } else {
                    // Wait for the drawer closing spring to finish before shrinking the invisible window.
                    let workItem = DispatchWorkItem { [weak window] in
                        guard let window else { return }
                        self.updateWindowSize(window: window, animated: false)
                    }
                    context.coordinator.pendingShrinkWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: workItem)
                }
            } else {
                updateWindowSize(window: window, animated: true)
            }
        }
    }
    
    private func updateWindowSize(window: NSWindow, animated: Bool) {
        let mult = style.baseWidthMultiplier
        let bezel = style.bezelWidth * 2
        let phoneWidth: CGFloat
        let phoneHeight: CGFloat
        if isLandscape {
            let h = 320.0 * scale.multiplier
            phoneWidth = h * aspect * mult + bezel
            phoneHeight = h + bezel
        } else {
            phoneWidth = 320.0 * scale.multiplier * mult + bezel
            phoneHeight = (320.0 * aspect) * scale.multiplier + bezel
        }
        
        let targetWidth = (phoneWidth + 40) + (showDrawer ? 290 + 16 : 0)
        let targetHeight = phoneHeight + 40
        
        let currentFrame = window.frame
        let deltaW = targetWidth - currentFrame.width
        let deltaH = targetHeight - currentFrame.height
        
        if abs(deltaW) > 2 || abs(deltaH) > 2 {
            let newOrigin = NSPoint(x: currentFrame.origin.x, y: currentFrame.origin.y - deltaH)
            let newFrame = NSRect(origin: newOrigin, size: NSSize(width: targetWidth, height: targetHeight))
            window.setFrame(newFrame, display: true, animate: animated)
        }
    }
}

// MARK: - Native Window Dragging for macOS 14–27+
public struct WindowDraggableModifier: ViewModifier {
    public init() {}
    
    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .background(WindowDragRepresentable())
                .gesture(WindowDragGesture())
        } else {
            content
                .background(WindowDragRepresentable())
        }
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

