import Foundation
import LocalAuthentication
import CryptoKit
import MasterPassword

public enum WorkspaceError: Error, LocalizedError {
    case invalid(String), changedHostKey(String), rejectedHostKey, disconnected, alreadyExists(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .changedHostKey(let endpoint): return "The host key for \(endpoint) has changed. Verify the server before reconnecting."
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
        try store(endpoint: endpoint, key: key)
    }
    func trustedKey(for endpoint: String) -> String? { keys[endpoint] }

    func replace(endpoint: String, expectedKey: String, with newKey: String) throws {
        guard keys[endpoint] == expectedKey else {
            throw WorkspaceError.invalid("The saved host key changed during review. Reconnect to check it again.")
        }
        _ = try Self.fingerprint(newKey)
        try store(endpoint: endpoint, key: newKey)
    }

    private func store(endpoint: String, key: String) throws {
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
    /// Reads the vault key behind Touch ID. Set after a master-password unlock, for this app launch only.
    private var keyReader: (@Sendable (String) throws -> Data)?
    /// Passwords that signed in once, sealed for this Mac. Kept whether or not a password vault exists, so a session
    /// that does not ask on every connection connects while the vault is locked. Nil without a Secure Enclave.
    private var device: DeviceSecrets?
    var touchIDEnrolled: Bool { keyReader != nil }
    /// Whether a password that signs in is remembered without unlocking the vault.
    var savesWithoutUnlock: Bool { device != nil }
    /// Accounts with a password in the vault. Entry names are readable while it is locked; secrets are not.
    var vaultIdentifiers: Set<String> { Set(vault?.identifiers ?? []) }

    /// Passwords that sign in are remembered on this Mac (`deviceSecrets`) and connect again without asking. The
    /// password vault is a separate store: while it is unlocked, connections skip the per-connection check.
    public init(url: URL, deviceSecrets: URL? = nil) throws {
        self.url = url
        vault = FileManager.default.fileExists(atPath: url.path) ? try MasterVault.load(Data(contentsOf: url)) : nil
        if let deviceSecrets, DeviceSecrets.isAvailable { device = try DeviceSecrets(url: deviceSecrets) }
    }

    /// Touch ID unlock lasts for this app launch only; a restart needs the master password (DATA-PROTECTION.md).
    private func forgetTouchID() { keyReader = nil }
    public var state: String { vault == nil ? "Not configured" : vault!.isLocked ? "Locked" : "Unlocked" }
    public func create(password: String, iterations: Int = MasterVault.defaultIterations) throws {
        guard vault == nil else { throw WorkspaceError.invalid("A vault already exists. Unlock it instead.") }
        let created = try MasterVault.create(password: password, iterations: iterations)
        try writePrivate(created.serialized(), to: url); vault = created
    }
    /// Checks the master password without unlocking the vault.
    func verifyMasterPassword(_ password: String) -> Bool {
        guard let vault else { return false }
        return (try? vault.unlocked(password: password)) != nil
    }
    public func unlock(password: String) throws {
        guard let vault else { throw WorkspaceError.invalid("Create a vault first.") }
        self.vault = try vault.unlocked(password: password)
    }

    func enableTouchIDAfterPasswordUnlock() throws {
        guard VaultTouchID.isAvailable, let vault, !vault.isLocked else { return }
        do {
            let touchID = try VaultTouchID(protecting: vault.vaultKeyForProtectedStorage())
            keyReader = { try touchID.readKey(reason: $0) }
        } catch {
            forgetTouchID()
            throw WorkspaceError.invalid("Could not enable Touch ID for the password vault.")
        }
    }

    /// Tests stand in for the Touch ID prompt: `onPrompt` runs where it would appear. Needs the vault unlocked.
    func enableTouchIDForTesting(onPrompt: @escaping @Sendable (String) -> Void) throws {
        guard let vault, !vault.isLocked else { throw VaultError.locked }
        let key = try vault.vaultKeyForProtectedStorage()
        keyReader = { onPrompt($0); return key }
    }

    func unlockWithTouchID(reason: String) async throws {
        guard let vault, vault.isLocked else { throw VaultError.locked }
        let generation = sessionGeneration
        let key = try await touchIDKey(reason: reason)
        guard sessionGeneration == generation, !Task.isCancelled, self.vault?.isLocked == true else { return }
        do {
            self.vault = try vault.unlocked(vaultKey: key)
        } catch {
            forgetTouchID()
            throw WorkspaceError.invalid("Touch ID could not unlock the vault. Enter the master password.")
        }
    }

    /// Of `ids`, the ones only the locked vault can supply: not remembered on this Mac or for this launch.
    func lockedVaultIDs(_ ids: Set<String>) -> Set<String> {
        guard let vault, vault.isLocked else { return [] }
        return ids.filter { id in
            sessionPasswords[id] == nil && (try? device?.secret(id: id)) == nil && vault.identifiers.contains(id)
        }
    }

    /// One Touch ID prompt for one connection: reads `ids` out of the locked vault for this launch. The vault itself
    /// stays locked, so the next session that asks on every connection asks again.
    func readWithTouchID(ids: Set<String>, reason: String) async throws {
        guard let vault, vault.isLocked else { return }
        let generation = sessionGeneration
        let key = try await touchIDKey(reason: reason)
        guard sessionGeneration == generation, !Task.isCancelled else { return }
        let opened: MasterVault
        do { opened = try vault.unlocked(vaultKey: key) }
        catch {
            forgetTouchID()
            throw WorkspaceError.invalid("Touch ID could not unlock the vault. Enter the master password.")
        }
        for id in ids { if let secret = try? opened.retrieve(id: id) { sessionPasswords[id] = secret } }
    }

    private func touchIDKey(reason: String) async throws -> Data {
        guard let keyReader else { throw VaultError.locked }
        let generation = sessionGeneration
        do {
            return try await Task.detached { try keyReader(reason) }.value
        } catch let error as LAError {
            // Cancelled, locked out, or not now: keep Touch ID set up for next time.
            throw WorkspaceError.invalid(error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel
                ? "Touch ID was cancelled. Enter the master password or try again."
                : "Touch ID could not unlock the vault. Enter the master password.")
        } catch {
            // The Secure Enclave key no longer opens (for example, fingerprints changed).
            if sessionGeneration == generation { forgetTouchID() }
            throw WorkspaceError.invalid("Touch ID could not unlock the vault. Enter the master password.")
        }
    }
    public func lock() { vault = vault?.locked(); sessionPasswords.removeAll(); sessionGeneration = UUID() }
    public func rememberForSession(id: String, password: String, generation: UUID) {
        guard generation == sessionGeneration else { return }
        sessionPasswords[id] = password
    }
    public func forgetForSession(id: String) { sessionPasswords.removeValue(forKey: id) }
    /// Drops a remembered secret the server just refused, so the form asks for the new one.
    func forgetForSession(id: String, matching password: String, generation: UUID) {
        guard generation == sessionGeneration else { return }
        if sessionPasswords[id] == password { forgetForSession(id: id) }
        if (try? device?.secret(id: id)) == password { try? device?.remove(id: id) }
    }
    /// Remembers a password: on this Mac when it has a Secure Enclave, otherwise in the unlocked vault.
    public func save(id: String, password: String) throws {
        if device != nil {
            try device?.store(id: id, secret: password); sessionPasswords[id] = password
            return
        }
        try addToVault(id: id, secret: password)
        sessionPasswords[id] = password
    }

    /// Puts a password in the master-password vault, a separate copy the user chose to keep. Needs the vault unlocked.
    public func addToVault(id: String, secret: String) throws {
        guard let vault else { throw WorkspaceError.invalid("Create the password vault first.") }
        let updated = try vault.storing(id: id, secret: secret, overwrite: true)
        try writePrivate(updated.serialized(), to: url); self.vault = updated
    }

    /// The secret to sign in with: remembered for this launch, remembered on this Mac, or in the unlocked vault.
    public func password(id: String) throws -> String {
        if let password = sessionPasswords[id] { return password }
        if let saved = try device?.secret(id: id) { return saved }
        guard let vault, device == nil || vault.identifiers.contains(id) else {
            throw device == nil ? VaultError.locked : VaultError.notFound(id)
        }
        return try vault.retrieve(id: id)
    }

    /// Keeps a secret that just signed in, so the next connection needs no typing, also after a restart. Without a
    /// Secure Enclave it goes to the vault when it is unlocked, and is kept for this app launch otherwise.
    public func rememberWorking(id: String, secret: String, generation: UUID) {
        guard generation == sessionGeneration, !secret.isEmpty else { return }
        sessionPasswords[id] = secret
        persist(id: id, secret: secret)
    }

    /// Runs after an unlock. Without a Secure Enclave, saves secrets that signed in while the vault was locked.
    func persistSessionSecrets() {
        for (id, secret) in sessionPasswords { persist(id: id, secret: secret) }
    }

    private func persist(id: String, secret: String) {
        if device != nil {
            if (try? device?.secret(id: id)) != secret { try? device?.store(id: id, secret: secret) }
            return
        }
        guard let vault, !vault.isLocked, (try? vault.retrieve(id: id)) != secret else { return }
        try? addToVault(id: id, secret: secret)
    }

    // MARK: Saved sign-ins list

    enum Place: Equatable, Sendable { case thisMac, vault }

    /// Every saved sign-in and where it is kept. Vault entry names are readable while it is locked; secrets are not.
    func savedEntries() -> [(id: String, place: Place)] {
        (device?.identifiers ?? []).map { ($0, Place.thisMac) } + (vault?.identifiers ?? []).map { ($0, Place.vault) }
    }

    func revealSaved(id: String, in place: Place) throws -> String {
        switch place {
        case .thisMac:
            guard let saved = try device?.secret(id: id) else { throw VaultError.notFound(id) }
            return saved
        case .vault:
            guard let vault else { throw VaultError.notFound(id) }
            return try vault.retrieve(id: id)
        }
    }

    func removeSaved(id: String, from place: Place) throws {
        switch place {
        case .thisMac:
            try device?.remove(id: id)
            sessionPasswords.removeValue(forKey: id)
        case .vault:
            guard let vault else { return }
            let updated = try vault.removing(id: id)
            try writePrivate(updated.serialized(), to: url); self.vault = updated
        }
    }

    /// Withdraws what lets an account connect without typing: the copy on this Mac and for this launch, and the vault
    /// copy while the vault is unlocked. A copy in the locked vault stays; using it needs an unlock.
    func forgetRemembered(id: String) throws {
        try device?.remove(id: id)
        sessionPasswords.removeValue(forKey: id)
        if let vault, !vault.isLocked, vault.identifiers.contains(id) { try removeSaved(id: id, from: .vault) }
    }
}
