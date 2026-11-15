import Foundation
import AppKit

/// Executes user-created or community-imported `CustomMCPToolSchema` definitions safely via ADB & Vision OCR.
public enum CustomMCPToolExecutor {

    public static func execute(
        schema: CustomMCPToolSchema,
        arguments: [String: MCPJSONValue]
    ) async -> MCPToolResult {
        do {
            try schema.validate()
            let serial = try await AndroidMCPTools.resolveSerial(arguments["serial"]?.stringValue)

            switch schema.action {
            case .readTextUIAutomator:
                return try await readTextUIAutomator(serial: serial, target: schema.target)
            case .readTextOCR:
                return try await readTextOCR(serial: serial, target: schema.target)
            case .tapElement:
                return try await tapElement(serial: serial, target: schema.target)
            case .typeText:
                return try await typeText(serial: serial, schema: schema, arguments: arguments)
            }
        } catch {
            return .text("Error executing '\(schema.name)': \(error.localizedDescription)", isError: true)
        }
    }

    private static func readTextUIAutomator(serial: String, target: VisualNodeTarget) async throws -> MCPToolResult {
        let nodes = try await AndroidMCPTools.fetchUITree(serial: serial)
        guard let matched = resolveLiveNode(from: nodes, target: target) else {
            return .text("Target UI element not found on current Android screen.", isError: true)
        }
        let value = !matched.text.isEmpty ? matched.text : matched.content_desc
        if value.isEmpty {
            return .text("(Element found at (\(matched.center_x), \(matched.center_y)), but it contains no text or content-desc.)")
        }
        return .text(value)
    }

    private static func readTextOCR(serial: String, target: VisualNodeTarget) async throws -> MCPToolResult {
        let cgImage: CGImage
        if let liveFrame = ScrcpyClient.shared.latestFrameImage {
            cgImage = liveFrame
        } else {
            let pngData = try await ADBService.shared.executeData(
                arguments: ["-s", serial, "exec-out", "screencap", "-p"],
                timeoutSeconds: 10.0
            )
            guard let nsImage = NSImage(data: pngData),
                  let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return .text("Failed to decode Android screenshot for Vision OCR.", isError: true)
            }
            cgImage = image
        }

        let extracted = try await VisionOCRService.shared.recognizeText(
            in: cgImage,
            normalizedCropRect: target.cgNormalizedRect
        )
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return .text(trimmed.isEmpty ? "(No text recognized in target region.)" : trimmed)
    }

    private static func tapElement(serial: String, target: VisualNodeTarget) async throws -> MCPToolResult {
        let tapPoint = await resolveTapPoint(serial: serial, target: target)
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "tap", "\(tapPoint.x)", "\(tapPoint.y)"],
            timeoutSeconds: 5.0
        )
        let label = target.resourceId ?? target.text ?? target.contentDesc ?? "(\(tapPoint.x), \(tapPoint.y))"
        return .text("Tapped '\(label)' at (\(tapPoint.x), \(tapPoint.y)).")
    }

    private static func typeText(
        serial: String,
        schema: CustomMCPToolSchema,
        arguments: [String: MCPJSONValue]
    ) async throws -> MCPToolResult {
        let firstParamName = schema.parameters.first?.name
        let textValue = arguments["text"]?.stringValue
            ?? (firstParamName.flatMap { arguments[$0]?.stringValue })
            ?? ""
        guard !textValue.isEmpty else {
            return .text("Missing text argument for '\(schema.name)'.", isError: true)
        }

        // Focus target field first
        let tapPoint = await resolveTapPoint(serial: serial, target: schema.target)
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "tap", "\(tapPoint.x)", "\(tapPoint.y)"],
            timeoutSeconds: 5.0
        )

        let cmd = AndroidMCPTools.buildSafeTypeTextCommand(textValue)
        if cmd.useClipboard {
            _ = try? await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", "text", cmd.quotedArg],
                timeoutSeconds: 4.0
            )
            _ = try await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "input", "keyevent", "279"],
                timeoutSeconds: 4.0
            )
        } else {
            _ = try await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg],
                timeoutSeconds: 5.0
            )
        }
        return .text("Typed \(textValue.count) characters into '\(schema.name)'.")
    }

    private static func resolveTapPoint(serial: String, target: VisualNodeTarget) async -> (x: Int, y: Int) {
        if let nodes = try? await AndroidMCPTools.fetchUITree(serial: serial),
           let live = resolveLiveNode(from: nodes, target: target) {
            return (live.center_x, live.center_y)
        }
        return (target.fallbackX, target.fallbackY)
    }

    /// Resolves the best live `AndroidUINode` matching `target` by semantic ID, content-desc, text, or proximity.
    public static func resolveLiveNode(from nodes: [AndroidUINode], target: VisualNodeTarget) -> AndroidUINode? {
        if let rid = target.resourceId, !rid.isEmpty {
            let matches = nodes.filter { $0.resource_id == rid }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if let desc = target.contentDesc, !desc.isEmpty {
            let matches = nodes.filter { $0.content_desc.localizedCaseInsensitiveContains(desc) }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if let text = target.text, !text.isEmpty {
            let matches = nodes.filter { $0.text.localizedCaseInsensitiveContains(text) }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        if let cls = target.className, !cls.isEmpty {
            let matches = nodes.filter { $0.class == cls }
            if let closest = closestNode(in: matches, toX: target.fallbackX, y: target.fallbackY) {
                return closest
            }
        }
        return nil
    }

    private static func closestNode(in candidates: [AndroidUINode], toX x: Int, y: Int) -> AndroidUINode? {
        candidates.min { a, b in
            let distA = (a.center_x - x) * (a.center_x - x) + (a.center_y - y) * (a.center_y - y)
            let distB = (b.center_x - x) * (b.center_x - x) + (b.center_y - y) * (b.center_y - y)
            return distA < distB
        }
    }
}
