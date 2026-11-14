import Foundation
import AppKit
import ImageIO
import AVFoundation

public enum MediaFolderFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case camera
    case screenshots
    case downloads
    case videos

    public var id: String { rawValue }

    public func title(lang: AppLanguage) -> String {
        switch self {
        case .all: return L10n.tr("Все", "All", lang: lang)
        case .camera: return L10n.tr("Камера", "Camera", lang: lang)
        case .screenshots: return L10n.tr("Скриншоты", "Screenshots", lang: lang)
        case .downloads: return L10n.tr("Загрузки", "Downloads", lang: lang)
        case .videos: return L10n.tr("Видео", "Videos", lang: lang)
        }
    }
}

public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let remotePath: String
    public let isScreenshot: Bool
    public var localURL: URL?

    public var isVideo: Bool {
        let lower = remotePath.lowercased()
        return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
    }

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

    /// Parses raw `timestamp|path` or plain `path` lines returned by `adb shell find ... stat`.
    public static func parseMediaLines(_ output: String, folder: MediaFolderFilter = .all, limit: Int = 500) -> [String] {
        let validExtensions = [".jpg", ".jpeg", ".png", ".heic", ".webp", ".mp4", ".mov"]
        let videoExtensions = [".mp4", ".mov"]

        var result: [String] = []
        var seenPaths = Set<String>()

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let path: String
            if let pipeIdx = trimmed.firstIndex(of: "|") {
                path = String(trimmed[trimmed.index(after: pipeIdx)...])
            } else {
                path = trimmed
            }

            let lower = path.lowercased()
            guard validExtensions.contains(where: { lower.hasSuffix($0) }) else { continue }

            switch folder {
            case .all:
                break
            case .camera:
                guard lower.contains("/dcim/") && !lower.contains("screenshot") else { continue }
            case .screenshots:
                guard lower.contains("screenshot") else { continue }
            case .downloads:
                guard lower.contains("/download/") else { continue }
            case .videos:
                guard videoExtensions.contains(where: { lower.hasSuffix($0) }) else { continue }
            }

            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            result.append(path)
            if result.count >= limit { break }
        }
        return result
    }
    
    /// Fetches media files across DCIM, Pictures, Download, and Movies sorted newest-first.
    public func fetchRecentPhotos(serial: String, limit: Int = 500, folder: MediaFolderFilter = .all) async -> [PhotoItem] {
        let roots: String
        switch folder {
        case .camera:
            roots = "/sdcard/DCIM"
        case .downloads:
            roots = "/sdcard/Download"
        case .videos:
            roots = "/sdcard/DCIM /sdcard/Movies /sdcard/Pictures /sdcard/Download"
        case .all, .screenshots:
            roots = "/sdcard/DCIM /sdcard/Pictures /sdcard/Download /sdcard/Movies"
        }

        let cmd = "for r in \(roots); do [ -d \"$r\" ] && find \"$r\" -maxdepth 4 -type f \\( -iname \"*.jpg\" -o -iname \"*.jpeg\" -o -iname \"*.png\" -o -iname \"*.heic\" -o -iname \"*.webp\" -o -iname \"*.mp4\" -o -iname \"*.mov\" \\) ! -path \"*/.*\" -exec stat -c \"%Y|%n\" {} + 2>/dev/null; done | sort -rn | head -n \(max(limit, 500))"
        guard let output = try? await ADBService.shared.execute(arguments: ["-s", serial, "shell", cmd], timeoutSeconds: 12.0) else {
            return []
        }

        let paths = Self.parseMediaLines(output, folder: folder, limit: limit)
        var items: [PhotoItem] = []
        items.reserveCapacity(paths.count)
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let isScreenshot = path.lowercased().contains("screenshot")
            let localCached = cacheDir.appendingPathComponent(name)
            let localURL = fileManager.fileExists(atPath: localCached.path) ? localCached : nil
            items.append(PhotoItem(id: path, name: name, remotePath: path, isScreenshot: isScreenshot, localURL: localURL))
        }
        return items
    }

    /// Generates a fast memory-efficient thumbnail for an image or video file.
    public func generateThumbnail(for url: URL, maxPixelSize: CGFloat = 180) async -> NSImage? {
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "mov" {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            if let cgImage = try? await generator.image(at: .zero).image {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
            return nil
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        }
        return NSImage(contentsOf: url)
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
        guard !urls.isEmpty else { return (false, L10n.tr("Нет файлов для передачи", "No files to transfer")) }
        
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
                    let uriString = URL(fileURLWithPath: dest).absoluteString
                    _ = try? await ADBService.shared.execute(arguments: [
                        "-s", serial, "shell",
                        "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                        "-d", uriString,
                        "-p", "com.android.providers.media"
                    ])
                    pushedCount += 1
                } catch {
                    print("Failed to push file \(filename): \(error)")
                }
            }
        }
        
        if pushedCount > 0 {
            return (true, L10n.tr("Передано в Галерею: \(pushedCount)", "Sent to Gallery: \(pushedCount)"))
        } else {
            return (false, L10n.tr("Ошибка при передаче файлов", "Failed to transfer files"))
        }
    }
}
