import Foundation

/// Bitmask matching `com.shadowgraph.daemon.graph.ShadowNode.PATCH_*` constants.
public struct ShadowPatchMask: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public static let parent      = ShadowPatchMask(rawValue: 1 << 0)
    public static let order       = ShadowPatchMask(rawValue: 1 << 1)
    public static let text        = ShadowPatchMask(rawValue: 1 << 2)
    public static let contentDesc = ShadowPatchMask(rawValue: 1 << 3)
    public static let resourceId  = ShadowPatchMask(rawValue: 1 << 4)
    public static let nodeClass   = ShadowPatchMask(rawValue: 1 << 5)
    public static let bounds      = ShadowPatchMask(rawValue: 1 << 6)
    public static let flags       = ShadowPatchMask(rawValue: 1 << 7)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public struct WireHelloPayload: Decodable, Sendable, Equatable {
    public let protocolVersion: Int
    public let format: String
    public let sdkInt: Int
    public let deviceModel: String
    public let pid: Int64

    public enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case format
        case sdkInt = "sdk_int"
        case deviceModel = "device_model"
        case pid
    }

    public init(protocolVersion: Int, format: String, sdkInt: Int, deviceModel: String, pid: Int64) {
        self.protocolVersion = protocolVersion
        self.format = format
        self.sdkInt = sdkInt
        self.deviceModel = deviceModel
        self.pid = pid
    }
}

public struct WireSnapshotPayload: Decodable, Sendable, Equatable {
    public let seq: UInt64
    public let timestampMs: Int64
    public let reason: String
    public let activePackage: String
    public let activeWindowId: Int
    public let nodeCount: Int
    public let nodes: [ShadowUINode]

    public enum CodingKeys: String, CodingKey {
        case seq
        case timestampMs = "ts_ms"
        case reason
        case activePackage = "package"
        case activeWindowId = "window_id"
        case nodeCount = "node_count"
        case nodes
    }

    public init(
        seq: UInt64,
        timestampMs: Int64,
        reason: String,
        activePackage: String,
        activeWindowId: Int,
        nodeCount: Int,
        nodes: [ShadowUINode]
    ) {
        self.seq = seq
        self.timestampMs = timestampMs
        self.reason = reason
        self.activePackage = activePackage
        self.activeWindowId = activeWindowId
        self.nodeCount = nodeCount
        self.nodes = nodes
    }
}

public struct WireNodePatch: Decodable, Sendable, Equatable {
    public let nodeId: Int64
    public let mask: Int
    public let parentId: Int64?
    public let hasParentIdKey: Bool
    public let index: Int?
    public let childIndex: Int?
    public let depth: Int?
    public let text: String?
    public let contentDesc: String?
    public let resourceId: String?
    public let className: String?
    public let packageName: String?
    public let bounds: String?
    public let centerX: Int?
    public let centerY: Int?
    public let clickable: Bool?
    public let scrollable: Bool?
    public let editable: Bool?
    public let focused: Bool?
    public let checked: Bool?
    public let enabled: Bool?
    public let visible: Bool?

    public enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case mask
        case parentId = "parent_id"
        case index
        case childIndex = "child_index"
        case depth
        case text
        case contentDesc = "content_desc"
        case resourceId = "resource_id"
        case className = "class"
        case packageName = "package_name"
        case bounds
        case centerX = "center_x"
        case centerY = "center_y"
        case clickable
        case scrollable
        case editable
        case focused
        case checked
        case enabled
        case visible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nodeId = try c.decode(Int64.self, forKey: .nodeId)
        self.mask = try c.decode(Int.self, forKey: .mask)

        let containsParent = c.contains(.parentId)
        self.hasParentIdKey = containsParent
        if containsParent {
            self.parentId = try c.decodeIfPresent(Int64.self, forKey: .parentId)
        } else {
            self.parentId = nil
        }

        self.index = try c.decodeIfPresent(Int.self, forKey: .index)
        self.childIndex = try c.decodeIfPresent(Int.self, forKey: .childIndex)
        self.depth = try c.decodeIfPresent(Int.self, forKey: .depth)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.contentDesc = try c.decodeIfPresent(String.self, forKey: .contentDesc)
        self.resourceId = try c.decodeIfPresent(String.self, forKey: .resourceId)
        self.className = try c.decodeIfPresent(String.self, forKey: .className)
        self.packageName = try c.decodeIfPresent(String.self, forKey: .packageName)
        self.bounds = try c.decodeIfPresent(String.self, forKey: .bounds)
        self.centerX = try c.decodeIfPresent(Int.self, forKey: .centerX)
        self.centerY = try c.decodeIfPresent(Int.self, forKey: .centerY)
        self.clickable = try c.decodeIfPresent(Bool.self, forKey: .clickable)
        self.scrollable = try c.decodeIfPresent(Bool.self, forKey: .scrollable)
        self.editable = try c.decodeIfPresent(Bool.self, forKey: .editable)
        self.focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
        self.checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        self.visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
    }

    public init(
        nodeId: Int64,
        mask: Int,
        parentId: Int64? = nil,
        hasParentIdKey: Bool = false,
        index: Int? = nil,
        childIndex: Int? = nil,
        depth: Int? = nil,
        text: String? = nil,
        contentDesc: String? = nil,
        resourceId: String? = nil,
        className: String? = nil,
        packageName: String? = nil,
        bounds: String? = nil,
        centerX: Int? = nil,
        centerY: Int? = nil,
        clickable: Bool? = nil,
        scrollable: Bool? = nil,
        editable: Bool? = nil,
        focused: Bool? = nil,
        checked: Bool? = nil,
        enabled: Bool? = nil,
        visible: Bool? = nil
    ) {
        self.nodeId = nodeId
        self.mask = mask
        self.parentId = parentId
        self.hasParentIdKey = hasParentIdKey
        self.index = index
        self.childIndex = childIndex
        self.depth = depth
        self.text = text
        self.contentDesc = contentDesc
        self.resourceId = resourceId
        self.className = className
        self.packageName = packageName
        self.bounds = bounds
        self.centerX = centerX
        self.centerY = centerY
        self.clickable = clickable
        self.scrollable = scrollable
        self.editable = editable
        self.focused = focused
        self.checked = checked
        self.enabled = enabled
        self.visible = visible
    }
}

public struct WireDiffPayload: Decodable, Sendable, Equatable {
    public let baseSeq: UInt64
    public let seq: UInt64
    public let timestampMs: Int64
    public let activePackage: String
    public let activeWindowId: Int
    public let eventType: Int?
    public let eventPackage: String?
    public let inserted: [ShadowUINode]
    public let updated: [WireNodePatch]
    public let removed: [Int64]

    public enum CodingKeys: String, CodingKey {
        case baseSeq = "base_seq"
        case seq
        case timestampMs = "ts_ms"
        case activePackage = "package"
        case activeWindowId = "window_id"
        case eventType = "event_type"
        case eventPackage = "event_package"
        case inserted
        case updated
        case removed
    }

    public init(
        baseSeq: UInt64,
        seq: UInt64,
        timestampMs: Int64,
        activePackage: String,
        activeWindowId: Int,
        eventType: Int? = nil,
        eventPackage: String? = nil,
        inserted: [ShadowUINode] = [],
        updated: [WireNodePatch] = [],
        removed: [Int64] = []
    ) {
        self.baseSeq = baseSeq
        self.seq = seq
        self.timestampMs = timestampMs
        self.activePackage = activePackage
        self.activeWindowId = activeWindowId
        self.eventType = eventType
        self.eventPackage = eventPackage
        self.inserted = inserted
        self.updated = updated
        self.removed = removed
    }
}

public struct WireHeartbeatPayload: Decodable, Sendable, Equatable {
    public let seq: UInt64
    public let timestampMs: Int64
    public let uptimeMs: Int64
    public let activePackage: String
    public let activeWindowId: Int
    public let clients: Int

    public enum CodingKeys: String, CodingKey {
        case seq
        case timestampMs = "ts_ms"
        case uptimeMs = "uptime_ms"
        case activePackage = "package"
        case activeWindowId = "window_id"
        case clients
    }

    public init(
        seq: UInt64,
        timestampMs: Int64,
        uptimeMs: Int64,
        activePackage: String,
        activeWindowId: Int,
        clients: Int
    ) {
        self.seq = seq
        self.timestampMs = timestampMs
        self.uptimeMs = uptimeMs
        self.activePackage = activePackage
        self.activeWindowId = activeWindowId
        self.clients = clients
    }
}

public struct WireErrorPayload: Decodable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let timestampMs: Int64

    public enum CodingKeys: String, CodingKey {
        case code
        case message
        case timestampMs = "ts_ms"
    }

    public init(code: String, message: String, timestampMs: Int64) {
        self.code = code
        self.message = message
        self.timestampMs = timestampMs
    }
}

public struct WirePongPayload: Decodable, Sendable, Equatable {
    public let timestampMs: Int64
    public let seq: UInt64

    public enum CodingKeys: String, CodingKey {
        case timestampMs = "ts_ms"
        case seq
    }

    public init(timestampMs: Int64, seq: UInt64) {
        self.timestampMs = timestampMs
        self.seq = seq
    }
}

public enum WireMessage: Sendable, Equatable {
    case hello(WireHelloPayload)
    case snapshot(WireSnapshotPayload)
    case diff(WireDiffPayload)
    case heartbeat(WireHeartbeatPayload)
    case error(WireErrorPayload)
    case pong(WirePongPayload)
}

public enum DaemonCommand: Sendable, Equatable {
    case snapshot
    case ping
    case setDebounce(ms: Int)
    case shutdown
}
