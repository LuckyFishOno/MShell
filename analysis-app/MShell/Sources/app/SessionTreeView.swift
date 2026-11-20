import SwiftUI

struct SessionTreeView: View {
    @ObservedObject var store: SessionTreeStore
    @ObservedObject var model: WorkspaceModel
    @State private var editor: TreeEditor?
    @State private var name = ""
    @State private var deleting: SessionTreeNode?
    @State private var connectionEditor: ConnectionEditRequest?
    var importFolder: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(T("Session Manager"), systemImage: "folder").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button(T("New folder…")) { edit(.folder, parent: store.destination) }
                    Button(T("New saved session…")) { connectionEditor = ConnectionEditRequest(parent: store.destination) }
                    Button(T("Import Xshell folder…"), action: importFolder)
                    Button(T("Save current connection…")) { saveCurrent() }.disabled(model.selected?.isLocal != false)
                    Divider()
                    Button(T("Expand all")) { perform { try store.expandAll(true) } }
                    Button(T("Collapse all")) { perform { try store.expandAll(false) } }
                    Button(T("Paste at root")) { perform { try store.paste(into: nil) } }.disabled(store.clipboard == nil)
                } label: { Image(systemName: "plus.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(T("Search sessions"), text: $store.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("sessionSearch")
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(T("Clear search"))
                }
            }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(store.children(of: nil).filter { store.matches($0.id) }) { item in row(item) }
                    if store.nodes.isEmpty {
                        Text(T("Save a connection or create a folder using +.")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
                    } else if !store.children(of: nil).contains(where: { store.matches($0.id) }) {
                        Text(T("No matching sessions")).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(T("Root folder")) { store.selection = nil }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 6)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: .infinity)
        }
        .sheet(item: $connectionEditor) { request in
            ConnectionEditor(store: store, item: request.item, parent: request.parent)
        }
        .sheet(item: $editor) { current in
            VStack(alignment: .leading, spacing: 16) {
                Text(current.title).font(.headline)
                TextField(T("Name"), text: $name).textFieldStyle(.roundedBorder).onSubmit { submit(current) }
                if current.kind == .save { Text(T("Host, account and proxy settings only. Passwords are excluded.")).font(.caption).foregroundStyle(.secondary) }
                HStack { Button(T("Cancel")) { editor = nil }; Spacer(); Button(T("Save")) { submit(current) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(24).frame(width: 380)
        }
        .alert(T("Delete saved item?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let item = deleting { perform { try store.remove(item.id) } }; deleting = nil }
        } message: { Text(String(format: T("%@ and its saved descendants will be removed. Open connections and remote files are unaffected."), deleting?.name ?? "")) }
    }
    private func row(_ item: SessionTreeNode) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if item.isFolder {
                    Button { perform { try store.setExpanded(item.id, !item.expanded) } } label: {
                        Image(systemName: item.expanded || !store.query.isEmpty ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                    }.buttonStyle(.plain).disabled(!store.query.isEmpty)
                } else { Color.clear.frame(width: 12, height: 12) }
                Image(systemName: item.isFolder ? "folder.fill" : "terminal").foregroundStyle(item.isFolder ? .orange : .secondary)
                Text(item.name).lineLimit(1)
                Spacer(minLength: 0)
                if store.clipboard == item.id { Image(systemName: store.cutting ? "scissors" : "doc.on.doc").font(.caption) }
            }
            .padding(.vertical, 5).padding(.horizontal, 4).contentShape(Rectangle())
            .background(store.selection == item.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .modifier(SessionTreeRowInteraction(select: { store.selection = item.id }, activate: {
                if item.isFolder { perform { try store.setExpanded(item.id, !item.expanded) } }
                else { model.openSaved(item, inNewWindow: true) }
            }))
            .contextMenu {
                if item.isFolder {
                    Button(T("Open all in tabs")) { perform { try model.openSavedFolder(item.id) } }
                    Button(T("New folder…")) { edit(.folder, parent: item.id) }
                    Button(T("New saved session…")) { connectionEditor = ConnectionEditRequest(parent: item.id) }
                    Button(T("Save current connection here…")) { saveCurrent(parent: item.id) }.disabled(model.selected?.isLocal != false)
                    Button(T("Paste")) { perform { try store.paste(into: item.id) } }.disabled(store.clipboard == nil)
                } else {
                    Button(T("Open in new window")) { model.openSaved(item, inNewWindow: true) }
                    Button(T("Open in tab")) { model.openSaved(item) }
                    Button(T("Session properties…")) { connectionEditor = ConnectionEditRequest(item: item, parent: item.parent) }
                }
                Divider()
                Button(T("Rename…")) { name = item.name; editor = TreeEditor(kind: .rename, item: item.id, parent: item.parent, tab: nil) }
                Button(T("Copy")) { store.prepareClipboard(item.id, cut: false) }
                Button(T("Cut")) { store.prepareClipboard(item.id, cut: true) }
                Button(T("Delete…"), role: .destructive) { deleting = item }
            }
            if item.isFolder && (item.expanded || !store.query.isEmpty) {
                ForEach(store.children(of: item.id).filter { store.matches($0.id) }) { child in row(child).padding(.leading, 14) }
            }
        })
    }
    private func edit(_ kind: TreeEditor.Kind, parent: UUID?) {
        name = ""; editor = TreeEditor(kind: kind, item: nil, parent: parent, tab: nil)
    }
    private func saveCurrent(parent: UUID? = nil) {
        guard let tab = model.selected, !tab.isLocal else { return }
        name = tab.host.isEmpty ? "" : tab.title == "New connection" ? tab.host : tab.title
        editor = TreeEditor(kind: .save, item: nil, parent: parent ?? store.destination, tab: tab.id)
    }
    private func submit(_ current: TreeEditor) {
        do {
            switch current.kind {
            case .folder: try store.add(name: name, parent: current.parent)
            case .rename: if let id = current.item { try store.rename(id, to: name) }
            case .save:
                guard let tab = model.tabs.first(where: { $0.id == current.tab }) else { throw WorkspaceError.invalid("The connection tab was closed.") }
                try model.saveConnection(tab, name: name, parent: current.parent)
            }
            editor = nil
        } catch { model.error = error.localizedDescription; editor = nil }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { model.error = error.localizedDescription } }
}

struct SessionTreeRowInteraction: ViewModifier {
    let select: () -> Void
    let activate: () -> Void
    func body(content: Content) -> some View {
        // Selection must not wait for the double-click recognizer to fail.
        content.onTapGesture(count: 2) { select(); activate() }
            .simultaneousGesture(TapGesture().onEnded { select() })
    }
}

private struct TreeEditor: Identifiable {
    enum Kind { case folder, rename, save }
    let id = UUID()
    let kind: Kind
    let item: UUID?
    let parent: UUID?
    let tab: UUID?
    var title: String { switch kind { case .folder: return T("New folder"); case .rename: return T("Rename saved item"); case .save: return T("Save connection") } }
}


private struct ConnectionEditRequest: Identifiable {
    let id = UUID()
    var item: SessionTreeNode?
    let parent: UUID?
}
