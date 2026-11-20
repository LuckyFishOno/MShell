import XCTest
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import FileTransfer

final class SFTPWireTests: XCTestCase {
    private func packet(_ bytes: [UInt8]) -> SSHChannelData {
        var frame = ByteBuffer(); frame.writeInteger(UInt32(bytes.count)); frame.writeBytes(bytes)
        return SSHChannelData(type: .channel, data: .byteBuffer(frame))
    }
    private func fixture() throws -> (EmbeddedChannel, SFTPHandler, EventLoopPromise<Void>) {
        let channel = EmbeddedChannel()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        let handler = SFTPHandler(readyPromise: ready, timeoutSeconds: 1)
        try channel.pipeline.addHandler(handler).wait()
        return (channel, handler, ready)
    }
    func testUnsupportedVersionFailsInitialization() throws {
        let (channel, _, ready) = try fixture(); defer { _ = try? channel.finish() }
        _ = try channel.writeInbound(packet([2, 0, 0, 0, 4]))
        XCTAssertThrowsError(try ready.futureResult.wait())
    }
    func testOversizedFrameFailsWithoutWaitingForItsBody() throws {
        let (channel, _, ready) = try fixture(); defer { _ = try? channel.finish() }
        var bytes = ByteBuffer(); bytes.writeInteger(UInt32(2 << 20))
        _ = try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))
        XCTAssertThrowsError(try ready.futureResult.wait())
    }
    func testInitializationTimeoutIsBounded() throws {
        let (channel, _, ready) = try fixture(); defer { _ = try? channel.finish() }
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        XCTAssertThrowsError(try ready.futureResult.wait())
    }
    func testFragmentedVersionAndRequestTimeout() throws {
        let (channel, handler, ready) = try fixture(); defer { _ = try? channel.finish() }
        let bytes: [UInt8] = [0, 0, 0, 5, 2, 0, 0, 0, 3]
        for byte in bytes { _ = try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: [byte])))) }
        XCTAssertNoThrow(try ready.futureResult.wait())
        let response = handler.request(type: .stat) { _ in }
        channel.embeddedEventLoop.advanceTime(by: .seconds(2))
        XCTAssertThrowsError(try response.wait())
    }
    func testTruncatedAttributesFailInsteadOfReturningPartialMetadata() throws {
        let (channel, handler, ready) = try fixture(); defer { _ = try? channel.finish() }
        _ = try channel.writeInbound(packet([2, 0, 0, 0, 3])); try ready.futureResult.wait()
        let response = handler.request(type: .stat) { _ in }
        // ATTRS for request1: size-present flag without its required 8-byte value.
        _ = try channel.writeInbound(packet([105, 0, 0, 0, 1, 0, 0, 0, 1]))
        XCTAssertThrowsError(try response.wait())
    }
    func testMalformedResponseFailsAllOutstandingRequests() throws {
        let (channel, handler, ready) = try fixture(); defer { _ = try? channel.finish() }
        _ = try channel.writeInbound(packet([2, 0, 0, 0, 3])); try ready.futureResult.wait()
        let first = handler.request(type: .stat) { _ in }
        let second = handler.request(type: .stat) { _ in }
        _ = try channel.writeInbound(packet([255]))
        XCTAssertThrowsError(try first.wait()); XCTAssertThrowsError(try second.wait())
    }
}
