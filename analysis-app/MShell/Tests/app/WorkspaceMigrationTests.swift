import XCTest
@testable import App

@MainActor final class WorkspaceMigrationTests: XCTestCase {
    func testPreviewThenImportPersistsNestedCatalogWithoutCredentialsOrUnsupportedRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sessions")
        let devices = source.appendingPathComponent("Factory/Devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        func write(_ name: String, protocolName: String = "SSH", port: String = "22", options: String = "") throws {
            let body = "[SessionInfo]\r\nHost=node.example\r\nUserName=ops\r\nProtocol=\(protocolName)\r\nPort=\(port)\r\nPassword=fixture-secret\r\n\(options)"
            try Data(body.utf8).write(to: devices.appendingPathComponent(name))
        }
        try write("Switch10.xsh", port: "2222", options: "AuthMethod=Public Key\r\n")
        try write("Switch10.xfp", protocolName: "SFTP")
        try write("Old.xsh", protocolName: "TELNET")
        try write("Invalid.xsh", port: "70000")
        try write("Private.xsh", options: "Proxy=Corporate\r\n")
        try FileManager.default.createSymbolicLink(at: devices.appendingPathComponent("Linked.xsh"),
                                                   withDestinationURL: devices.appendingPathComponent("Switch10.xsh"))

        let catalog = root.appendingPathComponent("sessions.json")
        let tree = try SessionTreeStore(url: catalog)
        let existing = try tree.add(name: "Sessions", parent: nil)
        let before = try Data(contentsOf: catalog)
        let preview = try ProfileImport.scan(source)
        XCTAssertEqual(preview.entries.count, 2)
        XCTAssertEqual(preview.skipped.count, 4)
        XCTAssertEqual(preview.entries.first { $0.components.last == "Switch10.xsh" }?.notes.count, 1)
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        XCTAssertThrowsError(try tree.importProfiles(preview, name: "Sessions", parent: nil))
        XCTAssertEqual(try Data(contentsOf: catalog), before)

        let imported = try tree.importProfiles(preview, name: tree.availableImportName(preview.name, parent: nil), parent: nil)
        let reloaded = try SessionTreeStore(url: catalog)
        XCTAssertEqual(reloaded.node(existing)?.name, "Sessions")
        XCTAssertEqual(reloaded.node(imported)?.name, "Sessions (2)")
        XCTAssertTrue(reloaded.children(of: imported).contains { $0.name == "Empty" && $0.isFolder })
        let sessions = reloaded.connections(in: imported)
        XCTAssertEqual(sessions.map(\.name), ["Switch10", "Switch10 (2)"])
        let folder = try XCTUnwrap(reloaded.node(sessions.first?.parent))
        XCTAssertEqual(folder.name, "Devices")
        XCTAssertEqual(reloaded.node(folder.parent)?.name, "Factory")
        XCTAssertEqual(sessions.compactMap { $0.connection?.port }.sorted(), [22, 2222])
        XCTAssertEqual(sessions.first { $0.connection?.port == 22 }?.connection?.opensFiles, true)
        XCTAssertFalse(String(decoding: try Data(contentsOf: catalog), as: UTF8.self).contains("fixture-secret"))

        let session = try XCTUnwrap(sessions.first)
        try reloaded.updateConnection(session.id, name: "Edited", connection: SavedConnection(
            host: "replacement.test", username: "ops", proxyHost: "proxy.test", proxyPort: 1080,
            identityPath: "/tmp/user-chosen-ed25519"
        ))
        let edited = try XCTUnwrap(try SessionTreeStore(url: catalog).node(session.id))
        XCTAssertEqual(edited.name, "Edited")
        XCTAssertEqual(edited.connection?.identityPath, "/tmp/user-chosen-ed25519")
        XCTAssertEqual(edited.parent, session.parent)
    }

    func testQuickConnectTargetsAndMalformedInput() {
        XCTAssertEqual(SavedConnection.quickTarget("ssh ops@node.test:2201"),
                       SavedConnection(host: "node.test", port: 2201, username: "ops"))
        XCTAssertEqual(SavedConnection.quickTarget("ops@[2001:db8::1]"),
                       SavedConnection(host: "2001:db8::1", username: "ops"))
        for invalid in ["ops@", "ops@host:", "a@b@c", "ops@[]", "ops@host:hello", "ops@host:0", "ops@host:65536",
                        "-x@host", "ops@host/dir", "ssh -p 22 ops@host", "ops@[::1]extra"] {
            XCTAssertNil(SavedConnection.quickTarget(invalid), invalid)
        }
    }

    func testBracketedPasteTracksTerminalModeAndCannotCloseItsOwnBracket() {
        let tab = SessionTab()
        tab.screen.feed("\u{1b}[?2004h")
        XCTAssertTrue(tab.screen.bracketedPaste)
        let wrapped = TerminalKeyboard.pasteBytes("first\r\nsecond\u{1b}[201~", bracketed: tab.screen.bracketedPaste)
        XCTAssertEqual(wrapped, Array("\u{1b}[200~first\rsecond[201~\u{1b}[201~".utf8))
        tab.screen.feed("\u{1b}[?2004l")
        XCTAssertFalse(tab.screen.bracketedPaste)
        XCTAssertEqual(TerminalKeyboard.pasteBytes("first\nsecond", bracketed: false), Array("first\rsecond".utf8))
    }
}
