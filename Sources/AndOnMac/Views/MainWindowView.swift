import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState: AppState
    @State private var drawerExpanded: Bool = false
    @State private var windowWideForDrawer: Bool = false
    @State private var shrinkTask: DispatchWorkItem?
    
    public init(appState: AppState) {
        self.appState = appState
    }

    private var phoneTotalSize: CGSize {
        let bezel = appState.effectiveFrameStyle.bezelWidth * 2
        let mult = appState.effectiveFrameStyle.baseWidthMultiplier
        if appState.isLandscape {
            let h = 320.0 * appState.windowScale.multiplier
            return CGSize(width: h * appState.effectiveAspect * mult + bezel, height: h + bezel)
        } else {
            return CGSize(width: 320.0 * appState.windowScale.multiplier * mult + bezel,
                          height: (320.0 * appState.effectiveAspect) * appState.windowScale.multiplier + bezel)
        }
    }

    private var targetWindowWidth: CGFloat {
        phoneTotalSize.width + (AndSpacing.xl * 2) + (windowWideForDrawer ? 290 + 16 : 0)
    }

    private var targetWindowHeight: CGFloat {
        phoneTotalSize.height + (AndSpacing.xl * 2)
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
        }
        .padding(28)
        .onAppear {
            windowWideForDrawer = appState.showPhotoDrawer
            drawerExpanded = appState.showPhotoDrawer
        }
        .onChange(of: appState.showPhotoDrawer) { _, newValue in
            shrinkTask?.cancel()
            shrinkTask = nil

            if newValue {
                windowWideForDrawer = true
                DispatchQueue.main.async {
                    withAnimation(AndMotion.drawerSpring) {
                        drawerExpanded = true
                    }
                }
            } else {
                withAnimation(AndMotion.drawerSpring) {
                    drawerExpanded = false
                }
                let item = DispatchWorkItem {
                    if !appState.showPhotoDrawer {
                        windowWideForDrawer = false
                    }
                }
                shrinkTask = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: item)
            }
        }
        .background(
            WindowConfigurator(
                showDrawer: windowWideForDrawer,
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
            } onWillClose: {
                appState.stopMirroringOnWindowClose()
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
    var onWillClose: (() -> Void)? = nil
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator {
        weak var configuredWindow: NSWindow?
        var observedWindow: NSWindow?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                if context.coordinator.configuredWindow !== window {
                    configure(window)
                    context.coordinator.configuredWindow = window
                }
                attachCloseObserver(to: window, coordinator: context.coordinator)
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
            attachCloseObserver(to: window, coordinator: context.coordinator)
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

    private func attachCloseObserver(to window: NSWindow, coordinator: Coordinator) {
        guard coordinator.observedWindow !== window else { return }
        if let prev = coordinator.closeObserver {
            NotificationCenter.default.removeObserver(prev)
        }
        coordinator.observedWindow = window
        coordinator.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onWillClose?()
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

public struct NonDraggableAreaRepresentable: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NonDraggableNSView {
        NonDraggableNSView()
    }

    public func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

public final class NonDraggableNSView: NSView {
    override public var mouseDownCanMoveWindow: Bool { false }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

public extension View {
    func makeWindowDraggable() -> some View {
        self.modifier(WindowDraggableModifier())
    }
}

