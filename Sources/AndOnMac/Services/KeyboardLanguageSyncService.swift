import Foundation
import Carbon
import Cocoa

/// Synchronizes macOS active keyboard input language with the connected Android device in real time.
/// Supports Gboard, Samsung Keyboard, and Android Input Method Manager.
public final class KeyboardLanguageSyncService: @unchecked Sendable {
    public static let shared = KeyboardLanguageSyncService()
    
    public var currentDeviceSerial: String?
    public var onLanguageChanged: ((String) -> Void)?
    
    private var languageToSubtypeMap: [String: Int] = [:]
    private let mapLock = NSLock()
    private var lastSyncedLanguage: String = ""
    private var isSyncing: Bool = false
    private var pollTimer: Timer?
    private var syncTask: Task<Void, Never>?
    
    private init() {
        setupObservers()
    }
    
    // MARK: - Observers Setup
    private func setupObservers() {
        // 1. Carbon Distributed Notification (fires system-wide whenever layout changes)
        let center = CFNotificationCenterGetDistributedCenter()
        let notificationName = CFNotificationName("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged" as CFString)
        
        CFNotificationCenterAddObserver(
            center,
            nil,
            { (_, _, _, _, _) in
                KeyboardLanguageSyncService.shared.checkAndSyncLanguage()
            },
            notificationName.rawValue,
            nil,
            .deliverImmediately
        )
        
        // 2. AppKit Notification (fires when text context switches)
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndSyncLanguage()
        }
    }
    
    // MARK: - Public Control
    public func startSync(for serial: String) {
        self.currentDeviceSerial = serial
        self.isSyncing = true
        
        Task {
            await refreshDeviceSubtypes(serial: serial)
            await MainActor.run {
                self.checkAndSyncLanguage(force: true)
                self.startPeriodicSync()
            }
        }
    }
    
    public func stopSync() {
        self.isSyncing = false
        self.currentDeviceSerial = nil
        self.pollTimer?.invalidate()
        self.pollTimer = nil
        self.syncTask?.cancel()
        self.syncTask = nil
    }
    
    // MARK: - Subtype Discovery via ADB
    public func refreshDeviceSubtypes(serial: String) async {
        do {
            let output = try await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "dumpsys input_method | grep -E 'mSubtypeLocale='"],
                timeoutSeconds: 3.0
            )
            let map = Self.parseSubtypes(from: output)
            if !map.isEmpty {
                mapLock.withLock {
                    self.languageToSubtypeMap = map
                }
            }
        } catch {
            // Keep default/empty map
        }
    }
    
    public static func parseSubtypes(from output: String) -> [String: Int] {
        var map: [String: Int] = [:]
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard line.contains("mSubtypeLocale=") else { continue }

            var resolvedId: Int?
            if let idRange = line.range(of: "mSubtypeId=") {
                let idSub = line[idRange.upperBound...]
                if let idStr = idSub.components(separatedBy: " ").first, let id = Int(idStr), id != 0 {
                    resolvedId = id
                }
            }
            if resolvedId == nil, let hashRange = line.range(of: "mSubtypeHashCode=") {
                let hashSub = line[hashRange.upperBound...]
                if let hashStr = hashSub.components(separatedBy: " ").first, let hash = Int(hashStr), hash != 0 {
                    resolvedId = hash
                }
            }
            guard let id = resolvedId else { continue }

            guard let locRange = line.range(of: "mSubtypeLocale=") else { continue }
            let locSub = line[locRange.upperBound...]
            let locTokens = locSub.components(separatedBy: " ")
            guard let locStr = locTokens.first, !locStr.isEmpty else { continue }
            
            let lang = String(locStr.prefix(2).lowercased())
            if map[lang] == nil {
                map[lang] = id
            }
        }
        return map
    }

    /// Parses `mCurrentSubtype=android.view.inputmethod.InputMethodSubtype@9442b7f9` into signed 32-bit hashCode (`-1807566855`).
    public static func parseCurrentSubtype(from output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            guard let markerRange = line.range(of: "mCurrentSubtype="),
                  let atRange = line[markerRange.upperBound...].range(of: "@") else { continue }
            let hexPart = line[atRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let hexToken = hexPart.components(separatedBy: CharacterSet.alphanumerics.inverted).first ?? ""
            guard !hexToken.isEmpty, let raw = UInt32(hexToken, radix: 16) else { continue }
            return Int(Int32(bitPattern: raw))
        }
        return nil
    }
    
    // MARK: - Current Mac Language Detection (Must be called on main thread for Carbon TIS thread-safety)
    public static func getCurrentMacLanguage() -> String {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                getCurrentMacLanguageOnMain()
            }
        }
        return getCurrentMacLanguageOnMain()
    }
    
    private static func getCurrentMacLanguageOnMain() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "en" }
        guard let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "en" }
        let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as? [String] ?? []
        if let first = langs.first {
            return String(first.prefix(2).lowercased())
        }
        return "en"
    }
    
    // MARK: - Sync Logic
    public func checkAndSyncLanguage(force: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.checkAndSyncLanguage(force: force)
            }
            return
        }
        guard isSyncing, let serial = currentDeviceSerial else { return }
        
        let currentLang = Self.getCurrentMacLanguage()
        if !force && currentLang == lastSyncedLanguage {
            return
        }
        
        lastSyncedLanguage = currentLang
        let badge = currentLang.uppercased()
        
        Task { @MainActor in
            self.onLanguageChanged?(badge)
            AppState.shared?.currentLanguageBadge = badge
            
            let uiLang = AppState.shared?.lang ?? L10n.currentLanguage()
            AppState.shared?.photoTransferNotice = Self.formatInputLanguageNotice(code: currentLang, uiLang: uiLang)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if AppState.shared?.photoTransferNotice?.hasPrefix("🌐") == true {
                    AppState.shared?.photoTransferNotice = nil
                }
            }
        }
        
        syncTask?.cancel()
        syncTask = Task {
            var (targetSubtype, mapCount) = mapLock.withLock {
                (self.languageToSubtypeMap[currentLang], self.languageToSubtypeMap.count)
            }

            if targetSubtype == nil {
                await self.refreshDeviceSubtypes(serial: serial)
                (targetSubtype, mapCount) = mapLock.withLock {
                    (self.languageToSubtypeMap[currentLang], self.languageToSubtypeMap.count)
                }
            }

            guard !Task.isCancelled else { return }

            if let targetSubtype = targetSubtype {
                // Verify Android's actual live subtype before toggling so we never desync or toggle away from a matching layout
                let currentOut = (try? await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "dumpsys input_method | grep -m 1 mCurrentSubtype="],
                    timeoutSeconds: 1.5
                )) ?? ""
                if let currentAndroidSubtype = Self.parseCurrentSubtype(from: currentOut),
                   currentAndroidSubtype == targetSubtype {
                    return
                }

                let maxAttempts = max(1, min(mapCount, 5))
                for _ in 0..<maxAttempts {
                    guard !Task.isCancelled else { return }
                    if ScrcpyClient.shared.isConnected {
                        ScrcpyClient.shared.sendKeycode(204)
                    } else {
                        _ = try? await ADBService.shared.execute(
                            arguments: ["-s", serial, "shell", "input keyevent 204"],
                            timeoutSeconds: 2.0
                        )
                    }
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard !Task.isCancelled else { return }

                    let checkOut = (try? await ADBService.shared.execute(
                        arguments: ["-s", serial, "shell", "dumpsys input_method | grep -m 1 mCurrentSubtype="],
                        timeoutSeconds: 1.5
                    )) ?? ""
                    if let updatedSubtype = Self.parseCurrentSubtype(from: checkOut),
                       updatedSubtype == targetSubtype {
                        break
                    }
                }
            } else if !force {
                // Universal fallback only on explicit user switch when subtype map is unavailable
                if ScrcpyClient.shared.isConnected {
                    ScrcpyClient.shared.sendKeycode(204)
                } else {
                    _ = try? await ADBService.shared.execute(
                        arguments: ["-s", serial, "shell", "input keyevent 204"],
                        timeoutSeconds: 2.0
                    )
                }
            }
        }
    }
    
    public static func formatInputLanguageNotice(code: String, uiLang: AppLanguage? = nil) -> String {
        let langDisplayName = localizedLanguageName(for: code)
        return L10n.tr("🌐 Язык ввода: \(langDisplayName)", "🌐 Input Language: \(langDisplayName)", lang: uiLang)
    }

    private static func localizedLanguageName(for code: String) -> String {
        switch code {
        case "ru": return "Русский (RU)"
        case "en": return "English (EN)"
        case "de": return "Deutsch (DE)"
        case "es": return "Español (ES)"
        case "fr": return "Français (FR)"
        case "it": return "Italiano (IT)"
        case "uk": return "Українська (UA)"
        case "tr": return "Türkçe (TR)"
        case "zh": return "中文 (ZH)"
        case "ja": return "日本語 (JA)"
        default: return code.uppercased()
        }
    }
    
    // MARK: - Periodic Polling Fallback
    private func startPeriodicSync() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkAndSyncLanguage()
        }
        timer.tolerance = 0.25
        pollTimer = timer
    }
}
