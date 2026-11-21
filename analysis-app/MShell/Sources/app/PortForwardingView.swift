import SwiftUI
import Ssh

enum ForwardingKind: String, Codable, CaseIterable, Sendable {
    case local, remote, dynamic

    var title: String {
        switch self {
        case .local: return "Local port forwarding"
        case .remote: return "Remote port forwarding"
        case .dynamic: return "Dynamic SOCKS proxy"
        }
    }

    var help: String {
        switch self {
        case .local: return "MShell listens on 127.0.0.1. The SSH server connects to the destination you enter."
        case .remote: return "The SSH server listens on its loopback interface. This Mac connects to the destination you enter."
        case .dynamic: return "MShell listens on 127.0.0.1 for SOCKS4, SOCKS4a, and SOCKS5 connections."
        }
    }
}

struct ForwardingRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: ForwardingKind
    let listenPort: Int
    let host: String?
    let port: Int?

    init(kind: ForwardingKind, listenPort: Int, host: String? = nil, port: Int? = nil) {
        id = UUID()
        self.kind = kind
        self.listenPort = listenPort
        self.host = host
        self.port = port
    }

    func validate() throws {
        guard (0...65535).contains(listenPort) else {
            throw WorkspaceError.invalid("Enter a forwarding host and valid TCP ports.")
        }
        if kind == .dynamic, host == nil, port == nil { return }
        guard kind != .dynamic, let host, !host.isEmpty, host.utf8.count <= 255,
              !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
              let port, (1...65535).contains(port) else {
            throw WorkspaceError.invalid("Enter a forwarding host and valid TCP ports.")
        }
    }

    static func validateSaved(_ rules: [Self]) throws {
        guard rules.count <= 16, Set(rules.map(\.id)).count == rules.count else {
            throw WorkspaceError.invalid("A session can have up to 16 forwarding rules.")
        }
        for rule in rules { try rule.validate() }
    }

    func address(boundPort: Int? = nil) -> String {
        let hostLabel = kind == .remote ? "localhost" : "127.0.0.1"
        let port = boundPort ?? listenPort
        let listener = "\(hostLabel):" + (port == 0 ? T("Automatic") : String(port))
        guard let host, let destination = self.port else { return listener }
        return listener + " → " + (host.contains(":") ? "[\(host)]" : host) + ":\(destination)"
    }
}

struct SessionForward: Identifiable {
    let id = UUID()
    let rule: ForwardingRule
    let handle: any SSHForward
}

extension WorkspaceModel {
    @discardableResult
    func startForward(_ tab: SessionTab, localPort: Int, host: String, port: Int) async throws -> SessionForward {
        try await startForward(tab, rule: ForwardingRule(kind: .local, listenPort: localPort, host: host, port: port))
    }

    @discardableResult
    func startForward(_ tab: SessionTab, rule: ForwardingRule) async throws -> SessionForward {
        guard tab.connected, let ssh = tab.session else { throw WorkspaceError.disconnected }
        try rule.validate()
        guard tab.forwards.count + tab.forwardStarts.count < 16 else {
            throw WorkspaceError.invalid("A session can have up to 16 forwarding rules.")
        }
        guard !tab.forwards.contains(where: { $0.rule.id == rule.id }), tab.forwardStarts.insert(rule.id).inserted else {
            throw WorkspaceError.invalid("This forwarding rule is already active.")
        }
        let epoch = tab.epoch
        defer { if tab.epoch == epoch { tab.forwardStarts.remove(rule.id) } }

        let tunnel: any SSHForward
        switch (rule.kind, rule.host, rule.port) {
        case (.local, let host?, let port?):
            tunnel = try await ssh.startLocalForward(localPort: rule.listenPort, targetHost: host, targetPort: port)
        case (.remote, let host?, let port?):
            tunnel = try await ssh.startRemoteForward(remotePort: rule.listenPort, targetHost: host, targetPort: port)
        case (.dynamic, nil, nil):
            tunnel = try await ssh.startDynamicForward(localPort: rule.listenPort)
        default:
            throw WorkspaceError.invalid("Enter a forwarding host and valid TCP ports.")
        }

        guard tab.epoch == epoch, !Task.isCancelled else {
            await tunnel.close()
            throw WorkspaceError.disconnected
        }
        let forward = SessionForward(rule: rule, handle: tunnel)
        tab.forwards.append(forward)
        let id = forward.id
        Task { @MainActor [weak tab] in
            await tunnel.waitForClose()
            tab?.forwards.removeAll { $0.id == id }
        }
        return forward
    }

    func startSavedForwards(_ tab: SessionTab, epoch: UUID) async {
        for rule in tab.forwardingRules {
            guard tab.epoch == epoch, !Task.isCancelled else { return }
            guard tab.forwardingRules.contains(rule) else { continue }
            do { try await startForward(tab, rule: rule) }
            catch {
                guard tab.epoch == epoch else { return }
                tab.forwardingErrors.append(T(rule.kind.title) + " · " + rule.address() + "\n" + T(message(for: error)))
            }
        }
    }

    func stopForward(_ tab: SessionTab, _ forward: SessionForward) async {
        await forward.handle.close()
        tab.forwards.removeAll { $0.id == forward.id }
    }

    func changeForwardingRules(_ tab: SessionTab, _ edit: (inout [ForwardingRule]) -> Void) throws {
        let saved = tab.savedSessionID.flatMap { sessionTree.node($0) }
        if tab.savedSessionID != nil && saved?.connection == nil {
            throw WorkspaceError.invalid("This saved connection no longer exists.")
        }
        var rules = saved == nil ? tab.forwardingRules : saved?.connection?.forwardingRules ?? []
        edit(&rules)
        try ForwardingRule.validateSaved(rules)
        if let saved, var connection = saved.connection {
            connection.forwardingRules = rules.isEmpty ? nil : rules
            try sessionTree.updateConnection(saved.id, name: saved.name, connection: connection)
            for other in tabs + sessionWindows.values.map(\.tab) where other.savedSessionID == saved.id {
                other.forwardingRules = rules
            }
        }
        tab.forwardingRules = rules
    }
}

struct PortForwardingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var kind: ForwardingKind = .local
    @State private var listenPort = ""
    @State private var host = "127.0.0.1"
    @State private var port = ""
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(T("Port forwarding"), systemImage: "arrow.left.arrow.right")
                .font(.title2.weight(.semibold))
            Form {
                Picker(T("Forwarding type"), selection: $kind) {
                    ForEach(ForwardingKind.allCases, id: \.self) { Text(T($0.title)).tag($0) }
                }
                TextField(T(kind == .remote ? "Remote listening port" : "Local port"), text: $listenPort,
                          prompt: Text(T("Automatic")))
                if kind != .dynamic {
                    TextField(T("Destination host"), text: $host)
                    TextField(T("Destination port"), text: $port)
                }
            }
            Text(T(kind.help)).font(.callout).foregroundStyle(.secondary)
            if let error { Text(T(error)).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            List {
                Section(T("Active forwards")) {
                    if tab.forwards.isEmpty { Text(T("No active forwards")).foregroundStyle(.secondary) }
                    ForEach(tab.forwards) { forward in
                        HStack {
                            ruleLabel(forward.rule, boundPort: forward.handle.port)
                            Spacer()
                            Button(T("Stop")) { Task { await model.stopForward(tab, forward) } }.buttonStyle(.borderless)
                        }
                    }
                    ForEach(Array(tab.forwardingErrors.enumerated()), id: \.offset) { _, detail in
                        Text(detail).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section(T("Saved forwarding rules")) {
                    if tab.forwardingRules.isEmpty { Text(T("No saved forwarding rules")).foregroundStyle(.secondary) }
                    ForEach(tab.forwardingRules) { rule in
                        HStack {
                            ruleLabel(rule)
                            Spacer()
                            Button(T("Start forwarding")) { start(rule) }
                                .disabled(!tab.connected || starting || tab.forwards.contains { $0.rule.id == rule.id })
                            Button(role: .destructive) {
                                perform { try model.changeForwardingRules(tab) { $0.removeAll { $0.id == rule.id } } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .accessibilityLabel(T("Remove forwarding rule"))
                        }.buttonStyle(.borderless)
                    }
                }
            }.listStyle(.inset)
            if tab.savedSessionID == nil {
                Text(T("Save this connection to keep its forwarding rules.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(T("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if starting { ProgressView().controlSize(.small) }
                Button(T("Save rule")) { perform { let rule = try draft(); try model.changeForwardingRules(tab) { $0.append(rule) } } }
                Button(T("Start forwarding")) { perform { start(try draft()) } }
                    .keyboardShortcut(.defaultAction).disabled(!tab.connected || starting)
            }
        }
        .padding(24)
        .frame(width: 600, height: 540)
    }

    private func ruleLabel(_ rule: ForwardingRule, boundPort: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(T(rule.kind.title)).font(.caption).foregroundStyle(.secondary)
            Text(rule.address(boundPort: boundPort)).font(.callout.monospaced())
        }.padding(.vertical, 3)
    }

    private func draft() throws -> ForwardingRule {
        let source = listenPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = ForwardingRule(kind: kind, listenPort: source.isEmpty ? 0 : (Int(source) ?? -1),
                                  host: kind == .dynamic ? nil : host.trimmingCharacters(in: .whitespacesAndNewlines),
                                  port: kind == .dynamic ? nil : Int(port.trimmingCharacters(in: .whitespacesAndNewlines)))
        try rule.validate()
        return rule
    }

    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() }
        catch { self.error = message(for: error) }
    }

    private func start(_ rule: ForwardingRule) {
        error = nil
        starting = true
        Task {
            defer { starting = false }
            do { try await model.startForward(tab, rule: rule) }
            catch { self.error = message(for: error) }
        }
    }
}
