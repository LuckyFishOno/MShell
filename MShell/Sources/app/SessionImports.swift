import Foundation
import Network

// Session imports from other SSH clients and from files MShell exports. Each reader produces a `ProfileImport`, so
// every format is reviewed in the same preview sheet before anything is saved. Passwords are never read: the
// formats that carry them keep them encrypted, and MShell asks for them on the first connection instead.

/// Reads an import file as text, whatever Windows encoding wrote it.
enum ImportText {
    static let limit = 4_194_304

    static func read(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw WorkspaceError.invalid("Select a smaller file. The import limit is 4 MiB.") }
        return decode(data)
    }

    /// UTF-16 or UTF-8 with or without a byte order mark, then the code pages Windows uses in Taiwan and China, then
    /// Western Windows. MobaXterm and older PuTTY exports are written in the system code page.
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        // regedit writes UTF-16 without a mark in some tools: every other byte of ASCII text is zero.
        if data.count >= 4, data[data.startIndex + 1] == 0, data[data.startIndex + 3] == 0,
           let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        for encoding in [CFStringEncodings.dosChineseTrad, .GB_18030_2000] {
            let converted = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: converted)) { return text }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    /// `~/…` as this Mac's home folder, so shared files can name keys without a user's own path.
    static func expandHome(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        let expanded = path == "~" || path.hasPrefix("~/") ? (path as NSString).expandingTildeInPath : path
        return expanded.hasPrefix("/") && !expanded.contains("\0") ? expanded : nil
    }
}

/// Collects folders, sessions, and the jump hosts they pass through, then hands them over as one `ProfileImport`.
struct ImportCollector {
    static let jumpFolder = "Jump hosts"

    private(set) var folders: [[String]] = []
    private(set) var entries: [ProfileImport.Entry] = []
    var skipped: [ProfileImport.Skipped] = []
    private var taken: Set<[String]> = []

    mutating func addFolder(_ path: [String]) {
        for length in path.indices.map({ $0 + 1 }) {
            let prefix = Array(path.prefix(length))
            if !folders.contains(prefix) { folders.append(prefix) }
        }
    }

    /// Adds a session under `folder`, renaming it when the folder already has one by that name. Returns its path.
    @discardableResult
    mutating func add(_ name: String, in folder: [String], connection: SavedConnection, notes: [String] = [],
                      jump: [String]? = nil) -> [String] {
        if !folder.isEmpty { addFolder(folder) }
        var candidate = name, index = 2
        while taken.contains(folder + [candidate]) { candidate = "\(name) (\(index))"; index += 1 }
        let components = folder + [candidate]
        taken.insert(components)
        entries.append(.init(components: components, name: candidate, connection: connection, notes: notes, jump: jump))
        return components
    }

    /// A jump host saved as its own session in the "Jump hosts" folder, shared by every session that passes through
    /// it. `previous` is the hop before it, for a chain of gateways.
    mutating func hop(host: String, port: Int, username: String, previous: [String]?) throws -> [String] {
        let label = "\(username)@\(host)" + (port == 22 ? "" : ":\(port)")
        let components = [Self.jumpFolder, label]
        if taken.contains(components) { return components }
        let connection = SavedConnection(host: host, port: port, username: username)
        try connection.validate()
        return add(label, in: [Self.jumpFolder], connection: connection, jump: previous)
    }

    mutating func link(_ components: [String], to jump: [String]) {
        guard let index = entries.firstIndex(where: { $0.components == components }) else { return }
        let entry = entries[index]
        entries[index] = .init(components: entry.components, name: entry.name, connection: entry.connection, notes: entry.notes, jump: jump)
    }

    func result(name: String) -> ProfileImport {
        // The jump host folder goes last, under the sessions that use it.
        let ordered = folders.filter { $0.first != Self.jumpFolder } + folders.filter { $0.first == Self.jumpFolder }
        return ProfileImport(name: name, folders: ordered, entries: OpenSSHConfigImport.breakCycles(entries), skipped: skipped)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - MobaXterm

/// Reads a MobaXterm session export (`.mxtsessions`) or the `[Bookmarks]` sections of `MobaXterm.ini`.
///
/// Each session is one `Name=#icon#fields%…#…` line; fields are `%`-separated. SSH sessions (type 0) and SFTP
/// sessions (type 7) are imported with their folder, user, port, SSH gateways, and SOCKS or HTTP proxy. Field
/// positions follow MobaXterm's own export, which is not publicly documented, so short lines are accepted.
enum MobaXtermImport {
    static func scan(_ url: URL, localUser: String = NSUserName()) throws -> ProfileImport {
        try parse(ImportText.read(url), name: url.deletingPathExtension().lastPathComponent, localUser: localUser)
    }

    static func parse(_ text: String, name: String, localUser: String = NSUserName()) throws -> ProfileImport {
        var collector = ImportCollector()
        var inBookmarks = false
        var folder: [String] = []
        var found = false
        for raw in ImportText.lines(text) {
            let line = raw.trimmed
            if line.hasPrefix("[") {
                let section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
                inBookmarks = section == "bookmarks" || section.hasPrefix("bookmarks_")
                folder = []
                continue
            }
            guard inBookmarks, let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmed, value = String(line[line.index(after: equals)...])
            switch key.lowercased() {
            case "subrep":
                folder = value.split(separator: "\\").map { String($0).trimmed }.filter { !$0.isEmpty }
                if !folder.isEmpty { collector.addFolder(folder) }
            case "imgnum":
                continue
            default:
                guard value.contains("#") else { continue }
                found = true
                session(key, value: value, folder: folder, localUser: localUser, into: &collector)
            }
        }
        guard found else { throw WorkspaceError.invalid("No MobaXterm sessions were found in this file.") }
        return collector.result(name: name)
    }

    private static func session(_ name: String, value: String, folder: [String], localUser: String, into collector: inout ImportCollector) {
        let path = (folder + [name]).joined(separator: " / ")
        let groups = value.components(separatedBy: "#")
        guard groups.count >= 3 else { return collector.skipped.append(.init(path: path, reason: "The session could not be read.")) }
        let fields = groups[2].components(separatedBy: "%")
        func field(_ index: Int) -> String { index < fields.count ? fields[index].trimmed : "" }
        let type = field(0)
        guard type == "0" || type == "7" else {
            return collector.skipped.append(.init(path: path, reason: "Only SSH and SFTP sessions can be imported."))
        }
        let isSFTP = type == "7"
        let host = field(1)
        guard !host.isEmpty else { return collector.skipped.append(.init(path: path, reason: "The session has no host.")) }
        guard let port = field(2).isEmpty ? 22 : Int(field(2)), (1...65535).contains(port) else {
            return collector.skipped.append(.init(path: path, reason: "Enter a valid port."))
        }
        var notes: [String] = []
        var username = field(3)
        if username.isEmpty || username == "<default>" {
            username = localUser
            notes.append("MobaXterm used the Windows sign-in name for this session. Check the user name.")
        }
        if !field(isSFTP ? 9 : 14).isEmpty {
            notes.append("This session used a key file on Windows. Choose the key in the session properties.")
        }

        // Proxy: SSH sessions name SOCKS4, SOCKS5, and HTTP as 1 to 3; SFTP sessions count the variants with sign-in.
        var proxy: (kind: ProxyKind, host: String, port: Int)?
        let proxyType = Int(field(isSFTP ? 10 : 19)) ?? 0
        let proxyKind: ProxyKind?
        if isSFTP {
            proxyKind = [1: .socks4, 2: .socks4, 3: .socks5, 4: .socks5, 5: .http, 6: .http, 7: .http, 8: .http][proxyType]
        } else {
            proxyKind = [1: .socks4, 2: .socks5, 3: .http][proxyType]
        }
        if proxyType != 0 {
            guard let proxyKind else {
                return collector.skipped.append(.init(path: path, reason: "This session uses a proxy type MShell does not support."))
            }
            let proxyHost = field(isSFTP ? 11 : 20)
            guard !proxyHost.isEmpty, let proxyPort = Int(field(isSFTP ? 12 : 21)), (1...65535).contains(proxyPort) else {
                return collector.skipped.append(.init(path: path, reason: "The proxy settings could not be read."))
            }
            proxy = (proxyKind, proxyHost, proxyPort)
            if !field(isSFTP ? 13 : 22).isEmpty {
                notes.append("The proxy sign-in was not imported. MShell connects to proxies without a password.")
            }
        }

        // SSH gateways, first hop first. Several hops are separated by __PIPE__.
        var previous: [String]?
        if !isSFTP, !field(8).isEmpty {
            let hosts = field(8).components(separatedBy: "__PIPE__"), ports = field(9).components(separatedBy: "__PIPE__")
            let users = field(10).components(separatedBy: "__PIPE__")
            do {
                for (index, gatewayHost) in hosts.enumerated() where !gatewayHost.trimmed.isEmpty {
                    let gatewayPort = index < ports.count ? Int(ports[index].trimmed) ?? 22 : 22
                    let gatewayUser = index < users.count && !users[index].trimmed.isEmpty ? users[index].trimmed : username
                    let hop = try collector.hop(host: gatewayHost.trimmed, port: gatewayPort, username: gatewayUser, previous: previous)
                    // A proxy reaches the first gateway, which then reaches the session.
                    if previous == nil, let proxy { collector.setProxy(hop, proxy) }
                    previous = hop
                }
            } catch {
                return collector.skipped.append(.init(path: path, reason: "The SSH gateway settings could not be read."))
            }
        }
        let connection = SavedConnection(host: host, port: port, username: username,
                                         proxyHost: previous == nil ? proxy?.host : nil, proxyPort: previous == nil ? proxy?.port : nil,
                                         opensFiles: isSFTP, proxyKind: previous == nil ? proxy?.kind ?? .socks5 : .socks5)
        do { try connection.validate() } catch {
            return collector.skipped.append(.init(path: path, reason: "Invalid saved connection settings."))
        }
        collector.add(name, in: folder, connection: connection, notes: notes, jump: previous)
    }
}

extension ImportCollector {
    mutating func setProxy(_ components: [String], _ proxy: (kind: ProxyKind, host: String, port: Int)) {
        guard let index = entries.firstIndex(where: { $0.components == components }), entries[index].jump == nil else { return }
        let entry = entries[index]
        var connection = entry.connection
        connection.proxyHost = proxy.host; connection.proxyPort = proxy.port
        connection.proxyKind = proxy.kind == .socks5 ? nil : proxy.kind
        entries[index] = .init(components: entry.components, name: entry.name, connection: connection, notes: entry.notes, jump: entry.jump)
    }
}

// MARK: - PuTTY

/// Reads PuTTY or KiTTY sessions exported from the Windows registry (`reg export HKCU\Software\SimonTatham\PuTTY`).
///
/// SSH sessions are imported with their user, port, SOCKS or HTTP proxy, SSH proxy (as a jump host), and port
/// forwards. PuTTY has no folders; the sessions land in the folder named in the preview.
enum PuTTYImport {
    static func scan(_ url: URL, localUser: String = NSUserName()) throws -> ProfileImport {
        try parse(ImportText.read(url), localUser: localUser)
    }

    static func parse(_ text: String, localUser: String = NSUserName()) throws -> ProfileImport {
        var sessions: [(name: String, values: [String: RegistryValue])] = []
        var current: Int?
        var pending = ""
        for raw in ImportText.lines(text) {
            // Long hex values continue on the next line after a backslash.
            var line = pending + raw.trimmed
            if line.hasSuffix("\\") && !line.hasPrefix("[") { pending = String(line.dropLast()); continue }
            pending = ""
            line = line.trimmed
            if line.hasPrefix("[") {
                current = nil
                guard !line.hasPrefix("[-"), let range = line.range(of: "\\Sessions\\", options: .caseInsensitive) else { continue }
                let encoded = String(line[range.upperBound...].dropLast())
                guard !encoded.isEmpty, !encoded.contains("\\") else { continue }
                let name = encoded.removingPercentEncoding ?? encoded
                sessions.append((name, [:])); current = sessions.count - 1
            } else if let current, let (key, value) = RegistryValue.parse(line) {
                sessions[current].values[key.lowercased()] = value
            }
        }
        guard !sessions.isEmpty else { throw WorkspaceError.invalid("No PuTTY sessions were found in this file.") }

        var collector = ImportCollector()
        for (name, values) in sessions where name != "Default Settings" {
            func string(_ key: String) -> String { values[key.lowercased()]?.string?.trimmed ?? "" }
            func number(_ key: String) -> Int? { values[key.lowercased()]?.number }
            let protocolName = string("Protocol").lowercased()
            guard protocolName.isEmpty || protocolName == "ssh" else {
                collector.skipped.append(.init(path: name, reason: "Only SSH sessions can be imported.")); continue
            }
            var host = string("HostName"), username = string("UserName")
            if let at = host.lastIndex(of: "@") {
                if username.isEmpty { username = String(host[..<at]) }
                host = String(host[host.index(after: at)...])
            }
            guard !host.isEmpty else { collector.skipped.append(.init(path: name, reason: "The session has no host.")); continue }
            let port = number("PortNumber") ?? 22
            guard (1...65535).contains(port) else { collector.skipped.append(.init(path: name, reason: "Enter a valid port.")); continue }
            var notes: [String] = []
            if username.isEmpty {
                username = localUser
                notes.append("PuTTY asks for the user name when this session connects. Check the user name.")
            }
            if !string("PublicKeyFile").isEmpty {
                notes.append("This session used a key file on Windows. Choose the key in the session properties.")
            }

            var connection = SavedConnection(host: host, port: port, username: username)
            var jump: [String]?
            let proxyHost = string("ProxyHost"), proxyPort = number("ProxyPort") ?? 80
            switch number("ProxyMethod") ?? 0 {
            case 0: break
            case let method where (1...3).contains(method):
                guard !proxyHost.isEmpty, (1...65535).contains(proxyPort) else {
                    collector.skipped.append(.init(path: name, reason: "The proxy settings could not be read.")); continue
                }
                connection.proxyHost = proxyHost; connection.proxyPort = proxyPort
                connection.proxyKind = [1: ProxyKind.socks4, 3: .http][method]
                if !string("ProxyUsername").isEmpty {
                    notes.append("The proxy sign-in was not imported. MShell connects to proxies without a password.")
                }
            case 6:
                // PuTTY 0.77 and later: reach the host through another SSH server, which MShell calls a jump host.
                do {
                    jump = try collector.hop(host: proxyHost, port: values["proxyport"] == nil ? 22 : proxyPort,
                                             username: string("ProxyUsername").isEmpty ? username : string("ProxyUsername"), previous: nil)
                } catch { collector.skipped.append(.init(path: name, reason: "The SSH proxy settings could not be read.")); continue }
            default:
                collector.skipped.append(.init(path: name, reason: "This session uses a proxy type MShell does not support.")); continue
            }
            let (rules, ignored) = forwards(string("PortForwardings"))
            if !rules.isEmpty { connection.forwardingRules = rules }
            if ignored { notes.append("Some port forwards were not imported. Review them in the session's port forwarding.") }
            do { try connection.validate() } catch {
                collector.skipped.append(.init(path: name, reason: "Invalid saved connection settings.")); continue
            }
            collector.add(name, in: [], connection: connection, notes: notes, jump: jump)
        }
        return collector.result(name: "PuTTY sessions")
    }

    /// PuTTY's `PortForwardings`: `L8080=db:5432,R9000=localhost:3000,D1080`. Forwards bound to a specific address or
    /// limited to IPv4 or IPv6 are left out, since MShell listens on loopback only.
    static func forwards(_ text: String) -> (rules: [ForwardingRule], ignored: Bool) {
        var rules: [ForwardingRule] = [], ignored = false
        for item in text.split(separator: ",").map({ String($0).trimmed }) where !item.isEmpty {
            guard let kind = ["L": ForwardingKind.local, "R": .remote, "D": .dynamic][String(item.prefix(1)).uppercased()] else {
                ignored = true; continue
            }
            let body = item.dropFirst()
            let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
            guard let listen = parts.first, let listenPort = Int(listen), rules.count < 16 else { ignored = true; continue }
            if kind == .dynamic {
                if parts.count == 1 { rules.append(ForwardingRule(kind: .dynamic, listenPort: listenPort)) } else { ignored = true }
                continue
            }
            guard parts.count == 2, let colon = parts[1].lastIndex(of: ":"), let port = Int(parts[1][parts[1].index(after: colon)...]) else {
                ignored = true; continue
            }
            let host = String(parts[1][..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let rule = ForwardingRule(kind: kind, listenPort: listenPort, host: host, port: port)
            if (try? rule.validate()) != nil { rules.append(rule) } else { ignored = true }
        }
        return (rules, ignored)
    }
}

/// One value line of a `.reg` file: `"Name"="text"` or `"Name"=dword:00000016`.
enum RegistryValue: Equatable {
    case string(String), number(Int)

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Int? { if case .number(let value) = self { return value }; return nil }

    static func parse(_ line: String) -> (String, RegistryValue)? {
        guard line.hasPrefix("\""), let (key, rest) = quoted(line.dropFirst()), rest.hasPrefix("=") else { return nil }
        let value = rest.dropFirst()
        if value.hasPrefix("\""), let (text, _) = quoted(value.dropFirst()) { return (key, .string(text)) }
        if value.lowercased().hasPrefix("dword:"), let number = Int(value.dropFirst(6), radix: 16) { return (key, .number(number)) }
        return nil
    }

    /// Reads up to the closing quote, undoing `\\` and `\"`. Returns the text and what follows the quote.
    private static func quoted(_ text: Substring) -> (String, Substring)? {
        var result = "", escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { return (result, text[text.index(after: index)...]) }
            else { result.append(character) }
        }
        return nil
    }
}

// MARK: - CSV

/// Reads sessions from a spreadsheet saved as CSV. The first row names the columns; `host` is required and the
/// others are optional: `folder` (`Team/Production`), `name`, `port`, `username`, `protocol` (`ssh` or `sftp`),
/// `identity file`, `proxy type` (`socks4`, `socks5`, or `http`), `proxy host`, `proxy port`, and `jump` (another
/// row's `folder/name`, or `user@host:port`). Commas, semicolons, or tabs separate the columns.
enum CSVSessionImport {
    static let columns = ["folder", "name", "host", "port", "username", "protocol", "identity file",
                          "proxy type", "proxy host", "proxy port", "jump"]

    private static let aliases: [String: String] = [
        "folder": "folder", "path": "folder", "group": "folder", "name": "name", "session": "name", "sessionname": "name",
        "label": "name", "host": "host", "hostname": "host", "address": "host", "server": "host", "port": "port",
        "username": "username", "user": "username", "login": "username", "protocol": "protocol", "type": "protocol",
        "identityfile": "identity file", "key": "identity file", "keyfile": "identity file", "privatekey": "identity file",
        "proxytype": "proxy type", "proxyhost": "proxy host", "proxyport": "proxy port", "jump": "jump",
        "jumphost": "jump", "proxyjump": "jump"
    ]

    static func scan(_ url: URL, localUser: String = NSUserName()) throws -> ProfileImport {
        try parse(ImportText.read(url), name: url.deletingPathExtension().lastPathComponent, localUser: localUser)
    }

    static func parse(_ text: String, name: String, localUser: String = NSUserName()) throws -> ProfileImport {
        let rows = records(text)
        guard let header = rows.first else { throw WorkspaceError.invalid("The CSV file is empty.") }
        var index: [String: Int] = [:]
        var collector = ImportCollector()
        for (position, title) in header.enumerated() {
            let key = title.lowercased().filter { $0.isLetter || $0.isNumber }
            if let column = aliases[key], index[column] == nil { index[column] = position }
            if key.contains("password") || key.contains("passphrase") {
                collector.skipped.append(.init(path: title, reason: "Passwords are not imported. MShell asks for them when you connect."))
            }
        }
        guard index["host"] != nil else { throw WorkspaceError.invalid("The CSV file needs a host column.") }

        struct Row { let line: Int; let folder: [String]; let name: String; let values: [String: String] }
        var parsed: [Row] = []
        for (offset, record) in rows.dropFirst().enumerated() where record.contains(where: { !$0.trimmed.isEmpty }) {
            var values: [String: String] = [:]
            for (column, position) in index where position < record.count {
                // MShell's export puts an apostrophe before text a spreadsheet would read as a formula.
                var value = record[position].trimmed
                if value.hasPrefix("'"), let next = value.dropFirst().first, "=+@".contains(next) { value.removeFirst() }
                values[column] = value
            }
            let folder = (values["folder"] ?? "").split(separator: "/").map { String($0).trimmed }.filter { !$0.isEmpty }
            let host = values["host"] ?? ""
            parsed.append(Row(line: offset + 2, folder: folder, name: (values["name"] ?? "").isEmpty ? host : values["name"]!, values: values))
        }
        guard !parsed.isEmpty else { throw WorkspaceError.invalid("The CSV file has no sessions.") }

        var added: [String: [String]] = [:]
        var jumps: [([String], String)] = []
        for row in parsed {
            let path = String(format: T("Line %d"), row.line) + (row.name.isEmpty ? "" : " · \(row.name)")
            let values = row.values
            let protocolName = (values["protocol"] ?? "").lowercased()
            guard protocolName.isEmpty || protocolName == "ssh" || protocolName == "sftp" else {
                collector.skipped.append(.init(path: path, reason: "Only SSH and SFTP sessions can be imported.")); continue
            }
            guard let host = values["host"], !host.isEmpty else {
                collector.skipped.append(.init(path: path, reason: "The session has no host.")); continue
            }
            guard let port = (values["port"] ?? "").isEmpty ? 22 : Int(values["port"]!), (1...65535).contains(port) else {
                collector.skipped.append(.init(path: path, reason: "Enter a valid port.")); continue
            }
            var notes: [String] = []
            var username = values["username"] ?? ""
            if username.isEmpty { username = localUser; notes.append("No user name was given. Check the user name.") }
            var identity = ImportText.expandHome(values["identity file"])
            if identity == nil, !(values["identity file"] ?? "").isEmpty {
                notes.append("The key file must be a full path on this Mac. Choose the key in the session properties.")
                identity = nil
            }
            var connection = SavedConnection(host: host, port: port, username: username, identityPath: identity,
                                             opensFiles: protocolName == "sftp")
            if let proxyHost = values["proxy host"], !proxyHost.isEmpty {
                let kind: ProxyKind? = ["socks5": .socks5, "socks": .socks5, "socks4": .socks4, "http": .http, "": .socks5][(values["proxy type"] ?? "").lowercased()]
                guard let kind, let proxyPort = Int(values["proxy port"] ?? ""), (1...65535).contains(proxyPort) else {
                    collector.skipped.append(.init(path: path, reason: "The proxy settings could not be read.")); continue
                }
                connection.proxyHost = proxyHost; connection.proxyPort = proxyPort
                connection.proxyKind = kind == .socks5 ? nil : kind
            }
            guard (try? connection.validate()) != nil else {
                collector.skipped.append(.init(path: path, reason: "Invalid saved connection settings.")); continue
            }
            let components = collector.add(row.name, in: row.folder, connection: connection, notes: notes)
            let key = (row.folder + [row.name]).joined(separator: "/").lowercased()
            if added[key] == nil { added[key] = components }
            if let jump = values["jump"], !jump.isEmpty { jumps.append((components, jump)) }
        }

        // Jumps name another row by folder and name, or a server that is not in the file.
        for (components, jump) in jumps {
            let key = jump.split(separator: "/").map { String($0).trimmed }.joined(separator: "/").lowercased()
            if let target = added[key], target != components { collector.link(components, to: target); continue }
            if let address = Self.address(jump), let hop = try? collector.hop(host: address.host, port: address.port,
                                                                              username: address.user ?? localUser, previous: nil) {
                collector.link(components, to: hop); continue
            }
            collector.addNote(components, "The jump host could not be found in this file. Set the jump host in MShell.")
        }
        return collector.result(name: name)
    }

    /// `user@host:port`, `host:port`, or `user@host`. A bare word is not an address, since it is more likely a session name.
    static func address(_ text: String) -> (user: String?, host: String, port: Int)? {
        var rest = text.trimmed, user: String?
        if let at = rest.lastIndex(of: "@") { user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...]) }
        var port = 22
        if let colon = rest.lastIndex(of: ":"), !rest.hasPrefix("["), let parsed = Int(rest[rest.index(after: colon)...]) {
            port = parsed; rest = String(rest[..<colon])
        } else if user == nil { return nil }
        guard !rest.isEmpty, !rest.contains("/"), (1...65535).contains(port) else { return nil }
        return (user, rest, port)
    }

    /// RFC 4180 records, with the separator picked from the header line.
    static func records(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = [",", ";", "\t"].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        var records: [[String]] = [], record: [String] = [], field = "", quoted = false
        var iterator = text.makeIterator()
        var pendingQuote = false
        while let character = iterator.next() {
            if quoted {
                if pendingQuote {
                    pendingQuote = false
                    if character == "\"" { field.append("\""); continue }
                    quoted = false
                } else if character == "\"" { pendingQuote = true; continue }
                else { field.append(character); continue }
            }
            switch character {
            case "\"" where field.isEmpty: quoted = true
            case separator: record.append(field); field = ""
            case "\n", "\r", "\r\n":
                record.append(field); field = ""
                if record != [""] { records.append(record) }
                record = []
            default: field.append(character)
            }
        }
        if pendingQuote { quoted = false }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        if let first = records.first?.first, first.hasPrefix("\u{FEFF}") { records[0][0] = String(first.dropFirst()) }
        return records
    }
}

extension ImportCollector {
    mutating func addNote(_ components: [String], _ note: String) {
        guard let index = entries.firstIndex(where: { $0.components == components }) else { return }
        let entry = entries[index]
        entries[index] = .init(components: entry.components, name: entry.name, connection: entry.connection,
                               notes: entry.notes + [note], jump: entry.jump)
    }
}

// MARK: - MShell sessions file

/// The file MShell writes with **Export**: folders and sessions with every setting except credentials, for a backup
/// or for teammates. Key and agent paths under the home folder are written as `~/…` and read back as the reader's own.
struct SessionsFile: Codable {
    static let format = "mshell-sessions"
    static let fileExtension = "mshellsessions"

    struct Item: Codable {
        var folder: [String]
        var name: String
        var connection: SavedConnection
        /// Folder and name of the jump host when it is in the same file.
        var jump: [String]?
        /// `user@host:port` of a jump host that was not exported with this session.
        var jumpAddress: String?
    }

    var format = Self.format
    var version = 1
    var name: String
    var exported: Date
    var folders: [[String]]
    var items: [Item]

    static func scan(_ url: URL) throws -> ProfileImport {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ImportText.limit + 1) ?? Data()
        guard data.count <= ImportText.limit else { throw WorkspaceError.invalid("Select a smaller file. The import limit is 4 MiB.") }
        return try read(data)
    }

    static func read(_ data: Data) throws -> ProfileImport {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(Self.self, from: data), file.format == format else {
            throw WorkspaceError.invalid("This is not an MShell sessions file.")
        }
        guard file.version == 1 else { throw WorkspaceError.invalid("This sessions file was written by a newer MShell.") }
        var collector = ImportCollector()
        for folder in file.folders where !folder.isEmpty { collector.addFolder(folder) }
        var paths: [[String]: [String]] = [:]
        var links: [([String], SessionsFile.Item)] = []
        for item in file.items {
            let path = (item.folder + [item.name]).joined(separator: " / ")
            var connection = item.connection
            connection.jumpSessionID = nil
            connection.identityPath = ImportText.expandHome(connection.identityPath)
            connection.agentSocket = connection.usesAgent == true ? ImportText.expandHome(connection.agentSocket) : nil
            guard (try? connection.validate()) != nil else {
                collector.skipped.append(.init(path: path, reason: "Invalid saved connection settings.")); continue
            }
            let components = collector.add(item.name, in: item.folder, connection: connection)
            paths[item.folder + [item.name]] = components
            links.append((components, item))
        }
        for (components, item) in links {
            if let jump = item.jump, let target = paths[jump] { collector.link(components, to: target) }
            else if let address = item.jumpAddress.flatMap(CSVSessionImport.address),
                    let hop = try? collector.hop(host: address.host, port: address.port, username: address.user ?? NSUserName(), previous: nil) {
                collector.link(components, to: hop)
            } else if item.jump != nil {
                collector.addNote(components, "The jump host could not be found in this file. Set the jump host in MShell.")
            }
        }
        return collector.result(name: file.name)
    }
}
