import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AndroidShadowGraphKit

public struct AndroidNotificationSummary: Codable, Sendable, Equatable {
    public let package: String
    public let title: String
    public let text: String
    public let timestamp: String
}

/// Implements all 11 semantic Android UI & control tools exposed via MCP.
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
        ),
        MCPToolDefinition(
            name: "android_navigate_to_node",
            description: "Autonomously navigate across known Android UI screens using the Shadow Graph A* router without intermediate LLM roundtrips, verifying each step against the live Shadow DOM.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string"), "description": .string("Optional ADB device serial.")]),
                    "target": .object(["type": .string("string"), "description": .string("Semantic destination hint (package name, screen title, label, or resource_id). Required unless target_hash is provided.")]),
                    "target_hash": .object(["type": .string("string"), "description": .string("Optional hex (0x...) or decimal UInt64 layoutHash for exact vertex pinning.")]),
                    "max_steps": .object(["type": .string("integer"), "description": .string("Maximum transition hops allowed (default 12).")]),
                    "step_timeout_ms": .object(["type": .string("integer"), "description": .string("Per-step Shadow DOM settle timeout in milliseconds (default 2000).")]),
                    "confirmed": .object(["type": .string("boolean"), "description": .string("Set to true ONLY after explicit user confirmation in chat to allow irreversible/hazardous actions (payment, purchase, delete). Default: false.")]),
                    "auto_explore": .object(["type": .string("boolean"), "description": .string("When true and no known graph route exists (no_route / target_not_found), automatically fall back to live Shadow DOM explore-and-click with bounded scrolling and DAG edge recording. Default: false.")])
                ])
            ])
        ),
        MCPToolDefinition(
            name: "android_explore_and_click",
            description: "Dynamic Shadow DOM discovery + click with optional A* graph/prefix routing, bounded list scrolling (down/up), hazardous action HITL guard, and automatic Spatial Graph edge recording. Returns top-20 PII-redacted interactive candidates (needs_selection, isError: false) if no confident match is found.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "serial": .object(["type": .string("string"), "description": .string("Optional ADB device serial.")]),
                    "target": .object(["type": .string("string"), "description": .string("Target UI label, resource_id suffix, content_desc, or breadcrumb path (e.g. 'Night Light', 'Display > Night Light').")]),
                    "max_scrolls": .object(["type": .string("integer"), "description": .string("Maximum bounded discovery scrolls (0-10). Default: 3.")]),
                    "step_timeout_ms": .object(["type": .string("integer"), "description": .string("Per-step Shadow DOM settle timeout in milliseconds (default 2000).")]),
                    "confirmed": .object(["type": .string("boolean"), "description": .string("Set to true ONLY after explicit user confirmation in chat to click hazardous/irreversible elements. Default: false.")]),
                    "prefer_graph_route": .object(["type": .string("boolean"), "description": .string("Try known A* graph route (or nearest known prefix vertex) before scanning live Shadow DOM. Default: true.")])
                ]),
                "required": .array([.string("target")])
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
            case "android_navigate_to_node":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await navigateToNode(serial: serial, args: arguments)
            case "android_explore_and_click":
                let serial = try await resolveSerial(arguments["serial"]?.stringValue)
                return try await exploreAndClick(serial: serial, args: arguments)
            default:
                return .text("Unknown tool: \(name)", isError: true)
            }
        } catch let deviation as PathDeviationError {
            return formatPathDeviationResult(deviation)
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
        await ShadowGraphManager.shared.ensureStarted(serial: serial)
        if let cached = await ShadowGraphManager.shared.fastCompactTreeIfFresh(
            maxWaitSeconds: 0.35,
            maxAgeSeconds: 15.0
        ) {
            return cached
        }
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
            await ShadowGraphManager.shared.ensureStarted(serial: serial)
            _ = await ShadowGraphManager.shared.bridge.client.waitForHello(maxWaitMs: 150)
            await ShadowGraphManager.shared.recordAction(
                AttributedUIAction(kind: .tap, targetDescription: "(\(x),\(y))", x: x, y: y)
            )
            try await ShadowGraphManager.shared.actionExecutor().dispatchTap(serial: serial, x: x, y: y)
            return .text("Tapped at (\(x), \(y)).")
        }

        let textRaw = args["text"]?.stringValue
        let idRaw = args["resource_id"]?.stringValue
        let descRaw = args["content_desc"]?.stringValue
        let textQuery = textRaw?.lowercased()
        let idQuery = idRaw?.lowercased()
        let descQuery = descRaw?.lowercased()

        guard textQuery != nil || idQuery != nil || descQuery != nil else {
            return .text("Provide either (x, y) or one of text, resource_id, content_desc.", isError: true)
        }

        await ShadowGraphManager.shared.ensureStarted(serial: serial)

        // Single-selector ShadowDOM fast path with exact/clickable scoring
        var shadowTarget: AndroidUINode?
        if let t = textRaw, idRaw == nil, descRaw == nil,
           let node = await ShadowGraphManager.shared.findNode(byText: t) {
            shadowTarget = node.toCompactNode()
        } else if let r = idRaw, textRaw == nil, descRaw == nil,
                  let node = await ShadowGraphManager.shared.findNode(byResourceID: r) {
            shadowTarget = node.toCompactNode()
        } else if let d = descRaw, textRaw == nil, idRaw == nil,
                  let node = await ShadowGraphManager.shared.findNode(byContentDesc: d) {
            shadowTarget = node.toCompactNode()
        }

        let target: AndroidUINode
        if let shadowTarget {
            target = shadowTarget
        } else {
            let nodes = try await fetchUITree(serial: serial)
            let match = nodes.first { node in
                if let t = textQuery, !node.text.lowercased().contains(t) { return false }
                if let r = idQuery, !node.resource_id.lowercased().contains(r) { return false }
                if let d = descQuery, !node.content_desc.lowercased().contains(d) { return false }
                return true
            }

            guard let found = match else {
                return .text("No matching UI element found in current hierarchy.", isError: true)
            }
            target = found
        }

        let actionLabel = !target.text.isEmpty
            ? target.text
            : (!target.content_desc.isEmpty ? target.content_desc : target.resource_id)
        await ShadowGraphManager.shared.recordAction(
            AttributedUIAction(
                kind: .tap,
                targetDescription: actionLabel,
                x: target.center_x,
                y: target.center_y,
                selectorResourceId: target.resource_id.isEmpty ? nil : target.resource_id,
                selectorText: target.text.isEmpty ? nil : target.text,
                selectorContentDesc: target.content_desc.isEmpty ? nil : target.content_desc
            )
        )

        try await ShadowGraphManager.shared.actionExecutor().dispatchTap(
            serial: serial,
            x: target.center_x,
            y: target.center_y
        )
        return .text("Tapped '\(target.text.isEmpty ? target.content_desc : target.text)' at (\(target.center_x), \(target.center_y)).")
    }

    private static func swipe(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        let explicitDuration = args["duration_ms"]?.intValue.map { max(50, min(3000, $0)) }
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

        await ShadowGraphManager.shared.ensureStarted(serial: serial)
        _ = await ShadowGraphManager.shared.bridge.client.waitForHello(maxWaitMs: 150)
        let executor = ShadowGraphManager.shared.actionExecutor()
        let zeroFling = await executor.supportsZeroFlingSwipes(serial: serial)
        let duration = explicitDuration ?? (zeroFling ? ADBMacroActionExecutor.defaultDaemonSwipeDurationMs : 300)
        await ShadowGraphManager.shared.recordAction(
            AttributedUIAction(
                kind: .swipe,
                targetDescription: args["direction"]?.stringValue ?? "(\(x1),\(y1))->(\(x2),\(y2))",
                x: x1,
                y: y1,
                endX: x2,
                endY: y2,
                durationMs: duration
            )
        )
        try await executor.dispatchSwipe(
            serial: serial,
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            durationMs: duration,
            holdMs: ADBMacroActionExecutor.defaultZeroFlingHoldMs
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
        await ShadowGraphManager.shared.ensureStarted(serial: serial)
        await ShadowGraphManager.shared.recordAction(
            AttributedUIAction(
                kind: .typeText,
                targetDescription: String(text.prefix(32)),
                textInput: text,
                pressEnter: pressEnter
            )
        )
        let cmd = buildSafeTypeTextCommand(text)

        let executor = ShadowGraphManager.shared.actionExecutor()
        if !cmd.useClipboard {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "input", "text", cmd.quotedArg], timeoutSeconds: 6.0)
        } else {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cmd", "clipboard", "set", cmd.quotedArg], timeoutSeconds: 4.0)
            try await executor.dispatchKeyeventCode(serial: serial, keyCode: "279")
        }

        if pressEnter {
            try await executor.dispatchKeyeventCode(serial: serial, keyCode: "66")
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
        await ShadowGraphManager.shared.ensureStarted(serial: serial)
        _ = await ShadowGraphManager.shared.bridge.client.waitForHello(maxWaitMs: 150)
        await ShadowGraphManager.shared.recordAction(
            AttributedUIAction(kind: .keyevent, targetDescription: key.uppercased())
        )
        try await ShadowGraphManager.shared.actionExecutor().dispatchKeyeventCode(serial: serial, keyCode: code)
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

        await ShadowGraphManager.shared.ensureStarted(serial: serial)
        await ShadowGraphManager.shared.recordAction(
            AttributedUIAction(kind: .launchApp, targetDescription: targetPackage)
        )
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "monkey", "-p", targetPackage, "-c", "android.intent.category.LAUNCHER", "1"],
            timeoutSeconds: 6.0
        )
        return .text("Launched \(targetPackage).")
    }

    private static func navigateToNode(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        let targetHint = args["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetHash = try parseLayoutHash(args["target_hash"])
        guard targetHash != nil || (targetHint?.isEmpty == false) else {
            return .text("Provide either 'target' or 'target_hash'.", isError: true)
        }

        let maxSteps = max(1, min(32, args["max_steps"]?.intValue ?? 12))
        let stepTimeoutMs = max(100, min(30_000, args["step_timeout_ms"]?.intValue ?? 2000))
        let confirmed = args["confirmed"]?.boolValue ?? false
        let autoExplore = args["auto_explore"]?.boolValue ?? false

        let outcome = try await ShadowGraphManager.shared.navigateToNode(
            serial: serial,
            target: targetHint,
            targetHash: targetHash,
            maxSteps: maxSteps,
            stepTimeoutMs: stepTimeoutMs,
            confirmed: confirmed,
            autoExplore: autoExplore
        )
        return formatNavigationOutcome(outcome)
    }

    private static func exploreAndClick(serial: String, args: [String: MCPJSONValue]) async throws -> MCPToolResult {
        guard let target = args["target"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return .text("Missing required 'target' parameter.", isError: true)
        }
        let maxScrolls = max(0, min(10, args["max_scrolls"]?.intValue ?? 3))
        let stepTimeoutMs = max(100, min(30_000, args["step_timeout_ms"]?.intValue ?? 2000))
        let confirmed = args["confirmed"]?.boolValue ?? false
        let preferGraphRoute = args["prefer_graph_route"]?.boolValue ?? true

        let outcome = try await ShadowGraphManager.shared.exploreAndClick(
            serial: serial,
            target: target,
            maxScrolls: maxScrolls,
            stepTimeoutMs: stepTimeoutMs,
            confirmed: confirmed,
            preferGraphRoute: preferGraphRoute
        )
        return formatExploreOutcome(outcome)
    }

    public static func parseLayoutHash(_ value: MCPJSONValue?) throws -> UInt64? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .int(let intVal):
            guard intVal >= 0 else {
                throw NSError(domain: "AndroidMCPTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid negative 'target_hash'."])
            }
            return UInt64(intVal)
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                let hex = String(trimmed.dropFirst(2))
                guard let parsed = UInt64(hex, radix: 16) else {
                    throw NSError(domain: "AndroidMCPTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid hex 'target_hash': \(trimmed)"])
                }
                return parsed
            }
            if let decimal = UInt64(trimmed, radix: 10) {
                return decimal
            }
            if let hex = UInt64(trimmed, radix: 16) {
                return hex
            }
            throw NSError(domain: "AndroidMCPTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid 'target_hash': \(trimmed)"])
        default:
            throw NSError(domain: "AndroidMCPTools", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid 'target_hash' type; expected string."])
        }
    }

    public static func formatNavigationOutcome(_ outcome: ShadowNavigationOutcome) -> MCPToolResult {
        func hex(_ hash: UInt64) -> String { String(format: "0x%016llx", hash) }

        switch outcome {
        case .arrived(let report):
            let summary: [MCPJSONValue] = report.steps.map { step in
                .object([
                    "step_index": .int(step.stepIndex),
                    "action": .string(step.actionSignature),
                    "target_hash": .string(hex(step.targetHash)),
                    "elapsed_ms": .int(step.elapsedMs),
                    "matched_by_exact_hash": .bool(step.matchedByExactHash),
                    "skipped": .bool(step.wasSkipped)
                ])
            }
            var obj: [String: MCPJSONValue] = [
                "status": .string("arrived"),
                "start_hash": .string(hex(report.startHash)),
                "target_hash": .string(hex(report.finalHash)),
                "steps_executed": .int(report.steps.count),
                "total_elapsed_ms": .int(report.totalElapsedMs),
                "path_summary": .array(summary)
            ]
            if !report.recoveredSteps.isEmpty {
                obj["recovered_steps"] = .array(report.recoveredSteps.map { .string($0) })
            }
            return .text(encodeJSONValue(.object(obj)), isError: false)

        case .alreadyAtTarget(let stateHash, let activePackage):
            let payload: MCPJSONValue = .object([
                "status": .string("already_at_target"),
                "current_hash": .string(hex(stateHash)),
                "active_package": .string(activePackage),
                "steps_executed": .int(0),
                "total_elapsed_ms": .int(0)
            ])
            return .text(encodeJSONValue(payload), isError: false)

        case .explored(let exploreOutcome):
            return formatExploreOutcome(exploreOutcome)

        case .requiresConfirmation(let req):
            let payload: MCPJSONValue = .object([
                "status": .string("requires_confirmation"),
                "is_hazardous": .bool(true),
                "hazard_category": .string(req.hazardCategory.rawValue),
                "hazard_reason": .string(req.hazardReason),
                "blocked_step_index": .int(req.stepIndex),
                "total_steps": .int(req.totalSteps),
                "steps_completed": .int(req.stepsCompleted),
                "blocked_action": .string(req.actionSignature),
                "target_description": .string(req.targetDescription),
                "current_hash": .string(hex(req.currentHash)),
                "target_hash": .string(hex(req.targetHash)),
                "message": .string("Irreversible action blocked awaiting human approval. Ask the user in chat to confirm, then re-run android_navigate_to_node with confirmed: true.")
            ])
            return .text(encodeJSONValue(payload), isError: false)

        case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
            let payload: MCPJSONValue = .object([
                "status": .string("secure_screen_active"),
                "code": .string("SECURE_SCREEN_ACTIVE"),
                "reason": .string(reason),
                "active_package": .string(activePackage),
                "timeout_seconds": .int(timeoutSeconds),
                "message": .string("Protected biometric/PIN screen remained locked past \(timeoutSeconds)s. Ask the user to unlock on the phone and retry.")
            ])
            return .text(encodeJSONValue(payload), isError: true)

        case .noRoute(let startHash, let activePackage, let candidates, let reachableCount, let knownCount):
            let payload: MCPJSONValue = .object([
                "status": .string("no_route"),
                "current_hash": .string(hex(startHash)),
                "active_package": .string(activePackage),
                "candidate_target_hashes": .array(candidates.map { .string(hex($0)) }),
                "reachable_vertex_count": .int(reachableCount),
                "known_vertex_count": .int(knownCount)
            ])
            return .text(encodeJSONValue(payload), isError: true)

        case .targetNotFound(let query, let knownCount):
            let payload: MCPJSONValue = .object([
                "status": .string("target_not_found"),
                "query": .string(query),
                "known_vertex_count": .int(knownCount)
            ])
            return .text(encodeJSONValue(payload), isError: true)

        case .streamUnavailable:
            let payload: MCPJSONValue = .object([
                "status": .string("stream_unavailable"),
                "message": .string("Shadow DOM stream is unavailable; ensure android-daemon is running and connected.")
            ])
            return .text(encodeJSONValue(payload), isError: true)
        }
    }

    public static func formatExploreOutcome(_ outcome: ExploreOutcome) -> MCPToolResult {
        func hex(_ hash: UInt64) -> String { String(format: "0x%016llx", hash) }
        func encodeCandidate(_ c: ExploreCandidate) -> MCPJSONValue {
            .object([
                "nodeId": .int(Int(c.nodeId)),
                "label": .string(c.label),
                "resourceId": .string(c.resourceId),
                "className": .string(c.className),
                "centerX": .int(c.centerX),
                "centerY": .int(c.centerY),
                "clickable": .bool(c.clickable),
                "scrollable": .bool(c.scrollable),
                "score": .int(c.score)
            ])
        }

        switch outcome {
        case .arrivedViaGraph(let report, let alreadyAtTarget, let activePackage):
            let summary: [MCPJSONValue] = report.steps.map { step in
                .object([
                    "step_index": .int(step.stepIndex),
                    "action": .string(step.actionSignature),
                    "target_hash": .string(hex(step.targetHash)),
                    "elapsed_ms": .int(step.elapsedMs),
                    "matched_by_exact_hash": .bool(step.matchedByExactHash),
                    "skipped": .bool(step.wasSkipped)
                ])
            }
            var obj: [String: MCPJSONValue] = [
                "status": .string("arrived_via_graph"),
                "already_at_target": .bool(alreadyAtTarget),
                "active_package": .string(activePackage),
                "start_hash": .string(hex(report.startHash)),
                "target_hash": .string(hex(report.finalHash)),
                "steps_executed": .int(report.steps.count),
                "total_elapsed_ms": .int(report.totalElapsedMs),
                "path_summary": .array(summary)
            ]
            if !report.recoveredSteps.isEmpty {
                obj["recovered_steps"] = .array(report.recoveredSteps.map { .string($0) })
            }
            return .text(encodeJSONValue(.object(obj)), isError: false)

        case .exploredAndClicked(
            let matchedCandidate,
            let scrollsPerformed,
            let startHash,
            let finalHash,
            let activePackage,
            let screenChanged,
            let edgeRecorded,
            let totalElapsedMs
        ):
            let payload: MCPJSONValue = .object([
                "status": .string("explored_and_clicked"),
                "matched_candidate": encodeCandidate(matchedCandidate),
                "scrolls_performed": .int(scrollsPerformed),
                "start_hash": .string(hex(startHash)),
                "final_hash": .string(hex(finalHash)),
                "active_package": .string(activePackage),
                "screen_changed": .bool(screenChanged),
                "edge_recorded": .bool(edgeRecorded),
                "total_elapsed_ms": .int(totalElapsedMs)
            ])
            return .text(encodeJSONValue(payload), isError: false)

        case .requiresConfirmation(let req):
            let payload: MCPJSONValue = .object([
                "status": .string("requires_confirmation"),
                "is_hazardous": .bool(true),
                "hazard_category": .string(req.hazardCategory.rawValue),
                "hazard_reason": .string(req.hazardReason),
                "blocked_step_index": .int(req.stepIndex),
                "total_steps": .int(req.totalSteps),
                "steps_completed": .int(req.stepsCompleted),
                "blocked_action": .string(req.actionSignature),
                "target_description": .string(req.targetDescription),
                "current_hash": .string(hex(req.currentHash)),
                "target_hash": .string(hex(req.targetHash)),
                "message": .string("Irreversible action blocked awaiting human approval. Ask the user in chat to confirm, then re-run android_explore_and_click with confirmed: true.")
            ])
            return .text(encodeJSONValue(payload), isError: false)

        case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
            let payload: MCPJSONValue = .object([
                "status": .string("secure_screen_active"),
                "code": .string("SECURE_SCREEN_ACTIVE"),
                "reason": .string(reason),
                "active_package": .string(activePackage),
                "timeout_seconds": .int(timeoutSeconds),
                "message": .string("Protected biometric/PIN screen remained locked past \(timeoutSeconds)s. Ask the user to unlock on the phone and retry.")
            ])
            return .text(encodeJSONValue(payload), isError: true)

        case .needsSelection(let query, let currentHash, let activePackage, let scrollsPerformed, let candidates):
            let payload: MCPJSONValue = .object([
                "status": .string("needs_selection"),
                "query": .string(query),
                "current_hash": .string(hex(currentHash)),
                "active_package": .string(activePackage),
                "scrolls_performed": .int(scrollsPerformed),
                "candidate_count": .int(candidates.count),
                "candidates": .array(candidates.map(encodeCandidate)),
                "message": .string("No confident live match (>=500) found. Select a candidate from 'candidates' or refine 'target'.")
            ])
            return .text(encodeJSONValue(payload), isError: false)
        }
    }

    public static func formatPathDeviationResult(_ error: PathDeviationError) -> MCPToolResult {
        func hex(_ hash: UInt64) -> String { String(format: "0x%016llx", hash) }

        var obj: [String: MCPJSONValue] = [
            "status": .string("path_deviation"),
            "message": .string(error.description)
        ]

        switch error {
        case .executionAlreadyInProgress:
            obj["error_type"] = .string("execution_already_in_progress")
        case .shadowStreamUnavailable:
            obj["error_type"] = .string("shadow_stream_unavailable")
        case .missingActionPayload(let stepIndex, let edgeId):
            obj["error_type"] = .string("missing_action_payload")
            obj["step_index"] = .int(stepIndex)
            obj["edge_id"] = .string(edgeId.uuidString)
        case .unexpectedStartState(let expectedHash, let actualHash, let actualPackage):
            obj["error_type"] = .string("unexpected_start_state")
            obj["expected_hash"] = .string(hex(expectedHash))
            obj["last_observed_hash"] = actualHash.map { .string(hex($0)) } ?? .null
            obj["last_observed_package"] = .string(actualPackage)
        case .actionDispatchFailed(let stepIndex, let actionSignature, let underlyingMessage):
            obj["error_type"] = .string("action_dispatch_failed")
            obj["step_index"] = .int(stepIndex)
            obj["action"] = .string(actionSignature)
            obj["underlying_error"] = .string(underlyingMessage)
        case .stepTimeout(let stepIndex, let expectedTargetHash, let lastObservedHash, let lastObservedPackage, let timeoutMs):
            obj["error_type"] = .string("step_timeout")
            obj["step_index"] = .int(stepIndex)
            obj["expected_target_hash"] = .string(hex(expectedTargetHash))
            obj["last_observed_hash"] = lastObservedHash.map { .string(hex($0)) } ?? .null
            obj["last_observed_package"] = .string(lastObservedPackage)
            obj["timeout_ms"] = .int(timeoutMs)
        case .requiresConfirmation(let req):
            obj["status"] = .string("requires_confirmation")
            obj["error_type"] = .string("requires_confirmation")
            obj["hazard_category"] = .string(req.hazardCategory.rawValue)
            obj["hazard_reason"] = .string(req.hazardReason)
            obj["blocked_action"] = .string(req.actionSignature)
            obj["blocked_step_index"] = .int(req.stepIndex)
        case .secureScreenTimeout(let reason, let activePackage, let timeoutSeconds):
            obj["status"] = .string("secure_screen_active")
            obj["error_type"] = .string("secure_screen_timeout")
            obj["reason"] = .string(reason)
            obj["active_package"] = .string(activePackage)
            obj["timeout_seconds"] = .int(timeoutSeconds)
        }

        return .text(encodeJSONValue(.object(obj)), isError: true)
    }

    private static func encodeJSONValue(_ value: MCPJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
