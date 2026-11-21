import Foundation
import NIOCore
import NIOPosix

// A minimal in-process SOCKS5 proxy for tests. One ByteBuffer-typed handler performs the no-auth SOCKS5
// greeting and CONNECT reply, then relays raw bytes to a fixed upstream (the test SSH server). Staying
// ByteBuffer-typed throughout avoids any handler-type-swap race on establishment. Test-only.
enum SOCKSTestProxy {
    // A dedicated single-thread group so the whole proxy (listener, each client, each upstream) lives on
    // one event loop, avoiding cross-event-loop pipeline access. Kept alive for the process.
    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    static func start(upstreamHost: String, upstreamPort: Int) async throws -> (Channel, Int) {
        let group = SOCKSTestProxy.group
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SOL_SOCKET, SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(MiniSOCKS5(upstreamHost: upstreamHost, upstreamPort: upstreamPort))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        guard let port = server.localAddress?.port else { throw TestProxyError.noPort }
        return (server, port)
    }
}

enum TestProxyError: Error { case noPort }

// Forwards every inbound ByteBuffer to a peer channel.
private final class Relay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(NIOAny(unwrapInboundIn(data)), promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil); context.fireChannelInactive() }
}

private final class MiniSOCKS5: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase { case greeting, request, relay }
    private var phase = Phase.greeting
    private var buffer = ByteBuffer()
    private let upstreamHost: String
    private let upstreamPort: Int
    private var upstream: Channel?
    init(upstreamHost: String, upstreamPort: Int) { self.upstreamHost = upstreamHost; self.upstreamPort = upstreamPort }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if phase == .relay {
            if let up = upstream { up.writeAndFlush(NIOAny(unwrapInboundIn(data)), promise: nil) }
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        switch phase {
        case .greeting:
            // [ver, nmethods, methods...]
            guard let ver = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self), let n = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self) else { return }
            guard buffer.readableBytes >= 2 + Int(n) else { return }
            buffer.moveReaderIndex(forwardBy: 2 + Int(n))
            precondition(ver == 5)
            var reply = context.channel.allocator.buffer(capacity: 2); reply.writeBytes([0x05, 0x00])
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            phase = .request
            if buffer.readableBytes > 0 { let rest = buffer; buffer = ByteBuffer(); channelRead(context: context, data: NIOAny(rest)) }
        case .request:
            // [ver, cmd, rsv, atyp, addr, port]; we don't need the target (fixed upstream).
            guard buffer.readableBytes >= 4, let atyp = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self) else { return }
            let addrLen: Int
            switch atyp { case 0x01: addrLen = 4; case 0x04: addrLen = 16
            case 0x03: guard let l = buffer.getInteger(at: buffer.readerIndex + 4, as: UInt8.self) else { return }; addrLen = 1 + Int(l)
            default: context.close(promise: nil); return }
            guard buffer.readableBytes >= 4 + addrLen + 2 else { return }
            buffer.moveReaderIndex(forwardBy: 4 + addrLen + 2)
            dialUpstream(context: context)
        case .relay: break
        }
    }

    private func dialUpstream(context: ChannelHandlerContext) {
        let client = context.channel
        ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.autoRead, value: false)
            .connect(host: upstreamHost, port: upstreamPort)
            .whenComplete { result in
                switch result {
                case .success(let up):
                    self.upstream = up
                    up.pipeline.addHandler(Relay(peer: client)).whenComplete { _ in
                        var reply = client.allocator.buffer(capacity: 10)
                        reply.writeBytes([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // succeeded, 0.0.0.0:0
                        self.phase = .relay
                        context.writeAndFlush(self.wrapOutboundOut(reply)).whenComplete { _ in
                            up.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in up.read() }
                        }
                    }
                case .failure:
                    context.close(promise: nil)
                }
            }
    }

    func channelInactive(context: ChannelHandlerContext) { upstream?.close(promise: nil); context.fireChannelInactive() }
}
