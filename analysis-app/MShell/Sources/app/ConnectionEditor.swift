import SwiftUI

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
    @State private var opensFiles: Bool
    @State private var jumpSessionID: UUID?
    @State private var usesProxy: Bool
    @State private var proxyHost: String
    @State private var proxyPort: String
    @State private var error: String?

    init(store: SessionTreeStore, item: SessionTreeNode? = nil, parent: UUID?) {
        self.store = store
        self.item = item
        self.parent = parent
        let settings = item?.connection
        _name = State(initialValue: item?.name ?? "")
        _host = State(initialValue: settings?.host ?? "")
        _port = State(initialValue: String(settings?.port ?? 22))
        _username = State(initialValue: settings?.username ?? "")
        _identityPath = State(initialValue: settings?.identityPath)
        _opensFiles = State(initialValue: settings?.opensFiles == true)
        _jumpSessionID = State(initialValue: settings?.jumpSessionID)
        _usesProxy = State(initialValue: settings?.proxyHost != nil)
        _proxyHost = State(initialValue: settings?.proxyHost ?? "")
        _proxyPort = State(initialValue: String(settings?.proxyPort ?? 1080))
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
                Toggle(T("Open in Remote files"), isOn: $opensFiles)
                JumpHostPicker(store: store, excluding: item?.id, selection: $jumpSessionID)
                if jumpSessionID == nil {
                    Toggle("SOCKS5", isOn: $usesProxy)
                    if usesProxy {
                        TextField(T("Proxy host"), text: $proxyHost)
                        TextField(T("Proxy port"), text: $proxyPort)
                    }
                }
            }
            Text(T("Passwords are managed separately in the vault.")).font(.callout).foregroundStyle(.secondary)
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
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxy = usesProxy && jumpSessionID == nil
        guard let port = Int(port), !proxy || Int(proxyPort) != nil else {
            error = "Enter a valid port."
            return
        }
        let connection = SavedConnection(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyHost: proxy ? proxyHost.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            proxyPort: proxy ? Int(proxyPort) : nil, identityPath: identityPath, opensFiles: opensFiles, jumpSessionID: jumpSessionID
        )
        do {
            if let item {
                try store.updateConnection(item.id, name: name, connection: connection)
            } else {
                try store.add(name: name, parent: parent, connection: connection)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


struct IdentityFilePicker: View {
    @Binding var path: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(T(path == nil ? "Choose Ed25519 key…" : "Change key…")) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK { path = panel.url?.path }
            }
            if let path {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).help(path).foregroundStyle(.secondary)
                Button { self.path = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel(T("Remove key reference"))
            }
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
