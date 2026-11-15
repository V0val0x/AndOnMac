import Foundation

/// Shared execution limits & defaults for Visual MCP macros and Self-Healing Vision OCR (backed by General Settings).
public enum MCPExecutionDefaults {
    public static let stepDelayKey = "macroDefaultStepDelayMs"
    public static let maxStepsKey = "macroMaxSteps"
    public static let maxDurationKey = "macroMaxTotalWaitSeconds"
    public static let selfHealingKey = "mcpSelfHealingEnabled"

    public static let defaultStepDelayMs = 450
    public static let minStepDelayMs = 50
    public static let maxStepDelayMs = 5000

    public static let defaultMaxSteps = 20
    public static let minMaxSteps = 1
    public static let maxMaxSteps = 50

    public static let defaultMaxDurationSeconds = 15
    public static let minMaxDurationSeconds = 3
    public static let maxMaxDurationSeconds = 120

    public static let defaultSelfHealingEnabled = true

    public static func currentStepDelayMs(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: stepDelayKey) as? Int else { return defaultStepDelayMs }
        return max(minStepDelayMs, min(maxStepDelayMs, raw))
    }

    public static func currentMaxSteps(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: maxStepsKey) as? Int else { return defaultMaxSteps }
        return max(minMaxSteps, min(maxMaxSteps, raw))
    }

    public static func currentMaxDurationSeconds(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: maxDurationKey) as? Int else { return defaultMaxDurationSeconds }
        return max(minMaxDurationSeconds, min(maxMaxDurationSeconds, raw))
    }

    public static func isSelfHealingEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(forKey: selfHealingKey) as? Bool else { return defaultSelfHealingEnabled }
        return raw
    }
}

/// Allow-listed Android UI actions executable by user-created or community-imported visual MCP tools.
public enum VisualMCPActionType: String, Codable, Sendable, CaseIterable, Identifiable {
    case readTextUIAutomator = "read_text_uiautomator"
    case readTextOCR = "read_text_ocr"
    case tapElement = "tap_element"
    case typeText = "type_text"
    case macro = "macro"

    public var id: String { rawValue }

    /// Actions valid as individual steps inside a multi-step macro (never nested macros).
    public static var singleStepCases: [VisualMCPActionType] {
        [.tapElement, .typeText, .readTextUIAutomator, .readTextOCR]
    }

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
        case .macro:
            return L10n.tr("Многошаговый макрос", "Multi-Step Macro", lang: lang)
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

/// Single recorded step in a multi-step Visual-to-MCP macro.
public struct VisualMacroStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var action: VisualMCPActionType
    public var target: VisualNodeTarget
    /// Optional text or template string (e.g. `"{{message_body}}"` or `"hello"`) for `.typeText` steps.
    public var textTemplate: String?
    /// Implicit UI transition delay after executing this step; `nil` inherits the tool or global default.
    public var delayAfterMs: Int?

    public init(
        id: UUID = UUID(),
        action: VisualMCPActionType,
        target: VisualNodeTarget,
        textTemplate: String? = nil,
        delayAfterMs: Int? = nil
    ) {
        self.id = id
        self.action = action == .macro ? .tapElement : action
        self.target = target
        self.textTemplate = textTemplate?.isEmpty == true ? nil : textTemplate
        self.delayAfterMs = delayAfterMs.map { max(0, min(MCPExecutionDefaults.maxStepDelayMs, $0)) }
    }
}

/// Persisted schema for a Visual-to-MCP tool or multi-step macro saved under `~/.andonmac/mcp_tools/<name>.json`.
public struct CustomMCPToolSchema: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let appPackageHint: String?
    public var isEnabled: Bool
    public let action: VisualMCPActionType
    public let target: VisualNodeTarget
    public let parameters: [CustomMCPParameter]
    public var steps: [VisualMacroStep]?
    /// Optional per-tool overrides (`nil` inherits General Settings).
    public var defaultStepDelayMs: Int?
    public var maxSteps: Int?
    public var maxDurationSeconds: Int?
    public var selfHealingEnabled: Bool?
    public let createdAt: Date

    public init(
        name: String,
        description: String,
        appPackageHint: String? = nil,
        isEnabled: Bool = true,
        action: VisualMCPActionType,
        target: VisualNodeTarget,
        parameters: [CustomMCPParameter] = [],
        steps: [VisualMacroStep]? = nil,
        defaultStepDelayMs: Int? = nil,
        maxSteps: Int? = nil,
        maxDurationSeconds: Int? = nil,
        selfHealingEnabled: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.description = description
        self.appPackageHint = appPackageHint?.isEmpty == true ? nil : appPackageHint
        self.isEnabled = isEnabled
        self.action = action
        self.target = target
        self.parameters = parameters
        self.steps = steps
        self.defaultStepDelayMs = defaultStepDelayMs
        self.maxSteps = maxSteps
        self.maxDurationSeconds = maxDurationSeconds
        self.selfHealingEnabled = selfHealingEnabled
        self.createdAt = createdAt
    }

    public func effectiveStepDelayMs(defaults: UserDefaults = .standard) -> Int {
        let base = defaultStepDelayMs ?? MCPExecutionDefaults.currentStepDelayMs(defaults: defaults)
        return max(MCPExecutionDefaults.minStepDelayMs, min(MCPExecutionDefaults.maxStepDelayMs, base))
    }

    public func effectiveMaxSteps(defaults: UserDefaults = .standard) -> Int {
        let base = maxSteps ?? MCPExecutionDefaults.currentMaxSteps(defaults: defaults)
        return max(MCPExecutionDefaults.minMaxSteps, min(MCPExecutionDefaults.maxMaxSteps, base))
    }

    public func effectiveMaxDurationSeconds(defaults: UserDefaults = .standard) -> Int {
        let base = maxDurationSeconds ?? MCPExecutionDefaults.currentMaxDurationSeconds(defaults: defaults)
        return max(MCPExecutionDefaults.minMaxDurationSeconds, min(MCPExecutionDefaults.maxMaxDurationSeconds, base))
    }

    public func effectiveSelfHealingEnabled(defaults: UserDefaults = .standard) -> Bool {
        selfHealingEnabled ?? MCPExecutionDefaults.isSelfHealingEnabled(defaults: defaults)
    }

    /// Extracts all unique valid `{{param_name}}` placeholder names across macro steps.
    public static func extractPlaceholderNames(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([a-z][a-z0-9_]{0,31})\\}\\}") else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var ordered: [String] = []
        var seen = Set<String>()
        for match in matches where match.numberOfRanges >= 2 {
            let name = nsText.substring(with: match.range(at: 1))
            if isValidParameterName(name), seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    public func extractTemplateParameterNames() -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for step in steps ?? [] {
            if let tpl = step.textTemplate {
                for name in Self.extractPlaceholderNames(from: tpl) where seen.insert(name).inserted {
                    ordered.append(name)
                }
            }
        }
        return ordered
    }

    /// Resolves `{{param_name}}` placeholders using incoming MCP tool arguments.
    public static func interpolateTemplate(_ template: String, arguments: [String: MCPJSONValue]) -> String {
        var resolved = template
        for placeholder in extractPlaceholderNames(from: template) {
            let replacement: String
            if let str = arguments[placeholder]?.stringValue {
                replacement = str
            } else if let intVal = arguments[placeholder]?.intValue {
                replacement = String(intVal)
            } else if let boolVal = arguments[placeholder]?.boolValue {
                replacement = boolVal ? "true" : "false"
            } else {
                continue
            }
            resolved = resolved.replacingOccurrences(of: "{{\(placeholder)}}", with: replacement)
        }
        return resolved
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

    /// Validates the full schema (name, parameter names, normalized rect bounds, and macro steps).
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
        if action == .macro {
            guard let steps, !steps.isEmpty else {
                throw NSError(
                    domain: "CustomMCPToolSchema",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Macro tool '\(name)' must contain at least one step."]
                )
            }
            for step in steps {
                guard step.target.normalizedRect.count == 4 else {
                    throw NSError(
                        domain: "CustomMCPToolSchema",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Each macro step's normalizedRect must contain 4 numbers."]
                    )
                }
            }
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

        // Auto-expose any {{param_name}} placeholders referenced by macro steps
        if action == .macro {
            for placeholder in extractTemplateParameterNames()
            where !effectiveParams.contains(where: { $0.name == placeholder }) {
                effectiveParams.append(
                    CustomMCPParameter(
                        name: placeholder,
                        type: "string",
                        description: "Dynamic input substituted into {{\(placeholder)}}.",
                        required: true
                    )
                )
            }
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
