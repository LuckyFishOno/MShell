import XCTest
import AppKit
@testable import App

@MainActor final class SavedSessionTests: XCTestCase {
    private func workspace() throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-session-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try WorkspaceModel(storage: root), root)
    }
    private func saved(_ model: WorkspaceModel, port: Int, username: String = "carve") throws -> SessionTreeNode {
        let id = try model.sessionTree.add(name: "Loopback", parent: nil,
            connection: SavedConnection(host: "127.0.0.1", port: port, username: username))
        return try XCTUnwrap(model.sessionTree.node(id))
    }
    private func approve(_ model: WorkspaceModel, tab: SessionTab) async throws {
        for _ in 0..<300 {
            if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); return }
            if tab.error != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected a loopback host-key prompt")
    }
    func testSavedSessionReusesSuccessfulLoginAndStartsIndependentTerminals() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, root) = try self.workspace(), original = model.tabs[0]
            original.host = "127.0.0.1"; original.port = String(port); original.username = "carve"; original.password = "secret"
            let login = Task { await model.connect(original) }
            try await self.approve(model, tab: original); await login.value
            XCTAssertTrue(original.connected); XCTAssertEqual(original.password, "")
            await model.startTerminal(original)
            let item = try self.saved(model, port: port)
            let first = try XCTUnwrap(model.openSaved(item)), second = try XCTUnwrap(model.openSaved(item))
            await first.savedConnectionTask?.value; await second.savedConnectionTask?.value
            XCTAssertTrue(first.connected); XCTAssertTrue(first.terminalReady); XCTAssertNil(first.error)
            XCTAssertTrue(second.connected); XCTAssertTrue(second.terminalReady); XCTAssertNil(second.error)
            XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.password, ""); XCTAssertNil(first.hostKeyPrompt)
            await model.disconnect(first)
            XCTAssertTrue(original.terminalReady); XCTAssertTrue(second.terminalReady)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("password-vault.json").path))
            XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8).contains("secret"))
            try await model.vault.create(password: "fixture-master", iterations: 100)
            await model.savePassword(original)
            XCTAssertNil(original.error)
            let reloaded = try WorkspaceModel(storage: root)
            try await reloaded.vault.unlock(password: "fixture-master")
            let persisted = try await reloaded.vault.password(id: original.credentialID)
            XCTAssertEqual(persisted, "secret", "Save password must also work after the form password has been cleared")
            await model.closeAll()
        }
    }
    func testReloadedSavedSessionUsesUnlockedEncryptedVaultWithoutPasswordForm() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (initial, root) = try self.workspace(), item = try self.saved(initial, port: port)
            try await initial.vault.create(password: "fixture-master", iterations: 100)
            try await initial.vault.save(id: "carve@[127.0.0.1]:\(port)", password: "secret")
            let model = try WorkspaceModel(storage: root)
            try await model.vault.unlock(password: "fixture-master")
            let tab = try XCTUnwrap(model.openSaved(item))
            try await self.approve(model, tab: tab)
            await tab.savedConnectionTask?.value
            XCTAssertTrue(tab.connected); XCTAssertTrue(tab.terminalReady); XCTAssertNil(tab.error); XCTAssertEqual(tab.password, "")
            await model.closeAll()
        }
    }
    func testSavedSFTPProfileBrowsesWithoutRequestingATerminal() async throws {
        try await OpenSSHFixture.withServer(interactive: true, rejectPTY: true) { port, directory in
            let (model, _) = try self.workspace()
            try Data("fixture".utf8).write(to: directory.appendingPathComponent("remote.txt"))
            try await model.vault.create(password: "fixture-master", iterations: 100)
            try await model.vault.save(id: "carve@[127.0.0.1]:\(port)", password: "secret")
            let id = try model.sessionTree.add(name: "SFTP", parent: nil, connection: SavedConnection(
                host: "127.0.0.1", port: port, username: "carve", opensFiles: true
            ))
            let item = try XCTUnwrap(model.sessionTree.node(id))
            let tab = try XCTUnwrap(model.openSaved(item))
            try await self.approve(model, tab: tab)
            await tab.savedConnectionTask?.value

            XCTAssertTrue(tab.connected)
            XCTAssertTrue(tab.showsFiles)
            XCTAssertTrue(tab.filesLoaded)
            XCTAssertEqual(tab.entries.map(\.name), ["remote.txt"])
            XCTAssertFalse(tab.terminalReady)
            XCTAssertNil(tab.error)
            await model.closeAll()
        }
    }

    func testNewWindowOpensAutomaticallyAndClosingItKeepsWorkspaceTerminalAlive() async throws {
        _ = NSApplication.shared
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, _) = try self.workspace(), local = model.addLocalTab(), item = try self.saved(model, port: port)
            try await model.vault.create(password: "fixture-master", iterations: 100)
            try await model.vault.save(id: "carve@[127.0.0.1]:\(port)", password: "secret")
            let count = model.tabs.count, selected = model.selection
            let tab = try XCTUnwrap(model.openSaved(item, inNewWindow: true))
            let controller = try XCTUnwrap(model.sessionWindows[tab.id])
            XCTAssertTrue(controller.window?.isVisible == true)
            XCTAssertEqual(model.tabs.count, count); XCTAssertEqual(model.selection, selected)
            try await self.approve(model, tab: tab); await tab.savedConnectionTask?.value
            XCTAssertTrue(tab.connected); XCTAssertTrue(tab.terminalReady)
            // Closing the main workspace must not disconnect a separate session window.
            await model.closeWorkspaceTabs()
            XCTAssertTrue(tab.connected); XCTAssertTrue(tab.terminalReady)
            let otherLocal = model.addLocalTab()
            controller.close()
            for _ in 0..<100 { if !tab.connected { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNil(model.sessionWindows[tab.id]); XCTAssertFalse(tab.connected)
            XCTAssertFalse(local.connected); XCTAssertTrue(otherLocal.terminalReady)
            await model.closeAll()
        }
    }
    func testClosingWindowBeforeAutoConnectStartsCancelsPendingLogin() async throws {
        _ = NSApplication.shared
        let (model, _) = try workspace(), item = try saved(model, port: 22)
        let tab = try XCTUnwrap(model.openSaved(item, inNewWindow: true))
        let pending = tab.savedConnectionTask
        model.sessionWindows[tab.id]?.close()
        await pending?.value
        XCTAssertFalse(tab.connected); XCTAssertFalse(tab.busy); XCTAssertNil(tab.hostKeyPrompt)
        XCTAssertTrue(model.sessionWindows.isEmpty)
        await model.closeAll()
    }
    func testLockedVaultDoesNotReusePreviousCredentialsOrConnect() async throws {
        let (model, _) = try workspace(), item = try saved(model, port: 22)
        try await model.vault.create(password: "fixture-master", iterations: 100)
        try await model.vault.save(id: "carve@[127.0.0.1]:22", password: "secret")
        await model.lockVault()
        let tab = try XCTUnwrap(model.openSaved(item))
        await tab.savedConnectionTask?.value
        XCTAssertFalse(tab.connected); XCTAssertFalse(tab.busy); XCTAssertNotNil(tab.error); XCTAssertNil(tab.hostKeyPrompt)
        await model.closeAll()
    }
    func testChangedHostKeyIsStillRejectedDuringAutomaticLogin() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, _) = try self.workspace(), item = try self.saved(model, port: port)
            let endpoint = "[127.0.0.1]:\(port)"
            try model.knownHosts.trust(endpoint: endpoint, key: "ssh-test " + Data("different-public-key".utf8).base64EncodedString())
            try await model.vault.create(password: "fixture-master", iterations: 100)
            try await model.vault.save(id: "carve@\(endpoint)", password: "secret")
            let tab = try XCTUnwrap(model.openSaved(item))
            await tab.savedConnectionTask?.value
            XCTAssertFalse(tab.connected); XCTAssertNotNil(tab.error); XCTAssertNil(tab.hostKeyPrompt)
            XCTAssertTrue(tab.error?.contains("has changed") == true)
            await model.closeAll()
        }
    }
}
