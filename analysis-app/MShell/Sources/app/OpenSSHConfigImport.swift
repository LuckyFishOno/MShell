import Foundation
import Darwin
import Network

/// Reads an OpenSSH client configuration (`~/.ssh/config`) into saved sessions.
///
/// Each concrete `Host` alias becomes one session. Settings follow OpenSSH's rule that the first value obtained wins,
/// so `Host *` defaults and later blocks apply only to what is still unset. `Include` is followed; `Match` blocks are
/// skipped. `ProxyJump` destinations become links between saved sessions.
enum OpenSSHConfigImport {
    struct Options {
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        var localUser: String = NSUserName()
        /// Whether `SSH_AUTH_SOCK` names an agent. Hosts without an IdentityFile then sign in with the agent's keys.
        var agentAvailable: Bool = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]?.hasPrefix("/") == true
    }

    /// OpenSSH's default identity files, tried when a host names none.
    static let defaultIdentities = ["id_ed25519", "id_ecdsa", "id_rsa"]

    private struct Block {
        var patterns: [String]
        var settings: [(key: String, values: [String], line: Int)] = []
    }

    static func scan(_ file: URL, options: Options = Options()) throws -> ProfileImport {
        var blocks: [Block] = [Block(patterns: ["*"])]
        var skipped: [ProfileImport.Skipped] = []
        var matchSkipped = false
        try read(file, options: options, depth: 0, blocks: &blocks, skipped: &skipped, matchSkipped: &matchSkipped)

        var aliases: [String] = []
        for block in blocks.dropFirst() {
            for pattern in block.patterns where !pattern.hasPrefix("!") {
                if pattern.contains(where: { "*?".contains($0) }) { continue }
                if !aliases.contains(pattern) { aliases.append(pattern) }
            }
        }
        let wildcards = blocks.dropFirst().flatMap(\.patterns).filter { !$0.hasPrefix("!") && $0.contains(where: { "*?".contains($0) }) }
        for pattern in Set(wildcards).sorted() where pattern != "*" {
            skipped.append(.init(path: "Host \(pattern)", reason: "Wildcard patterns are applied as defaults and not imported as sessions."))
        }

        var entries: [ProfileImport.Entry] = []
        var hops: [[String]: ProfileImport.Entry] = [:]
        var folders: [[String]] = []
        let jumpFolder = "ProxyJump"
        for alias in aliases {
            let values = resolve(alias, in: blocks)
            do {
                let (entry, route) = try entry(alias, values: values, aliases: aliases, blocks: blocks, options: options)
                entries.append(entry)
                for hop in route where hops[hop.components] == nil { hops[hop.components] = hop }
                if route.first?.components.count == 3 { folders.append([jumpFolder, alias]) }
            } catch {
                skipped.append(.init(path: alias, reason: error.localizedDescription))
            }
        }
        let existing = Set(entries.map(\.components))
        let hopEntries = hops.values.filter { !existing.contains($0.components) }.sorted { $0.path < $1.path }
        entries = breakCycles(entries + hopEntries)
        if !folders.isEmpty { folders.insert([jumpFolder], at: 0) }
        return ProfileImport(name: "OpenSSH config", folders: folders, entries: entries, skipped: skipped)
    }

    // MARK: Reading

    private static func read(_ file: URL, options: Options, depth: Int, blocks: inout [Block],
                             skipped: inout [ProfileImport.Skipped], matchSkipped: inout Bool) throws {
        guard depth < 16 else { throw WorkspaceError.invalid("The OpenSSH config includes too many nested files.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw WorkspaceError.invalid("Settings file exceeds 1 MiB.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.invalid("The OpenSSH config is not UTF-8 text.")
        }
        var inMatch = false
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            guard let (key, values) = words(raw), !values.isEmpty || key == "host" else { continue }
            switch key {
            case "host":
                inMatch = false
                blocks.append(Block(patterns: values))
            case "match":
                inMatch = true
                if !matchSkipped {
                    matchSkipped = true
                    skipped.append(.init(path: "Match", reason: "Match blocks are not imported. Review those hosts in MShell."))
                }
            case "include":
                guard !inMatch else { continue }
                for pattern in values {
                    for url in includes(pattern, options: options) {
                        try read(url, options: options, depth: depth + 1, blocks: &blocks,
                                 skipped: &skipped, matchSkipped: &matchSkipped)
                    }
                }
            default:
                guard !inMatch else { continue }
                blocks[blocks.count - 1].settings.append((key, values, offset + 1))
            }
        }
    }

    /// Splits one config line into a lowercased keyword and its arguments. Handles `Key=Value`, quotes, and comments.
    static func words(_ line: String) -> (String, [String])? {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var started = false
        var equals = false
        for character in line {
            if quoted {
                if character == "\"" { quoted = false } else { current.append(character) }
                continue
            }
            switch character {
            case "\"":
                quoted = true; started = true
            case "#" where !started && current.isEmpty:
                return finish(tokens)
            case " ", "\t":
                if started || !current.isEmpty { tokens.append(current); current = ""; started = false }
            case "=" where tokens.isEmpty:
                if started || !current.isEmpty { tokens.append(current); current = ""; started = false }
                equals = true
            case "=" where tokens.count == 1 && !equals && !started:
                equals = true
            default:
                current.append(character); started = true
            }
        }
        if started || !current.isEmpty { tokens.append(current) }
        return finish(tokens)

        func finish(_ tokens: [String]) -> (String, [String])? {
            guard let first = tokens.first else { return nil }
            return (first.lowercased(), Array(tokens.dropFirst()))
        }
    }

    private static func includes(_ pattern: String, options: Options) -> [URL] {
        var path = expandHome(pattern, options: options)
        if !path.hasPrefix("/") { path = options.home.appendingPathComponent(".ssh").appendingPathComponent(path).path }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }.sorted { $0.path < $1.path }
    }

    // MARK: Resolving

    /// Applies every block whose patterns match the alias, keeping the first value of each keyword.
    private static func resolve(_ alias: String, in blocks: [Block]) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for block in blocks where matches(alias, patterns: block.patterns) {
            for setting in block.settings where values[setting.key] == nil {
                values[setting.key] = setting.values
            }
        }
        return values
    }

    static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let body = negated ? String(pattern.dropFirst()) : pattern
            guard fnmatch(body.lowercased(), alias.lowercased(), 0) == 0 else { continue }
            if negated { return false }
            matched = true
        }
        return matched
    }

    private static func entry(_ alias: String, values: [String: [String]], aliases: [String], blocks: [Block],
                              options: Options) throws -> (ProfileImport.Entry, [ProfileImport.Entry]) {
        var notes: [String] = []
        let user = values["user"]?.first.map { tokens($0, alias: alias, host: alias, user: options.localUser, options: options) }
            ?? options.localUser
        let host = values["hostname"]?.first.map { tokens($0, alias: alias, host: alias, user: user, options: options) } ?? alias
        var port = 22
        if let raw = values["port"]?.first {
            guard let value = Int(raw), (1...65535).contains(value) else { throw WorkspaceError.invalid("Enter a valid port.") }
            port = value
        }
        var identity: String?
        if let raw = values["identityfile"]?.first, raw.lowercased() != "none" {
            var path = tokens(raw, alias: alias, host: host, user: user, options: options)
            if !path.hasPrefix("/") { path = options.home.appendingPathComponent(path).path }
            identity = URL(fileURLWithPath: path).standardizedFileURL.path
            if !FileManager.default.fileExists(atPath: identity!) { notes.append("The identity file was not found.") }
        }
        var usesAgent = false
        var agentSocket: String?
        if let raw = values["identityagent"]?.first {
            switch raw {
            case "none", "SSH_AUTH_SOCK": usesAgent = raw != "none" && options.agentAvailable
            default:
                let expanded = raw.hasPrefix("$") ? ProcessInfo.processInfo.environment[String(raw.dropFirst())] ?? "" : raw
                let path = tokens(expanded, alias: alias, host: host, user: user, options: options)
                if path.hasPrefix("/") { usesAgent = true; agentSocket = path }
                else { notes.append("IdentityAgent is not supported in this form. Choose the agent in MShell.") }
            }
        } else if identity == nil && options.agentAvailable && values["identitiesonly"]?.first?.lowercased() != "yes" {
            usesAgent = true
        }
        if identity == nil && !usesAgent { identity = defaultIdentity(options) }
        var proxy: ProxyConfiguration = .direct
        if let command = values["proxycommand"], command.first.map({ $0.lowercased() != "none" }) == true {
            if let parsed = netcatProxy(command) { proxy = parsed }
            else { notes.append("ProxyCommand is not supported. Set a jump host or proxy in MShell.") }
        }
        var jump: [String]?
        var route: [ProfileImport.Entry] = []
        if let raw = values["proxyjump"]?.first, raw.lowercased() != "none" {
            let chain = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if chain.count == 1, let target = aliases.first(where: { $0.caseInsensitiveCompare(chain[0]) == .orderedSame }) {
                jump = [target]
            } else {
                route = try makeRoute(chain, for: alias, blocks: blocks, options: options)
                jump = route.last?.components
            }
        }
        if proxy.kind != .none && jump != nil {
            notes.append("The proxy was left out because this host also uses a jump host.")
            proxy = .direct
        }
        let connection = SavedConnection(host: host, port: port, username: user,
                                         proxyHost: proxy.kind == .none ? nil : proxy.host,
                                         proxyPort: proxy.kind == .none ? nil : proxy.port, identityPath: identity,
                                         usesAgent: usesAgent, agentSocket: agentSocket, proxyKind: proxy.kind)
        try connection.validate()
        return (ProfileImport.Entry(components: [alias], name: alias, connection: connection, notes: notes, jump: jump), route)
    }

    private static func makeRoute(_ chain: [String], for alias: String, blocks: [Block],
                                  options: Options) throws -> [ProfileImport.Entry] {
        guard !chain.isEmpty, chain.count <= SessionTreeStore.maximumJumpHops else {
            throw WorkspaceError.invalid("Jump hosts must not loop and can chain at most 8 hosts.")
        }
        var route: [ProfileImport.Entry] = []
        var seen: Set<String> = [alias.lowercased()]
        for raw in chain {
            guard let hop = jumpTarget(raw) else { throw WorkspaceError.invalid("The jump host could not be read.") }
            guard seen.insert(hop.host.lowercased()).inserted else {
                throw WorkspaceError.invalid("Jump hosts must not loop and can chain at most 8 hosts.")
            }
            var values = resolve(hop.host, in: blocks)
            values.removeValue(forKey: "proxyjump")
            if !route.isEmpty { values.removeValue(forKey: "proxycommand") }
            if let user = hop.user { values["user"] = [user] }
            if let port = hop.port { values["port"] = [String(port)] }
            let (resolved, _) = try entry(hop.host, values: values, aliases: [], blocks: [], options: options)
            let address = hop.host + (hop.port.map { ":\($0)" } ?? "")
            // An explicit multi-hop route has its own links. It must not change how a standalone alias connects.
            let path = chain.count == 1 && hop.user == nil && hop.port == nil ? [address] : ["ProxyJump", alias, raw]
            route.append(.init(components: path, name: address, connection: resolved.connection,
                               notes: resolved.notes + ["Added as the jump host for another session."], jump: route.last?.components))
        }
        return route
    }

    /// Reads `nc [-X 4|5|connect] -x proxy[:port] %h %p`, the usual way to reach SSH through a proxy.
    static func netcatProxy(_ command: [String]) -> ProxyConfiguration? {
        guard let tool = command.first.map({ URL(fileURLWithPath: $0).lastPathComponent }),
              ["nc", "ncat", "netcat"].contains(tool), command.suffix(2) == ["%h", "%p"] else { return nil }
        var kind = ProxyKind.socks5
        var address: String?
        var index = 1
        while index < command.count - 2 {
            switch command[index] {
            case "-X":
                guard index + 1 < command.count else { return nil }
                switch command[index + 1].lowercased() {
                case "4": kind = .socks4
                case "5": kind = .socks5
                case "connect": kind = .http
                default: return nil
                }
                index += 2
            case "-x":
                guard index + 1 < command.count else { return nil }
                address = command[index + 1]
                index += 2
            default:
                return nil
            }
        }
        guard let address, let target = jumpTarget(address), target.user == nil else { return nil }
        return ProxyConfiguration(kind: kind, host: target.host, port: target.port ?? (kind == .http ? 3128 : 1080))
    }

    private static func defaultIdentity(_ options: Options) -> String? {
        defaultIdentities.map { options.home.appendingPathComponent(".ssh/\($0)").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Parses `[user@]host[:port]` or `ssh://[user@]host[:port]`.
    static func jumpTarget(_ value: String) -> (user: String?, host: String, port: Int?)? {
        var rest = value.hasPrefix("ssh://") ? String(value.dropFirst(6)) : value
        if rest.hasSuffix("/") { rest.removeLast() }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") { port = Int(tail.dropFirst()) ; if port == nil { return nil } }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            guard let value = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = value; rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, user.map({ !$0.isEmpty }) ?? true, port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return (user, rest, port)
    }

    /// Expands the OpenSSH tokens used in HostName, User, and IdentityFile.
    private static func tokens(_ value: String, alias: String, host: String, user: String, options: Options) -> String {
        var output = ""
        var iterator = expandHome(value, options: options).makeIterator()
        while let character = iterator.next() {
            guard character == "%" else { output.append(character); continue }
            switch iterator.next() {
            case "%": output.append("%")
            case "h": output += host
            case "n": output += alias
            case "r": output += user
            case "u": output += options.localUser
            case "d": output += options.home.path
            case let other?: output += "%" + String(other)
            case nil: output.append("%")
            }
        }
        return output
    }

    private static func expandHome(_ value: String, options: Options) -> String {
        if value == "~" { return options.home.path }
        if value.hasPrefix("~/") { return options.home.path + value.dropFirst(1) }
        return value
    }

    /// Drops jump links that would loop back on themselves, noting the session that lost its link.
    private static func breakCycles(_ entries: [ProfileImport.Entry]) -> [ProfileImport.Entry] {
        let links = Dictionary(entries.map { ($0.components, $0.jump) }, uniquingKeysWith: { first, _ in first })
        return entries.map { entry in
            var seen: Set<[String]> = [entry.components]
            var next = entry.jump
            while let current = next {
                guard seen.insert(current).inserted, seen.count <= SessionTreeStore.maximumJumpHops + 1 else {
                    return ProfileImport.Entry(components: entry.components, name: entry.name, connection: entry.connection,
                                               notes: entry.notes + ["The jump hosts loop or are nested too deeply. Set the jump host in MShell."])
                }
                next = links[current] ?? nil
            }
            return entry
        }
    }
}
