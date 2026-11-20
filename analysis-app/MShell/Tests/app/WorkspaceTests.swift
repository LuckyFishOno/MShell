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
    func testWorkspaceLayoutAppliesAfterReopeningAndKeepsTheSavedTheme() throws {
        let storage = try directory()
        let model = try WorkspaceModel(storage: storage)
        let theme = try XCTUnwrap(model.themes.first { $0.id != model.themeID }).id
        try model.selectTheme(theme)
        XCTAssertEqual(model.layout, .native)
        XCTAssertEqual(model.preferredLayout, .native)

        for layout in [WorkspaceLayout.terminal, .transfer, .native] {
            try model.selectLayout(layout)
            XCTAssertEqual(model.preferredLayout, layout)
            XCTAssertEqual(model.layout, .native)
            let reopened = try WorkspaceModel(storage: storage)
            XCTAssertEqual(reopened.layout, layout)
            XCTAssertEqual(reopened.preferredLayout, layout)
            XCTAssertEqual(reopened.themeID, theme)
        }
    }
    func testSplitKeepsIndependentLocalTerminalsAndRestoresSurvivingTab() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let first = model.addLocalTab()
        model.splitWorkspace(.sideBySide)
        let split = try XCTUnwrap(model.split)
        XCTAssertEqual(split.tabIDs.count, 2)
        let second = try XCTUnwrap(model.tabs.first { $0.id == split.tabIDs[1] })
        XCTAssertEqual(split.tabIDs[0], first.id)
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
        XCTAssertNil(model.split, "A new tab shows alone; the split group stays a tab of its own.")
        XCTAssertEqual(model.groups.map(\.tabIDs), [[first.id, second.id]])
        XCTAssertTrue(second.terminalReady)
        model.placeTab(third.id, at: .bottom, of: second.id)
        XCTAssertEqual(model.split?.root, .split(.sideBySide, .tab(first.id), .split(.stacked, .tab(second.id), .tab(third.id))))
        model.closeSplit()
        XCTAssertNil(model.split)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.selected?.id, third.id)
        XCTAssertTrue(first.terminalReady)
        XCTAssertTrue(second.terminalReady)

        model.splitWorkspace(.sideBySide)
        let surviving = try XCTUnwrap(model.split?.tabIDs.first { $0 != third.id })
        await model.closeTab(third)
        XCTAssertNil(model.split)
        XCTAssertEqual(model.selected?.id, surviving)
        XCTAssertTrue(model.selected?.terminalReady == true)
        await model.closeAll()
    }
    func testPaneTreeSplitsReplacesAndCollapsesWithoutAPaneLimit() {
        let ids = (0..<6).map { _ in UUID() }
        var split = WorkspaceSplit(axis: .stacked, first: ids[0], second: ids[1])
        split = split.splitting(ids[0], axis: .sideBySide, adding: ids[2])
        split = split.splitting(ids[1], axis: .sideBySide, adding: ids[3])
        XCTAssertEqual(split.root, .split(.stacked, .split(.sideBySide, .tab(ids[0]), .tab(ids[2])), .split(.sideBySide, .tab(ids[1]), .tab(ids[3]))))
        split = split.splitting(ids[3], axis: .stacked, adding: ids[4]).splitting(ids[4], axis: .sideBySide, adding: ids[5])
        XCTAssertEqual(split.tabIDs, [ids[0], ids[2], ids[1], ids[3], ids[4], ids[5]])
        let removed = try? XCTUnwrap(split.removing(ids[0]))
        XCTAssertEqual(removed?.tabIDs, [ids[2], ids[1], ids[3], ids[4], ids[5]])
        XCTAssertNil(WorkspaceSplit(axis: .stacked, first: ids[0], second: ids[1]).removing(ids[1]))
    }
    func testDropZonesFollowTheNearestEdgeAndTheMiddleReplaces() {
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(PaneDropEdge.at(CGPoint(x: 20, y: 100), in: size), .left)
        XCTAssertEqual(PaneDropEdge.at(CGPoint(x: 390, y: 100), in: size), .right)
        XCTAssertEqual(PaneDropEdge.at(CGPoint(x: 200, y: 10), in: size), .top)
        XCTAssertEqual(PaneDropEdge.at(CGPoint(x: 200, y: 190), in: size), .bottom)
        XCTAssertEqual(PaneDropEdge.at(CGPoint(x: 200, y: 100), in: size), .center)
        XCTAssertEqual(PaneDrag.tabID(from: PaneDrag.prefix + "nope"), nil)
        let id = UUID()
        XCTAssertEqual(PaneDrag.tabID(from: PaneDrag.prefix + id.uuidString), id)
        XCTAssertNil(PaneDrag.tabID(from: id.uuidString))
    }
    func testDraggingTabsOntoPaneEdgesSplitsMovesAndSwaps() throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let a = model.addTab().id, b = model.addTab(select: false).id, c = model.addTab(select: false).id
        model.selectTab(a)

        model.placeTab(b, at: .left, of: a)
        XCTAssertEqual(model.split?.root, .split(.sideBySide, .tab(b), .tab(a)))
        XCTAssertEqual(model.selection, b)

        model.placeTab(c, at: .bottom, of: a)
        XCTAssertEqual(model.split?.root, .split(.sideBySide, .tab(b), .split(.stacked, .tab(a), .tab(c))))

        model.placeTab(b, at: .top, of: c)
        XCTAssertEqual(model.split?.root, .split(.stacked, .tab(a), .split(.stacked, .tab(b), .tab(c))))

        model.placeTab(a, at: .center, of: c)
        XCTAssertEqual(model.split?.tabIDs, [c, b, a])

        model.placeTab(c, at: .right, of: c)
        XCTAssertEqual(model.split?.tabIDs, [c, b, a])

        let d = model.addTab(select: false).id
        model.placeTab(d, at: .center, of: b)
        XCTAssertEqual(model.split?.tabIDs, [c, d, a])
    }
    func testFourPaneWorkspaceMaximizesOnePaneAndClosesBackIntoTheGrid() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let first = model.addLocalTab()
        model.splitWorkspace(.stacked)
        model.splitWorkspace(.sideBySide)
        let below = try XCTUnwrap(model.split?.tabIDs[2])
        model.selectTab(below)
        model.splitWorkspace(.sideBySide)
        let layout = try XCTUnwrap(model.split)
        XCTAssertEqual(layout.tabIDs.count, 4)
        XCTAssertEqual(Set(layout.tabIDs).count, 4)
        XCTAssertEqual(model.tabs.count, 4)
        XCTAssertTrue(model.tabs.allSatisfy(\.terminalReady))

        model.toggleMaximizedPane(below)
        XCTAssertEqual(model.maximizedPane, below)
        XCTAssertEqual(model.selection, below)
        model.toggleMaximizedPane(below)
        XCTAssertNil(model.maximizedPane)
        model.toggleMaximizedPane(below)
        await model.closeTab(try XCTUnwrap(model.tabs.first { $0.id == below }))
        XCTAssertNil(model.maximizedPane)
        XCTAssertEqual(model.split?.tabIDs.count, 3)
        XCTAssertTrue(model.split?.contains(model.selection) == true)
        XCTAssertTrue(model.split?.contains(first.id) == true)
        await model.closeAll()
    }
    func testBroadcastSendsTypedInputToEveryPaneButRepliesStayLocal() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let first = model.addLocalTab()
        let outside = model.addLocalTab(select: false)
        model.selectTab(first.id)
        model.splitWorkspace(.sideBySide)
        let second = try XCTUnwrap(model.tabs.first { $0.id == model.split?.tabIDs[1] })
        XCTAssertEqual(second.id, outside.id)
        let third = model.addLocalTab(select: false)
        model.splitWorkspace(.stacked)
        XCTAssertEqual(model.split?.tabIDs.count, 3)
        let notShown = model.addLocalTab(select: false)

        model.toggleBroadcastInput()
        XCTAssertTrue(model.broadcastInput)
        model.typeTerminal(first, bytes: Array("printf 'BROADCAST_%s\\n' ALL\r".utf8))
        model.sendTerminal(second, bytes: Array("printf 'DIRECT_%s\\n' ONLY\r".utf8))
        for _ in 0..<200 {
            if [first, second, third].allSatisfy({ $0.transcript.contains("BROADCAST_ALL") }), second.transcript.contains("DIRECT_ONLY") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for tab in [first, second, third] { XCTAssertTrue(tab.transcript.contains("BROADCAST_ALL")) }
        XCTAssertFalse(notShown.transcript.contains("BROADCAST_ALL"))
        XCTAssertTrue(second.transcript.contains("DIRECT_ONLY"))
        XCTAssertFalse(first.transcript.contains("DIRECT_ONLY"))

        model.closeSplit()
        XCTAssertFalse(model.broadcastInput)
        model.toggleBroadcastInput()
        XCTAssertFalse(model.broadcastInput)
        await model.closeAll()
    }

    func testSplitGroupsAreSeparateTabsAndPanesDetachBackIntoTabs() throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let a = model.addTab().id, b = model.addTab(select: false).id, c = model.addTab(select: false).id, d = model.addTab(select: false).id
        model.placeTab(b, at: .bottom, of: a)
        model.placeTab(d, at: .right, of: c)
        XCTAssertEqual(model.groups.map(\.tabIDs), [[a, b], [c, d]])
        XCTAssertEqual(model.split?.tabIDs, [c, d])

        model.selectTab(a)
        XCTAssertEqual(model.split?.tabIDs, [a, b], "Selecting a pane shows its own group without changing the other one.")
        XCTAssertEqual(model.group(containing: c)?.tabIDs, [c, d])

        model.placeTab(d, at: .top, of: a)
        XCTAssertEqual(model.groups.map(\.tabIDs), [[d, a, b]], "Moving the last partner out dissolves the old group.")

        model.detachPane(a)
        XCTAssertEqual(model.groups.map(\.tabIDs), [[d, b]])
        XCTAssertEqual(model.selection, a)
        XCTAssertNil(model.split)
        model.detachPane(d)
        XCTAssertTrue(model.groups.isEmpty)
    }
    func testChangingAFileExtensionIsFlagged() {
        XCTAssertNil(FileNameCheck.warning(original: "report.txt", chosen: "notes.txt"))
        XCTAssertNil(FileNameCheck.warning(original: "report.TXT", chosen: "report.txt"))
        XCTAssertNotNil(FileNameCheck.warning(original: "report.txt", chosen: "report.log"))
        XCTAssertNotNil(FileNameCheck.warning(original: ".bashrc", chosen: "bashrc.sh"))
        XCTAssertNotNil(FileNameCheck.warning(original: "archive.tar.gz", chosen: "archive.tar"))
    }
    func testDisconnectClosesTheSessionAndItsPane() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let a = model.addTab(), b = model.addTab(select: false), c = model.addTab(select: false)
        model.selectTab(a.id)
        model.placeTab(b.id, at: .right, of: a.id)
        model.placeTab(c.id, at: .bottom, of: b.id)
        await model.disconnectAndClose(b)
        XCTAssertFalse(model.tabs.contains { $0.id == b.id })
        XCTAssertEqual(model.split?.tabIDs, [a.id, c.id])
        await model.disconnectAndClose(c)
        XCTAssertNil(model.split)
        XCTAssertEqual(model.tabs.map(\.id), [a.id])
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
