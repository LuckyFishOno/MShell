import Foundation
import Combine
import Ssh
import FileTransfer
import Network
import Terminal
import Profiles
import Formats
import Highlight
import MasterPassword
import LocalAuthentication
import AppKit

public struct HostKeyPrompt: Identifiable {
    public let id = UUID()
    public let endpoint: String
    public let fingerprint: String
    let key: String
}

struct HostKeyChange: Identifiable {
    let id = UUID()
    let endpoint: String
    let savedFingerprint: String
    let receivedFingerprint: String
    let savedKey: String
    let receivedKey: String
}

@MainActor public final class SessionTab: ObservableObject, Identifiable {
    public let id = UUID()
    var opensAutomatically = false
    var savedSessionID: UUID?
    @Published var jumpSessionID: UUID?
    @Published var jumpSecret = ""
    @Published var transportLost = false
    var pendingJump: SSHSession?
    var disconnectWatcher: Task<Void, Never>?
    @Published var forwards: [SessionForward] = []
    @Published var forwardingRules: [ForwardingRule] = []
    @Published var forwardingErrors: [String] = []
    var forwardStarts: Set<UUID> = []
    var savedConnectionTask: Task<Void, Never>?
    @Published public var title = "New connection"
    @Published public var host = ""
    @Published public var port = "22"
    @Published public var username = ""
    @Published public var password = ""
    @Published var identityPath: String?
    @Published var useAgent = false
    var agentSocket: String?
    var confirmsEachConnection = true
    @Published var keyPassphrase = ""
    @Published var showsFiles = false
    @Published public internal(set) var filesLoaded = false
    @Published public var useProxy = false
    @Published public var proxyKind: ProxyKind = .socks5
    @Published public var proxyHost = "127.0.0.1"
    @Published public var proxyPort = "1080"
    @Published public var status = "Disconnected"
    @Published public var error: String?
    @Published public var busy = false
    @Published public var connected = false
    @Published public var command = ""
    @Published public var remotePath = "."
    @Published public var entries: [RemoteEntry] = []
    @Published public var progress: Double?
    /// Plain text of the scrollback and screen. Built on demand: rebuilding it after every chunk of
    /// output cost more than drawing the terminal.
    public var transcript: String { lines.joined(separator: "\n") }
    @Published public var screenRevision = 0
    @Published var terminalFocusRequest = 0
    @Published public var hostKeyPrompt: HostKeyPrompt?
    @Published var hostKeyChange: HostKeyChange?
    @Published public var colorScheme: Formats.ColorScheme?
    @Published public var highlights: HighlightSet?
    var epoch = UUID()
    var terminalID = UUID()
    var fileOperationID = UUID()
    @Published public var terminalReady = false
    @Published public var terminalStarting = false
    @Published public var isLocal = false
    var localShell: LocalShell?
    var shell: SSHInteractiveShell?
    var shellOutput: Task<Void, Never>?
    var inputTask: Task<Void, Never>?
    var resizeTask: Task<Void, Never>?
    var pendingInput: [[UInt8]] = []
    var pendingInputBytes = 0
    var session: SSHSession?
    var transfer: SFTPTransfer?
    var transferOpening: Task<SFTPTransfer, Error>?
    /// Folders shown in the remote file sidebar for this session.
    let remoteTree = RemoteTreeState()
    /// The folder the file transfer view shows for this session.
    let remoteBrowser = RemoteBrowserState()
    var trustContinuation: CheckedContinuation<Void, Error>?
    var screen = TerminalScreen()
    public var credentialID: String { "\(username)@\(KnownHosts.endpoint(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 22))" }
    public var lines: [String] { screen.scrollback.map { String($0.filter { $0.width != 0 }.map(\.character)) } + screen.lines }
    public init() {
        feed(T("Connect to a server to use the terminal, or open Remote files for SFTP.") + "\n")
    }
    func feed(_ text: String) {
        screen.feed(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
        screenRevision += 1
    }
}

@MainActor public final class WorkspaceModel: ObservableObject {
    /// The window arrangement: macOS, Xshell-style, or MobaXterm-style. It applies at once and is remembered.
    @Published public private(set) var layout: WorkspaceLayout
    private let storage: URL

    func selectLayout(_ layout: WorkspaceLayout) throws {
        try layout.save(to: storage)
        self.layout = layout
    }

    @Published public private(set) var themeID = WorkspaceTheme.native.id
    @Published public private(set) var themePreview: ThemePreviewState?
    private var themePreviewTask: Task<Void, Never>?
    private var themePreviewGeneration = UUID()
    public let themes: [WorkspaceTheme]
    private let themePreferencesURL: URL
    public var displayedThemeID: String { themePreview?.activeID ?? themeID }
    public var theme: WorkspaceTheme { themes.first { $0.id == displayedThemeID } ?? .native }
    public func beginThemePreview() {
        guard themePreview == nil else { return }
        themePreview = ThemePreviewState(current: themeID)
    }
    public func focusThemePreview(_ id: String, schedule: Bool = true) throws {
        guard var preview = themePreview else { throw ThemeError.previewNotOpen }
        guard themes.contains(where: { $0.id == id }) else { throw ThemeError.unknownTheme }
        themePreviewTask?.cancel(); themePreviewGeneration = UUID()
        preview.focus(id); themePreview = preview
        let generation = themePreviewGeneration
        if schedule {
            themePreviewTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, self.themePreviewGeneration == generation else { return }
                self.advanceThemePreview(milliseconds: 200)
            }
        }
    }
    public func advanceThemePreview(milliseconds: Int) {
        guard (0...30_000).contains(milliseconds), var preview = themePreview else { return }
        preview.advance(milliseconds); themePreview = preview
    }
    public func applyThemePreview() throws {
        guard let preview = themePreview else { throw ThemeError.previewNotOpen }
        try selectTheme(preview.selectedID)
    }
    public func cancelThemePreview() {
        themePreviewTask?.cancel(); themePreviewTask = nil; themePreviewGeneration = UUID(); themePreview = nil
    }
    public func selectTheme(_ id: String) throws {
        guard themes.contains(where: { $0.id == id }) else { throw ThemeError.unknownTheme }
        let bytes = try JSONEncoder().encode(ThemePreference(selectedID: id))
        try writePrivate(bytes, to: themePreferencesURL)
        themeID = id
        cancelThemePreview()
    }
    @Published public var language = UIStrings.language {
        didSet { UIStrings.language = language; UIStrings.store(language) }
    }
    @Published public var tabs: [SessionTab] = [SessionTab()]
    @Published public private(set) var selection: UUID?
    /// Split layouts. Each group shows as one tab in the tab bar; tabs outside every group show alone.
    @Published private(set) var groups: [WorkspaceSplit] = [] {
        didSet {
            if !groups.contains(where: { $0.contains(maximizedPane) }) { maximizedPane = nil }
            if split == nil { broadcastInput = false }
        }
    }
    /// The split layout on screen: the group that holds the selected tab.
    var split: WorkspaceSplit? { groups.first { $0.contains(selection) } }
    func group(containing id: UUID?) -> WorkspaceSplit? { groups.first { $0.contains(id) } }
    /// Replaces the group holding `member` (or adds one) with `layout`; nil dissolves it.
    private func setGroup(containing member: UUID, to layout: WorkspaceSplit?) {
        var updated = groups
        if let index = updated.firstIndex(where: { $0.contains(member) }) {
            if let layout { updated[index] = layout } else { updated.remove(at: index) }
        } else if let layout { updated.append(layout) }
        groups = updated
    }
    /// The pane temporarily filling the session area, if any. Its siblings keep running.
    @Published private(set) var maximizedPane: UUID?
    /// When on, keyboard input in any pane is sent to every pane in the split layout.
    @Published private(set) var broadcastInput = false
    @Published public var vaultState = "Not configured"
    @Published public var vaultBusy = false
    @Published var vaultHasTouchID = false
    /// Passwords are saved on this Mac without unlocking the vault (any Mac with a Secure Enclave).
    @Published var savesWithoutUnlock = false
    /// Accounts and key passphrases that have a copy in the vault, for the "In vault" mark in the form.
    @Published var vaultEntries: Set<String> = []
    /// Stands in for the vault's Touch ID unlock in tests, which cannot answer the system prompt.
    /// Confirms the Mac's owner before a session marked to ask every time. Tests replace it.
    var confirmOwner: (String) async throws -> Void = { reason in
        // Under XCTest no one can answer the system prompt; tests that check the prompt set their own closure.
        if NSClassFromString("XCTestCase") != nil { return }
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
    @Published public var error: String?
    public let sessionTree: SessionTreeStore
    let quickCommands: QuickCommandStore
    public let knownHosts: KnownHosts
    public let vault: CredentialVault
    var sessionWindows: [UUID: SavedSessionWindow] = [:]
    /// Uploads and downloads started from any file panel or window.
    lazy var transfers = TransferQueue(model: self)
    /// Whether the middle of the main window shows terminals or the two-pane file transfer view.
    @Published var workspaceMode = WorkspaceMode.terminal
    /// A session in its own window whose files the transfer view shows instead of the selected tab's.
    @Published var pinnedTransferTab: UUID?
    /// The left-hand folder of the file transfer view, kept while switching tabs and modes.
    let localBrowser = LocalBrowserState()
    /// This Mac's folder tree in the Mac layout's file sidebar, shown while the local terminal is focused.
    let localTree = LocalTreeState()
    /// The Mac layout's file transfer view follows the selected tab.
    let mainTransferTarget = TransferTarget(followsSelection: true)
    /// The Xshell and MobaXterm layouts' own file transfer window.
    var transferWindow: FileTransferWindow?
    /// Set when a saved session that opens to its files has connected, so the layout can show them.
    @Published var filesRequest: FilesRequest?

    nonisolated public static var defaultStorage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MShell", isDirectory: true)
    }
    public init(storage: URL? = nil) throws {
        let storage = (storage ?? Self.defaultStorage).standardizedFileURL
        if storage == Self.defaultStorage.standardizedFileURL || AppSSHKey.directory == nil { AppSSHKey.directory = storage }
        self.storage = storage
        let layout = (try? WorkspaceLayout.load(from: storage)) ?? .native
        self.layout = layout
        themes = try ThemeCatalog.bundled()
        themePreferencesURL = storage.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: themePreferencesURL), let preference = try? JSONDecoder().decode(ThemePreference.self, from: data), themes.contains(where: { $0.id == preference.selectedID }) {
            themeID = preference.selectedID
        }
        sessionTree = try SessionTreeStore(url: storage.appendingPathComponent("sessions.json"))
        quickCommands = QuickCommandStore(url: storage.appendingPathComponent("quick-commands.json"))
        knownHosts = try KnownHosts(url: storage.appendingPathComponent("known-hosts.json"))
        vault = try CredentialVault(url: storage.appendingPathComponent("password-vault.json"),
                                    deviceSecrets: storage.appendingPathComponent("saved-sign-ins.json"))
        selection = tabs[0].id
    }
    public var selected: SessionTab? { tabs.first { $0.id == selection } }
    func selectTab(_ id: UUID, focusTerminal: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if maximizedPane != nil && !(split?.contains(id) ?? false) { maximizedPane = nil }
        selection = id; pinnedTransferTab = nil
        if focusTerminal { tab.terminalFocusRequest += 1 }
    }

    /// Splits the selected pane. The new pane shows the most recent tab that is not already visible,
    /// or a new local terminal. Focus stays on the pane that was split.
    func splitWorkspace(_ axis: WorkspaceSplitAxis) {
        guard let active = selected, canSplit(active.id) else { return }
        let grouped = Set(groups.flatMap(\.tabIDs)).union([active.id])
        let added = tabs.last(where: { !grouped.contains($0.id) && canSplit($0.id) }) ?? addLocalTab(select: false)
        setGroup(containing: active.id, to: split?.splitting(active.id, axis: axis, adding: added.id)
            ?? WorkspaceSplit(axis: axis, first: active.id, second: added.id))
        maximizedPane = nil
        selectTab(active.id)
    }

    /// Only connected sessions and local terminals share the screen; a tab still showing its sign-in form does not.
    func canSplit(_ id: UUID?) -> Bool {
        tabs.first { $0.id == id }.map { $0.connected || $0.isLocal } ?? false
    }

    /// Ungroups the split on screen; its panes become separate tabs again.
    func closeSplit() {
        guard let selection else { return }
        setGroup(containing: selection, to: nil)
        selectTab(selection)
    }

    /// Takes a pane out of its split group and shows it as its own tab.
    func detachPane(_ id: UUID) {
        guard let layout = group(containing: id) else { return }
        setGroup(containing: id, to: layout.removing(id))
        selectTab(id)
    }

    /// Places a dragged tab on a pane. An edge splits that pane toward the edge; the center shows the
    /// dragged tab in that pane, swapping places when both are already visible. Dragging a visible
    /// pane to another edge moves it.
    func placeTab(_ dragged: UUID, at edge: PaneDropEdge, of target: UUID) {
        guard dragged != target, canSplit(dragged), canSplit(target) else { return }
        var root = group(containing: target)?.root ?? .tab(target)
        if !root.contains(dragged), let source = group(containing: dragged) {
            // Leaving another group: that group keeps its other panes.
            setGroup(containing: dragged, to: source.removing(dragged))
        }
        if edge == .center {
            root = root.contains(dragged) ? root.swapping(dragged, target) : root.replacing(target, with: dragged)
        } else {
            if root.contains(dragged) {
                guard let remaining = root.removing(dragged) else { return }
                root = remaining
            }
            root = root.splitting(target, axis: edge.axis, adding: dragged, newFirst: edge.placesNewFirst)
        }
        setGroup(containing: target, to: nil)
        if let layout = WorkspaceSplit.make(root) { groups.append(layout) }
        maximizedPane = nil
        selectTab(dragged)
    }

    func toggleMaximizedPane(_ id: UUID) {
        guard split?.contains(id) == true else { return }
        maximizedPane = maximizedPane == id ? nil : id
        selectTab(id)
    }

    func toggleBroadcastInput() {
        broadcastInput = split != nil && !broadcastInput
    }

    /// Keyboard and paste input from a terminal view. Terminal replies and quick commands use
    /// `sendTerminal` and always stay with their own tab.
    func typeTerminal(_ tab: SessionTab, bytes: [UInt8]) {
        guard broadcastInput, let layout = split, layout.contains(tab.id) else { return sendTerminal(tab, bytes: bytes) }
        for id in layout.tabIDs {
            if let target = tabs.first(where: { $0.id == id }) { enqueueTerminalInput(target, bytes: bytes) }
        }
    }

    @discardableResult public func addTab(select: Bool = true) -> SessionTab {
        let tab = SessionTab()
        tabs.append(tab)
        if select { selectTab(tab.id) }
        return tab
    }
    @discardableResult public func addLocalTab(select: Bool = true) -> SessionTab {
        let tab = addTab(select: select); tab.isLocal = true; tab.title = "Local terminal"
        tab.host = "127.0.0.1"; tab.username = NSUserName()
        tab.screen = TerminalScreen(); tab.screenRevision += 1
        startLocalTerminal(tab)
        return tab
    }
    public func startLocalTerminal(_ tab: SessionTab) {
        guard tab.isLocal, tab.localShell == nil else { return }
        let epoch = UUID(); tab.epoch = epoch
        do {
            tab.localShell = try LocalShell(rows: tab.screen.rows, columns: tab.screen.cols) { [weak self, weak tab] data in
                Task { @MainActor in
                    guard let tab, tab.epoch == epoch else { return }
                    if data.isEmpty {
                        tab.localShell?.close(); tab.localShell = nil
                        tab.terminalReady = false; tab.connected = false; tab.status = "Shell closed"
                    } else {
                        tab.screen.feed(Array(data)); tab.screenRevision += 1
                        for event in tab.screen.takeEvents() {
                            if case .reply(let bytes) = event { self?.sendTerminal(tab, bytes: bytes) }
                        }
                    }
                }
            }
            tab.terminalID = UUID()
            tab.connected = true; tab.terminalReady = true; tab.status = "Connected"; tab.error = nil
        } catch { tab.error = error.localizedDescription }
    }
    public func closeTab(_ tab: SessionTab) async {
        await disconnect(tab)
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if let layout = group(containing: tab.id) {
            let remaining = layout.tabIDs.filter { $0 != tab.id }
            setGroup(containing: tab.id, to: layout.removing(tab.id))
            if selection == tab.id, let next = remaining.first { selectTab(next) }
        } else if tabs.isEmpty {
            _ = addLocalTab()
        } else if selection == tab.id {
            selectTab(tabs[min(index, tabs.count - 1)].id)
        }
    }
    /// Disconnects and closes the tab, or its own window when it was opened in one.
    public func disconnectAndClose(_ tab: SessionTab) async {
        if let window = sessionWindows[tab.id]?.window { window.close(); return }
        await closeTab(tab)
    }
    public func disconnect(_ tab: SessionTab) async {
        await endConnection(tab, lost: false)
    }

    private func endConnection(_ tab: SessionTab, lost: Bool) async {
        tab.savedConnectionTask?.cancel(); tab.savedConnectionTask = nil
        tab.epoch = UUID()
        tab.localShell?.close(); tab.localShell = nil
        answerHostKey(tab, approve: false)
        tab.hostKeyChange = nil
        let ssh = tab.session, transfer = tab.transfer, shell = tab.shell, jump = tab.pendingJump
        tab.pendingJump = nil
        tab.disconnectWatcher?.cancel()
        tab.disconnectWatcher = nil
        let forwards = tab.forwards
        tab.forwards = []
        tab.forwardStarts.removeAll()
        tab.forwardingErrors = []
        tab.resizeTask?.cancel(); tab.resizeTask = nil
        tab.shellOutput?.cancel(); tab.inputTask?.cancel(); tab.shellOutput = nil; tab.inputTask = nil
        tab.shell = nil; tab.terminalReady = false; tab.terminalStarting = false; tab.pendingInput = []; tab.pendingInputBytes = 0
        tab.transferOpening = nil; tab.remoteTree.reset(); tab.remoteBrowser.clear()
        tab.session = nil; tab.transfer = nil; tab.connected = false; tab.busy = false; tab.progress = nil; tab.status = "Disconnected"
        tab.password = ""; tab.keyPassphrase = ""; tab.jumpSecret = ""; tab.filesLoaded = false; tab.entries = []
        tab.transportLost = lost
        if lost {
            tab.status = "Connection lost"
            tab.error = nil
            tab.feed("\u{1b}[?1049l\u{1b}[?2004l\n" + T("Connection lost") + "\n")
        }
        for forward in forwards { await forward.handle.close() }
        await shell?.close()
        try? await transfer?.close()
        try? await ssh?.close()
        try? await jump?.close()
    }
    public func closeWorkspaceTabs() async {
        for tab in tabs { await disconnect(tab) }
        if sessionWindows.isEmpty { await lockVault() }
    }
    public func closeAll() async {
        let windows = Array(sessionWindows.values)
        for controller in windows { controller.close(); await disconnect(controller.tab) }
        for tab in tabs { await disconnect(tab) }
        await lockVault()
    }

    public func connect(_ tab: SessionTab) async {
        if tab.isLocal { startLocalTerminal(tab); return }
        guard !tab.busy, !tab.connected else { return }
        tab.error = nil
        tab.hostKeyChange = nil
        tab.forwardingErrors = []
        if let id = tab.savedSessionID {
            tab.forwardingRules = sessionTree.node(id)?.connection?.forwardingRules ?? []
        }
        let host = tab.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(tab.port), (1...65535).contains(port), !host.isEmpty, !tab.username.isEmpty,
              !tab.useProxy || (!tab.proxyHost.isEmpty && Int(tab.proxyPort).map { (1...65535).contains($0) } == true) else {
            tab.error = "Enter a host, username and valid TCP ports."
            return
        }
        let target = SavedConnection(host: host, port: port, username: tab.username, proxyHost: tab.useProxy ? tab.proxyHost : nil,
                                     proxyPort: tab.useProxy ? Int(tab.proxyPort) : nil, identityPath: tab.identityPath,
                                     jumpSessionID: tab.jumpSessionID, usesAgent: tab.useAgent, agentSocket: tab.agentSocket,
                                     proxyKind: tab.proxyKind, confirmsEachConnection: tab.confirmsEachConnection)
        let hops: [SavedConnection]
        do {
            try target.validate()
            guard let chain = sessionTree.jumpChain(for: target, excluding: tab.savedSessionID) else {
                throw WorkspaceError.invalid("Choose an available jump host in Connection settings.")
            }
            hops = chain
        } catch {
            tab.error = message(for: error)
            return
        }

        tab.host = host
        if !tab.opensAutomatically { tab.title = "\(tab.username)@\(host)" }
        let epoch = UUID()
        tab.epoch = epoch
        tab.busy = true
        tab.status = "Connecting…"
        let secret = tab.identityPath == nil ? (tab.useAgent ? "" : tab.password) : tab.keyPassphrase
        let jumpSecret = tab.jumpSecret
        tab.password = ""; tab.keyPassphrase = ""; tab.jumpSecret = ""
        var openingJump: SavedConnection?
        defer { if tab.epoch == epoch { tab.busy = false } }
        do {
            // An unlocked password vault already confirmed the owner for this launch, so it does not ask per connection.
            // While it is locked, a session marked to ask on every connection asks: Touch ID or the Mac password.
            let vaultUnlocked = await vault.state == "Unlocked"
            let asks = !vaultUnlocked
                && ((target.asksEachConnection && secret.isEmpty) || hops.contains(where: \.asksEachConnection))
            let reason = String(format: T("connect to %@"), "\(target.username)@\(host)")
            var confirmed = false
            // A password that only the locked vault holds is read with Touch ID for this one connection. That prompt is
            // also the per-connection check; the vault stays locked.
            if !vaultUnlocked, await vault.touchIDEnrolled {
                let accounts = (secret.isEmpty ? [target] : []) + hops
                let needed = Set(accounts.flatMap { connection in
                    ["\(connection.username)@\(KnownHosts.endpoint(host: connection.host, port: connection.port))"]
                        + (connection.identityPath.map { [Self.passphraseID($0)] } ?? [])
                })
                let locked = await vault.lockedVaultIDs(needed)
                if !locked.isEmpty {
                    tab.status = "Waiting for Touch ID…"
                    try await vault.readWithTouchID(ids: locked, reason: reason)
                    guard tab.epoch == epoch else { return }
                    confirmed = true
                    tab.status = "Connecting…"
                }
            }
            if asks, !confirmed {
                tab.status = "Waiting for Touch ID…"
                do { try await confirmOwner(reason) }
                catch { throw WorkspaceError.invalid("This session asks for Touch ID or the Mac password before it connects.") }
                guard tab.epoch == epoch else { return }
                tab.status = "Connecting…"
            }
            // Each hop is reached through the one before it. The typed jump secret belongs to the host the
            // destination is reached from; earlier hops use their key or the password remembered for this session.
            for (index, hop) in hops.enumerated() {
                openingJump = hop
                tab.status = "Connecting to jump host…"
                let server = try await establish(hop, secret: index == hops.count - 1 ? jumpSecret : "", tab: tab,
                                                 epoch: epoch, via: tab.pendingJump)
                guard tab.epoch == epoch else { try? await server.close(); return }
                tab.pendingJump = server
                openingJump = nil
                tab.status = "Connecting…"
            }
            let ssh = try await establish(target, secret: secret, tab: tab, epoch: epoch, via: tab.pendingJump)
            guard tab.epoch == epoch else { try? await ssh.close(); return }
            tab.pendingJump = nil
            tab.session = ssh
            tab.connected = true
            tab.transportLost = false
            tab.status = "Connected"
            tab.feed(T("Connected to") + " \(KnownHosts.endpoint(host: target.host, port: target.port))\n")
            tab.disconnectWatcher = Task { @MainActor [weak self, weak tab] in
                await ssh.waitForDisconnect()
                guard !Task.isCancelled, let self, let tab, tab.epoch == epoch else { return }
                await self.endConnection(tab, lost: true)
            }
            await startSavedForwards(tab, epoch: epoch)
        } catch {
            guard tab.epoch == epoch else { return }
            let server = tab.pendingJump
            tab.pendingJump = nil
            answerHostKey(tab, approve: false)
            tab.status = "Connection failed"
            let detail = tab.error ?? message(for: error)
            if let hop = openingJump {
                let label = hops.count > 1 ? "\(hop.host) – " + T(detail) : T(detail)
                tab.error = String(format: T("Jump host: %@"), label)
            } else {
                tab.error = detail
            }
            try? await server?.close()
        }
    }

    private func establish(_ configuration: SavedConnection, secret: String, tab: SessionTab, epoch: UUID,
                           via jump: SSHSession? = nil) async throws -> SSHSession {
        let endpoint = KnownHosts.endpoint(host: configuration.host, port: configuration.port)
        let id = "\(configuration.username)@\(endpoint)"
        let settings = SSHConnectionSettings(host: configuration.host, port: configuration.port, username: configuration.username)
        let credentialGeneration = await vault.sessionGeneration
        let credential: SSHCredential
        let password: String?
        var keySecret: (id: String, value: String)?
        if configuration.usesKeys {
            var agent: SSHAgentClient?
            if configuration.usesAgent == true {
                agent = configuration.agentSocket.map { SSHAgentClient(socketPath: $0) } ?? SSHAgentClient.environment()
                if agent == nil && configuration.identityPath == nil { throw SSHAgentError.unavailable }
            }
            let file = configuration.identityPath.map { URL(fileURLWithPath: $0) }
            // A passphrase typed once is kept in the vault under the key's path.
            var passphrase = secret
            if passphrase.isEmpty, let path = configuration.identityPath {
                passphrase = (try? await vault.password(id: Self.passphraseID(path))) ?? ""
            }
            credential = try await Task.detached(priority: .userInitiated) { [agent, passphrase] in
                try SSHCredential.keys(agent: agent, identityFile: file, passphrase: passphrase)
            }.value
            keySecret = configuration.identityPath.map { (Self.passphraseID($0), passphrase) }
            password = nil
        } else {
            let value = secret.isEmpty ? try await vault.password(id: id) : secret
            credential = .password(value)
            password = value
        }
        guard tab.epoch == epoch else { throw CancellationError() }
        let policy: HostKeyPolicy = .confirm { [weak self, weak tab] key in
            guard let self, let tab else { throw WorkspaceError.rejectedHostKey }
            try await self.confirmKey(tab, endpoint: endpoint, key: key, epoch: epoch)
        }
        do {
            let ssh: SSHSession
            if let jump {
                ssh = try await SSHSession.connect(settings: settings, credential: credential, via: jump, hostKey: policy)
            } else {
                ssh = try await SSHSession.connect(settings: settings, credential: credential, proxy: configuration.proxy, hostKey: policy)
            }
            if tab.epoch == epoch, let password {
                await vault.rememberWorking(id: id, secret: password, generation: credentialGeneration)
            }
            if tab.epoch == epoch, let keySecret {
                await vault.rememberWorking(id: keySecret.id, secret: keySecret.value, generation: credentialGeneration)
            }
            await refreshVault()
            return ssh
        } catch SSHError.authenticationFailed {
            guard let password else {
                throw WorkspaceError.invalid("SSH authentication failed. Check the username and private key.")
            }
            if secret.isEmpty, tab.epoch == epoch, tab.error == nil {
                await vault.forgetForSession(id: id, matching: password, generation: credentialGeneration)
            }
            throw SSHError.authenticationFailed
        }
    }

    /// The vault entry that holds a private key's passphrase.
    static func passphraseID(_ path: String) -> String { "passphrase:" + path }

    private func confirmKey(_ tab: SessionTab, endpoint: String, key: String, epoch: UUID) async throws {
        guard tab.epoch == epoch else { throw WorkspaceError.rejectedHostKey }
        do { if try knownHosts.isTrusted(endpoint: endpoint, key: key) { return } }
        catch WorkspaceError.changedHostKey {
            guard let savedKey = knownHosts.trustedKey(for: endpoint) else { throw WorkspaceError.rejectedHostKey }
            tab.hostKeyChange = try HostKeyChange(endpoint: endpoint, savedFingerprint: KnownHosts.fingerprint(savedKey),
                                                  receivedFingerprint: KnownHosts.fingerprint(key), savedKey: savedKey, receivedKey: key)
            tab.error = "The server host key has changed. Review its fingerprint before reconnecting."
            throw WorkspaceError.changedHostKey(endpoint)
        } catch { tab.error = message(for: error); throw error }
        guard tab.trustContinuation == nil else { throw WorkspaceError.rejectedHostKey }
        let prompt = HostKeyPrompt(endpoint: endpoint, fingerprint: try KnownHosts.fingerprint(key), key: key)
        try await withCheckedThrowingContinuation { continuation in tab.trustContinuation = continuation; tab.hostKeyPrompt = prompt }
        guard tab.epoch == epoch else { throw WorkspaceError.rejectedHostKey }
    }
    public func answerHostKey(_ tab: SessionTab, approve: Bool) {
        guard let continuation = tab.trustContinuation else { return }
        let prompt = tab.hostKeyPrompt
        tab.trustContinuation = nil; tab.hostKeyPrompt = nil
        do {
            guard approve, let prompt else { throw WorkspaceError.rejectedHostKey }
            try knownHosts.trust(endpoint: prompt.endpoint, key: prompt.key)
            continuation.resume()
        } catch { continuation.resume(throwing: error) }
    }

    func updateHostKeyAndReconnect(_ tab: SessionTab, change: HostKeyChange) async {
        guard !tab.busy, !tab.connected, tab.hostKeyChange?.id == change.id else { return }
        let host = tab.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = Int(tab.port).map { KnownHosts.endpoint(host: host, port: $0) }
        let probe = SavedConnection(host: host, port: Int(tab.port) ?? 22, username: tab.username, jumpSessionID: tab.jumpSessionID)
        let jumps = (sessionTree.jumpChain(for: probe, excluding: tab.savedSessionID) ?? [])
            .map { KnownHosts.endpoint(host: $0.host, port: $0.port) }
        guard change.endpoint == target || jumps.contains(change.endpoint) else {
            tab.hostKeyChange = nil
            tab.error = "Connection settings changed. Connect again to review the host key."
            return
        }
        do { try knownHosts.replace(endpoint: change.endpoint, expectedKey: change.savedKey, with: change.receivedKey) }
        catch {
            tab.hostKeyChange = nil
            tab.error = message(for: error)
            return
        }
        await connect(tab)
    }
    public func startTerminal(_ tab: SessionTab) async {
        guard tab.connected, let ssh = tab.session, tab.shell == nil, !tab.terminalStarting else { return }
        let epoch = tab.epoch; tab.terminalStarting = true
        defer { if tab.epoch == epoch { tab.terminalStarting = false } }
        do {
            let shell = try await ssh.openShell(rows: tab.screen.rows, columns: tab.screen.cols)
            guard tab.epoch == epoch else { await shell.close(); return }
            try await shell.resize(rows: tab.screen.rows, columns: tab.screen.cols)
            guard tab.epoch == epoch else { await shell.close(); return }
            tab.terminalID = UUID()
            tab.shell = shell; tab.terminalReady = true; tab.error = nil
            tab.shellOutput = Task { @MainActor [weak self, weak tab] in
                do {
                    for try await bytes in shell.output {
                        guard let tab, tab.epoch == epoch, !Task.isCancelled else { return }
                        tab.screen.feed(bytes)
                        tab.screenRevision += 1
                        for event in tab.screen.takeEvents() {
                            if case .reply(let bytes) = event { self?.sendTerminal(tab, bytes: bytes) }
                        }
                    }
                } catch { if let tab, tab.epoch == epoch, !Task.isCancelled { tab.error = message(for: error) } }
                if let tab, tab.epoch == epoch {
                    tab.inputTask?.cancel(); tab.inputTask = nil
                    tab.pendingInput.removeAll(); tab.pendingInputBytes = 0
                    tab.terminalReady = false; tab.shell = nil; tab.status = "Shell closed"
                    // `exit` or `logout` ends the session like a terminal app: the tab goes away. A shell that
                    // stops without an exit status (the connection dropped) keeps the tab for Reconnect.
                    if shell.exitStatus != nil, tab.error == nil, !Task.isCancelled {
                        tab.shellOutput = nil
                        await self?.disconnectAndClose(tab)
                    }
                }
            }
        } catch { if tab.epoch == epoch { tab.error = message(for: error) } }
    }
    public func sendTerminal(_ tab: SessionTab, bytes: [UInt8]) {
        enqueueTerminalInput(tab, bytes: bytes)
    }

    @discardableResult func enqueueTerminalInput(_ tab: SessionTab, bytes: [UInt8]) -> Bool {
        guard tab.terminalReady, !bytes.isEmpty, bytes.count <= 262144 else { return false }
        if tab.isLocal {
            guard let shell = tab.localShell else { return false }
            shell.send(bytes)
            return true
        }
        guard let shell = tab.shell else { return false }
        guard tab.pendingInputBytes + bytes.count <= 262144 else { tab.error = "Terminal input queue exceeds 256 KiB."; return false }
        tab.pendingInput.append(bytes); tab.pendingInputBytes += bytes.count
        guard tab.inputTask == nil else { return true }
        let epoch = tab.epoch
        let terminalID = tab.terminalID
        tab.inputTask = Task { @MainActor [weak tab] in
            guard let tab else { return }
            defer { if tab.epoch == epoch, tab.shell === shell { tab.inputTask = nil } }
            while !tab.pendingInput.isEmpty, tab.epoch == epoch, tab.terminalID == terminalID, !Task.isCancelled {
                let bytes = tab.pendingInput.removeFirst(); tab.pendingInputBytes -= bytes.count
                do { try await shell.send(bytes) }
                catch {
                    if tab.epoch == epoch, tab.shell === shell, !Task.isCancelled {
                        tab.pendingInput.removeAll(); tab.pendingInputBytes = 0
                        tab.error = message(for: error)
                    }
                    return
                }
            }
        }
        return true
    }
    public func resizeTerminal(_ tab: SessionTab, rows: Int, columns: Int) {
        let rows = min(200, max(5, rows)), columns = min(400, max(20, columns))
        guard rows != tab.screen.rows || columns != tab.screen.cols else { return }
        tab.screen.resize(rows: rows, cols: columns); tab.screenRevision += 1
        tab.localShell?.resize(rows: rows, columns: columns)
        tab.resizeTask?.cancel()
        if let shell = tab.shell {
            tab.resizeTask = Task {
                do { try await Task.sleep(nanoseconds: 80_000_000); try Task.checkCancellation(); try await shell.resize(rows: rows, columns: columns) } catch {}
            }
        }
    }
    public func execute(_ tab: SessionTab) async {
        guard !tab.busy, let ssh = tab.session, !tab.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = tab.command, epoch = tab.epoch
        tab.command = ""; tab.busy = true; tab.error = nil; tab.status = "Running command…"; tab.feed("$ \(command)\n")
        defer { if tab.epoch == epoch { tab.busy = false; tab.status = tab.connected ? "Connected" : "Disconnected" } }
        do {
            let output = try await ssh.runCommand(command, includeStandardError: true)
            if tab.epoch == epoch { tab.feed(output + (output.hasSuffix("\n") ? "" : "\n")) }
        } catch { if tab.epoch == epoch { tab.error = message(for: error) } }
    }
    private func fileSession(_ tab: SessionTab) async throws -> SFTPTransfer {
        if let transfer = tab.transfer { return transfer }
        // Panels that ask at the same moment share one SFTP channel instead of each opening their own.
        if let opening = tab.transferOpening { return try await opening.value }
        guard let ssh = tab.session else { throw WorkspaceError.disconnected }
        let epoch = tab.epoch
        let opening = Task { try await SFTPTransfer.open(ssh) }
        tab.transferOpening = opening
        let transfer: SFTPTransfer
        do { transfer = try await opening.value } catch {
            if epoch == tab.epoch { tab.transferOpening = nil }
            throw error
        }
        guard epoch == tab.epoch else { try? await transfer.close(); throw WorkspaceError.disconnected }
        tab.transferOpening = nil
        tab.transfer = transfer; return transfer
    }

    /// The SFTP session of a connected SSH tab, opened on first use.
    func sftp(for tab: SessionTab) async throws -> SFTPTransfer {
        guard tab.connected, !tab.isLocal else { throw WorkspaceError.disconnected }
        return try await fileSession(tab)
    }

    /// Connected SSH sessions, in the main window and in their own windows.
    var remoteTabs: [SessionTab] {
        (tabs + sessionWindows.values.map(\.tab)).filter { $0.connected && !$0.isLocal }
    }

    /// The session whose server the file transfer view shows.
    var transferTab: SessionTab? {
        if let id = pinnedTransferTab, let tab = sessionWindows[id]?.tab { return tab }
        return selected
    }

    /// Shows the two-pane file transfer view, on `tab` when given. The Mac layout switches its main window over to it;
    /// the Xshell and MobaXterm layouts open it in its own window, as Xshell opens Xftp.
    func openFileTransfer(for tab: SessionTab?) {
        if layout != .native {
            if transferWindow == nil { transferWindow = FileTransferWindow(model: self) }
            transferWindow?.select(tab ?? selected.flatMap { $0.connected && !$0.isLocal ? $0 : nil })
            transferWindow?.showWindow(nil)
            transferWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let tab, !tabs.contains(where: { $0.id == tab.id }) {
            // A session in its own window: show its server here and bring the main window forward.
            pinnedTransferTab = tab.id
            NSApp.windows.first { window in window.isVisible && !sessionWindows.values.contains { $0.window === window } && window.title == "MShell" }?
                .makeKeyAndOrderFront(nil)
        } else {
            pinnedTransferTab = nil
            if let tab, tab.id != selection { selectTab(tab.id, focusTerminal: false) }
        }
        workspaceMode = .files
    }

    func showTerminal() {
        workspaceMode = .terminal; pinnedTransferTab = nil
        if let selected { selected.terminalFocusRequest += 1 }
    }
    public func refreshFiles(_ tab: SessionTab, navigateTo path: String? = nil) async {
        guard !tab.busy, tab.connected else { return }
        let epoch = tab.epoch
        let requested = path ?? tab.remotePath
        tab.busy = true; tab.error = nil; tab.status = "Reading remote directory…"
        defer { if tab.epoch == epoch { tab.busy = false; tab.status = "Connected" } }
        do {
            let transfer = try await fileSession(tab)
            let directory = try await transfer.readDirectory(requested)
            guard tab.epoch == epoch else { return }
            tab.remotePath = directory.path
            tab.entries = directory.entries
            tab.filesLoaded = true
        } catch {
            if tab.epoch == epoch { tab.error = message(for: error) }
        }
    }
    public func remoteFile(_ name: String, in tab: SessionTab) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw WorkspaceError.invalid("Use a single file name.") }
        return (tab.remotePath as NSString).appendingPathComponent(name)
    }
    public func upload(_ tab: SessionTab, local: URL, overwrite: Bool = false) async {
        let epoch = tab.epoch
        await fileOperation(tab, title: "Uploading…") { transfer in
            let operation = tab.fileOperationID
            let name = local.lastPathComponent
            let path = try self.remoteFile(name, in: tab)
            if !overwrite, try await transfer.listDirectory(tab.remotePath).contains(where: { $0.name == name }) { throw WorkspaceError.alreadyExists(name) }
            try await transfer.upload(localURL: local, to: path) { progress in Task { @MainActor in if tab.busy && tab.epoch == epoch && tab.fileOperationID == operation { tab.progress = progress.fraction } } }
        }
    }
    public func download(_ tab: SessionTab, name: String, local: URL) async {
        let epoch = tab.epoch
        await fileOperation(tab, title: "Downloading…") { transfer in
            let operation = tab.fileOperationID
            let path = try self.remoteFile(name, in: tab)
            let partial = local.deletingLastPathComponent().appendingPathComponent(".mshell-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try await transfer.download(remotePath: path, to: partial) { progress in Task { @MainActor in if tab.busy && tab.epoch == epoch && tab.fileOperationID == operation { tab.progress = progress.fraction } } }
            if FileManager.default.fileExists(atPath: local.path) { _ = try FileManager.default.replaceItemAt(local, withItemAt: partial) }
            else { try FileManager.default.moveItem(at: partial, to: local) }
        }
    }
    public func rename(_ tab: SessionTab, from: String, to: String) async {
        await fileOperation(tab, title: "Renaming…") { transfer in
            let destination = try self.remoteFile(to, in: tab)
            if try await transfer.listDirectory(tab.remotePath).contains(where: { $0.name == to }) { throw WorkspaceError.alreadyExists(to) }
            try await transfer.rename(from: self.remoteFile(from, in: tab), to: destination)
        }
    }
    public func remove(_ tab: SessionTab, name: String) async {
        await fileOperation(tab, title: "Deleting…") { transfer in try await transfer.removeFile(self.remoteFile(name, in: tab)) }
    }
    private func fileOperation(_ tab: SessionTab, title: String, _ action: (SFTPTransfer) async throws -> Void) async {
        guard !tab.busy, tab.connected else { return }
        let epoch = tab.epoch; tab.fileOperationID = UUID(); tab.busy = true; tab.error = nil; tab.status = title; tab.progress = nil
        do { try await action(fileSession(tab)) }
        catch { if tab.epoch == epoch { tab.error = message(for: error) } }
        guard tab.epoch == epoch else { return }
        tab.fileOperationID = UUID(); tab.busy = false; tab.progress = nil; tab.status = "Connected"
        if tab.error == nil { await refreshFiles(tab) }
    }
    @discardableResult public func openSaved(_ item: SessionTreeNode, inNewWindow: Bool = false) -> SessionTab? {
        guard let settings = item.connection else { return nil }
        let tab = inNewWindow ? SessionTab() : addTab()
        tab.opensAutomatically = true
        tab.savedSessionID = item.id
        tab.jumpSessionID = settings.jumpSessionID
        tab.title = item.name; tab.host = settings.host; tab.port = String(settings.port); tab.username = settings.username
        tab.useProxy = settings.proxyHost != nil; tab.proxyKind = settings.proxyKind ?? .socks5; tab.proxyHost = settings.proxyHost ?? "127.0.0.1"; tab.proxyPort = String(settings.proxyPort ?? 1080)
        tab.identityPath = settings.identityPath
        tab.useAgent = settings.usesAgent == true
        tab.agentSocket = settings.agentSocket
        tab.confirmsEachConnection = settings.asksEachConnection
        tab.showsFiles = settings.opensFiles == true
        tab.forwardingRules = settings.forwardingRules ?? []
        if inNewWindow {
            let controller = SavedSessionWindow(model: self, tab: tab)
            sessionWindows[tab.id] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        tab.savedConnectionTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab, !Task.isCancelled else { return }
            await self.connect(tab)
            guard !Task.isCancelled else { return }
            if tab.connected {
                // A session saved to open its files (an Xftp profile, say) browses without asking for a terminal.
                if tab.showsFiles {
                    await self.refreshFiles(tab)
                    if inNewWindow { self.openFileTransfer(for: tab) } else { self.filesRequest = FilesRequest(tab: tab.id) }
                } else { await self.startTerminal(tab) }
            }
            tab.savedConnectionTask = nil
        }
        return tab
    }
    public func openSavedFolder(_ id: UUID) throws {
        let items = sessionTree.connections(in: id)
        guard items.count <= 50 else { throw WorkspaceError.invalid("Open at most 50 saved sessions at once. Select a smaller folder.") }
        for item in items { openSaved(item) }
    }
    public func saveConnection(_ tab: SessionTab, name: String, parent: UUID?) throws {
        guard let port = Int(tab.port) else { throw WorkspaceError.invalid("Enter a valid port.") }
        var settings = SavedConnection(host: tab.host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, username: tab.username,
            proxyHost: tab.useProxy ? tab.proxyHost : nil, proxyPort: tab.useProxy ? Int(tab.proxyPort) : nil, identityPath: tab.identityPath, opensFiles: tab.showsFiles, jumpSessionID: tab.jumpSessionID,
            usesAgent: tab.useAgent, agentSocket: tab.agentSocket, proxyKind: tab.proxyKind,
            confirmsEachConnection: tab.confirmsEachConnection)
        settings.forwardingRules = tab.forwardingRules.isEmpty ? nil : tab.forwardingRules
        try settings.validate()
        let id = try sessionTree.add(name: name, parent: parent, connection: settings)
        if tab.savedSessionID == nil { tab.savedSessionID = id }
    }
    public func importProfile(_ url: URL) throws {
        let profile = try SessionProfile(data: limitedData(url), name: url.deletingPathExtension().lastPathComponent)
        let settings = try SSHConnectionSettings(profile: profile)
        let tab = addTab(); tab.title = profile.name; tab.host = settings.host; tab.port = String(settings.port); tab.username = settings.username
        tab.showsFiles = profile.resolvedProtocol == .sftp
        var options = TerminalOptions(); options.rows = min(100, max(10, profile.terminal.rows)); options.cols = min(240, max(40, profile.terminal.cols))
        options.scrollbackSize = 1000; tab.screen = TerminalScreen(options: options)
        if !profile.connection.proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.useProxy = true
            tab.proxyHost = ""
            tab.error = "This profile declares a proxy. Configure its address below before connecting."
        }
    }
    public func importColors(_ url: URL, tab: SessionTab) throws { tab.colorScheme = try Formats.ColorScheme(data: limitedData(url), name: url.deletingPathExtension().lastPathComponent); tab.screenRevision += 1 }
    public func importHighlights(_ url: URL, tab: SessionTab) throws { tab.highlights = try HighlightSet(data: limitedData(url), name: url.deletingPathExtension().lastPathComponent); tab.screenRevision += 1 }
    private func limitedData(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw WorkspaceError.invalid("Settings file exceeds 1 MiB.") }; return data
    }
    public func refreshVault() async {
        vaultState = await vault.state
        vaultHasTouchID = await vault.touchIDEnrolled
        savesWithoutUnlock = await vault.savesWithoutUnlock
        vaultEntries = await vault.vaultIdentifiers
    }
    public func configureVault(password: String, create: Bool) async {
        guard !vaultBusy else { return }; vaultBusy = true; error = nil
        do {
            if create { try await vault.create(password: password) } else { try await vault.unlock(password: password) }
            await vault.persistSessionSecrets()
            try await vault.enableTouchIDAfterPasswordUnlock()
        }
        catch { self.error = message(for: error) }
        await refreshVault(); vaultBusy = false
    }
    func unlockVaultWithTouchID() async {
        guard !vaultBusy else { return }
        vaultBusy = true
        error = nil
        do {
            try await vault.unlockWithTouchID(reason: T("Unlock the MShell password vault"))
            await vault.persistSessionSecrets()
        }
        catch { self.error = message(for: error) }
        await refreshVault()
        vaultBusy = false
    }
    public func lockVault() async { await vault.lock(); await refreshVault() }
    /// Stops using the tab's key: the saved session forgets it, and so does the saved passphrase unless another
    /// saved session still uses the same key. The key file stays.
    func removeKey(from tab: SessionTab) async {
        guard let path = tab.identityPath else { return }
        tab.identityPath = nil
        do {
            if let id = tab.savedSessionID, let node = sessionTree.node(id), var connection = node.connection,
               connection.identityPath == path {
                connection.identityPath = nil
                try sessionTree.updateConnection(id, name: node.name, connection: connection)
            }
            try await forgetSignIn(account: tab.credentialID, keyPath: path)
        } catch {
            tab.error = message(for: error)
        }
    }

    /// Withdraws what let an account connect without typing, after its key is removed: the account's remembered
    /// password is deleted, so the next connection, also from the session tree, needs the password typed again (or
    /// the vault unlocked, if a copy was put there). The key's passphrase goes too unless another saved session
    /// still uses that key.
    func forgetSignIn(account: String, keyPath: String) async throws {
        try await vault.forgetRemembered(id: account)
        if !sessionTree.nodes.contains(where: { $0.connection?.identityPath == keyPath }) {
            try await vault.forgetRemembered(id: Self.passphraseID(keyPath))
        }
        await refreshVault()
    }

    // MARK: Saved sign-ins list

    /// Asks for Touch ID or the Mac password before the saved sign-ins are listed. Returns false when cancelled.
    /// Changing whether a saved session asks on every connection needs the master password when a vault exists
    /// (`verifyMasterPassword`), and Touch ID or the Mac password otherwise.
    func verifyMasterPassword(_ password: String) async -> Bool { await vault.verifyMasterPassword(password) }
    func authorizeAskChange() async -> Bool {
        do { try await confirmOwner(T("change whether this session asks on every connection")); return true }
        catch { return false }
    }

    func authorizeSavedSignIns() async -> Bool {
        do { try await confirmOwner(T("view saved passwords")); return true }
        catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) { return false }
        catch { self.error = "Touch ID or the Mac password is required to view saved passwords."; return false }
    }

    func savedSignIns() async -> [SavedSignIn] {
        let connections = sessionTree.nodes.compactMap { node in node.connection.map { (node.name, $0) } }
        return await vault.savedEntries().map { entry, place in
            if entry.hasPrefix("passphrase:") {
                let path = String(entry.dropFirst("passphrase:".count))
                let names = connections.filter { $0.1.identityPath == path }.map(\.0)
                return SavedSignIn(entry: entry, place: place, isPassphrase: true,
                                   account: URL(fileURLWithPath: path).lastPathComponent, detail: path, sessions: names)
            }
            let names = connections.filter { "\($0.1.username)@\(KnownHosts.endpoint(host: $0.1.host, port: $0.1.port))" == entry }.map(\.0)
            return SavedSignIn(entry: entry, place: place, isPassphrase: false, account: entry, detail: nil, sessions: names)
        }
    }

    func revealSignIn(_ item: SavedSignIn) async throws -> String { try await vault.revealSaved(id: item.entry, in: item.place) }

    func removeSignIn(_ item: SavedSignIn) async throws {
        try await vault.removeSaved(id: item.entry, from: item.place)
        await refreshVault()
    }

    /// Deletes the account's password from the vault and from this launch's memory, so the next connection asks.
    func removeFromVault(_ tab: SessionTab) async {
        let id = tab.credentialID
        do {
            try await vault.removeSaved(id: id, from: .vault)
            await vault.forgetForSession(id: id)
        } catch VaultError.locked {
            tab.error = "Unlock the password vault to delete its entries."
        } catch {
            tab.error = message(for: error)
        }
        await refreshVault()
    }

    /// Puts the account's password in the master-password vault: the one typed in the form, or the one remembered.
    /// It is a copy the user keeps on purpose; signing in remembers passwords on this Mac without it.
    public func savePassword(_ tab: SessionTab) async {
        guard tab.identityPath == nil, !tab.useAgent else { return }
        do {
            let secret = tab.password.isEmpty ? try await vault.password(id: tab.credentialID) : tab.password
            try await vault.addToVault(id: tab.credentialID, secret: secret)
            await refreshVault()
        }
        catch { tab.error = message(for: error) }
    }
}

/// One entry in the saved sign-ins list: an account password or a key passphrase.
struct SavedSignIn: Identifiable, Equatable {
    /// The vault entry ID: `user@[host]:port` or `passphrase:<key path>`.
    let entry: String
    /// Remembered on this Mac, or kept in the master-password vault.
    let place: CredentialVault.Place
    var id: String { (place == .vault ? "vault:" : "mac:") + entry }
    let isPassphrase: Bool
    let account: String
    let detail: String?
    /// Saved sessions that use it.
    let sessions: [String]
}

func message(for error: Error) -> String {
    if let error = error as? VaultError {
        switch error {
        case .locked: return "Enter a connection password or unlock the password vault."
        case .wrongPassword: return "The master password is incorrect."
        case .notFound: return "No password is saved for this account. Enter a connection password."
        case .passwordLength: return "The master password must contain 6–50 characters."
        default: return "The vault could not be read or updated: \(error)"
        }
    }
    if let error = error as? SSHError {
        switch error {
        case .authenticationFailed: return "SSH authentication failed. Check the username and password."
        case .connectFailed(let detail): return "Connection failed: \(detail)"
        case .commandFailed(let detail): return "Command failed: \(detail)"
        case .invalidSettings(let detail): return "Invalid connection settings: \(detail)"
        case .notConnected: return "The session is disconnected."
        }
    }
    return error.localizedDescription
}

/// Asks the window to show the files of a session that has just connected.
struct FilesRequest: Equatable {
    let tab: UUID
    let nonce = UUID()
}
