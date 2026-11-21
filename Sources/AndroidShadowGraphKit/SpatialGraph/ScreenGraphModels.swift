import Foundation

public struct AttributedUIAction: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case tap
        case swipe
        case keyevent
        case typeText
        case launchApp
    }

    public let kind: Kind
    public let targetDescription: String
    public let x: Int?
    public let y: Int?
    public let endX: Int?
    public let endY: Int?
    public let durationMs: Int?
    public let textInput: String?
    public let pressEnter: Bool?
    public let selectorResourceId: String?
    public let selectorText: String?
    public let selectorContentDesc: String?
    public let selectorAliases: [String]
    public let timestamp: Date

    public enum CodingKeys: String, CodingKey {
        case kind
        case targetDescription
        case x
        case y
        case endX
        case endY
        case durationMs
        case textInput
        case pressEnter
        case selectorResourceId
        case selectorText
        case selectorContentDesc
        case selectorAliases
        case timestamp
    }

    public init(
        kind: Kind,
        targetDescription: String,
        x: Int? = nil,
        y: Int? = nil,
        endX: Int? = nil,
        endY: Int? = nil,
        durationMs: Int? = nil,
        textInput: String? = nil,
        pressEnter: Bool? = nil,
        selectorResourceId: String? = nil,
        selectorText: String? = nil,
        selectorContentDesc: String? = nil,
        selectorAliases: [String] = [],
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.targetDescription = targetDescription
        self.x = x
        self.y = y
        self.endX = endX
        self.endY = endY
        self.durationMs = durationMs
        self.textInput = textInput
        self.pressEnter = pressEnter
        self.selectorResourceId = selectorResourceId
        self.selectorText = selectorText
        self.selectorContentDesc = selectorContentDesc
        self.selectorAliases = selectorAliases
        self.timestamp = timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.targetDescription = try container.decode(String.self, forKey: .targetDescription)
        self.x = try container.decodeIfPresent(Int.self, forKey: .x)
        self.y = try container.decodeIfPresent(Int.self, forKey: .y)
        self.endX = try container.decodeIfPresent(Int.self, forKey: .endX)
        self.endY = try container.decodeIfPresent(Int.self, forKey: .endY)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.textInput = try container.decodeIfPresent(String.self, forKey: .textInput)
        self.pressEnter = try container.decodeIfPresent(Bool.self, forKey: .pressEnter)
        self.selectorResourceId = try container.decodeIfPresent(String.self, forKey: .selectorResourceId)
        self.selectorText = try container.decodeIfPresent(String.self, forKey: .selectorText)
        self.selectorContentDesc = try container.decodeIfPresent(String.self, forKey: .selectorContentDesc)
        self.selectorAliases = try container.decodeIfPresent([String].self, forKey: .selectorAliases) ?? []
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(targetDescription, forKey: .targetDescription)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        try container.encodeIfPresent(endX, forKey: .endX)
        try container.encodeIfPresent(endY, forKey: .endY)
        try container.encodeIfPresent(durationMs, forKey: .durationMs)
        try container.encodeIfPresent(textInput, forKey: .textInput)
        try container.encodeIfPresent(pressEnter, forKey: .pressEnter)
        try container.encodeIfPresent(selectorResourceId, forKey: .selectorResourceId)
        try container.encodeIfPresent(selectorText, forKey: .selectorText)
        try container.encodeIfPresent(selectorContentDesc, forKey: .selectorContentDesc)
        if !selectorAliases.isEmpty {
            try container.encode(selectorAliases, forKey: .selectorAliases)
        }
        try container.encode(timestamp, forKey: .timestamp)
    }

    public var signature: String {
        if !targetDescription.isEmpty {
            return "\(kind.rawValue):\(targetDescription)"
        }
        if let x, let y {
            return "\(kind.rawValue):(\(x),\(y))"
        }
        return kind.rawValue
    }

    /// Returns a PII-scrubbed copy safe to store in `SpatialGraphEngine` and serialize into `shadow_graph.json`.
    public func redactedForStorage() -> AttributedUIAction {
        AttributedUIAction(
            kind: kind,
            targetDescription: ScreenLayoutHasher.redactPII(targetDescription),
            x: x,
            y: y,
            endX: endX,
            endY: endY,
            durationMs: durationMs,
            textInput: textInput.map { ScreenLayoutHasher.redactPII($0) },
            pressEnter: pressEnter,
            selectorResourceId: selectorResourceId,
            selectorText: selectorText.map { ScreenLayoutHasher.redactPII($0) },
            selectorContentDesc: selectorContentDesc.map { ScreenLayoutHasher.redactPII($0) },
            selectorAliases: selectorAliases.map { ScreenLayoutHasher.redactPII($0) },
            timestamp: timestamp
        )
    }
}

public struct ScreenStateVertex: Sendable, Codable, Identifiable, Equatable {
    public var id: UInt64 { layoutHash }
    public let layoutHash: UInt64
    public let activePackage: String
    public let sampleInteractiveLabels: [String]
    public var semanticTokens: Set<String>
    public let firstSeenAt: Date
    public var lastSeenAt: Date
    public var visitCount: Int
    /// First-discovery parent hash in the acyclic spanning DAG (`nil` for root).
    public let discoveryParentHash: UInt64?
    /// Depth from root in the acyclic spanning DAG (`0` for root).
    public let discoveryDepth: Int
    /// Whether this vertex came from the cross-device Zero-PII Seed Graph and is awaiting hydration.
    public let isSeed: Bool
    /// Multilingual / cross-OEM semantic aliases carried by seed vertices and preserved after hydration.
    public var semanticAliases: [String]

    public enum CodingKeys: String, CodingKey {
        case layoutHash
        case activePackage
        case sampleInteractiveLabels
        case semanticTokens
        case firstSeenAt
        case lastSeenAt
        case visitCount
        case discoveryParentHash
        case discoveryDepth
        case isSeed
        case semanticAliases
    }

    public init(
        layoutHash: UInt64,
        activePackage: String,
        sampleInteractiveLabels: [String],
        semanticTokens: Set<String> = [],
        firstSeenAt: Date,
        lastSeenAt: Date,
        visitCount: Int,
        discoveryParentHash: UInt64?,
        discoveryDepth: Int,
        isSeed: Bool = false,
        semanticAliases: [String] = []
    ) {
        self.layoutHash = layoutHash
        self.activePackage = activePackage
        self.sampleInteractiveLabels = sampleInteractiveLabels
        self.semanticTokens = semanticTokens
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.visitCount = visitCount
        self.discoveryParentHash = discoveryParentHash
        self.discoveryDepth = discoveryDepth
        self.isSeed = isSeed
        self.semanticAliases = semanticAliases
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.layoutHash = try container.decode(UInt64.self, forKey: .layoutHash)
        self.activePackage = try container.decode(String.self, forKey: .activePackage)
        self.sampleInteractiveLabels = try container.decode([String].self, forKey: .sampleInteractiveLabels)
        self.semanticTokens = try container.decodeIfPresent(Set<String>.self, forKey: .semanticTokens) ?? []
        self.firstSeenAt = try container.decode(Date.self, forKey: .firstSeenAt)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        self.visitCount = try container.decode(Int.self, forKey: .visitCount)
        self.discoveryParentHash = try container.decodeIfPresent(UInt64.self, forKey: .discoveryParentHash)
        self.discoveryDepth = try container.decode(Int.self, forKey: .discoveryDepth)
        self.isSeed = try container.decodeIfPresent(Bool.self, forKey: .isSeed) ?? false
        self.semanticAliases = try container.decodeIfPresent([String].self, forKey: .semanticAliases) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layoutHash, forKey: .layoutHash)
        try container.encode(activePackage, forKey: .activePackage)
        try container.encode(sampleInteractiveLabels, forKey: .sampleInteractiveLabels)
        try container.encode(semanticTokens, forKey: .semanticTokens)
        try container.encode(firstSeenAt, forKey: .firstSeenAt)
        try container.encode(lastSeenAt, forKey: .lastSeenAt)
        try container.encode(visitCount, forKey: .visitCount)
        try container.encodeIfPresent(discoveryParentHash, forKey: .discoveryParentHash)
        try container.encode(discoveryDepth, forKey: .discoveryDepth)
        if isSeed {
            try container.encode(isSeed, forKey: .isSeed)
        }
        if !semanticAliases.isEmpty {
            try container.encode(semanticAliases, forKey: .semanticAliases)
        }
    }
}

public struct ScreenTransitionEdge: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let fromHash: UInt64
    public let toHash: UInt64
    public let action: AttributedUIAction?
    public let actionSignature: String
    public var traversalCount: Int
    public var averageTransitionMs: Double
    public let isSpanningTreeEdge: Bool
    public var lastTraversedAt: Date
    public var isHazardous: Bool
    public var hazardReason: String?
    public var consecutiveFailures: Int
    public var isSeed: Bool

    public enum CodingKeys: String, CodingKey {
        case id
        case fromHash
        case toHash
        case action
        case actionSignature
        case traversalCount
        case averageTransitionMs
        case isSpanningTreeEdge
        case lastTraversedAt
        case isHazardous
        case hazardReason
        case consecutiveFailures
        case isSeed
    }

    public init(
        id: UUID = UUID(),
        fromHash: UInt64,
        toHash: UInt64,
        action: AttributedUIAction?,
        actionSignature: String,
        traversalCount: Int = 1,
        averageTransitionMs: Double = 0,
        isSpanningTreeEdge: Bool = false,
        lastTraversedAt: Date = Date(),
        isHazardous: Bool = false,
        hazardReason: String? = nil,
        consecutiveFailures: Int = 0,
        isSeed: Bool = false
    ) {
        self.id = id
        self.fromHash = fromHash
        self.toHash = toHash
        self.action = action
        self.actionSignature = actionSignature
        self.traversalCount = traversalCount
        self.averageTransitionMs = averageTransitionMs
        self.isSpanningTreeEdge = isSpanningTreeEdge
        self.lastTraversedAt = lastTraversedAt
        self.isHazardous = isHazardous
        self.hazardReason = hazardReason
        self.consecutiveFailures = consecutiveFailures
        self.isSeed = isSeed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.fromHash = try container.decode(UInt64.self, forKey: .fromHash)
        self.toHash = try container.decode(UInt64.self, forKey: .toHash)
        self.action = try container.decodeIfPresent(AttributedUIAction.self, forKey: .action)
        self.actionSignature = try container.decode(String.self, forKey: .actionSignature)
        self.traversalCount = try container.decode(Int.self, forKey: .traversalCount)
        self.averageTransitionMs = try container.decode(Double.self, forKey: .averageTransitionMs)
        self.isSpanningTreeEdge = try container.decode(Bool.self, forKey: .isSpanningTreeEdge)
        self.lastTraversedAt = try container.decode(Date.self, forKey: .lastTraversedAt)
        self.isHazardous = try container.decodeIfPresent(Bool.self, forKey: .isHazardous) ?? false
        self.hazardReason = try container.decodeIfPresent(String.self, forKey: .hazardReason)
        self.consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        self.isSeed = try container.decodeIfPresent(Bool.self, forKey: .isSeed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fromHash, forKey: .fromHash)
        try container.encode(toHash, forKey: .toHash)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encode(actionSignature, forKey: .actionSignature)
        try container.encode(traversalCount, forKey: .traversalCount)
        try container.encode(averageTransitionMs, forKey: .averageTransitionMs)
        try container.encode(isSpanningTreeEdge, forKey: .isSpanningTreeEdge)
        try container.encode(lastTraversedAt, forKey: .lastTraversedAt)
        try container.encode(isHazardous, forKey: .isHazardous)
        try container.encodeIfPresent(hazardReason, forKey: .hazardReason)
        try container.encode(consecutiveFailures, forKey: .consecutiveFailures)
        if isSeed {
            try container.encode(isSeed, forKey: .isSeed)
        }
    }
}

public struct SpatialGraphSnapshot: Sendable, Codable, Equatable {
    public let rootStateHash: UInt64?
    public let currentStateHash: UInt64?
    public let vertices: [ScreenStateVertex]
    public let edges: [ScreenTransitionEdge]
    public let spanningChildren: [UInt64: [UInt64]]

    public init(
        rootStateHash: UInt64?,
        currentStateHash: UInt64?,
        vertices: [ScreenStateVertex],
        edges: [ScreenTransitionEdge],
        spanningChildren: [UInt64: [UInt64]]
    ) {
        self.rootStateHash = rootStateHash
        self.currentStateHash = currentStateHash
        self.vertices = vertices
        self.edges = edges
        self.spanningChildren = spanningChildren
    }
}

public struct RankedVertexMatch: Sendable, Equatable {
    public let vertex: ScreenStateVertex
    public let score: Int

    public init(vertex: ScreenStateVertex, score: Int) {
        self.vertex = vertex
        self.score = score
    }
}
