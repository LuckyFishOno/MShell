import XCTest
import Crypto
import _CryptoExtras
import NIOSSH
@testable import Ssh

/// Signs in to a loopback OpenSSH server with each supported key format.
final class KeyFormatTests: XCTestCase {
    private var server: LocalSSHD!

    override func setUpWithError() throws {
        try XCTSkipUnless(LocalSSHD.available, "OpenSSH is not installed")
        server = try LocalSSHD()
    }
    override func tearDown() { server?.stop() }

    private func signIn(with key: URL, passphrase: String = "") async throws -> String {
        let credential = try SSHCredential.privateKeyFile(at: key, passphrase: passphrase)
        let session = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: server.port, username: server.user),
                                                   credential: credential, connectTimeoutSeconds: 15)
        defer { Task { try? await session.close() } }
        return try await session.runCommand("echo signed-in").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testOpenSSHKeysOfEveryTypeSignIn() async throws {
        for (name, type, bits) in [("ed", "ed25519", nil), ("p256", "ecdsa", 256), ("p384", "ecdsa", 384), ("p521", "ecdsa", 521), ("rsa", "rsa", 3072)] as [(String, String, Int?)] {
            let key = try server.addKey(name, type: type, bits: bits)
            let output = try await signIn(with: key)
            XCTAssertEqual(output, "signed-in", name)
        }
    }

    func testEncryptedOpenSSHKeysNeedTheirPassphrase() async throws {
        let key = try server.addKey("rsa-locked", type: "rsa", bits: 2048, passphrase: "correct horse")
        XCTAssertThrowsError(try SSHPrivateKeyFile.load(at: key, passphrase: "")) { XCTAssertEqual($0 as? SSHKeyFileError, .passphraseRequired) }
        XCTAssertThrowsError(try SSHPrivateKeyFile.load(at: key, passphrase: "wrong")) { XCTAssertEqual($0 as? SSHKeyFileError, .cannotUnlock) }
        let output = try await signIn(with: key, passphrase: "correct horse")
        XCTAssertEqual(output, "signed-in")
        let ecdsa = try server.addKey("p256-locked", type: "ecdsa", bits: 256, passphrase: "pw")
        let ecdsaOutput = try await signIn(with: ecdsa, passphrase: "pw")
        XCTAssertEqual(ecdsaOutput, "signed-in")
    }

    func testPEMAndPKCS8KeysSignIn() async throws {
        for (name, type, bits, format) in [("rsa-pem", "rsa", 2048, "PEM"), ("ec-pem", "ecdsa", 256, "PEM"), ("rsa-pkcs8", "rsa", 2048, "PKCS8"), ("ec-pkcs8", "ecdsa", 384, "PKCS8")] {
            let key = try server.addKey(name, type: type, bits: bits, format: format)
            let output = try await signIn(with: key)
            XCTAssertEqual(output, "signed-in", name)
        }
    }

    func testPublicKeyLineMatchesSSHKeygen() throws {
        for (name, type, bits) in [("ed", "ed25519", 256), ("p521", "ecdsa", 521), ("rsa", "rsa", 2048)] {
            let key = try server.addKey(name, type: type, bits: bits)
            let expected = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
            XCTAssertEqual(try SSHPrivateKeyFile.load(at: key, passphrase: "").publicKeyLine, expected, name)
        }
    }

    func testPuTTYKeysSignIn() async throws {
        for (name, type, bits) in [("ed", "ed25519", 256), ("p256", "ecdsa", 256), ("rsa", "rsa", 2048)] {
            let key = try server.addKey(name, type: type, bits: bits)
            let openSSH = try String(contentsOf: key, encoding: .utf8)
            for (version, passphrase) in [(2, ""), (3, ""), (2, "putty pass")] {
                let ppk = try PPKWriter.write(openSSH: openSSH, version: version, passphrase: passphrase, comment: name)
                let url = key.appendingPathExtension("v\(version)\(passphrase.isEmpty ? "" : "e").ppk")
                try ppk.write(to: url, atomically: true, encoding: .utf8)
                let output = try await signIn(with: url, passphrase: passphrase)
                XCTAssertEqual(output, "signed-in", "\(name) v\(version)")
                if !passphrase.isEmpty {
                    XCTAssertThrowsError(try SSHPrivateKeyFile.load(at: url, passphrase: "nope")) { XCTAssertEqual($0 as? SSHKeyFileError, .cannotUnlock) }
                }
            }
        }
    }

    func testUnsupportedFilesExplainWhatToDo() throws {
        XCTAssertThrowsError(try SSHPrivateKeyFile.parse("hello", passphrase: "")) { XCTAssertEqual($0 as? SSHKeyFileError, .invalid) }
        XCTAssertThrowsError(try SSHPrivateKeyFile.parse("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----", passphrase: "")) {
            guard case .unsupported = $0 as? SSHKeyFileError else { return XCTFail("\($0)") }
        }
        let v3 = "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: aes256-cbc\nComment: x\nPublic-Lines: 1\nAAAA\nKey-Derivation: Argon2id\nPrivate-Lines: 1\nAAAA\nPrivate-MAC: 00"
        XCTAssertThrowsError(try SSHPrivateKeyFile.parse(v3, passphrase: "pw")) {
            guard case .unsupported = $0 as? SSHKeyFileError else { return XCTFail("\($0)") }
        }
    }
}

/// Writes PuTTY .ppk files from an unencrypted OpenSSH key, following the PuTTY format description.
enum PPKWriter {
    static func write(openSSH: String, version: Int, passphrase: String, comment: String) throws -> String {
        let file = try SSHPrivateKeyFile.parse(openSSH, passphrase: "")
        let parts = file.publicKeyLine.split(separator: " ")
        let type = String(parts[0])
        let publicBlob = Array(Data(base64Encoded: String(parts[1]))!)
        var priv = SSHWireWriter()
        let body = openSSH.split(whereSeparator: \.isNewline).dropFirst().dropLast().joined()
        var envelope = SSHWireReader(Array(Data(base64Encoded: body)!))
        _ = try envelope.take(15); _ = try envelope.string(); _ = try envelope.string(); _ = try envelope.string(); _ = try envelope.uint32(); _ = try envelope.string()
        var secret = SSHWireReader(try envelope.string())
        _ = try secret.uint32(); _ = try secret.uint32(); _ = try secret.text()
        switch type {
        case "ssh-ed25519":
            _ = try secret.string(); let both = try secret.string(); priv.string(Array(both[..<32]))
        case let t where t.hasPrefix("ecdsa"):
            _ = try secret.string(); _ = try secret.string(); priv.mpint(try secret.mpint())
        default:
            _ = try secret.mpint(); _ = try secret.mpint(); let d = try secret.mpint(), iqmp = try secret.mpint(), p = try secret.mpint(), q = try secret.mpint()
            priv.mpint(d); priv.mpint(p); priv.mpint(q); priv.mpint(iqmp)
        }
        var privateBlob = priv.bytes
        let encryption = passphrase.isEmpty ? "none" : "aes256-cbc"
        if !passphrase.isEmpty {
            let padding = (16 - privateBlob.count % 16) % 16
            privateBlob += Array(Insecure.SHA1.hash(data: privateBlob)).prefix(padding)
        }
        var signed = SSHWireWriter()
        signed.string(type); signed.string(encryption); signed.string(comment); signed.string(publicBlob); signed.string(privateBlob)
        let pass = Array(passphrase.utf8)
        let mac: [UInt8]
        if version == 2 {
            let key = Array(Insecure.SHA1.hash(data: Array("putty-private-key-file-mac-key".utf8) + pass))
            mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: signed.bytes, using: SymmetricKey(data: key)))
        } else {
            mac = Array(HMAC<SHA256>.authenticationCode(for: signed.bytes, using: SymmetricKey(data: [UInt8]())))
        }
        if !passphrase.isEmpty {
            let key = Array((Array(Insecure.SHA1.hash(data: [0, 0, 0, 0] + pass)) + Array(Insecure.SHA1.hash(data: [0, 0, 0, 1] + pass))).prefix(32))
            privateBlob = try encrypt(privateBlob, key: key)
        }
        func lines(_ bytes: [UInt8]) -> [String] {
            let text = Data(bytes).base64EncodedString()
            return stride(from: 0, to: text.count, by: 64).map { String(Array(text)[$0..<min($0 + 64, text.count)]) }
        }
        let pubLines = lines(publicBlob), privLines = lines(privateBlob)
        return (["PuTTY-User-Key-File-\(version): \(type)", "Encryption: \(encryption)", "Comment: \(comment)", "Public-Lines: \(pubLines.count)"]
                + pubLines + ["Private-Lines: \(privLines.count)"] + privLines
                + ["Private-MAC: " + mac.map { String(format: "%02x", $0) }.joined()]).joined(separator: "\n") + "\n"
    }

    private static func encrypt(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        let sealed = try AES._CBC.encrypt(data, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)), noPadding: true)
        return Array(sealed)
    }
}
