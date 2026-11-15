import Foundation
import CoreGraphics

/// Result of mapping a user-drawn normalized screen selection to an Android UI hierarchy node.
public struct MatchedVisualNode: Sendable, Equatable {
    public let node: AndroidUINode?
    public let devicePixelRect: CGRect
    public let normalizedRect: CGRect
    public let iouScore: Double

    public var fallbackCenterX: Int {
        if let node { return node.center_x }
        return Int(devicePixelRect.midX.rounded())
    }

    public var fallbackCenterY: Int {
        if let node { return node.center_y }
        return Int(devicePixelRect.midY.rounded())
    }

    public func toVisualNodeTarget() -> VisualNodeTarget {
        VisualNodeTarget(
            resourceId: node?.resource_id,
            className: node?.class,
            text: node?.text,
            contentDesc: node?.content_desc,
            fallbackX: fallbackCenterX,
            fallbackY: fallbackCenterY,
            normalizedRect: [
                Double(normalizedRect.origin.x),
                Double(normalizedRect.origin.y),
                Double(normalizedRect.size.width),
                Double(normalizedRect.size.height)
            ]
        )
    }
}

/// Pure coordinate & semantic matching engine linking a drawn macOS overlay rect to `AndroidUINode`s.
public enum VisualNodeMatcher {

    /// Parses UIAutomator `[x1,y1][x2,y2]` bounds into a `CGRect` in device pixel coordinates.
    public static func parseBoundsRect(from bounds: String) -> CGRect? {
        let numbers = bounds
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        let x1 = min(numbers[0], numbers[2])
        let y1 = min(numbers[1], numbers[3])
        let x2 = max(numbers[0], numbers[2])
        let y2 = max(numbers[1], numbers[3])
        let w = x2 - x1
        let h = y2 - y1
        guard w > 0, h > 0 else { return nil }
        return CGRect(x: x1, y: y1, width: w, height: h)
    }

    /// Converts a top-left normalized selection rect (`0...1`) into Android device pixel coordinates.
    public static func devicePixelRect(
        fromNormalized normalizedRect: CGRect,
        deviceWidth: Int,
        deviceHeight: Int
    ) -> CGRect {
        let w = CGFloat(max(1, deviceWidth))
        let h = CGFloat(max(1, deviceHeight))
        let clampedX = max(0, min(1, normalizedRect.origin.x))
        let clampedY = max(0, min(1, normalizedRect.origin.y))
        let clampedW = max(0.01, min(1 - clampedX, normalizedRect.size.width))
        let clampedH = max(0.01, min(1 - clampedY, normalizedRect.size.height))
        return CGRect(x: clampedX * w, y: clampedY * h, width: clampedW * w, height: clampedH * h)
    }

    /// Computes Intersection-over-Union (`0...1`) between two rectangles.
    public static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0.0
        }
        let interArea = Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height + b.width * b.height) - interArea
        guard unionArea > 0 else { return 0.0 }
        return interArea / unionArea
    }

    /// Matches the best `AndroidUINode` overlapping the user's drawn box, preferring semantic identifiers.
    public static func matchBestNode(
        normalizedRect: CGRect,
        deviceWidth: Int,
        deviceHeight: Int,
        nodes: [AndroidUINode]
    ) -> MatchedVisualNode {
        let targetRect = devicePixelRect(
            fromNormalized: normalizedRect,
            deviceWidth: deviceWidth,
            deviceHeight: deviceHeight
        )
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)

        var bestNode: AndroidUINode?
        var bestScore: Double = 0
        var bestIoU: Double = 0

        for node in nodes {
            guard let nodeRect = parseBoundsRect(from: node.bounds) else { continue }
            let iou = intersectionOverUnion(targetRect, nodeRect)
            let containsCenter = nodeRect.contains(targetCenter) || targetRect.contains(CGPoint(x: node.center_x, y: node.center_y))
            guard iou > 0.02 || containsCenter else { continue }

            // Semantic richness bonus so concrete widgets beat wrapping layout containers
            var semanticBonus = 0.0
            if !node.resource_id.isEmpty { semanticBonus += 0.20 }
            if !node.text.isEmpty { semanticBonus += 0.12 }
            if !node.content_desc.isEmpty { semanticBonus += 0.10 }
            if node.clickable { semanticBonus += 0.05 }

            let centerBonus = containsCenter ? 0.10 : 0.0
            let score = iou + semanticBonus + centerBonus

            if score > bestScore {
                bestScore = score
                bestNode = node
                bestIoU = iou
            }
        }

        return MatchedVisualNode(
            node: bestNode,
            devicePixelRect: targetRect,
            normalizedRect: normalizedRect,
            iouScore: bestIoU
        )
    }
}
