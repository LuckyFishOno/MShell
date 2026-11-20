import Foundation
import CryptoKit
import MasterPassword

public enum WorkspaceError: Error, LocalizedError {
    case invalid(String), changedHostKey(String), rejectedHostKey, disconnected, alreadyExists(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changedHostKey(let endpoint): return "The host key for \(endpoint) has changed. Connection refused. Verify the server before updating known-hosts.json."
        case .rejectedHostKey: return "Host key was not approved."
        case .disconnected: return "The session is disconnected."
        case .alreadyExists(let name): return "\(name) already exists. Confirm replacement before uploading."
        }
    }
}

func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@MainActor public final class KnownHosts {
    private let url: URL
    private var keys: [String: String]
    public init(url: URL) throws {
        self.url = url
        keys = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) : [:]
    }
    public static func endpoint(host: String, port: Int) -> String { "[\(host.lowercased())]:\(port)" }
    public static func fingerprint(_ key: String) throws -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else { throw WorkspaceError.invalid("Invalid host public key.") }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public func isTrusted(endpoint: String, key: String) throws -> Bool {
        _ = try Self.fingerprint(key)
        guard let saved = keys[endpoint] else { return false }
        guard saved == key else { throw WorkspaceError.changedHostKey(endpoint) }
        return true
    }
    public func trust(endpoint: String, key: String) throws {
        _ = try isTrusted(endpoint: endpoint, key: key)
        var updated = keys; updated[endpoint] = key
        try writePrivate(JSONEncoder().encode(updated), to: url)
        keys = updated
    }
}

public actor CredentialVault {
    private let url: URL
    private var vault: MasterVault?
    private var sessionPasswords: [String: String] = [:]
    public private(set) var sessionGeneration = UUID()
    public init(url: URL) throws {
        self.url = url
        vault = FileManager.default.fileExists(atPath: url.path) ? try MasterVault.load(Data(contentsOf: url)) : nil
    }
    public var state: String { vault == nil ? "Not configured" : vault!.isLocked ? "Locked" : "Unlocked" }
    public func create(password: String, iterations: Int = MasterVault.defaultIterations) throws {
        guard vault == nil else { throw WorkspaceError.invalid("A vault already exists. Unlock it instead.") }
        let created = try MasterVault.create(password: password, iterations: iterations)
        try writePrivate(created.serialized(), to: url); vault = created
    }
    public func unlock(password: String) throws {
        guard let vault else { throw WorkspaceError.invalid("Create a vault first.") }
        self.vault = try vault.unlocked(password: password)
    }
    public func lock() { vault = vault?.locked(); sessionPasswords.removeAll(); sessionGeneration = UUID() }
    public func rememberForSession(id: String, password: String, generation: UUID) {
        guard generation == sessionGeneration else { return }
        sessionPasswords[id] = password
    }
    public func forgetForSession(id: String) { sessionPasswords.removeValue(forKey: id) }
    public func save(id: String, password: String) throws {
        guard let vault else { throw VaultError.locked }
        let updated = try vault.storing(id: id, secret: password, overwrite: true)
        try writePrivate(updated.serialized(), to: url); self.vault = updated; sessionPasswords[id] = password
    }
    public func password(id: String) throws -> String {
        if let password = sessionPasswords[id] { return password }
        guard let vault else { throw VaultError.locked }; return try vault.retrieve(id: id)
    }
}
