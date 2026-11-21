import Foundation
import AppKit
import SwiftUI
import CryptoKit

public struct ThemeColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public init?(hex: String) {
        guard hex.first == "#" else { return nil }
        var digits = String(hex.dropFirst())
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if digits.count <= 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 6 { digits += "ff" }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 24) & 255) / 255
        green = Double((value >> 16) & 255) / 255
        blue = Double((value >> 8) & 255) / 255
        alpha = Double(value & 255) / 255
    }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var color: Color { Color(nsColor: nsColor) }
}

public struct WorkspaceTheme: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let appearance: String
    public let colors: [String: ThemeColor]
    public var isDark: Bool { appearance == "dark" || appearance == "high-contrast-dark" }
    public var background: ThemeColor { colors["editor.background"] ?? fallback(isDark ? "#101620" : "#ffffff") }
    public var foreground: ThemeColor { colors["editor.foreground"] ?? fallback(isDark ? "#d1e0e6" : "#202020") }
    var border: ThemeColor? { colors["sideBar.border"] }
    public var sidebar: ThemeColor { colors["sideBar.background"] ?? background }
    public var header: ThemeColor { colors["titleBar.activeBackground"] ?? sidebar }
    public var tabs: ThemeColor { colors["editorGroupHeader.tabsBackground"] ?? sidebar }
    /// Some themes use a faint focus border; the accent marks controls, so it must stay visible.
    public var accent: ThemeColor {
        [colors["focusBorder"], colors["button.background"]].compactMap { $0 }.first { $0.alpha >= 0.5 }
            ?? fallback(isDark ? "#62e1c1" : "#0069cc")
    }
    public var terminalBackground: ThemeColor { colors["terminal.background"] ?? background }
    public var terminalForeground: ThemeColor { colors["terminal.foreground"] ?? foreground }
    public var cursor: ThemeColor { colors["terminalCursor.foreground"] ?? terminalForeground }
    public var selection: ThemeColor { colors["terminal.selectionBackground"] ?? colors["editor.selectionBackground"] ?? fallback(isDark ? "#264f78" : "#add6ff") }
    static let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                           "BrightBlack", "BrightRed", "BrightGreen", "BrightYellow", "BrightBlue",
                           "BrightMagenta", "BrightCyan", "BrightWhite"]
    public func terminalANSI(_ index: Int) -> ThemeColor {
        let keys = Self.ansiKeys
        let dark = ["202530", "e06c75", "98c379", "e5c07b", "61afef", "c678dd", "56b6c2", "abb2bf", "5c6370", "ff7b86", "b5e890", "ffdf99", "89c4ff", "e6a6ff", "79e2f2", "ffffff"]
        let light = ["000000", "a31515", "008000", "795e26", "0451a5", "800080", "007f7f", "555555", "666666", "c72e2e", "087d08", "8a6700", "005cc5", "a000a0", "007c91", "767676"]
        guard keys.indices.contains(index) else { return terminalForeground }
        return colors["terminal.ansi" + keys[index]] ?? fallback("#" + (isDark ? dark : light)[index])
    }
    private func fallback(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }
    /// Default and fallback theme: the first preset (Midnight). The former "mshell" theme was removed;
    /// a saved "mshell" preference is treated as stale and falls back to this theme.
    public static let native: WorkspaceTheme = presets[0]
}

public enum ThemeCatalog {
    /// License notices for the bundled third-party theme colors.
    public static func licenseNotices() throws -> String {
        try ["vscode-themes-license", "vscode-community-themes-licenses"].map { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { throw ThemeError.missingResources }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
    private struct Blueprint: Decodable {
        let schema: String
        let assets: [Asset]
        struct Asset: Decodable {
            let id: String
            let kind: String
            let label: String
            let appearance: String
            let colors: [String: Entry]
        }
        struct Entry: Decodable { let value: String? }
    }
    public static func bundled() throws -> [WorkspaceTheme] {
        guard let resource = Bundle.module.url(forResource: "vscode-themes", withExtension: "json"),
              let checksum = Bundle.module.url(forResource: "vscode-themes", withExtension: "sha256") else { throw ThemeError.missingResources }
        let data = try Data(contentsOf: resource), expected = try String(contentsOf: checksum, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { throw ThemeError.invalidResources }
        let blueprint = try JSONDecoder().decode(Blueprint.self, from: data)
        guard blueprint.schema == "carve/frontend-blueprint@1", !blueprint.assets.isEmpty, blueprint.assets.count <= 64 else { throw ThemeError.invalidResources }
        let defaultThemes = WorkspaceTheme.presets
        var ids = Set(defaultThemes.map(\.id))
        return defaultThemes + (try blueprint.assets.map { asset in
            guard asset.kind == "color-palette", ids.insert(asset.id).inserted,
                  ["light", "dark", "high-contrast-light", "high-contrast-dark"].contains(asset.appearance) else { throw ThemeError.invalidResources }
            var colors: [String: ThemeColor] = [:]
            for (key, entry) in asset.colors {
                if let value = entry.value {
                    guard let color = ThemeColor(hex: value) else { throw ThemeError.invalidResources }
                    colors[key] = color
                }
            }
            return WorkspaceTheme(id: asset.id, title: asset.label, appearance: asset.appearance, colors: colors)
        })
    }
}

struct ThemePreference: Codable { let selectedID: String }
public struct ThemePreviewState {
    public private(set) var activeID: String
    public private(set) var selectedID: String
    public private(set) var pendingID: String?
    private var remaining = 0
    init(current: String) { activeID = current; selectedID = current }
    mutating func focus(_ id: String) { selectedID = id; pendingID = id; remaining = 200 }
    mutating func advance(_ milliseconds: Int) {
        guard let pendingID else { return }
        remaining -= milliseconds
        if remaining <= 0 { activeID = pendingID; self.pendingID = nil }
    }
}
public enum ThemeError: Error, LocalizedError {
    case missingResources, invalidResources, unknownTheme, previewNotOpen
    public var errorDescription: String? {
        switch self {
        case .missingResources: return "Theme resources are missing."
        case .invalidResources: return "Theme resources failed integrity validation."
        case .unknownTheme: return "The selected theme is unavailable."
        case .previewNotOpen: return "Open theme preferences before previewing a theme."
        }
    }
}
