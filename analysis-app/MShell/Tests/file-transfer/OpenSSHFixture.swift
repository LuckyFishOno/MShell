import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel
@testable import Ssh

// Test-only SSH server backed by the system OpenSSH SFTP executable. This exercises a separate,
// standard SFTP v3 implementation instead of Citadel's non-v3 rename packet parser.
private enum FixtureError: Error { case unsupportedChannel }
enum OpenSSHFixture {
    struct Route: Sendable {
        let host: String
        let port: Int
    }

    static func withServer(rejectSessions: Bool = false, ctrOnly: Bool = false, interactive: Bool = false, rejectPTY: Bool = false, stallPTY: Bool = false, auth: NIOSSHServerUserAuthenticationDelegate = PasswordAuth(), route: Route? = nil, onTransport: (@Sendable (Channel) -> Void)? = nil, _ body: (Int, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = MultiThreadedEventLoopGroup.singleton
        var config = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(p521Key: .init())], userAuthDelegate: auth)
        if ctrOnly { config.transportProtectionSchemes = [AES128CTR.self] }
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                onTransport?(channel)
                return channel.pipeline.addHandlers([
                    NIOSSHHandler(role: .server(config), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                        if case .directTCPIP(let target) = type,
                           let route, target.targetHost == route.host, target.targetPort == route.port {
                            return connectFixtureRoute(child, port: route.port)
                        }
                        guard type == .session, !rejectSessions else { return child.eventLoop.makeFailedFuture(FixtureError.unsupportedChannel) }
                        return child.pipeline.addHandler(OpenSSHSubsystem(directory: directory, interactive: interactive, rejectPTY: rejectPTY, stallPTY: stallPTY))
                    }),
                    FixtureCloseOnError()
                ])
            }.bind(host: "127.0.0.1", port: 0).get()
        do {
            try await body(server.localAddress!.port!, directory)
            try await server.close().get()
        } catch { try? await server.close().get(); throw error }
    }

    // Only the explicitly configured test destination can be opened, always on loopback.
    private static func connectFixtureRoute(_ child: Channel, port: Int) -> EventLoopFuture<Void> {
        let (ssh, tcp) = RelaySide.pair()
        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            child.pipeline.addHandlers([SSHByteStream(), ssh])
        }.flatMap {
            ClientBootstrap(group: child.eventLoop)
                .connectTimeout(.seconds(3))
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { $0.pipeline.addHandler(tcp) }
                .connect(host: "127.0.0.1", port: port)
                .map { _ in () }
        }
    }

}

private final class FixtureCloseOnError: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class OpenSSHSubsystem: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let directory: URL
    private var process: Process?
    private let input = Pipe()
    private let output = Pipe()
    private let interactive: Bool, rejectPTY: Bool, stallPTY: Bool
    private var hasPTY = false, shellStarted = false
    private var inputLine: [UInt8] = []
    private var cwd = "/initial"
    init(directory: URL, interactive: Bool, rejectPTY: Bool, stallPTY: Bool) {
        self.directory = directory; self.interactive = interactive; self.rejectPTY = rejectPTY; self.stallPTY = stallPTY
    }
    private func send(_ text: String, context: ChannelHandlerContext) {
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: text)))), promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.PseudoTerminalRequest {
            if stallPTY { return }
            hasPTY = interactive && !rejectPTY && request.term == "xterm-256color"
            context.triggerUserOutboundEvent(hasPTY ? ChannelSuccessEvent() as Any : ChannelFailureEvent() as Any, promise: nil); return
        }
        if event is SSHChannelRequestEvent.ShellRequest {
            guard hasPTY else { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
            shellStarted = true
            context.triggerUserOutboundEvent(ChannelSuccessEvent()).whenSuccess { self.send("READY> ", context: context) }; return
        }
        if let size = event as? SSHChannelRequestEvent.WindowChangeRequest, shellStarted {
            send("\r\nTERMSIZE \(size.terminalRowHeight)x\(size.terminalCharacterWidth)\r\nREADY> ", context: context); return
        }
        if let exec = event as? SSHChannelRequestEvent.ExecRequest {
            let data = SSHChannelData(type: exec.command == "stderr" ? .stdErr : .channel,
                data: .byteBuffer(ByteBuffer(string: exec.command == "stderr" ? "STDERR OUTPUT" : exec.command.uppercased())))
            context.writeAndFlush(NIOAny(data)).flatMap {
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: exec.command == "exit-7" ? 7 : 0))
            }.whenComplete { _ in context.close(promise: nil) }
            return
        }
        guard let request = event as? SSHChannelRequestEvent.SubsystemRequest else {
            context.fireUserInboundEventTriggered(event); return
        }
        guard request.subsystem == "sftp", process == nil else { context.close(promise: nil); return }
        let child = context.channel
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        process.arguments = ["-e", "-d", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { file in
            let bytes = file.availableData
            if bytes.isEmpty { file.readabilityHandler = nil; return }
            child.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))), promise: nil)
        }
        process.terminationHandler = { _ in child.close(promise: nil) }
        do {
            try process.run()
            self.process = process
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        } catch { context.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        if shellStarted, case .byteBuffer(let bytes) = data.data {
            for byte in bytes.readableBytesView {
                if byte == 3 { inputLine = []; send("^C\r\nREADY> ", context: context) }
                else if byte == 13 {
                    let line = String(decoding: inputLine, as: UTF8.self); inputLine = []
                    if line == "cd child" { cwd = "/initial/child" }
                    send("\r\n" + (line == "pwd" ? cwd : line.hasPrefix("echo ") ? String(line.dropFirst(5)) : "") + "\r\nREADY> ", context: context)
                } else if byte == 127 { if !inputLine.isEmpty { inputLine.removeLast() } }
                else { inputLine.append(byte); context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: [byte])))), promise: nil) }
            }
            return
        }
        guard data.type == .channel, case .byteBuffer(let bytes) = data.data, process != nil else { context.close(promise: nil); return }
        do { try input.fileHandleForWriting.write(contentsOf: Data(bytes.readableBytesView)) }
        catch { context.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        context.fireChannelInactive()
    }
}
