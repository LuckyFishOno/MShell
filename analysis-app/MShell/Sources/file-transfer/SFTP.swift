// A minimal SFTP v3 client over a SwiftNIO SSH session child channel. Native (pure-Swift NIO), used in
// place of Citadel's SFTP client so the product does not depend on Citadel. Implements only what the
// file-transfer module needs: realpath, stat, open/read/write/close, opendir/readdir, mkdir, remove,
// rmdir, rename. SFTP protocol per draft-ietf-secsh-filexfer-02 (version 3). Not a port of Xtransport.
import Foundation
import NIOCore
import NIOSSH
import Ssh

enum SFTPPacketType: UInt8 {
    case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6
    case fstat = 8, opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15
    case realpath = 16, stat = 17, rename = 18
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
}

struct SFTPOpenFlags: OptionSet {
    let rawValue: UInt32
    static let read = SFTPOpenFlags(rawValue: 0x1)
    static let write = SFTPOpenFlags(rawValue: 0x2)
    static let append = SFTPOpenFlags(rawValue: 0x4)
    static let create = SFTPOpenFlags(rawValue: 0x8)
    static let truncate = SFTPOpenFlags(rawValue: 0x10)
}

public enum SFTPWireError: Error, Equatable {
    case notReady
    case status(code: UInt32, message: String)
    case protocolError(String)
    case closed
}

/// Parsed reply used internally to resolve a pending request.
enum SFTPReply {
    case status(code: UInt32, message: String)
    case handle(ByteBuffer)
    case data(ByteBuffer)
    case name([SFTPName])
    case attrs(size: UInt64?)
}

public struct SFTPName: Sendable, Equatable {
    public var filename: String
    public var size: UInt64?
    public var permissions: UInt32?
}

// Reassembles length-prefixed SFTP packets from the SSH channel's stdout, resolves pending requests by
// id, and frames outbound packets as SSHChannelData. Lives on the channel's event loop.
final class SFTPHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    let readyPromise: EventLoopPromise<Void>
    private var pending: [UInt32: EventLoopPromise<SFTPReply>] = [:]
    private var inbound = ByteBuffer()
    private var nextId: UInt32 = 0
    private var readySettled = false
    private var readinessTimeout: Scheduled<Void>?
    private var deadlines: [UInt32: Scheduled<Void>] = [:]
    private let timeoutSeconds: Int64
    private static let maxFrameBytes = 1 << 20
    private var context: ChannelHandlerContext?

    init(readyPromise: EventLoopPromise<Void>, timeoutSeconds: Int64 = 30) { self.readyPromise = readyPromise; self.timeoutSeconds = timeoutSeconds }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        readinessTimeout = context.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            self.failAll(SFTPWireError.protocolError("SFTP initialization timed out"))
            context.close(promise: nil)
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) {
        failAll(SFTPWireError.closed); self.context = nil
    }
    private func failAll(_ error: Error) {
        readinessTimeout?.cancel()
        if !readySettled { readySettled = true; readyPromise.fail(error) }
        let promises = pending.values
        pending.removeAll()
        for timer in deadlines.values { timer.cancel() }; deadlines.removeAll()
        for promise in promises { promise.fail(error) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error); context.close(promise: nil)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelFailureEvent {
            failAll(SFTPWireError.protocolError("SFTP subsystem refused")); context.close(promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Request the sftp subsystem, then send our INIT(version 3).
        let subsystem = SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: false)
        context.triggerUserOutboundEvent(subsystem, promise: nil)
        var initBuf = context.channel.allocator.buffer(capacity: 5)
        initBuf.writeInteger(UInt8(SFTPPacketType.initialize.rawValue))
        initBuf.writeInteger(UInt32(3))
        send(packet: initBuf, context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SFTPWireError.closed)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var bytes) = channelData.data, channelData.type == .channel else { return }
        inbound.writeBuffer(&bytes)
        while let length = inbound.getInteger(at: inbound.readerIndex, as: UInt32.self) {
            guard length > 0, length <= Self.maxFrameBytes else {
                failAll(SFTPWireError.protocolError("invalid SFTP frame length")); context.close(promise: nil); return
            }
            guard let frame = takeFrame() else { break }
            handle(frame: frame)
        }
    }

    // Allocates an id, registers a promise, and frames the packet (the caller has written type+body to
    // `body`, excluding the request id — which this inserts right after the type byte).
    func request(type: SFTPPacketType, _ build: (inout ByteBuffer) -> Void) -> EventLoopFuture<SFTPReply> {
        guard let context else { return readyPromise.futureResult.eventLoop.makeFailedFuture(SFTPWireError.notReady) }
        guard pending.count < 128 else { return context.eventLoop.makeFailedFuture(SFTPWireError.protocolError("too many pending requests")) }
        var id = nextId &+ 1
        while id == 0 || pending[id] != nil { id = id &+ 1 }
        nextId = id
        let promise = context.eventLoop.makePromise(of: SFTPReply.self)
        pending[id] = promise
        deadlines[id] = context.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            self.failAll(SFTPWireError.protocolError("SFTP request timed out"))
            context.close(promise: nil)
        }
        var buf = context.channel.allocator.buffer(capacity: 32)
        buf.writeInteger(type.rawValue)
        buf.writeInteger(id)
        build(&buf)
        send(packet: buf, context: context)
        return promise.futureResult
    }

    private func send(packet: ByteBuffer, context: ChannelHandlerContext) {
        var framed = context.channel.allocator.buffer(capacity: packet.readableBytes + 4)
        framed.writeInteger(UInt32(packet.readableBytes))
        framed.writeImmutableBuffer(packet)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(framed))), promise: nil)
    }

    private func takeFrame() -> ByteBuffer? {
        guard let length = inbound.getInteger(at: inbound.readerIndex, as: UInt32.self) else { return nil }
        guard inbound.readableBytes >= 4 + Int(length) else { return nil }
        inbound.moveReaderIndex(forwardBy: 4)
        let frame = inbound.readSlice(length: Int(length))!
        inbound.discardReadBytes()
        return frame
    }

    private func handle(frame: ByteBuffer) {
        var frame = frame
        do {
            guard let raw = frame.readInteger(as: UInt8.self), let type = SFTPPacketType(rawValue: raw) else {
                throw SFTPWireError.protocolError("unknown SFTP packet type")
            }
            if type == .version {
                guard !readySettled, frame.readInteger(as: UInt32.self) == 3 else {
                    throw SFTPWireError.protocolError("unsupported or duplicate SFTP version")
                }
                while frame.readableBytes > 0 { _ = try Self.requiredString(&frame); _ = try Self.requiredString(&frame) }
                readySettled = true; readinessTimeout?.cancel(); readyPromise.succeed(()); return
            }
            guard readySettled, let id = frame.readInteger(as: UInt32.self), let promise = pending.removeValue(forKey: id) else {
                throw SFTPWireError.protocolError("unsolicited SFTP response")
            }
            deadlines.removeValue(forKey: id)?.cancel()
            do {
                let reply: SFTPReply
                switch type {
                case .status:
                    guard let code = frame.readInteger(as: UInt32.self) else { throw SFTPWireError.protocolError("missing status code") }
                    let message = String(buffer: try Self.requiredString(&frame))
                    _ = try Self.requiredString(&frame) // language tag
                    reply = .status(code: code, message: message)
                case .handle: reply = .handle(try Self.requiredString(&frame))
                case .data:
                    let data = try Self.requiredString(&frame)
                    guard data.readableBytes > 0 else { throw SFTPWireError.protocolError("empty read without EOF") }
                    reply = .data(data)
                case .name:
                    guard let count = frame.readInteger(as: UInt32.self), count <= 8192 else { throw SFTPWireError.protocolError("invalid name count") }
                    var names: [SFTPName] = []
                    for _ in 0..<count {
                        let name = String(buffer: try Self.requiredString(&frame))
                        _ = try Self.requiredString(&frame) // longname
                        let attrs = try Self.readAttributes(&frame)
                        names.append(SFTPName(filename: name, size: attrs.size, permissions: attrs.permissions))
                    }
                    reply = .name(names)
                case .attrs: reply = .attrs(size: try Self.readAttributes(&frame).size)
                default: throw SFTPWireError.protocolError("unexpected response type")
                }
                guard frame.readableBytes == 0 else { throw SFTPWireError.protocolError("trailing response bytes") }
                promise.succeed(reply)
            } catch { promise.fail(error); throw error }
        } catch {
            failAll(error); context?.close(promise: nil)
        }
    }

    static func readString(_ buf: inout ByteBuffer) -> ByteBuffer? {
        guard let len = buf.readInteger(as: UInt32.self) else { return nil }
        return buf.readSlice(length: Int(len))
    }
    private static func requiredString(_ buf: inout ByteBuffer) throws -> ByteBuffer {
        guard let value = readString(&buf) else { throw SFTPWireError.protocolError("truncated SFTP string") }
        return value
    }
    static func readAttributes(_ buf: inout ByteBuffer) throws -> (size: UInt64?, permissions: UInt32?) {
        guard let flags = buf.readInteger(as: UInt32.self), flags & ~UInt32(0x8000000f) == 0 else { throw SFTPWireError.protocolError("invalid attribute flags") }
        func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            guard let value = buf.readInteger(as: type) else { throw SFTPWireError.protocolError("truncated attributes") }; return value
        }
        var size: UInt64?, permissions: UInt32?
        if flags & 1 != 0 { size = try integer(UInt64.self) }
        if flags & 2 != 0 { _ = try integer(UInt32.self); _ = try integer(UInt32.self) }
        if flags & 4 != 0 { permissions = try integer(UInt32.self) }
        if flags & 8 != 0 { _ = try integer(UInt32.self); _ = try integer(UInt32.self) }
        if flags & 0x80000000 != 0 {
            let count = try integer(UInt32.self)
            guard count <= 8192 else { throw SFTPWireError.protocolError("too many attribute extensions") }
            for _ in 0..<count { _ = try requiredString(&buf); _ = try requiredString(&buf) }
        }
        return (size, permissions)
    }
}

/// SFTP session over one SSH connection. Request methods hop onto the channel's event loop.
public actor SFTPSession {
    private let channel: Channel
    private let handler: SFTPHandler

    private init(channel: Channel, handler: SFTPHandler) { self.channel = channel; self.handler = handler }

    public static func start(_ ssh: SSHSession, timeoutSeconds: Int64 = 30) async throws -> SFTPSession {
        guard timeoutSeconds > 0, timeoutSeconds <= 3600 else { throw SFTPWireError.protocolError("invalid SFTP timeout") }
        var captured: SFTPHandler?
        let channel = try await ssh.openChildChannel(timeoutSeconds: timeoutSeconds) { child in
            let ready = child.eventLoop.makePromise(of: Void.self)
            let h = SFTPHandler(readyPromise: ready, timeoutSeconds: timeoutSeconds)
            captured = h
            return child.pipeline.addHandler(h)
        }
        guard let handler = captured else { throw SFTPWireError.protocolError("no handler") }
        do { try await handler.readyPromise.futureResult.get() }
        catch { try? await channel.close().get(); throw error }
        return SFTPSession(channel: channel, handler: handler)
    }

    private func send(_ type: SFTPPacketType, _ build: @escaping @Sendable (inout ByteBuffer) -> Void) async throws -> SFTPReply {
        let handler = self.handler
        let future: EventLoopFuture<SFTPReply> = try await channel.eventLoop.submit { handler.request(type: type) { build(&$0) } }.get()
        return try await future.get()
    }

    private static func writeString(_ buf: inout ByteBuffer, _ s: String) {
        buf.writeInteger(UInt32(s.utf8.count)); buf.writeString(s)
    }

    private func expectStatus(_ reply: SFTPReply) throws {
        guard case .status(let code, let msg) = reply else { throw SFTPWireError.protocolError("expected status response") }
        if code != 0 { throw SFTPWireError.status(code: code, message: msg) }
    }

    public func realPath(_ path: String) async throws -> String {
        let reply = try await send(.realpath, { Self.writeString(&$0, path) })
        if case .name(let names) = reply, let first = names.first { return first.filename }
        try expectStatus(reply); throw SFTPWireError.protocolError("expected realpath names")
    }
    public func stat(_ path: String) async throws -> UInt64? {
        let reply = try await send(.stat, { Self.writeString(&$0, path) })
        if case .attrs(let size) = reply { return size }
        try expectStatus(reply); throw SFTPWireError.protocolError("expected stat attributes")
    }
    func open(_ path: String, flags: SFTPOpenFlags) async throws -> ByteBuffer {
        let reply = try await send(.open) { b in Self.writeString(&b, path); b.writeInteger(flags.rawValue); b.writeInteger(UInt32(0)) }
        if case .handle(let h) = reply { return h }
        try expectStatus(reply); throw SFTPWireError.protocolError("open")
    }
    func read(_ handle: ByteBuffer, offset: UInt64, length: UInt32) async throws -> ByteBuffer? {
        let reply = try await send(.read) { b in var h = handle; b.writeInteger(UInt32(h.readableBytes)); b.writeImmutableBuffer(h); b.writeInteger(offset); b.writeInteger(length) }
        switch reply {
        case .data(let d): return d
        case .status(let code, _) where code == 1: return nil // EOF
        case .status(let code, let msg): throw SFTPWireError.status(code: code, message: msg)
        default: throw SFTPWireError.protocolError("read")
        }
    }
    func write(_ handle: ByteBuffer, offset: UInt64, data: ByteBuffer) async throws {
        try expectStatus(try await send(.write) { b in var h = handle; b.writeInteger(UInt32(h.readableBytes)); b.writeImmutableBuffer(h); b.writeInteger(offset); var d = data; b.writeInteger(UInt32(d.readableBytes)); b.writeBuffer(&d) })
    }
    func close(_ handle: ByteBuffer) async throws {
        try expectStatus(try await send(.close) { b in var h = handle; b.writeInteger(UInt32(h.readableBytes)); b.writeImmutableBuffer(h) })
    }
    func openDir(_ path: String) async throws -> ByteBuffer {
        let reply = try await send(.opendir) { Self.writeString(&$0, path) }
        if case .handle(let h) = reply { return h }
        try expectStatus(reply); throw SFTPWireError.protocolError("opendir")
    }
    func readDir(_ handle: ByteBuffer) async throws -> [SFTPName]? {
        let reply = try await send(.readdir) { b in var h = handle; b.writeInteger(UInt32(h.readableBytes)); b.writeImmutableBuffer(h) }
        switch reply {
        case .name(let names):
            guard !names.isEmpty else { throw SFTPWireError.protocolError("empty directory page without EOF") }
            return names
        case .status(let code, _) where code == 1: return nil // EOF
        case .status(let code, let msg): throw SFTPWireError.status(code: code, message: msg)
        default: throw SFTPWireError.protocolError("readdir")
        }
    }
    public func mkdir(_ path: String) async throws {
        try expectStatus(try await send(.mkdir) { b in Self.writeString(&b, path); b.writeInteger(UInt32(0)) })
    }
    public func remove(_ path: String) async throws {
        try expectStatus(try await send(.remove) { Self.writeString(&$0, path) })
    }
    public func rmdir(_ path: String) async throws {
        try expectStatus(try await send(.rmdir) { Self.writeString(&$0, path) })
    }
    public func rename(_ old: String, _ new: String) async throws {
        try expectStatus(try await send(.rename) { b in Self.writeString(&b, old); Self.writeString(&b, new) })
    }
    public func close() async throws { try? await channel.close().get() }
}
