import Foundation
import Combine
import Network

/// Native, credential-free catalog. This format is not an original profile-folder format.
public struct SavedConnection: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var proxyHost: String?
    public var proxyPort: Int?
    /// SOCKS4, SOCKS5, or HTTP CONNECT. Saved catalogs from before this field mean SOCKS5.
    public var proxyKind: ProxyKind?
    public var identityPath: String?
    var opensFiles: Bool?
    public var jumpSessionID: UUID?
    /// Offers the SSH agent's keys before the identity file.
    public var usesAgent: Bool?
    /// An agent socket other than `SSH_AUTH_SOCK`, such as one named by `IdentityAgent` in an OpenSSH config.
    public var agentSocket: String?
    var forwardingRules: [ForwardingRule]?
    /// Asks for Touch ID or the Mac password before every connection that uses a saved password or key, unless the
    /// password vault is unlocked. A new session starts with it on; sessions saved before it existed keep it off.
    public var confirmsEachConnection: Bool?
    var asksEachConnection: Bool { confirmsEachConnection == true }
    public init(host: String, port: Int = 22, username: String, proxyHost: String? = nil, proxyPort: Int? = nil, identityPath: String? = nil, opensFiles: Bool = false, jumpSessionID: UUID? = nil,
                usesAgent: Bool = false, agentSocket: String? = nil, proxyKind: ProxyKind = .socks5,
                confirmsEachConnection: Bool = false) {
        self.host = host; self.port = port; self.username = username
        self.proxyHost = proxyHost; self.proxyPort = proxyPort; self.identityPath = identityPath
        self.opensFiles = opensFiles ? true : nil
        self.jumpSessionID = jumpSessionID
        self.usesAgent = usesAgent ? true : nil
        self.agentSocket = usesAgent ? agentSocket : nil
        self.proxyKind = proxyHost == nil || proxyKind == .socks5 || proxyKind == .none ? nil : proxyKind
        self.confirmsEachConnection = confirmsEachConnection ? true : nil
    }
    /// The proxy this connection dials, or `.direct`.
    var proxy: ProxyConfiguration {
        guard let proxyHost, let proxyPort else { return .direct }
        return ProxyConfiguration(kind: proxyKind ?? .socks5, host: proxyHost, port: proxyPort)
    }
    /// Signs in with keys only: an identity file, the SSH agent, or both.
    var usesKeys: Bool { identityPath != nil || usesAgent == true }
    func validate() throws {
        if let forwardingRules { try ForwardingRule.validateSaved(forwardingRules) }
        if jumpSessionID != nil && proxyHost != nil {
            throw WorkspaceError.invalid("Set the proxy on the jump host rather than on the destination.")
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !username.isEmpty,
              (1...65535).contains(port), (proxyHost == nil) == (proxyPort == nil),
              proxyPort.map({ (1...65535).contains($0) }) ?? true,
              proxyHost.map({ !$0.isEmpty }) ?? true,
              identityPath.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              agentSocket.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true else { throw WorkspaceError.invalid("Invalid saved connection settings.") }
    }
}

public struct SessionTreeNode: Codable, Identifiable, Equatable {
    public let id: UUID
    public var parent: UUID?
    public var name: String
    public var connection: SavedConnection?
    public var expanded: Bool
    public var isFolder: Bool { connection == nil }
    public init(id: UUID = UUID(), parent: UUID? = nil, name: String, connection: SavedConnection? = nil, expanded: Bool = true) {
        self.id = id; self.parent = parent; self.name = name; self.connection = connection; self.expanded = expanded
    }
}

@MainActor public final class SessionTreeStore: ObservableObject {
    private struct Document: Codable { var version = 1; var nodes: [SessionTreeNode] }
    @Published public private(set) var nodes: [SessionTreeNode]
    @Published public var selection: UUID?
    @Published public var query = ""
    @Published public private(set) var clipboard: UUID?
    @Published public private(set) var cutting = false
    private let url: URL
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            let bytes = try h.read(upToCount: 4_194_305) ?? Data()
            guard bytes.count <= 4_194_304 else { throw WorkspaceError.invalid("Session catalog exceeds 4 MiB.") }
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1 else { throw WorkspaceError.invalid("Unsupported session catalog version.") }
            try Self.validate(document.nodes); nodes = document.nodes
        } else { nodes = [] }
    }
    public func node(_ id: UUID?) -> SessionTreeNode? { nodes.first { $0.id == id } }
    /// The longest jump chain a session may use: up to this many hosts before the destination.
    nonisolated static let maximumJumpHops = 8

    /// Saved sessions that can serve as a jump host for `id`: anything whose own chain is valid and never passes
    /// back through `id`.
    func jumpCandidates(excluding id: UUID?) -> [SessionTreeNode] {
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return nodes.filter { node in
            guard node.id != id, node.connection != nil, let chain = Self.jumpChain(from: node.id, in: indexed) else { return false }
            return !chain.contains { $0.id == id } && chain.count < Self.maximumJumpHops
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The jump hosts a connection passes through, first hop (the one MShell dials) first.
    /// Returns nil when a link is missing, loops, or exceeds the limit.
    func jumpChain(for connection: SavedConnection, excluding id: UUID?) -> [SavedConnection]? {
        var indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let start = id ?? UUID()
        indexed[start] = SessionTreeNode(id: start, name: "_", connection: connection)
        return Self.jumpChain(from: start, in: indexed)?.compactMap(\.connection)
    }

    /// Hosts reached before `id`, ordered from the first hop to the last. The node itself is not included.
    static func jumpChain(from id: UUID, in indexed: [UUID: SessionTreeNode]) -> [SessionTreeNode]? {
        var chain: [SessionTreeNode] = []
        var seen: Set<UUID> = [id]
        var next = indexed[id]?.connection?.jumpSessionID
        while let current = next {
            guard seen.insert(current).inserted, chain.count < maximumJumpHops,
                  let node = indexed[current], node.connection != nil else { return nil }
            chain.append(node)
            next = node.connection?.jumpSessionID
        }
        return chain.reversed()
    }

    public func children(of parent: UUID?) -> [SessionTreeNode] {
        nodes.filter { $0.parent == parent }.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    public var destination: UUID? {
        guard let current = node(selection) else { return nil }
        return current.isFolder ? current.id : current.parent
    }
    public func matches(_ id: UUID) -> Bool {
        guard let current = node(id) else { return false }
        if query.isEmpty || current.name.localizedCaseInsensitiveContains(query) || current.connection?.host.localizedCaseInsensitiveContains(query) == true { return true }
        return children(of: id).contains { matches($0.id) }
    }
    private func commit(_ updated: [SessionTreeNode]) throws {
        try Self.validate(updated)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(nodes: updated))
        guard data.count <= 4_194_304 else { throw WorkspaceError.invalid("Session catalog exceeds 4 MiB.") }
        try writePrivate(data, to: url); nodes = updated
    }
    private static func validate(_ nodes: [SessionTreeNode]) throws {
        guard nodes.count <= 5000, Set(nodes.map(\.id)).count == nodes.count else { throw WorkspaceError.invalid("Invalid or oversized session tree.") }
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var names = Set<String>()
        for node in nodes {
            let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 160, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), name == node.name else {
                throw WorkspaceError.invalid("Use a name of 1–160 characters without path separators or control characters.")
            }
            let key = (node.parent?.uuidString ?? "root") + "/" + nameKey(name)
            guard names.insert(key).inserted else { throw WorkspaceError.invalid("An item with that name already exists here.") }
            try node.connection?.validate()
            if node.connection?.jumpSessionID != nil {
                guard jumpChain(from: node.id, in: indexed) != nil else {
                    throw WorkspaceError.invalid("Jump hosts must not loop and can chain at most 8 hosts.")
                }
            }
            var parent = node.parent, visited: Set<UUID> = [node.id]
            while let id = parent {
                guard visited.count < 65, visited.insert(id).inserted, let folder = indexed[id], folder.isFolder else {
                    throw WorkspaceError.invalid("Invalid parent, cycle or folder depth exceeds 64.")
                }
                parent = folder.parent
            }
        }
    }
    @discardableResult public func add(name: String, parent: UUID?, connection: SavedConnection? = nil) throws -> UUID {
        let item = SessionTreeNode(parent: parent, name: name, connection: connection)
        var updated = nodes
        if let index = updated.firstIndex(where: { $0.id == parent && $0.isFolder }) { updated[index].expanded = true }
        try commit(updated + [item]); selection = item.id; return item.id
    }
    public func rename(_ id: UUID, to name: String) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.invalid("Item no longer exists.") }
        var updated = nodes; updated[index].name = name; try commit(updated)
    }
    func updateConnection(_ id: UUID, name: String, connection: SavedConnection) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id && !$0.isFolder }) else {
            throw WorkspaceError.invalid("Item no longer exists.")
        }
        var updated = nodes
        updated[index].name = name
        updated[index].connection = connection
        try commit(updated)
    }

    @discardableResult func importProfiles(_ draft: ProfileImport, name: String, parent: UUID?) throws -> UUID {
        guard !draft.entries.isEmpty else { throw WorkspaceError.invalid("No compatible profiles were found.") }
        let root = SessionTreeNode(parent: parent, name: name)
        var updated = nodes
        if let index = updated.firstIndex(where: { $0.id == parent && $0.isFolder }) {
            updated[index].expanded = true
        }
        updated.append(root)
        var folders: [[String]: UUID] = [:]
        var names: [UUID: Set<String>] = [:]
        var imported: [[String]: UUID] = [:]
        @discardableResult func append(_ name: String, to parent: UUID, connection: SavedConnection? = nil) -> UUID {
            let safeName = Self.importName(name)
            var candidate = safeName
            var index = 2
            while !names[parent, default: []].insert(Self.nameKey(candidate)).inserted {
                let suffix = " (\(index))"
                candidate = String(safeName.prefix(160 - suffix.count)) + suffix
                index += 1
            }
            let item = SessionTreeNode(parent: parent, name: candidate, connection: connection)
            updated.append(item)
            return item.id
        }
        for path in draft.folders {
            let parentPath = Array(path.dropLast())
            let parentID = folders[parentPath] ?? root.id
            if let folderName = path.last { folders[path] = append(folderName, to: parentID) }
        }
        for entry in draft.entries {
            let folder = folders[Array(entry.components.dropLast())] ?? root.id
            imported[entry.components] = append(entry.name, to: folder, connection: entry.connection)
        }
        for entry in draft.entries {
            guard let jump = entry.jump, let target = imported[jump], let id = imported[entry.components],
                  let index = updated.firstIndex(where: { $0.id == id }) else { continue }
            updated[index].connection?.jumpSessionID = target
        }
        try commit(updated)
        selection = root.id
        query = ""
        return root.id
    }

    func availableImportName(_ base: String, parent: UUID?) -> String {
        let siblings = Set(nodes.filter { $0.parent == parent }.map { Self.nameKey($0.name) })
        let base = Self.importName(base)
        var candidate = base
        var index = 2
        while siblings.contains(Self.nameKey(candidate)) {
            let suffix = " (\(index))"
            candidate = String(base.prefix(160 - suffix.count)) + suffix
            index += 1
        }
        return candidate
    }

    private static func importName(_ name: String) -> String {
        let safe = name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == "\\" ? "_" : String(scalar)
        }.joined()
        let trimmed = String(safe.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", ".", ".."].contains(trimmed) ? "_" : trimmed
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func setExpanded(_ id: UUID, _ expanded: Bool) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].isFolder else { return }
        var updated = nodes; updated[index].expanded = expanded; try commit(updated)
    }
    public func expandAll(_ expanded: Bool) throws {
        try commit(nodes.map { var item = $0; if item.isFolder { item.expanded = expanded }; return item })
    }
    private func subtree(_ id: UUID) -> [SessionTreeNode] {
        guard let item = node(id) else { return [] }
        return [item] + children(of: id).flatMap { subtree($0.id) }
    }
    public func connections(in id: UUID?) -> [SessionTreeNode] {
        if let id { return subtree(id).filter { !$0.isFolder } }
        return children(of: nil).flatMap { subtree($0.id) }.filter { !$0.isFolder }
    }
    public func remove(_ id: UUID) throws {
        let ids = Set(subtree(id).map(\.id)); try commit(nodes.filter { !ids.contains($0.id) })
        if let selected = selection, ids.contains(selected) { selection = nil }
        if let copied = clipboard, ids.contains(copied) { clipboard = nil }
    }
    public func prepareClipboard(_ id: UUID, cut: Bool) { clipboard = id; cutting = cut }
    public func paste(into parent: UUID?) throws {
        guard let source = clipboard, node(source) != nil else { throw WorkspaceError.invalid("Copy or cut an item first.") }
        try relocate(source, into: parent, copy: !cutting)
        if cutting { clipboard = nil }
    }
    public func relocate(_ id: UUID, into parent: UUID?, copy: Bool) throws {
        let branch = subtree(id); guard let root = branch.first else { throw WorkspaceError.invalid("Item no longer exists.") }
        guard !branch.contains(where: { $0.id == parent }) else { throw WorkspaceError.invalid("A folder cannot be placed inside itself.") }
        if !copy && root.parent == parent { return }
        var updated = nodes
        if copy {
            let ids = Dictionary(uniqueKeysWithValues: branch.map { ($0.id, UUID()) })
            for item in branch {
                updated.append(SessionTreeNode(id: ids[item.id]!, parent: item.id == id ? parent : item.parent.flatMap { ids[$0] }, name: item.name, connection: item.connection, expanded: item.expanded))
            }
        } else {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
            updated[index].parent = parent
        }
        try commit(updated)
    }
}
