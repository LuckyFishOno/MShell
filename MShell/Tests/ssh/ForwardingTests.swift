import XCTest
import NIOCore
import NIOPosix
@testable import Network
@testable import Ssh

/// Dynamic (SOCKS) and remote forwards through the loopback OpenSSH server.
final class ForwardingTests: XCTestCase {
    private var server: LocalSSHD!
    private var session: SSHSession!

    override func setUp() async throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        server = try LocalSSHD()
        let key = try server.addKey("forward", type: "ed25519")
        session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                               credential: SSHCredential.privateKeyFile(at: key, passphrase: ""), connectTimeoutSeconds: 15)
    }

    override func tearDown() async throws {
        try? await session?.close()
        server?.stop()
    }

    /// A loopback server that echoes each line, so replies only follow what the test sends.
    private func echoServer() async throws -> Channel {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try? await channel.close().get() }
        return channel
    }

    /// Sends a line and returns the echoed line.
    private func roundTrip(_ channel: Channel, _ text: String) async throws -> String {
        let promise = channel.eventLoop.makePromise(of: String.self)
        try await channel.pipeline.addHandler(FirstLine(promise)).get()
        defer { channel.close(promise: nil) }
        try await channel.writeAndFlush(channel.allocator.buffer(string: text + "\n")).get()
        return try await promise.futureResult.get()
    }

    func testDynamicForwardServesSOCKS5AndSOCKS4Clients() async throws {
        let forward = try await session.startDynamicForward(localPort: 0)
        let echo = try await echoServer()
        let echoPort = try XCTUnwrap(echo.localAddress?.port)
        let group = MultiThreadedEventLoopGroup.singleton
        for kind in [ProxyKind.socks5, .socks4] {
            for host in ["127.0.0.1", "localhost"] {
                let channel = try await NetworkConnector.connect(host: host, port: echoPort,
                                                                 proxy: ProxyConfiguration(kind: kind, host: "127.0.0.1", port: forward.port),
                                                                 group: group, connectTimeout: .seconds(10))
                let line = try await roundTrip(channel, "\(kind)-\(host)")
                XCTAssertEqual(line, "\(kind)-\(host)")
            }
        }
        // A whole SSH session can run through its own SOCKS forward.
        let key = try XCTUnwrap(URL(fileURLWithPath: server.path("forward")))
        let nested = try await SSHSession.connect(settings: SSHConnectionSettings(host: "localhost", port: server.port, username: server.user),
                                                  credential: SSHCredential.privateKeyFile(at: key, passphrase: ""),
                                                  proxy: ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: forward.port),
                                                  connectTimeoutSeconds: 15)
        let output = try await nested.runCommand("echo nested")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "nested")
        try await nested.close()
        await forward.close()
        await forward.waitForClose()
    }

    func testDynamicForwardRefusesUnsupportedRequests() async throws {
        let forward = try await session.startDynamicForward(localPort: 0)
        defer { Task { await forward.close() } }
        // SOCKS5 with only username/password offered gets "no acceptable methods".
        let reply = try rawExchange(port: forward.port, send: [5, 1, 2], expect: 2)
        XCTAssertEqual(reply, [5, 0xFF])
        // SOCKS5 BIND is refused with "command not supported".
        let bind = try rawExchange(port: forward.port, send: [5, 1, 0, 5, 2, 0, 1, 127, 0, 0, 1, 0, 22], expect: 12)
        XCTAssertEqual(Array(bind.suffix(10).prefix(2)), [5, 7])
    }

    func testRemoteForwardRelaysServerConnectionsToThisMac() async throws {
        // The "remote" server is this Mac, so the bound port is reachable here too. The destination is the sshd banner.
        let echo = try await echoServer()
        let forward = try await session.startRemoteForward(remotePort: 0, targetHost: "127.0.0.1",
                                                           targetPort: try XCTUnwrap(echo.localAddress?.port))
        XCTAssertGreaterThan(forward.port, 0)
        let group = MultiThreadedEventLoopGroup.singleton
        let channel = try await NetworkConnector.connect(host: "127.0.0.1", port: forward.port, group: group, connectTimeout: .seconds(10))
        let line = try await roundTrip(channel, "reverse")
        XCTAssertEqual(line, "reverse")
        await forward.close()
        await forward.waitForClose()
        var refused = false
        for _ in 0..<40 {
            if !LocalSSHD.canConnect(port: forward.port) { refused = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(refused, "the server stops listening after cancel")
    }

    private func rawExchange(port: Int, send: [UInt8], expect: Int) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        _ = send.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64)
        while received.count < expect {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            received += chunk[..<count]
        }
        return received
    }
}

private final class FirstLine: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<String>
    private var text = ""
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        text += buffer.readString(length: buffer.readableBytes) ?? ""
        if let end = text.firstIndex(of: "\n") { promise.succeed(String(text[..<end])) }
    }
    func channelInactive(context: ChannelHandlerContext) { promise.succeed(text) }
}

private final class Echo: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
}
