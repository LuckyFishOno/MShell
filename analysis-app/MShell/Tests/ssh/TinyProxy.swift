import Darwin
import Foundation
import XCTest

/// A loopback HTTP CONNECT or SOCKS4/4a proxy for tests. It records each request and pipes bytes to 127.0.0.1.
final class TinyProxy: @unchecked Sendable {
    enum Mode { case http, socks4, httpNeedsSignIn }

    let port: Int
    private let listener: Int32
    private let mode: Mode
    private let lock = NSLock()
    private var requests: [String] = []
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }

    init(_ mode: Mode) throws {
        self.mode = mode
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw XCTSkip("The test proxy could not listen.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread { [self] in acceptLoop() }.start()
    }

    func stop() { shutdown(listener, SHUT_RDWR); close(listener) }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            Thread { [self] in serve(client) }.start()
        }
    }

    private func serve(_ client: Int32) {
        var buffer: [UInt8] = []
        func readMore() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return false }
            buffer += chunk[..<count]
            return true
        }
        var targetPort = 0
        var reply: [UInt8] = []
        switch mode {
        case .http, .httpNeedsSignIn:
            while buffer.firstRange(of: Array("\r\n\r\n".utf8)) == nil { guard readMore() else { close(client); return } }
            let line = String(decoding: buffer, as: UTF8.self).components(separatedBy: "\r\n")[0]
            record(line)
            if mode == .httpNeedsSignIn {
                _ = write(client, Array("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n".utf8), 66)
                close(client); return
            }
            targetPort = Int(line.split(separator: " ")[1].split(separator: ":").last ?? "") ?? 0
            reply = Array("HTTP/1.1 200 Connection established\r\nProxy-Agent: tiny\r\n\r\n".utf8)
        case .socks4:
            while buffer.count < 9 || !buffer[8...].contains(0) { guard readMore() else { close(client); return } }
            targetPort = Int(buffer[2]) << 8 | Int(buffer[3])
            var name = "\(buffer[4]).\(buffer[5]).\(buffer[6]).\(buffer[7])"
            if buffer[4...6] == [0, 0, 0] && buffer[7] != 0 {
                let userEnd = buffer[8...].firstIndex(of: 0)!
                while !buffer[(userEnd + 1)...].contains(0) { guard readMore() else { close(client); return } }
                let nameEnd = buffer[(userEnd + 1)...].firstIndex(of: 0)!
                name = "4a:" + String(decoding: buffer[(userEnd + 1)..<nameEnd], as: UTF8.self)
            }
            record("SOCKS4 \(name):\(targetPort)")
            reply = [0, 90, 0, 0, 0, 0, 0, 0]
        }
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(targetPort).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(client); close(upstream); return }
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        Thread { Self.pump(from: upstream, to: client) }.start()
        Self.pump(from: client, to: upstream)
    }

    private func record(_ line: String) { lock.lock(); requests.append(line); lock.unlock() }

    private static func pump(from source: Int32, to destination: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(source, &chunk, chunk.count)
            guard count > 0 else { break }
            var sent = 0
            while sent < count {
                let result = chunk[sent..<count].withUnsafeBytes { write(destination, $0.baseAddress, $0.count) }
                guard result > 0 else { break }
                sent += result
            }
        }
        shutdown(destination, SHUT_WR)
    }
}
