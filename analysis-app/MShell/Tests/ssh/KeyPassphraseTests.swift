import XCTest
import Foundation
@testable import Ssh

/// The connection form shows the passphrase field only for keys that have one.
final class KeyPassphraseTests: XCTestCase {
    private func keygen(_ name: String, passphrase: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent(name)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        task.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-f", key.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        return key
    }

    func testOnlyEncryptedKeysNeedAPassphrase() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"))
        XCTAssertFalse(SSHPrivateKeyFile.needsPassphrase(at: try keygen("plain", passphrase: "")))
        XCTAssertTrue(SSHPrivateKeyFile.needsPassphrase(at: try keygen("locked", passphrase: "correct horse")))
    }

    func testTheMShellKeyIsRecognisedWithoutOpeningTheEnclave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-se-\(UUID().uuidString)")
        // Not a real enclave handle: the check must not try to load it.
        try Data((SecureEnclaveSSHIdentity.prefix + "AAAA\n").utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(SSHPrivateKeyFile.needsPassphrase(at: url))
    }
}
