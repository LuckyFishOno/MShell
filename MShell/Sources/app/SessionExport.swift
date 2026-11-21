import Foundation

/// Writes saved sessions for a backup, a teammate, or a spreadsheet.
///
/// The catalog holds no passwords, and none are written: passwords stay in this Mac's keychain and the vault. Key
/// files are referred to by path only, and paths under the home folder are written as `~/…` so the file names no
/// user's own folder.
@MainActor enum SessionExport {
    enum Format: CaseIterable {
        /// Every setting, folders and jump hosts included, for importing into MShell.
        case mshell
        /// One row per session, for spreadsheets and other tools.
        case csv

        var fileExtension: String { self == .mshell ? SessionsFile.fileExtension : "csv" }
    }

    struct Collected {
        var name: String
        var folders: [[String]] = []
        var sessions: [(folder: [String], node: SessionTreeNode)] = []
    }

    /// Everything under `root` (the whole tree when nil), with paths relative to it.
    static func collect(_ store: SessionTreeStore, root: UUID?) -> Collected {
        let top = root.flatMap(store.node)
        var collected = Collected(name: top?.name ?? "MShell sessions")
        func walk(_ parent: UUID?, path: [String]) {
            for child in store.children(of: parent) {
                if child.isFolder {
                    collected.folders.append(path + [child.name])
                    walk(child.id, path: path + [child.name])
                } else {
                    collected.sessions.append((path, child))
                }
            }
        }
        if let top, !top.isFolder { collected.sessions = [([], top)] } else { walk(root, path: []) }
        return collected
    }

    static func data(_ store: SessionTreeStore, root: UUID?, format: Format, now: Date = Date()) throws -> Data {
        let collected = collect(store, root: root)
        guard !collected.sessions.isEmpty || !collected.folders.isEmpty else {
            throw WorkspaceError.invalid("There are no sessions to export.")
        }
        var paths: [UUID: [String]] = [:]
        for session in collected.sessions { paths[session.node.id] = session.folder + [session.node.name] }
        func jump(_ connection: SavedConnection) -> (path: [String]?, address: String?) {
            guard let id = connection.jumpSessionID else { return (nil, nil) }
            if let path = paths[id] { return (path, nil) }
            guard let target = store.node(id)?.connection else { return (nil, nil) }
            return (nil, "\(target.username)@\(target.host)" + (target.port == 22 ? "" : ":\(target.port)"))
        }

        switch format {
        case .mshell:
            let items = collected.sessions.compactMap { session -> SessionsFile.Item? in
                guard var connection = session.node.connection else { return nil }
                let (path, address) = jump(connection)
                connection.jumpSessionID = nil
                connection.identityPath = shareable(connection.identityPath)
                connection.agentSocket = shareable(connection.agentSocket)
                return SessionsFile.Item(folder: session.folder, name: session.node.name, connection: connection,
                                         jump: path, jumpAddress: address)
            }
            let file = SessionsFile(name: collected.name, exported: now, folders: collected.folders, items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(file)
        case .csv:
            var lines = [CSVSessionImport.columns.map(field).joined(separator: ",")]
            for session in collected.sessions {
                guard let connection = session.node.connection else { continue }
                let (path, address) = jump(connection)
                let proxyKind = connection.proxyHost == nil ? "" : (connection.proxyKind ?? .socks5).rawValue
                let row = [session.folder.joined(separator: "/"), session.node.name, connection.host, String(connection.port),
                           connection.username, connection.opensFiles == true ? "sftp" : "ssh",
                           shareable(connection.identityPath) ?? "", proxyKind, connection.proxyHost ?? "",
                           connection.proxyPort.map(String.init) ?? "", path?.joined(separator: "/") ?? address ?? ""]
                lines.append(row.map(field).joined(separator: ","))
            }
            // A byte order mark lets Excel open names in Chinese and other scripts correctly.
            return Data("\u{FEFF}".utf8) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }

    /// `~/…` for a path in the home folder.
    static func shareable(_ path: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path) -> String? {
        guard let path else { return nil }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A CSV field, quoted when needed. Text a spreadsheet would run as a formula gets a leading apostrophe.
    static func field(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+@".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
