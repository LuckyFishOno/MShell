import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileTransfer
import Ssh

public struct DesktopView: View {
    @StateObject var model: WorkspaceModel
    @State var masterPassword = ""
    @State var vaultExpanded = false
    @State var showingSignIns = false
    @AppStorage("showsConnectionTree") var showsTree = true
    @AppStorage("showsComposeBar") var showsCompose = true
    @AppStorage("sideRailPanel") var railPanel = SideRailPanel.sessions
    @State var sidebar: WorkspaceSidebar?
    @State var importRequest: FolderImportRequest?
    @State var stripTargeted = false
    @State var splitRatios: [String: CGFloat] = [:]
    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Group {
            switch model.layout {
            case .native: nativeLayout
            case .terminal: xshellLayout
            case .transfer: mobaLayout
            }
        }
        .toolbar { workspaceToolbar }
        .toolbarBackground(model.theme.header.color, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .frame(minWidth: model.layout == .transfer ? 1110 : 1040, minHeight: 700)
        .background(model.theme.background.color)
        .foregroundStyle(model.theme.foreground.color)
        .tint(model.theme.accent.color)
        .background(ThemeTitlebar(theme: model.theme))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(item: $importRequest) { request in
            ProfileImportView(store: model.sessionTree, source: request.url, parent: request.parent, kind: request.source)
        }
        .task {
            await model.refreshVault()
            // A locked vault is the first thing to open after launch: show its unlock field.
            if model.vaultState == "Locked" { vaultExpanded = true }
        }
        .onDisappear { Task { await model.closeWorkspaceTabs() } }
    }

    /// The Mac layout: connection tree, flat tabs over floating panes, and optional right-hand panels.
    private var nativeLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsTree {
                    connectionSidebar
                        .padding(13).frame(width: 254).background(model.theme.sidebar.color)
                        .transition(.move(edge: .leading))
                    workspaceDivider
                }
                VStack(spacing: 0) {
                    tabStrip()
                    sessionArea
                }
                trailingSidebar
            }
            errorBanner
        }
    }

    /// The saved-connection tree with the password vault under it.
    var connectionSidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
            SessionTreeView(store: model.sessionTree, model: model, importFolder: chooseImportFolder,
                            importOpenSSH: chooseOpenSSHConfig)
            Divider().opacity(0.5)
            if model.savesWithoutUnlock { savedPasswordsSection }
            vaultSection
        }
        .sheet(isPresented: $showingSignIns) { SavedSignInsView(model: model) }
    }

    private var savedPasswordsButton: some View {
        Button {
            Task { if await model.authorizeSavedSignIns() { showingSignIns = true } }
        } label: {
            Label(T("Saved passwords…"), systemImage: "key.viewfinder")
        }
        .help(T("Asks for Touch ID or the Mac password"))
        .accessibilityIdentifier("savedPasswordsButton")
    }

    /// With a Secure Enclave, a password that signs in is remembered on this Mac and connects again without asking.
    private var savedPasswordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            savedPasswordsButton.buttonStyle(.plain).font(.system(size: 12))
            Text(T("Passwords that sign in are remembered on this Mac and connect again without asking, also after a restart."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submitMasterPassword() {
        guard !model.vaultBusy, !masterPassword.isEmpty else { return }
        let password = masterPassword; masterPassword = ""
        Task { await model.configureVault(password: password, create: model.vaultState == "Not configured") }
    }

    private var masterPasswordUnlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Return in the field does what the button does.
            SecureField(T("Master password"), text: $masterPassword)
                .onSubmit(submitMasterPassword)
            Button(T(model.vaultState == "Not configured" ? "Create vault" : "Unlock vault"), action: submitMasterPassword)
                .disabled(model.vaultBusy || masterPassword.isEmpty)
            if model.vaultHasTouchID {
                Button { Task { await model.unlockVaultWithTouchID() } } label: {
                    Label(T("Unlock with Touch ID"), systemImage: "touchid")
                }.disabled(model.vaultBusy)
            }
        }
    }

    /// The master-password vault: copies the user keeps on purpose with **Add to vault**. On a Mac without a Secure
    /// Enclave it is also where passwords that sign in are kept.
    private var vaultSection: some View {
        DisclosureGroup(isExpanded: $vaultExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if model.vaultState != "Unlocked" {
                    masterPasswordUnlock
                } else { Button(T("Lock vault")) { Task { await model.lockVault() } } }
                if !model.savesWithoutUnlock { savedPasswordsButton }
                Text(T(!model.savesWithoutUnlock
                       ? "Unlock once after opening MShell. Passwords that sign in are saved here, and every connection fills them in without asking again until you lock the vault or quit."
                       : model.vaultState == "Not configured"
                       ? "Create a vault to keep passwords under a master password. While it is unlocked, connections stop asking for Touch ID one by one."
                       : "Unlock once after opening MShell, and connections stop asking for Touch ID one by one. While it is locked, sessions set to ask on every connection ask; the others connect with the password remembered on this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Label(T("Password vault"), systemImage: "lock.shield")
                Spacer()
                Text(T(model.vaultState)).foregroundStyle(.secondary)
                // Collapsed and locked: unlock with Touch ID without opening the section.
                if !vaultExpanded, model.vaultState == "Locked", model.vaultHasTouchID {
                    Button { Task { await model.unlockVaultWithTouchID() } } label: {
                        Image(systemName: "touchid").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.vaultBusy)
                    .help(T("Unlock with Touch ID"))
                    .accessibilityLabel(T("Unlock with Touch ID"))
                }
            }.font(.system(size: 12))
        }
    }

    /// Quick commands or the theme list, slid in from the right.
    @ViewBuilder var trailingSidebar: some View {
        switch sidebar {
        case .themes:
            workspaceDivider
            themeSidebar.transition(.move(edge: .trailing).combined(with: .opacity))
        case .commands:
            if let tab = model.selected {
                workspaceDivider
                QuickCommandPanel(model: model, store: model.quickCommands, tab: tab) { withAnimation { sidebar = nil } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder var errorBanner: some View {
        if let error = model.error {
            HStack { Image(systemName: "exclamationmark.triangle"); Text(T(error)); Spacer(); Button(T("Dismiss")) { model.error = nil } }
                .foregroundStyle(.red).padding(10)
        }
    }

    func toggleSidebar(_ panel: WorkspaceSidebar) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { sidebar = sidebar == panel ? nil : panel }
    }

    /// Tab bar entries in tab order. A split group is one entry, placed where its first pane's tab was.
    var stripItems: [StripItem] {
        var seen = Set<Int>()
        return model.tabs.compactMap { tab in
            guard let index = model.groups.firstIndex(where: { $0.contains(tab.id) }) else { return .tab(tab) }
            return seen.insert(index).inserted ? .group(model.groups[index]) : nil
        }
    }

    func tabStrip(_ chrome: TabChrome = .flat) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let items = stripItems
                let addWidth: CGFloat = 40
                // Tabs share the bar evenly and shrink down to an icon instead of scrolling out of view.
                let width = max(StripTab.minimumWidth, min(StripTab.maximumWidth, (proxy.size.width - addWidth) / CGFloat(max(items.count, 1))))
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        stripTab(item, width: width, chrome: chrome, number: index + 1)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    Button { model.addTab() } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 28, height: min(28, chrome.height)).contentShape(Rectangle())
                    }
                    .buttonStyle(StripPlusStyle())
                    .help(T("New connection"))
                    .frame(width: addWidth)
                    Spacer(minLength: 0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: items.map(\.id))
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: width)
            }
            .frame(height: chrome.height)
            .padding(.top, chrome == .flat ? 0 : 4)
            .padding(.horizontal, chrome == .flat ? 0 : 4)
            .background(model.theme.tabs.color)
            .overlay {
                if stripTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(model.theme.accent.color, lineWidth: 2)
                        .background(model.theme.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .padding(2).allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: stripTargeted)
            // Dropping a pane on the tab bar takes it out of its split and makes it a tab again.
            .onDrop(of: [.plainText], isTargeted: Binding(get: { stripTargeted }, set: { targeted in
                stripTargeted = targeted && model.group(containing: PaneDrag.current) != nil
            })) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = object as? String, let id = PaneDrag.tabID(from: text) else { return }
                    DispatchQueue.main.async {
                        PaneDrag.current = nil
                        model.detachPane(id)
                    }
                }
                return true
            }
            Rectangle().fill(model.theme.foreground.color.opacity(0.08)).frame(height: 1)
        }
    }

    @ViewBuilder private func stripTab(_ item: StripItem, width: CGFloat, chrome: TabChrome, number: Int) -> some View {
        switch item {
        case .tab(let tab):
            StripTab(title: chrome.title(UIStrings.text(tab.title, language: model.language), number: number), chrome: chrome,
                     symbol: tab.isLocal ? "terminal" : "network",
                     connected: tab.connected, width: width, selected: tab.id == model.selection, theme: model.theme,
                     select: { model.selectTab(tab.id) },
                     close: { Task { await model.closeTab(tab) } })
                .onDrag { PaneDrag.provider(for: tab.id) }
                .help(T("Drag onto a pane to split it"))
        case .group(let layout):
            let members = layout.tabIDs.compactMap { id in model.tabs.first { $0.id == id } }
            // Like Termius, a split is a "Workspace"; further splits are numbered. The tooltip lists its panes.
            let workspaceNumber = (model.groups.firstIndex(of: layout) ?? 0) + 1
            StripTab(title: chrome.title(T("Workspace") + (workspaceNumber > 1 ? " \(workspaceNumber)" : ""), number: number), chrome: chrome,
                     detail: members.map { UIStrings.text($0.title, language: model.language) }.joined(separator: "\n"),
                     symbol: "rectangle.split.2x1", connected: members.contains(where: \.connected), width: width,
                     selected: layout.contains(model.selection), theme: model.theme,
                     select: { if !layout.contains(model.selection), let first = layout.tabIDs.first { model.selectTab(first) } },
                     close: { Task { for tab in members { await model.closeTab(tab) } } })
        }
    }

    /// Native window toolbar. The Mac layout keeps its actions here; the Xshell and MobaXterm layouts
    /// draw their own toolbars in the window, so only the sidebar button and the layout menu stay.
    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { withAnimation(.easeOut(duration: 0.18)) { showsTree.toggle() } } label: {
                Label(T(showsTree ? "Hide connection tree" : "Show connection tree"), systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help(T(showsTree ? "Hide connection tree" : "Show connection tree"))
            .accessibilityIdentifier("connectionTreeToggle")
        }
        // A flexible space pushes the session actions to the trailing edge, like Finder and Terminal.
        ToolbarItem(placement: .automatic) { Spacer() }
        if model.layout == .native {
            ToolbarItemGroup(placement: .automatic) {
                newConnectionMenu
            }
            ToolbarItemGroup(placement: .automatic) {
                Toggle(isOn: Binding(get: { sidebar == .commands }, set: { on in withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { sidebar = on ? .commands : nil } })) {
                    Label(T("Quick commands"), systemImage: "command")
                }
                .help(T("Quick commands"))
                .accessibilityIdentifier("quickCommandsToggle")
                Toggle(isOn: Binding(get: { sidebar == .themes }, set: { on in withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { sidebar = on ? .themes : nil } })) {
                    Label(T("Color theme"), systemImage: "paintpalette")
                }
                .help(T("Color theme"))
                .accessibilityIdentifier("workspaceThemeToggle")
            }
        }
        ToolbarItem(placement: .automatic) { layoutMenu }
    }

    var newConnectionMenu: some View {
        Menu {
            newConnectionItems
        } label: {
            Label(T("New connection"), systemImage: "plus")
        } primaryAction: { model.addTab() }
        .help(T("New connection"))
        .accessibilityIdentifier("newConnectionMenu")
    }

    @ViewBuilder var newConnectionItems: some View {
        Button { model.addTab() } label: { Label(T("New connection"), systemImage: "network") }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        Button { model.addLocalTab() } label: { Label(T("Local terminal"), systemImage: "terminal") }
            .keyboardShortcut("t", modifiers: .command)
        Divider()
        Button(T("Import session…")) { chooseFile(types: ["xsh", "xfp"]) { try model.importProfile($0) } }
        Button(T("Import Xshell folder…"), action: chooseImportFolder)
        Button(T("Import OpenSSH config…"), action: chooseOpenSSHConfig)
    }

    /// Switches between the macOS, Xshell, and MobaXterm arrangements. The choice applies at once.
    private var layoutMenu: some View {
        Menu {
            Picker(T("Layout"), selection: Binding(get: { model.layout }, set: { layout in
                withAnimation(.easeInOut(duration: 0.2)) {
                    do { try model.selectLayout(layout) } catch { model.error = error.localizedDescription }
                }
            })) {
                ForEach(WorkspaceLayout.allCases) { layout in
                    Label { Text(layout.title); Text(layout.detail) } icon: { Image(systemName: layout.symbol) }.tag(layout)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(T("Layout"), systemImage: model.layout.symbol)
        }
        .help(T("Layout") + ": " + model.layout.title)
        .accessibilityIdentifier("layoutMenu")
    }

    /// Panes float as cards over a slightly darker well. Pane frames change without animation: animating
    /// them would resize and redraw every terminal on each frame.
    var sessionArea: some View {
        ZStack {
            if let split = model.split {
                if let id = model.maximizedPane, let tab = model.tabs.first(where: { $0.id == id }) {
                    pane(tab, card: true)
                } else {
                    paneTree(split.root)
                }
            } else if let tab = model.selected {
                pane(tab, card: false)
            }
        }
        .padding(model.layout == .native ? 5 : 0)
        .background(model.theme.tabs.color)
    }

    private func paneDropTarget(_ target: UUID) -> PaneDropTarget {
        PaneDropTarget(target: target, accent: model.theme.accent.color,
                       accepts: { [model] dragged in model.canSplit(dragged) && model.canSplit(target) }) { dragged, edge in
            model.placeTab(dragged, at: edge, of: target)
        }
    }

    /// Draws a split layout recursively; every divider can be dragged, and a double-click evens it out.
    private func paneTree(_ node: WorkspacePane) -> AnyView {
        switch node {
        case .tab(let id):
            guard let tab = model.tabs.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            return AnyView(pane(tab, card: true))
        case .split(let axis, let first, let second):
            // Ratios are kept per pair of panes, so moving one divider leaves the others where they were.
            let key = "\(first.tabIDs[0])|\(second.tabIDs[0])"
            let ratio = Binding(get: { splitRatios[key] ?? 0.5 }, set: { splitRatios[key] = $0 })
            return AnyView(PaneSplitView(axis: axis, ratio: ratio, first: paneTree(first), second: paneTree(second),
                                         dividerColor: model.theme.accent.color))
        }
    }

    /// One session as a floating card. In a split, the focused card gets an accent ring and a deeper shadow.
    private func pane(_ tab: SessionTab, card inSplit: Bool) -> some View {
        let focused = inSplit && model.selection == tab.id
        let classic = model.layout != .native
        // Xshell and MobaXterm draw square, edge-to-edge panes; the Mac layout floats rounded cards.
        let shape = RoundedRectangle(cornerRadius: classic ? 0 : 10, style: .continuous)
        return SessionPane(model: model, tab: tab, compact: inSplit, dockedFiles: model.layout == .transfer,
                           flat: classic, showsHeader: !classic || inSplit)
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background.color)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(focused ? model.theme.accent.color.opacity(0.75) : model.theme.foreground.color.opacity(0.08),
                                   lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                if model.broadcastInput && inSplit {
                    shape.strokeBorder(Color.orange.opacity(0.85), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { model.selectTab(tab.id, focusTerminal: false) })
            .modifier(paneDropTarget(tab.id))
    }

    var workspaceDivider: some View {
        Rectangle().fill(model.theme.border?.color ?? model.theme.foreground.color.opacity(0.16)).frame(width: 1)
    }

    var themeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(T("Color theme"), systemImage: "paintpalette").font(.headline)
                Spacer()
                Button { sidebar = nil } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("Close theme panel"))
            }
            ThemeGallery(themes: model.themes, selectedID: model.displayedThemeID) { id in
                do { try model.selectTheme(id) }
                catch { model.error = error.localizedDescription }
            }
        }
        .padding(13)
        .frame(width: 236)
        .background(model.theme.sidebar.color)
    }

    func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = T("Review profiles")
        if panel.runModal() == .OK, let url = panel.url {
            importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination)
        }
    }

    /// Opens `~/.ssh/config` for review, or asks for another file when it does not exist.
    func chooseOpenSSHConfig() {
        let standard = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        var url: URL? = FileManager.default.isReadableFile(atPath: standard.path) ? standard : nil
        if url == nil {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.showsHiddenFiles = true
            panel.directoryURL = standard.deletingLastPathComponent()
            panel.prompt = T("Review hosts")
            if panel.runModal() == .OK { url = panel.url }
        }
        if let url {
            importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination, source: .openSSHConfig)
        }
    }

    func chooseFile(types: [String], action: (URL) throws -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            do { try action(url) } catch { model.error = error.localizedDescription }
        }
    }
}

enum WorkspaceSidebar {
    case commands, themes
}

struct FolderImportRequest: Identifiable {
    enum Source { case xshellFolder, openSSHConfig }
    let id = UUID()
    let url: URL
    let parent: UUID?
    var source: Source = .xshellFolder
}

/// Drag payload for a tab chip. The prefix keeps ordinary dragged text from being read as a tab.
enum PaneDrag {
    static let prefix = "mshell-tab:"
    /// The tab being dragged, so a pane does not offer to split around itself.
    @MainActor static var current: UUID?

    @MainActor static func provider(for id: UUID) -> NSItemProvider {
        current = id
        return NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    static func tabID(from text: String) -> UUID? {
        guard text.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(prefix.count)))
    }
}

/// Lets a tab chip be dropped on a pane: near an edge splits toward that edge, the middle replaces the pane.
private struct PaneDropTarget: ViewModifier {
    let target: UUID
    let accent: Color
    /// Whether the tab being dragged may join this pane. Only connected sessions can be split.
    let accepts: (UUID?) -> Bool
    let place: (UUID, PaneDropEdge) -> Void
    @State private var size = CGSize.zero
    @State private var hover: PaneDropEdge?

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { proxy in
                Color.clear.onAppear { size = proxy.size }.onChange(of: proxy.size) { _, new in size = new }
            })
            .overlay { if let hover { PaneDropHighlight(edge: hover, accent: accent).transition(.opacity) } }
            .animation(.easeOut(duration: 0.12), value: hover)
            .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: target, size: size, hover: $hover, accepts: accepts, place: place))
    }
}

private struct PaneDropDelegate: DropDelegate {
    let target: UUID
    let size: CGSize
    @Binding var hover: PaneDropEdge?
    let accepts: (UUID?) -> Bool
    let place: (UUID, PaneDropEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let dragged = MainActor.assumeIsolated { PaneDrag.current }
        guard dragged != target, MainActor.assumeIsolated({ accepts(dragged) }) else {
            hover = nil
            return DropProposal(operation: .forbidden)
        }
        hover = PaneDropEdge.at(info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hover = nil }

    func performDrop(info: DropInfo) -> Bool {
        let edge = PaneDropEdge.at(info.location, in: size)
        hover = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = PaneDrag.tabID(from: text) else { return }
            DispatchQueue.main.async { PaneDrag.current = nil; place(id, edge) }
        }
        return true
    }
}

/// Shows where a dropped tab will go: the half of the pane at that edge, or the whole pane.
private struct PaneDropHighlight: View {
    let edge: PaneDropEdge
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let area = region(in: proxy.size)
            RoundedRectangle(cornerRadius: 6)
                .fill(accent.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 2))
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
                .animation(.easeOut(duration: 0.12), value: edge)
        }
        .padding(4)
        .allowsHitTesting(false)
    }

    private func region(in size: CGSize) -> CGRect {
        let halfWidth = size.width / 2, halfHeight = size.height / 2
        switch edge {
        case .left: return CGRect(x: 0, y: 0, width: halfWidth, height: size.height)
        case .right: return CGRect(x: halfWidth, y: 0, width: halfWidth, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: halfHeight)
        case .bottom: return CGRect(x: 0, y: halfHeight, width: size.width, height: halfHeight)
        case .center: return CGRect(origin: .zero, size: size)
        }
    }
}

enum StripItem: Identifiable {
    case tab(SessionTab)
    case group(WorkspaceSplit)
    var id: UUID {
        switch self {
        case .tab(let tab): return tab.id
        case .group(let layout): return layout.tabIDs[0]
        }
    }
}

private struct StripPlusStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A flat tab: the selected tab takes the content background. Narrow tabs drop the title, then the
/// status dot, and finally show only the icon. The close button lights up only under the pointer.
/// How tabs are drawn: flat Mac tabs, Xshell's boxed tabs, or MobaXterm's rounded, numbered tabs.
enum TabChrome: Equatable {
    case flat, boxed, rounded
    var height: CGFloat { self == .flat ? 34 : 28 }
    func title(_ title: String, number: Int) -> String { self == .rounded ? "\(number). \(title)" : title }
}

struct StripTab: View {
    static let minimumWidth: CGFloat = 38
    static let maximumWidth: CGFloat = 200
    let title: String
    var chrome: TabChrome = .flat
    var detail: String? = nil
    let symbol: String
    let connected: Bool
    let width: CGFloat
    let selected: Bool
    let theme: WorkspaceTheme
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        let wide = width >= 64, showsTitle = width >= 70, showsDot = width >= 110
        // MobaXterm keeps a close button on every wide tab; the other styles show it under the pointer.
        let fixedClose = chrome == .rounded && showsTitle
        // A tap gesture rather than a Button: a Button keeps the mouse and stops the tab from being dragged.
        HStack(spacing: 6) {
            // The close button takes the icon's place under the pointer, so it costs no width.
            ZStack {
                icon.opacity(hovering && !fixedClose ? 0 : 1)
                if hovering && !fixedClose { closeButton.transition(.opacity) }
            }
            .frame(width: 16, height: 16)
            if showsTitle {
                Text(title).font(.system(size: chrome == .flat ? 12 : 11.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if showsDot && chrome != .rounded {
                    Circle().fill(connected ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
                if fixedClose { closeButton }
            }
        }
        .padding(.horizontal, wide ? 8 : 0)
        .frame(width: chrome == .flat ? width : max(width - 2, 30), height: chrome.height, alignment: showsTitle ? .leading : .center)
        .background { tabBackground }
        .overlay(alignment: .top) { if selected && chrome != .rounded { Rectangle().fill(theme.accent.color).frame(height: 2) } }
        .overlay(alignment: .trailing) {
            if !selected && chrome == .flat { Rectangle().fill(theme.foreground.color.opacity(0.1)).frame(width: 1, height: 16) }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.18), value: selected)
        .help(detail ?? title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    @ViewBuilder private var tabBackground: some View {
        switch chrome {
        case .flat:
            if selected { theme.background.color.shadow(color: .black.opacity(0.18), radius: 3, y: -1) }
            else if hovering { Color.primary.opacity(0.05) }
        case .boxed, .rounded:
            let radius: CGFloat = chrome == .boxed ? 3 : 7
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
            shape.fill(selected ? theme.background.color : hovering ? theme.header.color.opacity(0.9) : theme.header.color.opacity(0.55))
                .overlay(shape.stroke(theme.foreground.color.opacity(selected ? 0.18 : 0.1), lineWidth: 1))
                // The selected tab joins the pane below it.
                .overlay(alignment: .bottom) { if selected { theme.background.color.frame(height: 1.5).padding(.horizontal, 1) } }
        }
    }

    private var icon: some View {
        Group {
            if chrome == .flat {
                Image(systemName: symbol).foregroundStyle(selected ? theme.accent.color : .secondary)
            } else {
                // Classic tabs color the icon by state: green when connected, gray otherwise.
                Image(systemName: symbol).foregroundStyle(connected ? Color.green : Color.secondary)
            }
        }
        .font(.system(size: 11))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .foregroundStyle(hoveringClose ? Color.primary : Color.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(hoveringClose ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .help(T("Close connection"))
    }
}

/// A small borderless icon button that lights up only while the pointer is over it.
struct PaneIconButton: View {
    let symbol: String
    var active = false
    var activeColor: Color = .accentColor
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? activeColor : hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(T(help))
        .accessibilityLabel(T(help))
    }
}

struct SessionPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    let compact: Bool
    let dockedFiles: Bool
    /// Square, edge-to-edge drawing for the Xshell and MobaXterm layouts.
    let flat: Bool
    /// Classic layouts drop the pane header for a lone connected pane: the tab and status bar say the same.
    let showsHeader: Bool
    @State private var forwarding = false
    @State private var reviewedHostKey: HostKeyChange?
    @State private var confirmingVaultRemoval = false
    @State private var keyNeedsPassphrase = true
    @State private var jumpKeyNeedsPassphrase = true
    init(model: WorkspaceModel, tab: SessionTab, compact: Bool = false, dockedFiles: Bool = false, flat: Bool = false, showsHeader: Bool = true) {
        self.model = model; self.tab = tab; self.compact = compact
        self.dockedFiles = dockedFiles; self.flat = flat; self.showsHeader = showsHeader
    }
    private var live: Bool { tab.connected || tab.isLocal }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader || !live || tab.busy { header }
            VStack(alignment: .leading, spacing: 10) {
                if live {
                    status
                } else {
                    // A split pane can be short and narrow: the sign-in form scrolls rather than being cut off, and
                    // the terminal below only appears when it still holds output from before the connection dropped.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            connectionForm
                            status
                        }
                        .padding(1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: tab.transportLost ? 260 : .infinity, alignment: .top)
                    .layoutPriority(1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if live || tab.transportLost { content }
            }
            .padding(flat ? (live ? 0 : 10) : compact ? 6 : 10)
        }
        .animation(.easeOut(duration: 0.2), value: tab.connected)
        .animation(.easeOut(duration: 0.18), value: tab.showsFiles)
        .textFieldStyle(.roundedBorder)
        .sheet(item: visibleHostKey, onDismiss: { model.answerHostKey(tab, approve: false) }) { prompt in
            VStack(alignment: .leading, spacing: 18) {
                Label(T("Verify this server"), systemImage: "key.horizontal").font(.title2.bold())
                Text(prompt.endpoint).font(.headline)
                Text(T("Compare this fingerprint with the server administrator before trusting this connection."))
                Text(prompt.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("hostFingerprint")
                HStack { Button(T("Cancel")) { model.answerHostKey(tab, approve: false) }; Spacer(); Button(T("Trust and connect")) { model.answerHostKey(tab, approve: true) }.buttonStyle(.borderedProminent).accessibilityIdentifier("trustHostButton") }
            }.padding(24).frame(width: 530)
        }
        .sheet(item: $reviewedHostKey) { change in
            VStack(alignment: .leading, spacing: 14) {
                Label(T("Host key changed"), systemImage: "exclamationmark.shield").font(.title2.bold())
                Text(change.endpoint).font(.headline).textSelection(.enabled)
                Text(T("Confirm the new fingerprint from the server console or with your administrator before updating the saved key."))
                    .fixedSize(horizontal: false, vertical: true)
                fingerprint(T("Saved fingerprint"), value: change.savedFingerprint)
                fingerprint(T("New fingerprint"), value: change.receivedFingerprint)
                HStack {
                    Spacer()
                    Button(T("Cancel")) { reviewedHostKey = nil }.keyboardShortcut(.cancelAction)
                    Button(T("Update key and reconnect"), role: .destructive) {
                        reviewedHostKey = nil
                        Task { await model.updateHostKeyAndReconnect(tab, change: change) }
                    }
                    .accessibilityIdentifier("updateHostKeyButton")
                }
            }
            .padding(24).frame(width: 555)
        }
        .sheet(isPresented: $forwarding) { PortForwardingView(model: model, tab: tab) }
        .task { if CommandLine.arguments.contains("--capture-files") { tab.showsFiles = true } }
        .task(id: tab.connected) { if tab.connected { await showSelectedPanel() } }
        .onChange(of: tab.showsFiles) { _, _ in Task { await showSelectedPanel() } }
        .onChange(of: tab.identityPath) { _, _ in tab.password = ""; tab.keyPassphrase = ""; tab.error = nil }
        .task(id: tab.identityPath) { keyNeedsPassphrase = await Self.needsPassphrase(tab.identityPath) }
        .task(id: model.sessionTree.node(tab.jumpSessionID)?.connection?.identityPath) {
            jumpKeyNeedsPassphrase = await Self.needsPassphrase(model.sessionTree.node(tab.jumpSessionID)?.connection?.identityPath)
        }
        .onChange(of: tab.useAgent) { _, _ in tab.password = "" }
        .onChange(of: tab.jumpSessionID) { _, id in
            tab.jumpSecret = ""
            if id != nil { tab.useProxy = false }
        }
    }

    /// Connection progress and the last error, shown above the terminal or under the sign-in form.
    @ViewBuilder private var status: some View {
        if let progress = tab.progress { ProgressView(value: progress).tint(model.theme.accent.color) }
        if let error = tab.error {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(T(error)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let change = tab.hostKeyChange, !tab.busy {
                    Button(T("Review host key…")) { reviewedHostKey = change }
                        .foregroundStyle(model.theme.foreground.color)
                        .accessibilityIdentifier("reviewHostKeyButton")
                }
                Button { tab.error = nil; tab.hostKeyChange = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.font(.callout).foregroundStyle(.red).padding(8).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var content: some View {
        if !tab.showsFiles || dockedFiles {
            if tab.connected && !tab.terminalReady && !tab.terminalStarting {
                Button(T("Open terminal")) { Task { await model.startTerminal(tab) } }
            }
            TerminalDisplay(tab: tab, model: model).clipShape(RoundedRectangle(cornerRadius: flat ? 0 : 8)).accessibilityIdentifier("terminalOutput")
        } else {
            RemoteFilesPane(model: model, tab: tab, compact: compact)
                .transition(.opacity)
        }
    }

    private static func needsPassphrase(_ path: String?) async -> Bool {
        guard let path else { return false }
        return await Task.detached { SSHPrivateKeyFile.needsPassphrase(at: URL(fileURLWithPath: path)) }.value
    }

    /// A thin Termius-style bar: what the pane is, and a few icon actions. Drag it to move the pane.
    private var header: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(tab.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Image(systemName: tab.isLocal ? "apple.logo" : "network").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(tab.isLocal ? "127.0.0.1" : tab.host.isEmpty ? T("New connection") : tab.host)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Text(subtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                if tab.busy || tab.terminalStarting { ProgressView().controlSize(.mini) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onDrag { PaneDrag.provider(for: tab.id) }
            .help(T("Drag onto a pane to split it"))

            if tab.connected && !tab.isLocal && !dockedFiles {
                PaneIconButton(symbol: tab.showsFiles ? "terminal" : "folder", active: tab.showsFiles,
                               help: tab.showsFiles ? "Terminal" : "Remote files") { tab.showsFiles.toggle() }
                    .accessibilityIdentifier("workspaceSections")
            }
            if !tab.isLocal {
                PaneIconButton(symbol: "arrow.left.arrow.right", help: "Port forwarding") { forwarding = true }
                    .accessibilityIdentifier("portForwardingButton")
            }
            if model.split?.contains(tab.id) == true {
                PaneIconButton(symbol: "dot.radiowaves.left.and.right", active: model.broadcastInput, activeColor: .orange,
                               help: model.broadcastInput ? "Stop typing into all panes" : "Type into all panes") { model.toggleBroadcastInput() }
                    .accessibilityIdentifier("broadcastInputButton")
                let maximized = model.maximizedPane == tab.id
                PaneIconButton(symbol: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: maximized ? "Restore pane" : "Maximize pane") {
                    model.toggleMaximizedPane(tab.id)
                }
                .accessibilityIdentifier("maximizePaneButton")
            }
            if !tab.connected && !tab.isLocal && !tab.busy {
                Button(T(tab.transportLost ? "Reconnect" : "Connect")) { Task { await model.connect(tab) } }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(model.theme.accent.color)
                    .accessibilityIdentifier("connectButton")
            }
            PaneIconButton(symbol: "xmark", help: tab.connected || tab.busy ? "Disconnect and close this session" : "Close connection") {
                Task { await model.disconnectAndClose(tab) }
            }
            .accessibilityIdentifier("disconnectButton")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 30)
        .background(model.theme.header.color.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(model.theme.foreground.color.opacity(0.07)).frame(height: 1) }
    }

    private var subtitle: String {
        if !tab.connected && !tab.busy { return T(tab.status) }
        if tab.isLocal { return "local, \(tab.username)" }
        return "ssh, \(tab.username)"
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            let credentialLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            credentialLayout {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    field("Host") { TextField("server.example.com", text: $tab.host).accessibilityIdentifier("hostField") }
                    field("Port") { TextField("22", text: $tab.port).accessibilityIdentifier("portField") }.frame(width: 55)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    field("Username") { TextField(T("Username"), text: $tab.username).accessibilityIdentifier("usernameField") }
                    if tab.identityPath == nil && tab.useAgent {
                        field("Authentication") {
                            Label(T("Keys from the SSH agent"), systemImage: "key.horizontal").foregroundStyle(.secondary)
                        }
                    } else if tab.identityPath == nil {
                        field("Password or vault entry") { SecureField(T("Password or vault entry"), text: $tab.password).accessibilityIdentifier("passwordField") }
                    } else if keyNeedsPassphrase {
                        // Only an encrypted key file has a passphrase; the MShell key and unencrypted keys do not.
                        field("Key passphrase") { SecureField(T("Key passphrase"), text: $tab.keyPassphrase) }
                    }
                }
            }.onSubmit { Task { await model.connect(tab) } }
            // One row when the pane is wide enough; in a narrow split pane, the proxy settings move to a second row.
            ViewThatFits(in: .horizontal) {
                HStack {
                    keyOptions
                    if tab.jumpSessionID == nil {
                        Divider().frame(height: 16)
                        proxyOptions(hostWidth: 170)
                    }
                    Spacer(minLength: 8)
                    savePasswordButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack { keyOptions; Spacer(minLength: 8); savePasswordButton }
                        VStack(alignment: .leading, spacing: 8) { keyOptions; savePasswordButton }
                    }
                    if tab.jumpSessionID == nil {
                        HStack { proxyOptions(hostWidth: nil) }
                    }
                }
            }
            HStack {
                JumpHostPicker(store: model.sessionTree, excluding: tab.savedSessionID, selection: $tab.jumpSessionID)
                    .frame(maxWidth: 290)
                if let jump = model.sessionTree.node(tab.jumpSessionID)?.connection,
                   jump.identityPath == nil ? jump.usesAgent != true : jumpKeyNeedsPassphrase {
                    let title = jump.identityPath == nil ? "Jump host password" : "Jump host key passphrase"
                    SecureField(T(title), text: $tab.jumpSecret).frame(maxWidth: 220)
                }
            }
        }
        .disabled(tab.busy)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var keyOptions: some View {
        IdentityFilePicker(path: $tab.identityPath) { Task { await model.removeKey(from: tab) } }
        Toggle(T("SSH agent"), isOn: $tab.useAgent).toggleStyle(.checkbox).fixedSize()
            .help(T("Offer the SSH agent's keys before the key file"))
    }

    @ViewBuilder private func proxyOptions(hostWidth: CGFloat?) -> some View {
        Toggle(T("Proxy"), isOn: $tab.useProxy).toggleStyle(.checkbox).fixedSize()
        if tab.useProxy {
            ProxyKindPicker(kind: $tab.proxyKind).frame(width: 92)
            TextField(T("Proxy host"), text: $tab.proxyHost).frame(width: hostWidth).frame(minWidth: 90)
            TextField(T("Port"), text: $tab.proxyPort).frame(width: 65)
        }
    }

    @ViewBuilder private var savePasswordButton: some View {
        // Without a vault there is nothing to add to: passwords that sign in are remembered on this Mac.
        if tab.identityPath == nil && !tab.useAgent && model.vaultState != "Not configured" {
            let stored = model.vaultEntries.contains(tab.credentialID)
            if stored {
                // Already in the vault: a mark that opens update and remove.
                let unlocked = model.vaultState == "Unlocked"
                Menu {
                    Button(T("Update vault")) { Task { await model.savePassword(tab) } }
                        .disabled(!unlocked || tab.password.isEmpty)
                    Button(T("Remove from vault…"), role: .destructive) { confirmingVaultRemoval = true }
                        .disabled(!unlocked)
                    if !unlocked { Text(T("Unlock the password vault to change it.")) }
                } label: {
                    Label(T("In vault"), systemImage: "checkmark.shield.fill")
                }
                .menuStyle(.button).fixedSize()
                .tint(.green).foregroundStyle(.green)
                .help(T("This account's password is saved in the password vault."))
                .accessibilityIdentifier("inVaultMark")
                .confirmationDialog(T("Remove this password from the vault?"), isPresented: $confirmingVaultRemoval) {
                    Button(T("Remove"), role: .destructive) { Task { await model.removeFromVault(tab) } }
                } message: {
                    Text(T("The next connection to this account asks for the password."))
                }
            } else {
                // Not "save password": signing in already saves it while the vault is unlocked.
                Button {
                    Task { await model.savePassword(tab) }
                } label: {
                    Label(T("Add to vault"), systemImage: "lock.shield")
                }
                .disabled(model.vaultState != "Unlocked")
                .help(T(model.vaultState != "Unlocked"
                        ? "Unlock the password vault to keep a copy of this password there."
                        : "Keeps a copy of this password in the master-password vault. Passwords that sign in are remembered on this Mac without it."))
                .accessibilityIdentifier("addToVaultButton")
            }
        }
    }

    private var visibleHostKey: Binding<HostKeyPrompt?> {
        Binding(get: {
            let inSplit = model.split?.contains(tab.id) == true
            return !inSplit || model.selection == tab.id ? tab.hostKeyPrompt : nil
        }, set: { _ in })
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(T(title)).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func fingerprint(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced()).textSelection(.enabled)
        }
    }
    private func showSelectedPanel() async {
        guard tab.connected else { return }
        if (!tab.showsFiles || dockedFiles) && !tab.terminalReady {
            await model.startTerminal(tab)
        }
    }
}
