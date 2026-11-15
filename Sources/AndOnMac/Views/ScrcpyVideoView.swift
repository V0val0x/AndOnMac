import SwiftUI
import AppKit
import CoreVideo
import VideoToolbox

public struct ScrcpyVideoView: NSViewRepresentable {
    public let serial: String?
    public var screenClipRadius: CGFloat = 24
    public var onFileDrop: (([URL]) -> Void)?
    public var onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)?
    public var onHomeGestureTriggered: (() -> Void)?
    
    public init(
        serial: String?,
        screenClipRadius: CGFloat = 24,
        onFileDrop: (([URL]) -> Void)? = nil,
        onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)? = nil,
        onHomeGestureTriggered: (() -> Void)? = nil
    ) {
        self.serial = serial
        self.screenClipRadius = screenClipRadius
        self.onFileDrop = onFileDrop
        self.onHoverZonesChanged = onHoverZonesChanged
        self.onHomeGestureTriggered = onHomeGestureTriggered
    }
    
    public func makeNSView(context: Context) -> ScrcpyDisplayNSView {
        let view = ScrcpyDisplayNSView()
        view.serial = serial
        view.layer?.cornerRadius = screenClipRadius
        view.onFileDrop = onFileDrop
        view.onHoverZonesChanged = onHoverZonesChanged
        view.onHomeGestureTriggered = onHomeGestureTriggered
        return view
    }
    
    public func updateNSView(_ nsView: ScrcpyDisplayNSView, context: Context) {
        nsView.serial = serial
        nsView.layer?.cornerRadius = screenClipRadius
        nsView.onFileDrop = onFileDrop
        nsView.onHoverZonesChanged = onHoverZonesChanged
        nsView.onHomeGestureTriggered = onHomeGestureTriggered
        nsView.bindFrameCallback()
    }
}

public final class ScrcpyDisplayNSView: NSView {
    public var serial: String?
    public var onFileDrop: (([URL]) -> Void)?
    public var onHoverZonesChanged: ((_ isTop: Bool, _ isBottom: Bool) -> Void)?
    public var onHomeGestureTriggered: (() -> Void)?
    
    override public var isFlipped: Bool { true }
    override public var acceptsFirstResponder: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { !hasRenderedFrame }
    
    private var trackingArea: NSTrackingArea?
    private var latestImage: CGImage?
    private var metalRenderer: MetalVideoRenderer?
    private var displayLink: CADisplayLink?
    public private(set) var hasRenderedFrame: Bool = false
    private var isTrackingTouch: Bool = false
    private var touchStartNormalized: CGPoint?
    private var isTrackpadPanning: Bool = false
    private var trackpadPanPoint: CGPoint = .zero
    private var isBottomScrollHomeTracking: Bool = false
    private var bottomScrollAccumulatedUp: CGFloat = 0
    private var bottomScrollAccumulatedX: CGFloat = 0
    private var bottomScrollTriggered: Bool = false
    private var isPinching: Bool = false
    private var pinchCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var pinchSpread: CGFloat = 0.12

    public enum SmartphoneEdgeGesture: Equatable, Sendable {
        case back
        case home
        case appSwitcher
        case notifications
    }

    /// Detects Android smartphone edge gestures (edge-back, bottom-home, bottom-recents, top-notifications).
    public static func detectEdgeGesture(startNormalized: CGPoint, endNormalized: CGPoint) -> SmartphoneEdgeGesture? {
        let dx = endNormalized.x - startNormalized.x
        let dy = endNormalized.y - startNormalized.y

        // Left edge swipe right -> Back
        if startNormalized.x <= 0.06, dx >= 0.08, abs(dx) > abs(dy) * 1.25 {
            return .back
        }
        // Right edge swipe left -> Back
        if startNormalized.x >= 0.94, dx <= -0.08, abs(dx) > abs(dy) * 1.25 {
            return .back
        }
        // Bottom edge swipe up -> Home (normal swipe) or App Switcher (tall swipe > 50% screen)
        if startNormalized.y >= 0.90, dy <= -0.07, abs(dy) > abs(dx) * 1.25 {
            return dy <= -0.50 ? .appSwitcher : .home
        }
        // Top edge swipe down -> Notification Shade
        if startNormalized.y <= 0.08, dy >= 0.08, abs(dy) > abs(dx) * 1.25 {
            return .notifications
        }
        return nil
    }

    /// Detects whether a click-free two-finger trackpad scroll near the bottom edge should trigger Home.
    public static func shouldTriggerScrollHome(
        startNormalizedY: CGFloat,
        accumulatedUpwardDelta: CGFloat,
        horizontalDelta: CGFloat
    ) -> Bool {
        guard startNormalizedY >= 0.85 else { return false }
        return accumulatedUpwardDelta >= 22 && accumulatedUpwardDelta > abs(horizontalDelta) * 1.2
    }

    /// Converts high-precision macOS trackpad deltas into damped, bounded normalized drag increments.
    public static func trackpadDragDelta(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, viewSize: CGSize) -> CGPoint {
        let w = max(1.0, viewSize.width)
        let h = max(1.0, viewSize.height)
        let sensitivity: CGFloat = 0.75
        let maxStep: CGFloat = 0.08
        let nx = max(-maxStep, min(maxStep, (scrollingDeltaX * sensitivity) / w))
        let ny = max(-maxStep, min(maxStep, (scrollingDeltaY * sensitivity) / h))
        return CGPoint(x: nx, y: ny)
    }

    /// Clamps discrete physical mouse wheel scroll deltas so one notch never jumps multiple pages.
    public static func clampedMouseWheelScroll(deltaX: CGFloat, deltaY: CGFloat) -> (h: Float, v: Float) {
        let h = max(-0.35, min(0.35, Float(-deltaX) / 12.0))
        let v = max(-0.35, min(0.35, Float(deltaY) / 12.0))
        return (h, v)
    }
    
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

        if let renderer = MetalVideoRenderer() {
            self.metalRenderer = renderer
            renderer.metalLayer.frame = bounds
            renderer.metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            renderer.metalLayer.cornerRadius = 38
            renderer.metalLayer.masksToBounds = true
            layer?.addSublayer(renderer.metalLayer)
        }
        
        // Register for file drops from Mac Finder / Desktop
        registerForDraggedTypes([.fileURL])
        
        // Subscribe to decoded video frames
        bindFrameCallback()
    }

    private func ensureDisplayLink() {
        if window != nil && displayLink == nil && metalRenderer != nil {
            let link = self.displayLink(target: self, selector: #selector(handleDisplayLink))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            ensureDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func handleDisplayLink() {
        metalRenderer?.renderLatestFrameIfAvailable()
    }
    
    public func bindFrameCallback() {
        let renderer = self.metalRenderer
        ScrcpyClient.shared.onFrameDecoded = { [weak self, weak renderer] pixelBuffer in
            if let renderer = renderer {
                renderer.submit(pixelBuffer: pixelBuffer)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.hasRenderedFrame = true
                    if self.displayLink == nil {
                        self.ensureDisplayLink()
                        renderer.renderLatestFrameIfAvailable()
                    }
                }
                return
            }
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if let cgImage = cgImage {
                DispatchQueue.main.async {
                    guard let self = self, !self.hasRenderedFrame else { return }
                    self.renderCGImage(cgImage)
                }
            }
        }
        ScrcpyClient.shared.onFrameImageDecoded = { [weak self] cgImage in
            DispatchQueue.main.async {
                guard let self = self, self.metalRenderer == nil else { return }
                self.renderCGImage(cgImage)
            }
        }
        if !hasRenderedFrame, let cached = ScrcpyClient.shared.latestFrameImage, metalRenderer == nil {
            renderCGImage(cached)
        }
    }
    
    override public func layout() {
        super.layout()
        ensureDisplayLink()
        if let renderer = metalRenderer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            renderer.metalLayer.frame = bounds
            renderer.metalLayer.contentsScale = scale
            renderer.metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let corner = layer?.cornerRadius {
                renderer.metalLayer.cornerRadius = corner
            }
            CATransaction.commit()
        } else if let latestImage = latestImage {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = latestImage
            layer?.contentsGravity = .resizeAspect
            CATransaction.commit()
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
    
    public func renderCGImage(_ cgImage: CGImage) {
        self.latestImage = cgImage
        self.hasRenderedFrame = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = cgImage
        layer?.contentsGravity = .resizeAspect
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
        let loc = convert(event.locationInWindow, from: nil)
        guard hasRenderedFrame,
              loc.y > 38,
              let pt = normalizedPoint(from: event, allowClamping: false) else {
            // Drag when no frame rendered yet, in top HUD/status bar region, or on bezel/letterbox margin moves the macOS window
            isTrackingTouch = false
            window?.performDrag(with: event)
            return
        }
        isTrackingTouch = true
        let startPt = CGPoint(x: pt.x, y: pt.y)
        touchStartNormalized = startPt
        // Snap edge touches to exact 0/1 boundary so Android system edge gestures also engage natively
        let clampedX: CGFloat = startPt.x <= 0.05 ? 0.0 : (startPt.x >= 0.95 ? 1.0 : startPt.x)
        let clampedY: CGFloat = startPt.y >= 0.94 ? 1.0 : (startPt.y <= 0.05 ? 0.0 : startPt.y)
        ScrcpyClient.shared.sendTouchEvent(action: 0, normalizedX: clampedX, normalizedY: clampedY)
    }
    
    override public func mouseDragged(with event: NSEvent) {
        guard isTrackingTouch, let pt = normalizedPoint(from: event, allowClamping: true) else { return }
        ScrcpyClient.shared.sendTouchEvent(action: 2, normalizedX: pt.x, normalizedY: pt.y)
    }
    
    override public func mouseUp(with event: NSEvent) {
        guard isTrackingTouch else { return }
        isTrackingTouch = false
        let start = touchStartNormalized
        touchStartNormalized = nil
        guard let pt = normalizedPoint(from: event, allowClamping: true) else { return }

        if let start, let gesture = Self.detectEdgeGesture(startNormalized: start, endNormalized: CGPoint(x: pt.x, y: pt.y)) {
            ScrcpyClient.shared.sendTouchEvent(action: 3, normalizedX: pt.x, normalizedY: pt.y) // ACTION_CANCEL
            performEdgeGesture(gesture)
            return
        }
        ScrcpyClient.shared.sendTouchEvent(action: 1, normalizedX: pt.x, normalizedY: pt.y)
    }

    private func performEdgeGesture(_ gesture: SmartphoneEdgeGesture) {
        switch gesture {
        case .back:
            ScrcpyClient.shared.sendKeycode(4) // KEYCODE_BACK
        case .home:
            ScrcpyClient.shared.sendKeycode(3) // KEYCODE_HOME
        case .appSwitcher:
            ScrcpyClient.shared.sendKeycode(187) // KEYCODE_APP_SWITCH
        case .notifications:
            ScrcpyClient.shared.expandNotificationsPanel()
        }
    }
    
    override public func rightMouseDown(with event: NSEvent) {
        // Right click behaves as Android BACK button (Apple iPhone Mirroring behavior)
        ScrcpyClient.shared.sendBackOrScreenOn()
    }
    
    // MARK: - Trackpad & Mouse Scrolling + Multi-Touch Gestures
    override public func scrollWheel(with event: NSEvent) {
        guard hasRenderedFrame, let pt = normalizedPoint(from: event, allowClamping: true) else { return }

        if event.hasPreciseScrollingDeltas {
            // Suppress macOS momentum inertia so lifting fingers stops scrolling cleanly instead of flinging pages
            guard event.momentumPhase == [] else {
                if isTrackpadPanning {
                    ScrcpyClient.shared.sendTouchEvent(action: 1, pointerId: 10, normalizedX: trackpadPanPoint.x, normalizedY: trackpadPanPoint.y)
                    isTrackpadPanning = false
                }
                if isBottomScrollHomeTracking {
                    isBottomScrollHomeTracking = false
                    bottomScrollAccumulatedUp = 0
                    bottomScrollAccumulatedX = 0
                    bottomScrollTriggered = false
                }
                return
            }

            let upwardDelta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY

            if event.phase == .began || (!isTrackpadPanning && !isBottomScrollHomeTracking && (event.phase == .changed || event.phase == [])) {
                if pt.y >= 0.85 {
                    isBottomScrollHomeTracking = true
                    bottomScrollAccumulatedUp = 0
                    bottomScrollAccumulatedX = 0
                    bottomScrollTriggered = false
                }
            }

            if isBottomScrollHomeTracking {
                switch event.phase {
                case .began, .changed, []:
                    bottomScrollAccumulatedUp += upwardDelta
                    bottomScrollAccumulatedX += event.scrollingDeltaX
                    if !bottomScrollTriggered && Self.shouldTriggerScrollHome(
                        startNormalizedY: 0.90,
                        accumulatedUpwardDelta: bottomScrollAccumulatedUp,
                        horizontalDelta: bottomScrollAccumulatedX
                    ) {
                        bottomScrollTriggered = true
                        ScrcpyClient.shared.sendKeycode(3) // KEYCODE_HOME
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        DispatchQueue.main.async { [weak self] in
                            self?.onHomeGestureTriggered?()
                        }
                    }
                case .ended, .cancelled:
                    isBottomScrollHomeTracking = false
                    bottomScrollAccumulatedUp = 0
                    bottomScrollAccumulatedX = 0
                    bottomScrollTriggered = false
                default:
                    break
                }
                return
            }

            let vSize = videoRect().size
            let delta = Self.trackpadDragDelta(scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY, viewSize: vSize)

            switch event.phase {
            case .mayBegin:
                return
            case .began:
                isTrackpadPanning = true
                trackpadPanPoint = CGPoint(x: max(0.08, min(0.92, pt.x)), y: max(0.08, min(0.92, pt.y)))
                ScrcpyClient.shared.sendTouchEvent(action: 0, pointerId: 10, normalizedX: trackpadPanPoint.x, normalizedY: trackpadPanPoint.y)
            case .changed, []:
                if !isTrackpadPanning {
                    isTrackpadPanning = true
                    trackpadPanPoint = CGPoint(x: max(0.08, min(0.92, pt.x)), y: max(0.08, min(0.92, pt.y)))
                    ScrcpyClient.shared.sendTouchEvent(action: 0, pointerId: 10, normalizedX: trackpadPanPoint.x, normalizedY: trackpadPanPoint.y)
                }
                trackpadPanPoint = CGPoint(
                    x: max(0.01, min(0.99, trackpadPanPoint.x + delta.x)),
                    y: max(0.01, min(0.99, trackpadPanPoint.y + delta.y))
                )
                ScrcpyClient.shared.sendTouchEvent(action: 2, pointerId: 10, normalizedX: trackpadPanPoint.x, normalizedY: trackpadPanPoint.y)
            case .ended, .cancelled:
                if isTrackpadPanning {
                    ScrcpyClient.shared.sendTouchEvent(action: 1, pointerId: 10, normalizedX: trackpadPanPoint.x, normalizedY: trackpadPanPoint.y)
                    isTrackpadPanning = false
                }
            default:
                break
            }
        } else {
            let clamped = Self.clampedMouseWheelScroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            ScrcpyClient.shared.sendScrollEvent(normalizedX: pt.x, normalizedY: pt.y, deltaH: clamped.h, deltaV: clamped.v)
        }
    }

    override public func magnify(with event: NSEvent) {
        guard hasRenderedFrame, let pt = normalizedPoint(from: event, allowClamping: true) else { return }
        switch event.phase {
        case .began:
            isPinching = true
            pinchCenter = CGPoint(x: max(0.2, min(0.8, pt.x)), y: max(0.2, min(0.8, pt.y)))
            pinchSpread = 0.12
            ScrcpyClient.shared.sendTouchEvent(action: 0, pointerId: 20, normalizedX: pinchCenter.x - pinchSpread, normalizedY: pinchCenter.y)
            ScrcpyClient.shared.sendTouchEvent(action: 0, pointerId: 21, normalizedX: pinchCenter.x + pinchSpread, normalizedY: pinchCenter.y)
        case .changed:
            guard isPinching else { return }
            pinchSpread = max(0.03, min(0.45, pinchSpread + event.magnification * 0.22))
            ScrcpyClient.shared.sendTouchEvent(action: 2, pointerId: 20, normalizedX: max(0.02, pinchCenter.x - pinchSpread), normalizedY: pinchCenter.y)
            ScrcpyClient.shared.sendTouchEvent(action: 2, pointerId: 21, normalizedX: min(0.98, pinchCenter.x + pinchSpread), normalizedY: pinchCenter.y)
        case .ended, .cancelled:
            guard isPinching else { return }
            isPinching = false
            ScrcpyClient.shared.sendTouchEvent(action: 1, pointerId: 20, normalizedX: max(0.02, pinchCenter.x - pinchSpread), normalizedY: pinchCenter.y)
            ScrcpyClient.shared.sendTouchEvent(action: 1, pointerId: 21, normalizedX: min(0.98, pinchCenter.x + pinchSpread), normalizedY: pinchCenter.y)
        default:
            break
        }
    }

    override public func swipe(with event: NSEvent) {
        guard hasRenderedFrame else { return }
        if abs(event.deltaX) > abs(event.deltaY) {
            ScrcpyClient.shared.sendKeycode(4) // 3-finger swipe left/right -> Back
        } else if event.deltaY > 0 {
            ScrcpyClient.shared.sendKeycode(3) // 3-finger swipe up -> Home
        } else if event.deltaY < 0 {
            ScrcpyClient.shared.expandNotificationsPanel() // 3-finger swipe down -> Notifications
        }
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
        
        // Command key combinations (matched by hardware ANSI keyCode so they work on Russian/non-Latin layouts)
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 9: // V -> Universal Clipboard Paste (Cmd+V)
                if let string = NSPasteboard.general.string(forType: .string) {
                    ScrcpyClient.shared.setClipboardText(string, paste: true)
                    return
                }
            case 8: // C -> Copy (Cmd+C -> Android KEYCODE_COPY = 278)
                ScrcpyClient.shared.sendKeycode(278)
                return
            case 7: // X -> Cut (Cmd+X -> Android KEYCODE_CUT = 277)
                ScrcpyClient.shared.sendKeycode(277)
                return
            case 0: // A -> Select All (Cmd+A -> Android KEYCODE_A with CTRL = 0x3000)
                ScrcpyClient.shared.sendKeycode(29, metaState: 0x3000)
                return
            case 36, 76: // Return / Keypad Enter -> Send message
                ScrcpyClient.shared.sendKeycode(66, metaState: 0x3000)
                return
            default:
                // Let other Command shortcuts (Cmd+1/2/3/4/0/+/-/P/W/Q) pass to the macOS Menu Bar!
                super.keyDown(with: event)
                return
            }
        }
        
        // Special Keycode mapping
        switch event.keyCode {
        case 36, 76: // Enter / Return or Numpad Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                // Shift+Enter or Option+Enter -> Newline in chat / multiline
                ScrcpyClient.shared.sendKeycode(66, metaState: 0)
            } else {
                // Plain Enter -> Send message in messengers (Ctrl+Enter in Android)
                if AppState.shared?.sendOnEnter != false {
                    ScrcpyClient.shared.sendKeycode(66, metaState: 0x3000) // AMETA_CTRL_ON | AMETA_CTRL_LEFT_ON
                } else {
                    ScrcpyClient.shared.sendKeycode(66, metaState: 0)
                }
            }
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
