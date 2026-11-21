import XCTest
import NIOSSH
@testable import Ssh

/// Signs in to a loopback OpenSSH server with keys held by a real `ssh-agent`.
final class SSHAgentTests: XCTestCase {
    private var server: LocalSSHD!
    private var agent: Process?
    private var socket = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(LocalSSHD.available && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-agent"),
                          "OpenSSH is not installed")
        server = try LocalSSHD()
        // Unix socket paths are limited to 104 bytes, so keep this one short.
        socket = "/tmp/mshell-agent-\(UUID().uuidString.prefix(8)).sock"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", socket]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        agent = process
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { usleep(50_000) }
    }

    override func tearDown() {
        agent?.terminate(); agent?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: socket)
        server?.stop()
    }

    private func add(_ key: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        task.arguments = ["-q", key.path]
        task.environment = ["SSH_AUTH_SOCK": socket]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
    }

    private func signIn(_ credential: SSHCredential) async throws -> String {
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: credential, connectTimeoutSeconds: 15)
        defer { Task { try? await session.close() } }
        return try await session.runCommand("echo agent-ok").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAgentKeysOfEveryTypeSignIn() async throws {
        let keys: [(String, String, Int?)] = [("ed", "ed25519", nil), ("p256", "ecdsa", 256), ("p384", "ecdsa", 384),
                                              ("p521", "ecdsa", 521), ("rsa", "rsa", 3072)]
        for (name, type, bits) in keys { try add(server.addKey(name, type: type, bits: bits)) }
        let client = SSHAgentClient(socketPath: socket, timeoutSeconds: 10)
        let identities = try client.identities()
        XCTAssertEqual(identities.map(\.comment), keys.map(\.0))
        XCTAssertEqual(identities.map(\.type), ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                                               "ecdsa-sha2-nistp521", "ssh-rsa"])
        for identity in identities {
            let pub = try String(contentsOfFile: server.path(identity.comment + ".pub"), encoding: .utf8)
            XCTAssertTrue(pub.hasPrefix(identity.publicKeyLine + " "), identity.comment)
            let output = try await signIn(.privateKey(client.privateKey(for: identity)))
            XCTAssertEqual(output, "agent-ok", identity.comment)
        }
    }

    func testAgentOffersEachKeyUntilTheServerAcceptsOne() async throws {
        // These two are in the agent but not authorized; only the last key opens the server.
        for name in ["stranger-a", "stranger-b"] {
            let other = try LocalSSHD.temporaryKey(name)
            try add(other)
        }
        try add(server.addKey("trusted", type: "ed25519"))
        let client = SSHAgentClient(socketPath: socket, timeoutSeconds: 10)
        XCTAssertEqual(try client.identities().count, 3)
        let output = try await signIn(.privateKeys(client.privateKeys()))
        XCTAssertEqual(output, "agent-ok")
    }

    func testMissingAgentAndEmptyAgentExplainWhatToDo() throws {
        XCTAssertThrowsError(try SSHAgentClient(socketPath: "/tmp/mshell-no-agent-\(UUID().uuidString.prefix(6))").identities()) {
            XCTAssertEqual($0 as? SSHAgentError, .unavailable)
        }
        XCTAssertEqual(try SSHAgentClient(socketPath: socket).identities(), [])
        XCTAssertNil(SSHAgentClient.environment([:]))
        XCTAssertEqual(SSHAgentClient.environment(["SSH_AUTH_SOCK": socket])?.socketPath, socket)
    }
}

extension LocalSSHD {
    /// A key outside the server's authorized keys, removed with the system temporary folder.
    static func temporaryKey(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-key-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path, "-C", name])
        return URL(fileURLWithPath: path)
    }
}
