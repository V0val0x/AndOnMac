import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct AndroidNotificationSummary: Codable, Sendable, Equatable {
    public let package: String
    public let title: String
    public let text: String
    public let timestamp: String
}

/// Implements all 9 semantic Android UI & control tools exposed via MCP.
public enum AndroidMCPTools {
    public static let allDefinitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "android_list_devices",
            description: "List connected USB and Wi-Fi Android devices with serial, model name, screen resolution, and battery level.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),
        MCPToolDefinition(
            name: "android_get_ui_tree",
            description: "Dump the live Android UI accessibility hierarchy as a compact JSON array of interactive/meaningful elements with bounds and pre-computed center_x/center_y coordinates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string"), "description": .string("Optional ADB device serial; defaults to first connected device.")])
                ])
            ])
        ),
        MCPToolDefinition(
            name: "android_screenshot",
            description: "Capture the current Android screen as a downscaled PNG image (max 1080px height) for visual inspection.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string"), "description": .string("Optional ADB device serial.")])
                ])
            ])
        ),
        MCPToolDefinition(
            name: "android_tap_element",
            description: "Tap the Android screen either by explicit (x, y) pixel coordinates OR semantically by matching text, resource_id, or content_desc from the current UI tree.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")]),
                    "x": .object(["type": .string("integer"), "description": .string("Explicit X coordinate")]),
                    "y": .object(["type": .string("integer"), "description": .string("Explicit Y coordinate")]),
                    "text": .object(["type": .string("string"), "description": .string("Case-insensitive text match")]),
                    "resource_id": .object(["type": .string("string"), "description": .string("Partial or full resource-id match")]),
                    "content_desc": .object(["type": .string("string"), "description": .string("Case-insensitive content-desc match")])
                ])
            ])
        ),
        MCPToolDefinition(
            name: "android_swipe",
            description: "Perform a directional swipe (up, down, left, right) or custom (x1, y1) -> (x2, y2) gesture with configurable duration_ms.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")]),
                    "direction": .object(["type": .string("string"), "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])]),
                    "x1": .object(["type": .string("integer")]),
                    "y1": .object(["type": .string("integer")]),
                    "x2": .object(["type": .string("integer")]),
                    "y2": .object(["type": .string("integer")]),
                    "duration_ms": .object(["type": .string("integer"), "description": .string("Swipe duration in milliseconds (default 300).")])
                ])
            ])
        ),
        MCPToolDefinition(
            name: "android_type_text",
            description: "Type text into the focused Android input field (handles spaces, special chars, and Unicode/Cyrillic via clipboard paste fallback) with optional press_enter.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")]),
                    "press_enter": .object(["type": .string("boolean")])
                ]),
                "required": .array([.string("text")])
            ])
        ),
        MCPToolDefinition(
            name: "android_keyevent",
            description: "Send a system navigation or media keyevent (BACK, HOME, RECENTS, ENTER, DELETE, VOLUME_UP, VOLUME_DOWN, WAKEUP).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")]),
                    "key": .object([
                        "type": .string("string"),
                        "enum": .array([.string("BACK"), .string("HOME"), .string("RECENTS"), .string("ENTER"), .string("DELETE"), .string("VOLUME_UP"), .string("VOLUME_DOWN"), .string("WAKEUP")])
                    ])
                ]),
                "required": .array([.string("key")])
            ])
        ),
        MCPToolDefinition(
            name: "android_launch_app",
            description: "Launch an Android app by exact package name (e.g. com.whatsapp) or fuzzy-matching human-readable app label (e.g. WhatsApp, Telegram).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")]),
                    "app": .object(["type": .string("string"), "description": .string("Package name or app display name.")])
                ]),
                "required": .array([.string("app")])
            ])
        ),
        MCPToolDefinition(
            name: "android_get_notifications",
            description: "Read active Android status bar notifications (useful for 2FA codes and incoming messages).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string")])
                ])
            ])
        )
    ]

    public static func execute(name: String, arguments: [String: MCPJSONValue]) async -> MCPToolResult {
        do {
            switch name {
            case "android_list_devices":
                return try await listDevices()
            case "android_get_ui_tree":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                let nodes = try await fetchUITree(serial: serial)
                return .text(try encodeJSON(nodes))
            case "android_screenshot":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await captureScreenshot(serial: serial)
            case "android_tap_element":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await tapElement(serial: serial, args: arguments)
            case "android_swipe":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await swipe(serial: serial, args: arguments)
            case "android_type_text":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await typeText(serial: serial, args: arguments)
            case "android_keyevent":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await sendKeyevent(serial: serial, args: arguments)
            case "android_launch_app":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await launchApp(serial: serial, args: arguments)
            case "android_get_notifications":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                let output = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "dumpsys", "notification", "--noredact"], timeoutSeconds: 8.0)
                let items = parseNotifications(from: output)
                return .text(try encodeJSON(items))
            default:
                return .text("Unknown tool: \(name)", isError: true)
            }
        } catch {
            return .text("Error executing \(name): \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Tool Implementations

    public static func resolveSerial(_ requested: String?) async throws -> String {
        if let requested, !requested.isEmpty {
            guard ADBService.validateSerial(requested) else {
                throw NSError(domain: "AndroidMCPTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid serial: \(requested)"])
            }
            return requested
        }
        let devices = await ADBService.shared.listDevices()
        guard let first = devices.first(where: { $0.state == .ready || $0.state == .mirroring }) ?? devices.first else {
            throw NSError(domain: "AndroidMCPTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "No Android devices connected via ADB."])
        }
        return first.id
    }

    private static func listDevices() async throws -> MCPToolResult {
        let devices = await ADBService.shared.listDevices()
        var rows: [[String: MCPJSONValue]] = []
        for dev in devices {
            let wmSize = (try? await ADBService.shared.execute(arguments: ["-s", dev.id, "shell", "wm", "size"], timeoutSeconds: 3.0))?
                .replacingOccurrences(of: "Physical size:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let batteryVal: MCPJSONValue = dev.batteryLevel.map { MCPJSONValue.int($0) } ?? .null
            let row: [String: MCPJSONValue] = [
                "serial": .string(dev.id),
                "model": .string(dev.displayName),
                "connection": .string(dev.connectionType.rawValue),
                "resolution": .string(wmSize),
                "battery": batteryVal
            ]
            rows.append(row)
        }
        let data = try JSONEncoder().encode(MCPJSONValue.array(rows.map { .object($0) }))
        return .text(String(decoding: data, as: UTF8.self))
    }

    public static func fetchUITree(serial: String) async throws -> [AndroidUINode] {
        var xml = (try? await ADBService.shared.execute(arguments: ["-s", serial, "exec-out", "uiautomator", "dump", "/dev/tty"], timeoutSeconds: 8.0)) ?? ""
        if !xml.contains("<hierarchy") {
            let remoteDump = "/sdcard/window_dump.xml"
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "uiautomator", "dump", remoteDump], timeoutSeconds: 8.0)
            xml = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cat", remoteDump], timeoutSeconds: 6.0)
            _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "rm", "-f", remoteDump], timeoutSeconds: 3.0)
        }
        return AndroidUITreeParser.parse(xmlString: xml)
    }

    private static func captureScreenshot(serial: String) async throws -> MCPToolResult {
        let rawPNG = try await ADBService.shared.executeData(arguments: ["-s", serial, "exec-out", "screencap", "-p"], timeoutSeconds: 10.0)
        let scaledPNG = downscalePNGIfNeeded(rawPNG, maxHeight: 1080) ?? rawPNG
        return MCPToolResult(content: [.image(base64: scaledPNG.base64EncodedString(), mimeType: "image/png")])
    }

    /// Proportionally downscales PNG bytes so height <= `maxHeight` to minimize LLM vision token cost.
    public static func downscalePNGIfNeeded(_ data: Data, maxHeight: Int = 1080) -> Data? {
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            guard image.height > maxHeight, image.height > 0 else { return data }

            let scale = CGFloat(maxHeight) / CGFloat(image.height)
            let targetW = max(1, Int(CGFloat(image.width) * scale))
            let targetH = maxHeight

            guard let ctx = CGContext(
                data: nil,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return data }

            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            guard let scaledImage = ctx.makeImage() else { return data }

            let outData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else { return data }
            CGImageDestinationAddImage(dest, scaledImage, nil)
            guard CGImageDestinationFinalize(dest) else { return data }
            return outData as Data
        }
    }

    private static func tapElement(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        if let x = args["x"]?.intValue, let y = args["y"]?.intValue {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "tap", "\(x)", "\(y)"], timeoutSeconds: 5.0)
            return .text("Tapped at (\(x), \(y)).")
        }

        let textQuery = args["text"]?.stringValue?.lowercased()
        let idQuery = args["resource_id"]?.stringValue?.lowercased()
        let descQuery = args["content_desc"]?.stringValue?.lowercased()

        guard textQuery != nil || idQuery != nil || descQuery != nil else {
            return .text("Provide either (x, y) or one of text, resource_id, content_desc.", isError: true)
        }

        let nodes = try await fetchUITree(serial: serial)
        let match = nodes.first { node in
            if let t = textQuery, !node.text.lowercased().contains(t) { return false }
            if let r = idQuery, !node.resource_id.lowercased().contains(r) { return false }
            if let d = descQuery, !node.content_desc.lowercased().contains(d) { return false }
            return true
        }

        guard let target = match else {
            return .text("No matching UI element found in current hierarchy.", isError: true)
        }

        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "tap", "\(target.center_x)", "\(target.center_y)"],
            timeoutSeconds: 5.0
        )
        return .text("Tapped '\(target.text.isEmpty ? target.content_desc : target.text)' at (\(target.center_x), \(target.center_y)).")
    }

    private static func swipe(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        let duration = max(50, min(3000, args["duration_ms"]?.intValue ?? 300))
        let x1, y1, x2, y2: Int
        if let dir = args["direction"]?.stringValue {
            switch dir {
            case "up": (x1, y1, x2, y2) = (540, 1700, 540, 600)
            case "down": (x1, y1, x2, y2) = (540, 600, 540, 1700)
            case "left": (x1, y1, x2, y2) = (900, 1200, 180, 1200)
            case "right": (x1, y1, x2, y2) = (180, 1200, 900, 1200)
            default: (x1, y1, x2, y2) = (540, 1500, 540, 700)
            }
        } else if let ax1 = args["x1"]?.intValue, let ay1 = args["y1"]?.intValue,
                  let ax2 = args["x2"]?.intValue, let ay2 = args["y2"]?.intValue {
            (x1, y1, x2, y2) = (ax1, ay1, ax2, ay2)
        } else {
            return .text("Provide either direction or (x1, y1, x2, y2).", isError: true)
        }

        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(duration)"],
            timeoutSeconds: 6.0
        )
        return .text("Swiped (\(x1),\(y1)) -> (\(x2),\(y2)) in \(duration)ms.")
    }

    /// Builds injection-safe `adb shell` text arguments for `android_type_text`.
    /// Both ASCII (`input text`) and Unicode (`cmd clipboard set`) paths are strictly POSIX single-quoted
    /// so Android `/system/bin/sh` never evaluates `;`, `|`, `&`, `$()`, backticks, redirects, or newlines.
    public static func buildSafeTypeTextCommand(_ rawText: String) -> (useClipboard: Bool, quotedArg: String) {
        let sanitized = rawText.replacingOccurrences(of: "\0", with: "")
        let isSimpleASCII = sanitized.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F
        }
        if isSimpleASCII {
            let spaceEncoded = sanitized.replacingOccurrences(of: " ", with: "%s")
            return (false, ADBService.shellQuote(spaceEncoded))
        } else {
            return (true, ADBService.shellQuote(sanitized))
        }
    }

    private static func typeText(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            return .text("Missing 'text' parameter.", isError: true)
        }
        let pressEnter = args["press_enter"]?.boolValue ?? false
        let cmd = buildSafeTypeTextCommand(text)

        if !cmd.useClipboard {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg], timeoutSeconds: 6.0)
        } else {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", cmd.quotedArg], timeoutSeconds: 4.0)
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "keyevent", "279"], timeoutSeconds: 4.0)
        }

        if pressEnter {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "keyevent", "66"], timeoutSeconds: 4.0)
        }
        return .text("Typed \(text.count) characters\(pressEnter ? " + ENTER" : "").")
    }

    private static func sendKeyevent(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        guard let key = args["key"]?.stringValue else {
            return .text("Missing 'key' parameter.", isError: true)
        }
        let map: [String: String] = [
            "BACK": "4",
            "HOME": "3",
            "RECENTS": "187",
            "ENTER": "66",
            "DELETE": "67",
            "VOLUME_UP": "24",
            "VOLUME_DOWN": "25",
            "WAKEUP": "224"
        ]
        guard let code = map[key.uppercased()] else {
            return .text("Unsupported keyevent: \(key)", isError: true)
        }
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "keyevent", code], timeoutSeconds: 4.0)
        return .text("Sent keyevent \(key.uppercased()) (\(code)).")
    }

    private static func launchApp(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        guard let query = args["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return .text("Missing 'app' parameter.", isError: true)
        }

        let targetPackage: String
        if query.contains(".") && !query.contains(" ") {
            targetPackage = query
        } else {
            let apps = try await AndroidAppLauncherService.shared.fetchInstalledApps(serial: serial)
            if let match = apps.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(query) ||
                $0.packageName.localizedCaseInsensitiveContains(query)
            }) {
                targetPackage = match.packageName
            } else {
                return .text("Could not find installed app matching '\(query)'.", isError: true)
            }
        }

        guard ADBService.validatePackageName(targetPackage) else {
            return .text("Invalid Android package name: '\(targetPackage)'.", isError: true)
        }

        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
            timeoutSeconds: 6.0
        )
        return .text("Launched \(targetPackage).")
    }

    /// Parses `dumpsys notification --noredact` into clean notification summaries.
    public static func parseNotifications(from dumpsysOutput: String) -> [AndroidNotificationSummary] {
        var results: [AndroidNotificationSummary] = []
        var currentPackage: String?
        var currentTitle: String?
        var currentText: String?
        var currentTime: String?

        func flushCurrent() {
            guard let pkg = currentPackage else { return }
            let title = currentTitle ?? ""
            let text = currentText ?? ""
            if !title.isEmpty || !text.isEmpty {
                results.append(AndroidNotificationSummary(
                    package: pkg,
                    title: title,
                    text: text,
                    timestamp: currentTime ?? ""
                ))
            }
            currentPackage = nil
            currentTitle = nil
            currentText = nil
            currentTime = nil
        }

        for rawLine in dumpsysOutput.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NotificationRecord(") {
                flushCurrent()
                if let pkgRange = line.range(of: "pkg="),
                   let after = line[pkgRange.upperBound...].split(separator: " ").first {
                    currentPackage = String(after)
                }
            } else if line.hasPrefix("android.title=") {
                currentTitle = extractNotificationValue(from: line, key: "android.title=")
            } else if line.hasPrefix("android.text=") {
                currentText = extractNotificationValue(from: line, key: "android.text=")
            } else if line.hasPrefix("when=") {
                currentTime = String(line.dropFirst("when=".count))
            }
        }
        flushCurrent()
        return Array(results.prefix(25))
    }

    private static func extractNotificationValue(from line: String, key: String) -> String {
        let rest = String(line.dropFirst(key.count))
        if let openParen = rest.firstIndex(of: "("), rest.hasSuffix(")") {
            let inner = rest[rest.index(after: openParen)..<rest.index(before: rest.endIndex)]
            return String(inner)
        }
        return rest
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
