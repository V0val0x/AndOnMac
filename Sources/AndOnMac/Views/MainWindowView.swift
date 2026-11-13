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
        .padding(20)
        .background(
            WindowConfigurator(
                showDrawer: appState.showPhotoDrawer,
                scale: appState.windowScale
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
        .sheet(isPresented: $appState.showPairingSheet) {
            WirelessPairingView(appState: appState)
        }
    }
}

// Configures the parent NSWindow to be transparent, floating, and dynamically sized
private struct WindowConfigurator: NSViewRepresentable {
    let showDrawer: Bool
    let scale: PhoneWindowScale
    let configure: (NSWindow) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
                updateWindowSize(window: window, animated: false)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configure(window)
            updateWindowSize(window: window, animated: true)
        }
    }
    
    private func updateWindowSize(window: NSWindow, animated: Bool) {
        let phoneWidth = 360 * scale.multiplier
        let aspect = CGFloat(ScrcpyClient.shared.deviceHeight) / CGFloat(max(1, ScrcpyClient.shared.deviceWidth))
        let effectiveAspect = (aspect >= 1.3 && aspect <= 2.4) ? aspect : (20.0 / 9.0)
        let phoneHeight = (360.0 * effectiveAspect) * scale.multiplier
        
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
