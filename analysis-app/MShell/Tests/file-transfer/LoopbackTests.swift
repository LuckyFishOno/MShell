import XCTest
import Foundation
import Citadel
@preconcurrency import NIOSSH
import NIOCore
import NIOPosix
import CarveShared
import Network
@testable import Ssh
@testable import FileTransfer

// Real end-to-end tests: an in-process Citadel SSH server on 127.0.0.1 (random port), driven through
// our own SSHSession / SFTPTransfer wrappers. This exercises the actual SSH transport, auth, exec and
// SFTP data path, not mocks. The server side here is a minimal in-memory implementation that exists
// only to give the client something real to talk to; it is not part of the product.

// Accept one fixed password identity.
final class PasswordAuth: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let p) = request.request, request.username == "carve", p.password == "secret" {
            responsePromise.succeed(.success)
        } else {
            responsePromise.succeed(.failure)
        }
    }
}

// Exec delegate: replies on stdout with the uppercased command, so the test can prove a real round trip.
private final class UppercasingExec: ExecDelegate, @unchecked Sendable {
    struct Ctx: ExecCommandContext { func terminate() async throws {} }
    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        if command == "hang" { return Ctx() }
        DispatchQueue.global().async {
            let h = outputHandler.stdoutPipe.fileHandleForWriting
            h.write(Data(command.uppercased().utf8))
            try? h.close()
            Thread.sleep(forTimeInterval: 0.2)
            outputHandler.succeed(exitCode: command == "exit-7" ? 7 : 0)
        }
        return Ctx()
    }
}

// In-memory SFTP server: a path -> bytes store, enough for upload, download and one directory listing.
private final class MemorySFTP: SFTPDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [UInt8]] = [:]
    private var dirs: Set<String> = []

    private final class Handle: SFTPFileHandle, @unchecked Sendable {
        let owner: MemorySFTP; let path: String; let writable: Bool
        init(owner: MemorySFTP, path: String, writable: Bool) { self.owner = owner; self.path = path; self.writable = writable }
        func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
            owner.lock.lock(); defer { owner.lock.unlock() }
            let bytes = owner.files[path] ?? []
            let start = Int(offset); if start >= bytes.count { return ByteBuffer() }
            let end = min(start + Int(length), bytes.count)
            return ByteBuffer(bytes: bytes[start..<end])
        }
        func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
            owner.lock.lock(); defer { owner.lock.unlock() }
            var bytes = owner.files[path] ?? []
            let start = Int(offset); let incoming = Array(data.readableBytesView)
            if bytes.count < start + incoming.count { bytes.append(contentsOf: [UInt8](repeating: 0, count: start + incoming.count - bytes.count)) }
            bytes.replaceSubrange(start..<start + incoming.count, with: incoming)
            owner.files[path] = bytes
            return .ok
        }
        func close() async throws -> SFTPStatusCode { .ok }
        func readFileAttributes() async throws -> SFTPFileAttributes {
            owner.lock.lock(); defer { owner.lock.unlock() }
            return SFTPFileAttributes(size: UInt64(owner.files[path]?.count ?? 0))
        }
        func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
    }

    private final class Dir: SFTPDirectoryHandle, @unchecked Sendable {
        let entries: [SFTPPathComponent]; let done = NSLock(); var sent = false
        init(entries: [SFTPPathComponent]) { self.entries = entries }
        func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
            done.lock(); defer { done.unlock() }
            if sent { return [] }          // second call -> EOF
            sent = true
            return [SFTPFileListing(path: entries)]
        }
    }

    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        [SFTPPathComponent(filename: canonicalUrl, longname: canonicalUrl, attributes: .none)]
    }
    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes {
        lock.lock(); defer { lock.unlock() }
        guard let bytes = files[path] else { throw SFTPStatusCode.noSuchFile }
        return SFTPFileAttributes(size: UInt64(bytes.count))
    }
    func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
        lock.lock()
        if flags.contains(.create) && (files[filePath] == nil || flags.contains(.truncate)) { files[filePath] = [] }
        let exists = files[filePath] != nil
        lock.unlock()
        guard exists else { throw SFTPStatusCode.noSuchFile }
        return Handle(owner: self, path: filePath, writable: flags.contains(.write))
    }
    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode {
        lock.lock(); dirs.insert(filePath); lock.unlock(); return .ok
    }
    func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        lock.lock(); files[filePath] = nil; lock.unlock(); return .ok
    }
    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode {
        lock.lock(); defer { lock.unlock() }
        if let b = files[oldPath] { files[newPath] = b; files[oldPath] = nil }
        return .ok
    }
    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        lock.lock(); defer { lock.unlock() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let names = files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.filter { !$0.contains("/") }
        let comps = names.sorted().map { name -> SFTPPathComponent in
            SFTPPathComponent(filename: name, longname: name, attributes: SFTPFileAttributes(size: UInt64(files[prefix + name]?.count ?? 0)))
        }
        return Dir(entries: comps)
    }
    // Remaining protocol methods are not used by these tests.
    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode {
        lock.lock(); dirs.remove(filePath); lock.unlock(); return .ok
    }
    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { .ok }
    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { .unsupportedOperation }
    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw SFTPStatusCode.noSuchFile }
}

extension SFTPStatusCode: @retroactive Error {}

@available(macOS 15.0, *)
final class LoopbackTests: XCTestCase {
    // SSHServer.channel is internal, so the bound port is not readable. Bind an explicit high port and
    // retry on collision instead of using port 0.
    private func withServer(_ body: @escaping (Int, MemorySFTP) async throws -> Void) async throws {
        let sftp = MemorySFTP()
        var server: SSHServer?
        var port = 0
        for _ in 0..<12 {
            let candidate = Int.random(in: 49152...65500)
            do {
                server = try await SSHServer.host(
                    host: "127.0.0.1", port: candidate,
                    hostKeys: [NIOSSHPrivateKey(p521Key: .init())],
                    authenticationDelegate: PasswordAuth()
                )
                port = candidate
                break
            } catch { continue }
        }
        guard let server else { XCTFail("could not bind a loopback port"); return }
        server.enableExec(withDelegate: UppercasingExec())
        server.enableSFTP(withDelegate: sftp)
        do { try await body(port, sftp) } catch { try? await server.close(); throw error }
        try? await server.close()
    }

    private func session(_ port: Int) async throws -> SSHSession {
        try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "carve"),
                                     credential: .password("secret"), hostKey: .acceptAny, connectTimeoutSeconds: 5)
    }

    func testExecRoundTrip() async throws {
        try await withServer { port, _ in
            let s = try await self.session(port)
            let out = try await s.runCommand("hello world")
            XCTAssertEqual(out, "HELLO WORLD")
            try await s.close()
        }
    }

    // Both proxy-aware connection paths use the native NIOSSH product implementation.
    func testProxyDirectConnects() async throws {
        try await withServer { port, _ in
            let s = try await SSHSession.connect(
                settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "carve"),
                credential: .password("secret"), proxy: .direct, hostKey: .acceptAny, connectTimeoutSeconds: 5)
            let out = try await s.runCommand("via direct proxy path")
            XCTAssertEqual(out, "VIA DIRECT PROXY PATH")
            try await s.close()
        }
    }

    // SSH exec over a SOCKS5 proxy: a minimal in-process SOCKS5 proxy sits in front of the SSH server,
    // and SSHSession connects through it. Proves network(SOCKS5) -> ssh end to end on native NIOSSH.
    func testExecOverSOCKS5Proxy() async throws {
        try await withServer { sshPort, _ in
            let (proxy, proxyPort) = try await SOCKSTestProxy.start(upstreamHost: "127.0.0.1", upstreamPort: sshPort)
            defer { try? proxy.close().wait() }
            let s = try await SSHSession.connect(
                settings: SSHConnectionSettings(host: "127.0.0.1", port: sshPort, username: "carve"),
                credential: .password("secret"),
                proxy: ProxyConfiguration(kind: .socks5, host: "127.0.0.1", port: proxyPort),
                hostKey: .acceptAny, connectTimeoutSeconds: 5)
            let out = try await s.runCommand("through socks")
            XCTAssertEqual(out, "THROUGH SOCKS")
            try await s.close()
        }
    }

    func testSFTPOverSOCKS5Proxy() async throws {
        try await OpenSSHFixture.withServer { port, root in
            let (proxy, proxyPort) = try await SOCKSTestProxy.start(upstreamHost: "127.0.0.1", upstreamPort: port)
            let ssh = try await SSHSession.connect(settings: .init(host: "127.0.0.1", port: port, username: "carve"), credential: .password("secret"), proxy: .init(kind: .socks5, host: "127.0.0.1", port: proxyPort), connectTimeoutSeconds: 5)
            do {
                let transfer = try await SFTPTransfer.open(ssh)
                let input = root.appendingPathComponent("input.bin")
                let output = root.appendingPathComponent("output.bin")
                let remote = root.appendingPathComponent("remote.bin").path
                let payload = Data((0..<100000).map { UInt8($0 % 251) })
                try payload.write(to: input)
                try await transfer.upload(localURL: input, to: remote)
                try await transfer.download(remotePath: remote, to: output)
                XCTAssertEqual(try Data(contentsOf: output), payload)
                try await transfer.rename(from: remote, to: root.appendingPathComponent("renamed.bin").path)
                let entries = try await transfer.listDirectory(root.path)
                XCTAssertTrue(entries.contains { $0.name == "renamed.bin" })
                try await transfer.removeFile(root.appendingPathComponent("renamed.bin").path)
                try await transfer.close()
            } catch { try? await ssh.close(); try? await proxy.close().get(); throw error }
            try await ssh.close(); try await proxy.close().get()
        }
    }

    func testExecTimeoutAndNonzeroExitAndOutputLimit() async throws {
        try await withServer { port, _ in
            let ssh = try await self.session(port)
            do { _ = try await ssh.runCommand("hang", timeoutSeconds: 1); XCTFail("expected timeout") }
            catch let error as SSHError { XCTAssertEqual(error, .commandFailed("command timed out")) }
            do { _ = try await ssh.runCommand("exit-7"); XCTFail("expected exit error") }
            catch let error as SSHError { XCTAssertEqual(error, .commandFailed("exit status 7")) }
            do { _ = try await ssh.runCommand("too long", maxResponseBytes: 4); XCTFail("expected output limit") }
            catch let error as SSHError { XCTAssertEqual(error, .commandFailed("command output exceeds limit")) }
            try await ssh.close()
        }
    }

    func testUntrustedHostKeyFails() async throws {
        try await withServer { port, _ in
            do {
                _ = try await SSHSession.connect(settings: .init(host: "127.0.0.1", port: port, username: "carve"), credential: .password("secret"), hostKey: .trusted([]), connectTimeoutSeconds: 2)
                XCTFail("expected host key rejection")
            } catch let error as SSHError {
                guard case .connectFailed = error else { return XCTFail("unexpected error: \(error)") }
            }
        }
    }

    func testNetworkConnectorRejectsStalledSOCKSHandshake() async throws {
        let proxy = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        do {
            do {
                _ = try await NetworkConnector.connect(host: "127.0.0.1", port: 22, proxy: .init(kind: .socks5, host: "127.0.0.1", port: proxy.localAddress!.port!), group: MultiThreadedEventLoopGroup.singleton, connectTimeout: .seconds(1))
                XCTFail("expected proxy timeout")
            } catch let error as NetworkError {
                guard case .proxyFailed = error else { return XCTFail("unexpected error: \(error)") }
            }
            try await proxy.close().get()
        } catch { try? await proxy.close().get(); throw error }
    }

    func testSilentPeerTimesOutDuringHandshake() async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        do {
            do {
                _ = try await SSHSession.connect(settings: .init(host: "127.0.0.1", port: server.localAddress!.port!, username: "carve"), credential: .password("secret"), connectTimeoutSeconds: 1)
                XCTFail("expected handshake timeout")
            } catch let error as SSHError { XCTAssertEqual(error, .connectFailed("SSH handshake/authentication timed out")) }
            try await server.close().get()
        } catch { try? await server.close().get(); throw error }
    }

    func testNetworkConnectorEstablishesSOCKSBeforeReturning() async throws {
        try await OpenSSHFixture.withServer { port, _ in
            let (proxy, proxyPort) = try await SOCKSTestProxy.start(upstreamHost: "127.0.0.1", upstreamPort: port)
            do {
                let channel = try await NetworkConnector.connect(host: "127.0.0.1", port: port, proxy: .init(kind: .socks5, host: "127.0.0.1", port: proxyPort), group: MultiThreadedEventLoopGroup.singleton, connectTimeout: .seconds(2))
                XCTAssertTrue(channel.isActive)
                try await channel.close().get()
            } catch { try? await proxy.close().get(); throw error }
            try await proxy.close().get()
        }
    }

    func testRejectedExecChannelFailsWithoutHanging() async throws {
        try await OpenSSHFixture.withServer(rejectSessions: true) { port, _ in
            let ssh = try await self.session(port)
            do { _ = try await ssh.runCommand("denied", timeoutSeconds: 2); XCTFail("expected channel rejection") }
            catch let error as SSHError {
                guard case .commandFailed = error else { try? await ssh.close(); return XCTFail("unexpected error: \(error)") }
            }
            try await ssh.close()
        }
    }

    func testRejectedSFTPChannelFailsWithoutHanging() async throws {
        try await OpenSSHFixture.withServer(rejectSessions: true) { port, _ in
            let ssh = try await self.session(port)
            do { _ = try await SFTPSession.start(ssh, timeoutSeconds: 2); XCTFail("expected channel rejection") }
            catch { XCTAssertFalse(String(describing: error).isEmpty) }
            try await ssh.close()
        }
    }

    func testWrongPasswordFails() async throws {
        try await withServer { port, _ in
            do {
                _ = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "carve"),
                                                 credential: .password("wrong"), hostKey: .acceptAny, connectTimeoutSeconds: 5)
                XCTFail("expected auth failure")
            } catch let e as SSHError {
                switch e { case .connectFailed, .authenticationFailed: break; default: XCTFail("wrong error \(e)") }
            }
        }
    }

    func testSFTPUploadDownloadRoundTrip() async throws {
        try await OpenSSHFixture.withServer { port, root in
            let s = try await self.session(port)
            let sftp = try await SFTPTransfer.open(s)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carve-\(UUID().uuidString)")
            let localIn = tmp.appendingPathExtension("in"), localOut = tmp.appendingPathExtension("out")
            let payload = Data((0..<100000).map { UInt8($0 % 251) })   // crosses three 32 KiB chunk boundaries
            try payload.write(to: localIn)
            defer { try? FileManager.default.removeItem(at: localIn); try? FileManager.default.removeItem(at: localOut) }

            var lastProgress = 0.0
            try await sftp.upload(localURL: localIn, to: root.appendingPathComponent("data.bin").path) { p in if let f = p.fraction { lastProgress = f } }
            XCTAssertEqual(lastProgress, 1.0, accuracy: 0.0001)
            try await sftp.download(remotePath: root.appendingPathComponent("data.bin").path, to: localOut)
            XCTAssertEqual(try Data(contentsOf: localOut), payload)
            try await sftp.close(); try await s.close()
        }
    }

    func testSFTPListAndRenameAndRemove() async throws {
        try await OpenSSHFixture.withServer { port, root in
            let s = try await self.session(port)
            let sftp = try await SFTPTransfer.open(s)
            let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("carve-la-\(UUID().uuidString)")
            try Data("one".utf8).write(to: a)
            defer { try? FileManager.default.removeItem(at: a) }
            try await sftp.upload(localURL: a, to: root.appendingPathComponent("first.txt").path)
            try await sftp.rename(from: root.appendingPathComponent("first.txt").path, to: root.appendingPathComponent("renamed.txt").path)
            let entries = try await sftp.listDirectory(root.path)
            XCTAssertEqual(entries.map(\.name).sorted(), ["renamed.txt"])
            XCTAssertEqual(entries.first?.size, 3)
            try await sftp.removeFile(root.appendingPathComponent("renamed.txt").path)
            let afterRemove = try await sftp.listDirectory(root.path)
            XCTAssertTrue(afterRemove.isEmpty)
            try await sftp.close(); try await s.close()
        }
    }
}

final class CTRCompatibilityTests: XCTestCase {
    func testCTRAndSHA2OnlyPeerSupportsExecAndSFTP() async throws {
        try await OpenSSHFixture.withServer(ctrOnly: true) { port, root in
            let ssh = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: port, username: "carve"), credential: .password("secret"), connectTimeoutSeconds: 5)
            let output = try await ssh.runCommand("ctr compatibility")
            XCTAssertEqual(output, "CTR COMPATIBILITY")
            let sftp = try await SFTPTransfer.open(ssh)
            _ = try await sftp.listDirectory(root.path)
            try await sftp.close(); try await ssh.close()
        }
    }
}
