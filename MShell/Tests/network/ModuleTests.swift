import XCTest
import Foundation
import NIOCore
import NIOPosix
import CarveShared
@testable import Network

final class NetworkFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() {
        XCTAssertEqual(NetworkFeature.id, "network")
        XCTAssertEqual(NetworkFeature.contractSha256, "54a2df7059c845834cecf1adce9ce597961f66d3f8497ed5ba7a2454aedf247e")
    }

    func testFeatureReadinessAndDescribe() throws {
        let ready = try NetworkFeature.run(FeatureRequest(payload: ""), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(ready.payload.contains("\"ready\":true"))
        XCTAssertTrue(ready.payload.contains("socks5"))
        let r = try NetworkFeature.run(FeatureRequest(payload: #"{"op":"describe","host":"h","port":22,"proxy":{"kind":"socks5","host":"p","port":1080}}"#), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(r.payload.contains("\"proxy\":\"socks5\""))
        XCTAssertTrue(r.payload.contains("\"proxyPort\":1080"))
    }

    func testDescribeRejectsBadTargetAndProxy() {
        XCTAssertThrowsError(try NetworkFeature.run(FeatureRequest(payload: #"{"op":"describe","host":"","port":22}"#), dependencies: FeatureOutputs([:])))
        XCTAssertThrowsError(try NetworkFeature.run(FeatureRequest(payload: #"{"op":"describe","host":"h","port":70000}"#), dependencies: FeatureOutputs([:])))
        XCTAssertThrowsError(try NetworkFeature.run(FeatureRequest(payload: #"{"op":"describe","host":"h","port":22,"proxy":{"kind":"mystery"}}"#), dependencies: FeatureOutputs([:])))
    }

    func testProxyConfigurationDefaults() {
        XCTAssertEqual(ProxyConfiguration.direct.kind, .none)
        XCTAssertEqual(ProxyConfiguration(kind: .socks5, host: "p").port, 1080)
    }
}

// Captures the first inbound ByteBuffer into a promise so a test can read a reply off a bare channel.
private final class CollectHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let promise: EventLoopPromise<String>
    init(_ p: EventLoopPromise<String>) { promise = p }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        promise.succeed(buf.readString(length: buf.readableBytes) ?? "")
    }
}

// Writes back whatever it receives.
private final class EchoHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

final class NetworkDirectConnectTests: XCTestCase {
    func testDirectConnectReachesEchoServerAndReturnsChannel() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { ch in ch.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)

        let channel = try await NetworkConnector.connect(host: "127.0.0.1", port: port, proxy: .direct, group: group, connectTimeout: .seconds(5))
        let reply = channel.eventLoop.makePromise(of: String.self)
        try await channel.pipeline.addHandler(CollectHandler(reply)).get()
        try await channel.writeAndFlush(ByteBuffer(string: "ping")).get()
        let got = try await reply.futureResult.get()
        XCTAssertEqual(got, "ping")
        try await channel.close().get()
    }

    func testConnectToClosedPortFailsCleanly() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        do {
            _ = try await NetworkConnector.connect(host: "127.0.0.1", port: 9, proxy: .direct, group: group, connectTimeout: .seconds(3))
            XCTFail("expected failure")
        } catch let e as NetworkError {
            guard case .connectFailed = e else { return XCTFail("wrong error \(e)") }
        }
    }

    func testInvalidTargetRejectedBeforeConnecting() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        do {
            _ = try await NetworkConnector.connect(host: "", port: 22, proxy: .direct, group: group)
            XCTFail("expected failure")
        } catch let e as NetworkError {
            guard case .invalidTarget = e else { return XCTFail("wrong error \(e)") }
        }
    }
}
