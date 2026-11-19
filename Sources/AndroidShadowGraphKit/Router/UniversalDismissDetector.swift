import Foundation

public struct DismissCandidate: Sendable, Equatable {
    public let nodeId: Int64
    public let tapX: Int
    public let tapY: Int
    public let label: String
    public let reason: String
    public let score: Int

    public init(
        nodeId: Int64,
        tapX: Int,
        tapY: Int,
        label: String,
        reason: String,
        score: Int
    ) {
        self.nodeId = nodeId
        self.tapX = tapX
        self.tapY = tapY
        self.label = label
        self.reason = reason
        self.score = score
    }
}

/// Deterministic detector for closing non-destructive in-app popups, cookie prompts,
/// and promo splash screens during A* auto-recovery (#4).
public enum UniversalDismissDetector {
    private static let launcherPackages: Set<String> = [
        "com.google.android.apps.nexuslauncher",
        "com.android.launcher3",
        "com.android.launcher",
        "com.sec.android.app.launcher",
        "com.miui.home",
        "com.oppo.launcher",
        "com.oneplus.launcher"
    ]

    private static let exactDismissPhrases: [String: Int] = [
        "не сейчас": 115,
        "not now": 115,
        "позже": 105,
        "maybe later": 105,
        "later": 100,
        "напомнить позже": 105,
        "закрыть": 110,
        "close": 110,
        "пропустить": 108,
        "skip": 108,
        "нет, спасибо": 112,
        "no thanks": 112,
        "no, thanks": 112,
        "отклонить": 102,
        "decline": 102,
        "dismiss": 110,
        "понятно": 96,
        "got it": 96,
        "скрыть": 98,
        "hide": 95,
        "не разрешать": 98,
        "don't allow": 98,
        "deny": 96
    ]

    private static let compactCloseGlyphs: Set<String> = [
        "x", "×", "✕", "✖", "╳", "close ad", "закрыть рекламу"
    ]

    private static let dismissResourceIdSuffixes: [String: Int] = [
        "interstitial_close": 120,
        "close_button": 115,
        "btn_close": 115,
        "close_btn": 115,
        "iv_close": 110,
        "ic_close": 108,
        "dismiss": 105,
        "dismiss_button": 108,
        "btn_dismiss": 108,
        "skip_button": 108,
        "btn_skip": 108,
        "negative_button": 96,
        "close": 92
    ]

    public static func findDismissCandidate(
        in index: ShadowTreeIndex,
        excludingNodeIds: Set<Int64> = [],
        ignoredPackages: Set<String> = ["com.android.systemui"]
    ) -> DismissCandidate? {
        guard !launcherPackages.contains(index.activePackage) else {
            return nil
        }

        var best: DismissCandidate?

        for node in index.orderedNodes {
            guard node.visible, node.enabled else { continue }
            guard !excludingNodeIds.contains(node.nodeId) else { continue }
            if !node.packageName.isEmpty && ignoredPackages.contains(node.packageName) {
                continue
            }
            // Never dismiss via a destructive/payment action
            if HazardousActionClassifier.assess(node: node).isHazardous {
                continue
            }

            let resolvedTarget = clickableTarget(for: node, in: index)
            guard !excludingNodeIds.contains(resolvedTarget.nodeId) else { continue }
            if HazardousActionClassifier.assess(node: resolvedTarget).isHazardous {
                continue
            }

            guard let tapCoords = tapPoint(for: resolvedTarget) else { continue }
            guard let (score, label, reason) = matchScore(node: node, tapTarget: resolvedTarget) else {
                continue
            }

            let candidate = DismissCandidate(
                nodeId: resolvedTarget.nodeId,
                tapX: tapCoords.x,
                tapY: tapCoords.y,
                label: label,
                reason: reason,
                score: score
            )
            if let currentBest = best {
                if candidate.score > currentBest.score {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    private static func matchScore(
        node: ShadowUINode,
        tapTarget: ShadowUINode
    ) -> (score: Int, label: String, reason: String)? {
        let rawLabels = [node.text, node.contentDesc]
        for raw in rawLabels {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()

            if let baseScore = exactDismissPhrases[lowered] {
                let clickableBonus = tapTarget.clickable ? 15 : 0
                return (baseScore + clickableBonus, trimmed, "phrase:\(lowered)")
            }

            if compactCloseGlyphs.contains(lowered) {
                guard let rect = ShadowTreeIndex.parseBoundsRect(tapTarget.bounds)
                        ?? ShadowTreeIndex.parseBoundsRect(node.bounds) else {
                    continue
                }
                let width = rect.maxX - rect.minX
                let height = rect.maxY - rect.minY
                guard width <= 220 && height <= 220 else { continue }
                let clickableBonus = tapTarget.clickable ? 15 : 0
                return (104 + clickableBonus, trimmed, "close_glyph:\(lowered)")
            }
        }

        if !node.resourceId.isEmpty {
            let shortId = shortResourceId(node.resourceId)
            if let ridScore = dismissResourceIdSuffixes[shortId] {
                let clickableBonus = tapTarget.clickable ? 15 : 0
                let label = !node.contentDesc.isEmpty ? node.contentDesc : (!node.text.isEmpty ? node.text : shortId)
                return (ridScore + clickableBonus, label, "resource_id:\(shortId)")
            }
        }

        return nil
    }

    private static func clickableTarget(for node: ShadowUINode, in index: ShadowTreeIndex) -> ShadowUINode {
        if node.clickable {
            return node
        }
        var cursorId = node.parentId
        var depth = 0
        while let pid = cursorId, depth < 3 {
            guard let parent = index.nodesById[pid] else { break }
            if parent.clickable && parent.visible && parent.enabled {
                return parent
            }
            cursorId = parent.parentId
            depth += 1
        }
        return node
    }

    private static func tapPoint(for node: ShadowUINode) -> (x: Int, y: Int)? {
        if node.centerX > 0 || node.centerY > 0 {
            return (node.centerX, node.centerY)
        }
        if let rect = ShadowTreeIndex.parseBoundsRect(node.bounds) {
            return ((rect.minX + rect.maxX) / 2, (rect.minY + rect.maxY) / 2)
        }
        return nil
    }

    private static func shortResourceId(_ resourceId: String) -> String {
        if let range = resourceId.range(of: ":id/") {
            return String(resourceId[range.upperBound...]).lowercased()
        }
        if let idx = resourceId.lastIndex(of: "/") {
            let next = resourceId.index(after: idx)
            if next < resourceId.endIndex {
                return String(resourceId[next...]).lowercased()
            }
        }
        return resourceId.lowercased()
    }
}
