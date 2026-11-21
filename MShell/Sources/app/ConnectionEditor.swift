import SwiftUI
import Network
import Ssh

/// A saved entry is edited independently of any live connection.
struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: SessionTreeStore
    let item: SessionTreeNode?
    let parent: UUID?
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var identityPath: String?
    @State private var usesAgent: Bool
    @State private var confirmsEachConnection: Bool
    private let vaultOverrideNote = "If you have set up a password vault and it is unlocked, this setting does not apply: connections use the vault without asking."
    @State private var opensFiles: Bool
    @State private var jumpSessionID: UUID?
    @State private var usesProxy: Bool
    @State private var proxyHost: String
    @State private var proxyPort: String
    @State private var proxyKind: ProxyKind
    @State private var error: String?
    /// Saved value of the ask setting. Changing it needs the master password (or the owner without a vault).
    private let savedAsks: Bool?
    @State private var askChangeAuthorized = false
    @State private var enteringMasterPassword = false
    @State private var masterPassword = ""
    @State private var masterPasswordError: String?
    @State private var verifying = false

    /// Deletes saved sign-ins when the key is removed on save.
    var model: WorkspaceModel?

    init(store: SessionTreeStore, item: SessionTreeNode? = nil, parent: UUID?, model: WorkspaceModel? = nil) {
        self.store = store
        self.model = model
        self.item = item
        self.parent = parent
        let settings = item?.connection
        _name = State(initialValue: item?.name ?? "")
        _host = State(initialValue: settings?.host ?? "")
        _port = State(initialValue: String(settings?.port ?? 22))
        _username = State(initialValue: settings?.username ?? "")
        _identityPath = State(initialValue: settings?.identityPath)
        _usesAgent = State(initialValue: settings?.usesAgent == true)
        _confirmsEachConnection = State(initialValue: item == nil ? true : settings?.asksEachConnection == true)
        savedAsks = item == nil ? nil : settings?.asksEachConnection == true
        _opensFiles = State(initialValue: settings?.opensFiles == true)
        _jumpSessionID = State(initialValue: settings?.jumpSessionID)
        _usesProxy = State(initialValue: settings?.proxyHost != nil)
        _proxyHost = State(initialValue: settings?.proxyHost ?? "")
        _proxyPort = State(initialValue: String(settings?.proxyPort ?? 1080))
        _proxyKind = State(initialValue: settings?.proxyKind ?? .socks5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(T(item == nil ? "New saved session" : "Session properties"), systemImage: "server.rack")
                .font(.title2.weight(.semibold))
            Form {
                TextField(T("Name"), text: $name)
                TextField(T("Host"), text: $host)
                TextField(T("Port"), text: $port)
                TextField(T("Username"), text: $username)
                IdentityFilePicker(path: $identityPath)
                // One row with fixed spacing: the form spaces a checkbox next to a button differently from a plain one.
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(T("SSH agent"), isOn: $usesAgent)
                    Toggle(T("Open in Remote files"), isOn: $opensFiles)
                    HStack(spacing: 6) {
                        Toggle(T("Ask for Touch ID or the Mac password on every connection"), isOn: $confirmsEachConnection)
                        InfoButton(T(confirmsEachConnection
                                     ? "The saved password or key is used only after Touch ID or the Mac password. While the password vault is unlocked, it does not ask."
                                     : "After the first successful sign-in, this session connects without asking again.")
                                   + "\n\n" + T(vaultOverrideNote))
                    }
                }
                if usesAgent, let socket = item?.connection?.agentSocket {
                    LabeledContent(T("Agent socket")) {
                        Text(verbatim: socket).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(socket)
                    }
                }
                JumpHostPicker(store: store, excluding: item?.id, selection: $jumpSessionID)
                if jumpSessionID == nil {
                    Toggle(T("Proxy"), isOn: $usesProxy)
                    if usesProxy {
                        ProxyKindPicker(kind: $proxyKind, labeled: true)
                        TextField(T("Proxy host"), text: $proxyHost)
                        TextField(T("Proxy port"), text: $proxyPort)
                    }
                }
            }
            if let error {
                Label(T(error), systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.callout).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .sheet(isPresented: $enteringMasterPassword, onDismiss: { masterPassword = ""; masterPasswordError = nil }) {
            masterPasswordSheet
        }
    }

    private var masterPasswordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(T("Enter the master password"), systemImage: "lock.shield").font(.title3.weight(.semibold))
            Text(T("Changing whether this session asks on every connection needs the password vault's master password."))
                .fixedSize(horizontal: false, vertical: true)
            SecureField(T("Master password"), text: $masterPassword).onSubmit(checkMasterPassword)
            if let masterPasswordError {
                Label(T(masterPasswordError), systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button(T("Cancel")) { enteringMasterPassword = false }.keyboardShortcut(.cancelAction)
                Button(T("Save"), action: checkMasterPassword).keyboardShortcut(.defaultAction)
                    .disabled(masterPassword.isEmpty || verifying)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func checkMasterPassword() {
        guard let model, !masterPassword.isEmpty, !verifying else { return }
        let password = masterPassword
        verifying = true
        Task {
            let valid = await model.verifyMasterPassword(password)
            verifying = false
            guard valid else { masterPasswordError = "The master password is incorrect."; return }
            enteringMasterPassword = false
            askChangeAuthorized = true
            save()
        }
    }

    /// The ask setting of a saved session changed: confirm the owner before saving.
    private func authorizeAskChange() -> Bool {
        guard let model, let savedAsks, savedAsks != confirmsEachConnection, !askChangeAuthorized else { return true }
        if model.vaultState != "Not configured" {
            enteringMasterPassword = true
        } else {
            Task {
                if await model.authorizeAskChange() { askChangeAuthorized = true; save() }
                else { error = "Touch ID or the Mac password is required to change this setting." }
            }
        }
        return false
    }

    private func save() {
        guard authorizeAskChange() else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy = usesProxy && jumpSessionID == nil
        guard let port = Int(port), !proxy || Int(proxyPort) != nil else {
            error = "Enter a valid port."
            return
        }
        var connection = SavedConnection(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyHost: proxy ? proxyHost.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            proxyPort: proxy ? Int(proxyPort) : nil, identityPath: identityPath, opensFiles: opensFiles, jumpSessionID: jumpSessionID,
            usesAgent: usesAgent, agentSocket: item?.connection?.agentSocket, proxyKind: proxyKind,
            confirmsEachConnection: confirmsEachConnection
        )
        do {
            if let item {
                let previous = store.node(item.id)?.connection
                connection.forwardingRules = previous?.forwardingRules
                try store.updateConnection(item.id, name: name, connection: connection)
                // The key was removed: the account must sign in with a typed password again.
                if let previous, let removedKey = previous.identityPath, connection.identityPath == nil, let model {
                    let account = "\(previous.username)@\(KnownHosts.endpoint(host: previous.host, port: previous.port))"
                    Task { try? await model.forgetSignIn(account: account, keyPath: removedKey) }
                }
            } else {
                try store.add(name: name, parent: parent, connection: connection)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


/// MShell's own Secure Enclave key, kept in the app's data folder. Saved connections refer to it by path.
@MainActor enum AppSSHKey {
    /// Set by the workspace to its storage folder.
    static var directory: URL?
    static var url: URL? { directory?.appendingPathComponent("ssh-key-secure-enclave") }
    static var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    static func isAppKey(_ path: String?) -> Bool { path != nil && path == url?.path }

    static func publicKey() async throws -> String {
        guard let url else { throw SSHKeyFileError.invalid }
        return try await Task.detached(priority: .userInitiated) {
            try SecureEnclaveSSHIdentity.publicKey(of: Data(contentsOf: url))
        }.value
    }

    /// Posted after the key is created or replaced, so every key picker updates its button.
    static let changed = Notification.Name("MShellAppSSHKeyChanged")

    /// Creates a new key, replacing any earlier one. Servers that trusted the old public key need the new one.
    static func create() async throws -> String {
        guard let url else { throw SSHKeyFileError.invalid }
        let identity = try await Task.detached(priority: .userInitiated) { try SecureEnclaveSSHIdentity.create() }.value
        try writePrivate(identity.fileContents, to: url)
        NotificationCenter.default.post(name: changed, object: nil)
        return identity.publicKey
    }
}

struct IdentityFilePicker: View {
    @Binding var path: String?
    /// Runs after the user confirms removing the key; without it the key is only cleared from the form.
    var onRemove: (() -> Void)? = nil
    @State private var confirmingRemove = false
    @State private var busy = false
    @State private var shownPublicKey: String?
    @State private var keyError: String?
    @State private var confirmingRegenerate = false
    @State private var copied = false
    @State private var needsTouchID = false
    @State private var explainingTouchID = false
    /// Whether the MShell key exists: "Create public key" until it does, then "Show public key".
    @State private var hasAppKey = AppSSHKey.exists

    var body: some View {
        HStack(spacing: 8) {
            Button(T(path == nil ? "Choose private key…" : "Change key…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK { path = panel.url?.path }
            }
            if let path {
                Text(AppSSHKey.isAppKey(path) ? T("MShell key (Secure Enclave)") : URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(path).foregroundStyle(.secondary)
                Button { confirmingRemove = true } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel(T("Remove key reference")).help(T("Remove key reference"))
                    .accessibilityIdentifier("removeKeyButton")
                if needsTouchID {
                    Button { explainingTouchID = true } label: {
                        Label(T("Needs Touch ID"), systemImage: "touchid").foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain).fixedSize()
                    .help(T("This older key asks for Touch ID. Switch to the MShell key to stop the prompt."))
                }
            }
            if SecureEnclaveSSHIdentity.isAvailable && AppSSHKey.directory != nil {
                Button(T(hasAppKey ? "Show public key" : "Create public key"), action: hasAppKey ? showKey : createKey)
                    .help(T("A key kept in this Mac's Secure Enclave. Add its public key to the server."))
                    .disabled(busy)
            }
        }
        .onAppear { hasAppKey = AppSSHKey.exists }
        .onReceive(NotificationCenter.default.publisher(for: AppSSHKey.changed)) { _ in hasAppKey = AppSSHKey.exists }
        .confirmationDialog(T("Stop using this key?"), isPresented: $confirmingRemove) {
            Button(T("Remove"), role: .destructive) {
                if let onRemove { onRemove() } else { path = nil }
            }
        } message: {
            Text(T(onRemove == nil
                   ? "When you save, this session stops using the key and its saved password is deleted, so the next connection asks for the password. The key itself is not deleted."
                   : "The saved session stops using the key and its saved password and passphrase are deleted, so the next connection asks for the password. The key itself is not deleted."))
        }
        .task(id: path) {
            needsTouchID = false
            guard let path, !AppSSHKey.isAppKey(path) else { return }
            needsTouchID = await Task.detached {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
                return SecureEnclaveSSHIdentity.needsTouchID(data)
            }.value
        }
        .alert(T("This key asks for Touch ID"), isPresented: $explainingTouchID) {
            Button(T(hasAppKey ? "Show MShell key" : "Create MShell key"), action: hasAppKey ? showKey : createKey)
            Button(T("Cancel"), role: .cancel) {}
        } message: {
            Text(T("It was created by an earlier MShell build that bound it to Touch ID, and that cannot be changed. Create the MShell key, add its public key to the server's ~/.ssh/authorized_keys, and use it for this connection. It signs without Touch ID."))
        }
        .sheet(isPresented: Binding(get: { shownPublicKey != nil }, set: { if !$0 { shownPublicKey = nil } })) {
            publicKeySheet
        }
        .alert(T("Could not use the Secure Enclave key."), isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button(T("Done")) { keyError = nil }
        } message: { Text(keyError ?? "") }
    }

    private var publicKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label(T("MShell public key"), systemImage: "key.horizontal").font(.headline)
                InfoButton(T("Add this line to ~/.ssh/authorized_keys on the server. The private key stays in this Mac's Secure Enclave."))
            }
            Text(verbatim: shownPublicKey ?? "").font(.callout.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(T("Regenerate…"), role: .destructive) { confirmingRegenerate = true }.disabled(busy)
                Spacer()
                if !AppSSHKey.isAppKey(path) {
                    Button(T("Use for this connection")) { path = AppSSHKey.url?.path; shownPublicKey = nil }
                }
                Button(T(copied ? "Copied" : "Copy")) {
                    guard let shownPublicKey else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shownPublicKey, forType: .string)
                    copied = true
                }
                Button(T("Done")) { shownPublicKey = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 560)
        .onDisappear { copied = false }
        .confirmationDialog(T("Regenerate the MShell key?"), isPresented: $confirmingRegenerate) {
            Button(T("Regenerate"), role: .destructive) {
                perform { copied = false; shownPublicKey = try await AppSSHKey.create() }
            }
        } message: {
            Text(T("Servers that trust the current public key will stop accepting it. Add the new public key to them."))
        }
    }

    /// Creates the key only. A connection without a key starts using it; viewing it is a separate button.
    private func createKey() {
        perform {
            _ = try await AppSSHKey.create()
            hasAppKey = true
            if path == nil { path = AppSSHKey.url?.path }
        }
    }

    /// Shows the existing key without changing which key this connection uses.
    private func showKey() {
        perform {
            copied = false
            shownPublicKey = try await AppSSHKey.publicKey()
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { keyError = T(message(for: error)) }
        }
    }
}


struct JumpHostPicker: View {
    @ObservedObject var store: SessionTreeStore
    let excluding: UUID?
    @Binding var selection: UUID?

    var body: some View {
        let candidates = store.jumpCandidates(excluding: excluding)
        Picker(T("SSH jump host"), selection: $selection) {
            Text(T("None")).tag(UUID?.none)
            if let selection, !candidates.contains(where: { $0.id == selection }) {
                Text(T("Unavailable jump host")).tag(Optional(selection))
            }
            ForEach(candidates) { item in
                Text(item.name + " · " + (item.connection?.host ?? "")).tag(Optional(item.id))
            }
        }
    }
}


/// SOCKS5, SOCKS4 (4a for host names), or HTTP CONNECT.
struct ProxyKindPicker: View {
    @Binding var kind: ProxyKind
    var labeled = false

    var body: some View {
        Picker(T("Proxy type"), selection: $kind) {
            ForEach([ProxyKind.socks5, .socks4, .http], id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
        .labelsHidden(!labeled)
    }
}

private extension View {
    @ViewBuilder func labelsHidden(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}
