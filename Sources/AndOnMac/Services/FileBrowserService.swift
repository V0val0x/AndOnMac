import Foundation
import AppKit

public enum FileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case date
    case size

    public var id: String { rawValue }

    public func title(lang: AppLanguage) -> String {
        switch self {
        case .name: return L10n.tr("Имя", "Name", lang: lang)
        case .date: return L10n.tr("Дата", "Date", lang: lang)
        case .size: return L10n.tr("Размер", "Size", lang: lang)
        }
    }
}

public struct AndroidFileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let modifiedTimestamp: TimeInterval

    public var isHidden: Bool {
        name.hasPrefix(".")
    }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        sizeBytes: Int64,
        modifiedTimestamp: TimeInterval
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedTimestamp = modifiedTimestamp
    }

    public var formattedSize: String {
        if isDirectory { return "—" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var formattedDate: String {
        guard modifiedTimestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: modifiedTimestamp)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public var sfSymbolName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "webp", "gif", "bmp", "dng", "raw":
            return "photo.fill"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return "film.fill"
        case "mp3", "m4a", "flac", "wav", "ogg", "aac", "opus":
            return "music.note"
        case "apk", "xapk":
            return "shippingbox.fill"
        case "zip", "rar", "7z", "tar", "gz":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "md", "json", "xml", "csv", "log":
            return "doc.text.fill"
        default:
            return "doc.fill"
        }
    }
}

public final class FileBrowserService: @unchecked Sendable {
    public static let shared = FileBrowserService()

    private let fileManager = FileManager.default
    private var tempCacheDir: URL {
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("com.andonmac.cache/files", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    /// Safely single-quotes a remote POSIX path for `adb shell`.
    public static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Validates a remote Android path against traversal, null-byte injection, and destructive root deletions.
    public static func validateRemotePath(_ path: String, forDeletion: Bool = false) throws -> String {
        guard !path.isEmpty,
              path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            throw NSError(
                domain: "FileBrowserService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid remote path."]
            )
        }

        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw NSError(
                domain: "FileBrowserService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Path traversal segments are not allowed."]
            )
        }

        let normalized = "/" + rawComponents.joined(separator: "/")

        if forDeletion {
            let protectedRoots: Set<String> = [
                "/", "/sdcard", "/sdcard/DCIM", "/sdcard/Download", "/sdcard/Downloads",
                "/sdcard/Pictures", "/sdcard/Movies", "/sdcard/Music", "/sdcard/Documents",
                "/storage", "/storage/emulated", "/storage/emulated/0",
                "/system", "/data", "/vendor", "/etc", "/proc", "/dev", "/mnt"
            ]
            if protectedRoots.contains(normalized) || rawComponents.count < 2 {
                throw NSError(
                    domain: "FileBrowserService",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Refusing to delete protected system or root directory: \(normalized)"]
                )
            }
        }

        return normalized
    }

    /// Parses `stat -c "%F|%s|%Y|%n"` lines into sorted `AndroidFileItem` values.
    public static func parseStatListing(
        _ output: String,
        includeHidden: Bool = false,
        sortOrder: FileSortOrder = .name
    ) -> [AndroidFileItem] {
        var items: [AndroidFileItem] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }

            let fileType = String(parts[0]).lowercased()
            let size = Int64(parts[1]) ?? 0
            let mtime = TimeInterval(parts[2]) ?? 0
            let fullPath = String(parts[3])
            let name = (fullPath as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            if !includeHidden && name.hasPrefix(".") { continue }

            let isDir = fileType.contains("directory")
            items.append(AndroidFileItem(
                name: name,
                path: fullPath,
                isDirectory: isDir,
                sizeBytes: size,
                modifiedTimestamp: mtime
            ))
        }

        return sortItems(items, by: sortOrder)
    }

    public static func sortItems(_ items: [AndroidFileItem], by order: FileSortOrder) -> [AndroidFileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            switch order {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .date:
                if lhs.modifiedTimestamp != rhs.modifiedTimestamp {
                    return lhs.modifiedTimestamp > rhs.modifiedTimestamp
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Discovers internal `/sdcard` and any mounted external SD cards under `/storage/`.
    public func listStorageRoots(serial: String) async -> [String] {
        var roots = ["/sdcard"]
        let cmd = "ls -1 /storage 2>/dev/null"
        if let output = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd], timeoutSeconds: 4.0) {
            for entry in output.components(separatedBy: .newlines) {
                let name = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      name != "emulated",
                      name != "self",
                      name != "enc_emulated" else { continue }
                roots.append("/storage/\(name)")
            }
        }
        return roots
    }

    public func listDirectory(
        serial: String,
        path: String,
        includeHidden: Bool = false,
        sortOrder: FileSortOrder = .name
    ) async throws -> [AndroidFileItem] {
        let safePath = try Self.validateRemotePath(path)
        let escaped = Self.shellEscape(safePath)
        let cmd = "find \(escaped) -maxdepth 1 -mindepth 1 -exec stat -c '%F|%s|%Y|%n' {} + 2>/dev/null"
        let output = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd], timeoutSeconds: 10.0)
        return Self.parseStatListing(output, includeHidden: includeHidden, sortOrder: sortOrder)
    }

    public func createDirectory(serial: String, path: String) async throws {
        let safePath = try Self.validateRemotePath(path)
        let escaped = Self.shellEscape(safePath)
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "mkdir -p \(escaped)"], timeoutSeconds: 5.0)
    }

    public func renameItem(serial: String, from oldPath: String, to newPath: String) async throws {
        let safeOld = try Self.validateRemotePath(oldPath, forDeletion: true)
        let safeNew = try Self.validateRemotePath(newPath)
        let cmd = "mv \(Self.shellEscape(safeOld)) \(Self.shellEscape(safeNew))"
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd], timeoutSeconds: 5.0)
    }

    public func deleteItem(serial: String, path: String) async throws {
        let safePath = try Self.validateRemotePath(path, forDeletion: true)
        let cmd = "rm -rf \(Self.shellEscape(safePath))"
        _ = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd], timeoutSeconds: 8.0)
    }

    public func pullItem(serial: String, remotePath: String, to localURL: URL) async throws {
        let safePath = try Self.validateRemotePath(remotePath)
        _ = try await ADBService.shared.execute(
            arguments: ["-s", serial, "pull", safePath, localURL.path],
            timeoutSeconds: 120.0
        )
    }

    public func pullToCache(serial: String, item: AndroidFileItem) async throws -> URL {
        let safeName = PhotoTransferService.sanitizedCacheFilename(item.name)
        let localURL = tempCacheDir.appendingPathComponent(safeName)
        try? fileManager.removeItem(at: localURL)
        try await pullItem(serial: serial, remotePath: item.path, to: localURL)
        return localURL
    }

    public func pushItems(serial: String, localURLs: [URL], to remoteDirectory: String) async -> (succeeded: Int, failed: Int) {
        guard let safeRemoteDir = try? Self.validateRemotePath(remoteDirectory) else {
            return (0, localURLs.count)
        }
        var succeeded = 0
        var failed = 0
        for url in localURLs {
            let dest = (safeRemoteDir as NSString).appendingPathComponent(url.lastPathComponent)
            do {
                _ = try await ADBService.shared.execute(
                    arguments: ["-s", serial, "push", url.path, dest],
                    timeoutSeconds: 120.0
                )
                // Trigger Android MediaScanner for pushed files so Gallery/Music sees them right away
                _ = try? await ADBService.shared.execute(arguments: [
                    "-s", serial, "shell",
                    "content", "call", "--method", "scan_file", "--uri", "content://media",
                    "--extra", ADBService.shellQuote("file:--string=\(dest)")
                ], timeoutSeconds: 3.0)
                succeeded += 1
            } catch {
                failed += 1
            }
        }
        return (succeeded, failed)
    }
}
