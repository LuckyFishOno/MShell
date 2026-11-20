import XCTest
import Foundation
import Ssh
@testable import App

@MainActor final class InteractiveTests: XCTestCase {
    private func wait(_ tab: SessionTab, contains text: String) async throws {
        for _ in 0..<300 {
            if tab.transcript.contains(text) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Terminal output did not contain expected fixture text: \(text)")
    }
    func testPersistentPTYReceivesInputUnicodeInterruptResizeAndSFTPAlongside() async throws {
        try await OpenSSHFixture.withServer(ctrOnly: true, interactive: true) { port, _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("interactive-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = try WorkspaceModel(storage: root), tab = model.tabs[0]
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
            let connect = Task { await model.connect(tab) }
            for _ in 0..<300 { if tab.hostKeyPrompt != nil { model.answerHostKey(tab, approve: true); break }; try await Task.sleep(nanoseconds: 10_000_000) }
            await connect.value; XCTAssertTrue(tab.connected)
            await model.startTerminal(tab); XCTAssertTrue(tab.terminalReady)
            try await wait(tab, contains: "READY>")
            for byte in Array("cd child\rpwd\r".utf8) { model.sendTerminal(tab, bytes: [byte]) }
            try await wait(tab, contains: "/initial/child")
            model.sendTerminal(tab, bytes: Array("echo \u{4f60}\u{597d}\r".utf8)); try await wait(tab, contains: "\u{4f60}\u{597d}")
            model.sendTerminal(tab, bytes: [3]); try await wait(tab, contains: "^C")
            model.resizeTerminal(tab, rows: 35, columns: 100); try await wait(tab, contains: "TERMSIZE 35x100")
            await model.refreshFiles(tab); XCTAssertNil(tab.error); XCTAssertTrue(tab.terminalReady)
            await model.disconnect(tab); XCTAssertFalse(tab.terminalReady); XCTAssertNil(tab.shell); XCTAssertEqual(tab.pendingInputBytes, 0)
        }
    }
    func testRejectedPTYAndStalledPTYReturnFailures() async throws {
        for stalled in [false, true] {
            try await OpenSSHFixture.withServer(rejectPTY: !stalled, stallPTY: stalled) { port, _ in
                let ssh = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "carve"), credential: .password("secret"), connectTimeoutSeconds: 5)
                do { _ = try await ssh.openShell(timeoutSeconds: 1); XCTFail("Expected rejected or timed out PTY") } catch {}
                try await ssh.close()
            }
        }
    }
}
