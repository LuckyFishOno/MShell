import AppKit
import MasterPassword
import SwiftUI

/// The passwords and key passphrases MShell remembers. It opens only after Touch ID or the Mac password, and shows a
/// secret only when asked.
struct SavedSignInsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [SavedSignIn] = []
    @State private var loaded = false
    @State private var revealed: [String: String] = [:]
    @State private var copiedID: String?
    @State private var removing: SavedSignIn?
    @State private var error: String?
    @State private var filter = ""

    private var shown: [SavedSignIn] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            ([item.account, item.detail ?? ""] + item.sessions).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(T("Saved passwords"), systemImage: "key.viewfinder").font(.title2.weight(.semibold))
                Spacer()
                TextField(T("Search"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Text(T(model.savesWithoutUnlock
                   ? "Passwords that signed in are remembered on this Mac. Vault entries are copies you put in the password vault; they need the vault unlocked."
                   : "Passwords in the password vault. Unlock the vault to show or delete them."))
                .font(.callout).foregroundStyle(.secondary)
            if loaded && items.isEmpty {
                ContentUnavailableView(T("No saved passwords"), systemImage: "key",
                                       description: Text(T("A password is saved here after it first signs in.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { item in row(item) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .accessibilityIdentifier("savedSignInsList")
            }
            if let error {
                Label(T(error), systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text(T("Copied passwords are cleared from the clipboard after 60 seconds."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(T("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 460)
        .task { await reload() }
        .onDisappear { revealed = [:] }
        .confirmationDialog(T("Delete this saved password?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { item in
            Button(T("Delete"), role: .destructive) { Task { await remove(item) } }
        } message: { item in
            Text(T(item.place == .vault ? "Only the copy in the password vault is deleted."
                   : "The next connection asks for it again, unless the password vault has a copy and is unlocked."))
        }
    }

    private func row(_ item: SavedSignIn) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isPassphrase ? "key.horizontal" : "person.badge.key")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.account).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                let subtitle = item.sessions.isEmpty ? (item.isPassphrase ? T("Key passphrase") : T("Password"))
                    : item.sessions.joined(separator: ", ")
                HStack(spacing: 6) {
                    Label(T(item.place == .vault ? "Password vault" : "This Mac"),
                          systemImage: item.place == .vault ? "lock.shield" : "laptopcomputer")
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(item.detail ?? subtitle)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: revealed[item.id] ?? "••••••••").font(.callout.monospaced()).textSelection(.enabled)
                .lineLimit(1).frame(maxWidth: 170, alignment: .trailing)
            Button { Task { await toggleReveal(item) } } label: {
                Image(systemName: revealed[item.id] == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless).help(T(revealed[item.id] == nil ? "Show" : "Hide"))
            Button { Task { await copy(item) } } label: {
                Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless).help(T("Copy"))
            Button { removing = item } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(T("Delete"))
        }
        .padding(.vertical, 3)
    }

    private func reload() async {
        items = await model.savedSignIns()
        loaded = true
    }

    private func secret(_ item: SavedSignIn) async -> String? {
        do { error = nil; return try await model.revealSignIn(item) }
        catch VaultError.locked { self.error = "Unlock the password vault to see its entries."; return nil }
        catch { self.error = message(for: error); return nil }
    }

    private func toggleReveal(_ item: SavedSignIn) async {
        if revealed[item.id] != nil { revealed[item.id] = nil; return }
        revealed[item.id] = await secret(item)
    }

    private func copy(_ item: SavedSignIn) async {
        guard let value = await secret(item) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        let change = pasteboard.changeCount
        copiedID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            // Clear only if nothing else was copied since.
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedID == item.id { copiedID = nil }
        }
    }

    private func remove(_ item: SavedSignIn) async {
        do {
            error = nil
            try await model.removeSignIn(item)
            revealed[item.id] = nil
            await reload()
        } catch VaultError.locked {
            self.error = "Unlock the password vault to delete its entries."
        } catch {
            self.error = message(for: error)
        }
    }
}
