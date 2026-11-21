import XCTest
import Network
@testable import App

@MainActor final class OpenSSHConfigImportTests: XCTestCase {
    private func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-config-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".ssh/conf.d"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testHostsResolveWithFirstValueWinsDefaultsIncludesAndJumpLinks() throws {
        let home = try home()
        let ssh = home.appendingPathComponent(".ssh")
        try Data("id".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        try """
        # Personal hosts
        Include conf.d/*.conf
        Host web db
            HostName %h.example.com
            User deploy
            Port=2201
            IdentityFile ~/.ssh/id_ed25519
        Host bastion
            HostName "bastion.example.com"
            User jump
            IdentityFile id_missing
        Host db
            ProxyJump bastion
            Port 9999
        Host edge
            ProxyJump ops@gate.example.com:2222
            ProxyCommand ssh -W %h:%p other
        Host loop-a
            ProxyJump loop-b
        Host loop-b
            ProxyJump loop-a
        Match host *.internal
            User ignored
        Host *.lan !printer.lan
            User lan
        Host *
            User fallback
            Port 2022
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host included\n  HostName 10.0.0.9\n".write(to: ssh.appendingPathComponent("conf.d/extra.conf"),
                                                        atomically: true, encoding: .utf8)

        let draft = try OpenSSHConfigImport.scan(ssh.appendingPathComponent("config"),
                                                 options: .init(home: home, localUser: "me", agentAvailable: false))
        let byName = Dictionary(uniqueKeysWithValues: draft.entries.map { ($0.name, $0) })
        XCTAssertEqual(draft.entries.map(\.name), ["included", "web", "db", "bastion", "edge", "loop-a", "loop-b",
                                                   "gate.example.com:2222"])

        let included = try XCTUnwrap(byName["included"]?.connection)
        XCTAssertEqual([included.host, included.username], ["10.0.0.9", "fallback"])
        XCTAssertEqual(included.port, 2022)

        let web = try XCTUnwrap(byName["web"]?.connection)
        XCTAssertEqual([web.host, web.username], ["web.example.com", "deploy"])
        XCTAssertEqual(web.port, 2201)
        XCTAssertEqual(web.identityPath, ssh.appendingPathComponent("id_ed25519").standardizedFileURL.path)
        XCTAssertEqual(byName["web"]?.notes, [])

        let db = try XCTUnwrap(byName["db"])
        XCTAssertEqual(db.connection.port, 2201, "the first Port obtained wins")
        XCTAssertEqual(db.jump, ["bastion"])

        let bastion = try XCTUnwrap(byName["bastion"])
        XCTAssertEqual(bastion.connection.host, "bastion.example.com")
        XCTAssertEqual(bastion.connection.identityPath, home.appendingPathComponent("id_missing").path)
        XCTAssertEqual(bastion.notes, ["The identity file was not found."])

        let edge = try XCTUnwrap(byName["edge"])
        XCTAssertEqual(edge.jump, byName["gate.example.com:2222"]?.components)
        XCTAssertTrue(edge.notes.contains("ProxyCommand is not supported. Set a jump host or proxy in MShell."))
        let gate = try XCTUnwrap(byName["gate.example.com:2222"]?.connection)
        XCTAssertEqual([gate.host, gate.username], ["gate.example.com", "ops"])
        XCTAssertEqual(gate.port, 2222)

        XCTAssertTrue(byName["loop-a"]?.notes.contains { $0.contains("loop") } == true)
        XCTAssertTrue(draft.skipped.contains { $0.path == "Match" })
        XCTAssertTrue(draft.skipped.contains { $0.path == "Host *.lan" })
    }

    func testImportedJumpLinksPersistInTheSessionTree() throws {
        let home = try home()
        let config = home.appendingPathComponent(".ssh/config")
        try "Host a\n  HostName a.test\nHost b\n  HostName b.test\n  ProxyJump a\nHost c\n  HostName c.test\n  ProxyJump b\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let draft = try OpenSSHConfigImport.scan(config, options: .init(home: home, localUser: "me", agentAvailable: false))
        let tree = try SessionTreeStore(url: home.appendingPathComponent("sessions.json"))
        let root = try tree.importProfiles(draft, name: "OpenSSH config", parent: nil)
        let nodes = Dictionary(uniqueKeysWithValues: tree.children(of: root).map { ($0.name, $0) })
        XCTAssertEqual(nodes["b"]?.connection?.jumpSessionID, nodes["a"]?.id)
        XCTAssertEqual(nodes["c"]?.connection?.jumpSessionID, nodes["b"]?.id)
        let chain = try XCTUnwrap(tree.jumpChain(for: XCTUnwrap(nodes["c"]?.connection), excluding: nodes["c"]?.id))
        XCTAssertEqual(chain.map(\.host), ["a.test", "b.test"])
    }

    func testCommaSeparatedProxyJumpPreservesOrderAndStandaloneAliases() throws {
        let home = try home()
        let config = home.appendingPathComponent(".ssh/config")
        try """
        Host office
            HostName office.example.com
        Host bridge
            HostName private.example.com
            User default-user
        Host target
            ProxyJump office,ops@bridge:2202,security@final.example.com
        Match host ignored
            Include conf.d/ignored.conf
        """.write(to: config, atomically: true, encoding: .utf8)
        try "Host must-not-import\n".write(to: home.appendingPathComponent(".ssh/conf.d/ignored.conf"),
                                             atomically: true, encoding: .utf8)
        let draft = try OpenSSHConfigImport.scan(config, options: .init(home: home, localUser: "me", agentAvailable: false))
        XCTAssertFalse(draft.entries.contains { $0.name == "must-not-import" })
        let tree = try SessionTreeStore(url: home.appendingPathComponent("sessions.json"))
        let root = try tree.importProfiles(draft, name: "Imported", parent: nil)
        let target = try XCTUnwrap(tree.nodes.first { $0.parent == root && $0.name == "target" })
        let bridge = try XCTUnwrap(tree.nodes.first { $0.parent == root && $0.name == "bridge" })
        let chain = try XCTUnwrap(tree.jumpChain(for: try XCTUnwrap(target.connection), excluding: target.id))
        XCTAssertEqual(chain.map(\.host), ["office.example.com", "private.example.com", "final.example.com"])
        XCTAssertEqual(chain.map(\.username), ["me", "ops", "security"])
        XCTAssertEqual(chain.map(\.port), [22, 2202, 22])
        XCTAssertNil(bridge.connection?.jumpSessionID)
        XCTAssertEqual(bridge.connection?.username, "default-user")
    }

    func testAgentSettingsAndDefaultKeys() throws {
        let home = try home()
        let ssh = home.appendingPathComponent(".ssh")
        try Data("id".utf8).write(to: ssh.appendingPathComponent("id_rsa"))
        try """
        Host plain
        Host pinned
            IdentityFile ~/.ssh/id_rsa
        Host locked
            IdentitiesOnly yes
        Host vault
            IdentityAgent "~/Library/Group Containers/agent.sock"
        Host off
            IdentityAgent none
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let withAgent = try OpenSSHConfigImport.scan(ssh.appendingPathComponent("config"),
                                                     options: .init(home: home, localUser: "me", agentAvailable: true))
        let byName = Dictionary(uniqueKeysWithValues: withAgent.entries.map { ($0.name, $0.connection) })
        XCTAssertEqual(byName["plain"]?.usesAgent, true)
        XCTAssertNil(byName["plain"]?.identityPath)
        XCTAssertNil(byName["pinned"]?.usesAgent)
        XCTAssertEqual(byName["locked"]?.identityPath, ssh.appendingPathComponent("id_rsa").path, "IdentitiesOnly skips the agent")
        XCTAssertEqual(byName["vault"]?.agentSocket, home.path + "/Library/Group Containers/agent.sock")
        XCTAssertNil(byName["off"]?.usesAgent)

        let withoutAgent = try OpenSSHConfigImport.scan(ssh.appendingPathComponent("config"),
                                                        options: .init(home: home, localUser: "me", agentAvailable: false))
        XCTAssertEqual(withoutAgent.entries.first { $0.name == "plain" }?.connection.identityPath,
                       ssh.appendingPathComponent("id_rsa").path, "falls back to a default key file")
    }

    func testNetcatProxyCommandsBecomeProxies() throws {
        XCTAssertEqual(OpenSSHConfigImport.netcatProxy(["nc", "-X", "connect", "-x", "proxy.test:8080", "%h", "%p"]),
                       ProxyConfiguration(kind: .http, host: "proxy.test", port: 8080))
        XCTAssertEqual(OpenSSHConfigImport.netcatProxy(["/usr/bin/nc", "-X", "4", "-x", "10.0.0.1", "%h", "%p"]),
                       ProxyConfiguration(kind: .socks4, host: "10.0.0.1", port: 1080))
        XCTAssertEqual(OpenSSHConfigImport.netcatProxy(["nc", "-x", "127.0.0.1:9050", "%h", "%p"]),
                       ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: 9050))
        XCTAssertNil(OpenSSHConfigImport.netcatProxy(["ssh", "-W", "%h:%p", "bastion"]))
        XCTAssertNil(OpenSSHConfigImport.netcatProxy(["nc", "-X", "connect", "-x", "p:1", "-P", "user", "%h", "%p"]))

        let home = try home()
        let config = home.appendingPathComponent(".ssh/config")
        try "Host corp\n  HostName corp.test\n  ProxyCommand nc -X connect -x proxy.test:8080 %h %p\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let entry = try XCTUnwrap(OpenSSHConfigImport.scan(config, options: .init(home: home, localUser: "me", agentAvailable: false)).entries.first)
        XCTAssertEqual(entry.connection.proxy, ProxyConfiguration(kind: .http, host: "proxy.test", port: 8080))
        XCTAssertEqual(entry.notes, [])
    }

    func testWordsAndPatterns() {
        XCTAssertEqual(OpenSSHConfigImport.words("  HostName = \"my host\" # note")?.0, "hostname")
        XCTAssertEqual(OpenSSHConfigImport.words("  HostName = \"my host\" # note")?.1, ["my host"])
        XCTAssertNil(OpenSSHConfigImport.words("   # only a comment"))
        XCTAssertTrue(OpenSSHConfigImport.matches("db.LAN", patterns: ["*.lan"]))
        XCTAssertFalse(OpenSSHConfigImport.matches("printer.lan", patterns: ["*.lan", "!printer.lan"]))
        XCTAssertEqual(OpenSSHConfigImport.jumpTarget("ssh://u@[::1]:2200")?.host, "::1")
        XCTAssertEqual(OpenSSHConfigImport.jumpTarget("ssh://u@[::1]:2200")?.port, 2200)
        XCTAssertNil(OpenSSHConfigImport.jumpTarget("host:notaport"))
    }
}

@MainActor final class JumpChainTests: XCTestCase {
    func testChainsAreAllowedButLoopsAndOverlongChainsAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jump-chain-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let tree = try SessionTreeStore(url: dir.appendingPathComponent("sessions.json"))
        var previous: UUID?
        var ids: [UUID] = []
        for index in 0...SessionTreeStore.maximumJumpHops {
            let id = try tree.add(name: "hop\(index)", parent: nil,
                                  connection: .init(host: "h\(index).test", username: "u", jumpSessionID: previous))
            ids.append(id); previous = id
        }
        let last = try XCTUnwrap(tree.node(ids.last)?.connection)
        XCTAssertEqual(tree.jumpChain(for: last, excluding: ids.last)?.count, SessionTreeStore.maximumJumpHops)
        XCTAssertThrowsError(try tree.add(name: "too-far", parent: nil,
                                          connection: .init(host: "x.test", username: "u", jumpSessionID: ids.last)))
        XCTAssertFalse(tree.jumpCandidates(excluding: nil).contains { $0.id == ids.last })
        XCTAssertFalse(tree.jumpCandidates(excluding: ids[0]).contains { $0.id == ids[1] }, "would loop back")

        var looped = try XCTUnwrap(tree.node(ids[0])?.connection)
        looped.jumpSessionID = ids[2]
        XCTAssertThrowsError(try tree.updateConnection(ids[0], name: "hop0", connection: looped))
    }
}
