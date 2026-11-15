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

public struct AgenticTargetReticle: Equatable, Sendable {
    public let id: UUID
    public let x: Int
    public let y: Int
    public let startX: Int?
    public let startY: Int?
    public let kind: AttributedUIAction.Kind
    public let label: String

    public init(
        id: UUID = UUID(),
        x: Int,
        y: Int,
        startX: Int? = nil,
        startY: Int? = nil,
        kind: AttributedUIAction.Kind,
        label: String = ""
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.startX = startX
        self.startY = startY
        self.kind = kind
        self.label = label
    }
}

public enum AgenticToastPhase: Equatable, Sendable {
    case idle
    case executing
    case completed
    case failed
}

@MainActor
public final class AgenticHUDViewModel: ObservableObject {
    @Published public private(set) var toastTitle: String?
    @Published public private(set) var toastSubtitle: String?
    @Published public private(set) var toastPhase: AgenticToastPhase = .idle
    @Published public private(set) var activeReticle: AgenticTargetReticle?

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
            let unit = totalSteps == 1 ? "step" : "steps"
            toastTitle = "🤖 A* Path Computed: \(totalSteps) \(unit). Executing..."
            toastSubtitle = targetHint?.isEmpty == false ? "Target: \(targetHint!)" : nil
            toastPhase = .executing

        case .executionStarted(let totalSteps):
            toastDismissTask?.cancel()
            if toastPhase != .executing || lastPathComputedStepCount != totalSteps {
                let unit = totalSteps == 1 ? "step" : "steps"
                toastTitle = "🤖 A* Path Computed: \(totalSteps) \(unit). Executing..."
                toastSubtitle = nil
            }
            toastPhase = .executing

        case .willExecuteAction(let stepIndex, let totalSteps, let action):
            toastDismissTask?.cancel()
            let unit = totalSteps == 1 ? "step" : "steps"
            toastTitle = "🤖 A* Path Computed: \(totalSteps) \(unit). Step \(stepIndex + 1)/\(totalSteps)..."
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
                    label: label
                ))
            }

        case .stepSettled:
            break

        case .completed(let report):
            lastPathComputedStepCount = nil
            let unit = report.steps.count == 1 ? "step" : "steps"
            toastTitle = "🤖 Arrived in \(report.totalElapsedMs)ms (\(report.steps.count) \(unit))"
            toastSubtitle = nil
            toastPhase = .completed
            scheduleReticleClear(afterSeconds: 0.45)
            scheduleToastDismiss(afterSeconds: 2.8)

        case .failed(let message):
            lastPathComputedStepCount = nil
            toastTitle = "🤖 Path Execution Stopped"
            toastSubtitle = message
            toastPhase = .failed
            scheduleReticleClear(afterSeconds: 0.5)
            scheduleToastDismiss(afterSeconds: 3.5)
        }
    }

    public func clear() {
        reticleClearTask?.cancel()
        toastDismissTask?.cancel()
        activeReticle = nil
        toastTitle = nil
        toastSubtitle = nil
        toastPhase = .idle
        lastPathComputedStepCount = nil
    }

    private func showReticle(_ reticle: AgenticTargetReticle) {
        reticleClearTask?.cancel()
        activeReticle = reticle
        scheduleReticleClear(afterSeconds: 0.90)
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
    private var deviceWidth: Int = 1080
    private var deviceHeight: Int = 2400
    private var inputWidth: Int?
    private var inputHeight: Int?

    private let reticleContainerLayer = CALayer()
    private let pulseHaloLayer = CAShapeLayer()
    private let innerRingLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let centerDotLayer = CAShapeLayer()
    private let swipeLineLayer = CAShapeLayer()

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

        swipeLineLayer.fillColor = nil
        swipeLineLayer.strokeColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 0.72).cgColor
        swipeLineLayer.lineWidth = 2.0
        swipeLineLayer.lineDashPattern = [5, 4]
        swipeLineLayer.lineCap = .round
        swipeLineLayer.isHidden = true
        layer?.addSublayer(swipeLineLayer)

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

        let isNewReticle = (reticle.id != currentReticleId)
        currentReticleId = reticle.id
        positionLayers(for: reticle)

        if isNewReticle {
            start120HzPulseAnimations()
        }
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
        for sub in [reticleContainerLayer, pulseHaloLayer, innerRingLayer, crosshairLayer, centerDotLayer, swipeLineLayer] {
            sub.contentsScale = scale
        }
        CATransaction.commit()
    }

    private func positionLayers(for reticle: AgenticTargetReticle) {
        let targetPt = AgenticHUDCoordinateMapper.viewPoint(
            deviceX: reticle.x,
            deviceY: reticle.y,
            in: bounds.size,
            videoWidth: deviceWidth,
            videoHeight: deviceHeight,
            inputWidth: inputWidth,
            inputHeight: inputHeight
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reticleContainerLayer.position = targetPt
        reticleContainerLayer.isHidden = false
        reticleContainerLayer.opacity = 1.0

        if reticle.kind == .swipe,
           let sx = reticle.startX, let sy = reticle.startY,
           (sx != reticle.x || sy != reticle.y) {
            let startPt = AgenticHUDCoordinateMapper.viewPoint(
                deviceX: sx,
                deviceY: sy,
                in: bounds.size,
                videoWidth: deviceWidth,
                videoHeight: deviceHeight,
                inputWidth: inputWidth,
                inputHeight: inputHeight
            )
            let linePath = CGMutablePath()
            linePath.move(to: startPt)
            linePath.addLine(to: targetPt)
            swipeLineLayer.frame = bounds
            swipeLineLayer.path = linePath
            swipeLineLayer.isHidden = false
        } else {
            swipeLineLayer.isHidden = true
            swipeLineLayer.path = nil
        }
        CATransaction.commit()
    }

    private func hideReticle() {
        pulseHaloLayer.removeAllAnimations()
        innerRingLayer.removeAllAnimations()
        reticleContainerLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reticleContainerLayer.isHidden = true
        swipeLineLayer.isHidden = true
        swipeLineLayer.path = nil
        CATransaction.commit()
    }

    private func start120HzPulseAnimations() {
        pulseHaloLayer.removeAllAnimations()
        innerRingLayer.removeAllAnimations()
        reticleContainerLayer.removeAllAnimations()

        let proMotionRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

        // Outer ripple ring expansion (120Hz)
        let haloScale = CABasicAnimation(keyPath: "transform.scale")
        haloScale.fromValue = 0.55
        haloScale.toValue = 2.10

        let haloOpacity = CABasicAnimation(keyPath: "opacity")
        haloOpacity.fromValue = 0.95
        haloOpacity.toValue = 0.0

        let haloGroup = CAAnimationGroup()
        haloGroup.animations = [haloScale, haloOpacity]
        haloGroup.duration = 0.62
        haloGroup.repeatCount = 2
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

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(AndMotion.hudSpring, value: viewModel.toastPhase != .idle)
        .allowsHitTesting(false)
    }
}
