import AppKit
import SwiftUI

struct RemoteFilesPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    let compact: Bool
    @State private var pathDraft: String
    @State private var selectedFile: String?
    @State private var renameVisible = false
    @State private var renameTo = ""
    @State private var deleting: String?
    @State private var uploading: URL?

    init(model: WorkspaceModel, tab: SessionTab, compact: Bool = false) {
        self.model = model
        self.tab = tab
        self.compact = compact
        _pathDraft = State(initialValue: tab.remotePath)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { browse((tab.remotePath as NSString).appendingPathComponent("..")) } label: {
                    Image(systemName: "arrow.up")
                }.help(T("Parent folder")).disabled(!tab.filesLoaded || tab.remotePath == "/")
                TextField(T("Remote directory"), text: $pathDraft).onSubmit { browse(pathDraft) }
                    .accessibilityIdentifier("remotePathField")
                Button { browse(pathDraft) } label: { Image(systemName: "arrow.clockwise") }
                    .help(T("Refresh")).accessibilityLabel(T("Refresh")).accessibilityIdentifier("refreshFilesButton")
                Button(T("Upload…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { upload(url) }
                }.accessibilityIdentifier("uploadButton").disabled(!tab.filesLoaded)
            }.disabled(!tab.connected || tab.busy)
            List(selection: $selectedFile) {
                ForEach(tab.entries.sorted { $0.isDirectory && !$1.isDirectory }, id: \.name) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                        Text(entry.name)
                        Spacer()
                        if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).foregroundStyle(.secondary) }
                    }.tag(entry.name)
                }
            }
            // The list handles single-click selection and double-click opening itself; a tap gesture
            // on each row would swallow clicks and leave the file actions disabled.
            .contextMenu(forSelectionType: String.self) { names in
                if let name = names.first, isFile(name) {
                    Button(T("Download…")) { download(name) }
                    Button(T("Rename…")) { selectedFile = name; renameTo = name; renameVisible = true }
                    Button(T("Delete…"), role: .destructive) { deleting = name }
                }
            } primaryAction: { names in
                guard let name = names.first, !tab.busy else { return }
                if isFile(name) { download(name); return }
                do { browse(try model.remoteFile(name, in: tab)) }
                catch { tab.error = error.localizedDescription }
            }
            .onDeleteCommand { if let name = selectedFile, isFile(name), !tab.busy { deleting = name } }
            .dropDestination(for: URL.self) { urls, _ in
                guard tab.filesLoaded, !tab.busy, let url = urls.first(where: \.isFileURL) else { return false }
                upload(url); return true
            }
            .overlay {
                if tab.entries.isEmpty {
                    if tab.busy { ProgressView() }
                    else if !tab.connected { ContentUnavailableView(T("Connect to browse files"), systemImage: "network") }
                    else if tab.filesLoaded { ContentUnavailableView(T("This folder is empty"), systemImage: "folder") }
                    else { ContentUnavailableView(T("No files loaded"), systemImage: "folder") }
                }
            }
            HStack {
                Group {
                Button(T("Download…")) { if let name = selectedFile { download(name) } }
                    .accessibilityIdentifier("downloadButton")
                Button(T("Rename…")) { renameTo = selectedFile ?? ""; renameVisible = true }
                Button(T("Delete…"), role: .destructive) { deleting = selectedFile }
                }.disabled(!tab.connected || tab.busy || selectedFile == nil ||
                    tab.entries.first(where: { $0.name == selectedFile })?.isDirectory == true)
                Spacer()
                if !compact { entryCount }
            }
            if compact { entryCount.frame(maxWidth: .infinity, alignment: .trailing) }
        }
        .controlSize(compact ? .small : .regular)
        .sheet(isPresented: $renameVisible) {
            VStack(alignment: .leading, spacing: 16) {
                Text(T("Rename remote file")).font(.headline)
                TextField(T("New name"), text: $renameTo)
                if let selectedFile, let warning = FileNameCheck.warning(original: selectedFile, chosen: renameTo) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack { Button(T("Cancel")) { renameVisible = false }; Spacer(); Button(T("Rename")) {
                    if let old = selectedFile, let new = FileNameCheck.confirm(original: old, chosen: renameTo) {
                        Task { await model.rename(tab, from: old, to: new); if tab.error == nil { selectedFile = new } }
                    }
                    renameVisible = false
                }.disabled(renameTo.isEmpty) }
            }.padding(24).frame(width: 360)
        }
        .alert(T("Delete remote file?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let file = deleting { Task { await model.remove(tab, name: file) } }; deleting = nil }
        } message: { Text(deleting ?? "") }
        .alert(T("Replace the remote file?"), isPresented: Binding(get: { uploading != nil }, set: { if !$0 { uploading = nil } })) {
            Button(T("Cancel"), role: .cancel) { uploading = nil }
            Button(T("Replace"), role: .destructive) { if let url = uploading { startUpload(url, overwrite: true) }; uploading = nil }
        } message: { Text(String(format: T("%@ already exists in %@. Uploading replaces it."), uploading?.lastPathComponent ?? "", tab.remotePath)) }
        .task(id: tab.connected) {
            if tab.connected && !tab.filesLoaded { await model.refreshFiles(tab) }
        }
        .onChange(of: tab.remotePath) { _, path in selectedFile = nil; pathDraft = path }
        .onChange(of: tab.entries.map(\.name)) { _, names in
            if let selectedFile, !names.contains(selectedFile) { self.selectedFile = nil }
        }
    }

    private var entryCount: some View {
        Text(String(format: T("%d entries"), tab.entries.count)).font(.caption).foregroundStyle(.secondary)
    }
    private func isFile(_ name: String) -> Bool {
        tab.entries.first(where: { $0.name == name }).map { !$0.isDirectory } ?? false
    }
    /// Uploads at once; asks only when a file with the same name would be replaced.
    private func upload(_ url: URL) {
        if tab.entries.contains(where: { $0.name == url.lastPathComponent }) { uploading = url }
        else { startUpload(url, overwrite: false) }
    }
    private func startUpload(_ url: URL, overwrite: Bool) {
        Task {
            await model.upload(tab, local: url, overwrite: overwrite)
            if tab.error == nil { selectedFile = url.lastPathComponent }
        }
    }
    private func download(_ name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        // Show the whole remote name, extension included, so a changed extension is visible.
        panel.isExtensionHidden = false; panel.canSelectHiddenExtension = false
        guard panel.runModal() == .OK, let url = panel.url,
              let chosen = FileNameCheck.confirm(original: name, chosen: url.lastPathComponent) else { return }
        let local = url.deletingLastPathComponent().appendingPathComponent(chosen)
        Task { await model.download(tab, name: name, local: local) }
    }
    private func browse(_ path: String) {
        guard !path.isEmpty else { return }
        let target = path.hasPrefix("/") || !tab.filesLoaded
            ? path : (tab.remotePath as NSString).appendingPathComponent(path)
        Task {
            await model.refreshFiles(tab, navigateTo: target)
            if tab.error == nil { pathDraft = tab.remotePath }
        }
    }

}

/// Warns before a file is saved or renamed with a different extension.
enum FileNameCheck {
    static func extensionLabel(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? T("no extension") : "." + ext
    }

    static func warning(original: String, chosen: String) -> String? {
        let old = (original as NSString).pathExtension, new = (chosen as NSString).pathExtension
        guard !chosen.isEmpty, old.lowercased() != new.lowercased() else { return nil }
        return String(format: T("The extension changes from %@ to %@."), extensionLabel(original), extensionLabel(chosen))
    }

    /// Returns the name to use: `chosen`, the name with the original extension restored, or nil to cancel.
    @MainActor static func confirm(original: String, chosen: String) -> String? {
        guard let message = warning(original: original, chosen: chosen) else { return chosen }
        let alert = NSAlert()
        alert.messageText = T("Change the file extension?")
        alert.informativeText = message + " " + T("The file may open in a different app or stop opening.")
        alert.alertStyle = .warning
        let oldExt = (original as NSString).pathExtension
        let restored = oldExt.isEmpty ? (chosen as NSString).deletingPathExtension : ((chosen as NSString).deletingPathExtension as NSString).appendingPathExtension(oldExt) ?? chosen
        alert.addButton(withTitle: String(format: T("Keep %@"), extensionLabel(original)))
        alert.addButton(withTitle: String(format: T("Use %@"), extensionLabel(chosen)))
        alert.addButton(withTitle: T("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return restored
        case .alertSecondButtonReturn: return chosen
        default: return nil
        }
    }
}
