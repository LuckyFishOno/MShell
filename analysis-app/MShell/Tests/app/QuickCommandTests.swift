import Foundation
import XCTest
@testable import App

@MainActor final class QuickCommandTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSavedCommandsReloadAndFilterByNameOrText() throws {
        let root = try directory()
        let store = try WorkspaceModel(storage: root).quickCommands
        let command = QuickCommand(name: "  Disk space  ", text: "df -h")
        try store.save(command)
        let edited = QuickCommand(id: command.id, name: "Disk usage", text: "df -H")
        try store.save(edited)

        let reopened = try WorkspaceModel(storage: root).quickCommands
        XCTAssertEqual(reopened.entries, [edited])
        XCTAssertEqual(reopened.matching(" disk "), [edited])
        XCTAssertEqual(reopened.matching("df -h"), [edited])
        XCTAssertTrue(reopened.matching("memory").isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("quick-commands.json").path)
        XCTAssertEqual(permissions[.posixPermissions] as? Int, 0o600)
        try reopened.remove(command.id)
        XCTAssertTrue(try WorkspaceModel(storage: root).quickCommands.entries.isEmpty)
    }

    func testInvalidTextAndCorruptStorageCannotReplaceSavedCommands() throws {
        let root = try directory()
        let file = root.appendingPathComponent("quick-commands.json")
        let store = try WorkspaceModel(storage: root).quickCommands
        let valid = QuickCommand(name: "Date", text: "date")
        try store.save(valid)
        for text in ["", " ", "date\nwhoami", "date\r", "date\u{001b}[201~", "date\u{2028}", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try store.save(QuickCommand(id: valid.id, name: valid.name, text: text)))
        }
        XCTAssertEqual(store.entries, [valid])

        let invalid = Data("broken json".utf8)
        try invalid.write(to: file)
        let reopened = try WorkspaceModel(storage: root).quickCommands
        XCTAssertNotNil(reopened.loadError)
        XCTAssertThrowsError(try reopened.save(valid))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testInsertWaitsForReturnAndRunStaysBoundToTheSelectedTerminal() async throws {
        let model = try WorkspaceModel(storage: directory())
        model.tabs.removeAll()
        let first = model.addLocalTab(), second = model.addLocalTab()
        defer { first.localShell?.close(); second.localShell?.close() }
        model.splitWorkspace(.sideBySide)
        model.selectTab(first.id)

        let insert = QuickCommand(name: "Insert", text: "printf 'QUICK_INSERT_%s\\n' OK")
        XCTAssertNil(model.prepareQuickCommand(insert, for: second))
        let insertion = try XCTUnwrap(model.prepareQuickCommand(insert, for: first))
        XCTAssertTrue(model.sendQuickCommand(insertion, run: false))
        try await wait(for: "QUICK_INSERT_%s", in: first)
        XCTAssertFalse(first.transcript.contains("QUICK_INSERT_OK"))
        model.sendTerminal(first, bytes: [0x0D])
        try await wait(for: "QUICK_INSERT_OK", in: first)

        let command = QuickCommand(name: "Run", text: "printf 'QUICK_RUN_%s\\n' OK")
        let stale = try XCTUnwrap(model.prepareQuickCommand(command, for: first))
        model.selectTab(second.id)
        XCTAssertFalse(model.sendQuickCommand(stale, run: true))
        let current = try XCTUnwrap(model.prepareQuickCommand(command, for: second))
        XCTAssertTrue(model.sendQuickCommand(current, run: true))
        try await wait(for: "QUICK_RUN_OK", in: second)
        XCTAssertFalse(first.transcript.contains("QUICK_RUN_OK"))
        XCTAssertFalse(second.transcript.contains("QUICK_INSERT_OK"))

        await model.disconnect(second)
        model.startLocalTerminal(second)
        XCTAssertTrue(second.terminalReady)
        XCTAssertFalse(model.sendQuickCommand(current, run: true))
        await model.closeAll()
    }

    private func wait(for text: String, in tab: SessionTab) async throws {
        for _ in 0..<150 {
            if tab.transcript.contains(text) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Expected \(text) in terminal output:\n\(tab.transcript)")
    }
}
