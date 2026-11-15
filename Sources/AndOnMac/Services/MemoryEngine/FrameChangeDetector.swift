import Foundation
import CoreGraphics

/// Lightweight perceptual frame-change detector using 16x16 grayscale downsampling and FNV-1a hashing.
/// Prevents redundant Vision OCR work when the mirrored Android screen is static.
public final class FrameChangeDetector: @unchecked Sendable {
    private static let sampleSize = 16
    private let lock = NSLock()
    private var previousLuma: [UInt8]?
    private var previousHash: UInt64 = 0

    public init() {}

    /// Resets stored frame state (e.g., when mirroring restarts).
    public func reset() {
        lock.lock()
        previousLuma = nil
        previousHash = 0
        lock.unlock()
    }

    /// Returns `true` if `image` differs meaningfully from the previously evaluated frame.
    public func hasFrameChanged(_ image: CGImage, minMeanDelta: Double = 0.015) -> Bool {
        let current = autoreleasepool {
            Self.extractLumaGrid(from: image)
        }
        guard let current else { return true }
        let currentHash = Self.fnv1a64(current)

        lock.lock()
        defer { lock.unlock() }

        guard let prev = previousLuma else {
            previousLuma = current
            previousHash = currentHash
            return true
        }

        if currentHash == previousHash {
            return false
        }

        var totalDiff: Int = 0
        for i in 0..<current.count {
            totalDiff += abs(Int(current[i]) - Int(prev[i]))
        }
        let meanNormalizedDelta = Double(totalDiff) / (Double(current.count) * 255.0)
        if meanNormalizedDelta < minMeanDelta {
            return false
        }

        previousLuma = current
        previousHash = currentHash
        return true
    }

    /// Computes a 64-bit FNV-1a hash of the downsampled luma grid.
    public static func frameHash(for image: CGImage) -> UInt64 {
        guard let luma = autoreleasepool(invoking: { extractLumaGrid(from: image) }) else {
            return 0
        }
        return fnv1a64(luma)
    }

    private static func extractLumaGrid(from image: CGImage) -> [UInt8]? {
        let size = sampleSize
        var buffer = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &buffer,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return hash
    }
}
