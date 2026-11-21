import Foundation
import Darwin
import App

/// Explicit local diagnostic. Password input is read from the terminal without echo,
/// never from argv, a file or the environment. Trust is ephemeral, not a production pin.
enum SSHProbe {
    static func start(_ arguments: [String]) -> Never {
        guard let host = CarveCommand.value(after: "--host", in: arguments),
              let username = CarveCommand.value(after: "--user", in: arguments),
              let buffer = getpass("SSH password (not saved): ") else {
            print("Usage: --verify-ssh --host HOST --user USER [--port PORT]"); exit(1)
        }
        let secret = String(cString: buffer)
        memset(buffer, 0, strlen(buffer))
        let port = CarveCommand.value(after: "--port", in: arguments) ?? "22"
        Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("mshell-probe-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let workspace = try WorkspaceModel(storage: root)
                let draft = workspace.tabs[0]; draft.host = host; draft.port = port; draft.username = username
                let folder = try workspace.sessionTree.add(name: "Diagnostic", parent: nil)
                try workspace.saveConnection(draft, name: "SSH target", parent: folder)
                let reloaded = try WorkspaceModel(storage: root)
                guard let item = reloaded.sessionTree.connections(in: folder).first else { throw WorkspaceError.invalid("Saved connection did not reload.") }
                guard let tab = reloaded.openSaved(item) else { throw WorkspaceError.invalid("Saved connection did not open.") }
                // openSaved schedules the login on the main actor. Supply the secret before yielding.
                tab.password = secret
                for _ in 0..<400 {
                    if let prompt = tab.hostKeyPrompt {
                        print("Ephemeral trust-on-first-use fingerprint: \(prompt.fingerprint)")
                        print("Fingerprint was not independently verified; production trust is unchanged.")
                        reloaded.answerHostKey(tab, approve: true)
                    }
                    if tab.connected || tab.error != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard tab.connected else {
                    await reloaded.closeAll()
                    throw WorkspaceError.invalid(tab.error ?? "SSH connection failed.")
                }
                var commandOK = false
                if arguments.contains("--interactive") {
                    await reloaded.startTerminal(tab)
                    for _ in 0..<100 {
                        if tab.terminalReady || tab.error != nil { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard tab.terminalReady else {
                        await reloaded.closeAll()
                        throw WorkspaceError.invalid(tab.error ?? "PTY/shell did not open.")
                    }
                    try await Task.sleep(nanoseconds: 350_000_000)
                    @MainActor func lines() -> [String] {
                        tab.lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                    let before = Set(lines())
                    reloaded.sendTerminal(tab, bytes: Array("help\r".utf8))
                    for _ in 0..<100 {
                        commandOK = lines().contains { !before.contains($0) && $0 != "help" && !$0.hasSuffix(" help") }
                        if commandOK || tab.error != nil { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    print("PTY/shell request acknowledgement: PASS")
                    print("Interactive output beyond help echo: \(commandOK ? "PASS" : "FAIL")")
                } else {
                    tab.command = "printf 'MSHELL_SSH_OK\\n'; uname -s"
                    await reloaded.execute(tab)
                    commandOK = tab.error == nil && tab.lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "MSHELL_SSH_OK" }
                }
                print("Catalog reload/open: PASS")
                print("Native SSH authentication: PASS")
                print("Read-only command: \(commandOK ? "PASS" : "FAIL")")
                if !commandOK, let error = tab.error { print("Command detail: \(error)") }
                await reloaded.refreshFiles(tab)
                let filesOK = tab.filesLoaded && tab.error == nil
                print("Read-only SFTP directory listing: \(filesOK ? "PASS" : "UNAVAILABLE")")
                if let error = tab.error { print("SFTP detail: \(error)") }
                await reloaded.closeAll()
                try? FileManager.default.removeItem(at: root)
                exit(commandOK && filesOK ? 0 : 1)
            } catch {
                try? FileManager.default.removeItem(at: root)
                print("SSH diagnostic failed: \(error.localizedDescription)"); exit(1)
            }
        }
        dispatchMain()
    }
}
