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
        .padding(AndSpacing.xl)
        .frame(width: targetWindowWidth, height: targetWindowHeight, alignment: .topLeading)
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
            WindowConfigurator { window in
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false // PhoneMirrorFrameView provides realistic shadow
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

// Configures the parent NSWindow to be transparent and floating;
// sizing is handled natively by .windowResizability(.contentSize) + finite frame.
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    var onWillClose: (() -> Void)? = nil

    final class Coordinator {
        var observedWindow: NSWindow?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                attachCloseObserver(to: window, coordinator: context.coordinator)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                configure(window)
                attachCloseObserver(to: window, coordinator: context.coordinator)
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

