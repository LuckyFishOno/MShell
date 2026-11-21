import AppKit
import SwiftUI
import FileTransfer

/// What the main window's middle area shows in the Mac layout: terminals, or the two-pane file transfer view.
enum WorkspaceMode: String {
    case terminal, files
}

/// The Mac toolbar's Terminal / File Transfer switch. Both halves are as wide as the longer name and center their
/// text, which the system segmented control does not do for names of different lengths.
struct WorkspaceModeSwitch: View {
    let mode: WorkspaceMode
    let theme: WorkspaceTheme
    let choose: (WorkspaceMode) -> Void

    var body: some View {
        EqualWidthRow(spacing: 2) {
            segment(.terminal, T("Terminal"))
            segment(.files, T("File Transfer"))
        }
        .padding(2)
        .background(theme.foreground.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private func segment(_ value: WorkspaceMode, _ title: String) -> some View {
        let selected = mode == value
        return Button { if !selected { choose(value) } } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(theme.foreground.color.opacity(selected ? 1 : 0.6))
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 5).fill(theme.background.color)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays its children out in a row, each as wide as the widest one.
struct EqualWidthRow: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.map(\.width).max() ?? 0
        return CGSize(width: width * CGFloat(sizes.count) + spacing * CGFloat(max(0, sizes.count - 1)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// Which server the two-pane view shows. In the Mac layout's main window it follows the selected tab; in the Xshell
/// and MobaXterm layouts' own window it is picked from a menu, like Xftp.
@MainActor final class TransferTarget: ObservableObject {
    let followsSelection: Bool
    @Published var tabID: UUID?
    init(followsSelection: Bool) { self.followsSelection = followsSelection }
}

/// The Xshell and MobaXterm layouts open file transfer in its own window, as Xshell opens Xftp.
@MainActor final class FileTransferWindow: NSWindowController {
    let target = TransferTarget(followsSelection: false)
    let local = LocalBrowserState()

    init(model: WorkspaceModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = T("File Transfer")
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: FileTransferWindowContent(model: model, local: local, target: target))
        if !window.setFrameUsingName("MShellFileTransfer") { window.center() }
        window.setFrameAutosaveName("MShellFileTransfer")
    }
    required init?(coder: NSCoder) { fatalError("The transfer window requires a workspace.") }

    func select(_ tab: SessionTab?) {
        if let tab { target.tabID = tab.id }
    }
}

private struct FileTransferWindowContent: View {
    @ObservedObject var model: WorkspaceModel
    let local: LocalBrowserState
    let target: TransferTarget
    var body: some View {
        FileTransferView(model: model, local: local, queue: model.transfers, target: target)
            .foregroundStyle(model.theme.foreground.color)
            .tint(model.theme.accent.color)
            .background(ThemeTitlebar(theme: model.theme))
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
    }
}

// MARK: - Browser state

struct LocalItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
    var id: String { url.path }
    /// The `..` row at the top of a file list.
    var isParent: Bool { name == ".." }
}

@MainActor final class LocalBrowserState: ObservableObject {
    @Published var folder = FileManager.default.homeDirectoryForCurrentUser
    @Published var items: [LocalItem] = []
    @Published var showsHidden = false
    @Published var error: String?

    func load(_ url: URL? = nil) {
        let target = (url ?? folder).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys,
                                                                    options: showsHidden ? [] : [.skipsHiddenFiles])
            items = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return LocalItem(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true,
                                 size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
            }
            folder = target; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct RemoteItem: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Date
    let permissions: UInt32?
    var id: String { path }
    /// The `..` row at the top of a file list.
    var isParent: Bool { name == ".." }
}

@MainActor final class RemoteBrowserState: ObservableObject {
    @Published var folder: String?
    @Published var items: [RemoteItem] = []
    @Published var showsHidden = false
    @Published var loading = false
    @Published var error: String?

    func load(_ path: String?, model: WorkspaceModel, tab: SessionTab) async {
        loading = true; defer { loading = false }
        do {
            let transfer = try await model.sftp(for: tab)
            let directory = try await transfer.readDirectory(path ?? folder ?? ".")
            items = directory.entries.map {
                RemoteItem(path: RemoteTreeState.child(directory.path, $0.name), name: $0.name, isDirectory: $0.isDirectory,
                           size: $0.size ?? 0, modified: $0.modified ?? .distantPast, permissions: $0.permissions)
            }
            folder = directory.path; error = nil
        } catch { self.error = message(for: error) }
    }

    func clear() { folder = nil; items = []; error = nil }
}

// MARK: - Two-pane view

/// This Mac on the left and the selected session's server on the right, like WinSCP or FileZilla, with the transfer
/// queue below. It takes the main window's middle area in every layout; the tab bar above picks the server.
struct FileTransferView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var local: LocalBrowserState
    @ObservedObject var queue: TransferQueue
    @ObservedObject var target: TransferTarget
    @State private var localSelection = Set<String>()
    @State private var remoteSelection = Set<String>()
    @State private var pending: PendingTransfer?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                // In the main window the toolbar's switch and the tab bar already say what this is and which server.
                if !target.followsSelection {
                    titleBar
                    Divider()
                }
                HStack(spacing: 0) {
                    LocalFilePane(local: local, selection: $localSelection, upload: { urls in upload(urls) },
                                  download: { paths in download(paths) })
                    transferButtons
                    remotePane
                }
            }
            .frame(minHeight: 260)
            TransferQueueView(queue: queue).frame(minHeight: 100, idealHeight: 150)
        }
        .background(model.theme.background.color)
        .onAppear {
            if local.items.isEmpty { local.load() }
            if !target.followsSelection, target.tabID == nil {
                target.tabID = (model.selected.flatMap { $0.connected && !$0.isLocal ? $0 : nil } ?? model.remoteTabs.first)?.id
            }
        }
        .onChange(of: queue.revision) { _, _ in
            local.load()
            if let tab = currentTab { Task { await tab.remoteBrowser.load(nil, model: model, tab: tab) } }
        }
        .alert(T("Replace existing files?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(T("Replace"), role: .destructive) { pending?.start(.replace); pending = nil }
            Button(T("Skip existing")) { pending?.start(.skip); pending = nil }
            Button(T("Cancel"), role: .cancel) { pending = nil }
        } message: { Text(pending.map { $0.conflicts.joined(separator: "\n") } ?? "") }
    }

    /// The server on the right: the selected tab, or a session from its own window that asked to show its files.
    private var currentTab: SessionTab? {
        let tab = target.followsSelection ? model.transferTab : model.remoteTabs.first { $0.id == target.tabID }
        return tab.flatMap { $0.connected && !$0.isLocal ? $0 : nil }
    }

    /// The transfer window's top row. That window has no tab bar, so the server is chosen here.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(model.theme.accent.color)
            Text(T("File Transfer")).font(.system(size: 13, weight: .semibold))
            Picker(T("Server"), selection: Binding(get: { target.tabID }, set: { target.tabID = $0 })) {
                if currentTab == nil { Text(T("No connected server")).tag(UUID?.none) }
                ForEach(model.remoteTabs, id: \.id) { tab in
                    Text("\(tab.username)@\(tab.host)" + (tab.title != tab.host && tab.title != "New connection" ? "  ·  \(tab.title)" : ""))
                        .tag(Optional(tab.id))
                }
            }
            .labelsHidden().frame(maxWidth: 340)
            Spacer()
            if queue.isActive { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder private var remotePane: some View {
        if let tab = currentTab {
            RemoteFilePane(model: model, tab: tab, remote: tab.remoteBrowser, selection: $remoteSelection,
                           upload: { urls in upload(urls) }, download: { paths in download(paths) })
                .id(tab.id)
        } else {
            ContentUnavailableView(T("No connected server"), systemImage: "network",
                                   description: Text(T(target.followsSelection ? "Select a tab connected over SSH to show its server here."
                                                       : "Connect to a server over SSH, then choose it above.")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transferButtons: some View {
        VStack(spacing: 10) {
            Spacer()
            Button { upload(local.items.filter { localSelection.contains($0.id) }.map(\.url)) } label: {
                Image(systemName: "arrow.right").frame(width: 22, height: 18)
            }
            .help(T("Upload the selected files to the server"))
            .disabled(localSelection.isEmpty || currentTab?.remoteBrowser.folder == nil)
            Button { download((currentTab?.remoteBrowser.items ?? []).filter { remoteSelection.contains($0.id) }.map { ($0.path, $0.isDirectory) }) } label: {
                Image(systemName: "arrow.left").frame(width: 22, height: 18)
            }
            .help(T("Download the selected files to this Mac"))
            .disabled(remoteSelection.isEmpty || currentTab == nil)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(model.theme.sidebar.color.opacity(0.5))
    }

    private func upload(_ urls: [URL]) {
        guard let tab = currentTab, let folder = tab.remoteBrowser.folder, !urls.isEmpty else { return }
        Task {
            let conflicts = await queue.remoteConflicts(urls.map(\.lastPathComponent), in: folder, via: tab)
            let start: (TransferConflictPolicy) -> Void = { policy in queue.upload(urls, to: folder, via: tab, policy: policy) }
            if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
        }
    }

    private func download(_ paths: [(path: String, isDirectory: Bool)]) {
        guard let tab = currentTab, !paths.isEmpty else { return }
        let folder = local.folder
        let conflicts = TransferQueue.localConflicts(paths.map { ($0.path as NSString).lastPathComponent }, in: folder)
        let start: (TransferConflictPolicy) -> Void = { policy in queue.download(paths, to: folder, via: tab, policy: policy) }
        if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
    }
}

// MARK: - Panes

/// Drag payload for remote rows dropped on the local pane.
enum RemoteFileDrag {
    static let prefix = "mshell-remote-file:"
    static func payload(_ item: RemoteItem) -> String { prefix + (item.isDirectory ? "d:" : "f:") + item.path }
    static func parse(_ text: String) -> (path: String, isDirectory: Bool)? {
        guard text.hasPrefix(prefix) else { return nil }
        let body = text.dropFirst(prefix.count)
        guard body.count > 2 else { return nil }
        return (String(body.dropFirst(2)), body.hasPrefix("d:"))
    }
}

private struct PaneTitle: View {
    let symbol: String
    let title: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct LocalFilePane: View {
    @ObservedObject var local: LocalBrowserState
    @Binding var selection: Set<String>
    let upload: ([URL]) -> Void
    let download: ([(path: String, isDirectory: Bool)]) -> Void
    @State private var sortOrder = [KeyPathComparator(\LocalItem.name, comparator: .localizedStandard)]
    @State private var pathDraft = ""
    @State private var naming: LocalNaming?
    @State private var nameDraft = ""
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PaneTitle(symbol: "laptopcomputer", title: T("This Mac"))
                Spacer()
                Toggle(T("Hidden files"), isOn: $local.showsHidden).toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: local.showsHidden) { _, _ in local.load() }
            }
            HStack(spacing: 4) {
                Button { local.load(local.folder.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(local.folder.path == "/")
                Button { local.load(FileManager.default.homeDirectoryForCurrentUser) } label: { Image(systemName: "house") }
                    .help(T("Home folder"))
                TextField(T("Local folder"), text: $pathDraft).textFieldStyle(.roundedBorder)
                    .onSubmit { local.load(URL(fileURLWithPath: (pathDraft as NSString).expandingTildeInPath)) }
                Button { local.load() } label: { Image(systemName: "arrow.clockwise") }.help(T("Refresh"))
                Button { nameDraft = ""; naming = LocalNaming(rename: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help(T("New folder…"))
            }
            .buttonStyle(.borderless)
            if let error = local.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Table(of: LocalItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(T("Name"), value: \.name, comparator: .localizedStandard) { item in
                    Label { Text(item.name).lineLimit(1) } icon: {
                        if item.isParent { Image(systemName: "arrow.turn.left.up") }
                        else { Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 16, height: 16) }
                    }
                }.width(min: 160, ideal: 260)
                TableColumn(T("Size"), value: \.size) { item in
                    Text(item.isParent ? "" : item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }.width(min: 60, ideal: 80)
                TableColumn(T("Modified"), value: \.modified) { item in
                    Text(item.isParent ? "" : item.modified.formatted(.dateTime.year().month().day().hour().minute())).foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
            } rows: {
                ForEach(sorted) { item in
                    TableRow(item).itemProvider { item.isParent ? nil : NSItemProvider(contentsOf: item.url) }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let chosen = local.items.filter { ids.contains($0.id) }
                Button(T("Upload")) { upload(chosen.map(\.url)) }.disabled(chosen.isEmpty)
                Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url)) }.disabled(chosen.isEmpty)
                Divider()
                Button(T("Rename…")) {
                    if let item = chosen.first { nameDraft = item.name; naming = LocalNaming(rename: item) }
                }.disabled(chosen.count != 1)
                Button(T("Move to Trash"), role: .destructive) {
                    for item in chosen { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
                    local.load()
                }.disabled(chosen.isEmpty)
            } primaryAction: { ids in
                guard let item = sorted.first(where: { ids.contains($0.id) }) else { return }
                if item.isDirectory { local.load(item.url) } else { upload([item.url]) }
            }
            .dropDestination(for: String.self) { texts, _ in
                // Remote rows dropped here download into this folder.
                let paths = texts.compactMap(RemoteFileDrag.parse)
                guard !paths.isEmpty else { return false }
                download(paths); return true
            } isTargeted: { dropTargeted = $0 }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
        }
        .padding(10)
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pathDraft = local.folder.path }
        .onChange(of: local.folder) { _, folder in pathDraft = folder.path; selection = [] }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.rename == nil ? T("New folder") : T("Rename")).font(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                HStack {
                    Button(T("Cancel")) { naming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.rename == nil ? T("Create") : T("Rename")) { finish(request) }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
    }

    /// Folders first in the chosen order, under a `..` row that opens the parent folder, as in WinSCP and FileZilla.
    private var sorted: [LocalItem] {
        let items = local.items.sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
        guard local.folder.path != "/" else { return items }
        let parent = local.folder.deletingLastPathComponent()
        return [LocalItem(url: parent, name: "..", isDirectory: true, size: 0, modified: .distantPast)] + items
    }

    private func finish(_ request: LocalNaming) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        naming = nil
        do {
            if let item = request.rename {
                try FileManager.default.moveItem(at: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(name))
            } else {
                try FileManager.default.createDirectory(at: local.folder.appendingPathComponent(name), withIntermediateDirectories: false)
            }
        } catch { local.error = error.localizedDescription }
        local.load()
    }
}

private struct LocalNaming: Identifiable {
    let id = UUID()
    let rename: LocalItem?
}

private struct RemoteFilePane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var remote: RemoteBrowserState
    @Binding var selection: Set<String>
    let upload: ([URL]) -> Void
    let download: ([(path: String, isDirectory: Bool)]) -> Void
    @State private var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]
    @State private var pathDraft = ""
    @State private var naming: RemoteNaming?
    @State private var nameDraft = ""
    @State private var deleting: [RemoteItem] = []
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PaneTitle(symbol: "server.rack", title: "\(tab.username)@\(tab.host)")
                Spacer()
                Toggle(T("Hidden files"), isOn: $remote.showsHidden).toggleStyle(.checkbox).controlSize(.small)
            }
            HStack(spacing: 4) {
                Button { go((remote.folder.map { ($0 as NSString).deletingLastPathComponent }) ?? "/") } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(remote.folder == nil || remote.folder == "/")
                Button { go(".") } label: { Image(systemName: "house") }.help(T("Home folder"))
                TextField(T("Remote directory"), text: $pathDraft).textFieldStyle(.roundedBorder).onSubmit { go(pathDraft) }
                Button { go(nil) } label: { Image(systemName: "arrow.clockwise") }.help(T("Refresh"))
                Button { nameDraft = ""; naming = RemoteNaming(rename: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help(T("New folder…")).disabled(remote.folder == nil)
            }
            .buttonStyle(.borderless)
            if let error = remote.error { Text(T(error)).font(.caption).foregroundStyle(.red).lineLimit(2) }
            Table(of: RemoteItem.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(T("Name"), value: \.name, comparator: .localizedStandard) { item in
                    Label(item.name, systemImage: item.isParent ? "arrow.turn.left.up" : item.isDirectory ? "folder.fill" : "doc").lineLimit(1)
                }.width(min: 160, ideal: 260)
                TableColumn(T("Size"), value: \.size) { item in
                    Text(item.isParent ? "" : item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                }.width(min: 60, ideal: 80)
                TableColumn(T("Modified"), value: \.modified) { item in
                    Text(item.modified == .distantPast ? "" : item.modified.formatted(.dateTime.year().month().day().hour().minute()))
                        .foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
                TableColumn(T("Permissions")) { item in
                    Text(item.permissions.map(Self.mode) ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 90)
            } rows: {
                ForEach(sorted) { item in
                    TableRow(item).itemProvider { item.isParent ? nil : NSItemProvider(object: RemoteFileDrag.payload(item) as NSString) }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let chosen = remote.items.filter { ids.contains($0.id) }
                Button(T("Download")) { download(chosen.map { ($0.path, $0.isDirectory) }) }.disabled(chosen.isEmpty)
                Divider()
                Button(T("Rename…")) {
                    if let item = chosen.first { nameDraft = item.name; naming = RemoteNaming(rename: item) }
                }.disabled(chosen.count != 1)
                Button(T("Copy path")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chosen.map(\.path).joined(separator: "\n"), forType: .string)
                }.disabled(chosen.isEmpty)
                Divider()
                Button(T("Delete…"), role: .destructive) { deleting = chosen }.disabled(chosen.isEmpty)
            } primaryAction: { ids in
                guard let item = sorted.first(where: { ids.contains($0.id) }) else { return }
                if item.isDirectory { go(item.path) } else { download([(item.path, false)]) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                upload(files); return true
            } isTargeted: { dropTargeted = $0 }
            .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
            .overlay { if remote.loading && remote.items.isEmpty { ProgressView() } }
        }
        .padding(10)
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: tab.connected) {
            if tab.connected, remote.folder == nil { await remote.load(".", model: model, tab: tab) }
        }
        .onChange(of: remote.folder) { _, folder in pathDraft = folder ?? ""; selection = [] }
        .onAppear { pathDraft = remote.folder ?? "" }
        .alert(T("Delete from the server?"), isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button(T("Cancel"), role: .cancel) { deleting = [] }
            Button(T("Delete"), role: .destructive) { delete(deleting); deleting = [] }
        } message: { Text(deleting.map(\.path).joined(separator: "\n")) }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.rename == nil ? T("New remote folder") : T("Rename remote item")).font(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                HStack {
                    Button(T("Cancel")) { naming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.rename == nil ? T("Create") : T("Rename")) { finish(request) }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
    }

    /// Folders first in the chosen order, under a `..` row that opens the parent folder, as in WinSCP and FileZilla.
    private var sorted: [RemoteItem] {
        let items = remote.items.filter { remote.showsHidden || !$0.name.hasPrefix(".") }
            .sorted(using: sortOrder).sorted { $0.isDirectory && !$1.isDirectory }
        guard let folder = remote.folder, folder != "/" else { return items }
        let parent = (folder as NSString).deletingLastPathComponent
        return [RemoteItem(path: parent.isEmpty ? "/" : parent, name: "..", isDirectory: true, size: 0, modified: .distantPast,
                           permissions: nil)] + items
    }

    /// `rwxr-xr-x` from a POSIX mode.
    static func mode(_ permissions: UInt32) -> String {
        let marks = Array("rwxrwxrwx")
        return (permissions & 0o170000 == 0o040000 ? "d" : "-") + String((0..<9).map { permissions & (1 << (8 - $0)) != 0 ? marks[$0] : "-" })
    }

    private func go(_ path: String?) {
        Task { await remote.load(path?.isEmpty == true ? nil : path, model: model, tab: tab) }
    }

    private func delete(_ items: [RemoteItem]) {
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                for item in items { try await RemoteDelete.remove(item.path, isDirectory: item.isDirectory, with: transfer) }
            } catch { remote.error = message(for: error) }
            await remote.load(nil, model: model, tab: tab)
        }
    }

    private func finish(_ request: RemoteNaming) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), let folder = remote.folder else { return }
        naming = nil
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                if let item = request.rename {
                    guard let chosen = FileNameCheck.confirm(original: item.name, chosen: name) else { return }
                    let destination = RemoteTreeState.child(folder, chosen)
                    if try await transfer.entry(at: destination) != nil { throw WorkspaceError.alreadyExists(chosen) }
                    try await transfer.rename(from: item.path, to: destination)
                } else {
                    try await transfer.makeDirectory(RemoteTreeState.child(folder, name))
                }
            } catch { remote.error = message(for: error) }
            await remote.load(nil, model: model, tab: tab)
        }
    }
}

private struct RemoteNaming: Identifiable {
    let id = UUID()
    let rename: RemoteItem?
}

// MARK: - Queue

struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(T("Transfers"), systemImage: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(T("Cancel all")) { queue.cancelAll() }.disabled(!queue.isActive)
                Button(T("Clear finished")) { queue.clearFinished() }.disabled(!queue.items.contains { $0.state.isFinished })
            }
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if queue.items.isEmpty {
                Text(T("Drag files between the panes, or use the arrows, to transfer them."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(queue.items.reversed()) { item in TransferRow(item: item) { queue.cancel(item) } }
                    .listStyle(.plain)
            }
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(item.direction == .upload ? Color.accentColor : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.secondary).font(.caption)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Text(item.direction == .upload ? "→ \(item.host):\(item.destinationFolder)" : "← \(item.host)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if item.state == .running {
                    ProgressView(value: item.fraction ?? 0).controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            Text(detail).font(.caption).foregroundStyle(stateColor).lineLimit(1)
            if !item.state.isFinished {
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(T("Cancel"))
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let size = item.total.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
        switch item.state {
        case .waiting: return T("Waiting")
        case .running:
            let moved = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.bytes), countStyle: .file)
            let files = item.isFolder ? String(format: T("%d of %d files"), item.filesDone, item.fileCount) + " · " : ""
            return files + (size.map { "\(moved) / \($0)" } ?? moved)
        case .done: return T("Done") + (size.map { " · \($0)" } ?? "")
        case .skipped: return T("Skipped, already there")
        case .cancelled: return T("Cancelled")
        case .failed(let reason): return T(reason)
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
