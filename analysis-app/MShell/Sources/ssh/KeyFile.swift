import CCitadelBcrypt
import CommonCrypto
import Crypto
import _CryptoExtras
import Foundation
import NIOCore
import NIOSSH

private extension ArraySlice where Element == UInt8 {
    func windows(_ size: Int) -> [[UInt8]] {
        guard count >= size else { return [] }
        return (startIndex...(endIndex - size)).map { Array(self[$0..<$0 + size]) }
    }
}

public enum SSHKeyFileError: LocalizedError, Equatable {
    case invalid
    case passphraseRequired
    case cannotUnlock
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalid: return "Choose an OpenSSH, PEM, or PuTTY private key."
        case .passphraseRequired: return "Enter the private key passphrase."
        case .cannotUnlock: return "The private key could not be unlocked. Check its passphrase and format."
        case .unsupported(let detail): return detail
        }
    }
}

/// The key types MShell can sign with, for display.
public enum SSHKeyKind: String, Sendable {
    case ed25519 = "Ed25519", ecdsaP256 = "ECDSA P-256", ecdsaP384 = "ECDSA P-384", ecdsaP521 = "ECDSA P-521", rsa = "RSA"
}

extension SSHCredential {
    /// Reads one private key file. The passphrase is used only for this load.
    /// Supports OpenSSH (`BEGIN OPENSSH PRIVATE KEY`), PEM (PKCS#1, SEC1, PKCS#8), and PuTTY `.ppk` v2/v3 files
    /// with Ed25519, ECDSA P-256/384/521, or RSA keys.
    public static func privateKeyFile(at url: URL, passphrase: String) throws -> Self {
        .privateKey(try SSHPrivateKeyFile.load(at: url, passphrase: passphrase).key)
    }

    /// Kept for callers written before more key types were supported.
    public static func openSSHEd25519(at url: URL, passphrase: String) throws -> Self {
        try privateKeyFile(at: url, passphrase: passphrase)
    }
}

public struct SSHPrivateKeyFile {
    public let key: NIOSSHPrivateKey
    public let kind: SSHKeyKind
    /// The OpenSSH public key line, without a comment.
    public let publicKeyLine: String

    public static func load(at url: URL, passphrase: String) throws -> SSHPrivateKeyFile {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SSHKeyFileError.invalid
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else { throw SSHKeyFileError.invalid }
        return try parse(text, passphrase: passphrase)
    }

    /// Whether the file needs a passphrase to load. False for unencrypted keys and for Secure Enclave identities,
    /// which are recognised without touching the enclave; true when unsure, so the passphrase field stays available.
    public static func needsPassphrase(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 65_537), bytes.count <= 65_536,
              let text = String(data: bytes, encoding: .utf8) else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(SecureEnclaveSSHIdentity.prefix) { return false }
        do { _ = try parse(trimmed, passphrase: ""); return false } catch { return true }
    }

    public static func parse(_ text: String, passphrase: String) throws -> SSHPrivateKeyFile {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(SecureEnclaveSSHIdentity.prefix) {
            let (key, publicKey) = try SecureEnclaveSSHIdentity.load(trimmed)
            return SSHPrivateKeyFile(key: key, kind: .ecdsaP256, publicKeyLine: publicKey)
        }
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") { return try OpenSSHKeyFormat.parse(trimmed, passphrase: passphrase) }
        if trimmed.hasPrefix("PuTTY-User-Key-File-") { return try PuTTYKeyFormat.parse(trimmed, passphrase: passphrase) }
        if trimmed.hasPrefix("-----BEGIN ") { return try PEMKeyFormat.parse(trimmed) }
        throw SSHKeyFileError.invalid
    }

    private init(key: NIOSSHPrivateKey, kind: SSHKeyKind, publicKeyLine: String) {
        self.key = key
        self.kind = kind
        self.publicKeyLine = publicKeyLine
    }

    init(_ material: KeyMaterial) throws {
        switch material {
        case .ed25519(let key):
            self.key = NIOSSHPrivateKey(ed25519Key: key); kind = .ed25519
        case .p256(let key):
            self.key = NIOSSHPrivateKey(p256Key: key); kind = .ecdsaP256
        case .p384(let key):
            self.key = NIOSSHPrivateKey(p384Key: key); kind = .ecdsaP384
        case .p521(let key):
            self.key = NIOSSHPrivateKey(p521Key: key); kind = .ecdsaP521
        case .rsa(let key):
            guard key.keySizeInBits >= 2048 else { throw SSHKeyFileError.unsupported("RSA keys must be at least 2048 bits.") }
            self.key = NIOSSHPrivateKey(custom: try SSHRSAPrivateKey(key)); kind = .rsa
        }
        publicKeyLine = try material.publicKeyLine()
    }
}

enum KeyMaterial {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
    case rsa(_RSA.Signing.PrivateKey)

    /// The public key in the standard `ssh-rsa`/`ecdsa-…`/`ssh-ed25519` wire form.
    func publicBlob() throws -> [UInt8] {
        var out = SSHWireWriter()
        switch self {
        case .ed25519(let key):
            out.string("ssh-ed25519"); out.string(Array(key.publicKey.rawRepresentation))
        case .p256(let key):
            out.string("ecdsa-sha2-nistp256"); out.string("nistp256"); out.string(Array(key.publicKey.x963Representation))
        case .p384(let key):
            out.string("ecdsa-sha2-nistp384"); out.string("nistp384"); out.string(Array(key.publicKey.x963Representation))
        case .p521(let key):
            out.string("ecdsa-sha2-nistp521"); out.string("nistp521"); out.string(Array(key.publicKey.x963Representation))
        case .rsa(let key):
            let primitives = try key.publicKey.getKeyPrimitives()
            out.string("ssh-rsa"); out.mpint(Array(primitives.publicExponent)); out.mpint(Array(primitives.modulus))
        }
        return out.bytes
    }

    func publicKeyLine() throws -> String {
        let blob = try publicBlob()
        var reader = SSHWireReader(blob)
        return try reader.text() + " " + Data(blob).base64EncodedString()
    }
}

// MARK: - RSA with SHA-2 signatures (RFC 8332)

/// RSA keys sign with `rsa-sha2-512`; servers that follow OpenSSH 8.8+ refuse SHA-1 `ssh-rsa` signatures.
struct SSHRSAPrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-512"
    let key: _RSA.Signing.PrivateKey
    let rsaPublicKey: SSHRSAPublicKey
    var publicKey: NIOSSHPublicKeyProtocol { rsaPublicKey }

    init(_ key: _RSA.Signing.PrivateKey) throws {
        self.key = key
        let primitives = try key.publicKey.getKeyPrimitives()
        rsaPublicKey = SSHRSAPublicKey(e: Array(primitives.publicExponent), n: Array(primitives.modulus))
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let signature = try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
        return SSHRSASignature(rawRepresentation: signature.rawRepresentation)
    }
}

struct SSHRSAPublicKey: NIOSSHPublicKeyProtocol {
    // The algorithm name doubles as the key blob type here. OpenSSH maps `rsa-sha2-512` to its RSA key type,
    // and the signed payload uses the same blob, so verification matches.
    static let publicKeyPrefix = "rsa-sha2-512"
    let e: [UInt8], n: [UInt8]
    var rawRepresentation: Data { Data(e + n) }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? SSHRSASignature,
              let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { return false }
        return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature.rawRepresentation),
                                    for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var out = SSHWireWriter(); out.mpint(e); out.mpint(n)
        return buffer.writeBytes(out.bytes)
    }

    static func read(from buffer: inout ByteBuffer) throws -> SSHRSAPublicKey {
        var reader = SSHWireReader(buffer.readBytes(length: buffer.readableBytes) ?? [])
        return SSHRSAPublicKey(e: try reader.mpint(), n: try reader.mpint())
    }
}

struct SSHRSASignature: NIOSSHSignatureProtocol {
    static let signaturePrefix = "rsa-sha2-512"
    let rawRepresentation: Data
    func write(to buffer: inout ByteBuffer) -> Int {
        var out = SSHWireWriter(); out.string(Array(rawRepresentation))
        return buffer.writeBytes(out.bytes)
    }
    static func read(from buffer: inout ByteBuffer) throws -> SSHRSASignature {
        var reader = SSHWireReader(buffer.readBytes(length: buffer.readableBytes) ?? [])
        return SSHRSASignature(rawRepresentation: Data(try reader.string()))
    }
}

// MARK: - SSH wire format

struct SSHWireReader {
    private var bytes: [UInt8]
    private var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - offset }
    var rest: [UInt8] { Array(bytes[offset...]) }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHKeyFileError.invalid }
        defer { offset += 4 }
        return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw SSHKeyFileError.invalid }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
    mutating func string() throws -> [UInt8] {
        let length = Int(try uint32())
        guard length <= 1 << 20 else { throw SSHKeyFileError.invalid }
        return try take(length)
    }
    mutating func text() throws -> String {
        guard let text = String(bytes: try string(), encoding: .utf8) else { throw SSHKeyFileError.invalid }
        return text
    }
    /// An unsigned big-endian integer with the sign byte removed.
    mutating func mpint() throws -> [UInt8] { Array(try string().drop { $0 == 0 }) }
}

struct SSHWireWriter {
    var bytes: [UInt8] = []
    mutating func uint32(_ value: UInt32) { bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
    mutating func string(_ value: [UInt8]) { uint32(UInt32(value.count)); bytes += value }
    mutating func string(_ value: String) { string(Array(value.utf8)) }
    mutating func mpint(_ value: [UInt8]) {
        var trimmed = Array(value.drop { $0 == 0 })
        if let first = trimmed.first, first & 0x80 != 0 { trimmed.insert(0, at: 0) }
        string(trimmed)
    }
}

/// Builds key material from the private fields that follow a key type name.
private func readKeyMaterial(type: String, publicKey: [UInt8]?, from reader: inout SSHWireReader, rsaOrder: RSAFieldOrder) throws -> KeyMaterial {
    switch type {
    case "ssh-ed25519":
        switch rsaOrder {
        case .openSSH:
            let pub = try reader.string()
            let secret = try reader.string()
            guard pub.count == 32, secret.count == 64, Array(secret[32...]) == pub else { throw SSHKeyFileError.invalid }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret[..<32]))
        case .putty:
            let secret = try reader.string()
            guard secret.count == 32 else { throw SSHKeyFileError.invalid }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        }
    case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
        if rsaOrder == .openSSH { _ = try reader.string(); _ = try reader.string() }
        let scalar = try reader.mpint()
        func padded(_ size: Int) throws -> [UInt8] {
            guard scalar.count <= size else { throw SSHKeyFileError.invalid }
            return [UInt8](repeating: 0, count: size - scalar.count) + scalar
        }
        switch type {
        case "ecdsa-sha2-nistp256": return .p256(try P256.Signing.PrivateKey(rawRepresentation: padded(32)))
        case "ecdsa-sha2-nistp384": return .p384(try P384.Signing.PrivateKey(rawRepresentation: padded(48)))
        default: return .p521(try P521.Signing.PrivateKey(rawRepresentation: padded(66)))
        }
    case "ssh-rsa":
        let n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8]
        switch rsaOrder {
        case .openSSH:
            n = try reader.mpint(); e = try reader.mpint(); d = try reader.mpint()
            _ = try reader.mpint(); p = try reader.mpint(); q = try reader.mpint()
        case .putty:
            guard let publicKey else { throw SSHKeyFileError.invalid }
            var pub = SSHWireReader(publicKey)
            _ = try pub.string(); e = try pub.mpint(); n = try pub.mpint()
            d = try reader.mpint(); p = try reader.mpint(); q = try reader.mpint(); _ = try reader.mpint()
        }
        do { return .rsa(try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q)) }
        catch { throw SSHKeyFileError.invalid }
    case let other where other.hasPrefix("sk-"):
        throw SSHKeyFileError.unsupported("Security key (FIDO) SSH keys are not supported yet.")
    case let other where other.hasPrefix("ssh-dss"):
        throw SSHKeyFileError.unsupported("DSA keys are not supported. Use an Ed25519, ECDSA, or RSA key.")
    default:
        throw SSHKeyFileError.unsupported("This key type is not supported: \(type)")
    }
}

private enum RSAFieldOrder { case openSSH, putty }

// MARK: - OpenSSH

enum OpenSSHKeyFormat {
    static func parse(_ text: String, passphrase: String) throws -> SSHPrivateKeyFile {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let payload = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else { throw SSHKeyFileError.invalid }
        var envelope = SSHWireReader(Array(payload))
        guard try envelope.take(15) == Array("openssh-key-v1\0".utf8) else { throw SSHKeyFileError.invalid }
        let cipher = try envelope.text(), kdf = try envelope.text()
        var options = SSHWireReader(try envelope.string())
        guard try envelope.uint32() == 1 else { throw SSHKeyFileError.unsupported("Files with more than one key are not supported.") }
        _ = try envelope.string()
        var secret = try envelope.string()

        if cipher != "none" {
            guard kdf == "bcrypt" else { throw SSHKeyFileError.invalid }
            guard let spec = AESSpec(openSSH: cipher) else {
                throw SSHKeyFileError.unsupported("This key uses the \(cipher) cipher. Re-encrypt it with `ssh-keygen -p -Z aes256-ctr`.")
            }
            guard !passphrase.isEmpty else { throw SSHKeyFileError.passphraseRequired }
            let salt = try options.string(), rounds = try options.uint32()
            guard (1...64).contains(salt.count), (1...1 << 16).contains(rounds) else { throw SSHKeyFileError.invalid }
            let material = try BCryptKDF.derive(passphrase: passphrase, salt: salt, rounds: rounds, length: spec.keyLength + 16)
            secret = try spec.decrypt(secret, key: Array(material[..<spec.keyLength]), iv: Array(material[spec.keyLength...]))
        } else {
            guard kdf == "none" else { throw SSHKeyFileError.invalid }
        }

        var reader = SSHWireReader(secret)
        let check1 = try reader.uint32(), check2 = try reader.uint32()
        guard check1 == check2 else { throw cipher == "none" ? SSHKeyFileError.invalid : SSHKeyFileError.cannotUnlock }
        let type = try reader.text()
        return try SSHPrivateKeyFile(readKeyMaterial(type: type, publicKey: nil, from: &reader, rsaOrder: .openSSH))
    }
}

/// bcrypt_pbkdf as used by OpenSSH, from Citadel's bundled C implementation.
enum BCryptKDF {
    private static let ready: Bool = {
        citadel_set_crypto_hash_sha512 { output, input, length in
            _ = CC_SHA512(input, CC_LONG(length), output)
        }
        return true
    }()

    static func derive(passphrase: String, salt: [UInt8], rounds: UInt32, length: Int) throws -> [UInt8] {
        _ = ready
        let password = Array(passphrase.utf8)
        var output = [UInt8](repeating: 0, count: length)
        let status = citadel_bcrypt_pbkdf(password, password.count, salt, salt.count, &output, length, rounds)
        guard status == 0 else { throw SSHKeyFileError.cannotUnlock }
        return output
    }
}

struct AESSpec {
    let keyLength: Int
    let mode: CCMode

    init?(openSSH name: String) {
        switch name {
        case "aes128-ctr": keyLength = 16; mode = CCMode(kCCModeCTR)
        case "aes192-ctr": keyLength = 24; mode = CCMode(kCCModeCTR)
        case "aes256-ctr": keyLength = 32; mode = CCMode(kCCModeCTR)
        case "aes128-cbc": keyLength = 16; mode = CCMode(kCCModeCBC)
        case "aes192-cbc": keyLength = 24; mode = CCMode(kCCModeCBC)
        case "aes256-cbc": keyLength = 32; mode = CCMode(kCCModeCBC)
        default: return nil
        }
    }
    init(keyLength: Int, mode: CCMode) { self.keyLength = keyLength; self.mode = mode }

    func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard data.count % 16 == 0 || mode == CCMode(kCCModeCTR) else { throw SSHKeyFileError.invalid }
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                              iv, key, key.count, nil, 0, 0,
                                              mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0, &cryptor)
        guard created == kCCSuccess, let cryptor else { throw SSHKeyFileError.cannotUnlock }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, data, data.count, &output, output.count, &moved) == kCCSuccess, moved == data.count else {
            throw SSHKeyFileError.cannotUnlock
        }
        return output
    }
}

// MARK: - PuTTY

enum PuTTYKeyFormat {
    static func parse(_ text: String, passphrase: String) throws -> SSHPrivateKeyFile {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var index = 0
        var headers: [String: String] = [:]
        var publicLines: [String] = [], privateLines: [String] = []
        func block(count: String?) throws -> [String] {
            guard let count, let number = Int(count), (0...4096).contains(number), index + number <= lines.count else { throw SSHKeyFileError.invalid }
            defer { index += number }
            return Array(lines[index..<index + number])
        }
        while index < lines.count {
            let line = lines[index]; index += 1
            guard let colon = line.firstIndex(of: ":") else { throw SSHKeyFileError.invalid }
            let name = String(line[..<colon]), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "Public-Lines" { publicLines = try block(count: value) }
            if name == "Private-Lines" { privateLines = try block(count: value) }
        }
        let version: Int
        if let type = headers["PuTTY-User-Key-File-2"] { version = 2; headers["type"] = type }
        else if let type = headers["PuTTY-User-Key-File-3"] { version = 3; headers["type"] = type }
        else { throw SSHKeyFileError.unsupported("Only PuTTY key files of format 2 or 3 are supported.") }
        guard let type = headers["type"], let encryption = headers["Encryption"],
              let publicBlob = Data(base64Encoded: publicLines.joined()), var privateBlob = Data(base64Encoded: privateLines.joined()).map(Array.init),
              let macHex = headers["Private-MAC"], let mac = hexBytes(macHex) else { throw SSHKeyFileError.invalid }
        let comment = headers["Comment"] ?? ""

        let macKey: [UInt8]
        switch (version, encryption) {
        case (_, "none"):
            macKey = version == 2 ? sha1(Array("putty-private-key-file-mac-key".utf8)) : []
        case (2, "aes256-cbc"):
            guard !passphrase.isEmpty else { throw SSHKeyFileError.passphraseRequired }
            let pass = Array(passphrase.utf8)
            let key = Array((sha1([0, 0, 0, 0] + pass) + sha1([0, 0, 0, 1] + pass)).prefix(32))
            privateBlob = try AESSpec(keyLength: 32, mode: CCMode(kCCModeCBC)).decrypt(privateBlob, key: key, iv: [UInt8](repeating: 0, count: 16))
            macKey = sha1(Array("putty-private-key-file-mac-key".utf8) + pass)
        case (3, _):
            throw SSHKeyFileError.unsupported("Encrypted PuTTY v3 keys use Argon2. Export the key from PuTTYgen as an OpenSSH key, or save it with format 2.")
        default:
            throw SSHKeyFileError.unsupported("This PuTTY key encryption is not supported: \(encryption)")
        }

        var signed = SSHWireWriter()
        signed.string(type); signed.string(encryption); signed.string(comment)
        signed.string(Array(publicBlob)); signed.string(privateBlob)
        let expected = version == 2 ? hmacSHA1(key: macKey, data: signed.bytes) : hmacSHA256(key: macKey, data: signed.bytes)
        guard expected == mac else { throw encryption == "none" ? SSHKeyFileError.invalid : SSHKeyFileError.cannotUnlock }

        var reader = SSHWireReader(privateBlob)
        let material = try readKeyMaterial(type: type, publicKey: Array(publicBlob), from: &reader, rsaOrder: .putty)
        guard try material.publicBlob() == Array(publicBlob) else { throw SSHKeyFileError.invalid }
        return try SSHPrivateKeyFile(material)
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let chars = Array(text)
        guard chars.count % 2 == 0 else { return nil }
        return stride(from: 0, to: chars.count, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) }.count == chars.count / 2
            ? stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! } : nil
    }
    private static func sha1(_ data: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }
    private static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    private static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

// MARK: - PEM

enum PEMKeyFormat {
    static func parse(_ text: String) throws -> SSHPrivateKeyFile {
        if text.contains("ENCRYPTED") {
            throw SSHKeyFileError.unsupported("Encrypted PEM keys are not supported. Convert the key with `ssh-keygen -p -f KEY` to the OpenSSH format.")
        }
        if text.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            return try SSHPrivateKeyFile(.rsa(rsa(text)))
        }
        if text.hasPrefix("-----BEGIN EC PRIVATE KEY-----"), let key = try sec1(text) { return try SSHPrivateKeyFile(key) }
        if text.hasPrefix("-----BEGIN EC PRIVATE KEY-----") || text.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return try SSHPrivateKeyFile(.p256(key)) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return try SSHPrivateKeyFile(.p384(key)) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return try SSHPrivateKeyFile(.p521(key)) }
            if let key = ed25519PKCS8(text) { return try SSHPrivateKeyFile(.ed25519(key)) }
            if text.hasPrefix("-----BEGIN PRIVATE KEY-----") { return try SSHPrivateKeyFile(.rsa(rsa(text))) }
        }
        throw SSHKeyFileError.invalid
    }

    private static func rsa(_ text: String) throws -> _RSA.Signing.PrivateKey {
        do { return try _RSA.Signing.PrivateKey(pemRepresentation: text) } catch { throw SSHKeyFileError.invalid }
    }

    /// SEC1 `EC PRIVATE KEY`: SEQUENCE { INTEGER 1, OCTET STRING d, [0] curve OID, [1] public key }.
    /// Read directly, because OpenSSL-written files trip the stricter CryptoKit parser.
    private static func sec1(_ text: String) throws -> KeyMaterial? {
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") && !$0.contains(":") }.joined()
        guard let der = Data(base64Encoded: body).map(Array.init) else { throw SSHKeyFileError.invalid }
        var index = 0
        func length() -> Int? {
            guard index < der.count else { return nil }
            let first = Int(der[index]); index += 1
            if first < 0x80 { return first }
            let count = first & 0x7f
            guard count <= 2, index + count <= der.count else { return nil }
            defer { index += count }
            return der[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
        }
        guard der.first == 0x30 else { return nil }
        index = 1
        guard length() != nil, index + 3 <= der.count, Array(der[index..<index + 3]) == [0x02, 0x01, 0x01] else { return nil }
        index += 3
        guard index < der.count, der[index] == 0x04 else { return nil }
        index += 1
        guard let size = length(), index + size <= der.count else { return nil }
        let scalar = Array(der[index..<index + size])
        let rest = der[(index + size)...]
        func contains(_ oid: [UInt8]) -> Bool { rest.windows(oid.count).contains(oid) }
        func padded(_ width: Int) throws -> [UInt8] {
            guard scalar.count <= width else { throw SSHKeyFileError.invalid }
            return [UInt8](repeating: 0, count: width - scalar.count) + scalar
        }
        if contains([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]) { return .p256(try P256.Signing.PrivateKey(rawRepresentation: padded(32))) }
        if contains([0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22]) { return .p384(try P384.Signing.PrivateKey(rawRepresentation: padded(48))) }
        if contains([0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23]) { return .p521(try P521.Signing.PrivateKey(rawRepresentation: padded(66))) }
        // Explicit curve parameters (as ssh-keygen writes them): the scalar has the curve's width,
        // and the embedded public key must match the one derived from it.
        let material: KeyMaterial
        let derived: [UInt8]
        switch scalar.count {
        case 32: let key = try P256.Signing.PrivateKey(rawRepresentation: scalar); material = .p256(key); derived = Array(key.publicKey.x963Representation)
        case 48: let key = try P384.Signing.PrivateKey(rawRepresentation: scalar); material = .p384(key); derived = Array(key.publicKey.x963Representation)
        case 66: let key = try P521.Signing.PrivateKey(rawRepresentation: scalar); material = .p521(key); derived = Array(key.publicKey.x963Representation)
        default: return nil
        }
        return contains(derived) ? material : nil
    }

    /// PKCS#8 Ed25519 keys have a fixed 48-byte DER layout ending in the 32-byte seed.
    private static func ed25519PKCS8(_ text: String) -> Curve25519.Signing.PrivateKey? {
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body).map(Array.init), der.count == 48,
              Array(der[..<16]) == [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20] else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: der[16...])
    }
}
