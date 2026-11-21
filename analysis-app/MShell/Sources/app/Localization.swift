import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", traditionalChinese = "zh-Hant", simplifiedChinese = "zh-Hans"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return T("System default")
        case .english: return "English"
        case .traditionalChinese: return "\u{7e41}\u{9ad4}\u{4e2d}\u{6587}"
        case .simplifiedChinese: return "\u{7b80}\u{4f53}\u{4e2d}\u{6587}"
        }
    }
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        guard let first = preferred.first?.lowercased(), first.hasPrefix("zh") else { return "en" }
        return first.contains("hant") || first.contains("tw") || first.contains("hk") || first.contains("mo") ? "zh-Hant" : "zh-Hans"
    }
}

// UI state is changed only from the application's main actor.
enum UIStrings {
    static var language: AppLanguage = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--language"), index + 1 < args.count, let language = AppLanguage(rawValue: args[index + 1]) { return language }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: "MShell.language") ?? "system") ?? .system
    }()
    static let table: [String: [String: String]] = {
        guard let url = Bundle.module.url(forResource: "ui-strings", withExtension: "json"), let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return table
    }()
    static func text(_ key: String, language: AppLanguage) -> String {
        let locale = language.resolved()
        if let translated = table[key]?[locale] { return translated }
        for prefix in ["Connection failed: ", "Command failed: ", "Invalid connection settings: ", "The HTTP proxy refused the connection: "] {
            if key.hasPrefix(prefix), let translated = table[prefix]?[locale] {
                return translated + text(String(key.dropFirst(prefix.count)), language: language)
            }
        }
        return key
    }
}
func T(_ key: String) -> String { UIStrings.text(key, language: UIStrings.language) }
