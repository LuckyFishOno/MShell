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
    func testLoggingOutOfTheRemoteShellClosesTheTabButAChannelDropKeepsIt() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, _) = try self.workspace()
            var trusted = false
            @MainActor func open() async throws -> SessionTab {
                let tab = model.addTab()
                tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
                let login = Task { await model.connect(tab) }
                if !trusted { try await self.approve(model, tab: tab); trusted = true }
                await login.value
                await model.startTerminal(tab)
                XCTAssertTrue(tab.terminalReady)
                return tab
            }
            let dropped = try await open()
            model.sendTerminal(dropped, bytes: Array("drop\r".utf8))
            for _ in 0..<300 where dropped.terminalReady { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(dropped.terminalReady)
            XCTAssertTrue(model.tabs.contains { $0.id == dropped.id }, "A shell that ends without an exit status keeps its tab")

            let loggedOut = try await open()
            model.sendTerminal(loggedOut, bytes: Array("exit\r".utf8))
            for _ in 0..<300 where model.tabs.contains(where: { $0.id == loggedOut.id }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(model.tabs.contains { $0.id == loggedOut.id }, "exit closes the tab")
            XCTAssertFalse(loggedOut.connected)
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
            XCTAssertEqual(model.filesRequest?.tab, tab.id, "The layout is asked to show this session's files.")
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
    func testClosingSavedConnectionWindowKeepsItsSuccessfulPasswordForReopening() async throws {
        _ = NSApplication.shared
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, root) = try self.workspace(), item = try self.saved(model, port: port)
            let first = try XCTUnwrap(model.openSaved(item, inNewWindow: true))
            await first.savedConnectionTask?.value
            XCTAssertFalse(first.connected)

            first.password = "secret"
            first.error = nil
            let login = Task { await model.connect(first) }
            try await self.approve(model, tab: first)
            await login.value
            XCTAssertTrue(first.connected)
            let controller = try XCTUnwrap(model.sessionWindows[first.id])
            controller.close()
            for _ in 0..<100 {
                if !first.connected { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(first.connected)

            let failed = model.addTab()
            failed.host = "127.0.0.1"; failed.port = String(port); failed.username = "carve"; failed.password = "wrong"
            await model.connect(failed)
            XCTAssertFalse(failed.connected)

            let reopened = try XCTUnwrap(model.openSaved(item, inNewWindow: true))
            await reopened.savedConnectionTask?.value
            XCTAssertTrue(reopened.connected)
            XCTAssertTrue(reopened.terminalReady)
            XCTAssertEqual(reopened.password, "")
            XCTAssertNil(reopened.hostKeyPrompt)
            XCTAssertNil(reopened.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("password-vault.json").path))
            await model.closeAll()
        }
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
    func testAutomaticLoginWithChangedHostKeyRequiresReviewBeforeRetryingSavedPassword() async throws {
        try await OpenSSHFixture.withServer(interactive: true) { port, _ in
            let (model, root) = try self.workspace(), item = try self.saved(model, port: port)
            let endpoint = "[127.0.0.1]:\(port)"
            let oldKey = "ssh-test " + Data("different-public-key".utf8).base64EncodedString()
            try model.knownHosts.trust(endpoint: endpoint, key: oldKey)
            let generation = await model.vault.sessionGeneration
            await model.vault.rememberForSession(id: "carve@\(endpoint)", password: "secret", generation: generation)
            let tab = try XCTUnwrap(model.openSaved(item))
            await tab.savedConnectionTask?.value
            XCTAssertFalse(tab.connected); XCTAssertNotNil(tab.error); XCTAssertNil(tab.hostKeyPrompt)
            XCTAssertTrue(tab.error?.contains("has changed") == true)

            let change = try XCTUnwrap(tab.hostKeyChange)
            XCTAssertEqual(change.savedFingerprint, try KnownHosts.fingerprint(oldKey))
            XCTAssertEqual(change.receivedFingerprint, try KnownHosts.fingerprint(change.receivedKey))
            XCTAssertNotEqual(change.savedFingerprint, change.receivedFingerprint)
            XCTAssertTrue(try model.knownHosts.isTrusted(endpoint: endpoint, key: oldKey))

            await model.updateHostKeyAndReconnect(tab, change: change)
            XCTAssertTrue(tab.connected); XCTAssertEqual(tab.password, ""); XCTAssertNil(tab.error)
            XCTAssertNil(tab.hostKeyPrompt); XCTAssertNil(tab.hostKeyChange)
            let reloaded = try WorkspaceModel(storage: root)
            XCTAssertTrue(try reloaded.knownHosts.isTrusted(endpoint: endpoint, key: change.receivedKey))
            XCTAssertThrowsError(try reloaded.knownHosts.isTrusted(endpoint: endpoint, key: oldKey))
            await model.closeAll()
        }
    }
}
