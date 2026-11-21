import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Holds a device-bound copy of the vault key for this app launch. `enclaveKey` is the Secure Enclave's wrapped key
/// handle, usable only on this Mac after Touch ID with the currently enrolled fingers; the vault key is sealed under
/// an ECDH secret that needs it.
struct VaultTouchID: Sendable {
    private let enclaveKey: Data
    private let ephemeralPublicKey: Data
    private let sealedKey: Data
    private static let contextInfo = Data("MShell vault unlock".utf8)

    static var isAvailable: Bool {
        let context = LAContext()
        return SecureEnclave.isAvailable
            && context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && context.biometryType == .touchID
    }

    init(protecting key: Data) throws {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw WorkspaceError.invalid("Could not enable Touch ID for the password vault.")
        }
        let protectedKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeralKey.sharedSecretFromKeyAgreement(with: protectedKey.publicKey)
        enclaveKey = protectedKey.dataRepresentation
        ephemeralPublicKey = ephemeralKey.publicKey.x963Representation
        guard let combined = try AES.GCM.seal(key, using: Self.wrappingKey(from: shared)).combined else {
            throw WorkspaceError.invalid("Could not enable Touch ID for the password vault.")
        }
        sealedKey = combined
    }

    func readKey(reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclaveKey, authenticationContext: context)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: publicKey)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealedKey), using: Self.wrappingKey(from: shared))
    }

    private static func wrappingKey(from shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: contextInfo, outputByteCount: 32)
    }
}
