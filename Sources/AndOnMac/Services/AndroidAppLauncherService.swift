import Foundation

/// Represents an installed launchable Android user application.
public struct AndroidAppItem: Identifiable, Hashable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public let displayName: String

    public init(packageName: String, displayName: String? = nil) {
        self.packageName = packageName
        self.displayName = displayName ?? Self.friendlyName(for: packageName)
    }

    /// Resolves well-known Android package IDs or formats reverse-DNS package names into readable titles.
    public static func friendlyName(for packageName: String) -> String {
        let known: [String: String] = [
            "com.whatsapp": "WhatsApp",
            "org.telegram.messenger": "Telegram",
            "org.telegram.messenger.web": "Telegram",
            "com.google.android.youtube": "YouTube",
            "com.spotify.music": "Spotify",
            "com.instagram.android": "Instagram",
            "com.discord": "Discord",
            "com.zhiliaoapp.musically": "TikTok",
            "com.google.android.apps.maps": "Google Maps",
            "com.google.android.gm": "Gmail",
            "com.google.android.keep": "Google Keep",
            "com.google.android.apps.photos": "Google Photos",
            "com.android.chrome": "Chrome",
            "com.slack": "Slack",
            "com.notion.id": "Notion",
            "com.reddit.frontpage": "Reddit",
            "com.twitter.android": "X",
            "com.netflix.mediaclient": "Netflix",
            "com.ubercab": "Uber",
            "com.openai.chatgpt": "ChatGPT",
            "ru.yandex.yandexmaps": "Yandex Maps",
            "com.vkontakte.android": "VK"
        ]
        if let hit = known[packageName] {
            return hit
        }
        let segments = packageName.split(separator: ".").map(String.init)
        let ignored: Set<String> = ["com", "org", "net", "io", "app", "android", "google", "apps", "client", "mobile"]
        let meaningful = segments.filter { !ignored.contains($0.lowercased()) }
        let raw = meaningful.last ?? segments.last ?? packageName
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

/// Queries installed Android apps and launches them in standalone scrcpy virtual display windows.
public final class AndroidAppLauncherService: @unchecked Sendable {
    public static let shared = AndroidAppLauncherService()

    private let lock = NSLock()
    private var activeProcesses: [String: Process] = [:]

    private init() {}

    /// Parses `cmd package query-activities --brief` or `cmd package list packages` output into sorted `AndroidAppItem` entries.
    public static func parsePackageList(_ output: String) -> [AndroidAppItem] {
        var seen = Set<String>()
        var items: [AndroidAppItem] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var pkg: String
            if trimmed.hasPrefix("package:") {
                pkg = String(trimmed.dropFirst("package:".count))
            } else if let slashIdx = trimmed.firstIndex(of: "/"), !trimmed.contains(" "), !trimmed.contains("=") {
                pkg = String(trimmed[..<slashIdx])
            } else {
                pkg = trimmed
            }
            guard !pkg.isEmpty, !pkg.contains(" "), pkg.contains("."), !pkg.contains("="), seen.insert(pkg).inserted else { continue }
            items.append(AndroidAppItem(packageName: pkg))
        }

        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Fetches launchable apps (both user-installed and pre-installed/system like YouTube, Chrome, Settings).
    public func fetchInstalledApps(serial: String) async throws -> [AndroidAppItem] {
        guard ADBService.validateSerial(serial) else {
            throw NSError(domain: "AndroidAppLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device serial"])
        }
        if let launchable = try? await ADBService.shared.execute(
            arguments: ["-s", serial, "shell", "cmd", "package", "query-activities", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"],
            timeoutSeconds: 8.0
        ) {
            let parsed = Self.parsePackageList(launchable)
            if !parsed.isEmpty {
                return parsed
            }
        }
        let output: String
        do {
            output = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "cmd", "package", "list", "packages"], timeoutSeconds: 8.0)
        } catch {
            output = try await ADBService.shared.execute(arguments: ["-s", serial, "shell", "pm", "list", "packages"], timeoutSeconds: 8.0)
        }
        return Self.parsePackageList(output)
    }

    /// Launches a single Android app inside its own standalone virtual display macOS window.
    @discardableResult
    public func launchApp(
        _ app: AndroidAppItem,
        serial: String,
        profile: DeviceProfile = .default,
        turnScreenOff: Bool = true,
        stayAwake: Bool = true
    ) throws -> Process {
        guard ADBService.validateSerial(serial) else {
            throw NSError(domain: "AndroidAppLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device serial"])
        }
        guard ADBService.validatePackageName(app.packageName) else {
            throw NSError(domain: "AndroidAppLauncher", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Android package name"])
        }
        let scrcpy = MirrorService.shared.scrcpyPath
        guard FileManager.default.isExecutableFile(atPath: scrcpy) else {
            throw NSError(
                domain: "AndroidAppLauncher",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "scrcpy binary not found at \(scrcpy)"]
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scrcpy)
        var args = [
            "-s", serial,
            "--new-display",
            "--start-app=\(app.packageName)",
            "--window-title=\(app.displayName)",
            "--max-size=\(profile.maxSize)",
            "--max-fps=\(profile.maxFps)",
            "--video-bit-rate=\(profile.bitRate)"
        ]
        if turnScreenOff {
            args.append("--turn-screen-off")
        }
        if stayAwake {
            args.append("--stay-awake")
        }
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["ADB"] = ADBService.shared.adbPath
        if let serverPath = ScrcpyClient.resolveScrcpyServerPath() {
            env["SCRCPY_SERVER_PATH"] = serverPath
        }
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let key = "\(serial):\(app.packageName)"
        proc.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?.activeProcesses.removeValue(forKey: key)
            self?.lock.unlock()
        }

        try proc.run()
        ProcessLifecycleManager.shared.register(proc, tag: "app-launcher")
        lock.lock()
        activeProcesses[key] = proc
        lock.unlock()
        return proc
    }

    /// Terminates all standalone virtual display app windows.
    public func stopAllAppWindows() {
        lock.lock()
        let procs = Array(activeProcesses.values)
        activeProcesses.removeAll()
        lock.unlock()
        for proc in procs {
            ProcessLifecycleManager.shared.terminateProcess(proc)
        }
    }
}
