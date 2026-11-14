import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case english = "en"
    case russian = "ru"

    public var id: String { rawValue }

    /// Resolves `.system` to `.russian` or `.english` based on `Locale.preferredLanguages`.
    public static func resolveSystemLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for lang in preferredLanguages {
            let code = lang.lowercased()
            if code.hasPrefix("ru") {
                return .russian
            }
            if code.hasPrefix("en") {
                return .english
            }
        }
        return .english
    }

    public var resolved: AppLanguage {
        switch self {
        case .system:
            return Self.resolveSystemLanguage()
        case .english, .russian:
            return self
        }
    }

    public func displayName(in uiLang: AppLanguage) -> String {
        switch self {
        case .system:
            let detected = Self.resolveSystemLanguage() == .russian ? "Русский" : "English"
            return L10n.tr("Системный (\(detected))", "System (\(detected))", lang: uiLang)
        case .english:
            return "English"
        case .russian:
            return "Русский"
        }
    }
}

public enum L10n {
    public static let storageKey = "appLanguage"

    public static func currentLanguage(userDefaults: UserDefaults = .standard) -> AppLanguage {
        if let raw = userDefaults.string(forKey: storageKey),
           let stored = AppLanguage(rawValue: raw) {
            return stored.resolved
        }
        return AppLanguage.system.resolved
    }

    public static func tr(_ ru: String, _ en: String, lang: AppLanguage? = nil) -> String {
        let effective = (lang ?? currentLanguage()).resolved
        return effective == .russian ? ru : en
    }
}
