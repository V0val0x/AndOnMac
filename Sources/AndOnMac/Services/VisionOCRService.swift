import Foundation
import Vision
import CoreGraphics
import AppKit

/// Located OCR text match with top-left normalized (`0...1`) center coordinates.
public struct VisionTextMatch: Sendable, Equatable {
    public let matchedText: String
    public let normalizedCenterX: Double
    public let normalizedCenterY: Double
}

/// Performs on-device Neural Engine / Apple Silicon text recognition using Apple Vision.
public final class VisionOCRService: @unchecked Sendable {
    public static let shared = VisionOCRService()

    private init() {}

    /// Converts a normalized SwiftUI selection rect (top-left origin, 0...1) to pixel coordinates for `CGImage.cropping(to:)`.
    public static func pixelCropRect(
        normalizedRect: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let clamped = CGRect(
            x: max(0, min(1, normalizedRect.minX)),
            y: max(0, min(1, normalizedRect.minY)),
            width: max(0.01, min(1 - max(0, normalizedRect.minX), normalizedRect.width)),
            height: max(0.01, min(1 - max(0, normalizedRect.minY), normalizedRect.height))
        )
        return CGRect(
            x: clamped.origin.x * CGFloat(imageWidth),
            y: clamped.origin.y * CGFloat(imageHeight),
            width: clamped.size.width * CGFloat(imageWidth),
            height: clamped.size.height * CGFloat(imageHeight)
        ).integral
    }

    /// Recognizes text from `image` (optionally cropped to `normalizedCropRect` in top-left normalized coordinates).
    public func recognizeText(
        in image: CGImage,
        normalizedCropRect: CGRect? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> String {
        let targetImage: CGImage
        if let norm = normalizedCropRect {
            let cropRect = Self.pixelCropRect(
                normalizedRect: norm,
                imageWidth: image.width,
                imageHeight: image.height
            )
            targetImage = image.cropping(to: cropRect) ?? image
        } else {
            targetImage = image
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                autoreleasepool {
                    let request = VNRecognizeTextRequest { request, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                        continuation.resume(returning: lines.joined(separator: "\n"))
                    }
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let handler = VNImageRequestHandler(cgImage: targetImage, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Searches `image` on-device via Apple Vision OCR for `query` and returns its top-left normalized center coordinates.
    public func findTextCenter(
        matching query: String,
        in image: CGImage,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) async throws -> VisionTextMatch? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                autoreleasepool {
                    let request = VNRecognizeTextRequest { request, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                        var exactMatch: VisionTextMatch?
                        var bestContains: (match: VisionTextMatch, lengthDelta: Int)?

                        for obs in observations {
                            guard let candidate = obs.topCandidates(1).first else { continue }
                            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let box = obs.boundingBox
                            // Vision uses bottom-left origin; convert to Android top-left normalized coordinates.
                            let centerX = max(0, min(1, Double(box.midX)))
                            let centerY = max(0, min(1, 1.0 - Double(box.midY)))
                            let match = VisionTextMatch(
                                matchedText: text,
                                normalizedCenterX: centerX,
                                normalizedCenterY: centerY
                            )

                            if text.compare(trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                                exactMatch = match
                                break
                            }
                            if text.localizedCaseInsensitiveContains(trimmedQuery) {
                                let delta = abs(text.count - trimmedQuery.count)
                                if bestContains == nil || delta < bestContains!.lengthDelta {
                                    bestContains = (match, delta)
                                }
                            }
                        }

                        continuation.resume(returning: exactMatch ?? bestContains?.match)
                    }
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.automaticallyDetectsLanguage = true

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Captures the latest mirrored frame, runs Vision OCR on the cropped region, and copies extracted text to `NSPasteboard`.
    @discardableResult
    public func grabTextFromMirrorFrame(normalizedCropRect: CGRect) async throws -> String {
        guard let image = ScrcpyClient.shared.latestFrameImage else {
            throw NSError(
                domain: "VisionOCRService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No active mirror frame available for OCR"]
            )
        }
        let text = try await recognizeText(in: image, normalizedCropRect: normalizedCropRect)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(trimmed, forType: .string)
            }
        }
        return trimmed
    }
}
