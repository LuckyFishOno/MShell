import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A running port forward. Local and dynamic forwards listen on this Mac; remote forwards listen on the server.
public protocol SSHForward: AnyObject, Sendable {
    /// The listening port: on 127.0.0.1 for local and dynamic forwards, on the server for remote ones.
    var port: Int { get }
    func close() async
    func waitForClose() async
}

/// A loopback listener accounted for by a specific SSH transport.
public final class SSHLocalForward: SSHForward {
    public let port: Int
    private let state: LocalForwardState
    private let channel: Channel

    fileprivate init(port: Int, channel: Channel, state: LocalForwardState) {
        self.port = port
        self.channel = channel
        self.state = state
    }

    public func close() async {
        let state = state
        try? await channel.eventLoop.flatSubmit { state.stop() }.get()
    }

    public func waitForClose() async {
        try? await channel.closeFuture.get()
    }
}

extension SSHSession {
    /// Starts a local TCP forward. The destination is opened by the authenticated SSH server.
    public func startLocalForward(localPort: Int, targetHost: String, targetPort: Int) async throws -> SSHLocalForward {
        guard !closed, channel.isActive else { throw SSHError.notConnected }
        guard (0...65535).contains(localPort), validTCPDestination(targetHost, targetPort) else {
            throw SSHError.invalidSettings("Enter a forwarding host and valid TCP ports.")
        }
        return try await startListener(localPort: localPort, state: LocalForwardState(parent: channel, host: targetHost, port: targetPort))
    }

    /// Starts a SOCKS4/4a/5 proxy on 127.0.0.1. Each CONNECT request is opened by the SSH server, as `ssh -D` does.
    public func startDynamicForward(localPort: Int) async throws -> SSHLocalForward {
        guard !closed, channel.isActive else { throw SSHError.notConnected }
        guard (0...65535).contains(localPort) else { throw SSHError.invalidSettings("Enter a valid local port.") }
        return try await startListener(localPort: localPort, state: LocalForwardState(parent: channel, host: nil, port: 0))
    }

    private func startListener(localPort: Int, state: LocalForwardState) async throws -> SSHLocalForward {
        let parent = channel
        let listener = try await ServerBootstrap(group: parent.eventLoop)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { peer in state.accept(peer) }
            .bind(host: "127.0.0.1", port: localPort).get()

        guard let port = listener.localAddress?.port else {
            try? await listener.close().get()
            throw SSHError.connectFailed("The local forwarding port could not be read.")
        }
        try await parent.eventLoop.flatSubmit {
            state.listener = listener
            guard parent.isActive else { return state.stop().flatMapThrowing { throw SSHError.notConnected } }
            state.stopOnTransportClose()
            return parent.eventLoop.makeSucceededFuture(())
        }.get()
        return SSHLocalForward(port: port, channel: listener, state: state)
    }

    func openTCPChannel(host: String, port: Int, timeoutSeconds: Int64,
                        initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        guard !closed, channel.isActive else { throw SSHError.notConnected }
        guard validTCPDestination(host, port) else { throw SSHError.invalidSettings("Invalid SSH destination.") }
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await openDirectTCPIP(on: channel, host: host, port: port, origin: origin,
                                       timeoutSeconds: timeoutSeconds, initializer: initializer).get()
    }
}

func validTCPDestination(_ host: String, _ port: Int) -> Bool {
    !host.isEmpty && host.utf8.count <= 1024 && (1...65535).contains(port) &&
        !host.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
}

/// NIOSSH owns the raw promise. A separate deadline handles slow or nonresponsive peers.
func openDirectTCPIP(on parent: Channel, host: String, port: Int, origin: SocketAddress,
                             timeoutSeconds: Int64 = 15,
                             initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
    let loop = parent.eventLoop
    return loop.flatSubmit {
        guard parent.isActive else { return loop.makeFailedFuture(SSHError.notConnected) }
        return parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
            let raw = loop.makePromise(of: Channel.self)
            let result = loop.makePromise(of: Channel.self)
            let request = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
            var timedOut = false
            let deadline = loop.scheduleTask(in: .seconds(timeoutSeconds)) {
                timedOut = true
                result.fail(SSHError.connectFailed("SSH forwarding request timed out."))
                // There is no channel ID to cancel until the server replies. End the
                // stalled transport so it cannot accumulate indefinitely pending opens.
                parent.close(promise: nil)
            }
            raw.futureResult.whenComplete { response in
                deadline.cancel()
                if timedOut {
                    if case let .success(channel) = response { channel.close(promise: nil) }
                } else {
                    result.completeWith(response)
                }
            }
            ssh.createChannel(raw, channelType: .directTCPIP(request)) { child, _ in initializer(child) }
            return result.futureResult
        }
    }
}

/// Mutable state is confined to the SSH event loop, which also owns the loopback listener and peers.
private final class LocalForwardState: @unchecked Sendable {
    let parent: Channel
    /// The fixed destination, or nil for a dynamic (SOCKS) forward where each client names its own.
    let host: String?
    let port: Int
    var listener: Channel?
    private var peers: [ObjectIdentifier: Channel] = [:]
    private var stopped = false
    private var pending = 0

    init(parent: Channel, host: String?, port: Int) {
        self.parent = parent
        self.host = host
        self.port = port
    }

    func accept(_ local: Channel) -> EventLoopFuture<Void> {
        let loop = parent.eventLoop
        loop.preconditionInEventLoop()
        guard !stopped, peers.count + pending < 64, let origin = local.remoteAddress else {
            return loop.makeFailedFuture(SSHError.notConnected)
        }
        let id = ObjectIdentifier(local)
        peers[id] = local
        local.closeFuture.whenComplete { [weak self] _ in self?.peers.removeValue(forKey: id) }
        guard let host else {
            return local.pipeline.addHandler(SOCKSServerHandshake { [weak self] host, port, reply in
                guard let self, validTCPDestination(host, port) else { return loop.makeFailedFuture(SSHError.notConnected) }
                return self.tunnel(local, id: id, origin: origin, host: host, port: port, reply: reply)
            })
        }
        return tunnel(local, id: id, origin: origin, host: host, port: port, reply: nil)
    }

    /// Opens the SSH channel for one client. For SOCKS, the success reply is written before any server bytes.
    private func tunnel(_ local: Channel, id: ObjectIdentifier, origin: SocketAddress, host: String, port: Int,
                        reply: [UInt8]?) -> EventLoopFuture<Void> {
        let loop = parent.eventLoop
        pending += 1
        let (client, tunnel) = RelaySide.pair()
        let opened = openDirectTCPIP(on: parent, host: host, port: port, origin: origin) { [weak self] remote in
            guard let self, !self.stopped, self.peers[id] != nil else { return loop.makeFailedFuture(SSHError.notConnected) }
            return remote.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                remote.pipeline.addHandlers([SSHByteStream(), tunnel])
            }.flatMap {
                if let reply { local.writeAndFlush(local.allocator.buffer(bytes: reply), promise: nil) }
                return local.pipeline.addHandler(client)
            }
        }
        opened.whenComplete { _ in self.pending -= 1 }
        return opened.flatMapThrowing { remote in
            if self.stopped || self.peers[id] == nil {
                remote.close(promise: nil)
                throw SSHError.notConnected
            }
        }
    }

    func stopOnTransportClose() {
        parent.closeFuture.whenComplete { [weak self] _ in _ = self?.stop() }
    }

    func stop() -> EventLoopFuture<Void> {
        let loop = parent.eventLoop
        loop.preconditionInEventLoop()
        stopped = true
        var channels = Array(peers.values)
        if let listener { channels.append(listener) }
        self.listener = nil
        peers.removeAll()
        return EventLoopFuture.andAllComplete(channels.map { channel in
            channel.close().flatMapError { _ in channel.closeFuture }
        }, on: loop)
    }
}

final class SSHByteStream: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case let .byteBuffer(bytes) = packet.data else {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let packet = SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))
        context.write(wrapOutboundOut(packet), promise: promise)
    }
}

/// Both relay sides run on one event loop. Pause reads when the opposite send buffer fills.
final class RelaySide: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    fileprivate weak var peer: RelaySide?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func pair() -> (RelaySide, RelaySide) {
        let a = RelaySide()
        let b = RelaySide()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { peer?.resumeRead() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.peer = nil
    }

    func read(context: ChannelHandlerContext) {
        if peer?.context?.channel.isWritable == true { context.read() }
        else { pendingRead = true }
    }

    private func resumeRead() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { peer?.resumeRead() }
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer?.context?.flush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            peer?.context?.close(mode: .output, promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
