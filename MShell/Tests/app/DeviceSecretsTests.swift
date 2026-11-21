import XCTest
import Foundation
import MasterPassword
@testable import App

@MainActor final class DeviceSecretsTests: XCTestCase {
    private func directory() throws -> URL {
        try XCTSkipUnless(DeviceSecrets.isAvailable, "Needs a Secure Enclave")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSavedSignInsSurviveReopeningAndAreBoundToTheirEntry() throws {
        let url = try directory().appendingPathComponent("saved-sign-ins.json")
        var secrets = try DeviceSecrets(url: url)
        try secrets.store(id: "alice@[server]:22", secret: "first-secret")
        try secrets.store(id: "bob@[server]:22", secret: "second-secret")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("first-secret"))
        XCTAssertFalse(text.contains("second-secret"))

        var reopened = try DeviceSecrets(url: url)
        XCTAssertEqual(try reopened.secret(id: "alice@[server]:22"), "first-secret")
        XCTAssertNil(try reopened.secret(id: "carol@[server]:22"))

        // An entry copied under another account's ID does not open.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [String: Any])
        entries["bob@[server]:22"] = entries["alice@[server]:22"]
        object["entries"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        var swapped = try DeviceSecrets(url: url)
        XCTAssertThrowsError(try swapped.secret(id: "bob@[server]:22"))
    }

    func testAPasswordThatSignedInConnectsAgainAfterARestartWithoutUnlocking() async throws {
        let root = try directory()
        let vaultURL = root.appendingPathComponent("password-vault.json"), deviceURL = root.appendingPathComponent("saved-sign-ins.json")
        let vault = try CredentialVault(url: vaultURL, deviceSecrets: deviceURL)
        let savesWithoutUnlock = await vault.savesWithoutUnlock
        XCTAssertTrue(savesWithoutUnlock)
        await vault.rememberWorking(id: "alice@[server]:22", secret: "remembered", generation: await vault.sessionGeneration)
        await vault.lock()

        let restarted = try CredentialVault(url: vaultURL, deviceSecrets: deviceURL)
        let secret = try await restarted.password(id: "alice@[server]:22")
        XCTAssertEqual(secret, "remembered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path), "No master password is needed to save.")

        // The server refused it: forget it so the form asks for the new one.
        await restarted.forgetForSession(id: "alice@[server]:22", matching: "remembered", generation: await restarted.sessionGeneration)
        do { _ = try await restarted.password(id: "alice@[server]:22"); XCTFail("A refused password must be forgotten") } catch {}

        try await restarted.save(id: "bob@[server]:22", password: "typed")
        let saved = try await CredentialVault(url: vaultURL, deviceSecrets: deviceURL).password(id: "bob@[server]:22")
        XCTAssertEqual(saved, "typed")
    }

    func testTheVaultIsASeparateCopyUsedWhileUnlockedAndNeverEmptiedByUnlocking() async throws {
        let root = try directory()
        let vaultURL = root.appendingPathComponent("password-vault.json"), deviceURL = root.appendingPathComponent("saved-sign-ins.json")
        let vault = try CredentialVault(url: vaultURL, deviceSecrets: deviceURL)
        try await vault.create(password: "master-secret", iterations: 100)
        try await vault.addToVault(id: "alice@[server]:22", secret: "kept-in-vault")
        await vault.lock()

        let restarted = try CredentialVault(url: vaultURL, deviceSecrets: deviceURL)
        do { _ = try await restarted.password(id: "alice@[server]:22"); XCTFail("A vault copy needs the vault unlocked") } catch {}
        try await restarted.unlock(password: "master-secret")
        await restarted.persistSessionSecrets()
        let secret = try await restarted.password(id: "alice@[server]:22")
        XCTAssertEqual(secret, "kept-in-vault")
        let entries = await restarted.savedEntries()
        XCTAssertEqual(entries.map(\.id), ["alice@[server]:22"])
        XCTAssertEqual(entries.map(\.place), [.vault], "Unlocking does not move vault entries out of the vault.")
    }

    func testASessionMarkedToAskConfirmsTheOwnerBeforeUsingSavedSecrets() async throws {
        let model = try WorkspaceModel(storage: directory())
        var reasons: [String] = []
        model.confirmOwner = { reasons.append($0); throw CancellationError() }
        let tab = model.addTab()
        tab.host = "127.0.0.1"; tab.port = "1"; tab.username = "alice"
        tab.confirmsEachConnection = true
        await model.connect(tab)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertFalse(tab.connected)
        XCTAssertEqual(tab.error, "This session asks for Touch ID or the Mac password before it connects.")

        tab.password = "typed-now"
        await model.connect(tab)
        XCTAssertEqual(reasons.count, 1, "A password typed for this connection needs no extra confirmation.")

        tab.confirmsEachConnection = false
        await model.connect(tab)
        XCTAssertEqual(reasons.count, 1)

        // An unlocked vault already confirmed the owner: no prompt per connection.
        await model.configureVault(password: "master-secret", create: true)
        tab.confirmsEachConnection = true
        await model.connect(tab)
        XCTAssertEqual(reasons.count, 1, "The unlocked vault takes the place of the per-connection check.")
        await model.closeAll()
    }

    func testTheSavedListShowsEachPlaceAndDeletesOnlyThatCopy() async throws {
        let root = try directory()
        let vaultURL = root.appendingPathComponent("password-vault.json"), deviceURL = root.appendingPathComponent("saved-sign-ins.json")
        let vault = try CredentialVault(url: vaultURL, deviceSecrets: deviceURL)
        try await vault.save(id: "alice@[server]:22", password: "mac-copy")
        let onMac = await vault.savedEntries()
        XCTAssertEqual(onMac.map(\.place), [.thisMac], "Passwords that sign in are remembered on this Mac.")
        let revealed = try await vault.revealSaved(id: "alice@[server]:22", in: .thisMac)
        XCTAssertEqual(revealed, "mac-copy")

        try await vault.create(password: "master-secret", iterations: 100)
        try await vault.addToVault(id: "alice@[server]:22", secret: "vault-copy")
        let both = await vault.savedEntries()
        XCTAssertEqual(both.map(\.place), [.thisMac, .vault], "Creating the vault leaves the copy on this Mac.")

        await vault.lock()
        do { _ = try await vault.revealSaved(id: "alice@[server]:22", in: .vault); XCTFail("A locked vault entry stays hidden") } catch {}
        do { try await vault.removeSaved(id: "alice@[server]:22", from: .vault); XCTFail("Deleting a vault entry needs an unlock") } catch {}
        try await vault.unlock(password: "master-secret")
        try await vault.removeSaved(id: "alice@[server]:22", from: .vault)
        let left = await vault.savedEntries()
        XCTAssertEqual(left.map(\.place), [.thisMac], "Deleting the vault copy leaves the one on this Mac.")
    }

    func testTheListNamesTheSessionsThatUseEachSignInAndNeedsTheOwner() async throws {
        let model = try WorkspaceModel(storage: directory())
        try model.sessionTree.add(name: "Build server", parent: nil, connection: SavedConnection(host: "build.test", username: "alice"))
        try model.sessionTree.add(name: "Key login", parent: nil,
                                  connection: SavedConnection(host: "key.test", username: "bob", identityPath: "/keys/id_ed25519"))
        try await model.vault.save(id: "alice@[build.test]:22", password: "one")
        try await model.vault.save(id: WorkspaceModel.passphraseID("/keys/id_ed25519"), password: "two")
        let items = await model.savedSignIns()
        XCTAssertEqual(items.map(\.sessions), [["Build server"], ["Key login"]])
        XCTAssertEqual(items.last?.account, "id_ed25519")
        XCTAssertEqual(items.last?.isPassphrase, true)

        model.confirmOwner = { _ in throw CancellationError() }
        let refused = await model.authorizeSavedSignIns()
        XCTAssertFalse(refused)
        model.confirmOwner = { _ in }
        let allowed = await model.authorizeSavedSignIns()
        XCTAssertTrue(allowed)
        await model.closeAll()
    }

    func testRemovingAKeyMakesTheNextConnectionAskForThePasswordAgain() async throws {
        let model = try WorkspaceModel(storage: directory())
        let path = "/keys/id_ed25519"
        let id = try model.sessionTree.add(name: "Key login", parent: nil,
                                           connection: SavedConnection(host: "key.test", username: "bob", identityPath: path))
        try await model.vault.save(id: WorkspaceModel.passphraseID(path), password: "phrase")
        try await model.vault.save(id: "bob@[key.test]:22", password: "account-password")
        let node = try XCTUnwrap(model.sessionTree.node(id))
        let tab = model.openSaved(node)
        let opened = try XCTUnwrap(tab)
        opened.savedConnectionTask?.cancel()
        await opened.savedConnectionTask?.value
        XCTAssertEqual(opened.identityPath, path)

        await model.removeKey(from: opened)
        XCTAssertNil(opened.identityPath)
        XCTAssertNil(model.sessionTree.node(id)?.connection?.identityPath, "The saved session forgets the key.")
        let left = await model.vault.savedEntries()
        XCTAssertTrue(left.isEmpty, "The account password and the key passphrase are deleted.")

        // Opening it from the session tree no longer signs in on its own.
        let again = try XCTUnwrap(model.openSaved(try XCTUnwrap(model.sessionTree.node(id))))
        await again.savedConnectionTask?.value
        XCTAssertFalse(again.connected)
        XCTAssertEqual(again.error, "No password is saved for this account. Enter a connection password.")
        await model.closeAll()
    }

    func testWithAVaultPasswordsThatSignInStillConnectWhileItIsLocked() async throws {
        let root = try directory()
        let model = try WorkspaceModel(storage: root)
        await model.vault.rememberWorking(id: "alice@[server]:22", secret: "remembered-before", generation: await model.vault.sessionGeneration)
        await model.configureVault(password: "master-secret", create: true)
        XCTAssertTrue(model.savesWithoutUnlock, "The vault does not take over remembering passwords.")
        await model.vault.rememberWorking(id: "bob@[server]:22", secret: "signed-in", generation: await model.vault.sessionGeneration)
        await model.closeAll()

        let restarted = try WorkspaceModel(storage: root)
        let state = await restarted.vault.state
        XCTAssertEqual(state, "Locked")
        let before = try await restarted.vault.password(id: "alice@[server]:22")
        XCTAssertEqual(before, "remembered-before", "A locked vault does not hide passwords remembered on this Mac.")
        let after = try await restarted.vault.password(id: "bob@[server]:22")
        XCTAssertEqual(after, "signed-in")
        await restarted.closeAll()
    }

    func testTheFormMarksAPasswordInTheVaultAndCanRemoveIt() async throws {
        let model = try WorkspaceModel(storage: directory())
        await model.configureVault(password: "master-secret", create: true)
        let tab = model.addTab()
        tab.host = "server.test"; tab.username = "alice"; tab.password = "typed"
        XCTAssertFalse(model.vaultEntries.contains(tab.credentialID))
        await model.savePassword(tab)
        XCTAssertTrue(model.vaultEntries.contains(tab.credentialID), "The form shows it is in the vault.")

        await model.removeFromVault(tab)
        XCTAssertFalse(model.vaultEntries.contains(tab.credentialID))
        do { _ = try await model.vault.password(id: tab.credentialID); XCTFail("The next connection asks for the password") } catch {}
        await model.closeAll()
    }

    func testALockedVaultAsksOnlyForSessionsSetToAskAndStaysLocked() async throws {
        let model = try WorkspaceModel(storage: directory())
        await model.configureVault(password: "master-secret", create: true)
        let prompts = PromptCounter()
        try await model.vault.enableTouchIDForTesting { _ in prompts.add() }
        var checks = 0
        model.confirmOwner = { _ in checks += 1 }

        // Only the vault holds this password: one Touch ID prompt reads it, and it counts as the per-connection check.
        let vaultOnly = model.addTab()
        vaultOnly.host = "127.0.0.1"; vaultOnly.port = "1"; vaultOnly.username = "alice"; vaultOnly.confirmsEachConnection = true
        try await model.vault.addToVault(id: vaultOnly.credentialID, secret: "in-vault")
        await model.lockVault()
        await model.connect(vaultOnly)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(checks, 0, "The Touch ID that read the password is the only prompt.")
        XCTAssertEqual(model.vaultState, "Locked", "Touch ID for a connection does not unlock the vault.")
        XCTAssertNotEqual(vaultOnly.error, "No password is saved for this account. Enter a connection password.",
                          "The vault password was used; only the closed test port stops the connection.")

        // Remembered on this Mac and set to ask: the per-connection check asks, every time.
        let asking = model.addTab()
        asking.host = "127.0.0.1"; asking.port = "1"; asking.username = "bob"; asking.confirmsEachConnection = true
        try await model.vault.save(id: asking.credentialID, password: "on-mac")
        await model.connect(asking)
        await model.connect(asking)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(prompts.count, 1, "No vault read for a password this Mac remembers.")

        // Not set to ask: connects with the password on this Mac and no prompt.
        let quiet = model.addTab()
        quiet.host = "127.0.0.1"; quiet.port = "1"; quiet.username = "carol"; quiet.confirmsEachConnection = false
        try await model.vault.save(id: quiet.credentialID, password: "on-mac")
        await model.connect(quiet)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(model.vaultState, "Locked")

        // Unlocked: nothing asks.
        await model.configureVault(password: "master-secret", create: false)
        await model.connect(asking)
        XCTAssertEqual(checks, 2)
        await model.closeAll()
    }

    func testTheAskSettingIsSavedWithTheSession() throws {
        let connection = SavedConnection(host: "server.test", username: "alice", confirmsEachConnection: true)
        let decoded = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertTrue(decoded.asksEachConnection)
        let existing = try JSONDecoder().decode(SavedConnection.self, from: Data(#"{"host":"old.test","port":22,"username":"bob"}"#.utf8))
        XCTAssertFalse(existing.asksEachConnection, "Sessions saved before the setting existed keep it off.")
        XCTAssertTrue(SessionTab().confirmsEachConnection, "A new connection starts with it on.")
    }
}

private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

@MainActor final class AskChangeAuthorizationTests: XCTestCase {
    func testTheMasterPasswordIsCheckedWithoutUnlockingTheVault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-change-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = try WorkspaceModel(storage: root)
        let none = await model.verifyMasterPassword("anything")
        XCTAssertFalse(none, "Without a vault there is no master password to check.")
        await model.configureVault(password: "master-secret", create: true)
        await model.lockVault()
        let wrong = await model.verifyMasterPassword("wrong")
        XCTAssertFalse(wrong)
        let right = await model.verifyMasterPassword("master-secret")
        XCTAssertTrue(right)
        XCTAssertEqual(model.vaultState, "Locked", "Checking the password does not unlock the vault.")

        var reasons: [String] = []
        model.confirmOwner = { reasons.append($0) }
        let allowed = await model.authorizeAskChange()
        XCTAssertTrue(allowed)
        model.confirmOwner = { _ in throw CancellationError() }
        let refused = await model.authorizeAskChange()
        XCTAssertFalse(refused)
        XCTAssertEqual(reasons.count, 1)
        await model.closeAll()
    }
}
