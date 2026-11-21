import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Remote forwarding (ssh -R)

/// A port the SSH server listens on. Each connection to it is relayed to a destination reached from this Mac.
public final class SSHRemoteForward: SSHForward {
    /// The port the server bound. When 0 was requested, this is the port the server chose.
    public let port: Int
    public let bindHost: String
    private let state: RemoteForwardState

    fileprivate init(port: Int, bindHost: String, state: RemoteForwardState) {
        self.port = port
        self.bindHost = bindHost
        self.state = state
    }

    public func close() async {
        let state = state
        try? await state.parent.eventLoop.flatSubmit { state.stop(cancel: true) }.get()
    }

    public func waitForClose() async {
        try? await state.closed.futureResult.get()
    }
}

extension SSHSession {
    /// Asks the server to listen on `bindHost:remotePort` and relays each connection to `targetHost:targetPort`,
    /// which MShell connects to from this Mac. `bindHost` follows OpenSSH: "localhost" keeps the port on the server's
    /// loopback, and other addresses need `GatewayPorts` on the server.
    public func startRemoteForward(bindHost: String = "localhost", remotePort: Int,
                                   targetHost: String, targetPort: Int) async throws -> SSHRemoteForward {
        guard !closed, channel.isActive else { throw SSHError.notConnected }
        guard (0...65535).contains(remotePort), !bindHost.isEmpty, bindHost.utf8.count <= 255,
              validTCPDestination(targetHost, targetPort) else {
            throw SSHError.invalidSettings("Enter a forwarding host and valid TCP ports.")
        }
        let parent = channel
        let router = inbound
        return try await parent.eventLoop.flatSubmit {
            parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let state = RemoteForwardState(parent: parent, router: router, bindHost: bindHost, host: targetHost, port: targetPort)
                return state.start(using: ssh, requestedPort: remotePort).map { port in
                    SSHRemoteForward(port: port, bindHost: bindHost, state: state)
                }
            }
        }.get()
    }
}

/// Channels the server opens toward the client. Confined to the session's event loop.
final class InboundChannelRouter: @unchecked Sendable {
    var remoteForwards: [Int: RemoteForwardState] = [:]

    var initializer: ((Channel, SSHChannelType) -> EventLoopFuture<Void>)? {
        { [weak self] child, type in
            guard case .forwardedTCPIP(let info) = type, let state = self?.remoteForwards[info.listeningPort] else {
                return child.eventLoop.makeFailedFuture(SSHError.connectFailed("The server opened an unexpected channel."))
            }
            return state.accept(child)
        }
    }
}

final class RemoteForwardState: @unchecked Sendable {
    let parent: Channel
    weak var router: InboundChannelRouter?
    let bindHost: String
    let host: String
    let port: Int
    var boundPort = 0
    let closed: EventLoopPromise<Void>
    private var peers: [ObjectIdentifier: Channel] = [:]
    private var stopped = false
    private var startExpired = false

    init(parent: Channel, router: InboundChannelRouter, bindHost: String, host: String, port: Int) {
        self.parent = parent
        self.router = router
        self.bindHost = bindHost
        self.host = host
        self.port = port
        closed = parent.eventLoop.makePromise()
    }

    func start(using ssh: NIOSSHHandler, requestedPort: Int) -> EventLoopFuture<Int> {
        let loop = parent.eventLoop
        let response = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        let started = loop.makePromise(of: Int.self)
        let deadline = loop.scheduleTask(in: .seconds(15)) {
            self.startExpired = true
            self.closed.succeed(())
            started.fail(SSHError.connectFailed("The server did not answer the forwarding request in time."))
        }
        response.futureResult.whenComplete { result in
            deadline.cancel()
            guard case .success(let reply) = result else {
                self.closed.succeed(())
                started.fail(SSHError.connectFailed("The server refused to listen. The port may be in use, or the server may not allow remote forwarding."))
                return
            }
            let port = reply?.boundPort ?? requestedPort
            guard (1...65535).contains(port) else {
                self.closed.succeed(())
                started.fail(SSHError.connectFailed("The server did not report the port it chose."))
                return
            }
            if self.startExpired {
                // A late success still opened a server listener. Cancel it.
                ssh.sendTCPForwardingRequest(.cancel(host: self.bindHost, port: port), promise: nil)
                return
            }
            self.boundPort = port
            self.router?.remoteForwards[port] = self
            self.parent.closeFuture.whenComplete { _ in _ = self.stop(cancel: false) }
            started.succeed(port)
        }
        ssh.sendTCPForwardingRequest(.listen(host: bindHost, port: requestedPort), promise: response)
        return started.futureResult
    }

    /// Connects to the destination, then joins it to the server's channel. Reads wait until both sides exist.
    func accept(_ child: Channel) -> EventLoopFuture<Void> {
        let loop = parent.eventLoop
        guard !stopped, peers.count < 64 else { return loop.makeFailedFuture(SSHError.notConnected) }
        let (client, tunnel) = RelaySide.pair()
        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            ClientBootstrap(group: child.eventLoop)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { $0.pipeline.addHandler(client) }
                .connect(host: self.host, port: self.port)
        }.flatMap { local in
            guard !self.stopped else {
                local.close(promise: nil)
                return loop.makeFailedFuture(SSHError.notConnected)
            }
            let id = ObjectIdentifier(local)
            self.peers[id] = local
            local.closeFuture.whenComplete { _ in self.peers.removeValue(forKey: id) }
            child.closeFuture.whenComplete { _ in local.close(promise: nil) }
            return child.pipeline.addHandlers([SSHByteStream(), tunnel])
        }
    }

    func stop(cancel: Bool) -> EventLoopFuture<Void> {
        let loop = parent.eventLoop
        guard !stopped else { return closed.futureResult }
        stopped = true
        if router?.remoteForwards[boundPort] === self { router?.remoteForwards[boundPort] = nil }
        let channels = Array(peers.values)
        peers.removeAll()
        var work = channels.map { channel in channel.close().flatMapError { _ in channel.closeFuture } }
        if cancel, parent.isActive {
            let cancelled = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
            let deadline = loop.scheduleTask(in: .seconds(3)) { cancelled.succeed(nil) }
            cancelled.futureResult.whenComplete { _ in deadline.cancel() }
            parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                guard case .success(let ssh) = result else { cancelled.succeed(nil); return }
                ssh.sendTCPForwardingRequest(.cancel(host: self.bindHost, port: self.boundPort), promise: cancelled)
            }
            work.append(cancelled.futureResult.map { _ in }.recover { _ in })
        }
        let done = EventLoopFuture.andAllComplete(work, on: loop)
        done.whenComplete { _ in self.closed.succeed(()) }
        return done
    }
}

// MARK: - SOCKS server (ssh -D)

/// Reads one SOCKS4, SOCKS4a, or SOCKS5 CONNECT request from a local client, then asks `open` to reach it.
/// `open` writes `reply` before joining the tunnel; this handler then removes itself and passes on any early bytes.
final class SOCKSServerHandshake: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let open: (String, Int, [UInt8]) -> EventLoopFuture<Void>
    private var buffer: [UInt8] = []
    private enum Stage { case greeting, request, connecting, done }
    private var stage = Stage.greeting
    private var version: UInt8 = 0

    init(open: @escaping (String, Int, [UInt8]) -> EventLoopFuture<Void>) { self.open = open }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stage != .done else { context.fireChannelRead(data); return }
        var bytes = unwrapInboundIn(data)
        buffer += bytes.readBytes(length: bytes.readableBytes) ?? []
        guard buffer.count <= 2048 else { context.close(promise: nil); return }
        if stage != .connecting { process(context) }
    }

    private func process(_ context: ChannelHandlerContext) {
        if stage == .greeting {
            guard let first = buffer.first else { return }
            version = first
            switch first {
            case 4:
                stage = .request
            case 5:
                guard buffer.count >= 2, buffer.count >= 2 + Int(buffer[1]) else { return }
                let methods = buffer[2..<(2 + Int(buffer[1]))]
                buffer.removeFirst(2 + Int(buffer[1]))
                guard methods.contains(0) else {
                    context.writeAndFlush(outbound([5, 0xFF]), promise: nil)
                    context.close(promise: nil)
                    return
                }
                context.writeAndFlush(outbound([5, 0]), promise: nil)
                stage = .request
            default:
                context.close(promise: nil)
                return
            }
        }
        guard stage == .request else { return }
        if version == 5 { requestV5(context) } else { requestV4(context) }
    }

    private func requestV5(_ context: ChannelHandlerContext) {
        guard buffer.count >= 5 else { return }
        let length: Int
        switch buffer[3] {
        case 1: length = 4
        case 3: length = 1 + Int(buffer[4])
        case 4: length = 16
        default: reject(context, [5, 8, 0, 1, 0, 0, 0, 0, 0, 0]); return
        }
        guard buffer.count >= 4 + length + 2 else { return }
        let address = Array(buffer[4..<(4 + length)])
        let port = Int(buffer[4 + length]) << 8 | Int(buffer[5 + length])
        let command = buffer[1]
        let kind = buffer[3]
        buffer.removeFirst(4 + length + 2)
        guard command == 1 else { reject(context, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0]); return }
        let host: String
        switch kind {
        case 1: host = address.map(String.init).joined(separator: ".")
        case 3: host = String(decoding: address.dropFirst(), as: UTF8.self)
        default: host = Self.ipv6(address)
        }
        connect(context, host: host, port: port, success: [5, 0, 0, 1, 0, 0, 0, 0, 0, 0], failure: [5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
    }

    private func requestV4(_ context: ChannelHandlerContext) {
        guard buffer.count >= 9, let userEnd = buffer[8...].firstIndex(of: 0) else { return }
        var end = userEnd + 1
        var host = buffer[4...7].map(String.init).joined(separator: ".")
        if buffer[4...6] == [0, 0, 0] && buffer[7] != 0 {
            guard let nameEnd = buffer[end...].firstIndex(of: 0) else { return }
            host = String(decoding: buffer[end..<nameEnd], as: UTF8.self)
            end = nameEnd + 1
        }
        let command = buffer[1]
        let port = Int(buffer[2]) << 8 | Int(buffer[3])
        buffer.removeFirst(end)
        guard command == 1 else { reject(context, [0, 91, 0, 0, 0, 0, 0, 0]); return }
        connect(context, host: host, port: port, success: [0, 90, 0, 0, 0, 0, 0, 0], failure: [0, 91, 0, 0, 0, 0, 0, 0])
    }

    private func connect(_ context: ChannelHandlerContext, host: String, port: Int, success: [UInt8], failure: [UInt8]) {
        stage = .connecting
        open(host, port, success).whenComplete { result in
            switch result {
            case .success:
                self.stage = .done
                if !self.buffer.isEmpty {
                    context.fireChannelRead(self.wrapInboundOut(context.channel.allocator.buffer(bytes: self.buffer)))
                    context.fireChannelReadComplete()
                    self.buffer = []
                }
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            case .failure:
                self.reject(context, failure)
            }
        }
    }

    private func reject(_ context: ChannelHandlerContext, _ reply: [UInt8]) {
        context.writeAndFlush(outbound(reply)).whenComplete { _ in context.close(promise: nil) }
    }

    private func outbound(_ bytes: [UInt8]) -> NIOAny {
        NIOAny(ByteBuffer(bytes: bytes))
    }

    private static func ipv6(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
        return String(cString: text)
    }
}
