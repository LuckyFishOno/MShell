import XCTest
import NIOSSH
@testable import Ssh

/// Optional checks against real servers, skipped unless configured.
///
///     MSHELL_REMOTE_HOSTS="user@host[:port],user@host2"   # the second host is also reached through the first
///     MSHELL_REMOTE_KEYS=/path/to/folder                  # private keys whose public halves those accounts accept
///     MSHELL_REMOTE_LOGIN_ONLY="host3"                  # optional comma-separated hosts with restricted shells
///
/// The key folder must contain a known_hosts file with a pinned key for each test host.
final class RemoteHostTests: XCTestCase {
    private struct Target { let user: String; let host: String; let port: Int }

    private var targets: [Target] = []
    private var keys: [URL] = []
    private var hostKeys: [String: [NIOSSHPublicKey]] = [:]
    private var loginOnly: Set<String> = []

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let hosts = environment["MSHELL_REMOTE_HOSTS"], let folder = environment["MSHELL_REMOTE_KEYS"] else {
            throw XCTSkip("Set MSHELL_REMOTE_HOSTS and MSHELL_REMOTE_KEYS to run remote checks.")
        }
        targets = try hosts.split(separator: ",").map { item in
            let parts = item.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { throw SSHError.invalidSettings("Expected user@host in MSHELL_REMOTE_HOSTS.") }
            let address = parts[1].split(separator: ":")
            let host = try XCTUnwrap(address.first)
            let port = address.count > 1 ? try XCTUnwrap(Int(address[1])) : 22
            return Target(user: String(parts[0]), host: String(host), port: port)
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        keys = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.isEmpty && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "known_hosts" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(targets.isEmpty || keys.isEmpty, "No remote targets or keys.")
        loginOnly = Set((environment["MSHELL_REMOTE_LOGIN_ONLY"] ?? "").split(separator: ",").map(String.init))
        let knownHosts = try String(contentsOf: directory.appendingPathComponent("known_hosts"), encoding: .utf8)
        for line in knownHosts.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, !fields[0].hasPrefix("#") else { continue }
            let key = try NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])")
            for host in fields[0].split(separator: ",") { hostKeys[String(host), default: []].append(key) }
        }
    }

    private func check(_ session: SSHSession, _ target: Target, _ word: String, _ label: String) async throws {
        guard !loginOnly.contains(target.host) else { return }
        let output = try await session.runCommand("echo \(word)", includeStandardError: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, word, label)
    }

    private func trust(_ target: Target) throws -> HostKeyPolicy {
        let endpoint = target.port == 22 ? target.host : "[\(target.host)]:\(target.port)"
        return .trusted(try XCTUnwrap(hostKeys[endpoint], "Missing host key for \(endpoint) in known_hosts."))
    }

    private func settings(_ target: Target) -> SSHConnectionSettings {
        SSHConnectionSettings(host: target.host, port: target.port, username: target.user)
    }

    func testEveryKeyFileSignsInToEveryHost() async throws {
        for target in targets {
            for key in keys {
                let file = try SSHPrivateKeyFile.load(at: key, passphrase: "")
                let session = try await SSHSession.connect(settings: settings(target), credential: .privateKey(file.key),
                                                           hostKey: trust(target), connectTimeoutSeconds: 15)
                try await check(session, target, "mshell-\(file.kind.rawValue.replacingOccurrences(of: " ", with: "-"))",
                                "\(target.host) \(key.lastPathComponent)")
                try await session.close()
            }
        }
    }

    func testAgentKeysSignInToEveryHost() async throws {
        let socket = "/tmp/mshell-ragent-\(UUID().uuidString.prefix(8)).sock"
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run()
        // ssh-agent removes its own socket when it exits.
        defer { agent.terminate(); agent.waitUntilExit() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { usleep(50_000) }
        let client = SSHAgentClient(socketPath: socket, timeoutSeconds: 10)
        for target in targets {
            for key in keys {
                let add = Process()
                add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
                add.arguments = ["-D", "-q"]
                add.environment = ["SSH_AUTH_SOCK": socket]
                add.standardOutput = FileHandle.nullDevice; add.standardError = FileHandle.nullDevice
                try add.run(); add.waitUntilExit()
                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
                load.arguments = ["-q", key.path]
                load.environment = ["SSH_AUTH_SOCK": socket]
                load.standardOutput = FileHandle.nullDevice; load.standardError = FileHandle.nullDevice
                try load.run(); load.waitUntilExit()
                let identity = try XCTUnwrap(client.identities().first)
                let session = try await SSHSession.connect(settings: settings(target),
                                                           credential: .privateKey(client.privateKey(for: identity)),
                                                           hostKey: trust(target), connectTimeoutSeconds: 15)
                try await check(session, target, "agent-\(identity.type)", "\(target.host) \(key.lastPathComponent)")
                try await session.close()
            }
        }
    }

    func testSecondHostThroughTheFirstAsAJumpHost() async throws {
        try XCTSkipIf(targets.count < 2, "Needs two hosts.")
        let file = try SSHPrivateKeyFile.load(at: keys[0], passphrase: "")
        let jump = try await SSHSession.connect(settings: settings(targets[0]), credential: .privateKey(file.key),
                                                hostKey: trust(targets[0]), connectTimeoutSeconds: 15)
        let target = try await SSHSession.connect(settings: settings(targets[1]), credential: .privateKey(file.key),
                                                  via: jump, hostKey: trust(targets[1]), connectTimeoutSeconds: 15)
        let output = try await target.runCommand("hostname")
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try await target.close()
    }
}
