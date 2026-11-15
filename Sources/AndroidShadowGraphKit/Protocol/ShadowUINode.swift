import Foundation

/// Compact, token-efficient representation of a meaningful Android UI node.
/// Binary- and JSON-compatible with `AndroidMCPKit` and `AndOnMac` MCP tools.
public struct ShadowCompactNode: Codable, Sendable, Equatable {
    public let index: Int
    public let text: String
    public let resource_id: String
    public let content_desc: String
    public let `class`: String
    public let clickable: Bool
    public let scrollable: Bool
    public let bounds: String
    public let center_x: Int
    public let center_y: Int

    public init(
        index: Int,
        text: String,
        resource_id: String,
        content_desc: String,
        class: String,
        clickable: Bool,
        scrollable: Bool,
        bounds: String,
        center_x: Int,
        center_y: Int
    ) {
        self.index = index
        self.text = text
        self.resource_id = resource_id
        self.content_desc = content_desc
        self.class = `class`
        self.clickable = clickable
        self.scrollable = scrollable
        self.bounds = bounds
        self.center_x = center_x
        self.center_y = center_y
    }

    public init(from node: ShadowUINode) {
        self.index = node.index
        self.text = node.text
        self.resource_id = node.resourceId
        self.content_desc = node.contentDesc
        self.class = node.className
        self.clickable = node.clickable
        self.scrollable = node.scrollable
        self.bounds = node.bounds
        self.center_x = node.centerX
        self.center_y = node.centerY
    }
}

/// Full Shadow DOM node decoded from `android-daemon` (`ndjson/1`).
/// Preserves all fields expected by `ShadowCompactNode`/`AndroidUINode` alongside graph identity and live flags.
public struct ShadowUINode: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64 { nodeId }

    // AndroidUINode-compatible core fields
    public var index: Int
    public var text: String
    public var resourceId: String
    public var contentDesc: String
    public var className: String
    public var clickable: Bool
    public var scrollable: Bool
    public var bounds: String
    public var centerX: Int
    public var centerY: Int

    // Extended Shadow DOM graph metadata
    public var nodeId: Int64
    public var parentId: Int64?
    public var windowId: Int
    public var childIndex: Int
    public var depth: Int
    public var packageName: String
    public var editable: Bool
    public var focused: Bool
    public var checked: Bool
    public var enabled: Bool
    public var visible: Bool

    public enum CodingKeys: String, CodingKey {
        case index
        case text
        case resourceId = "resource_id"
        case contentDesc = "content_desc"
        case className = "class"
        case clickable
        case scrollable
        case bounds
        case centerX = "center_x"
        case centerY = "center_y"
        case nodeId = "node_id"
        case parentId = "parent_id"
        case windowId = "window_id"
        case childIndex = "child_index"
        case depth
        case packageName = "package_name"
        case editable
        case focused
        case checked
        case enabled
        case visible
    }

    public init(
        index: Int,
        text: String,
        resourceId: String,
        contentDesc: String,
        className: String,
        clickable: Bool,
        scrollable: Bool,
        bounds: String,
        centerX: Int,
        centerY: Int,
        nodeId: Int64,
        parentId: Int64?,
        windowId: Int,
        childIndex: Int,
        depth: Int,
        packageName: String,
        editable: Bool,
        focused: Bool,
        checked: Bool,
        enabled: Bool,
        visible: Bool
    ) {
        self.index = index
        self.text = text
        self.resourceId = resourceId
        self.contentDesc = contentDesc
        self.className = className
        self.clickable = clickable
        self.scrollable = scrollable
        self.bounds = bounds
        self.centerX = centerX
        self.centerY = centerY
        self.nodeId = nodeId
        self.parentId = parentId
        self.windowId = windowId
        self.childIndex = childIndex
        self.depth = depth
        self.packageName = packageName
        self.editable = editable
        self.focused = focused
        self.checked = checked
        self.enabled = enabled
        self.visible = visible
    }

    @inlinable
    public func toCompactNode() -> ShadowCompactNode {
        ShadowCompactNode(from: self)
    }
}

public enum ShadowTreeMatchMode: Sendable, Equatable {
    case exact
    case containsCaseInsensitive
    case suffixOrExactResourceId
}

/// Thin shared abstraction allowing `AndOnMac` and `AndroidMCPKit` to query a live Shadow DOM
/// without coupling to `Network.framework` or transport internals.
public protocol ShadowTreeProviding: Sendable {
    func getCurrentTree() async -> [ShadowUINode]
    func getCompactTree() async -> [ShadowCompactNode]
    func fastCompactTreeIfFresh(maxWaitSeconds: TimeInterval, maxAgeSeconds: TimeInterval) async -> [ShadowCompactNode]?
    func ensureShadowStreamReady(maxWaitSeconds: TimeInterval, maxAgeSeconds: TimeInterval) async -> Bool
    func findNode(byText query: String, mode: ShadowTreeMatchMode, preferClickable: Bool) async -> ShadowUINode?
    func findNode(byResourceID resourceId: String, mode: ShadowTreeMatchMode) async -> ShadowUINode?
    func findNode(byContentDesc query: String, mode: ShadowTreeMatchMode) async -> ShadowUINode?
    func recordAction(_ action: AttributedUIAction) async
}

public extension ShadowTreeProviding {
    func ensureShadowStreamReady(maxWaitSeconds: TimeInterval, maxAgeSeconds: TimeInterval) async -> Bool {
        await fastCompactTreeIfFresh(maxWaitSeconds: maxWaitSeconds, maxAgeSeconds: maxAgeSeconds) != nil
    }
}
