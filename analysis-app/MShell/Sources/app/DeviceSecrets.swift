import CryptoKit
import Foundation
import MasterPassword
import Security

/// Sign-in secrets that work without unlocking anything, on this Mac only.
///
/// Each entry is sealed with AES-GCM under a key rebuilt from a Secure Enclave key agreement, with the entry ID bound
/// as associated data. The file holds the enclave's wrapped key handle, which no other Mac can use; the enclave key
/// needs no Touch ID, so a saved password connects again after the app restarts.
struct DeviceSecrets {
    static var isAvailable: Bool { SecureEnclave.isAvailable }
    private static let contextInfo = Data("MShell saved sign-ins v1".utf8)

    private struct File: Codable {
        var version = 1
        var enclaveKey: Data
        var peerKey: Data
        var entries: [String: Data] = [:]
    }

    private let url: URL
    private var file: File?
    private var key: SymmetricKey?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let loaded = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard loaded.version == 1 else { throw WorkspaceError.invalid("Saved sign-ins use an unknown format.") }
            file = loaded
        }
    }

    func contains(_ id: String) -> Bool { file?.entries[id] != nil }
    var identifiers: [String] { file?.entries.keys.sorted() ?? [] }

    mutating func secret(id: String) throws -> String? {
        guard let sealed = file?.entries[id] else { return nil }
        let box = try AES.GCM.SealedBox(combined: sealed)
        return String(decoding: try AES.GCM.open(box, using: try symmetricKey(), authenticating: Data(id.utf8)), as: UTF8.self)
    }

    mutating func store(id: String, secret: String) throws {
        if file == nil { file = try Self.newFile() }
        guard let sealed = try AES.GCM.seal(Data(secret.utf8), using: try symmetricKey(), authenticating: Data(id.utf8)).combined else {
            throw WorkspaceError.invalid("Could not save the sign-in.")
        }
        file?.entries[id] = sealed
        try save()
    }

    mutating func remove(id: String) throws {
        guard file?.entries.removeValue(forKey: id) != nil else { return }
        try save()
    }

    private func save() throws {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(encoder.encode(file), to: url)
    }

    private mutating func symmetricKey() throws -> SymmetricKey {
        if let key { return key }
        guard let file else { throw VaultError.notFound("saved sign-ins") }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.enclaveKey)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: file.peerKey)
        let shared = try enclave.sharedSecretFromKeyAgreement(with: peer)
        let derived = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Self.contextInfo, outputByteCount: 32)
        key = derived
        return derived
    }

    private static func newFile() throws -> File {
        guard isAvailable, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                                          [.privateKeyUsage], nil) else {
            throw WorkspaceError.invalid("This Mac has no Secure Enclave.")
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let peer = P256.KeyAgreement.PrivateKey()
        return File(enclaveKey: enclave.dataRepresentation, peerKey: peer.publicKey.x963Representation)
    }
}
