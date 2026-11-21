import Foundation
import NIOCore
import NIOSSH

public final class SSHInteractiveShell: @unchecked Sendable {
    public let output: AsyncThrowingStream<[UInt8], Error>
    private let channel: Channel
    private let exit: ShellExit
    init(channel: Channel, output: AsyncThrowingStream<[UInt8], Error>, exit: ShellExit) { self.channel = channel; self.output = output; self.exit = exit }
    /// Set once the server reports how the shell ended (`exit`, `logout`, a signal). It stays nil when the
    /// channel closed without one, such as a dropped connection.
    public var exitStatus: Int? { exit.status }
    public func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty, bytes.count <= 262144 else { if bytes.isEmpty { return }; throw SSHError.invalidSettings("Terminal input exceeds 256 KiB.") }
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))).get()
    }
    public func resize(rows: Int, columns: Int) async throws {
        guard (1...500).contains(rows), (1...1000).contains(columns) else { throw SSHError.invalidSettings("Invalid terminal dimensions.") }
        try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)).get()
    }
    public func close() async { try? await channel.close().get() }
}

/// Written on the event loop before the output stream finishes, read by the consumer afterwards.
final class ShellExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    var status: Int? { lock.withLock { value } }
    func record(_ status: Int) { lock.withLock { if value == nil { value = status } } }
}

final class InteractiveShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let ready: EventLoopPromise<Void>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    private let rows: Int, columns: Int
    private var stage = 0
    private var finished = false
    let exit = ShellExit()
    init(ready: EventLoopPromise<Void>, continuation: AsyncThrowingStream<[UInt8], Error>.Continuation, rows: Int, columns: Int) {
        self.ready = ready; self.continuation = continuation; self.rows = rows; self.columns = columns
    }
    func channelActive(context: ChannelHandlerContext) {
        stage = 1
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])))
            .whenFailure { error in self.fail(error); context.close(promise: nil) }
        context.fireChannelActive()
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            if stage == 1 {
                stage = 2
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).whenFailure { error in self.fail(error); context.close(promise: nil) }
            } else if stage == 2 { stage = 3; ready.succeed(()) }
        } else if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exit.record(status.exitStatus)
        } else if event is SSHChannelRequestEvent.ExitSignal {
            exit.record(128)
        } else if event is ChannelFailureEvent {
            fail(SSHError.commandFailed(stage == 1 ? "Server rejected PTY request." : "Server rejected shell request.")); context.close(promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data, message.type == .channel || message.type == .stdErr else { return }
        if case .dropped = continuation.yield(Array(bytes.readableBytesView)) {
            fail(SSHError.commandFailed("Terminal consumer could not keep up with remote output.")); context.close(promise: nil)
        }
    }
    func startupTimeout(channel: Channel) {
        guard stage < 3, !finished else { return }
        fail(SSHError.commandFailed("PTY/shell startup timed out.")); channel.close(promise: nil)
    }
    func fail(_ error: Error) {
        guard !finished else { return }; finished = true
        if stage < 3 { ready.fail(error) }; continuation.finish(throwing: error)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            if stage < 3 { fail(SSHError.commandFailed("Shell closed before startup completed.")) }
            else { finished = true; continuation.finish() }
        }
        context.fireChannelInactive()
    }
}

extension SSHSession {
    public func openShell(rows: Int = 24, columns: Int = 80, timeoutSeconds: Int64 = 15) async throws -> SSHInteractiveShell {
        guard (1...500).contains(rows), (1...1000).contains(columns), (1...120).contains(timeoutSeconds) else { throw SSHError.invalidSettings("Invalid terminal dimensions or timeout.") }
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let pair = AsyncThrowingStream<[UInt8], Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let shellHandler = InteractiveShellHandler(ready: ready, continuation: pair.continuation, rows: rows, columns: columns)
        // Consume ready failures even if channel creation is rejected before handler installation.
        ready.futureResult.whenFailure { _ in }
        let child: Channel
        do { child = try await openChildChannel(timeoutSeconds: timeoutSeconds) { $0.pipeline.addHandler(shellHandler) } }
        catch { try? await channel.eventLoop.submit { shellHandler.fail(error) }.get(); throw error }
        let deadline = child.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            shellHandler.startupTimeout(channel: child)
        }
        defer { deadline.cancel() }
        do { try await ready.futureResult.get() }
        catch { try? await child.close().get(); throw error }
        return SSHInteractiveShell(channel: child, output: pair.stream, exit: shellHandler.exit)
    }
}
