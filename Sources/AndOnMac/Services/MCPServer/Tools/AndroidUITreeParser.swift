import Foundation

/// Compact, token-efficient representation of a meaningful Android UI node.
public struct AndroidUINode: Codable, Sendable, Equatable {
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
}

/// Parses `uiautomator dump` XML into compact `AndroidUINode` entries, stripping empty layout containers.
public final class AndroidUITreeParser: NSObject, XMLParserDelegate {
    private var nodes: [AndroidUINode] = []
    private var nodeIndex = 0

    /// Parses raw `uiautomator` XML (even if prefixed/suffixed with CLI status text) into meaningful nodes.
    public static func parse(xmlString: String) -> [AndroidUINode] {
        guard let start = xmlString.range(of: "<hierarchy"),
              let end = xmlString.range(of: "</hierarchy>", options: .backwards) else {
            return []
        }
        let xmlSlice = String(xmlString[start.lowerBound..<end.upperBound])
        guard let data = xmlSlice.data(using: .utf8) else { return [] }

        let delegate = AndroidUITreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.nodes
    }

    /// Parses `[x1,y1][x2,y2]` bounds into `(centerX, centerY)`.
    public static func parseCenter(from bounds: String) -> (x: Int, y: Int)? {
        let numbers = bounds
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        guard numbers.count == 4 else { return nil }
        return ((numbers[0] + numbers[2]) / 2, (numbers[1] + numbers[3]) / 2)
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "node" else { return }

        let text = (attributeDict["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceId = (attributeDict["resource-id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contentDesc = (attributeDict["content-desc"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let className = (attributeDict["class"] ?? "").split(separator: ".").last.map(String.init) ?? ""
        let clickable = attributeDict["clickable"] == "true"
        let scrollable = attributeDict["scrollable"] == "true"
        let bounds = attributeDict["bounds"] ?? ""

        // Strip empty non-interactive layout containers to save LLM tokens
        let isMeaningful = clickable || scrollable || !text.isEmpty || !contentDesc.isEmpty || !resourceId.isEmpty
        guard isMeaningful, let center = Self.parseCenter(from: bounds) else { return }

        nodes.append(AndroidUINode(
            index: nodeIndex,
            text: text,
            resource_id: resourceId,
            content_desc: contentDesc,
            class: className,
            clickable: clickable,
            scrollable: scrollable,
            bounds: bounds,
            center_x: center.x,
            center_y: center.y
        ))
        nodeIndex += 1
    }
}
