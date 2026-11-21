import SwiftUI
import AppKit

/// The Settings window's scene identifier. MShell opens its own window instead of SwiftUI's `Settings` scene, so
/// the app menu has a single, translated **Settings…** item.
public enum SettingsWindow {
    public static let id = "settings"
}

/// The app menu's **Settings…** item, in the workspace's language. It is there before the workspace finishes
/// loading, using the saved language until then.
public struct PreferencesMenuLink: View {
    private let model: WorkspaceModel?
    @Environment(\.openWindow) private var openWindow
    public init(model: WorkspaceModel?) { self.model = model }
    public var body: some View {
        Button { openWindow(id: SettingsWindow.id) } label: {
            if let model { MenuTitle(model: model) } else { Text(T("Preferences…")) }
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    private struct MenuTitle: View {
        @ObservedObject var model: WorkspaceModel
        var body: some View { Text(UIStrings.text("Preferences…", language: model.language)) }
    }
}

/// The Settings window: General (language) and Appearance (workspace theme).
public struct PreferencesView: View {
    enum Pane: Hashable { case general, appearance }
    @ObservedObject private var model: WorkspaceModel
    @State private var pane = Pane.general
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            // Pane buttons along the top, icon over name, as in the system's own settings windows.
            HStack(spacing: 4) {
                paneButton(.general, T("General"), "gearshape")
                paneButton(.appearance, T("Appearance"), "paintpalette")
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(model.theme.header.color)
            Rectangle().fill(model.theme.foreground.color.opacity(0.1)).frame(height: 1)
            Group {
                switch pane {
                case .general: GeneralSettings(model: model)
                case .appearance: AppearanceSettings(model: model)
                }
            }
            .padding(20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(T("Settings"))
        .background(model.theme.background.color)
        .foregroundStyle(model.theme.foreground.color)
        .background(ThemeTitlebar(theme: model.theme))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .tint(model.theme.accent.color)
    }

    private func paneButton(_ value: Pane, _ title: String, _ symbol: String) -> some View {
        let selected = pane == value
        return Button { pane = value } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(selected ? model.theme.accent.color : model.theme.foreground.color.opacity(0.7))
            .frame(minWidth: 64).padding(.vertical, 5).padding(.horizontal, 6)
            .background(selected ? model.theme.foreground.color.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Language, and later other app-wide choices.
private struct GeneralSettings: View {
    @ObservedObject var model: WorkspaceModel

    private let languages: [AppLanguage] = [.system, .traditionalChinese, .english]

    var body: some View {
        Form {
            Picker(selection: $model.language) {
                ForEach(languages) { language in
                    Text(language == .system ? String(format: T("System default (%@)"), AppLanguage.title(for: language.resolved())) : language.title)
                        .tag(language)
                }
            }
            label: {
                HStack(spacing: 6) {
                    Text(T("Language"))
                    InfoButton(T("Language changes apply immediately. System default follows the language set in System Settings."))
                }
            }
            .accessibilityIdentifier("languagePicker")
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(-8)
    }
}

/// The workspace theme, previewed live and kept only when applied.
private struct AppearanceSettings: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(T("Color theme")).font(.headline)
                InfoButton(T("Preview changes the workspace. Apply saves the theme; Cancel restores it."))
            }
            ThemeGallery(themes: model.themes, selectedID: model.themePreview?.selectedID ?? model.themeID) { id in
                model.beginThemePreview()
                do { try model.focusThemePreview(id) }
                catch { model.error = error.localizedDescription }
            }.frame(height: 312)
            if let error = model.error { Text(T(error)).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(T("Cancel preview")) { model.cancelThemePreview(); model.beginThemePreview() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelThemePreview")
                    .disabled(model.themePreview == nil || model.themePreview?.selectedID == model.themeID)
                Spacer()
                Button(T("Apply theme")) {
                    do { try model.applyThemePreview(); model.beginThemePreview() }
                    catch { model.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("applyThemePreview")
                .disabled(model.themePreview == nil || model.themePreview?.selectedID == model.themeID)
            }
        }
        .padding(.horizontal, 4)
        // A preview lasts while this pane is showing; leaving the pane or closing the window puts the theme back.
        .background(PreferencesWindowObserver(open: { model.beginThemePreview() }, close: { model.cancelThemePreview() }))
        .onAppear { model.beginThemePreview() }
        .onDisappear { model.cancelThemePreview() }
    }
}

private struct PreferencesWindowObserver: NSViewRepresentable {
    let open: () -> Void
    let close: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(open: open, close: close) }
    func updateNSView(_ view: ObserverView, context: Context) { view.open = open; view.close = close }
    final class ObserverView: NSView {
        var open: () -> Void
        var close: () -> Void
        private var observers: [NSObjectProtocol] = []
        init(open: @escaping () -> Void, close: @escaping () -> Void) { self.open = open; self.close = close; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
            if let window {
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.close() })
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.open() })
            }
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
