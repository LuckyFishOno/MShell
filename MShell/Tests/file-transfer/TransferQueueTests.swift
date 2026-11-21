import XCTest
import Foundation
@testable import App
@testable import FileTransfer

/// The transfer queue and file tree against a real `sftp-server`.
@MainActor final class TransferQueueTests: XCTestCase {
    private func connected(_ port: Int) async throws -> (WorkspaceModel, SessionTab, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root.appendingPathComponent("workspace")), tab = model.tabs[0]
        tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
        let connect = Task { await model.connect(tab) }
        for _ in 0..<300 {
            if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await connect.value
        XCTAssertTrue(tab.connected, tab.error ?? "")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        return (model, tab, local)
    }

    private func settle(_ queue: TransferQueue) async throws {
        for _ in 0..<1000 where queue.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(queue.isActive, "The queue finished")
    }

    private func files(under url: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let base = url.standardizedFileURL.path
        for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)! {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { found[String(file.standardizedFileURL.path.dropFirst(base.count + 1))] = try? Data(contentsOf: file) }
        }
        return found
    }

    func testFoldersUploadAndDownloadRecursivelyAndLargeFilesSurviveTheRoundTrip() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            let project = local.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("empty"), withIntermediateDirectories: true)
            // Sizes around the chunk and window edges, plus one large enough to need many pipelined windows.
            let big = Data((0..<1_300_007).map { UInt8(($0 * 31) % 253) })
            try big.write(to: project.appendingPathComponent("src/deep/big.bin"))
            try Data(count: 0).write(to: project.appendingPathComponent("zero.txt"))
            try Data(repeating: 7, count: SFTPTransfer.chunkSize).write(to: project.appendingPathComponent("src/exact.bin"))
            try Data("readme".utf8).write(to: project.appendingPathComponent("README.md"))

            queue.upload([project], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.last?.state, .done)
            XCTAssertEqual(queue.items.last?.fileCount, 4)
            XCTAssertEqual(queue.items.last?.filesDone, 4)
            XCTAssertEqual(self.files(under: remote.appendingPathComponent("project")), self.files(under: project))
            XCTAssertTrue(FileManager.default.fileExists(atPath: remote.appendingPathComponent("project/empty").path), "Empty folders are created")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("project").path)
                .contains { $0.hasSuffix(".partial") }, "No temporary upload names remain")

            let back = local.appendingPathComponent("back")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            queue.download([(remote.appendingPathComponent("project").path, true)], to: back, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.last?.state, .done)
            XCTAssertEqual(self.files(under: back.appendingPathComponent("project")), self.files(under: project))
            XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("project/src/deep/big.bin")), big)
            await model.closeAll()
        }
    }

    func testConflictsAreReportedAndSkipKeepsTheExistingFileWhileReplaceOverwritesIt() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            try Data("server copy".utf8).write(to: remote.appendingPathComponent("notes.txt"))
            let mine = local.appendingPathComponent("notes.txt"), other = local.appendingPathComponent("other.txt")
            try Data("my copy".utf8).write(to: mine); try Data("other".utf8).write(to: other)

            let conflicts = await queue.remoteConflicts(["notes.txt", "other.txt"], in: remote.path, via: tab)
            XCTAssertEqual(conflicts, ["notes.txt"])
            XCTAssertEqual(TransferQueue.localConflicts(["notes.txt", "missing.txt"], in: local), ["notes.txt"])

            queue.upload([mine, other], to: remote.path, via: tab, policy: .skip)
            try await self.settle(queue)
            XCTAssertEqual(queue.items.map(\.state), [.skipped, .done])
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("notes.txt"), encoding: .utf8), "server copy")
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("other.txt"), encoding: .utf8), "other")

            queue.upload([mine], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("notes.txt"), encoding: .utf8), "my copy")

            try Data("local edit".utf8).write(to: mine)
            queue.download([(remote.appendingPathComponent("missing.bin").path, false)], to: local, via: tab, policy: .replace)
            queue.download([(remote.appendingPathComponent("other.txt").path, false)], to: local, via: tab, policy: .skip)
            try await self.settle(queue)
            if case .failed = queue.items[queue.items.count - 2].state {} else { XCTFail("A missing file fails its item only") }
            XCTAssertEqual(queue.items.last?.state, .skipped)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasSuffix(".partial") })

            queue.clearFinished()
            XCTAssertTrue(queue.items.isEmpty)
            await model.closeAll()
        }
    }

    func testWaitingItemsCanBeCancelledAndADisconnectedSessionFailsCleanly() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, local) = try await self.connected(port)
            let queue = model.transfers
            let file = local.appendingPathComponent("a.txt")
            try Data("a".utf8).write(to: file)
            queue.upload([file], to: remote.path, via: tab, policy: .replace)
            queue.upload([file], to: remote.appendingPathComponent("nowhere").path, via: tab, policy: .replace)
            queue.cancel(queue.items[1])
            try await self.settle(queue)
            XCTAssertEqual(queue.items.map(\.state), [.done, .cancelled])

            await model.disconnect(tab)
            queue.upload([file], to: remote.path, via: tab, policy: .replace)
            try await self.settle(queue)
            if case .failed = queue.items.last?.state {} else { XCTFail("A disconnected session fails the item") }
            await model.closeAll()
        }
    }

    func testTheRemoteTreeOpensFoldersLazilyAndDeletesFoldersWithTheirContents() async throws {
        try await OpenSSHFixture.withServer { port, remote in
            let (model, tab, _) = try await self.connected(port)
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("logs/2026"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: remote.appendingPathComponent("logs/2026/app.log"))
            try Data("y".utf8).write(to: remote.appendingPathComponent("top.txt"))
            let tree = tab.remoteTree
            await tree.open(remote.path, model: model, tab: tab)
            let root = try XCTUnwrap(tree.root)
            XCTAssertEqual(tree.children[root]?.map(\.name), ["logs", "top.txt"], "Folders first, then files")
            let logs = RemoteTreeState.child(root, "logs")
            XCTAssertNil(tree.children[logs], "Folders load only when opened")
            await tree.toggle(logs, model: model, tab: tab)
            XCTAssertEqual(tree.children[logs]?.map(\.name), ["2026"])
            await tree.toggle(logs, model: model, tab: tab)
            XCTAssertFalse(tree.expanded.contains(logs))
            XCTAssertEqual(tree.uploadFolder, root, "Nothing selected uploads to the top folder")
            tree.selection = logs
            XCTAssertEqual(tree.uploadFolder, logs, "A selected folder takes the upload")
            tree.selection = RemoteTreeState.child(root, "top.txt")
            XCTAssertEqual(tree.uploadFolder, root, "A selected file uploads beside it")

            try await RemoteDelete.remove(logs, isDirectory: true, with: model.sftp(for: tab))
            await tree.refresh(model: model, tab: tab)
            XCTAssertEqual(tree.children[root]?.map(\.name), ["top.txt"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: remote.appendingPathComponent("logs").path))

            await model.disconnect(tab)
            XCTAssertNil(tree.root, "Disconnecting clears the tree")
            await model.closeAll()
        }
    }

    func testTheLocalTreeStartsAtHomeAndOpensFoldersOnDemand() throws {
        let tree = LocalTreeState()
        XCTAssertEqual(tree.root, LocalTreeState.home, "The local tree opens at the home folder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b-folder/inner"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("h".utf8).write(to: root.appendingPathComponent(".hidden"))
        tree.open(root.path)
        let top = tree.root
        XCTAssertEqual(tree.children[top]?.map(\.name), ["b-folder", "a.txt"], "Folders first, hidden files left out")
        let folder = LocalTreeState.child(top, "b-folder")
        tree.toggle(folder)
        XCTAssertEqual(tree.children[folder]?.map(\.name), ["inner"])
        tree.open(root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(tree.root, top, "A file cannot become the top folder")
        XCTAssertNotNil(tree.error)
    }
}
