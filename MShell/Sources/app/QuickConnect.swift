import SwiftUI

extension SavedConnection {
    static func quickTarget(_ input: String) -> Self? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = query.hasPrefix("ssh ") ? String(query.dropFirst(4)) : query
        guard !target.isEmpty, target.utf8.count <= 1024,
              !target.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let parts = target.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("-") else { return nil }
        let endpoint = parts[1]
        let host: Substring
        let portText: Substring?
        if endpoint.hasPrefix("["), let closing = endpoint.firstIndex(of: "]") {
            host = endpoint[endpoint.index(after: endpoint.startIndex)..<closing]
            let remainder = endpoint[endpoint.index(after: closing)...]
            guard remainder.isEmpty || remainder.hasPrefix(":") else { return nil }
            portText = remainder.isEmpty ? nil : remainder.dropFirst()
        } else {
            let components = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count <= 2, let component = components.first else { return nil }
            host = component
            portText = components.count == 2 ? components[1] : nil
        }
        let invalid = CharacterSet(charactersIn: "/\\[]?#")
        guard !host.isEmpty, !host.hasPrefix("-"), !host.unicodeScalars.contains(where: invalid.contains),
              !parts[0].unicodeScalars.contains(where: invalid.contains) else { return nil }
        guard let port = portText.map({ Int($0) }) ?? 22, (1...65535).contains(port) else { return nil }
        return Self(host: String(host), port: port, username: String(parts[0]))
    }
}

struct QuickConnect: View {
    private struct Row: Identifiable {
        let item: SessionTreeNode
        let folder: String
        var id: UUID { item.id }
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var selection: UUID?
    let model: WorkspaceModel
    private let rows: [Row]

    init(model: WorkspaceModel) {
        self.model = model
        let indexed = Dictionary(uniqueKeysWithValues: model.sessionTree.nodes.map { ($0.id, $0) })
        rows = model.sessionTree.nodes.compactMap { item in
            guard item.connection != nil else { return nil }
            var parents: [String] = []
            var current = item.parent
            while let folder = current.flatMap({ indexed[$0] }) {
                parents.append(folder.name)
                current = folder.parent
            }
            return Row(item: item, folder: parents.reversed().joined(separator: " / "))
        }.sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
    }

    private var filtered: ArraySlice<Row> {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = term.hasPrefix("ssh ") && SavedConnection.quickTarget(term) != nil
            ? String(term.dropFirst(4)) : term
        let words = query.split(whereSeparator: \.isWhitespace)
        return rows.filter { row in
            let address = row.item.connection.map { "\($0.username)@\($0.host):\($0.port)" } ?? ""
            return words.allSatisfy { word in
                [row.item.name, row.folder, address].contains { $0.localizedStandardContains(String(word)) }
            }
        }.prefix(100)
    }

    var body: some View {
        let matches = filtered
        VStack(alignment: .leading, spacing: 14) {
            Label(T("Quick connect"), systemImage: "bolt.horizontal.circle").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Find a session or enter user@host"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { connect() }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
            }.padding(11).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            if let direct = SavedConnection.quickTarget(search) {
                Button { openDirect(direct) } label: {
                    Label(String(format: T("Connect directly to %@"), "\(direct.username)@\(direct.host):\(direct.port)"),
                          systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.borderless)
            }

            if matches.isEmpty {
                ContentUnavailableView(T("No matching sessions"), systemImage: "server.rack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    List(selection: $selection) {
                        ForEach(matches) { row in
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.item.name).fontWeight(.medium)
                                    if let connection = row.item.connection {
                                        Text(verbatim: "\(connection.username)@\(connection.host):\(connection.port)")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(row.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .tag(row.id)
                            .id(row.id)
                            .onTapGesture(count: 2) { open(row.item) }
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: selection) { _, id in if let id { scroll.scrollTo(id) } }
                }
            }
            HStack {
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("Connect")) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matches.isEmpty && SavedConnection.quickTarget(search) == nil)
            }
        }
        .padding(22)
        .frame(width: 580, height: 435)
        .onAppear { selection = matches.first?.id; searchFocused = true }
        .onChange(of: search) { _, _ in
            selection = matches.first?.id
        }
    }

    private func move(_ delta: Int) {
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return }
        guard let selection, let index = ids.firstIndex(of: selection) else {
            selection = delta < 0 ? ids.last : ids.first
            return
        }
        self.selection = ids[min(ids.count - 1, max(0, index + delta))]
    }

    private func connect() {
        if let selection, let row = filtered.first(where: { $0.id == selection }) {
            open(row.item)
        } else if let direct = SavedConnection.quickTarget(search) {
            openDirect(direct)
        } else if let row = filtered.first {
            open(row.item)
        }
    }

    private func openDirect(_ connection: SavedConnection) {
        open(SessionTreeNode(name: "\(connection.username)@\(connection.host)", connection: connection))
    }

    private func open(_ item: SessionTreeNode) {
        model.openSaved(item)
        dismiss()
    }
}
