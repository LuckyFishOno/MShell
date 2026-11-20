import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileTransfer

public struct DesktopView: View {
    @StateObject private var model: WorkspaceModel
    @State private var masterPassword = ""
    @State private var vaultExpanded = false
    @AppStorage("showsConnectionTree") private var showsTree = true
    @State private var sidebar: WorkspaceSidebar?
    @State private var importRequest: FolderImportRequest?
    @State private var stripTargeted = false
    @State private var splitRatios: [String: CGFloat] = [:]
    public init(model: WorkspaceModel) {
        _model = StateObject(wrappedValue: model)
        _sidebar = State(initialValue: model.layout == .terminal ? .commands : nil)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.layout == .terminal { tabStrip }
            HStack(spacing: 0) {
                if showsTree {
                    VStack(alignment: .leading, spacing: 13) {
                        SessionTreeView(store: model.sessionTree, model: model, importFolder: chooseImportFolder)
                        Divider().opacity(0.5)
                        DisclosureGroup(isExpanded: $vaultExpanded) {
                            VStack(alignment: .leading, spacing: 8) {
                                if model.vaultState != "Unlocked" {
                                    SecureField(T("Master password"), text: $masterPassword)
                                    Button(T(model.vaultState == "Not configured" ? "Create vault" : "Unlock vault")) {
                                        let password = masterPassword; masterPassword = ""
                                        Task { await model.configureVault(password: password, create: model.vaultState == "Not configured") }
                                    }.disabled(model.vaultBusy || masterPassword.isEmpty)
                                } else { Button(T("Lock vault")) { Task { await model.lockVault() } } }
                                Text(T("Successful passwords are reused until you quit or lock the vault. Save password stores them encrypted.")).font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        } label: {
                            HStack(spacing: 8) {
                                Label(T("Password vault"), systemImage: "lock.shield")
                                Spacer()
                                Text(T(model.vaultState)).foregroundStyle(.secondary)
                            }.font(.system(size: 12))
                        }
                    }.padding(13).frame(width: 254).background(model.theme.sidebar.color)
                        .transition(.move(edge: .leading))
                    workspaceDivider
                }
                VStack(spacing: 0) {
                    if model.layout != .terminal { tabStrip }
                    sessionArea
                }
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
                    if model.layout == .transfer {
                        workspaceDivider
                        transferSidebar
                    }
                }
            }
            if let error = model.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(T(error)); Spacer(); Button(T("Dismiss")) { model.error = nil } }
                    .foregroundStyle(.red).padding(10)
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
            ProfileImportView(store: model.sessionTree, source: request.url, parent: request.parent)
        }
        .task { await model.refreshVault() }
        .onDisappear { Task { await model.closeWorkspaceTabs() } }
    }

    /// Tab bar entries in tab order. A split group is one entry, placed where its first pane's tab was.
    private var stripItems: [StripItem] {
        var seen = Set<Int>()
        return model.tabs.compactMap { tab in
            guard let index = model.groups.firstIndex(where: { $0.contains(tab.id) }) else { return .tab(tab) }
            return seen.insert(index).inserted ? .group(model.groups[index]) : nil
        }
    }

    private var tabStrip: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let items = stripItems
                let addWidth: CGFloat = 40
                // Tabs share the bar evenly and shrink down to an icon instead of scrolling out of view.
                let width = max(StripTab.minimumWidth, min(StripTab.maximumWidth, (proxy.size.width - addWidth) / CGFloat(max(items.count, 1))))
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        stripTab(item, width: width)
                            .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    Button { model.addTab() } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(StripPlusStyle())
                    .help(T("New connection"))
                    .frame(width: addWidth)
                    Spacer(minLength: 0)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: items.map(\.id))
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: width)
            }
            .frame(height: 34)
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

    @ViewBuilder private func stripTab(_ item: StripItem, width: CGFloat) -> some View {
        switch item {
        case .tab(let tab):
            StripTab(title: UIStrings.text(tab.title, language: model.language), symbol: tab.isLocal ? "terminal" : "network",
                     connected: tab.connected, width: width, selected: tab.id == model.selection, theme: model.theme,
                     select: { model.selectTab(tab.id) },
                     close: { Task { await model.closeTab(tab) } })
                .onDrag { PaneDrag.provider(for: tab.id) }
                .help(T("Drag onto a pane to split it"))
        case .group(let layout):
            let members = layout.tabIDs.compactMap { id in model.tabs.first { $0.id == id } }
            // Like Termius, a split is a "Workspace"; further splits are numbered. The tooltip lists its panes.
            let number = (model.groups.firstIndex(of: layout) ?? 0) + 1
            StripTab(title: T("Workspace") + (number > 1 ? " \(number)" : ""),
                     detail: members.map { UIStrings.text($0.title, language: model.language) }.joined(separator: "\n"),
                     symbol: "rectangle.split.2x1", connected: members.contains(where: \.connected), width: width,
                     selected: layout.contains(model.selection), theme: model.theme,
                     select: { if !layout.contains(model.selection), let first = layout.tabIDs.first { model.selectTab(first) } },
                     close: { Task { for tab in members { await model.closeTab(tab) } } })
        }
    }

    /// Native window toolbar: icon buttons with tooltips, grouped by where they act.
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
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                Button { model.addTab() } label: { Label(T("New connection"), systemImage: "network") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button { model.addLocalTab() } label: { Label(T("Local terminal"), systemImage: "terminal") }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button(T("Import session…")) { chooseFile(types: ["xsh", "xfp"]) { try model.importProfile($0) } }
                Button(T("Import Xshell folder…"), action: chooseImportFolder)
            } label: {
                Label(T("New connection"), systemImage: "plus")
            } primaryAction: { model.addTab() }
            .help(T("New connection"))
            .accessibilityIdentifier("newConnectionMenu")

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

    /// Panes float as cards over a slightly darker well. Pane frames change without animation: animating
    /// them would resize and redraw every terminal on each frame.
    private var sessionArea: some View {
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
        .padding(5)
        .background(model.theme.tabs.color)
    }

    private func paneDropTarget(_ target: UUID) -> PaneDropTarget {
        PaneDropTarget(target: target, accent: model.theme.accent.color) { dragged, edge in
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
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return SessionPane(model: model, tab: tab, compact: inSplit, dockedFiles: model.layout == .transfer)
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

    private var workspaceDivider: some View {
        Rectangle().fill(model.theme.border?.color ?? model.theme.foreground.color.opacity(0.16)).frame(width: 1)
    }

    private var transferSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(T("Remote files"), systemImage: "folder").font(.headline)
                .accessibilityIdentifier("transferSidebar")
            if let tab = model.selected, !tab.isLocal {
                RemoteFilesPane(model: model, tab: tab, compact: true).id(tab.id)
            } else {
                Text(T("Open an SSH tab to browse remote files."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(13)
        .frame(width: 302)
        .background(model.theme.sidebar.color)
    }

    private var themeSidebar: some View {
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

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = T("Review profiles")
        if panel.runModal() == .OK, let url = panel.url {
            importRequest = FolderImportRequest(url: url, parent: model.sessionTree.destination)
        }
    }

    private func chooseFile(types: [String], action: (URL) throws -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            do { try action(url) } catch { model.error = error.localizedDescription }
        }
    }
}

private enum WorkspaceSidebar {
    case commands, themes
}

private struct FolderImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let parent: UUID?
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
            .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: target, size: size, hover: $hover, place: place))
    }
}

private struct PaneDropDelegate: DropDelegate {
    let target: UUID
    let size: CGSize
    @Binding var hover: PaneDropEdge?
    let place: (UUID, PaneDropEdge) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard MainActor.assumeIsolated({ PaneDrag.current }) != target else {
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
private struct StripTab: View {
    static let minimumWidth: CGFloat = 38
    static let maximumWidth: CGFloat = 200
    let title: String
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
        // A tap gesture rather than a Button: a Button keeps the mouse and stops the tab from being dragged.
        HStack(spacing: 6) {
            // The close button takes the icon's place under the pointer, so it costs no width.
            ZStack {
                icon.opacity(hovering ? 0 : 1)
                if hovering { closeButton.transition(.opacity) }
            }
            .frame(width: 16, height: 16)
            if showsTitle {
                Text(title).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if showsDot {
                    Circle().fill(connected ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, wide ? 8 : 0)
        .frame(width: width, height: 34, alignment: showsTitle ? .leading : .center)
        .background {
            if selected { theme.background.color.shadow(color: .black.opacity(0.18), radius: 3, y: -1) }
            else if hovering { Color.primary.opacity(0.05) }
        }
        .overlay(alignment: .top) { if selected { Rectangle().fill(theme.accent.color).frame(height: 2) } }
        .overlay(alignment: .trailing) {
            if !selected { Rectangle().fill(theme.foreground.color.opacity(0.1)).frame(width: 1, height: 16) }
        }
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

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(selected ? theme.accent.color : .secondary)
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
    @State private var forwarding = false
    @State private var reviewedHostKey: HostKeyChange?
    init(model: WorkspaceModel, tab: SessionTab, compact: Bool = false, dockedFiles: Bool = false) {
        self.model = model; self.tab = tab; self.compact = compact
        self.dockedFiles = dockedFiles
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 10) {
            if !tab.connected && !tab.isLocal {
                connectionForm.transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let progress = tab.progress { ProgressView(value: progress).tint(model.theme.accent.color) }
            if let error = tab.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(T(error)).textSelection(.enabled)
                    Spacer()
                    if let change = tab.hostKeyChange, !tab.busy {
                        Button(T("Review host key…")) { reviewedHostKey = change }
                            .foregroundStyle(model.theme.foreground.color)
                            .accessibilityIdentifier("reviewHostKeyButton")
                    }
                    Button { tab.error = nil; tab.hostKeyChange = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.callout).foregroundStyle(.red).padding(8).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if !tab.showsFiles || dockedFiles {
                if tab.connected && !tab.terminalReady && !tab.terminalStarting {
                    Button(T("Open terminal")) { Task { await model.startTerminal(tab) } }
                }
                TerminalDisplay(tab: tab, model: model).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("terminalOutput")
            } else {
                RemoteFilesPane(model: model, tab: tab, compact: compact)
                    .transition(.opacity)
            }
            }
            .padding(compact ? 6 : 10)
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
        .onChange(of: tab.identityPath) { _, _ in tab.password = ""; tab.keyPassphrase = "" }
        .onChange(of: tab.jumpSessionID) { _, id in
            tab.jumpSecret = ""
            if id != nil { tab.useProxy = false }
        }
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
            if tab.connected && !tab.isLocal {
                PaneIconButton(symbol: "arrow.left.arrow.right", help: "Local port forwarding") { forwarding = true }
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
                    if tab.identityPath == nil {
                        field("Password or vault entry") { SecureField(T("Password or vault entry"), text: $tab.password).accessibilityIdentifier("passwordField") }
                    } else {
                        field("Key passphrase") { SecureField(T("Key passphrase"), text: $tab.keyPassphrase) }
                    }
                }
            }.onSubmit { Task { await model.connect(tab) } }
            HStack {
                IdentityFilePicker(path: $tab.identityPath)
                Divider().frame(height: 16)
                if tab.jumpSessionID == nil {
                    Toggle("SOCKS5", isOn: $tab.useProxy).toggleStyle(.checkbox)
                    if tab.useProxy {
                        TextField(T("Proxy host"), text: $tab.proxyHost).frame(width: 170)
                        TextField(T("Port"), text: $tab.proxyPort).frame(width: 65)
                    }
                }
                Spacer()
                if tab.identityPath == nil {
                    Button(T("Save password")) { Task { await model.savePassword(tab) } }
                        .disabled(model.vaultState != "Unlocked" || tab.password.isEmpty)
                }
            }
            HStack {
                JumpHostPicker(store: model.sessionTree, excluding: tab.savedSessionID, selection: $tab.jumpSessionID)
                    .frame(maxWidth: 290)
                if let jump = model.sessionTree.node(tab.jumpSessionID)?.connection {
                    let title = jump.identityPath == nil ? "Jump host password" : "Jump host key passphrase"
                    SecureField(T(title), text: $tab.jumpSecret).frame(maxWidth: 220)
                }
            }
        }
        .disabled(tab.busy)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
