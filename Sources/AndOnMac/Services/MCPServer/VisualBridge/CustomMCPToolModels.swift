import Foundation

/// Allow-listed Android UI actions executable by user-created or community-imported visual MCP tools.
public enum VisualMCPActionType: String, Codable, Sendable, CaseIterable, Identifiable {
    case readTextUIAutomator = "read_text_uiautomator"
    case readTextOCR = "read_text_ocr"
    case tapElement = "tap_element"
    case typeText = "type_text"

    public var id: String { rawValue }

    public func localizedTitle(lang: AppLanguage) -> String {
        switch self {
        case .readTextUIAutomator:
            return L10n.tr("Прочитать текст (UIAutomator)", "Read Text (UIAutomator)", lang: lang)
        case .readTextOCR:
            return L10n.tr("Прочитать текст (Vision OCR)", "Read Text (Vision OCR)", lang: lang)
        case .tapElement:
            return L10n.tr("Нажать на элемент", "Tap Element", lang: lang)
        case .typeText:
            return L10n.tr("Ввести текст", "Type Text", lang: lang)
        }
    }
}

/// Visual + semantic target linking a drawn screen region to an Android accessibility node.
public struct VisualNodeTarget: Codable, Sendable, Equatable {
    public let resourceId: String?
    public let className: String?
    public let text: String?
    public let contentDesc: String?
    public let fallbackX: Int
    public let fallbackY: Int
    /// Normalized selection rect `[x, y, width, height]` in top-left `0...1` coordinates.
    public let normalizedRect: [Double]

    public init(
        resourceId: String?,
        className: String?,
        text: String?,
        contentDesc: String?,
        fallbackX: Int,
        fallbackY: Int,
        normalizedRect: [Double]
    ) {
        self.resourceId = resourceId?.isEmpty == true ? nil : resourceId
        self.className = className?.isEmpty == true ? nil : className
        self.text = text?.isEmpty == true ? nil : text
        self.contentDesc = contentDesc?.isEmpty == true ? nil : contentDesc
        self.fallbackX = fallbackX
        self.fallbackY = fallbackY
        self.normalizedRect = normalizedRect
    }

    public var cgNormalizedRect: CGRect {
        guard normalizedRect.count == 4 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: max(0, min(1, normalizedRect[0])),
            y: max(0, min(1, normalizedRect[1])),
            width: max(0.01, min(1, normalizedRect[2])),
            height: max(0.01, min(1, normalizedRect[3]))
        )
    }
}

/// User-defined parameter for a custom MCP tool.
public struct CustomMCPParameter: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String // "string" | "integer" | "boolean"
    public var description: String
    public var required: Bool

    public init(name: String, type: String = "string", description: String = "", required: Bool = true) {
        self.name = name
        self.type = Self.allowedTypes.contains(type) ? type : "string"
        self.description = description
        self.required = required
    }

    public static let allowedTypes: [String] = ["string", "integer", "boolean"]
}

/// Persisted schema for a Visual-to-MCP tool saved under `~/.andonmac/mcp_tools/<name>.json`.
public struct CustomMCPToolSchema: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let appPackageHint: String?
    public var isEnabled: Bool
    public let action: VisualMCPActionType
    public let target: VisualNodeTarget
    public let parameters: [CustomMCPParameter]
    public let createdAt: Date

    public init(
        name: String,
        description: String,
        appPackageHint: String? = nil,
        isEnabled: Bool = true,
        action: VisualMCPActionType,
        target: VisualNodeTarget,
        parameters: [CustomMCPParameter] = [],
        createdAt: Date = Date()
    ) {
        self.name = name
        self.description = description
        self.appPackageHint = appPackageHint?.isEmpty == true ? nil : appPackageHint
        self.isEnabled = isEnabled
        self.action = action
        self.target = target
        self.parameters = parameters
        self.createdAt = createdAt
    }

    /// Validates tool name against `^[a-z][a-z0-9_]{1,63}$` and prevents collisions with built-in tools.
    public static func isValidToolName(_ rawName: String) -> Bool {
        guard rawName.count >= 2, rawName.count <= 64 else { return false }
        let pattern = "^[a-z][a-z0-9_]{1,63}$"
        guard rawName.range(of: pattern, options: .regularExpression) != nil else { return false }
        let builtInNames = Set(AndroidMCPTools.allDefinitions.map(\.name))
        return !builtInNames.contains(rawName)
    }

    /// Validates parameter name against `^[a-z][a-z0-9_]{0,31}$` and reserves `serial`.
    public static func isValidParameterName(_ rawName: String) -> Bool {
        guard rawName != "serial", !rawName.isEmpty, rawName.count <= 32 else { return false }
        let pattern = "^[a-z][a-z0-9_]{0,31}$"
        return rawName.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validates the full schema (name, parameter names, normalized rect bounds).
    public func validate() throws {
        guard Self.isValidToolName(name) else {
            throw NSError(
                domain: "CustomMCPToolSchema",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tool name '\(name)'. Use 2-64 lowercase letters, digits, or underscores, without colliding with built-in tools."]
            )
        }
        guard target.normalizedRect.count == 4 else {
            throw NSError(
                domain: "CustomMCPToolSchema",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Target normalizedRect must contain 4 numbers [x, y, width, height]."]
            )
        }
        var seenParams = Set<String>()
        for param in parameters {
            guard Self.isValidParameterName(param.name), seenParams.insert(param.name).inserted else {
                throw NSError(
                    domain: "CustomMCPToolSchema",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid or duplicate parameter name '\(param.name)'."]
                )
            }
        }
    }

    /// Converts this custom visual tool into a standard JSON-RPC 2.0 MCP Tool definition.
    public func toMCPToolDefinition() -> MCPToolDefinition {
        var properties: [String: MCPJSONValue] = [
            "serial": .object([
                "type": .string("string"),
                "description": .string("Optional ADB device serial.")
            ])
        ]
        var requiredList: [MCPJSONValue] = []

        var effectiveParams = parameters
        if action == .typeText && !effectiveParams.contains(where: { $0.name == "text" }) {
            effectiveParams.insert(
                CustomMCPParameter(
                    name: "text",
                    type: "string",
                    description: "Text to type into the target Android field.",
                    required: true
                ),
                at: 0
            )
        }

        for param in effectiveParams {
            properties[param.name] = .object([
                "type": .string(param.type),
                "description": .string(param.description.isEmpty ? "Parameter \(param.name)" : param.description)
            ])
            if param.required {
                requiredList.append(.string(param.name))
            }
        }

        var schemaDict: [String: MCPJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !requiredList.isEmpty {
            schemaDict["required"] = .array(requiredList)
        }

        return MCPToolDefinition(
            name: name,
            description: description.isEmpty ? action.localizedTitle(lang: .english) : description,
            inputSchema: .object(schemaDict)
        )
    }
}
