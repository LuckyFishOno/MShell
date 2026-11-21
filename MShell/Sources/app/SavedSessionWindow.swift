import AppKit
import SwiftUI

@MainActor final class SavedSessionWindow: NSWindowController, NSWindowDelegate {
    let tab: SessionTab
    private weak var model: WorkspaceModel?
    init(model: WorkspaceModel, tab: SessionTab) {
        self.model = model; self.tab = tab
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tab.title
        window.minSize = NSSize(width: 880, height: 580)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SavedSessionContent(model: model, tab: tab))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Saved session windows require a workspace.") }
    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        // Cancel before yielding so an unstarted auto-connect cannot reopen this session.
        tab.savedConnectionTask?.cancel()
        model.sessionWindows.removeValue(forKey: tab.id)
        Task { await model.disconnect(tab) }
    }
}

private struct SavedSessionContent: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    var body: some View {
        SessionPane(model: model, tab: tab, transferButton: true)
            .background(model.theme.background.color)
            .foregroundStyle(model.theme.foreground.color)
            .tint(model.theme.accent.color)
            .background(ThemeTitlebar(theme: model.theme))
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
            .task { await model.refreshVault() }
    }
}
