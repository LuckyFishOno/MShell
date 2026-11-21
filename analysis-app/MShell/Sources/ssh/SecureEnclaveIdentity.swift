import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

/// A device-bound P-256 identity. The file holds only the Secure Enclave's sealed key representation.
///
/// Keys never leave this Mac's Secure Enclave. New keys sign without Touch ID: in MShell, Touch ID guards the password
/// vault only. Keys created by 0.10.0 builds still require Touch ID; they ask once per app launch.
public enum SecureEnclaveSSHIdentity {
    static let prefix = "MShell-Secure-Enclave-P256-v1:"

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public static func create() throws -> (fileContents: Data, publicKey: String) {
        guard isAvailable,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage], nil) else {
            throw SSHKeyFileError.unsupported("This Mac has no Secure Enclave.")
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let identity = SecureEnclaveSigner(key: key)
        return (Data((prefix + key.dataRepresentation.base64EncodedString() + "\n").utf8), identity.publicKeyLine)
    }

    /// The OpenSSH public key line of a saved identity. Reading the public half needs no Touch ID.
    public static func publicKey(of fileContents: Data) throws -> String {
        let text = String(decoding: fileContents, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix), let blob = Data(base64Encoded: String(text.dropFirst(prefix.count))), !blob.isEmpty else {
            throw SSHKeyFileError.invalid
        }
        guard isAvailable else { throw SSHKeyFileError.unsupported("This Mac has no Secure Enclave.") }
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        return SecureEnclaveSigner(key: key).publicKeyLine
    }

    /// Whether signing with this saved identity asks for Touch ID: keys created by 0.10.0 builds were bound to
    /// biometrics in the Secure Enclave, and that cannot be changed afterwards. Checking shows no prompt.
    public static func needsTouchID(_ fileContents: Data) -> Bool {
        let text = String(decoding: fileContents, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, text.hasPrefix(prefix),
              let blob = Data(base64Encoded: String(text.dropFirst(prefix.count))), !blob.isEmpty else { return false }
        let context = LAContext()
        context.interactionNotAllowed = true
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context) else {
            return false
        }
        return (try? key.signature(for: Data("MShell key check".utf8))) == nil
    }

    static func load(_ text: String) throws -> (NIOSSHPrivateKey, String) {
        guard let blob = Data(base64Encoded: String(text.dropFirst(prefix.count))), !blob.isEmpty else { throw SSHKeyFileError.invalid }
        guard isAvailable else { throw SSHKeyFileError.unsupported("This Mac has no Secure Enclave.") }
        let key = try session.key(blob)
        let identity = SecureEnclaveSigner(key: key)
        return (NIOSSHPrivateKey(custom: identity), identity.publicKeyLine)
    }

    /// One authentication context for the app launch. NIOSSH signs synchronously on the connection's event loop, so
    /// signing never shows UI there: the context forbids interaction, and any Touch ID an older key needs is asked
    /// for here, while the key loads in a background task before the handshake.
    private static let session = EnclaveSession()

    private final class EnclaveSession: @unchecked Sendable {
        private let lock = NSLock()
        private let context: LAContext = {
            let context = LAContext()
            context.interactionNotAllowed = true
            return context
        }()

        func key(_ blob: Data) throws -> SecureEnclave.P256.Signing.PrivateKey {
            lock.lock()
            defer { lock.unlock() }
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            if (try? key.signature(for: Data("MShell key check".utf8))) != nil { return key }
            try authenticate()
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        }

        /// Asks for Touch ID once; the context stays authenticated for the rest of the launch.
        private func authenticate() throws {
            context.interactionNotAllowed = false
            defer { context.interactionNotAllowed = true }
            let done = DispatchSemaphore(value: 0)
            let result = LockedResult()
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "use your Secure Enclave SSH key") { success, error in
                result.set(success ? nil : (error ?? SSHKeyFileError.cannotUnlock))
                done.signal()
            }
            done.wait()
            guard let error = result.get() else { return }
            if let error = error as? LAError, [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                throw SSHKeyFileError.unsupported("Touch ID was cancelled. Connect again to use the Secure Enclave key.")
            }
            throw SSHKeyFileError.unsupported("Touch ID did not confirm the Secure Enclave key.")
        }
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ value: Error?) { lock.lock(); error = value; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}

private struct SecureEnclaveSigner: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = AgentP256.name
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKey: NIOSSHPublicKeyProtocol { SSHAgentPublicKey<AgentP256>(body: publicKeyBody) }

    private var publicKeyBody: [UInt8] {
        var writer = SSHWireWriter()
        writer.string("nistp256")
        writer.string(Array(key.publicKey.x963Representation))
        return writer.bytes
    }

    var publicKeyLine: String {
        var writer = SSHWireWriter()
        writer.string(Self.keyPrefix)
        return Self.keyPrefix + " " + Data(writer.bytes + publicKeyBody).base64EncodedString()
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try key.signature(for: data).rawRepresentation
        var factors = SSHWireWriter()
        factors.mpint(Array(signature.prefix(32)))
        factors.mpint(Array(signature.suffix(32)))
        var blob = SSHWireWriter()
        blob.string(factors.bytes)
        return SSHAgentSignature<AgentP256>(body: blob.bytes)
    }
}
