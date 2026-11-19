import SwiftUI
import AppKit
import QuartzCore
import AndroidShadowGraphKit

// MARK: - Coordinate Mapping & Target Extraction

public enum AgenticHUDCoordinateMapper {
    /// Computes the exact aspect-fitted video display rect within `viewSize` (matching `ScrcpyDisplayNSView.videoRect()`).
    public static func videoRect(in viewSize: CGSize, deviceWidth: Int, deviceHeight: Int) -> CGRect {
        let dw = CGFloat(deviceWidth)
        let dh = CGFloat(deviceHeight)
        guard dw > 0, dh > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = dw / dh
        if viewAspect > videoAspect {
            let videoW = viewSize.height * videoAspect
            let offsetX = (viewSize.width - videoW) / 2.0
            return CGRect(x: offsetX, y: 0, width: videoW, height: viewSize.height)
        } else {
            let videoH = viewSize.width / videoAspect
            let offsetY = (viewSize.height - videoH) / 2.0
            return CGRect(x: 0, y: offsetY, width: viewSize.width, height: videoH)
        }
    }

    /// Orients Android physical display dimensions `(inputWidth, inputHeight)` to match the live video orientation
    /// so portrait/landscape rotations map `(x, y)` accurately onto the video frame.
    public static func orientedInputSize(
        inputWidth: Int,
        inputHeight: Int,
        videoWidth: Int,
        videoHeight: Int
    ) -> (width: Int, height: Int) {
        let baseW = inputWidth > 0 ? inputWidth : max(1, videoWidth)
        let baseH = inputHeight > 0 ? inputHeight : max(1, videoHeight)
        if videoWidth > 0 && videoHeight > 0 && (videoWidth > videoHeight) != (baseW > baseH) {
            return (baseH, baseW)
        }
        return (baseW, baseH)
    }

    /// Maps Android physical pixel coordinates `(deviceX, deviceY)` (from Accessibility / `input tap` space `inputWidth x inputHeight`)
    /// into view coordinates (top-left origin) over the aspect-fitted `videoWidth x videoHeight` stream rect.
    public static func viewPoint(
        deviceX: Int,
        deviceY: Int,
        in viewSize: CGSize,
        videoWidth: Int,
        videoHeight: Int,
        inputWidth: Int? = nil,
        inputHeight: Int? = nil
    ) -> CGPoint {
        let vRect = videoRect(in: viewSize, deviceWidth: videoWidth, deviceHeight: videoHeight)
        let resolvedInput = orientedInputSize(
            inputWidth: (inputWidth ?? 0) > 0 ? inputWidth! : videoWidth,
            inputHeight: (inputHeight ?? 0) > 0 ? inputHeight! : videoHeight,
            videoWidth: videoWidth,
            videoHeight: videoHeight
        )
        let dw = CGFloat(max(1, resolvedInput.width))
        let dh = CGFloat(max(1, resolvedInput.height))
        let nx = max(0.0, min(1.0, CGFloat(deviceX) / dw))
        let ny = max(0.0, min(1.0, CGFloat(deviceY) / dh))
        return CGPoint(
            x: vRect.origin.x + nx * vRect.width,
            y: vRect.origin.y + ny * vRect.height
        )
    }

    /// Maps Android device pixel coordinates `(deviceX, deviceY)` (top-left origin) to view coordinates (top-left origin).
    public static func viewPoint(
        deviceX: Int,
        deviceY: Int,
        in viewSize: CGSize,
        deviceWidth: Int,
        deviceHeight: Int
    ) -> CGPoint {
        viewPoint(
            deviceX: deviceX,
            deviceY: deviceY,
            in: viewSize,
            videoWidth: deviceWidth,
            videoHeight: deviceHeight,
            inputWidth: deviceWidth,
            inputHeight: deviceHeight
        )
    }

    /// Extracts `(endX, endY)` if present, falling back to `(x, y)` for point actions such as `.tap`.
    public static func targetCoordinates(for action: AttributedUIAction) -> (x: Int, y: Int)? {
        if let endX = action.endX, let endY = action.endY {
            return (endX, endY)
        }
        if let x = action.x, let y = action.y {
            return (action.endX ?? x, action.endY ?? y)
        }
        return nil
    }
}

// MARK: - HUD State & MacroExecutionEngine Stream Listener

public enum AgenticHUDTelemetryMode: Equatable, Sendable {
    case autonomous          // Red (#FF3B30) — autonomous A* routing & execution
    case awaitingUserInput   // Yellow (#FFCC00) — waiting for chat confirmation or text input
    case awaitingBiometrics  // Blue (#0A84FF) — waiting for manual biometrics / PIN (FLAG_SECURE)
}

public struct AgenticTargetReticle: Equatable, Sendable {
    public let id: UUID
    public let x: Int
    public let y: Int
    public let startX: Int?
    public let startY: Int?
    public let kind: AttributedUIAction.Kind
    public let label: String
    public let telemetryMode: AgenticHUDTelemetryMode
    public let isCenteredIndicator: Bool

    public init(
        id: UUID = UUID(),
        x: Int,
        y: Int,
        startX: Int? = nil,
        startY: Int? = nil,
        kind: AttributedUIAction.Kind,
        label: String = "",
        telemetryMode: AgenticHUDTelemetryMode = .autonomous,
        isCenteredIndicator: Bool = false
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.startX = startX
        self.startY = startY
        self.kind = kind
        self.label = label
        self.telemetryMode = telemetryMode
        self.isCenteredIndicator = isCenteredIndicator
    }
}

public enum AgenticToastPhase: Equatable, Sendable {
    case idle
    case executing
    case awaitingConfirmation
    case awaitingBiometrics
    case completed
    case failed
}

@MainActor
public final class AgenticHUDViewModel: ObservableObject {
    @Published public private(set) var toastTitle: String?
    @Published public private(set) var toastSubtitle: String?
    @Published public private(set) var toastPhase: AgenticToastPhase = .idle
    @Published public private(set) var telemetryMode: AgenticHUDTelemetryMode = .autonomous
    @Published public private(set) var activeReticle: AgenticTargetReticle?
    @Published public private(set) var prefersTopToastDock: Bool = false

    private var streamTask: Task<Void, Never>?
    private var reticleClearTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?
    private var lastPathComputedStepCount: Int?

    public init() {}

    deinit {
        streamTask?.cancel()
        reticleClearTask?.cancel()
        toastDismissTask?.cancel()
    }

    /// Subscribes to a `MacroExecutionEngine` instance's `AsyncStream` without blocking execution.
    public func attach(to engine: MacroExecutionEngine) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            let stream = await engine.events
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handle(event: event)
            }
        }
    }

    /// Subscribes to a broadcast `AsyncStream<MacroExecutionEvent>` within the caller's structured task (e.g. SwiftUI `.task`).
    public func listen(to stream: AsyncStream<MacroExecutionEvent>) async {
        streamTask?.cancel()
        streamTask = nil
        for await event in stream {
            guard !Task.isCancelled else { break }
            handle(event: event)
        }
    }

    /// Subscribes to a broadcast `AsyncStream<MacroExecutionEvent>` (e.g. `ShadowGraphManager.shared.macroExecutionEvents`).
    public func startListening(to stream: AsyncStream<MacroExecutionEvent>) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.handle(event: event)
            }
        }
    }

    public func stopListening() {
        streamTask?.cancel()
        streamTask = nil
    }

    public func handle(event: MacroExecutionEvent) {
        switch event {
        case .pathComputed(let totalSteps, let targetHint):
            toastDismissTask?.cancel()
            lastPathComputedStepCount = totalSteps
            telemetryMode = .autonomous
            let unit = totalSteps == 1 ? "step" : "steps"
            toastTitle = "🤖 A* Path Computed: \(totalSteps) \(unit). Executing..."
            toastSubtitle = targetHint?.isEmpty == false ? "Target: \(targetHint!)" : nil
            toastPhase = .executing
            prefersTopToastDock = false

        case .executionStarted(let totalSteps):
            toastDismissTask?.cancel()
            telemetryMode = .autonomous
            if toastPhase != .executing || lastPathComputedStepCount != totalSteps {
                let unit = totalSteps == 1 ? "step" : "steps"
                toastTitle = "🤖 A* Path Computed: \(totalSteps) \(unit). Executing..."
                toastSubtitle = nil
            }
            toastPhase = .executing

        case .willExecuteAction(let stepIndex, let totalSteps, let action):
            toastDismissTask?.cancel()
            telemetryMode = .autonomous
            let actionVerb = (action.kind == .swipe) ? "Scrolling" : "A* Routing"
            toastTitle = "🤖 Step \(stepIndex + 1)/\(totalSteps) · \(actionVerb)"
            let label = action.targetDescription.isEmpty ? action.signature : action.targetDescription
            toastSubtitle = label
            toastPhase = .executing

            if let coords = AgenticHUDCoordinateMapper.targetCoordinates(for: action) {
                showReticle(AgenticTargetReticle(
                    x: coords.x,
                    y: coords.y,
                    startX: action.x,
                    startY: action.y,
                    kind: action.kind,
                    label: label,
                    telemetryMode: .autonomous
                ))
            } else {
                prefersTopToastDock = false
            }

        case .stepSettled:
            if telemetryMode == .autonomous {
                scheduleReticleClear(afterSeconds: 0.08)
            }

        case .awaitingConfirmation(let stepIndex, let totalSteps, let action, let reason):
            reticleClearTask?.cancel()
            toastDismissTask?.cancel()
            lastPathComputedStepCount = nil
            telemetryMode = .awaitingUserInput
            toastPhase = .awaitingConfirmation
            toastTitle = "⚠️ Confirm in Chat (\(stepIndex + 1)/\(totalSteps))"
            toastSubtitle = reason
            let label = action.targetDescription.isEmpty ? action.signature : action.targetDescription
            if let coords = AgenticHUDCoordinateMapper.targetCoordinates(for: action) {
                activeReticle = AgenticTargetReticle(
                    x: coords.x,
                    y: coords.y,
                    startX: action.x,
                    startY: action.y,
                    kind: .tap,
                    label: label,
                    telemetryMode: .awaitingUserInput
                )
            } else {
                activeReticle = AgenticTargetReticle(
                    x: 0,
                    y: 0,
                    kind: .tap,
                    label: label,
                    telemetryMode: .awaitingUserInput,
                    isCenteredIndicator: true
                )
            }

        case .awaitingChatInput(let prompt, let focusX, let focusY):
            reticleClearTask?.cancel()
            toastDismissTask?.cancel()
            telemetryMode = .awaitingUserInput
            toastPhase = .awaitingConfirmation
            toastTitle = "💬 Waiting for Chat Input"
            toastSubtitle = prompt
            if let fx = focusX, let fy = focusY {
                activeReticle = AgenticTargetReticle(
                    x: fx,
                    y: fy,
                    kind: .tap,
                    label: prompt,
                    telemetryMode: .awaitingUserInput
                )
            } else {
                activeReticle = AgenticTargetReticle(
                    x: 0,
                    y: 0,
                    kind: .tap,
                    label: prompt,
                    telemetryMode: .awaitingUserInput,
                    isCenteredIndicator: true
                )
            }

        case .awaitingBiometrics(let reason, let activePackage):
            reticleClearTask?.cancel()
            toastDismissTask?.cancel()
            telemetryMode = .awaitingBiometrics
            toastPhase = .awaitingBiometrics
            toastTitle = "🔒 Biometrics / PIN Required"
            toastSubtitle = activePackage.isEmpty ? reason : "\(activePackage) · Unlock on phone"
            prefersTopToastDock = false
            activeReticle = AgenticTargetReticle(
                x: 0,
                y: 0,
                kind: .tap,
                label: reason,
                telemetryMode: .awaitingBiometrics,
                isCenteredIndicator: true
            )

        case .biometricsCleared:
            reticleClearTask?.cancel()
            toastDismissTask?.cancel()
            telemetryMode = .autonomous
            if toastPhase == .awaitingBiometrics {
                activeReticle = nil
                toastTitle = nil
                toastSubtitle = nil
                toastPhase = .idle
            }

        case .recoveryAction(_, let detail):
            if toastPhase == .executing {
                toastSubtitle = "Auto-recovery: \(detail)"
            }

        case .completed(let report):
            lastPathComputedStepCount = nil
            telemetryMode = .autonomous
            let unit = report.steps.count == 1 ? "step" : "steps"
            toastTitle = "🤖 Arrived in \(report.totalElapsedMs)ms (\(report.steps.count) \(unit))"
            toastSubtitle = report.recoveredSteps.isEmpty ? nil : "Recovered: \(report.recoveredSteps.count)"
            toastPhase = .completed
            prefersTopToastDock = false
            scheduleReticleClear(afterSeconds: 0.16)
            scheduleToastDismiss(afterSeconds: 2.8)

        case .failed(let message):
            lastPathComputedStepCount = nil
            telemetryMode = .autonomous
            toastTitle = "🤖 Path Execution Stopped"
            toastSubtitle = message
            toastPhase = .failed
            prefersTopToastDock = false
            scheduleReticleClear(afterSeconds: 0.25)
            scheduleToastDismiss(afterSeconds: 3.5)
        }
    }

    public func handleSecureScreen(_ payload: WireSecureScreenPayload) {
        if payload.active {
            handle(event: .awaitingBiometrics(reason: payload.reason, activePackage: payload.activePackage))
        } else {
            handle(event: .biometricsCleared)
        }
    }

    public func clear() {
        reticleClearTask?.cancel()
        toastDismissTask?.cancel()
        activeReticle = nil
        toastTitle = nil
        toastSubtitle = nil
        toastPhase = .idle
        telemetryMode = .autonomous
        prefersTopToastDock = false
        lastPathComputedStepCount = nil
    }

    public func updateToastDocking(deviceHeight: Int, inputHeight: Int?) {
        guard (toastPhase == .executing || toastPhase == .awaitingConfirmation),
              let reticle = activeReticle,
              !reticle.isCenteredIndicator else {
            prefersTopToastDock = false
            return
        }
        let refHeight = CGFloat(max(1, inputHeight ?? deviceHeight))
        let endNY = CGFloat(reticle.y) / refHeight
        let startNY = reticle.startY.map { CGFloat($0) / refHeight } ?? endNY
        let shouldDockTop = max(endNY, startNY) >= 0.70
        if prefersTopToastDock != shouldDockTop {
            prefersTopToastDock = shouldDockTop
        }
    }

    private func showReticle(_ reticle: AgenticTargetReticle) {
        reticleClearTask?.cancel()
        activeReticle = reticle
        let duration: Double = (reticle.kind == .swipe) ? 0.48 : 0.30
        scheduleReticleClear(afterSeconds: duration)
    }

    private func scheduleReticleClear(afterSeconds seconds: Double) {
        reticleClearTask?.cancel()
        reticleClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activeReticle = nil
        }
    }

    private func scheduleToastDismiss(afterSeconds seconds: Double) {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toastTitle = nil
            self?.toastSubtitle = nil
            self?.toastPhase = .idle
        }
    }
}

// MARK: - 120Hz CAShapeLayer Crosshair Overlay

public struct AgenticCrosshairOverlayView: NSViewRepresentable {
    public let reticle: AgenticTargetReticle?
    public let deviceWidth: Int
    public let deviceHeight: Int
    public let inputWidth: Int?
    public let inputHeight: Int?

    public init(
        reticle: AgenticTargetReticle?,
        deviceWidth: Int,
        deviceHeight: Int,
        inputWidth: Int? = nil,
        inputHeight: Int? = nil
    ) {
        self.reticle = reticle
        self.deviceWidth = deviceWidth
        self.deviceHeight = deviceHeight
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
    }

    public func makeNSView(context: Context) -> AgenticCrosshairNSView {
        let view = AgenticCrosshairNSView()
        view.update(
            reticle: reticle,
            deviceWidth: deviceWidth,
            deviceHeight: deviceHeight,
            inputWidth: inputWidth,
            inputHeight: inputHeight
        )
        return view
    }

    public func updateNSView(_ nsView: AgenticCrosshairNSView, context: Context) {
        nsView.update(
            reticle: reticle,
            deviceWidth: deviceWidth,
            deviceHeight: deviceHeight,
            inputWidth: inputWidth,
            inputHeight: inputHeight
        )
    }
}

public final class AgenticCrosshairNSView: NSView {
    override public var isFlipped: Bool { true }

    private var currentReticle: AgenticTargetReticle?
    private var currentReticleId: UUID?
    private var activeTelemetryMode: AgenticHUDTelemetryMode = .autonomous
    private var deviceWidth: Int = 1080
    private var deviceHeight: Int = 2400
    private var inputWidth: Int?
    private var inputHeight: Int?

    private let reticleContainerLayer = CALayer()
    private let pulseHaloLayer = CAShapeLayer()
    private let innerRingLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let centerDotLayer = CAShapeLayer()
    private let swipeStartDotLayer = CAShapeLayer()
    private let swipeLineLayer = CAShapeLayer()
    private let swipeArrowLayer = CAShapeLayer()

    public var isShowingTapReticleForTesting: Bool {
        !reticleContainerLayer.isHidden
    }

    public var isShowingSwipeVectorForTesting: Bool {
        !swipeLineLayer.isHidden && !swipeArrowLayer.isHidden && !swipeStartDotLayer.isHidden
    }

    public var currentTelemetryModeForTesting: AgenticHUDTelemetryMode {
        activeTelemetryMode
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    /// Never intercept mouse/trackpad interaction meant for `ScrcpyDisplayNSView`.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        let red = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0).cgColor
        let softRedFill = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 0.16).cgColor
        let skyCyan = NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1.0).cgColor
        let skyCyanFill = NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.22).cgColor

        swipeLineLayer.fillColor = nil
        swipeLineLayer.strokeColor = NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.92).cgColor
        swipeLineLayer.lineWidth = 3.0
        swipeLineLayer.lineCap = .round
        swipeLineLayer.shadowColor = skyCyan
        swipeLineLayer.shadowRadius = 5.0
        swipeLineLayer.shadowOpacity = 0.85
        swipeLineLayer.shadowOffset = .zero
        swipeLineLayer.isHidden = true
        layer?.addSublayer(swipeLineLayer)

        swipeStartDotLayer.fillColor = skyCyanFill
        swipeStartDotLayer.strokeColor = skyCyan
        swipeStartDotLayer.lineWidth = 2.0
        swipeStartDotLayer.shadowColor = skyCyan
        swipeStartDotLayer.shadowRadius = 4.0
        swipeStartDotLayer.shadowOpacity = 0.80
        swipeStartDotLayer.shadowOffset = .zero
        swipeStartDotLayer.isHidden = true
        layer?.addSublayer(swipeStartDotLayer)

        swipeArrowLayer.fillColor = nil
        swipeArrowLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        swipeArrowLayer.lineWidth = 2.8
        swipeArrowLayer.lineCap = .round
        swipeArrowLayer.lineJoin = .round
        swipeArrowLayer.shadowColor = skyCyan
        swipeArrowLayer.shadowRadius = 5.0
        swipeArrowLayer.shadowOpacity = 0.95
        swipeArrowLayer.shadowOffset = .zero
        swipeArrowLayer.isHidden = true
        layer?.addSublayer(swipeArrowLayer)

        reticleContainerLayer.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        reticleContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        reticleContainerLayer.isHidden = true

        let center = CGPoint(x: 28, y: 28)

        // 1. Expanding outer pulse halo
        let haloRadius: CGFloat = 18
        let haloPath = CGPath(
            ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2),
            transform: nil
        )
        pulseHaloLayer.frame = reticleContainerLayer.bounds
        pulseHaloLayer.path = haloPath
        pulseHaloLayer.fillColor = softRedFill
        pulseHaloLayer.strokeColor = red
        pulseHaloLayer.lineWidth = 2.0

        // 2. Crisp pulsing inner circle
        let ringRadius: CGFloat = 13
        let ringPath = CGPath(
            ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2),
            transform: nil
        )
        innerRingLayer.frame = reticleContainerLayer.bounds
        innerRingLayer.path = ringPath
        innerRingLayer.fillColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 0.10).cgColor
        innerRingLayer.strokeColor = red
        innerRingLayer.lineWidth = 2.2
        innerRingLayer.shadowColor = red
        innerRingLayer.shadowRadius = 6
        innerRingLayer.shadowOpacity = 0.9
        innerRingLayer.shadowOffset = .zero

        // 3. Cardinal crosshair ticks
        let ticksPath = CGMutablePath()
        let innerGap: CGFloat = 6.5
        let outerTip: CGFloat = 21.0
        ticksPath.move(to: CGPoint(x: center.x - outerTip, y: center.y))
        ticksPath.addLine(to: CGPoint(x: center.x - innerGap, y: center.y))
        ticksPath.move(to: CGPoint(x: center.x + innerGap, y: center.y))
        ticksPath.addLine(to: CGPoint(x: center.x + outerTip, y: center.y))
        ticksPath.move(to: CGPoint(x: center.x, y: center.y - outerTip))
        ticksPath.addLine(to: CGPoint(x: center.x, y: center.y - innerGap))
        ticksPath.move(to: CGPoint(x: center.x, y: center.y + innerGap))
        ticksPath.addLine(to: CGPoint(x: center.x, y: center.y + outerTip))

        crosshairLayer.frame = reticleContainerLayer.bounds
        crosshairLayer.path = ticksPath
        crosshairLayer.fillColor = nil
        crosshairLayer.strokeColor = red
        crosshairLayer.lineWidth = 2.0
        crosshairLayer.lineCap = .round
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowRadius = 2.5
        crosshairLayer.shadowOpacity = 0.75
        crosshairLayer.shadowOffset = .zero

        // 4. Center dot
        let dotRadius: CGFloat = 3.0
        centerDotLayer.frame = reticleContainerLayer.bounds
        centerDotLayer.path = CGPath(
            ellipseIn: CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2),
            transform: nil
        )
        centerDotLayer.fillColor = red
        centerDotLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        centerDotLayer.lineWidth = 0.9

        reticleContainerLayer.addSublayer(pulseHaloLayer)
        reticleContainerLayer.addSublayer(innerRingLayer)
        reticleContainerLayer.addSublayer(crosshairLayer)
        reticleContainerLayer.addSublayer(centerDotLayer)
        layer?.addSublayer(reticleContainerLayer)
    }

    public func update(
        reticle: AgenticTargetReticle?,
        deviceWidth: Int,
        deviceHeight: Int,
        inputWidth: Int? = nil,
        inputHeight: Int? = nil
    ) {
        self.deviceWidth = max(1, deviceWidth)
        self.deviceHeight = max(1, deviceHeight)
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.currentReticle = reticle

        guard let reticle else {
            currentReticleId = nil
            hideReticle()
            return
        }

        let isNewReticle = (reticle.id != currentReticleId) || (reticle.telemetryMode != activeTelemetryMode)
        currentReticleId = reticle.id
        activeTelemetryMode = reticle.telemetryMode
        positionLayers(for: reticle)

        if isNewReticle {
            start120HzPulseAnimations(isSwipe: isSwipeVector(reticle), mode: reticle.telemetryMode)
        }
    }

    private func isSwipeVector(_ reticle: AgenticTargetReticle) -> Bool {
        guard reticle.kind == .swipe,
              let sx = reticle.startX, let sy = reticle.startY else {
            return false
        }
        return sx != reticle.x || sy != reticle.y
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContentsScale()
    }

    override public func layout() {
        super.layout()
        applyContentsScale()
        if let reticle = currentReticle {
            positionLayers(for: reticle)
        }
    }

    private func applyContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        for sub in [
            reticleContainerLayer, pulseHaloLayer, innerRingLayer, crosshairLayer, centerDotLayer,
            swipeStartDotLayer, swipeLineLayer, swipeArrowLayer
        ] {
            sub.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func applyTelemetryPalette(_ mode: AgenticHUDTelemetryMode) {
        let primaryColor: NSColor
        let haloFill: NSColor
        let innerFill: NSColor

        switch mode {
        case .autonomous:
            primaryColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
            haloFill = primaryColor.withAlphaComponent(0.16)
            innerFill = primaryColor.withAlphaComponent(0.10)
        case .awaitingUserInput:
            primaryColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1.0)
            haloFill = primaryColor.withAlphaComponent(0.20)
            innerFill = primaryColor.withAlphaComponent(0.14)
        case .awaitingBiometrics:
            primaryColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
            haloFill = primaryColor.withAlphaComponent(0.20)
            innerFill = primaryColor.withAlphaComponent(0.14)
        }

        let cgPrimary = primaryColor.cgColor
        pulseHaloLayer.fillColor = haloFill.cgColor
        pulseHaloLayer.strokeColor = cgPrimary
        innerRingLayer.fillColor = innerFill.cgColor
        innerRingLayer.strokeColor = cgPrimary
        innerRingLayer.shadowColor = cgPrimary
        crosshairLayer.strokeColor = cgPrimary
        centerDotLayer.fillColor = cgPrimary
    }

    private func positionLayers(for reticle: AgenticTargetReticle) {
        let targetPt: CGPoint
        if reticle.isCenteredIndicator {
            let vRect = AgenticHUDCoordinateMapper.videoRect(
                in: bounds.size,
                deviceWidth: deviceWidth,
                deviceHeight: deviceHeight
            )
            targetPt = CGPoint(x: vRect.midX, y: vRect.midY)
        } else {
            targetPt = AgenticHUDCoordinateMapper.viewPoint(
                deviceX: reticle.x,
                deviceY: reticle.y,
                in: bounds.size,
                videoWidth: deviceWidth,
                videoHeight: deviceHeight,
                inputWidth: inputWidth,
                inputHeight: inputHeight
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyTelemetryPalette(reticle.telemetryMode)

        if isSwipeVector(reticle), let sx = reticle.startX, let sy = reticle.startY {
            // Render a directional swipe trajectory + chevron instead of a tap crosshair at endPt
            reticleContainerLayer.isHidden = true

            let startPt = AgenticHUDCoordinateMapper.viewPoint(
                deviceX: sx,
                deviceY: sy,
                in: bounds.size,
                videoWidth: deviceWidth,
                videoHeight: deviceHeight,
                inputWidth: inputWidth,
                inputHeight: inputHeight
            )

            let originR: CGFloat = 6.5
            swipeStartDotLayer.frame = bounds
            swipeStartDotLayer.path = CGPath(
                ellipseIn: CGRect(x: startPt.x - originR, y: startPt.y - originR, width: originR * 2, height: originR * 2),
                transform: nil
            )
            swipeStartDotLayer.isHidden = false

            let linePath = CGMutablePath()
            linePath.move(to: startPt)
            linePath.addLine(to: targetPt)
            swipeLineLayer.frame = bounds
            swipeLineLayer.path = linePath
            swipeLineLayer.strokeEnd = 1.0
            swipeLineLayer.isHidden = false

            let angle = atan2(targetPt.y - startPt.y, targetPt.x - startPt.x)
            let wingLength: CGFloat = 11.0
            let spread: CGFloat = .pi / 5.2
            let wing1 = CGPoint(
                x: targetPt.x - wingLength * cos(angle - spread),
                y: targetPt.y - wingLength * sin(angle - spread)
            )
            let wing2 = CGPoint(
                x: targetPt.x - wingLength * cos(angle + spread),
                y: targetPt.y - wingLength * sin(angle + spread)
            )
            let chevronPath = CGMutablePath()
            chevronPath.move(to: wing1)
            chevronPath.addLine(to: targetPt)
            chevronPath.addLine(to: wing2)
            swipeArrowLayer.frame = bounds
            swipeArrowLayer.path = chevronPath
            swipeArrowLayer.isHidden = false
        } else {
            reticleContainerLayer.position = targetPt
            reticleContainerLayer.isHidden = false
            reticleContainerLayer.opacity = 1.0

            swipeStartDotLayer.isHidden = true
            swipeStartDotLayer.path = nil
            swipeLineLayer.isHidden = true
            swipeLineLayer.path = nil
            swipeArrowLayer.isHidden = true
            swipeArrowLayer.path = nil
        }
        CATransaction.commit()
    }

    private func hideReticle() {
        pulseHaloLayer.removeAllAnimations()
        innerRingLayer.removeAllAnimations()
        reticleContainerLayer.removeAllAnimations()
        swipeLineLayer.removeAllAnimations()
        swipeArrowLayer.removeAllAnimations()
        swipeStartDotLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reticleContainerLayer.isHidden = true
        swipeStartDotLayer.isHidden = true
        swipeStartDotLayer.path = nil
        swipeLineLayer.isHidden = true
        swipeLineLayer.path = nil
        swipeArrowLayer.isHidden = true
        swipeArrowLayer.path = nil
        CATransaction.commit()
    }

    private func start120HzPulseAnimations(isSwipe: Bool, mode: AgenticHUDTelemetryMode) {
        pulseHaloLayer.removeAllAnimations()
        innerRingLayer.removeAllAnimations()
        reticleContainerLayer.removeAllAnimations()
        swipeLineLayer.removeAllAnimations()
        swipeArrowLayer.removeAllAnimations()
        swipeStartDotLayer.removeAllAnimations()

        let proMotionRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

        if isSwipe {
            let strokeAnim = CABasicAnimation(keyPath: "strokeEnd")
            strokeAnim.fromValue = 0.0
            strokeAnim.toValue = 1.0
            strokeAnim.duration = 0.24
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strokeAnim.preferredFrameRateRange = proMotionRange
            swipeLineLayer.add(strokeAnim, forKey: "agenticSwipeStroke")

            let arrowFade = CABasicAnimation(keyPath: "opacity")
            arrowFade.fromValue = 0.0
            arrowFade.toValue = 1.0
            arrowFade.duration = 0.18
            arrowFade.beginTime = CACurrentMediaTime() + 0.10
            arrowFade.fillMode = .backwards
            arrowFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arrowFade.preferredFrameRateRange = proMotionRange
            swipeArrowLayer.add(arrowFade, forKey: "agenticSwipeArrowFade")
            return
        }

        // Outer ripple ring expansion (120Hz) — repeat continuously while awaiting chat/biometrics
        let haloScale = CABasicAnimation(keyPath: "transform.scale")
        haloScale.fromValue = 0.55
        haloScale.toValue = 2.10

        let haloOpacity = CABasicAnimation(keyPath: "opacity")
        haloOpacity.fromValue = 0.95
        haloOpacity.toValue = 0.0

        let haloGroup = CAAnimationGroup()
        haloGroup.animations = [haloScale, haloOpacity]
        haloGroup.duration = mode == .autonomous ? 0.62 : 1.05
        haloGroup.repeatCount = mode == .autonomous ? 2 : .infinity
        haloGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        haloGroup.isRemovedOnCompletion = false
        haloGroup.fillMode = .forwards
        haloGroup.preferredFrameRateRange = proMotionRange
        pulseHaloLayer.add(haloGroup, forKey: "agenticHaloPulse")

        // Inner reticle breathing pulse (120Hz)
        let ringPulse = CABasicAnimation(keyPath: "transform.scale")
        ringPulse.fromValue = 0.90
        ringPulse.toValue = 1.14
        ringPulse.duration = 0.34
        ringPulse.autoreverses = true
        ringPulse.repeatCount = .infinity
        ringPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringPulse.preferredFrameRateRange = proMotionRange
        innerRingLayer.add(ringPulse, forKey: "agenticRingPulse")

        // Subtle snap-in scale on the container (120Hz)
        let popIn = CASpringAnimation(keyPath: "transform.scale")
        popIn.fromValue = 1.35
        popIn.toValue = 1.0
        popIn.damping = 14
        popIn.stiffness = 280
        popIn.mass = 0.8
        popIn.duration = popIn.settlingDuration
        popIn.preferredFrameRateRange = proMotionRange
        reticleContainerLayer.add(popIn, forKey: "agenticReticlePop")
    }
}

// MARK: - Floating macOS Dark-Mode Status Toast

public struct AgenticStatusToastView: View {
    public let title: String
    public let subtitle: String?
    public let phase: AgenticToastPhase

    public init(title: String, subtitle: String? = nil, phase: AgenticToastPhase) {
        self.title = title
        self.subtitle = subtitle
        self.phase = phase
    }

    private var accentColor: Color {
        switch phase {
        case .executing: return Color(nsColor: .systemRed)
        case .awaitingConfirmation: return Color(nsColor: .systemYellow)
        case .awaitingBiometrics: return Color(nsColor: .systemBlue)
        case .completed: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemOrange)
        case .idle: return .secondary
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)
                .shadow(color: accentColor.opacity(0.8), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .contentTransition(.identity)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.identity)
                }
            }
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.68))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            accentColor.opacity(0.55),
                            Color.white.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 5)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 270, alignment: .trailing)
    }
}

// MARK: - Unified Agentic HUD Overlay

public struct AgenticHUDLayer: View {
    @ObservedObject public var viewModel: AgenticHUDViewModel
    public let deviceWidth: Int
    public let deviceHeight: Int
    public let inputWidth: Int?
    public let inputHeight: Int?
    public var bottomInset: CGFloat = 28

    public init(
        viewModel: AgenticHUDViewModel,
        deviceWidth: Int,
        deviceHeight: Int,
        inputWidth: Int? = nil,
        inputHeight: Int? = nil,
        bottomInset: CGFloat = 28
    ) {
        self.viewModel = viewModel
        self.deviceWidth = deviceWidth
        self.deviceHeight = deviceHeight
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.bottomInset = bottomInset
    }

    private var shouldDockToastAtTop: Bool {
        (viewModel.toastPhase == .executing || viewModel.toastPhase == .awaitingConfirmation) && viewModel.prefersTopToastDock
    }

    public var body: some View {
        ZStack(alignment: shouldDockToastAtTop ? .topTrailing : .bottomTrailing) {
            AgenticCrosshairOverlayView(
                reticle: viewModel.activeReticle,
                deviceWidth: deviceWidth,
                deviceHeight: deviceHeight,
                inputWidth: inputWidth,
                inputHeight: inputHeight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let title = viewModel.toastTitle, viewModel.toastPhase != .idle {
                AgenticStatusToastView(
                    title: title,
                    subtitle: viewModel.toastSubtitle,
                    phase: viewModel.toastPhase
                )
                .padding(.trailing, 10)
                .padding(.top, shouldDockToastAtTop ? 84 : 0)
                .padding(.bottom, shouldDockToastAtTop ? 0 : bottomInset)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.activeReticle) { _, _ in
            viewModel.updateToastDocking(deviceHeight: deviceHeight, inputHeight: inputHeight)
        }
        .animation(AndMotion.hudSpring, value: viewModel.toastPhase != .idle)
        .allowsHitTesting(false)
    }
}
