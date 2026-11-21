import Combine
import Foundation

struct QuickCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text
    }

    var validationError: String? {
        guard !name.isEmpty, name.utf8.count <= 240, Self.isSingleLine(name) else {
            return "Enter a short name on one line."
        }
        guard text.utf8.count <= 4096, Self.isSingleLine(text),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a single-line command of up to 4 KiB without control characters."
        }
        return nil
    }

    private static func isSingleLine(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}

@MainActor final class QuickCommandStore: ObservableObject {
    private static let maximumCommands = 256
    private static let maximumFileBytes = 8 * 1024 * 1024
    private let url: URL
    let loadError: String?
    @Published private(set) var entries: [QuickCommand] = []

    init(url: URL) {
        self.url = url
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard data.count <= Self.maximumFileBytes else { throw WorkspaceError.invalid("Quick command file is too large.") }
            let commands = try JSONDecoder().decode([QuickCommand].self, from: data)
            guard commands.count <= Self.maximumCommands, Set(commands.map(\.id)).count == commands.count,
                  commands.allSatisfy({ $0.validationError == nil }) else { throw WorkspaceError.invalid("Invalid quick command file.") }
            entries = commands
            loadError = nil
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            loadError = nil
        } catch {
            loadError = "Couldn’t read saved commands. Check quick-commands.json in the workspace folder, then reopen MShell."
        }
    }

    func matching(_ query: String) -> [QuickCommand] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(query) || $0.text.localizedStandardContains(query) }
    }

    func save(_ command: QuickCommand) throws {
        if let error = command.validationError { throw WorkspaceError.invalid(error) }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == command.id }) {
            updated[index] = command
        } else {
            guard updated.count < Self.maximumCommands else { throw WorkspaceError.invalid("You can save up to 256 quick commands.") }
            updated.append(command)
        }
        try persist(updated)
    }

    func remove(_ id: UUID) throws {
        try persist(entries.filter { $0.id != id })
    }

    private func persist(_ commands: [QuickCommand]) throws {
        if let loadError { throw WorkspaceError.invalid(loadError) }
        try writePrivate(JSONEncoder().encode(commands), to: url)
        entries = commands
    }
}

struct QuickCommandRequest: Identifiable {
    let id = UUID()
    let command: QuickCommand
    let tabID: UUID
    let epoch: UUID
    let terminalID: UUID
    let destination: String
}

extension WorkspaceModel {
    func quickCommandDestination(for tab: SessionTab) -> String {
        let number = (tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        let name = tab.isLocal ? "127.0.0.1" : tab.credentialID
        return String(format: T("Tab %d · %@"), number, name)
    }

    func prepareQuickCommand(_ command: QuickCommand, for tab: SessionTab) -> QuickCommandRequest? {
        guard command.validationError == nil, selection == tab.id, tab.canReceiveQuickCommands(in: layout) else { return nil }
        return QuickCommandRequest(command: command, tabID: tab.id, epoch: tab.epoch, terminalID: tab.terminalID,
                                   destination: quickCommandDestination(for: tab))
    }

    @discardableResult func sendQuickCommand(_ request: QuickCommandRequest, run: Bool) -> Bool {
        guard let tab = selected, tab.id == request.tabID, tab.epoch == request.epoch,
              tab.canReceiveQuickCommands(in: layout), tab.terminalID == request.terminalID,
              var bytes = TerminalKeyboard.pasteBytes(request.command.text, bracketed: tab.screen.bracketedPaste) else { return false }
        if run { bytes.append(0x0D) }
        guard enqueueTerminalInput(tab, bytes: bytes) else { return false }
        selectTab(tab.id)
        return true
    }
}

extension SessionTab {
    func canReceiveQuickCommands(in layout: WorkspaceLayout) -> Bool {
        // Files no longer replace the terminal in any layout, so a ready shell can always take a command.
        terminalReady && (isLocal ? localShell != nil : shell != nil)
    }
}
