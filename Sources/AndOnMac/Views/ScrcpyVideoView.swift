import SwiftUI
import AppKit
import CoreVideo
import VideoToolbox

public struct ScrcpyVideoView: NSViewRepresentable {
    public let serial: String?
    public var onFileDrop: (([URL]) -> Void)?
    public var onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)?
    
    public init(
        serial: String?,
        onFileDrop: (([URL]) -> Void)? = nil,
        onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)? = nil
    ) {
        self.serial = serial
        self.onFileDrop = onFileDrop
        self.onHoverZonesChanged = onHoverZonesChanged
    }
    
    public func makeNSView(context: Context) -> ScrcpyDisplayNSView {
        let view = ScrcpyDisplayNSView()
        view.serial = serial
        view.onFileDrop = onFileDrop
        view.onHoverZonesChanged = onHoverZonesChanged
        return view
    }
    
    public func updateNSView(_ nsView: ScrcpyDisplayNSView, context: Context) {
        nsView.serial = serial
        nsView.onFileDrop = onFileDrop
        nsView.onHoverZonesChanged = onHoverZonesChanged
    }
}

public final class ScrcpyDisplayNSView: NSView {
    public var serial: String?
    public var onFileDrop: (([URL]) -> Void)?
    public var onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)?
    
    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    
    private var trackingArea: NSTrackingArea?
    
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 38
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspect
        
        // Register for file drops from Mac Finder / Desktop
        registerForDraggedTypes([.fileURL])
        
        // Subscribe to decoded video frames
        ScrcpyClient.shared.onFrameDecoded = { [weak self] pixelBuffer in
            nonisolated(unsafe) let pb = pixelBuffer
            DispatchQueue.main.async {
                self?.renderFrame(pb)
            }
        }
    }
    
    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .mouseMoved, .mouseEnteredAndExited]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    private func renderFrame(_ pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        let contents = (cgImage as AnyObject?) ?? (CVPixelBufferGetIOSurface(pixelBuffer) as AnyObject?)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = contents
        CATransaction.commit()
    }
    
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override public func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let isTop = loc.y >= 0 && loc.y <= 42
        let isBottom = loc.y >= bounds.height - 38 && loc.y <= bounds.height
        onHoverZonesChanged?(isTop, isBottom)
    }
    
    override public func mouseExited(with event: NSEvent) {
        onHoverZonesChanged?(false, false)
    }
    
    // MARK: - Video Display Rect Calculator (Handles Letterbox & Pillarbox)
    private func videoRect() -> CGRect {
        let dw = CGFloat(ScrcpyClient.shared.deviceWidth)
        let dh = CGFloat(ScrcpyClient.shared.deviceHeight)
        guard dw > 0, dh > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = dw / dh
        if viewAspect > videoAspect {
            // Pillarbox (black bars left and right)
            let videoW = bounds.height * videoAspect
            let offsetX = (bounds.width - videoW) / 2.0
            return CGRect(x: offsetX, y: 0, width: videoW, height: bounds.height)
        } else {
            // Letterbox (black bars top and bottom)
            let videoH = bounds.width / videoAspect
            let offsetY = (bounds.height - videoH) / 2.0
            return CGRect(x: 0, y: offsetY, width: bounds.width, height: videoH)
        }
    }
    
    // MARK: - Touch Coordinates Helper
    private func normalizedPoint(from event: NSEvent, allowClamping: Bool = false) -> (x: CGFloat, y: CGFloat)? {
        let vRect = videoRect()
        guard vRect.width > 0, vRect.height > 0 else { return nil }
        let loc = convert(event.locationInWindow, from: nil)
        if !allowClamping && !vRect.contains(loc) { return nil }
        let nx = max(0.0, min(1.0, (loc.x - vRect.origin.x) / vRect.width))
        let ny = max(0.0, min(1.0, (loc.y - vRect.origin.y) / vRect.height))
        return (nx, ny)
    }
    
    // MARK: - Mouse Events (Forwarded to scrcpy touch protocol)
    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let pt = normalizedPoint(from: event, allowClamping: false) else { return }
        ScrcpyClient.shared.sendTouchEvent(action: 0, normalizedX: pt.x, normalizedY: pt.y)
    }
    
    override public func mouseDragged(with event: NSEvent) {
        guard let pt = normalizedPoint(from: event, allowClamping: true) else { return }
        ScrcpyClient.shared.sendTouchEvent(action: 2, normalizedX: pt.x, normalizedY: pt.y)
    }
    
    override public func mouseUp(with event: NSEvent) {
        guard let pt = normalizedPoint(from: event, allowClamping: true) else { return }
        ScrcpyClient.shared.sendTouchEvent(action: 1, normalizedX: pt.x, normalizedY: pt.y)
    }
    
    override public func rightMouseDown(with event: NSEvent) {
        // Right click behaves as Android BACK button (Apple iPhone Mirroring behavior)
        ScrcpyClient.shared.sendBackOrScreenOn()
    }
    
    // MARK: - Trackpad & Mouse Scrolling
    override public func scrollWheel(with event: NSEvent) {
        guard let pt = normalizedPoint(from: event, allowClamping: true) else { return }
        // Scale delta for smooth scroll on Android
        let deltaH = -Float(event.scrollingDeltaX) / 100.0
        let deltaV = Float(event.scrollingDeltaY) / 100.0
        ScrcpyClient.shared.sendScrollEvent(normalizedX: pt.x, normalizedY: pt.y, deltaH: deltaH, deltaV: deltaV)
    }
    
    // MARK: - Keyboard Events
    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Immediate sync for CapsLock, Globe / Fn, or modifier-based layout toggles
        KeyboardLanguageSyncService.shared.checkAndSyncLanguage()
    }
    
    override public func keyDown(with event: NSEvent) {
        // Handle Language / Input Source Switching shortcuts (Cmd+Space, Ctrl+Space)
        if event.keyCode == 49 && (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)) {
            super.keyDown(with: event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                KeyboardLanguageSyncService.shared.checkAndSyncLanguage()
            }
            return
        }
        
        // Command key combinations
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch key {
            case "v":
                // Universal Clipboard Paste (Cmd+V)
                if let string = NSPasteboard.general.string(forType: .string) {
                    ScrcpyClient.shared.setClipboardText(string)
                    return
                }
            case "c":
                // Copy (Cmd+C -> Android KEYCODE_COPY = 278)
                ScrcpyClient.shared.sendKeycode(278)
                return
            case "x":
                // Cut (Cmd+X -> Android KEYCODE_CUT = 277)
                ScrcpyClient.shared.sendKeycode(277)
                return
            case "a":
                // Select All (Cmd+A -> Android KEYCODE_A with CTRL or KEYCODE_ALL_APPS)
                // Inject Ctrl+A via text/key combinations
                ScrcpyClient.shared.sendKeycode(29) // KEYCODE_A
                return
            default:
                // Let other Command shortcuts (Cmd+1/2/3/4/0/+/-/P/W/Q) pass to the macOS Menu Bar!
                super.keyDown(with: event)
                return
            }
        }
        
        // Special Keycode mapping
        switch event.keyCode {
        case 36: // Enter / Return
            ScrcpyClient.shared.sendKeycode(66) // KEYCODE_ENTER
        case 51: // Backspace / Delete
            ScrcpyClient.shared.sendKeycode(67) // KEYCODE_DEL
        case 53: // Escape -> Back
            ScrcpyClient.shared.sendKeycode(4) // KEYCODE_BACK
        case 48: // Tab
            ScrcpyClient.shared.sendKeycode(61) // KEYCODE_TAB
        case 126: // Arrow Up
            ScrcpyClient.shared.sendKeycode(19) // KEYCODE_DPAD_UP
        case 125: // Arrow Down
            ScrcpyClient.shared.sendKeycode(20) // KEYCODE_DPAD_DOWN
        case 123: // Arrow Left
            ScrcpyClient.shared.sendKeycode(21) // KEYCODE_DPAD_LEFT
        case 124: // Arrow Right
            ScrcpyClient.shared.sendKeycode(22) // KEYCODE_DPAD_RIGHT
        default:
            if let chars = event.characters, !chars.isEmpty {
                ScrcpyClient.shared.sendText(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }
    
    // MARK: - Drag & Drop Destination (Mac -> Phone)
    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.fileURL.rawValue]) {
            return .copy
        }
        return []
    }
    
    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let items = pasteboard.pasteboardItems else { return false }
        
        var fileURLs: [URL] = []
        for item in items {
            if let str = item.string(forType: .fileURL), let url = URL(string: str) {
                fileURLs.append(url)
            }
        }
        
        guard !fileURLs.isEmpty else { return false }
        
        if let callback = onFileDrop {
            callback(fileURLs)
        } else if let s = serial {
            Task {
                _ = await PhotoTransferService.shared.pushFiles(urls: fileURLs, serial: s)
            }
        }
        return true
    }
}
