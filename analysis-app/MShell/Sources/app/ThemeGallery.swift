import SwiftUI
import AppKit

extension WorkspaceTheme {
    private static func preset(_ id: String, _ title: String, appearance: String, chrome: [String],
                               background: String, foreground: String, cursor: String,
                               selection: String, ansi: [String]) -> WorkspaceTheme {
        let keys = ["editor.background", "sideBar.background", "titleBar.activeBackground",
                    "editorGroupHeader.tabsBackground", "focusBorder", "sideBar.border",
                    "terminal.background", "terminal.foreground", "terminalCursor.foreground",
                    "terminal.selectionBackground", "editor.foreground"]
        let values = chrome + [background, foreground, cursor, selection, foreground]
        var colors = Dictionary(uniqueKeysWithValues: zip(keys, values).map { key, hex in
            (key, ThemeColor(hex: "#" + hex)!)
        })
        for (key, hex) in zip(ansiKeys, ansi) {
            colors["terminal.ansi" + key] = ThemeColor(hex: "#" + hex)
        }
        return WorkspaceTheme(id: id, title: title, appearance: appearance, colors: colors)
    }

    static let presets: [WorkspaceTheme] = [
        preset("midnight", "Midnight", appearance: "dark", chrome: ["191B2C", "222337", "27283E", "1F2136", "AFA1ED", "534B76"],
               background: "141722", foreground: "E1E7FA", cursor: "C3B4FF", selection: "484268",
              ansi: ["24283A", "FF8796", "95DDB8", "F4C486", "92ADF8", "C9A2F0", "80D1DB", "BBC5E0",
                     "8A96B7", "FFA3B1", "AAF0C6", "F9D6A9", "ABC3FF", "DEBEFF", "A1E5EB", "F5F6FF"]),
        preset("pine", "Pine", appearance: "dark", chrome: ["14241F", "1B3029", "233A30", "182C25", "8FD5AC", "396453"],
               background: "101E1A", foreground: "DCEBDD", cursor: "AAE7B5", selection: "315448",
              ansi: ["20352D", "F68D85", "92D0A0", "E6C184", "8BBBDF", "D0A4D0", "7CCFC5", "BACDBF",
                     "819F91", "FFA69A", "ACECB2", "F9D79A", "AAD4FD", "E9BDE8", "A0E4D7", "F1F6EE"]),
        preset("deep-blue", "Deep Blue", appearance: "dark", chrome: ["102136", "172A42", "1B3350", "142A45", "82BCF9", "335979"],
               background: "0A192B", foreground: "D7E7FA", cursor: "7FD8F8", selection: "244E70",
              ansi: ["1B2F46", "FF8998", "8BD6AD", "F1C681", "83B5FF", "C9A4FF", "75D1EC", "B7CDE1",
                     "7896B5", "FFA8B2", "A4EBC2", "FFDEAB", "A6C9FF", "DCC1FF", "9AE7FF", "F3F8FD"]),
        preset("amber", "Amber", appearance: "dark", chrome: ["291E14", "35271A", "423123", "332618", "FFC17B", "6A4A31"],
               background: "20170E", foreground: "F4DFC0", cursor: "FFCB76", selection: "654728",
              ansi: ["35291D", "F28A75", "B6CC85", "ECB267", "9BBADF", "D4A0C2", "8FC9C2", "CAB79F",
                     "A69882", "FFAC8B", "DAE5A4", "FFD995", "BDDBFC", "F0BDDF", "ABDDD4", "FFF3E2"]),
        preset("graphite", "Graphite", appearance: "dark", chrome: ["222528", "2B2F34", "34383E", "292C31", "B5C8E0", "555F6A"],
               background: "1C1E20", foreground: "E2E4E6", cursor: "F5F7FA", selection: "4B535E",
              ansi: ["292D30", "E59998", "A5CCA2", "DCCC99", "9FBBD7", "C5ADDA", "99CCCD", "C9CED3",
                     "92999E", "F9B9B7", "C1E3BB", "F0E0B3", "C1D8EE", "DECAEE", "B8E8E7", "FAFBFC"]),
        preset("paper", "Paper", appearance: "light", chrome: ["F7F3EA", "EDE7DA", "E6DDCD", "F0EBE0", "5F623A", "C4BDAB"],
               background: "F5F1E7", foreground: "292721", cursor: "4E5040", selection: "D6DFBD",
              ansi: ["27251F", "A32F36", "426414", "78530A", "234E96", "79346E", "166263", "555146",
                     "625E51", "9B343D", "43691B", "7E5A10", "2755A0", "803981", "1B696E", "49473D"]),
        preset("glacier", "Glacier", appearance: "light", chrome: ["F1F6FA", "E1EBF4", "D8E5F0", "E4EEF5", "245D83", "ADBFCE"],
               background: "EAF1F7", foreground: "263442", cursor: "12627C", selection: "C1DCE8",
              ansi: ["253440", "A32C46", "236649", "765618", "204F8D", "713E84", "186377", "485A67",
                     "556777", "A6324D", "286748", "795718", "26599A", "774391", "1C687A", "34495A"])
    ]

}

struct ThemeGallery: View {
    let themes: [WorkspaceTheme]
    let selectedID: String
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(themes) { theme in
                        row(theme).id(theme.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.top)
            .onAppear { scroll.scrollTo(selectedID, anchor: .center) }
        }
        .accessibilityIdentifier("themePicker")
    }

    private func row(_ theme: WorkspaceTheme) -> some View {
        let selected = selectedID == theme.id
        return Button { select(theme.id) } label: {
            HStack(spacing: 10) {
                WorkspaceThumbnail(theme: theme)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(T(theme.title)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(T(theme.isDark ? "Dark theme" : "Light theme"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T(theme.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("workspaceTheme.\(theme.id)")
    }
}

private struct WorkspaceThumbnail: View {
    let theme: WorkspaceTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(theme.foreground.color.opacity(0.4)).frame(width: 2, height: 2) }
                Capsule().fill(theme.accent.color).frame(width: 19, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 9)
            .background(theme.header.color)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.accent.color).frame(width: 9, height: 2)
                    Capsule().fill(theme.foreground.color.opacity(0.45)).frame(width: 7, height: 2)
                    Capsule().fill(theme.foreground.color.opacity(0.3)).frame(width: 8, height: 2)
                    Spacer(minLength: 0)
                }.padding(.top, 6).frame(width: 18).background(theme.sidebar.color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        Capsule().fill(theme.terminalANSI(2).color).frame(width: 7, height: 2)
                        Capsule().fill(theme.terminalForeground.color).frame(width: 15, height: 2)
                    }
                    HStack(spacing: 2) {
                        Capsule().fill(theme.terminalANSI(4).color).frame(width: 11, height: 2)
                        Capsule().fill(theme.terminalANSI(3).color).frame(width: 8, height: 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 5)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.terminalBackground.color)
            }
        }
        .frame(width: 65, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.13)) }
    }
}

/// Tint the native titlebar while keeping the system window controls.
struct ThemeTitlebar: NSViewRepresentable {
    let theme: WorkspaceTheme
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ view: TitlebarView, context: Context) { view.color = theme.header.nsColor }

    final class TitlebarView: NSView {
        var color: NSColor? { didSet { apply() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        private func apply() {
            guard let window, let color else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = color
        }
    }
}
