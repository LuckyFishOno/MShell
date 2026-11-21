import Foundation
import FileTransfer

/// What to do when a file already exists where a transfer would write it.
enum TransferConflictPolicy: Sendable {
    case replace, skip
}

enum TransferDirection: Sendable {
    case upload, download
}

/// One queued upload or download: a file, or a folder copied with everything inside it.
@MainActor final class TransferItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting, running, done, skipped, cancelled
        case failed(String)
        var isFinished: Bool { self != .waiting && self != .running }
    }

    let id = UUID()
    let direction: TransferDirection
    let name: String
    /// Local file path for an upload, remote path for a download.
    let source: String
    /// Folder the item is copied into: remote for an upload, local for a download.
    let destinationFolder: String
    let isFolder: Bool
    let host: String
    let policy: TransferConflictPolicy
    weak var tab: SessionTab?
    @Published var state: State = .waiting
    @Published var bytes: UInt64 = 0
    @Published var total: UInt64?
    @Published var filesDone = 0
    @Published var fileCount = 0

    init(direction: TransferDirection, name: String, source: String, destinationFolder: String, isFolder: Bool,
         tab: SessionTab, policy: TransferConflictPolicy) {
        self.direction = direction; self.name = name; self.source = source; self.destinationFolder = destinationFolder
        self.isFolder = isFolder; self.tab = tab; self.host = tab.host; self.policy = policy
    }

    var fraction: Double? {
        guard let total, total > 0 else { return state == .done ? 1 : nil }
        return min(1, Double(bytes) / Double(total))
    }
}

/// Runs uploads and downloads one after another, for every window and panel that starts them.
///
/// Files are written beside their destination under a temporary name and moved into place only when complete, so
/// a failed or cancelled transfer leaves an existing file as it was.
@MainActor final class TransferQueue: ObservableObject {
    @Published private(set) var items: [TransferItem] = []
    /// Bumped after each item ends, so file lists can refresh the folders it changed.
    @Published private(set) var revision = 0
    private weak var model: WorkspaceModel?
    private var runner: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Error>)?

    init(model: WorkspaceModel? = nil) { self.model = model }
    func attach(_ model: WorkspaceModel) { self.model = model }

    var isActive: Bool { items.contains { !$0.state.isFinished } }

    // MARK: Queueing

    func upload(_ urls: [URL], to remoteFolder: String, via tab: SessionTab, policy: TransferConflictPolicy) {
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            items.append(TransferItem(direction: .upload, name: url.lastPathComponent, source: url.path, destinationFolder: remoteFolder,
                                      isFolder: isFolder, tab: tab, policy: policy))
        }
        start()
    }

    func download(_ entries: [(path: String, isDirectory: Bool)], to localFolder: URL, via tab: SessionTab, policy: TransferConflictPolicy) {
        for entry in entries {
            items.append(TransferItem(direction: .download, name: (entry.path as NSString).lastPathComponent, source: entry.path,
                                      destinationFolder: localFolder.path, isFolder: entry.isDirectory, tab: tab, policy: policy))
        }
        start()
    }

    /// Names among `names` that already exist in the remote folder, so the caller can ask before queueing.
    func remoteConflicts(_ names: [String], in folder: String, via tab: SessionTab) async -> [String] {
        guard let model, let transfer = try? await model.sftp(for: tab),
              let existing = try? await transfer.listDirectory(folder) else { return [] }
        let taken = Set(existing.map(\.name))
        return names.filter { taken.contains($0) }
    }

    nonisolated static func localConflicts(_ names: [String], in folder: URL) -> [String] {
        names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    func cancel(_ item: TransferItem) {
        if current?.id == item.id { current?.task.cancel() }
        else if item.state == .waiting { item.state = .cancelled }
    }

    func cancelAll() {
        for item in items where item.state == .waiting { item.state = .cancelled }
        current?.task.cancel()
    }

    func clearFinished() { items.removeAll { $0.state.isFinished } }

    // MARK: Running

    private func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let item = self.items.first(where: { $0.state == .waiting }) {
                await self.run(item)
            }
            self?.runner = nil
        }
    }

    private func run(_ item: TransferItem) async {
        item.state = .running
        let task = Task { try await self.perform(item) }
        current = (item.id, task)
        do {
            try await task.value
            if item.state == .running { item.state = .done }
        } catch is CancellationError {
            item.state = .cancelled
        } catch {
            item.state = .failed(message(for: error))
        }
        current = nil
        revision += 1
    }

    private func perform(_ item: TransferItem) async throws {
        guard let model, let tab = item.tab else { throw WorkspaceError.disconnected }
        let transfer = try await model.sftp(for: tab)
        switch (item.direction, item.isFolder) {
        case (.upload, false):
            item.fileCount = 1
            item.total = Self.localSize(item.source)
            let skipped = try await uploadFile(URL(fileURLWithPath: item.source), into: item.destinationFolder, transfer, item, base: 0)
            if skipped { item.state = .skipped }
            item.filesDone = 1
        case (.upload, true):
            try await uploadFolder(URL(fileURLWithPath: item.source), into: item.destinationFolder, transfer, item)
        case (.download, false):
            item.fileCount = 1
            item.total = try await transfer.entry(at: item.source)?.size
            let skipped = try await downloadFile(item.source, into: URL(fileURLWithPath: item.destinationFolder), transfer, item, base: 0)
            if skipped { item.state = .skipped }
            item.filesDone = 1
        case (.download, true):
            try await downloadFolder(item.source, into: URL(fileURLWithPath: item.destinationFolder), transfer, item)
        }
    }

    nonisolated private static func localSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    private static func remoteChild(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : (folder as NSString).appendingPathComponent(name)
    }

    /// Uploads one file into `folder`. Returns true when it was skipped because the name was taken.
    private func uploadFile(_ url: URL, into folder: String, _ transfer: SFTPTransfer, _ item: TransferItem, base: UInt64) async throws -> Bool {
        let destination = Self.remoteChild(folder, url.lastPathComponent)
        let existing = try await transfer.entry(at: destination)
        if existing != nil, item.policy == .skip { return true }
        if existing?.isDirectory == true { throw WorkspaceError.invalid("A folder named \(url.lastPathComponent) is already there.") }
        let partial = Self.remoteChild(folder, ".\(url.lastPathComponent).mshell-\(UUID().uuidString.prefix(8)).partial")
        do {
            try await transfer.upload(localURL: url, to: partial) { progress in
                Task { @MainActor in item.bytes = base + progress.bytesTransferred }
            }
            if existing != nil { try await transfer.removeFile(destination) }
            try await transfer.rename(from: partial, to: destination)
        } catch {
            try? await transfer.removeFile(partial)
            throw error
        }
        return false
    }

    private func uploadFolder(_ root: URL, into folder: String, _ transfer: SFTPTransfer, _ item: TransferItem) async throws {
        // Everything is listed first, so the progress bar knows the total before the first byte moves.
        let plan = try await Task.detached { try Self.localPlan(root) }.value
        item.fileCount = plan.files.count
        item.total = plan.files.reduce(0) { $0 + $1.size }
        let top = Self.remoteChild(folder, root.lastPathComponent)
        try await makeRemoteFolder(top, transfer)
        for relative in plan.folders { try await makeRemoteFolder(Self.remoteChild(top, relative), transfer) }
        var sent: UInt64 = 0
        for file in plan.files {
            try Task.checkCancellation()
            let parent = (file.relative as NSString).deletingLastPathComponent
            _ = try await uploadFile(root.appendingPathComponent(file.relative), into: parent.isEmpty ? top : Self.remoteChild(top, parent),
                                     transfer, item, base: sent)
            sent += file.size; item.bytes = sent; item.filesDone += 1
        }
    }

    private func makeRemoteFolder(_ path: String, _ transfer: SFTPTransfer) async throws {
        if let existing = try await transfer.entry(at: path) {
            guard existing.isDirectory else { throw WorkspaceError.invalid("\((path as NSString).lastPathComponent) exists and is not a folder.") }
            return
        }
        try await transfer.makeDirectory(path)
    }

    nonisolated private static func localPlan(_ root: URL) throws -> (folders: [String], files: [(relative: String, size: UInt64)]) {
        var folders: [String] = [], files: [(String, UInt64)] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw TransferError.localFileError("cannot read \(root.path)")
        }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { folders.append(relative) }
            else { files.append((relative, UInt64(values.fileSize ?? 0))) }
        }
        return (folders, files)
    }

    /// Downloads one remote file into `folder`. Returns true when it was skipped because the name was taken.
    private func downloadFile(_ path: String, into folder: URL, _ transfer: SFTPTransfer, _ item: TransferItem, base: UInt64) async throws -> Bool {
        let destination = folder.appendingPathComponent((path as NSString).lastPathComponent)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists, item.policy == .skip { return true }
        if exists, isDirectory.boolValue { throw WorkspaceError.invalid("A folder named \(destination.lastPathComponent) is already there.") }
        let partial = folder.appendingPathComponent(".mshell-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await transfer.download(remotePath: path, to: partial) { progress in
            Task { @MainActor in item.bytes = base + progress.bytesTransferred }
        }
        try Task.checkCancellation()
        if exists { _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial) }
        else { try FileManager.default.moveItem(at: partial, to: destination) }
        return false
    }

    private func downloadFolder(_ path: String, into folder: URL, _ transfer: SFTPTransfer, _ item: TransferItem) async throws {
        var folders: [String] = [], files: [(path: String, size: UInt64)] = [], pending = [path]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            for entry in try await transfer.listDirectory(next) {
                let child = Self.remoteChild(next, entry.name)
                if entry.isDirectory { folders.append(child); pending.append(child) }
                else { files.append((child, entry.size ?? 0)) }
            }
        }
        item.fileCount = files.count
        item.total = files.reduce(0) { $0 + $1.size }
        let parent = (path as NSString).deletingLastPathComponent
        func local(_ remote: String) -> URL {
            let relative = String(remote.dropFirst(parent == "/" ? 1 : parent.count + 1))
            return folder.appendingPathComponent(relative, isDirectory: true)
        }
        for target in [path] + folders {
            try FileManager.default.createDirectory(at: local(target), withIntermediateDirectories: true)
        }
        var received: UInt64 = 0
        for file in files {
            try Task.checkCancellation()
            _ = try await downloadFile(file.path, into: local((file.path as NSString).deletingLastPathComponent), transfer, item, base: received)
            received += file.size; item.bytes = received; item.filesDone += 1
        }
    }
}
