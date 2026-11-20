import XCTest
import Foundation
import NIOCore
@testable import App

@MainActor final class AppFlowTests: XCTestCase {
    private func workspace() throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try WorkspaceModel(storage: root), root)
    }
    private func connect(_ model: WorkspaceModel, port: Int, approve: Bool) async throws {
        let tab = model.tabs[0]
        tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
        let task = Task { await model.connect(tab) }
        for _ in 0..<300 {
            if tab.hostKeyPrompt != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard tab.hostKeyPrompt != nil else {
            await model.disconnect(tab); await task.value
            return XCTFail("expected host-key confirmation, error: \(tab.error ?? "none")")
        }
        XCTAssertFalse(tab.connected, "No authenticated session before user approval")
        model.answerHostKey(tab, approve: approve)
        await task.value
    }
    func testWorkspaceTrustAndFileActionsUseRealOpenSSHTransport() async throws {
        try await OpenSSHFixture.withServer { port, remoteRoot in
            let (model, localRoot) = try self.workspace(), tab = model.tabs[0]
            try await self.connect(model, port: port, approve: true)
            XCTAssertTrue(tab.connected); XCTAssertNil(tab.error); XCTAssertEqual(tab.password, "")
            tab.command = "hello workspace"
            await model.execute(tab)
            XCTAssertNil(tab.error); XCTAssertTrue(tab.transcript.contains("HELLO WORKSPACE"))
            tab.command = "stderr"; await model.execute(tab)
            XCTAssertNil(tab.error); XCTAssertTrue(tab.transcript.contains("STDERR OUTPUT"))
            tab.command = "exit-7"; await model.execute(tab)
            XCTAssertTrue(tab.error?.contains("7") == true)
            XCTAssertTrue(tab.error?.contains("EXIT-7") == true, "Failed commands retain bounded server diagnostics")
            XCTAssertFalse(tab.busy); XCTAssertTrue(tab.connected)
            tab.remotePath = remoteRoot.path
            await model.refreshFiles(tab); XCTAssertNil(tab.error)
            let input = localRoot.appendingPathComponent("payload.bin"), output = localRoot.appendingPathComponent("download.bin")
            let payload = Data((0..<100000).map { UInt8($0 % 251) }); try payload.write(to: input)
            await model.upload(tab, local: input)
            await Task.yield()
            XCTAssertNil(tab.error); XCTAssertNil(tab.progress)
            XCTAssertTrue(tab.entries.contains { $0.name == "payload.bin" })
            await model.upload(tab, local: input)
            XCTAssertNotNil(tab.error, "Unconfirmed overwrite is refused")
            try Data("previous local file".utf8).write(to: output)
            await model.download(tab, name: "missing.bin", local: output)
            XCTAssertNotNil(tab.error)
            XCTAssertEqual(try Data(contentsOf: output), Data("previous local file".utf8), "Failed transfers preserve existing local files")
            await model.download(tab, name: "payload.bin", local: output)
            XCTAssertNil(tab.error); XCTAssertEqual(try Data(contentsOf: output), payload)
            await model.rename(tab, from: "payload.bin", to: "renamed.bin")
            XCTAssertNil(tab.error); XCTAssertTrue(tab.entries.contains { $0.name == "renamed.bin" })
            await model.remove(tab, name: "renamed.bin")
            XCTAssertNil(tab.error); XCTAssertFalse(tab.entries.contains { $0.name == "renamed.bin" })
            await model.disconnect(tab); XCTAssertFalse(tab.connected); XCTAssertFalse(tab.busy)
            try await model.vault.create(password: "test-master", iterations: 100)
            tab.password = "secret"; await model.savePassword(tab); tab.password = ""
            let (proxy, proxyPort) = try await SOCKSTestProxy.start(upstreamHost: "127.0.0.1", upstreamPort: port)
            tab.useProxy = true; tab.proxyHost = "127.0.0.1"; tab.proxyPort = String(proxyPort)
            await model.connect(tab)
            XCTAssertTrue(tab.connected, "Pinned host and unlocked vault reconnect through SOCKS5 without a new prompt")
            tab.command = "proxy workspace"; await model.execute(tab)
            XCTAssertNil(tab.error); XCTAssertTrue(tab.transcript.contains("PROXY WORKSPACE"))
            XCTAssertNil(tab.hostKeyPrompt)
            await model.closeAll(); try await proxy.close().get()
        }
    }
    func testRejectingHostKeyNeverAuthenticatesOrPersistsTrust() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let (model, root) = try self.workspace()
            try await self.connect(model, port: port, approve: false)
            XCTAssertFalse(model.tabs[0].connected); XCTAssertNotNil(model.tabs[0].error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("known-hosts.json").path))
        }
    }
    func testDisconnectCancelsOutstandingTrustPrompt() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let (model, _) = try self.workspace(), tab = model.tabs[0]
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
            let task = Task { await model.connect(tab) }
            for _ in 0..<300 { if tab.hostKeyPrompt != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(tab.hostKeyPrompt)
            await model.disconnect(tab); await task.value
            XCTAssertNil(tab.hostKeyPrompt); XCTAssertFalse(tab.connected); XCTAssertEqual(tab.status, "Disconnected")
        }
    }
}
