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
    private var lastSyncedLanguage: String = ""
    private var isSyncing: Bool = false
    private var pollTimer: Timer?
    
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
    }
    
    // MARK: - Subtype Discovery via ADB
    public func refreshDeviceSubtypes(serial: String) async {
        do {
            let output = try await ADBService.shared.execute(
                arguments: ["-s", serial, "shell", "dumpsys input_method | grep -E 'mSubtypeId=[^0].*mSubtypeLocale='"],
                timeoutSeconds: 3.0
            )
            let map = Self.parseSubtypes(from: output)
            if !map.isEmpty {
                self.languageToSubtypeMap = map
            }
        } catch {
            // Keep default/empty map
        }
    }
    
    public static func parseSubtypes(from output: String) -> [String: Int] {
        var map: [String: Int] = [:]
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard line.contains("mSubtypeId=") && line.contains("mSubtypeLocale=") else { continue }
            guard let idRange = line.range(of: "mSubtypeId="),
                  let locRange = line.range(of: "mSubtypeLocale=") else { continue }
            
            let idSub = line[idRange.upperBound...]
            let idTokens = idSub.components(separatedBy: " ")
            guard let idStr = idTokens.first, let id = Int(idStr), id != 0 else { continue }
            
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
    
    // MARK: - Current Mac Language Detection
    public static func getCurrentMacLanguage() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "en" }
        guard let langsPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return "en" }
        let langs = Unmanaged<CFArray>.fromOpaque(langsPtr).takeUnretainedValue() as! [String]
        if let first = langs.first {
            return String(first.prefix(2).lowercased())
        }
        return "en"
    }
    
    // MARK: - Sync Logic
    public func checkAndSyncLanguage(force: Bool = false) {
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
            
            let langDisplayName = localizedLanguageName(for: currentLang)
            AppState.shared?.photoTransferNotice = "🌐 Язык ввода: \(langDisplayName)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if AppState.shared?.photoTransferNotice?.hasPrefix("🌐") == true {
                    AppState.shared?.photoTransferNotice = nil
                }
            }
        }
        
        Task {
            if let targetSubtype = self.languageToSubtypeMap[currentLang] {
                // Apply exact subtype to Android InputMethodManager
                _ = try? await ADBService.shared.execute(
                    arguments: ["-s", serial, "shell", "settings put secure selected_input_method_subtype \(targetSubtype)"],
                    timeoutSeconds: 2.0
                )
                
                // If mirroring is active, send KEYCODE_LANGUAGE_SWITCH (204) to refresh active IME
                if ScrcpyClient.shared.isConnected {
                    ScrcpyClient.shared.sendKeycode(204)
                }
            } else {
                // Universal fallback: send KEYCODE_LANGUAGE_SWITCH
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
    
    private func localizedLanguageName(for code: String) -> String {
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkAndSyncLanguage()
        }
    }
}
