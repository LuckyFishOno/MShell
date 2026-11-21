import Foundation
import XCTest

/// A throwaway OpenSSH server on 127.0.0.1 for the current macOS user. It accepts only the keys that
/// tests add, never passwords, and is stopped when the test ends. Tests skip when OpenSSH is missing.
final class LocalSSHD {
    let directory: URL
    let port: Int
    let user = NSUserName()
    private let process = Process()

    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")
    }

    init(extraConfig: String = "") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        port = Int.random(in: 30000...45000)
        try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path("host_ed25519")])
        FileManager.default.createFile(atPath: path("authorized_keys"), contents: Data())
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(path("host_ed25519"))
        AuthorizedKeysFile \(path("authorized_keys"))
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        PidFile \(path("sshd.pid"))
        AllowTcpForwarding yes
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        \(extraConfig)
        """
        try config.write(toFile: path("sshd_config"), atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", path("sshd_config")]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        // Wait until the listener accepts connections.
        for _ in 0..<50 {
            if Self.canConnect(port: port) { return }
            usleep(100_000)
        }
        stop()
        throw XCTSkip("The local sshd did not start.")
    }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// Creates a key with ssh-keygen, authorizes its public half, and returns the private key path.
    @discardableResult
    func addKey(_ name: String, type: String, bits: Int? = nil, passphrase: String = "", format: String? = nil) throws -> URL {
        var arguments = ["-q", "-t", type, "-N", passphrase, "-f", path(name), "-C", name]
        if let bits { arguments += ["-b", String(bits)] }
        if let format { arguments += ["-m", format] }
        try Self.run("/usr/bin/ssh-keygen", arguments)
        try authorize(publicKey: String(contentsOfFile: path(name + ".pub"), encoding: .utf8))
        return URL(fileURLWithPath: path(name))
    }

    func authorize(publicKey line: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path("authorized_keys")))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    }

    /// Polls rather than calling `waitUntilExit`, which can hang when called from an async teardown on a thread
    /// without a run loop after sshd has already exited.
    func stop() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw XCTSkip("\(tool) failed") }
    }

    static func canConnect(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
