import AppKit
import SwiftUI
import FileTransfer

/// The folders of one session's remote file tree: which are open and what each one holds.
@MainActor final class RemoteTreeState: ObservableObject {
    @Published var root: String?
    @Published var children: [String: [RemoteEntry]] = [:]
    @Published var expanded: Set<String> = []
    @Published var loading: Set<String> = []
    @Published var selection: String?
    @Published var error: String?

    func reset() {
        root = nil; children = [:]; expanded = []; loading = []; selection = nil; error = nil
    }

    static func child(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    /// Opens `path` (the login folder when nil) as the top of the tree.
    func open(_ path: String?, model: WorkspaceModel, tab: SessionTab) async {
        do {
            let resolved = try await model.sftp(for: tab).resolve(path ?? ".")
            root = resolved; expanded = []; children = [:]; selection = nil; error = nil
            await load(resolved, model: model, tab: tab)
        } catch { self.error = message(for: error) }
    }

    func load(_ folder: String, model: WorkspaceModel, tab: SessionTab) async {
        loading.insert(folder); defer { loading.remove(folder) }
        do {
            let entries = try await model.sftp(for: tab).listDirectory(folder)
            children[folder] = entries.sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            error = nil
        } catch { self.error = message(for: error) }
    }

    func toggle(_ folder: String, model: WorkspaceModel, tab: SessionTab) async {
        if expanded.contains(folder) { expanded.remove(folder); return }
        expanded.insert(folder)
        if children[folder] == nil { await load(folder, model: model, tab: tab) }
    }

    /// Where the Upload button sends files: the selected folder, the folder of the selected file, or the top folder.
    var uploadFolder: String? {
        guard let root else { return nil }
        guard let selection, selection != root else { return root }
        let parent = (selection as NSString).deletingLastPathComponent
        let name = (selection as NSString).lastPathComponent
        let isFolder = children[parent]?.first { $0.name == name }?.isDirectory ?? false
        return isFolder ? selection : parent
    }

    /// Reloads the top folder and every open folder, dropping ones that no longer exist.
    func refresh(model: WorkspaceModel, tab: SessionTab) async {
        guard let root else { return await open(nil, model: model, tab: tab) }
        for folder in [root] + expanded.sorted() where folder == root || children[folder] != nil || expanded.contains(folder) {
            await load(folder, model: model, tab: tab)
        }
    }
}

/// Removes remote files and folders, emptying folders first.
@MainActor enum RemoteDelete {
    static func remove(_ path: String, isDirectory: Bool, with transfer: SFTPTransfer) async throws {
        if isDirectory {
            for entry in try await transfer.listDirectory(path) {
                try await remove(RemoteTreeState.child(path, entry.name), isDirectory: entry.isDirectory, with: transfer)
            }
            try await transfer.removeDirectory(path)
        } else {
            try await transfer.removeFile(path)
        }
    }
}

/// Files waiting for the user to choose whether to replace ones with the same name.
struct PendingTransfer: Identifiable {
    let id = UUID()
    let conflicts: [String]
    let start: (TransferConflictPolicy) -> Void
}

/// The Mac layout's right-hand panel: the files of the focused pane as a folder tree. A server pane shows the server's
/// files from its login folder; the local terminal shows this Mac's home folder.
struct RemoteFileSidebar: View {
    @ObservedObject var model: WorkspaceModel
    let close: () -> Void
    /// Bumped by the Upload button; the remote tree answers by asking which files to send.
    @State private var uploadRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(T(focusedTab?.isLocal == true ? "Local files" : "Remote files"), systemImage: "folder").font(.headline)
                Spacer()
                if let tab = focusedTab, !tab.isLocal {
                    SidebarUploadButton(tab: tab, tree: tab.remoteTree) { uploadRequest += 1 }
                }
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.plain).help(T("Hide files")).accessibilityLabel(T("Hide files"))
            }
            if let tab = focusedTab {
                if tab.isLocal {
                    LocalTreePanel(model: model, tree: model.localTree, queue: model.transfers)
                } else {
                    RemoteTreePanel(model: model, tab: tab, tree: tab.remoteTree, queue: model.transfers, uploadRequest: uploadRequest)
                        .id(tab.id)
                }
            } else {
                ContentUnavailableView(T("No remote session"), systemImage: "network",
                                       description: Text(T("Select a pane connected over SSH to browse its files.")))
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(13)
        .frame(width: 280)
        .background(model.theme.sidebar.color)
    }

    private var focusedTab: SessionTab? { model.selected }
}

/// The labeled Upload button in the file sidebar's title, usable once the server's files are showing.
private struct SidebarUploadButton: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var tree: RemoteTreeState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(T("Upload"), systemImage: "arrow.up.doc").labelStyle(.titleAndIcon).font(.system(size: 11))
        }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!tab.connected || tree.root == nil)
        .help(T("Upload files to the selected folder"))
        .accessibilityIdentifier("sidebarUploadButton")
    }
}

private struct RemoteTreePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @ObservedObject var tree: RemoteTreeState
    @ObservedObject var queue: TransferQueue
    let uploadRequest: Int
    @State private var pathDraft = ""
    @State private var pending: PendingTransfer?
    @State private var naming: NamingRequest?
    @State private var nameDraft = ""
    @State private var deleting: RemoteRow?
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tab.connected {
                ContentUnavailableView(T("Connect to browse files"), systemImage: "network").frame(maxHeight: .infinity)
            } else {
                header
                treeList
                TransferStatusStrip(queue: queue) { model.openFileTransfer(for: tab) }
            }
        }
        .task(id: tab.connected) {
            if tab.connected, tree.root == nil { await tree.open(nil, model: model, tab: tab) }
        }
        .onChange(of: tree.root) { _, root in pathDraft = root ?? "" }
        .onAppear { pathDraft = tree.root ?? "" }
        .onChange(of: queue.revision) { _, _ in Task { await tree.refresh(model: model, tab: tab) } }
        .onChange(of: uploadRequest) { _, _ in if let folder = tree.uploadFolder { chooseUpload(to: folder) } }
        .alert(T("Replace existing files?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(T("Replace"), role: .destructive) { pending?.start(.replace); pending = nil }
            Button(T("Skip existing")) { pending?.start(.skip); pending = nil }
            Button(T("Cancel"), role: .cancel) { pending = nil }
        } message: { Text(pending.map { $0.conflicts.joined(separator: "\n") } ?? "") }
        .alert(T("Delete from the server?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let row = deleting { delete(row) }; deleting = nil }
        } message: {
            Text(deleting.map { $0.entry.isDirectory ? String(format: T("%@ and everything in it will be deleted."), $0.path) : $0.path } ?? "")
        }
        .sheet(item: $naming) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.title).font(.headline)
                TextField(T("Name"), text: $nameDraft).onSubmit { finish(request) }
                HStack {
                    Button(T("Cancel")) { naming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.confirm) { finish(request) }.keyboardShortcut(.defaultAction)
                        .disabled(!Self.validName(nameDraft))
                }
            }.padding(22).frame(width: 340)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(tab.username)@\(tab.host)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Button { open((tree.root.map { ($0 as NSString).deletingLastPathComponent }) ?? "/") } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(tree.root == nil || tree.root == "/")
                Button { open(nil) } label: { Image(systemName: "house") }.help(T("Home folder"))
                TextField(T("Remote directory"), text: $pathDraft).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { open(pathDraft) }
                Button { Task { await tree.refresh(model: model, tab: tab) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(T("Refresh"))
            }
            .buttonStyle(.borderless).controlSize(.small)
            if let error = tree.error {
                Label(T(error), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let root = tree.root {
                    if root != "/" { TreeParentRow { open((root as NSString).deletingLastPathComponent) } }
                    ForEach(rows(in: root, depth: 0)) { row in rowView(row) }
                    if tree.children[root]?.isEmpty == true {
                        Text(T("This folder is empty")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                } else if tree.loading.isEmpty == false {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
        .background(dropTarget == tree.root ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        // Files dropped from Finder on empty space go to the top folder.
        .dropDestination(for: URL.self) { urls, _ in
            guard let root = tree.root else { return false }
            upload(urls, to: root); return true
        } isTargeted: { dropTarget = $0 ? tree.root : (dropTarget == tree.root ? nil : dropTarget) }
    }

    /// The visible rows under `folder`: each entry, followed by its contents when it is an open folder.
    private func rows(in folder: String, depth: Int) -> [RemoteRow] {
        (tree.children[folder] ?? []).flatMap { entry -> [RemoteRow] in
            let path = RemoteTreeState.child(folder, entry.name)
            let row = RemoteRow(path: path, entry: entry, depth: depth)
            guard entry.isDirectory, tree.expanded.contains(path), depth < 32 else { return [row] }
            return [row] + rows(in: path, depth: depth + 1)
        }
    }

    private func rowView(_ row: RemoteRow) -> some View {
        HStack(spacing: 4) {
            if row.entry.isDirectory {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(tree.expanded.contains(row.path) ? 90 : 0)).frame(width: 12)
            } else { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: row.entry.isDirectory ? "folder.fill" : "doc").font(.system(size: 11))
                .foregroundStyle(row.entry.isDirectory ? Color.accentColor : .secondary)
            Text(row.entry.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if tree.loading.contains(row.path) { ProgressView().controlSize(.mini) }
            else if !row.entry.isDirectory, let size = row.entry.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(background(for: row), in: RoundedRectangle(cornerRadius: 4))
        .onTapGesture(count: 2) { activate(row) }
        .simultaneousGesture(TapGesture().onEnded {
            tree.selection = row.path
            if row.entry.isDirectory { Task { await tree.toggle(row.path, model: model, tab: tab) } }
        })
        .contextMenu { menu(for: row) }
        .modifier(FolderDrop(enabled: row.entry.isDirectory, path: row.path, target: $dropTarget) { urls in upload(urls, to: row.path) })
        .help(row.path)
    }

    private func background(for row: RemoteRow) -> Color {
        if dropTarget == row.path { return Color.accentColor.opacity(0.22) }
        return tree.selection == row.path ? Color.accentColor.opacity(0.14) : .clear
    }

    @ViewBuilder private func menu(for row: RemoteRow) -> some View {
        let folder = row.entry.isDirectory ? row.path : (row.path as NSString).deletingLastPathComponent
        if row.entry.isDirectory {
            Button(T("Open as top folder")) { open(row.path) }
            Button(T("Upload files here…")) { chooseUpload(to: row.path) }
        }
        Button(T("Download…")) { chooseDownload(row) }
        Divider()
        Button(T("New folder…")) { nameDraft = ""; naming = NamingRequest(kind: .folder(in: folder)) }
        Button(T("Rename…")) { nameDraft = row.entry.name; naming = NamingRequest(kind: .rename(row.path)) }
        Button(T("Copy path")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string)
        }
        Divider()
        Button(T("Delete…"), role: .destructive) { deleting = row }
    }

    private func activate(_ row: RemoteRow) {
        tree.selection = row.path
        if !row.entry.isDirectory { chooseDownload(row) }
    }

    private func open(_ path: String?) {
        Task { await tree.open(path?.isEmpty == true ? nil : path, model: model, tab: tab) }
    }

    private func chooseUpload(to folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = T("Upload")
        if panel.runModal() == .OK { upload(panel.urls, to: folder) }
    }

    private func chooseDownload(_ row: RemoteRow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = T("Download here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let conflicts = TransferQueue.localConflicts([row.entry.name], in: folder)
        let start: (TransferConflictPolicy) -> Void = { policy in
            queue.download([(row.path, row.entry.isDirectory)], to: folder, via: tab, policy: policy)
        }
        if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
    }

    private func upload(_ urls: [URL], to folder: String) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        Task {
            let conflicts = await queue.remoteConflicts(files.map(\.lastPathComponent), in: folder, via: tab)
            let start: (TransferConflictPolicy) -> Void = { policy in queue.upload(files, to: folder, via: tab, policy: policy) }
            if conflicts.isEmpty { start(.replace) } else { pending = PendingTransfer(conflicts: conflicts, start: start) }
            if !tree.expanded.contains(folder), folder != tree.root { tree.expanded.insert(folder) }
        }
    }

    private func delete(_ row: RemoteRow) {
        Task {
            do {
                try await RemoteDelete.remove(row.path, isDirectory: row.entry.isDirectory, with: model.sftp(for: tab))
                if tree.selection == row.path { tree.selection = nil }
                tree.expanded.remove(row.path)
            } catch { tree.error = message(for: error) }
            await tree.refresh(model: model, tab: tab)
        }
    }

    private func finish(_ request: NamingRequest) {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(name) else { return }
        naming = nil
        Task {
            do {
                let transfer = try await model.sftp(for: tab)
                switch request.kind {
                case .folder(let parent):
                    try await transfer.makeDirectory(RemoteTreeState.child(parent, name))
                    if parent != tree.root { tree.expanded.insert(parent) }
                case .rename(let path):
                    guard let chosen = FileNameCheck.confirm(original: (path as NSString).lastPathComponent, chosen: name) else { return }
                    let destination = RemoteTreeState.child((path as NSString).deletingLastPathComponent, chosen)
                    if try await transfer.entry(at: destination) != nil { throw WorkspaceError.alreadyExists(chosen) }
                    try await transfer.rename(from: path, to: destination)
                }
            } catch { tree.error = message(for: error) }
            await tree.refresh(model: model, tab: tab)
        }
    }

    static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".." && !trimmed.contains("/") && !trimmed.contains("\0")
    }
}

private struct RemoteRow: Identifiable {
    let path: String
    let entry: RemoteEntry
    let depth: Int
    var id: String { path }
}

private struct NamingRequest: Identifiable {
    enum Kind { case folder(in: String), rename(String) }
    let id = UUID()
    let kind: Kind
    var title: String {
        switch kind { case .folder: return T("New remote folder"); case .rename: return T("Rename remote item") }
    }
    var confirm: String {
        switch kind { case .folder: return T("Create"); case .rename: return T("Rename") }
    }
}

/// Lets Finder files be dropped on a folder row, which highlights while they hover.
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    let path: String
    @Binding var target: String?
    let drop: ([URL]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: URL.self) { urls, _ in drop(urls); return true } isTargeted: { hovering in
                if hovering { target = path } else if target == path { target = nil }
            }
        } else { content }
    }
}

/// One line about the transfer in progress, opening the transfer window for the full queue.
struct TransferStatusStrip: View {
    @ObservedObject var queue: TransferQueue
    let openQueue: () -> Void

    var body: some View {
        if let item = queue.items.first(where: { $0.state == .running }) {
            TransferStatusLine(item: item, waiting: queue.items.filter { $0.state == .waiting }.count, openQueue: openQueue)
        }
    }
}

private struct TransferStatusLine: View {
    @ObservedObject var item: TransferItem
    let waiting: Int
    let openQueue: () -> Void

    var body: some View {
        Button(action: openQueue) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if waiting > 0 { Text(String(format: T("+%d waiting"), waiting)).foregroundStyle(.secondary) }
                }.font(.system(size: 11))
                ProgressView(value: item.fraction ?? 0).controlSize(.small)
            }
            .padding(8).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(T("Show transfers"))
    }
}

/// This Mac's files for the sidebar, opened at the home folder like a server opens at its login folder.
@MainActor final class LocalTreeState: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    @Published var children: [String: [LocalItem]] = [:]
    @Published var expanded: Set<String> = []
    @Published var selection: String?
    @Published var error: String?

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path }

    static func child(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    func open(_ path: String) {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = String(format: T("%@ is not a folder."), target); return
        }
        root = target; children = [:]; expanded = []; selection = nil
        load(target)
    }

    func load(_ folder: String) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            children[folder] = urls.compactMap { url -> LocalItem? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                // Apps and other packages open like files; a link to a folder opens like the folder.
                var isFolder = values.isDirectory == true && values.isPackage != true
                if values.isSymbolicLink == true, let target = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                    isFolder = target.isDirectory == true && target.isPackage != true
                }
                return LocalItem(url: url, name: url.lastPathComponent, isDirectory: isFolder,
                                 size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
            }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func toggle(_ folder: String) {
        if expanded.contains(folder) { expanded.remove(folder); return }
        expanded.insert(folder)
        if children[folder] == nil { load(folder) }
    }

    func refresh() {
        for folder in [root] + expanded.sorted() where folder == root || children[folder] != nil { load(folder) }
    }
}

/// The local terminal's view of the sidebar: this Mac's folders, starting at home.
private struct LocalTreePanel: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tree: LocalTreeState
    @ObservedObject var queue: TransferQueue
    @State private var pathDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if tree.root != "/" { TreeParentRow { tree.open((tree.root as NSString).deletingLastPathComponent) } }
                    ForEach(rows(in: tree.root, depth: 0)) { row in rowView(row) }
                    if tree.children[tree.root]?.isEmpty == true {
                        Text(T("This folder is empty")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity)
            TransferStatusStrip(queue: queue) { model.openFileTransfer(for: nil) }
        }
        .onAppear {
            if tree.children[tree.root] == nil { tree.load(tree.root) }
            pathDraft = Self.display(tree.root)
        }
        .onChange(of: tree.root) { _, root in pathDraft = Self.display(root) }
        // Downloads land on this Mac, so a finished transfer can change what these folders hold.
        .onChange(of: queue.revision) { _, _ in tree.refresh() }
    }

    private static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { tree.open((tree.root as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                    .help(T("Parent folder")).disabled(tree.root == "/")
                Button { tree.open(LocalTreeState.home) } label: { Image(systemName: "house") }.help(T("Home folder"))
                TextField(T("Local folder"), text: $pathDraft).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit { tree.open(pathDraft.isEmpty ? LocalTreeState.home : pathDraft) }
                Button { tree.refresh() } label: { Image(systemName: "arrow.clockwise") }.help(T("Refresh"))
            }
            .buttonStyle(.borderless).controlSize(.small)
            if let error = tree.error {
                Label(T(error), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private func rows(in folder: String, depth: Int) -> [LocalRow] {
        (tree.children[folder] ?? []).flatMap { item -> [LocalRow] in
            let row = LocalRow(path: LocalTreeState.child(folder, item.name), item: item, depth: depth)
            guard item.isDirectory, tree.expanded.contains(row.path), depth < 32 else { return [row] }
            return [row] + rows(in: row.path, depth: depth + 1)
        }
    }

    private func rowView(_ row: LocalRow) -> some View {
        HStack(spacing: 4) {
            if row.item.isDirectory {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(tree.expanded.contains(row.path) ? 90 : 0)).frame(width: 12)
            } else { Color.clear.frame(width: 12, height: 1) }
            Image(systemName: row.item.isDirectory ? "folder.fill" : "doc").font(.system(size: 11))
                .foregroundStyle(row.item.isDirectory ? Color.accentColor : .secondary)
            Text(row.item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            // Apps and other packages have no single size to show, as in Finder.
            if !row.item.isDirectory, (try? row.item.url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: row.item.size), countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12 + 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(tree.selection == row.path ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onTapGesture(count: 2) { if !row.item.isDirectory { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) } }
        .simultaneousGesture(TapGesture().onEnded {
            tree.selection = row.path
            if row.item.isDirectory { tree.toggle(row.path) }
        })
        // Dragging a file out hands Finder, other apps, or a terminal pane the file itself.
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: row.path)) ?? NSItemProvider() }
        .contextMenu {
            if row.item.isDirectory { Button(T("Open as top folder")) { tree.open(row.path) } }
            else { Button(T("Open")) { NSWorkspace.shared.open(URL(fileURLWithPath: row.path)) } }
            Button(T("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)]) }
            Button(T("Copy path")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.path, forType: .string)
            }
        }
        .help(row.path)
    }
}

private struct LocalRow: Identifiable {
    let path: String
    let item: LocalItem
    let depth: Int
    var id: String { path }
}

/// The `..` row at the top of a sidebar tree: a click opens the parent folder as the new top.
private struct TreeParentRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 12, height: 1)
            Image(systemName: "arrow.turn.left.up").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("..").font(.system(size: 12))
            Spacer(minLength: 4)
        }
        .padding(.leading, 2).padding(.vertical, 3).padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(hovering ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(T("Parent folder"))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(T("Parent folder"))
    }
}
