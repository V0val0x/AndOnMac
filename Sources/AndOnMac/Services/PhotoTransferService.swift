import Foundation
import AppKit

public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let remotePath: String
    public let isScreenshot: Bool
    public var localURL: URL?
    
    public init(id: String, name: String, remotePath: String, isScreenshot: Bool, localURL: URL? = nil) {
        self.id = id
        self.name = name
        self.remotePath = remotePath
        self.isScreenshot = isScreenshot
        self.localURL = localURL
    }
}

public final class PhotoTransferService: @unchecked Sendable {
    public static let shared = PhotoTransferService()
    
    private let fileManager = FileManager.default
    private var cacheDir: URL {
        let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("com.andonmac.cache/photos", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private init() {}
    
    /// Fetches a list of the most recent photos and screenshots from the Android device
    public func fetchRecentPhotos(serial: String, limit: Int = 24) async -> [PhotoItem] {
        // Safe query without wildcard expansion overflow
        let cmd = "for d in /sdcard/DCIM/Camera /sdcard/Pictures/Screenshots /sdcard/DCIM/Screenshots /sdcard/Pictures; do if [ -d \"$d\" ]; then ls -1t \"$d\" 2>/dev/null | head -n \(limit) | while read -r f; do echo \"$d/$f\"; done; fi; done"
        guard let output = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd]) else {
            return []
        }
        
        let validExtensions = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".mp4", ".mov"]
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                return validExtensions.contains { lower.hasSuffix($0) }
            }
        
        var items: [PhotoItem] = []
        var seenNames = Set<String>()
        for path in lines {
            let name = (path as NSString).lastPathComponent
            if seenNames.contains(name) { continue }
            seenNames.insert(name)
            
            let isScreenshot = path.lowercased().contains("screenshot")
            let localCached = cacheDir.appendingPathComponent(name)
            let localURL = fileManager.fileExists(atPath: localCached.path) ? localCached : nil
            items.append(PhotoItem(id: path, name: name, remotePath: path, isScreenshot: isScreenshot, localURL: localURL))
            if items.count >= limit { break }
        }
        return items
    }
    
    /// Pulls a photo from Android to local Mac cache for drag-and-drop or preview
    public func downloadPhoto(item: PhotoItem, serial: String) async -> URL? {
        let localDest = cacheDir.appendingPathComponent(item.name)
        if fileManager.fileExists(atPath: localDest.path) {
            return localDest
        }
        
        do {
            _ = try await ADBService.shared.execute(arguments: ["-s", serial, "pull", item.remotePath, localDest.path])
            if fileManager.fileExists(atPath: localDest.path) {
                return localDest
            }
        } catch {
            print("Failed to pull photo: \(error)")
        }
        return nil
    }
    
    /// Pushes files from Mac into Android Gallery / Downloads and invokes MediaScanner
    public func pushFiles(urls: [URL], serial: String) async -> (success: Bool, message: String) {
        guard !urls.isEmpty else { return (false, "Нет файлов для передачи") }
        
        // Ensure destination directory exists on phone
        let remoteFolder = "/sdcard/Pictures/AndOnMac"
        _ = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", "mkdir", "-p", remoteFolder])
        
        var pushedCount = 0
        for url in urls {
            let filename = url.lastPathComponent
            let isAPK = filename.lowercased().hasSuffix(".apk")
            
            if isAPK {
                // Install APK directly
                do {
                    _ = try await ADBService.shared.execute(arguments: ["-s", serial, "install", "-r", url.path])
                    pushedCount += 1
                } catch {
                    print("Failed to install APK \(filename): \(error)")
                }
            } else {
                let dest = "\(remoteFolder)/\(filename)"
                do {
                    _ = try await ADBService.shared.execute(arguments: ["-s", serial, "push", url.path, dest])
                    // Scan file so it shows in Gallery / Google Photos immediately
                    // 1. Modern Android (11-15) via MediaProvider content provider
                    _ = try? await ADBService.shared.execute(arguments: [
                        "-s", serial, "shell",
                        "content", "call", "--method", "scan_file", "--uri", "content://media",
                        "--extra", "file:--string=\(dest)"
                    ])
                    // 2. Package-explicit broadcast fallback for Android 7-10
                    _ = try? await ADBService.shared.execute(arguments: [
                        "-s", serial, "shell",
                        "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                        "-d", "file://\(dest)",
                        "-p", "com.android.providers.media"
                    ])
                    pushedCount += 1
                } catch {
                    print("Failed to push file \(filename): \(error)")
                }
            }
        }
        
        if pushedCount > 0 {
            return (true, "Передано файлов в Галерею: \(pushedCount)")
        } else {
            return (false, "Ошибка при передаче файлов")
        }
    }
}
