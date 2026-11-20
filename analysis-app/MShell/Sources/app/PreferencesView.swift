import SwiftUI
import AppKit

public struct PreferencesMenuLink: View {
    @ObservedObject private var model: WorkspaceModel
    @Environment(\.openSettings) private var openSettings
    public init(model: WorkspaceModel) { self.model = model }
    public var body: some View {
        Button(UIStrings.text("Preferences…", language: model.language)) { openSettings() }.keyboardShortcut(",", modifiers: .command)
    }
}

public struct PreferencesView: View {
    @ObservedObject private var model: WorkspaceModel
    public init(model: WorkspaceModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(T("Preferences")).font(.title2.bold())
            Form {
                Picker(T("Language"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("languagePicker")
                Text(T("Language changes apply immediately.")).font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                Text(T("Color theme")).font(.headline)
                Text(T("Preview changes the workspace. Apply saves the theme; Cancel restores it."))
                    .font(.caption).foregroundStyle(.secondary)
                ThemeGallery(themes: model.themes, selectedID: model.themePreview?.selectedID ?? model.themeID) { id in
                    model.beginThemePreview()
                    do { try model.focusThemePreview(id) }
                    catch { model.error = error.localizedDescription }
                }.frame(height: 312)
            }
            if let error = model.error { Text(T(error)).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(T("Cancel preview")) { model.cancelThemePreview(); NSApp.keyWindow?.performClose(nil) }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelThemePreview")
                Spacer()
                Button(T("Apply theme")) {
                    do { try model.applyThemePreview(); NSApp.keyWindow?.performClose(nil) }
                    catch { model.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("applyThemePreview")
            }
        }.padding(24).frame(width: 475)
        .background(model.theme.background.color)
        .foregroundStyle(model.theme.foreground.color)
        .background(ThemeTitlebar(theme: model.theme))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .tint(model.theme.accent.color)
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
