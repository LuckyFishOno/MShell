import XCTest
import CarveShared
@testable import MasterPassword

final class MasterPasswordFeatureTests: XCTestCase {
    func testDeclaresPlannedInterface() { XCTAssertEqual(MasterPasswordFeature.id, "master-password"); XCTAssertEqual(MasterPasswordFeature.contractSha256, "32e908cfddce634f246928838ba4ca6831cd2a3b97e05d91ec1f68f79a551de2") }

    // Fewer iterations keep the test fast; production uses MasterVault.defaultIterations.
    let iters = 1000

    func testPasswordLengthRule() {
        XCTAssertThrowsError(try MasterVault.create(password: "12345", iterations: iters)) { XCTAssertEqual($0 as? VaultError, .passwordLength) }
        XCTAssertThrowsError(try MasterVault.create(password: String(repeating: "x", count: 51), iterations: iters)) { XCTAssertEqual($0 as? VaultError, .passwordLength) }
        XCTAssertNoThrow(try MasterVault.create(password: "123456", iterations: iters))
    }

    func testStoreRetrieveRoundTripThroughSerialization() throws {
        var v = try MasterVault.create(password: "correct horse", iterations: iters)
        v = try v.storing(id: "prod-ssh", secret: "hunter2")
        v = try v.storing(id: "db", secret: "p@ss word")
        let onDisk = try v.serialized()
        let reopened = try MasterVault.load(onDisk).unlocked(password: "correct horse")
        XCTAssertEqual(try reopened.retrieve(id: "prod-ssh"), "hunter2")
        XCTAssertEqual(try reopened.retrieve(id: "db"), "p@ss word")
        XCTAssertEqual(reopened.identifiers, ["db", "prod-ssh"])
    }

    func testProtectedUnlockKeyIsVerifiedAgainstTheVault() throws {
        let vault = try MasterVault.create(password: "fixture-password", iterations: 100)
            .storing(id: "example", secret: "fixture-secret")
        let key = try vault.vaultKeyForProtectedStorage()
        let locked = try MasterVault.load(vault.serialized())
        XCTAssertThrowsError(try locked.vaultKeyForProtectedStorage())
        XCTAssertThrowsError(try locked.unlocked(vaultKey: Data(repeating: 0, count: 32)))
        XCTAssertEqual(try locked.unlocked(vaultKey: key).retrieve(id: "example"), "fixture-secret")
    }

    func testWrongPasswordIsRejectedAndSecretsStayUnreadable() throws {
        let v = try (try MasterVault.create(password: "right-one", iterations: iters)).storing(id: "a", secret: "s")
        let data = try v.serialized()
        XCTAssertThrowsError(try MasterVault.load(data).unlocked(password: "wrong-one")) { XCTAssertEqual($0 as? VaultError, .wrongPassword) }
        XCTAssertThrowsError(try MasterVault.load(data).retrieve(id: "a")) { XCTAssertEqual($0 as? VaultError, .locked) }
    }

    func testCiphertextIsNotPlaintextAndSaltIsRandom() throws {
        let a = try MasterVault.create(password: "same-password", iterations: iters)
        let b = try MasterVault.create(password: "same-password", iterations: iters)
        XCTAssertNotEqual(try a.serialized(), try b.serialized(), "random salt per vault")
        let v = try a.storing(id: "x", secret: "TOPSECRET")
        XCTAssertFalse(String(decoding: try v.serialized(), as: UTF8.self).contains("TOPSECRET"))
    }

    func testChangePasswordReEncryptsEntries() throws {
        var v = try MasterVault.create(password: "old-password", iterations: iters)
        v = try v.storing(id: "a", secret: "value-a")
        let changed = try v.changingPassword(to: "new-password", iterations: iters)
        XCTAssertThrowsError(try MasterVault.load(try changed.serialized()).unlocked(password: "old-password"))
        let reopened = try MasterVault.load(try changed.serialized()).unlocked(password: "new-password")
        XCTAssertEqual(try reopened.retrieve(id: "a"), "value-a")
    }

    func testRemoveAndMissingEntry() throws {
        var v = try MasterVault.create(password: "abcdef", iterations: iters)
        v = try v.storing(id: "a", secret: "s")
        v = try v.removing(id: "a")
        XCTAssertEqual(v.identifiers, [])
        XCTAssertThrowsError(try v.retrieve(id: "a")) { XCTAssertEqual($0 as? VaultError, .notFound("a")) }
        XCTAssertTrue(MasterVault.removedVault().discardedSecrets)
    }

    func testCorruptVaultRejected() {
        XCTAssertThrowsError(try MasterVault.load(Data("{}".utf8))) { XCTAssertEqual($0 as? VaultError, .corruptVault("not a vault file")) }
    }

    func testFeatureEntryCreateStoreRetrieve() throws {
        func call(_ obj: [String: Any]) throws -> [String: Any] {
            let r = try MasterPasswordFeature.run(FeatureRequest(payload: String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)), dependencies: FeatureOutputs([:]))
            return try JSONSerialization.jsonObject(with: Data(r.payload.utf8)) as! [String: Any]
        }
        let created = try call(["op": "create", "password": "feature-pw"])
        let vault = created["vault"] as! String
        let stored = try call(["op": "store", "vault": vault, "password": "feature-pw", "id": "k", "secret": "v"])
        let got = try call(["op": "retrieve", "vault": stored["vault"] as! String, "password": "feature-pw", "id": "k"])
        XCTAssertEqual(got["secret"] as? String, "v")
    }
}
