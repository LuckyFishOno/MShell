import NIOCore
import NIOSSH
import Citadel

/// Restricts the upstream AES-CTR adapter to SHA-2 MACs. Cryptographic operations
/// remain in Citadel/BoringSSL; this adapter contains no custom cryptography.
final class SHA2AES128CTR: NIOSSHTransportProtection {
    static let cipherName = AES128CTR.cipherName
    static let cipherBlockSize = AES128CTR.cipherBlockSize
    static let macNames = ["hmac-sha2-256", "hmac-sha2-512"]
    private let base: AES128CTR
    var macBytes: Int { base.macBytes }
    static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        guard let mac, macNames.contains(mac) else { throw SSHError.invalidSettings("Unsupported AES-CTR MAC.") }
        return try AES128CTR.keySizes(forMac: mac)
    }
    init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        _ = try Self.keySizes(forMac: mac)
        base = try AES128CTR(initialKeys: initialKeys, mac: mac)
    }
    func updateKeys(_ keys: NIOSSHSessionKeys) throws { try base.updateKeys(keys) }
    func decryptFirstBlock(_ source: inout ByteBuffer) throws { try base.decryptFirstBlock(&source) }
    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        try base.decryptAndVerifyRemainingPacket(&source, sequenceNumber: sequenceNumber)
    }
    func encryptPacket(_ packet: NIOSSHEncryptablePayload, to buffer: inout ByteBuffer, sequenceNumber: UInt32) throws {
        try base.encryptPacket(packet, to: &buffer, sequenceNumber: sequenceNumber)
    }
}
