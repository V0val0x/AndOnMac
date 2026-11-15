import Foundation
import AppKit

/// Persistent JSON registry (`~/.andonmac/mcp_tools/*.json`) for user-created and community-imported visual MCP tools.
public final class CustomMCPToolRegistry: ObservableObject, @unchecked Sendable {
    public static let shared = CustomMCPToolRegistry()

    public let directoryURL: URL
    private let lock = NSLock()
    private var cachedTools: [CustomMCPToolSchema] = []

    /// Published snapshot for SwiftUI Tool Hub bindings.
    @Published public private(set) var tools: [CustomMCPToolSchema] = []

    /// Invoked whenever the tool set or enabled states change (used for MCP LiveReload notifications).
    public var onToolsChanged: (@Sendable () -> Void)?

    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".andonmac", isDirectory: true)
            .appendingPathComponent("mcp_tools", isDirectory: true)
    }

    public init(directoryURL: URL = CustomMCPToolRegistry.defaultDirectoryURL) {
        self.directoryURL = directoryURL
        loadAllTools()
    }

    /// Loads and validates all `*.json` tool definitions from `directoryURL`.
    @discardableResult
    public func loadAllTools() -> [CustomMCPToolSchema] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let files = (try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [CustomMCPToolSchema] = []
        var seenNames = Set<String>()

        for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let schema = try? decoder.decode(CustomMCPToolSchema.self, from: data),
                  (try? schema.validate()) != nil,
                  seenNames.insert(schema.name).inserted else {
                continue
            }
            loaded.append(schema)
        }

        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        lock.lock()
        cachedTools = loaded
        lock.unlock()

        if Thread.isMainThread {
            self.tools = loaded
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.tools = loaded
            }
        }
        return loaded
    }

    /// Returns all currently loaded tools (thread-safe).
    public func allToolsSnapshot() -> [CustomMCPToolSchema] {
        lock.lock()
        defer { lock.unlock() }
        return cachedTools
    }

    /// Returns MCP tool definitions for all enabled custom tools (reloading from disk for LiveReload).
    public func enabledMCPDefinitions(reload: Bool = true) -> [MCPToolDefinition] {
        let current = reload ? loadAllTools() : allToolsSnapshot()
        return current.filter(\.isEnabled).map { $0.toMCPToolDefinition() }
    }

    /// Looks up an enabled custom tool by name (reloading from disk if not cached).
    public func enabledTool(named name: String) -> CustomMCPToolSchema? {
        let current = loadAllTools()
        return current.first { $0.name == name && $0.isEnabled }
    }

    /// Validates and persists a custom tool to `<directoryURL>/<name>.json`.
    public func saveTool(_ schema: CustomMCPToolSchema) throws {
        try schema.validate()
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let fileURL = safeFileURL(forToolName: schema.name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(schema)
        try data.write(to: fileURL, options: .atomic)

        _ = loadAllTools()
        onToolsChanged?()
    }

    /// Enables or disables a persisted tool and notifies connected MCP clients.
    public func setEnabled(name: String, enabled: Bool) throws {
        let current = allToolsSnapshot()
        guard var tool = current.first(where: { $0.name == name }) else {
            throw NSError(domain: "CustomMCPToolRegistry", code: 404, userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' not found."])
        }
        tool.isEnabled = enabled
        try saveTool(tool)
    }

    /// Deletes a custom tool JSON file from disk and notifies connected MCP clients.
    public func deleteTool(name: String) throws {
        guard CustomMCPToolSchema.isValidToolName(name) else {
            throw NSError(domain: "CustomMCPToolRegistry", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid tool name."])
        }
        let fileURL = safeFileURL(forToolName: name)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        _ = loadAllTools()
        onToolsChanged?()
    }

    /// Serializes a tool schema to pretty-printed JSON for sharing/export.
    public func exportJSON(name: String) throws -> String {
        let current = allToolsSnapshot()
        guard let tool = current.first(where: { $0.name == name }) else {
            throw NSError(domain: "CustomMCPToolRegistry", code: 404, userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' not found."])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tool)
        return String(decoding: data, as: UTF8.self)
    }

    /// Copies a tool's JSON schema to the macOS clipboard.
    @MainActor
    public func copyExportJSONToClipboard(name: String) throws -> String {
        let json = try exportJSON(name: name)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        return json
    }

    /// Parses, validates, and saves a JSON schema pasted from clipboard or community GitHub repos.
    @discardableResult
    public func importFromJSON(_ jsonString: String) throws -> CustomMCPToolSchema {
        guard let data = jsonString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw NSError(domain: "CustomMCPToolRegistry", code: 400, userInfo: [NSLocalizedDescriptionKey: "Empty or invalid UTF-8 JSON."])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let schema = try decoder.decode(CustomMCPToolSchema.self, from: data)
        try schema.validate()
        try saveTool(schema)
        return schema
    }

    private func safeFileURL(forToolName name: String) -> URL {
        // Tool name is strictly ^[a-z][a-z0-9_]{1,63}$ so no path traversal is possible
        directoryURL.appendingPathComponent("\(name).json", isDirectory: false)
    }
}
