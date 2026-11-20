import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

public enum SSHKeyFileError: LocalizedError {
    case invalid
    case passphraseRequired
    case cannotUnlock

    public var errorDescription: String? {
        switch self {
        case .invalid: return "Choose an OpenSSH Ed25519 private key."
        case .passphraseRequired: return "Enter the private key passphrase."
        case .cannotUnlock: return "The private key could not be unlocked. Check its passphrase and format."
        }
    }
}

extension SSHCredential {
    /// Reads a single OpenSSH Ed25519 identity. The passphrase is used only for this load.
    public static func openSSHEd25519(at url: URL, passphrase: String) throws -> Self {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SSHKeyFileError.invalid
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else { throw SSHKeyFileError.invalid }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 3, lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let payload = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else { throw SSHKeyFileError.invalid }

        var envelope = ByteBuffer(bytes: payload)
        func field(_ input: inout ByteBuffer) -> ByteBuffer? {
            guard let size: UInt32 = input.readInteger() else { return nil }
            return input.readSlice(length: Int(size))
        }
        guard envelope.readString(length: 15) == "openssh-key-v1\0",
              let cipher = field(&envelope).map({ String(buffer: $0) }),
              let kdf = field(&envelope).map({ String(buffer: $0) }),
              var parameters = field(&envelope), envelope.readInteger(as: UInt32.self) == 1,
              var publicKey = field(&envelope),
              field(&publicKey).map({ String(buffer: $0) }) == "ssh-ed25519",
              field(&publicKey)?.readableBytes == 32, publicKey.readableBytes == 0,
              let privateKey = field(&envelope), privateKey.readableBytes >= 8, envelope.readableBytes == 0 else {
            throw SSHKeyFileError.invalid
        }

        let encrypted = cipher != "none"
        if encrypted {
            guard ["aes128-ctr", "aes256-ctr"].contains(cipher), kdf == "bcrypt",
                  let salt = field(&parameters), (1...64).contains(salt.readableBytes),
                  let rounds = parameters.readInteger(as: UInt32.self), (1..<32).contains(rounds),
                  parameters.readableBytes == 0 else { throw SSHKeyFileError.invalid }
            guard !passphrase.isEmpty else { throw SSHKeyFileError.passphraseRequired }
        } else {
            guard kdf == "none", parameters.readableBytes == 0 else { throw SSHKeyFileError.invalid }
        }

        do {
            let normalized = lines.joined(separator: "\n")
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: normalized, decryptionKey: encrypted ? Data(passphrase.utf8) : nil
            )
            return .privateKey(NIOSSHPrivateKey(ed25519Key: key))
        } catch {
            throw encrypted ? SSHKeyFileError.cannotUnlock : SSHKeyFileError.invalid
        }
    }
}
