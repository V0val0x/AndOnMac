import AppKit
import SwiftUI

/// Manages the floating Spotlight-style `NSPanel` for Semantic Screen Memory ("Recall", `Cmd+Shift+F`).
@MainActor
public final class RecallPanelController {
    public static let shared = RecallPanelController()

    private var panel: NSPanel?

    private init() {}

    public func toggle(appState: AppState) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(appState: appState)
        }
    }

    public func show(appState: AppState) {
        if panel == nil {
            let newPanel = KeyableRecallPanel(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.isFloatingPanel = true
            newPanel.level = .floating
            newPanel.backgroundColor = .clear
            newPanel.isOpaque = false
            newPanel.hasShadow = false
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.isMovableByWindowBackground = true
            newPanel.hidesOnDeactivate = false
            self.panel = newPanel
        }

        guard let panel else { return }
        let rootView = RecallSearchView(appState: appState) { [weak self] in
            self?.close()
        }
        panel.contentView = NSHostingView(rootView: rootView)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    public func close() {
        panel?.orderOut(nil)
    }
}

private final class KeyableRecallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
