import SwiftUI
import Ssh

struct SessionForward: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let handle: SSHLocalForward
}

extension WorkspaceModel {
    @discardableResult
    func startForward(_ tab: SessionTab, localPort: Int, host: String, port: Int) async throws -> SessionForward {
        guard tab.connected, let ssh = tab.session else { throw WorkspaceError.disconnected }
        let epoch = tab.epoch
        guard tab.forwards.count < 16, tab.forwardStarts < 16 - tab.forwards.count else {
            throw WorkspaceError.invalid("A session can have up to 16 local forwards.")
        }
        tab.forwardStarts += 1
        defer { if tab.epoch == epoch { tab.forwardStarts -= 1 } }
        let tunnel = try await ssh.startLocalForward(localPort: localPort, targetHost: host, targetPort: port)
        guard tab.epoch == epoch else { await tunnel.close(); throw WorkspaceError.disconnected }
        let forward = SessionForward(host: host, port: port, handle: tunnel)
        tab.forwards.append(forward)
        let id = forward.id
        Task { @MainActor [weak tab] in
            await tunnel.waitForClose()
            tab?.forwards.removeAll { $0.id == id }
        }
        return forward
    }

    func stopForward(_ tab: SessionTab, _ forward: SessionForward) async {
        await forward.handle.close()
        tab.forwards.removeAll { $0.id == forward.id }
    }
}

struct PortForwardingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    @State private var localPort = ""
    @State private var host = "127.0.0.1"
    @State private var port = ""
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(T("Local port forwarding"), systemImage: "arrow.left.arrow.right")
                .font(.title2.weight(.semibold))
            Text(T("MShell listens on 127.0.0.1. The SSH server connects to the destination you enter."))
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField(T("Local port"), text: $localPort, prompt: Text(T("Automatic")))
                TextField(T("Destination host"), text: $host)
                TextField(T("Destination port"), text: $port)
            }
            .disabled(!tab.connected || starting)
            if let error {
                Text(T(error)).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            List {
                ForEach(tab.forwards) { forward in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "127.0.0.1:\(forward.handle.port) → \(forward.host):\(forward.port)")
                                .font(.callout.monospaced())
                            Text(T("Listening")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(T("Stop")) { Task { await model.stopForward(tab, forward) } }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
            .overlay {
                if tab.forwards.isEmpty {
                    Text(T(tab.connected ? "No active forwards" : "Connection lost"))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(T("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if starting { ProgressView().controlSize(.small) }
                Button(T("Start forwarding"), action: start)
                    .keyboardShortcut(.defaultAction).disabled(!tab.connected || starting || port.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 510, height: 395)
    }

    private func start() {
        let destination = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let local = source.isEmpty ? 0 : Int(source), let remote = Int(port) else {
            error = "Enter a forwarding host and valid TCP ports."
            return
        }
        error = nil
        starting = true
        Task {
            defer { starting = false }
            do {
                try await model.startForward(tab, localPort: local, host: destination, port: remote)
            } catch {
                self.error = message(for: error)
            }
        }
    }
}
