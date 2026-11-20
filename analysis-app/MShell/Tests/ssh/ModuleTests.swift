import XCTest
import CarveShared
import Profiles
@testable import Ssh

final class SshFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(SshFeature.id, "ssh"); XCTAssertEqual(SshFeature.contractSha256, "f4f5b310b7a353be72677b4a3cc4c4cb2bfc8aa5241441bfdc4e391f1571ad9e") }

    func profile(_ proto: String, host: String = "h", port: UInt16 = 22) throws -> SessionProfile {
        let ini = "[SessionInfo]\r\nHost=\(host)\r\nPort=\(port)\r\nProtocol=\(proto)\r\nUserName=bob\r\n"
        return try SessionProfile(data: Data([0xFF, 0xFE]) + ini.data(using: .utf16LittleEndian)!, name: "s")
    }

    func testSettingsFromSshProfile() throws {
        let s = try SSHConnectionSettings(profile: try profile("SSH", host: "example.com", port: 2200))
        XCTAssertEqual(s, SSHConnectionSettings(host: "example.com", port: 2200, username: "bob"))
    }

    func testSftpProfileIsAlsoAccepted() throws {
        XCTAssertNoThrow(try SSHConnectionSettings(profile: try profile("SFTP")))
    }

    func testNonSshProfileRejected() throws {
        XCTAssertThrowsError(try SSHConnectionSettings(profile: try profile("TELNET"))) {
            XCTAssertEqual($0 as? SSHError, .invalidSettings("session protocol is TELNET, not SSH/SFTP"))
        }
    }

    func testEmptyHostRejected() throws {
        XCTAssertThrowsError(try SSHConnectionSettings(profile: try profile("SSH", host: ""))) {
            XCTAssertEqual($0 as? SSHError, .invalidSettings("session has no host"))
        }
    }

    func testFeatureReadinessAndSettingsOp() throws {
        let ready = try SshFeature.run(FeatureRequest(payload: ""), dependencies: FeatureOutputs([:]))
        XCTAssertTrue(ready.payload.contains("\"ready\":true"))
        XCTAssertTrue(ready.payload.contains("socks5"))
        let r = try SshFeature.run(FeatureRequest(payload: #"{"op":"settings","host":"h2","port":2022,"user":"carol"}"#), dependencies: FeatureOutputs([:]))
        XCTAssertEqual(r.payload, #"{"host":"h2","port":2022,"user":"carol"}"#)
    }

    func testInvalidPortRejectedBeforeConnecting() async throws {
        do {
            _ = try await SSHSession.connect(settings: SSHConnectionSettings(host: "h", port: 70000, username: "u"), credential: .password("x"))
            XCTFail("expected failure")
        } catch let e as SSHError {
            guard case .invalidSettings = e else { return XCTFail("wrong error \(e)") }
        }
    }

    // Connecting to a closed port fails cleanly as connectFailed (no server to handshake with).
    func testConnectToClosedPortFailsCleanly() async throws {
        do {
            _ = try await SSHSession.connect(settings: SSHConnectionSettings(host: "127.0.0.1", port: 9, username: "u"),
                                             credential: .password("x"), hostKey: .acceptAny, connectTimeoutSeconds: 3)
            XCTFail("expected connect to fail")
        } catch let e as SSHError {
            switch e { case .connectFailed, .authenticationFailed: break; default: XCTFail("wrong error: \(e)") }
        }
    }
}

final class CTRPolicyTests: XCTestCase {
    func testCTRAdapterRejectsSHA1AndAcceptsSHA2() throws {
        XCTAssertThrowsError(try SHA2AES128CTR.keySizes(forMac: "hmac-sha1"))
        XCTAssertThrowsError(try SHA2AES128CTR.keySizes(forMac: nil))
        XCTAssertNoThrow(try SHA2AES128CTR.keySizes(forMac: "hmac-sha2-256"))
        XCTAssertNoThrow(try SHA2AES128CTR.keySizes(forMac: "hmac-sha2-512"))
    }
}
