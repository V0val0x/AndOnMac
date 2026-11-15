import Foundation
import AppKit
import CoreGraphics

/// Background 10-second screen memory indexer with pixel-hash throttling, Apple Vision OCR, and 7-day retention.
public final class ScreenMemorySnapshotter: ObservableObject, @unchecked Sendable {
    public static let shared = ScreenMemorySnapshotter()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var indexedCount: Int = 0
    @Published public private(set) var storageBytes: Int64 = 0

    private let detector = FrameChangeDetector()
    private let database: ScreenMemoryDatabase
    private var loopTask: Task<Void, Never>?
    private var lastPruneDate: Date = .distantPast
    private var currentSerial: String?

    public init(database: ScreenMemoryDatabase = .shared) {
        self.database = database
        refreshStats()
    }

    public func start(serial: String) {
        guard ADBService.validateSerial(serial) else { return }
        stop()
        currentSerial = serial
        detector.reset()

        DispatchQueue.main.async {
            self.isRunning = true
        }

        loopTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = self.database.pruneRetention()
            self.lastPruneDate = Date()
            self.refreshStats()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await self.captureOnce(serial: serial)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentSerial = nil
        detector.reset()
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }

    public func refreshStats() {
        let s = database.stats()
        DispatchQueue.main.async {
            self.indexedCount = s.count
            self.storageBytes = s.totalBytes
        }
    }

    public func clearAllMemory() {
        database.clearAll()
        detector.reset()
        refreshStats()
    }

    /// Parses foreground Android package name from `adb shell dumpsys window` output.
    public static func parseForegroundPackage(from dumpsysOutput: String) -> String {
        // Matches lines like:
        // mCurrentFocus=Window{abc123 u0 com.whatsapp/com.whatsapp.HomeActivity}
        // mFocusedApp=ActivityRecord{abc123 u0 com.google.android.youtube/.HomeActivity t42}
        for line in dumpsysOutput.components(separatedBy: .newlines) {
            guard line.contains("mCurrentFocus") || line.contains("mFocusedApp") else { continue }
            guard let slashIndex = line.firstIndex(of: "/") else { continue }
            let prefix = line[..<slashIndex]
            if let token = prefix.split(whereSeparator: { $0 == " " || $0 == "{" }).last {
                let pkg = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                if pkg.contains("."), !pkg.contains("=") {
                    return pkg
                }
            }
        }
        return "unknown"
    }

    private func captureOnce(serial: String) async {
        guard let frame = ScrcpyClient.shared.latestFrameImage else { return }
        guard detector.hasFrameChanged(frame) else { return }

        let frameHash = FrameChangeDetector.frameHash(for: frame)

        // Run Apple Vision OCR on Neural Engine at utility QoS (autoreleasepool is inside VisionOCRService)
        let extractedText: String
        do {
            extractedText = try await VisionOCRService.shared.recognizeText(in: frame, qos: .utility)
        } catch {
            return
        }

        let cleanedText = extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }

        let packageName = await fetchForegroundPackage(serial: serial)
        let thumbFilename = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jpg"
        let thumbURL = database.thumbnailsDirectoryURL.appendingPathComponent(thumbFilename, isDirectory: false)

        let savedThumb = autoreleasepool { () -> Bool in
            Self.writeCompressedThumbnail(from: frame, to: thumbURL, maxWidth: 360, quality: 0.65)
        }
        guard savedThumb else { return }

        database.insertSnapshot(
            timestamp: Date(),
            appPackageName: packageName,
            extractedText: cleanedText,
            thumbnailFilename: thumbFilename,
            frameHash: frameHash
        )

        if Date().timeIntervalSince(lastPruneDate) > 3_600 {
            _ = database.pruneRetention()
            lastPruneDate = Date()
        }
        refreshStats()
    }

    private func fetchForegroundPackage(serial: String) async -> String {
        guard let output = try? await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "dumpsys", "window", "windows"],
            timeoutSeconds: 3.0
        ) else {
            return "unknown"
        }
        let parsed = Self.parseForegroundPackage(from: output)
        if parsed != "unknown" {
            return parsed
        }
        if let fallback = try? await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "dumpsys", "window"],
            timeoutSeconds: 3.0
        ) {
            return Self.parseForegroundPackage(from: fallback)
        }
        return "unknown"
    }

    private static func writeCompressedThumbnail(
        from image: CGImage,
        to url: URL,
        maxWidth: CGFloat,
        quality: CGFloat
    ) -> Bool {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else { return false }

        let scale = min(1.0, maxWidth / srcW)
        let dstW = max(1, Int((srcW * scale).rounded()))
        let dstH = max(1, Int((srcH * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let scaled = ctx.makeImage() else { return false }

        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return false
        }
        do {
            try jpeg.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
