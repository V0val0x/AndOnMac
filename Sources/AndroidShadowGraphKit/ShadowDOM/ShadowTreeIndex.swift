import Foundation

/// Immutable, pre-indexed snapshot of the active Android UI tree for O(1) lookups and zero-copy reads.
public struct ShadowTreeIndex: Sendable, Equatable {
    public let seq: UInt64
    public let timestampMs: Int64
    public let activePackage: String
    public let activeWindowId: Int
    public let orderedNodes: [ShadowUINode]
    public let compactNodes: [ShadowCompactNode]
    public let nodesById: [Int64: ShadowUINode]
    public let childrenByParentId: [Int64: [Int64]]

    // Secondary hash indexes for O(1) exact/suffix selector queries
    private let nodesByResourceId: [String: [ShadowUINode]]
    private let nodesByShortResourceId: [String: [ShadowUINode]]
    private let nodesByLowercasedText: [String: [ShadowUINode]]
    private let nodesByLowercasedDesc: [String: [ShadowUINode]]

    public init(
        seq: UInt64,
        timestampMs: Int64,
        activePackage: String,
        activeWindowId: Int,
        nodes: [ShadowUINode]
    ) {
        self.seq = seq
        self.timestampMs = timestampMs
        self.activePackage = activePackage
        self.activeWindowId = activeWindowId

        let sorted = nodes.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.nodeId < $1.nodeId
        }
        self.orderedNodes = sorted

        var compact: [ShadowCompactNode] = []
        compact.reserveCapacity(sorted.count)

        var byId: [Int64: ShadowUINode] = Dictionary(minimumCapacity: sorted.count)
        var byParent: [Int64: [Int64]] = [:]
        var byResId: [String: [ShadowUINode]] = [:]
        var byShortResId: [String: [ShadowUINode]] = [:]
        var byText: [String: [ShadowUINode]] = [:]
        var byDesc: [String: [ShadowUINode]] = [:]

        for node in sorted {
            compact.append(node.toCompactNode())
            byId[node.nodeId] = node

            if let pid = node.parentId {
                byParent[pid, default: []].append(node.nodeId)
            }
            if !node.resourceId.isEmpty {
                byResId[node.resourceId, default: []].append(node)
                let shortId = Self.extractShortResourceId(node.resourceId)
                if !shortId.isEmpty {
                    byShortResId[shortId, default: []].append(node)
                }
            }
            if !node.text.isEmpty {
                byText[node.text.lowercased(), default: []].append(node)
            }
            if !node.contentDesc.isEmpty {
                byDesc[node.contentDesc.lowercased(), default: []].append(node)
            }
        }

        self.compactNodes = compact
        self.nodesById = byId
        self.childrenByParentId = byParent
        self.nodesByResourceId = byResId
        self.nodesByShortResourceId = byShortResId
        self.nodesByLowercasedText = byText
        self.nodesByLowercasedDesc = byDesc
    }

    public func exactNodes(forResourceId resourceId: String) -> [ShadowUINode]? {
        nodesByResourceId[resourceId]
    }

    public func shortIdNodes(forShortResourceId shortId: String) -> [ShadowUINode]? {
        nodesByShortResourceId[shortId]
    }

    public func exactLowercasedTextNodes(for queryLowercased: String) -> [ShadowUINode]? {
        nodesByLowercasedText[queryLowercased]
    }

    public func exactLowercasedDescNodes(for queryLowercased: String) -> [ShadowUINode]? {
        nodesByLowercasedDesc[queryLowercased]
    }

    public struct BoundsRect: Sendable, Equatable {
        public let minX: Int
        public let minY: Int
        public let maxX: Int
        public let maxY: Int

        public var area: Int64 {
            Int64(maxX - minX) * Int64(maxY - minY)
        }

        public func contains(x: Int, y: Int) -> Bool {
            x >= minX && x <= maxX && y >= minY && y <= maxY
        }
    }

    /// Parses UIAutomator / Accessibility `[x1,y1][x2,y2]` bounds into integer coordinates.
    public static func parseBoundsRect(_ bounds: String) -> BoundsRect? {
        var nums: [Int] = []
        nums.reserveCapacity(4)
        var current = ""
        for ch in bounds {
            if ch == "-" {
                if current.isEmpty {
                    current.append(ch)
                } else {
                    if let val = Int(current) { nums.append(val) }
                    current = "-"
                }
            } else if ch.isASCII && ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                if let val = Int(current) { nums.append(val) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty, let val = Int(current) {
            nums.append(val)
        }
        guard nums.count == 4 else { return nil }
        let minX = min(nums[0], nums[2])
        let minY = min(nums[1], nums[3])
        let maxX = max(nums[0], nums[2])
        let maxY = max(nums[1], nums[3])
        guard maxX > minX, maxY > minY else { return nil }
        return BoundsRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Resolves the most specific visible UI node under physical display coordinates `(x, y)`
    /// for semantic tap attribution (`selectorText`, `selectorContentDesc`, `selectorResourceId`).
    public func resolveNode(atX x: Int, y: Int) -> ShadowUINode? {
        var bestNode: ShadowUINode?
        var bestBounds: BoundsRect?

        for node in orderedNodes where node.visible {
            let hasLabel = !node.text.isEmpty || !node.contentDesc.isEmpty
            let isInteractive = node.clickable || node.editable
            guard hasLabel || isInteractive else { continue }
            guard let rect = Self.parseBoundsRect(node.bounds), rect.contains(x: x, y: y) else { continue }

            if let currentBest = bestNode, let currentRect = bestBounds {
                let lhsArea = rect.area
                let rhsArea = currentRect.area
                if lhsArea < rhsArea {
                    bestNode = node
                    bestBounds = rect
                } else if lhsArea == rhsArea {
                    let currentHasLabel = !currentBest.text.isEmpty || !currentBest.contentDesc.isEmpty
                    if hasLabel != currentHasLabel {
                        if hasLabel {
                            bestNode = node
                            bestBounds = rect
                        }
                    } else if node.clickable != currentBest.clickable {
                        if node.clickable {
                            bestNode = node
                            bestBounds = rect
                        }
                    } else if node.depth != currentBest.depth {
                        if node.depth > currentBest.depth {
                            bestNode = node
                            bestBounds = rect
                        }
                    } else if node.index > currentBest.index {
                        bestNode = node
                        bestBounds = rect
                    }
                }
            } else {
                bestNode = node
                bestBounds = rect
            }
        }

        guard let winner = bestNode else { return nil }

        // If user clicked inside a clickable container (e.g., Settings row) outside its TextView child,
        // inspect visible descendants so the row's label & resourceId are still attributed.
        if winner.text.isEmpty && winner.contentDesc.isEmpty && winner.clickable,
           let descendant = findBestSemanticDescendant(of: winner.nodeId) {
            return descendant
        }
        return winner
    }

    /// Builds an `AttributedUIAction` for a manual tap at physical display coordinates `(x, y)`.
    public func attributedTapAction(atX x: Int, y: Int, timestamp: Date = Date()) -> AttributedUIAction {
        guard let node = resolveNode(atX: x, y: y) else {
            return AttributedUIAction(
                kind: .tap,
                targetDescription: "(\(x),\(y))",
                x: x,
                y: y,
                timestamp: timestamp
            )
        }
        let label: String
        if !node.text.isEmpty {
            label = node.text
        } else if !node.contentDesc.isEmpty {
            label = node.contentDesc
        } else if !node.resourceId.isEmpty {
            label = node.resourceId
        } else {
            label = "(\(x),\(y))"
        }
        return AttributedUIAction(
            kind: .tap,
            targetDescription: label,
            x: x,
            y: y,
            selectorResourceId: node.resourceId.isEmpty ? nil : node.resourceId,
            selectorText: node.text.isEmpty ? nil : node.text,
            selectorContentDesc: node.contentDesc.isEmpty ? nil : node.contentDesc,
            timestamp: timestamp
        )
    }

    private func findBestSemanticDescendant(of rootId: Int64) -> ShadowUINode? {
        guard let initialChildren = childrenByParentId[rootId], !initialChildren.isEmpty else {
            return nil
        }
        var queue = initialChildren
        var cursor = 0
        var visited: Set<Int64> = [rootId]
        var candidates: [ShadowUINode] = []

        while cursor < queue.count && visited.count < 64 {
            let childId = queue[cursor]
            cursor += 1
            guard visited.insert(childId).inserted,
                  let child = nodesById[childId],
                  child.visible else {
                continue
            }
            if !child.text.isEmpty || !child.contentDesc.isEmpty {
                candidates.append(child)
            }
            if let grandchildren = childrenByParentId[childId] {
                queue.append(contentsOf: grandchildren)
            }
        }

        return candidates.max { lhs, rhs in
            Self.descendantLabelScore(lhs) < Self.descendantLabelScore(rhs)
        }
    }

    private static func descendantLabelScore(_ node: ShadowUINode) -> (Int, Int) {
        var score = 0
        if !node.text.isEmpty { score += 10 }
        if node.resourceId.lowercased().hasSuffix("title") { score += 8 }
        if !node.contentDesc.isEmpty { score += 4 }
        if !node.resourceId.isEmpty { score += 2 }
        return (score, -node.index)
    }

    private static func extractShortResourceId(_ resourceId: String) -> String {
        if let range = resourceId.range(of: ":id/") {
            return String(resourceId[range.upperBound...])
        }
        if let slashIdx = resourceId.lastIndex(of: "/") {
            let next = resourceId.index(after: slashIdx)
            if next < resourceId.endIndex {
                return String(resourceId[next...])
            }
        }
        return resourceId
    }
}

public struct ShadowDOMUpdate: Sendable, Equatable {
    public let index: ShadowTreeIndex
    public let isFullSnapshot: Bool
    public let insertedCount: Int
    public let updatedCount: Int
    public let removedCount: Int
    public let eventType: Int?
    public let eventPackage: String?
    public let isSecureScreenActive: Bool

    public init(
        index: ShadowTreeIndex,
        isFullSnapshot: Bool,
        insertedCount: Int,
        updatedCount: Int,
        removedCount: Int,
        eventType: Int? = nil,
        eventPackage: String? = nil,
        isSecureScreenActive: Bool = false
    ) {
        self.index = index
        self.isFullSnapshot = isFullSnapshot
        self.insertedCount = insertedCount
        self.updatedCount = updatedCount
        self.removedCount = removedCount
        self.eventType = eventType
        self.eventPackage = eventPackage
        self.isSecureScreenActive = isSecureScreenActive
    }
}
