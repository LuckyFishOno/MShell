import SwiftUI

struct ProfileImportView: View {
    @Environment(\.dismiss) private var dismiss
    let store: SessionTreeStore
    let source: URL
    let parent: UUID?
    @State private var draft: ProfileImport?
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(T("Import Xshell folder"), systemImage: "folder.badge.plus").font(.title2.weight(.semibold))
            Text(source.lastPathComponent).foregroundStyle(.secondary)
            if let draft {
                LabeledContent(T("Folder name")) { TextField(T("Folder name"), text: $name).labelsHidden() }
                Text(T("Review the sessions below. Credentials and host trust must be set in MShell."))
                    .font(.callout).foregroundStyle(.secondary)
                List {
                    Section(String(format: T("%d ready to import"), draft.entries.count)) {
                        ForEach(draft.entries, id: \.components) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.path)
                                Text(verbatim: "\(entry.connection.username)@\(entry.connection.host):\(entry.connection.port)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                ForEach(entry.notes, id: \.self) { Text(T($0)).font(.caption).foregroundStyle(.orange) }
                            }.padding(.vertical, 3)
                        }
                    }
                    if !draft.skipped.isEmpty {
                        Section(String(format: T("%d skipped"), draft.skipped.count)) {
                            ForEach(draft.skipped, id: \.path) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.path)
                                    Text(T(item.reason)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else if error == nil {
                ProgressView(T("Reading profiles…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let error { Text(T(error)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(T("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("Import")) { commit() }.keyboardShortcut(.defaultAction)
                    .disabled(draft?.entries.isEmpty != false || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600, height: 475)
        .task(id: source) {
            let scan = Task.detached(priority: .userInitiated) { try ProfileImport.scan(source) }
            do {
                let preview = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                try Task.checkCancellation()
                draft = preview
                name = store.availableImportName(preview.name, parent: parent)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func commit() {
        guard let draft else { return }
        do {
            try store.importProfiles(draft, name: name.trimmingCharacters(in: .whitespacesAndNewlines), parent: parent)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
