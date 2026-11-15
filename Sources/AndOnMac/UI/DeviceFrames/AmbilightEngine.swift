import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

public struct AmbilightRGB: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double

    public static let neutralDark = AmbilightRGB(r: 0.08, g: 0.14, b: 0.24)

    public init(r: Double, g: Double, b: Double) {
        self.r = max(0.0, min(1.0, r))
        self.g = max(0.0, min(1.0, g))
        self.b = max(0.0, min(1.0, b))
    }

    public var color: Color {
        Color(red: r, green: g, blue: b)
    }

    /// Enhances chrominance slightly so muted UI borders still produce a subtle Continuity-style halo.
    public func enhancedForGlow(vibranceBoost: Double = 1.28) -> AmbilightRGB {
        let mean = (r + g + b) / 3.0
        let nr = mean + (r - mean) * vibranceBoost
        let ng = mean + (g - mean) * vibranceBoost
        let nb = mean + (b - mean) * vibranceBoost
        // Clamp brightness so very bright white apps yield a tasteful ambient halo instead of harsh glare
        let luma = 0.2126 * nr + 0.7152 * ng + 0.0722 * nb
        let scale = luma > 0.68 ? (0.68 / max(0.001, luma)) : 1.0
        return AmbilightRGB(r: nr * scale, g: ng * scale, b: nb * scale)
    }
}

public struct AmbilightPalette: Equatable, Sendable {
    public let top: AmbilightRGB
    public let bottom: AmbilightRGB
    public let leading: AmbilightRGB
    public let trailing: AmbilightRGB

    public static let neutral = AmbilightPalette(
        top: .neutralDark,
        bottom: AmbilightRGB(r: 0.04, g: 0.06, b: 0.11),
        leading: .neutralDark,
        trailing: AmbilightRGB(r: 0.05, g: 0.10, b: 0.18)
    )

    public init(top: AmbilightRGB, bottom: AmbilightRGB, leading: AmbilightRGB, trailing: AmbilightRGB) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }
}

/// Real-time GPU-accelerated CoreImage edge sampler casting an adaptive Ambilight shadow around the device frame.
@MainActor
public final class AmbilightEngine: ObservableObject {
    public static let shared = AmbilightEngine()

    @Published public private(set) var palette: AmbilightPalette = .neutral

    private nonisolated let sampler = AmbilightSampler.shared

    private init() {
        AmbilightSampler.shared.onPaletteUpdated = { [weak self] newPalette in
            Task { @MainActor [weak self] in
                guard let self, self.sampler.isEnabled else { return }
                if self.palette != newPalette {
                    self.palette = newPalette
                }
            }
        }
    }

    public func setSamplingEnabled(_ enabled: Bool) {
        sampler.setEnabled(enabled)
        if !enabled {
            palette = .neutral
        }
    }

    /// Thread-safe entry point invoked from `VTDecompressionSession` decode callbacks without MainActor hops.
    /// Drops intermediate stale frames rather than queueing to protect zero-latency display smoothness.
    nonisolated public static func submitPixelBuffer(_ pixelBuffer: CVPixelBuffer, enabled: Bool? = nil) {
        if let enabled, !enabled { return }
        let sampler = AmbilightSampler.shared
        guard sampler.isEnabled || enabled == true else { return }
        sampler.enqueue(pixelBuffer: pixelBuffer)
    }

    public func reset() {
        sampler.reset()
        palette = .neutral
    }

    /// Synchronously extracts a 4-edge `AmbilightPalette` using `CIAreaAverage`.
    nonisolated public static func extractPalette(from image: CIImage, context: CIContext) -> AmbilightPalette {
        let extent = image.extent
        guard extent.width >= 4, extent.height >= 4 else { return .neutral }

        let stripW = max(2.0, extent.width * 0.14)
        let stripH = max(2.0, extent.height * 0.14)

        // CoreImage origin is bottom-left: maxY is visual top, minY is visual bottom.
        let topRect = CGRect(x: extent.minX, y: extent.maxY - stripH, width: extent.width, height: stripH)
        let bottomRect = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: stripH)
        let leadingRect = CGRect(x: extent.minX, y: extent.minY, width: stripW, height: extent.height)
        let trailingRect = CGRect(x: extent.maxX - stripW, y: extent.minY, width: stripW, height: extent.height)

        let top = sampleAverageRGB(image: image, region: topRect, context: context).enhancedForGlow()
        let bottom = sampleAverageRGB(image: image, region: bottomRect, context: context).enhancedForGlow()
        let leading = sampleAverageRGB(image: image, region: leadingRect, context: context).enhancedForGlow()
        let trailing = sampleAverageRGB(image: image, region: trailingRect, context: context).enhancedForGlow()

        return AmbilightPalette(top: top, bottom: bottom, leading: leading, trailing: trailing)
    }

    nonisolated private static func sampleAverageRGB(image: CIImage, region: CGRect, context: CIContext) -> AmbilightRGB {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = region

        guard let output = filter.outputImage else { return .neutralDark }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: bounds,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return AmbilightRGB(
            r: Double(bitmap[0]) / 255.0,
            g: Double(bitmap[1]) / 255.0,
            b: Double(bitmap[2]) / 255.0
        )
    }
}

/// Lock-protected single-slot coalescing worker so `CVPixelBuffer`s are sampled smoothly (~30 Hz) without backpressure.
private final class AmbilightSampler: @unchecked Sendable {
    static let shared = AmbilightSampler()

    private let lock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.andonmac.ambilight", qos: .userInteractive)
    private var _isEnabled = false
    private var pendingBuffer: CVPixelBuffer?
    private var isScheduled = false
    private var lastSampleUptime: TimeInterval = 0
    private let minimumInterval: TimeInterval = 1.0 / 30.0
    var onPaletteUpdated: (@Sendable (AmbilightPalette) -> Void)?
    private lazy var ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        _isEnabled = enabled
        if !enabled {
            pendingBuffer = nil
            isScheduled = false
            lastSampleUptime = 0
        }
        lock.unlock()
    }

    func enqueue(pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pendingBuffer = pixelBuffer
        let elapsed = now - lastSampleUptime
        if isScheduled || elapsed < minimumInterval {
            lock.unlock()
            return
        }
        isScheduled = true
        lastSampleUptime = now
        lock.unlock()

        processingQueue.async { [weak self] in
            self?.drainLatest()
        }
    }

    func reset() {
        lock.lock()
        pendingBuffer = nil
        isScheduled = false
        lastSampleUptime = 0
        lock.unlock()
    }

    private func drainLatest() {
        lock.lock()
        let buffer = pendingBuffer
        let callback = onPaletteUpdated
        pendingBuffer = nil
        isScheduled = false
        lock.unlock()

        guard let buffer else { return }
        let extracted: AmbilightPalette = autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return AmbilightEngine.extractPalette(from: ciImage, context: ciContext)
        }
        callback?(extracted)
    }
}

/// Soft ambient halo rendered behind the phone chassis based on edge colors extracted from the stream.
/// Isolates `@ObservedObject` subscription to this leaf view so parent views and `ScrcpyVideoView` never re-render per frame.
public struct AmbilightGlowView: View {
    @ObservedObject private var engine = AmbilightEngine.shared
    public let cornerRadius: CGFloat
    public let isEnabled: Bool

    public init(cornerRadius: CGFloat, isEnabled: Bool, palette: AmbilightPalette? = nil) {
        self.cornerRadius = cornerRadius
        self.isEnabled = isEnabled
        self._explicitPalette = palette
    }

    private let _explicitPalette: AmbilightPalette?

    public var body: some View {
        let activePalette = _explicitPalette ?? engine.palette
        ZStack {
            if isEnabled {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                activePalette.leading.color.opacity(0.52),
                                activePalette.top.color.opacity(0.45),
                                activePalette.trailing.color.opacity(0.52),
                                activePalette.bottom.color.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blur(radius: 26)
                    .padding(-6)
                    .animation(.easeOut(duration: 0.25), value: activePalette)
            }
        }
        .allowsHitTesting(false)
    }
}
