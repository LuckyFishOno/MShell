import Darwin
import Foundation
import NIOCore
import NIOSSH

public enum SSHAgentError: LocalizedError, Equatable {
    case unavailable
    case noIdentities
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No SSH agent is running. Start ssh-agent or choose a key file."
        case .noIdentities: return "The SSH agent has no keys MShell can use. Add one with ssh-add."
        case .failed(let detail): return detail
        }
    }
}

/// One key held by an SSH agent. The private key never leaves the agent; MShell asks it to sign.
public struct SSHAgentIdentity: Sendable, Equatable {
    /// The public key blob as the agent reports it.
    public let blob: [UInt8]
    public let comment: String
    public let type: String

    public var publicKeyLine: String { type + " " + Data(blob).base64EncodedString() }

    /// Key types MShell can offer through an agent. Security keys (`sk-*`) and certificates are not offered.
    static let supportedTypes: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                                              "ecdsa-sha2-nistp521", "ssh-rsa"]
}

/// A minimal client for the OpenSSH agent protocol (draft-miller-ssh-agent) over a Unix socket.
///
/// Calls block the calling thread with a timeout. NIOSSH signs synchronously during authentication, so a signature
/// request runs on the connection's event loop; the timeout bounds that wait when an agent asks the user to confirm.
public struct SSHAgentClient: Sendable {
    public let socketPath: String
    public var timeoutSeconds: Int

    private enum Message: UInt8 {
        case failure = 5
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
    }

    /// `SSH_AGENT_RSA_SHA2_512`: asks the agent for an `rsa-sha2-512` signature instead of SHA-1.
    static let rsaSHA512Flag: UInt32 = 4

    public init(socketPath: String, timeoutSeconds: Int = 60) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// The agent named by `SSH_AUTH_SOCK`, when set. macOS sets it for apps started from the Dock.
    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SSHAgentClient? {
        guard let path = environment["SSH_AUTH_SOCK"], path.hasPrefix("/") else { return nil }
        return SSHAgentClient(socketPath: path)
    }

    /// Lists the keys the agent holds that MShell can sign with.
    public func identities() throws -> [SSHAgentIdentity] {
        var reply = SSHWireReader(try request([Message.requestIdentities.rawValue]))
        guard let kind = try? reply.take(1).first, kind == Message.identitiesAnswer.rawValue else {
            throw SSHAgentError.failed("The SSH agent refused to list its keys.")
        }
        let count = try reply.uint32()
        guard count <= 1024 else { throw SSHAgentError.failed("The SSH agent sent an invalid key list.") }
        var identities: [SSHAgentIdentity] = []
        for _ in 0..<count {
            let blob = try reply.string()
            let comment = String(decoding: try reply.string(), as: UTF8.self)
            var header = SSHWireReader(blob)
            guard let type = try? header.text(), SSHAgentIdentity.supportedTypes.contains(type) else { continue }
            identities.append(SSHAgentIdentity(blob: blob, comment: comment, type: type))
        }
        return identities
    }

    /// Asks the agent to sign `data` with the key whose public blob is `blob`. Returns the signature blob.
    func sign(_ data: [UInt8], blob: [UInt8], flags: UInt32) throws -> [UInt8] {
        var message = SSHWireWriter()
        message.bytes.append(Message.signRequest.rawValue)
        message.string(blob)
        message.string(data)
        message.uint32(flags)
        var reply = SSHWireReader(try request(message.bytes))
        guard let kind = try? reply.take(1).first, kind == Message.signResponse.rawValue else {
            throw SSHAgentError.failed("The SSH agent declined to sign. It may need you to confirm the key.")
        }
        return try reply.string()
    }

    /// Wraps each usable identity as a key NIOSSH can offer.
    public func privateKeys() throws -> [NIOSSHPrivateKey] {
        try identities().compactMap { try? privateKey(for: $0) }
    }

    public func privateKey(for identity: SSHAgentIdentity) throws -> NIOSSHPrivateKey {
        var reader = SSHWireReader(identity.blob)
        _ = try reader.text()
        let body = reader.rest
        switch identity.type {
        case "ssh-ed25519": return NIOSSHPrivateKey(custom: SSHAgentKey<AgentEd25519>(agent: self, blob: identity.blob, body: body))
        case "ecdsa-sha2-nistp256": return NIOSSHPrivateKey(custom: SSHAgentKey<AgentP256>(agent: self, blob: identity.blob, body: body))
        case "ecdsa-sha2-nistp384": return NIOSSHPrivateKey(custom: SSHAgentKey<AgentP384>(agent: self, blob: identity.blob, body: body))
        case "ecdsa-sha2-nistp521": return NIOSSHPrivateKey(custom: SSHAgentKey<AgentP521>(agent: self, blob: identity.blob, body: body))
        case "ssh-rsa": return NIOSSHPrivateKey(custom: SSHAgentKey<AgentRSA>(agent: self, blob: identity.blob, body: body))
        default: throw SSHAgentError.noIdentities
        }
    }

    // MARK: Transport

    private func request(_ payload: [UInt8]) throws -> [UInt8] {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SSHAgentError.unavailable }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SSHAgentError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path)
            raw[path.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SSHAgentError.unavailable }

        var framed = SSHWireWriter()
        framed.string(payload)
        try write(descriptor, framed.bytes)
        var length = SSHWireReader(try read(descriptor, count: 4))
        let size = Int(try length.uint32())
        guard size > 0, size <= 256 * 1024 else { throw SSHAgentError.failed("The SSH agent sent an invalid reply.") }
        let reply = try read(descriptor, count: size)
        if reply.first == Message.failure.rawValue && size == 1 {
            throw SSHAgentError.failed("The SSH agent declined the request.")
        }
        return reply
    }

    private func write(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let result = bytes[sent...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw SSHAgentError.failed("The SSH agent connection closed.") }
            sent += result
        }
    }

    private func read(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let result = buffer[received...].withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if result < 0 && errno == EINTR { continue }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw SSHAgentError.failed("The SSH agent did not answer in time.")
            }
            guard result > 0 else { throw SSHAgentError.failed("The SSH agent connection closed.") }
            received += result
        }
        return buffer
    }
}

// MARK: - Agent-backed keys

/// Names one agent key algorithm. NIOSSH reads key and signature names from static members, so each algorithm is
/// its own type.
protocol AgentAlgorithm {
    /// The algorithm name sent in the userauth request. For RSA this is `rsa-sha2-512`.
    static var name: String { get }
    static var signFlags: UInt32 { get }
}

enum AgentEd25519: AgentAlgorithm { static let name = "ssh-ed25519"; static let signFlags: UInt32 = 0 }
enum AgentP256: AgentAlgorithm { static let name = "ecdsa-sha2-nistp256"; static let signFlags: UInt32 = 0 }
enum AgentP384: AgentAlgorithm { static let name = "ecdsa-sha2-nistp384"; static let signFlags: UInt32 = 0 }
enum AgentP521: AgentAlgorithm { static let name = "ecdsa-sha2-nistp521"; static let signFlags: UInt32 = 0 }
enum AgentRSA: AgentAlgorithm { static let name = "rsa-sha2-512"; static let signFlags = SSHAgentClient.rsaSHA512Flag }

struct SSHAgentKey<Algorithm: AgentAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }
    let agent: SSHAgentClient
    /// The agent's own blob, used to name the key in sign requests.
    let blob: [UInt8]
    let agentPublicKey: SSHAgentPublicKey<Algorithm>
    var publicKey: NIOSSHPublicKeyProtocol { agentPublicKey }

    init(agent: SSHAgentClient, blob: [UInt8], body: [UInt8]) {
        self.agent = agent
        self.blob = blob
        agentPublicKey = SSHAgentPublicKey(body: body)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        var reply = SSHWireReader(try agent.sign(Array(data), blob: blob, flags: Algorithm.signFlags))
        guard try reply.text() == Algorithm.name else {
            throw SSHAgentError.failed("The SSH agent signed with an unexpected algorithm.")
        }
        return SSHAgentSignature<Algorithm>(body: reply.rest)
    }
}

/// The key blob after its type name. NIOSSH writes `keyPrefix` and then these bytes unchanged.
struct SSHAgentPublicKey<Algorithm: AgentAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }
    let body: [UInt8]
    var rawRepresentation: Data { Data(body) }
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(body) }
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(body: buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}

/// The signature blob after its algorithm name, passed through as the agent produced it.
struct SSHAgentSignature<Algorithm: AgentAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }
    let body: [UInt8]
    var rawRepresentation: Data { Data(body) }
    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(body) }
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(body: buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}

extension SSHCredential {
    /// Keys to offer in order: the agent's keys, then the identity file. When the agent cannot be reached but a key
    /// file is set, the file alone is offered, as OpenSSH does.
    public static func keys(agent: SSHAgentClient?, identityFile: URL?, passphrase: String) throws -> SSHCredential {
        var keys: [NIOSSHPrivateKey] = []
        if let agent {
            do { keys += try agent.privateKeys() }
            catch where identityFile != nil {}
        }
        if let identityFile { keys.append(try SSHPrivateKeyFile.load(at: identityFile, passphrase: passphrase).key) }
        guard let first = keys.first else { throw SSHAgentError.noIdentities }
        return keys.count == 1 ? .privateKey(first) : .privateKeys(keys)
    }
}
