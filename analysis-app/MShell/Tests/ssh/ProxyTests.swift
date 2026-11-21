import XCTest
@testable import Network
@testable import Ssh

/// Signs in to the loopback OpenSSH server through HTTP CONNECT and SOCKS4/4a proxies.
final class ProxyTests: XCTestCase {
    private var server: LocalSSHD!
    private var key: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        server = try LocalSSHD()
        key = try server.addKey("proxy", type: "ed25519")
    }
    override func tearDown() { server?.stop() }

    private func signIn(host: String, through proxy: ProxyConfiguration) async throws -> String {
        let credential = try SSHCredential.privateKeyFile(at: key, passphrase: "")
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: host, port: server.port, username: server.user),
                                                   credential: credential, proxy: proxy, connectTimeoutSeconds: 15)
        defer { Task { try? await session.close() } }
        return try await session.runCommand("echo via-proxy").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testHTTPConnectProxy() async throws {
        let proxy = try TinyProxy(.http)
        defer { proxy.stop() }
        let output = try await signIn(host: "127.0.0.1", through: ProxyConfiguration(kind: .http, host: "127.0.0.1", port: proxy.port))
        XCTAssertEqual(output, "via-proxy")
        XCTAssertEqual(proxy.seen, ["CONNECT 127.0.0.1:\(server.port) HTTP/1.1"])
    }

    func testSOCKS4AndSOCKS4aProxies() async throws {
        let proxy = try TinyProxy(.socks4)
        defer { proxy.stop() }
        let configuration = ProxyConfiguration(kind: .socks4, host: "127.0.0.1", port: proxy.port)
        let byAddress = try await signIn(host: "127.0.0.1", through: configuration)
        let byName = try await signIn(host: "localhost", through: configuration)
        XCTAssertEqual([byAddress, byName], ["via-proxy", "via-proxy"])
        XCTAssertEqual(proxy.seen, ["SOCKS4 127.0.0.1:\(server.port)", "SOCKS4 4a:localhost:\(server.port)"])
    }

    func testProxyRefusalIsExplained() async throws {
        let proxy = try TinyProxy(.httpNeedsSignIn)
        defer { proxy.stop() }
        do {
            _ = try await signIn(host: "127.0.0.1", through: ProxyConfiguration(kind: .http, host: "127.0.0.1", port: proxy.port))
            XCTFail("expected the proxy to refuse")
        } catch SSHError.connectFailed(let detail) {
            XCTAssertEqual(detail, "The HTTP proxy requires a sign-in, which MShell does not support yet.")
        }
    }

    func testRequestAndReplyFormats() throws {
        XCTAssertEqual(String(decoding: ProxyHandshake.httpRequest(host: "::1", port: 22), as: UTF8.self),
                       "CONNECT [::1]:22 HTTP/1.1\r\nHost: [::1]:22\r\nUser-Agent: MShell\r\n\r\n")
        XCTAssertEqual(ProxyHandshake.socks4Request(host: "10.1.2.3", port: 2222), [4, 1, 8, 174, 10, 1, 2, 3, 0])
        XCTAssertEqual(ProxyHandshake.socks4Request(host: "db", port: 22), [4, 1, 0, 22, 0, 0, 0, 1, 0, 100, 98, 0])
        XCTAssertNil(try ProxyHandshake.httpReply(Array("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertEqual(try ProxyHandshake.httpReply(Array("HTTP/1.0 200 OK\r\n\r\nSSH-2.0".utf8)), 19)
        XCTAssertThrowsError(try ProxyHandshake.httpReply(Array("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)))
        XCTAssertNil(try ProxyHandshake.socks4Reply([0, 90, 0]))
        XCTAssertThrowsError(try ProxyHandshake.socks4Reply([0, 91, 0, 0, 0, 0, 0, 0]))
    }
}
