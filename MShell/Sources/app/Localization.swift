import Foundation

// Interface text follows the standard Apple layout: `Resources/<language>.lproj/Localizable.strings`, keyed by the
// English source string, with English as the development language. The language choice is the app's own
// `AppleLanguages` preference, the same setting as System Settings › General › Language & Region › Applications, so
// either place changes it. MShell's own text switches at once; menus drawn by macOS follow after a restart.

/// The languages MShell ships, plus following the Mac.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", traditionalChinese = "zh-Hant"
    public var id: String { rawValue }

    /// Localizations in `Resources`, in order of preference when nothing else matches.
    static let supported = ["en", "zh-Hant"]

    public var title: String {
        switch self {
        case .system: return T("System default")
        case .english: return "English"
        case .traditionalChinese: return "\u{7e41}\u{9ad4}\u{4e2d}\u{6587}"
        }
    }

    /// The name of a resolved language code, in that language.
    static func title(for code: String) -> String {
        (AppLanguage(rawValue: code) ?? .english).title
    }

    /// The shipped localization to use. Following the Mac takes the first preferred language MShell has; any Chinese
    /// variant uses Traditional Chinese, and anything else English.
    public func resolved(preferred: [String] = UIStrings.systemLanguages()) -> String {
        guard self == .system else { return rawValue }
        for language in preferred.map({ $0.lowercased() }) {
            if language.hasPrefix("zh") { return "zh-Hant" }
            if language.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    /// The language a stored `AppleLanguages` list asks for, or `.system` when it is absent.
    static func from(appleLanguages: [String]?) -> AppLanguage {
        guard let first = appleLanguages?.first?.lowercased() else { return .system }
        return first.hasPrefix("zh") ? .traditionalChinese : first.hasPrefix("en") ? .english : .system
    }
}

// UI state is changed only from the application's main actor.
public enum UIStrings {
    private static let appleLanguages = "AppleLanguages"
    /// The key earlier versions stored the choice under; read once and moved to `AppleLanguages`.
    private static let legacyKey = "MShell.language"

    static var language: AppLanguage = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--language"), index + 1 < args.count, let language = AppLanguage(rawValue: args[index + 1]) {
            return language
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey) {
            let language: AppLanguage = legacy.hasPrefix("zh") ? .traditionalChinese : AppLanguage(rawValue: legacy) ?? .system
            UserDefaults.standard.removeObject(forKey: legacyKey)
            store(language)
            return language
        }
        return AppLanguage.from(appleLanguages: appLanguages())
    }()

    /// Saves the choice as this app's preferred language, or removes it to follow the Mac. Only the app bundle writes
    /// it, so tests and command-line runs leave the user's setting alone.
    static func store(_ language: AppLanguage) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if language == .system { UserDefaults.standard.removeObject(forKey: appleLanguages) }
        else { UserDefaults.standard.set([language.rawValue], forKey: appleLanguages) }
    }

    /// `AppleLanguages` set for this app alone, not inherited from the Mac.
    private static func appLanguages() -> [String]? {
        CFPreferencesCopyValue(appleLanguages as CFString, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String]
    }

    /// The Mac's preferred languages, ignoring this app's own choice.
    public static func systemLanguages() -> [String] {
        CFPreferencesCopyValue(appleLanguages as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
    }

    /// One `.lproj` bundle per shipped language, loaded once so lookups are safe from any thread.
    static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.supported.map { code in
        let path = Bundle.module.path(forResource: code, ofType: "lproj") ?? Bundle.module.path(forResource: code.lowercased(), ofType: "lproj")
        return (code, path.flatMap(Bundle.init(path:)) ?? Bundle.module)
    })

    private static let missing = "\u{1}"

    /// The translation of `key`, or nil when the language has none.
    static func lookup(_ key: String, in code: String) -> String? {
        let value = bundles[code]?.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }

    public static func text(_ key: String, language: AppLanguage) -> String {
        let code = language.resolved()
        if let translated = lookup(key, in: code) { return translated }
        // Error messages are built from a translated lead-in and a translated detail.
        for prefix in ["Connection failed: ", "Command failed: ", "Invalid connection settings: ", "The HTTP proxy refused the connection: "] {
            if key.hasPrefix(prefix), let translated = lookup(prefix, in: code) {
                return translated + text(String(key.dropFirst(prefix.count)), language: language)
            }
        }
        return key
    }
}

func T(_ key: String) -> String { UIStrings.text(key, language: UIStrings.language) }
