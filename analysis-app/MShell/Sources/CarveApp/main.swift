import Foundation
import SwiftUI
import AppKit
import App

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "layout" { exit(LayoutCommand.run(arguments)) }
if arguments.contains("--theme-flow-trace") { ThemeFlowProbe.start() }
if arguments.contains("--verify-ssh") { SSHProbe.start(arguments) }
if CarveCommand.handles(arguments) { exit(CarveCommand.run(arguments)) }
MShellApplication.main()

struct MShellApplication: SwiftUI.App {
    @StateObject private var store = ApplicationWorkspace()
    var body: some Scene {
        Window("MShell", id: "workspace") { WorkspaceWindow(store: store) }.defaultSize(width: 1320, height: 840)
            .windowToolbarStyle(.unified(showsTitle: false))
            .commands {
                CommandGroup(replacing: .appSettings) {
                    if let workspace = store.workspace { PreferencesMenuLink(model: workspace) }
                }
                if let workspace = store.workspace { WorkspaceSplitCommands(model: workspace) }
            }
        Settings {
            if let workspace = store.workspace { PreferencesView(model: workspace) }
            else { ProgressView("Opening workspace…").padding().task { store.load() } }
        }
    }
}

@MainActor final class ApplicationWorkspace: ObservableObject {
    @Published var failure: String?
    @Published var workspace: WorkspaceModel?
    func load() {
            guard workspace == nil, failure == nil else { return }
            do {
                if let index = arguments.firstIndex(of: "--workspace"), index + 1 < arguments.count {
                    workspace = try WorkspaceModel(storage: URL(fileURLWithPath: arguments[index + 1]))
                } else { workspace = try WorkspaceModel() }
            } catch { failure = error.localizedDescription }
            if let workspace {
                if let index = arguments.firstIndex(of: "--theme"), index + 1 < arguments.count {
                    do { try workspace.selectTheme(arguments[index + 1]) }
                    catch { failure = error.localizedDescription; workspace.error = error.localizedDescription }
                }
                workspace.tabs.removeAll(); workspace.addLocalTab()
            }
            NSApp.activate(ignoringOtherApps: true)
    }
}

struct WorkspaceWindow: View {
    @ObservedObject var store: ApplicationWorkspace
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Group {
            if let workspace = store.workspace { DesktopView(model: workspace) }
            else if let failure = store.failure { ContentUnavailableView("Workspace could not be opened", systemImage: "exclamationmark.triangle", description: Text(failure)).frame(width: 600, height: 300) }
            else { ProgressView("Opening workspace…").frame(width: 600, height: 300) }
        }.task {
            store.load()
            if arguments.contains("--show-preferences") { openSettings() }
            if let index = arguments.firstIndex(of: "--preview-theme"), index + 1 < arguments.count, let model = store.workspace {
                model.beginThemePreview()
                do { try model.focusThemePreview(arguments[index + 1]) } catch { model.error = error.localizedDescription }
            }
            SmokeCapture.scheduleIfRequested {
                guard let model = store.workspace else { return [:] }
                return ["savedTheme": model.themeID, "displayedTheme": model.displayedThemeID, "previewOpen": model.themePreview != nil,
                        "localTerminalReady": model.selected?.terminalReady ?? false, "language": model.language.rawValue]
            }
        }
    }
}
