import XCTest
import NIOCore
@preconcurrency import NIOSSH
@testable import App

@MainActor final class IdentityWorkspaceTests: XCTestCase {
    func testEncryptedIdentitySavedThenUnlocksSSHAndBrowsesSFTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = root.appendingPathComponent("id_ed25519")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generator.arguments = ["-q", "-t", "ed25519", "-N", "fixture-passphrase", "-f", identity.path]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: String(contentsOf: identity.appendingPathExtension("pub"), encoding: .utf8))
        try await OpenSSHFixture.withServer(interactive: true, auth: FixtureKeyAuth(key: publicKey)) { @MainActor port, directory in
            let model = try WorkspaceModel(storage: root)
            let id = try model.sessionTree.add(name: "Key host", parent: nil, connection: SavedConnection(
                host: "127.0.0.1", port: port, username: "carve", identityPath: identity.path
            ))
            let item = try XCTUnwrap(try SessionTreeStore(url: root.appendingPathComponent("sessions.json")).node(id))
            let tab = try XCTUnwrap(model.openSaved(item))
            await tab.savedConnectionTask?.value
            XCTAssertEqual(tab.error, "Enter the private key passphrase.")
            tab.keyPassphrase = "wrong"
            await model.connect(tab)
            XCTAssertFalse(tab.connected)
            XCTAssertNil(tab.hostKeyPrompt)
            XCTAssertEqual(tab.keyPassphrase, "")

            tab.keyPassphrase = "fixture-passphrase"
            let connect = Task { await model.connect(tab) }
            for _ in 0..<500 {
                if tab.hostKeyPrompt != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let prompt = tab.hostKeyPrompt
            if prompt == nil {
                let message = tab.error
                await model.disconnect(tab)
                await connect.value
                XCTFail(message ?? "Expected a loopback host-key prompt")
                return
            }
            model.answerHostKey(tab, approve: true)
            await connect.value
            XCTAssertTrue(tab.connected, tab.error ?? "")
            XCTAssertEqual(tab.keyPassphrase, "")

            await model.startTerminal(tab)
            XCTAssertTrue(tab.terminalReady, tab.error ?? "")
            let nested = directory.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data("fixture".utf8).write(to: nested.appendingPathComponent("file.txt"))
            await model.refreshFiles(tab, navigateTo: "nested")
            XCTAssertEqual(URL(fileURLWithPath: tab.remotePath).resolvingSymlinksInPath().path, nested.resolvingSymlinksInPath().path)
            XCTAssertEqual(tab.entries.map(\.name), ["file.txt"])
            XCTAssertTrue(tab.filesLoaded)
            await model.refreshFiles(tab, navigateTo: nested.appendingPathComponent("missing").path)
            XCTAssertNotNil(tab.error)
            XCTAssertEqual(URL(fileURLWithPath: tab.remotePath).resolvingSymlinksInPath().path, nested.resolvingSymlinksInPath().path)
            XCTAssertEqual(tab.entries.map(\.name), ["file.txt"])
            XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8).contains("fixture-passphrase"))
            await model.closeAll()
        }
    }
}

private struct FixtureKeyAuth: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let presented) = request.request,
           request.username == "carve", presented.publicKey == key {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}
