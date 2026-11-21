import Darwin
import Foundation
import NIOCore
import NIOSOCKS

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTarget(let detail): return "Invalid address: \(detail)"
        case .connectFailed(let detail): return "Connection failed: \(detail)"
        case .proxyFailed(let detail): return detail
        case .unsupportedProxy(let detail): return detail
        }
    }
}

public enum ProxyHandshake {
    /// Handlers to install ahead of the SSH handler on a channel that connects to `proxy`. They hold the SSH
    /// client's first bytes until the proxy has opened the tunnel to `host:port`, then step aside.
    public static func handlers(for proxy: ProxyConfiguration, host: String, port: Int,
                                established: EventLoopPromise<Void>? = nil) -> [ChannelHandler] {
        switch proxy.kind {
        case .none: return []
        case .socks5: return [SOCKSClientHandler(targetAddress: .domain(host, port: port))]
        case .socks4: return [ProxyHandshakeHandler(.socks4, host: host, port: port, established: established)]
        case .http: return [ProxyHandshakeHandler(.http, host: host, port: port, established: established)]
        }
    }

    /// `CONNECT host:port HTTP/1.1`, with an IPv6 literal in brackets.
    static func httpRequest(host: String, port: Int) -> [UInt8] {
        let authority = (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
        return Array("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nUser-Agent: MShell\r\n\r\n".utf8)
    }

    /// SOCKS4 for an IPv4 address; SOCKS4a (the proxy resolves the name) for anything else.
    static func socks4Request(host: String, port: Int) -> [UInt8] {
        var request: [UInt8] = [4, 1, UInt8(port >> 8), UInt8(port & 0xff)]
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 {
            withUnsafeBytes(of: address.s_addr) { request += $0 }
            request.append(0)
        } else {
            request += [0, 0, 0, 1, 0]
            request += Array(host.utf8) + [0]
        }
        return request
    }

    /// The number of bytes the HTTP reply header used, or nil until it is complete.
    static func httpReply(_ bytes: [UInt8]) throws -> Int? {
        let end = Array("\r\n\r\n".utf8)
        guard let range = bytes.firstRange(of: end) else {
            if bytes.count > 16 * 1024 { throw NetworkError.proxyFailed("The HTTP proxy sent an oversized reply.") }
            return nil
        }
        let header = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
        let status = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = status.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else {
            throw NetworkError.proxyFailed("The HTTP proxy sent an unreadable reply.")
        }
        switch code {
        case 200..<300: return range.upperBound
        case 407: throw NetworkError.proxyFailed("The HTTP proxy requires a sign-in, which MShell does not support yet.")
        default: throw NetworkError.proxyFailed("The HTTP proxy refused the connection: \(status)")
        }
    }

    /// The SOCKS4 reply is always eight bytes.
    static func socks4Reply(_ bytes: [UInt8]) throws -> Int? {
        guard bytes.count >= 8 else { return nil }
        guard bytes[0] == 0 else { throw NetworkError.proxyFailed("The SOCKS4 proxy sent an unreadable reply.") }
        switch bytes[1] {
        case 90: return 8
        case 92, 93: throw NetworkError.proxyFailed("The SOCKS4 proxy could not confirm the user (identd).")
        default: throw NetworkError.proxyFailed("The SOCKS4 proxy refused the connection.")
        }
    }
}

/// Speaks a proxy's opening exchange. Outbound bytes from the handlers behind it wait until the tunnel is open.
final class ProxyHandshakeHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum Kind { case http, socks4 }

    private let kind: Kind
    private let request: [UInt8]
    private let established: EventLoopPromise<Void>?
    private var received: [UInt8] = []
    private var pending: [(NIOAny, EventLoopPromise<Void>?)] = []
    private var sent = false
    private var open = false
    private var failed = false

    init(_ kind: Kind, host: String, port: Int, established: EventLoopPromise<Void>?) {
        self.kind = kind
        self.established = established
        request = kind == .http ? ProxyHandshake.httpRequest(host: host, port: port)
            : ProxyHandshake.socks4Request(host: host, port: port)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { sendRequest(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequest(context)
        context.fireChannelActive()
    }

    private func sendRequest(_ context: ChannelHandlerContext) {
        guard !sent else { return }
        sent = true
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: request)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !open else { context.fireChannelRead(data); return }
        guard !failed else { return }
        var buffer = unwrapInboundIn(data)
        received += buffer.readBytes(length: buffer.readableBytes) ?? []
        do {
            let used = try kind == .http ? ProxyHandshake.httpReply(received) : ProxyHandshake.socks4Reply(received)
            guard let used else { return }
            open = true
            established?.succeed(())
            let leftover = Array(received[used...])
            received = []
            for (data, promise) in pending { context.write(data, promise: promise) }
            pending = []
            context.flush()
            if !leftover.isEmpty {
                context.fireChannelRead(wrapInboundOut(context.channel.allocator.buffer(bytes: leftover)))
            }
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        } catch {
            fail(context, error)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if open { context.write(data, promise: promise) } else { pending.append((data, promise)) }
    }

    func flush(context: ChannelHandlerContext) {
        if open { context.flush() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !open { fail(context, NetworkError.proxyFailed("The proxy closed the connection before opening the tunnel.")) }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if !open && !failed { fail(context, NetworkError.proxyFailed("The proxy connection was closed.")) }
    }

    private func fail(_ context: ChannelHandlerContext, _ error: Error) {
        guard !failed else { return }
        failed = true
        established?.fail(error)
        for (_, promise) in pending { promise?.fail(error) }
        pending = []
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
