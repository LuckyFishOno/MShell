import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import App

@MainActor final class TunnelWorkspaceTests: XCTestCase {
    func testSavedJumpRoutesTerminalSFTPAndLoopbackForwardWithIndependentTrust() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let echo = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { $0.pipeline.addHandler(EchoAfterEOF()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { echo.close(promise: nil) }
        let servicePort = try XCTUnwrap(echo.localAddress?.port)
        let targetName = "target.mshell.invalid"
        let serviceName = "service.mshell.invalid"
        let targetAuth = ScopedPassword(user: "target", secret: "target-fixture")
        try await OpenSSHFixture.withServer(interactive: true, auth: targetAuth,
                                            route: .init(host: serviceName, port: servicePort)) { targetPort, directory in
            let marker = directory.appendingPathComponent("from-target.txt")
            try Data("target fixture".utf8).write(to: marker)
            let jumpAuth = ScopedPassword(user: "jump", secret: "jump-fixture")
            try await OpenSSHFixture.withServer(auth: jumpAuth, route: .init(host: targetName, port: targetPort)) { jumpPort, _ in
                let root = self.scratch()
                let model = try WorkspaceModel(storage: root)
                let jump = try model.sessionTree.add(name: "Jump", parent: nil, connection: .init(
                    host: "127.0.0.1", port: jumpPort, username: "jump"
                ))
                let target = try model.sessionTree.add(name: "Target", parent: nil, connection: .init(
                    host: targetName, port: targetPort, username: "target", jumpSessionID: jump
                ))
                let reloaded = try WorkspaceModel(storage: root)
                let item = try XCTUnwrap(reloaded.sessionTree.node(target))
                let tab = try XCTUnwrap(reloaded.openSaved(item))
                tab.password = "target-fixture"
                tab.jumpSecret = "jump-fixture"

                await self.approve(reloaded, tab, endpoint: "[127.0.0.1]:\(jumpPort)")
                await self.approve(reloaded, tab, endpoint: "[\(targetName)]:\(targetPort)")
                await tab.savedConnectionTask?.value

                XCTAssertTrue(tab.connected, tab.error ?? "")
                XCTAssertTrue(tab.terminalReady, tab.error ?? "")
                XCTAssertEqual(tab.password, "")
                XCTAssertEqual(tab.jumpSecret, "")
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sessions.json"), encoding: .utf8)
                    .contains("-fixture"), false)
                await reloaded.refreshFiles(tab)
                XCTAssertEqual(tab.entries.map(\.name), ["from-target.txt"])

                let forward = try await reloaded.startForward(tab, localPort: 0, host: serviceName, port: servicePort)
                let bytes = (0..<(128 * 1024)).map { UInt8(truncatingIfNeeded: $0) }
                let roundTrip = try await roundTripBytes(bytes, port: forward.handle.port)
                XCTAssertEqual(roundTrip, bytes)

                await reloaded.stopForward(tab, forward)
                XCTAssertTrue(tab.forwards.isEmpty)
                // Binding the same loopback port proves the listener was relinquished.
                let replacement = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: forward.handle.port).get()
                try await replacement.close().get()
                XCTAssertTrue(tab.connected)
                await reloaded.closeAll()
            }
        }
    }

    func testDisconnectClearsForwardAndPermitsFreshSSHHandshake() async throws {
        let transport = FixtureTransport()
        try await OpenSSHFixture.withServer(interactive: true, onTransport: { transport.record($0) }) { port, _ in
            let model = try WorkspaceModel(storage: self.scratch())
            let tab = try XCTUnwrap(model.selected)
            tab.host = "127.0.0.1"; tab.port = String(port); tab.username = "carve"; tab.password = "secret"
            let login = Task { await model.connect(tab) }
            await self.approve(model, tab, endpoint: "[127.0.0.1]:\(port)")
            await login.value
            await model.startTerminal(tab)
            XCTAssertTrue(tab.terminalReady)
            let forward = try await model.startForward(tab, localPort: 0, host: "127.0.0.1", port: 22)

            try await transport.closeCurrent()
            for _ in 0..<300 {
                if tab.transportLost { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(tab.transportLost)
            XCTAssertFalse(tab.connected)
            XCTAssertFalse(tab.terminalReady)
            XCTAssertTrue(tab.forwards.isEmpty)
            await forward.handle.waitForClose()

            await model.connect(tab)
            await model.startTerminal(tab)
            XCTAssertTrue(tab.connected, tab.error ?? "")
            XCTAssertTrue(tab.terminalReady)
            XCTAssertFalse(tab.transportLost)
            XCTAssertNil(tab.hostKeyPrompt)
            await model.closeAll()
        }
    }

    private func scratch() -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-tunnel-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func approve(_ workspace: WorkspaceModel, _ tab: SessionTab, endpoint: String) async {
        for _ in 0..<300 {
            if let prompt = tab.hostKeyPrompt {
                XCTAssertEqual(prompt.endpoint, endpoint)
                workspace.answerHostKey(tab, approve: prompt.endpoint == endpoint)
                return
            }
            if tab.status == "Connection failed" { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Missing approval for \(endpoint). \(tab.error ?? "")")
        await workspace.disconnect(tab)
    }
}

private struct ScopedPassword: NIOSSHServerUserAuthenticationDelegate {
    let user: String
    let secret: String
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let password) = request.request, request.username == user, password.password == secret {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

private final class FixtureTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Channel?
    func record(_ channel: Channel) { lock.withLock { current = channel } }
    func closeCurrent() async throws {
        let channel = try XCTUnwrap(lock.withLock { current })
        try await channel.close().get()
    }
}

private final class EchoAfterEOF: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var received = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        received.writeBuffer(&chunk)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            let channel = context.channel
            channel.writeAndFlush(received).whenComplete { _ in channel.close(promise: nil) }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private func roundTripBytes(_ bytes: [UInt8], port: Int) async throws -> [UInt8] {
    let loop = MultiThreadedEventLoopGroup.singleton.next()
    let result = loop.makePromise(of: [UInt8].self)
    let reader = ReadBack(expectedCount: bytes.count, result: result)
    let channel = try await ClientBootstrap(group: loop).connectTimeout(.seconds(3))
        .channelInitializer { $0.pipeline.addHandler(reader) }
        .connect(host: "127.0.0.1", port: port).get()
    let deadline = loop.scheduleTask(in: .seconds(5)) { channel.close(promise: nil) }
    defer { deadline.cancel(); channel.close(promise: nil) }
    try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
    try await channel.close(mode: .output).get()
    return try await result.futureResult.get()
}

private final class ReadBack: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let expectedCount: Int
    let result: EventLoopPromise<[UInt8]>
    private var received: [UInt8] = []
    private var completed = false
    init(expectedCount: Int, result: EventLoopPromise<[UInt8]>) {
        self.expectedCount = expectedCount
        self.result = result
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        received.append(contentsOf: unwrapInboundIn(data).readableBytesView)
        if received.count >= expectedCount, !completed {
            completed = true
            result.succeed(received)
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !completed { completed = true; result.fail(ChannelError.eof) }
        context.fireChannelInactive()
    }
}
