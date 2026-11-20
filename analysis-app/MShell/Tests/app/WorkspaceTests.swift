import XCTest
import Foundation
import MasterPassword
@testable import App

@MainActor final class WorkspaceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testSplitKeepsIndependentLocalTerminalsAndRestoresSurvivingTab() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let first = model.addLocalTab()
        model.splitWorkspace(.sideBySide)
        let split = try XCTUnwrap(model.split)
        let second = try XCTUnwrap(model.tabs.first { $0.id == split.second })
        XCTAssertEqual(split.first, first.id)
        XCTAssertEqual(model.selected?.id, first.id)

        model.sendTerminal(first, bytes: Array("printf 'SPLIT_%s\\n' one\r".utf8))
        model.selectTab(second.id)
        model.sendTerminal(second, bytes: Array("printf 'SPLIT_%s\\n' two\r".utf8))
        for _ in 0..<100 {
            if first.transcript.contains("SPLIT_one"), second.transcript.contains("SPLIT_two") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(first.transcript.contains("SPLIT_one"))
        XCTAssertFalse(first.transcript.contains("SPLIT_two"))
        XCTAssertTrue(second.transcript.contains("SPLIT_two"))
        XCTAssertFalse(second.transcript.contains("SPLIT_one"))

        let third = model.addLocalTab()
        XCTAssertEqual(model.split?.first, first.id)
        XCTAssertEqual(model.split?.second, third.id)
        XCTAssertTrue(second.terminalReady)
        model.splitWorkspace(.stacked)
        XCTAssertEqual(model.split?.axis, .stacked)
        model.closeSplit()
        XCTAssertNil(model.split)
        XCTAssertEqual(model.selected?.id, third.id)
        XCTAssertTrue(first.terminalReady)
        XCTAssertTrue(second.terminalReady)

        model.splitWorkspace(.sideBySide)
        let surviving = try XCTUnwrap(model.split?.other(than: third.id))
        await model.closeTab(third)
        XCTAssertNil(model.split)
        XCTAssertEqual(model.selected?.id, surviving)
        XCTAssertTrue(model.selected?.terminalReady == true)
        await model.closeAll()
    }

    func testTabsHaveIndependentStateAndClosingLastCreatesBlankTab() async throws {
        let model = try WorkspaceModel(storage: directory())
        let first = model.tabs[0]; first.host = "first.test"; first.password = "not-persisted"
        let second = model.addTab(); second.host = "second.test"
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(first.host, "first.test")
        await model.closeTab(first); XCTAssertEqual(first.password, ""); XCTAssertEqual(model.tabs.count, 1)
        await model.closeTab(second); XCTAssertEqual(model.tabs.count, 1); XCTAssertEqual(model.selected?.host, "127.0.0.1"); XCTAssertEqual(model.selected?.isLocal, true)
        await model.closeAll()
    }
    func testLocalShellPTYInputResizeIsolationAndExit() async throws {
        let model = try WorkspaceModel(storage: directory())
        let first = model.addLocalTab(), second = model.addLocalTab()
        defer { first.localShell?.close(); second.localShell?.close() }
        XCTAssertTrue(first.terminalReady); XCTAssertEqual(first.host, "127.0.0.1")
        model.resizeTerminal(first, rows: 31, columns: 91)
        model.sendTerminal(first, bytes: Array("printf '\\nLOCAL_PTY_%s\\n' OK; stty size\r".utf8))
        for _ in 0..<100 {
            if first.transcript.contains("LOCAL_PTY_OK"), first.transcript.contains("31 91") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(first.transcript.contains("LOCAL_PTY_OK"), first.transcript)
        XCTAssertTrue(first.transcript.contains("31 91"), first.transcript)
        XCTAssertFalse(second.transcript.contains("LOCAL_PTY_OK"))
        model.sendTerminal(first, bytes: Array("exit\r".utf8))
        for _ in 0..<100 {
            if !first.terminalReady { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(first.terminalReady)
        XCTAssertTrue(second.terminalReady)
        await model.closeAll()
    }
    func testInvalidSettingsDoNotStartConnection() async throws {
        let model = try WorkspaceModel(storage: directory()); let tab = model.tabs[0]
        tab.host = "localhost"; tab.username = "user"; tab.port = "70000"
        await model.connect(tab)
        XCTAssertNotNil(tab.error); XCTAssertFalse(tab.busy); XCTAssertFalse(tab.connected)
    }
    func testHostTrustPersistsAndChangedKeysAreRejected() throws {
        let path = try directory().appendingPathComponent("known-hosts.json")
        let key = "ssh-test " + Data("first-public-key".utf8).base64EncodedString()
        let changed = "ssh-test " + Data("changed-public-key".utf8).base64EncodedString()
        let hosts = try KnownHosts(url: path)
        XCTAssertFalse(try hosts.isTrusted(endpoint: "[server]:22", key: key))
        try hosts.trust(endpoint: "[server]:22", key: key)
        let reloaded = try KnownHosts(url: path)
        XCTAssertTrue(try reloaded.isTrusted(endpoint: "[server]:22", key: key))
        XCTAssertThrowsError(try reloaded.isTrusted(endpoint: "[server]:22", key: changed))
        XCTAssertThrowsError(try reloaded.trust(endpoint: "[server]:22", key: changed))
        XCTAssertTrue(try KnownHosts(url: path).isTrusted(endpoint: "[server]:22", key: key))
    }
    func testVaultPasswordIsEncryptedAndRequiresUnlockAfterReopening() async throws {
        let path = try directory().appendingPathComponent("vault.json")
        let vault = try CredentialVault(url: path)
        try await vault.create(password: "master-secret", iterations: 100)
        try await vault.save(id: "account", password: "connection-secret")
        XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("connection-secret"))
        let reopened = try CredentialVault(url: path)
        do { _ = try await reopened.password(id: "account"); XCTFail("expected locked") } catch {}
        do { try await reopened.unlock(password: "incorrect"); XCTFail("expected wrong password") } catch {}
        try await reopened.unlock(password: "master-secret")
        let secret = try await reopened.password(id: "account"); XCTAssertEqual(secret, "connection-secret")
        await reopened.lock()
        do { _ = try await reopened.password(id: "account"); XCTFail("expected locked") } catch {}
    }
    func testSuccessfulCredentialCacheIsMemoryOnlyAndLockInvalidatesPendingWrites() async throws {
        let path = try directory().appendingPathComponent("vault.json"), vault = try CredentialVault(url: path)
        let generation = await vault.sessionGeneration
        await vault.rememberForSession(id: "alice@[server]:22", password: "ephemeral-secret", generation: generation)
        let secret = try await vault.password(id: "alice@[server]:22")
        XCTAssertEqual(secret, "ephemeral-secret")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        do { _ = try await vault.password(id: "bob@[server]:22"); XCTFail("Separate accounts must not share credentials") } catch {}
        await vault.lock()
        await vault.rememberForSession(id: "alice@[server]:22", password: "late-secret", generation: generation)
        do { _ = try await vault.password(id: "alice@[server]:22"); XCTFail("Lock must clear credentials and reject stale writes") } catch {}
    }
    func testImportProfileDoesNotConnectOrImportStoredPassword() throws {
        let root = try directory(), file = root.appendingPathComponent("session.xsh")
        try Data("[SessionInfo]\r\nHost=server.test\r\nUserName=alice\r\nProtocol=SSH\r\nPassword=not-a-native-vault-secret\r\n".utf8).write(to: file)
        let model = try WorkspaceModel(storage: root)
        try model.importProfile(file)
        XCTAssertEqual(model.selected?.host, "server.test"); XCTAssertEqual(model.selected?.username, "alice")
        XCTAssertEqual(model.selected?.password, ""); XCTAssertEqual(model.selected?.connected, false)
    }
    func testCorruptVaultIterationMetadataIsRejectedBeforeUnlocking() throws {
        let root = try directory(), file = root.appendingPathComponent("password-vault.json")
        let vault = try MasterVault.create(password: "master-secret", iterations: 100)
        var data = try JSONSerialization.jsonObject(with: vault.serialized()) as! [String: Any]
        data["iterations"] = 0
        try JSONSerialization.data(withJSONObject: data).write(to: file)
        XCTAssertThrowsError(try WorkspaceModel(storage: root))
    }

    func testRemoteFileNamesCannotEscapeSelectedDirectory() throws {
        let model = try WorkspaceModel(storage: directory()), tab = model.tabs[0]; tab.remotePath = "/tmp"
        for name in ["../file", "..", ".", "a/b", "a\0b", ""] { XCTAssertThrowsError(try model.remoteFile(name, in: tab)) }
        XCTAssertEqual(try model.remoteFile("file.txt", in: tab), "/tmp/file.txt")
    }
}
