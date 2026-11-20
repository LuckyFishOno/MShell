import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FileTransfer

public struct DesktopView: View {
    @StateObject private var model: WorkspaceModel
    @State private var masterPassword = ""
    @State private var vaultExpanded = false
    @State private var quickConnect = false
    @State private var themesVisible = false
    @State private var importRequest: FolderImportRequest?
    public init(model: WorkspaceModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { model.addTab() } label: {
                    Label(T("New connection"), systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button { quickConnect = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        Text(T("Quick connect"))
                        Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityIdentifier("quickConnect")

                Menu {
                    Button(T("Import session…")) { chooseFile(types: ["xsh", "xfp"]) { try model.importProfile($0) } }
                    Button(T("Import Xshell folder…"), action: chooseImportFolder)
                } label: { Label(T("Import"), systemImage: "square.and.arrow.down") }.fixedSize()

                Spacer()
                splitMenu
                Button { model.addLocalTab() } label: { Label(T("Local terminal"), systemImage: "terminal") }
                    .keyboardShortcut("t", modifiers: .command)
                Button { themesVisible.toggle() } label: {
                    Label(T("Color theme"), systemImage: "paintpalette")
                }
                .buttonStyle(.bordered)
                .tint(themesVisible ? model.theme.accent.color : nil)
                .accessibilityIdentifier("workspaceThemeToggle")
            }
            .controlSize(.regular)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(model.theme.header.color)
            Divider().opacity(0.5)
            HStack(spacing: 0) {
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
                workspaceDivider
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ScrollViewReader { scroll in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    ForEach(model.tabs) { tab in
                                        ConnectionChip(tab: tab, language: model.language, accent: model.theme.accent.color,
                                            selected: tab.id == model.selection,
                                            select: { model.selectTab(tab.id) },
                                            close: { Task { await model.closeTab(tab) } })
                                            .id(tab.id)
                                    }
                                }.padding(.leading, 10).padding(.vertical, 6)
                            }
                            .onChange(of: model.selection) { _, selected in
                                if let selected { scroll.scrollTo(selected) }
                            }
                        }
                        Menu {
                            Button(T("Local terminal")) { model.addLocalTab() }
                            Button(T("New connection")) { model.addTab() }
                        } label: { Image(systemName: "plus").frame(width: 30, height: 28) }
                            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10)
                    }.background(model.theme.tabs.color)
                    Divider().opacity(0.4)
                    sessionArea
                }
                if themesVisible {
                    workspaceDivider
                    themeSidebar
                }
            }
            if let error = model.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(T(error)); Spacer(); Button(T("Dismiss")) { model.error = nil } }
                    .foregroundStyle(.red).padding(10)
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .background(model.theme.background.color)
        .foregroundStyle(model.theme.foreground.color)
        .tint(model.theme.accent.color)
        .background(ThemeTitlebar(theme: model.theme))
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(isPresented: $quickConnect) { QuickConnect(model: model) }
        .sheet(item: $importRequest) { request in
            ProfileImportView(store: model.sessionTree, source: request.url, parent: request.parent)
        }
        .task { await model.refreshVault() }
        .onDisappear { Task { await model.closeWorkspaceTabs() } }
    }
    private var splitMenu: some View {
        Menu {
            Button { model.splitWorkspace(.sideBySide) } label: {
                Label(T("Split side by side"), systemImage: "rectangle.split.2x1")
            }
            Button { model.splitWorkspace(.stacked) } label: {
                Label(T("Split top and bottom"), systemImage: "rectangle.split.1x2")
            }
            if model.split != nil {
                Divider()
                Button(T("Close split view")) { model.closeSplit() }
            }
        } label: {
            Label(T("Split view"), systemImage: "rectangle.split.2x1")
        }.fixedSize().accessibilityIdentifier("workspaceSplitMenu")
    }

    @ViewBuilder private var sessionArea: some View {
        if let split = model.split,
           let first = model.tabs.first(where: { $0.id == split.first }),
           let second = model.tabs.first(where: { $0.id == split.second }) {
            switch split.axis {
            case .sideBySide:
                HSplitView {
                    pane(first, compact: true).frame(minWidth: 260)
                    pane(second, compact: true).frame(minWidth: 260)
                }
            case .stacked:
                VSplitView {
                    pane(first, compact: false).frame(minHeight: 215)
                    pane(second, compact: false).frame(minHeight: 215)
                }
            }
        } else if let tab = model.selected {
            SessionPane(model: model, tab: tab).id(tab.id)
        }
    }

    private func pane(_ tab: SessionTab, compact: Bool) -> some View {
        SessionPane(model: model, tab: tab, compact: compact)
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background.color)
            .overlay(alignment: .top) {
                if model.selection == tab.id {
                    Rectangle().fill(model.theme.accent.color).frame(height: 2).allowsHitTesting(false)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { model.selectTab(tab.id, focusTerminal: false) })
    }

    private var workspaceDivider: some View {
        Rectangle().fill(model.theme.border?.color ?? model.theme.foreground.color.opacity(0.16)).frame(width: 1)
    }

    private var themeSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(T("Color theme"), systemImage: "paintpalette").font(.headline)
                Spacer()
                Button { themesVisible = false } label: {
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

private struct FolderImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let parent: UUID?
}

private struct ConnectionChip: View {
    @ObservedObject var tab: SessionTab
    let language: AppLanguage
    let accent: Color
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 9) {
                    Image(systemName: tab.isLocal ? "terminal" : "network").foregroundStyle(selected ? accent : .secondary)
                    Text(UIStrings.text(tab.title, language: language)).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Circle().fill(tab.connected ? Color.mint : Color.gray).frame(width: 5, height: 5)
                }.frame(minWidth: 110, maxWidth: 210, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help(T("Close connection"))
        }.padding(.horizontal, 12).padding(.vertical, 11)
        .background(selected ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { if selected { Capsule().fill(accent).frame(height: 2).padding(.horizontal, 12) } }
    }
}

struct SessionPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: SessionTab
    let compact: Bool
    @State private var pathDraft: String
    @State private var settingsExpanded = true
    @State private var selectedFile: String?
    @State private var renameVisible = false
    @State private var renameTo = ""
    @State private var deleting: String?
    @State private var uploading: URL?
    @State private var forwarding = false
    init(model: WorkspaceModel, tab: SessionTab, compact: Bool = false) {
        self.model = model; self.tab = tab; self.compact = compact
        _settingsExpanded = State(initialValue: !tab.opensAutomatically)
        _pathDraft = State(initialValue: tab.remotePath)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.isLocal ? "127.0.0.1" : tab.host.isEmpty ? T("New connection") : tab.host).font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(tab.connected ? .green : .secondary).frame(width: 6, height: 6)
                        Text(tab.isLocal && !compact ? "macOS · \(tab.username) · \(T(tab.status))" : T(tab.status))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if tab.busy || tab.terminalStarting { ProgressView().controlSize(.mini) }
                    }
                }
                Spacer()
                if !tab.isLocal {
                    Button { settingsExpanded.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                        .help(T(settingsExpanded ? "Hide connection settings" : "Show connection settings"))
                    Button { forwarding = true } label: { Image(systemName: "arrow.left.arrow.right") }
                        .help(T("Local port forwarding")).accessibilityLabel(T("Local port forwarding"))
                        .accessibilityIdentifier("portForwardingButton").disabled(!tab.connected)
                }
                Menu {
                    Button(T("Use workspace terminal colors")) { tab.colorScheme = nil; tab.screenRevision += 1 }
                    Button(T("Import colors (.scs)…")) { importAppearance(highlights: false) }
                    Button(T("Import highlights (.hls)…")) { importAppearance(highlights: true) }
                } label: {
                    if compact { Image(systemName: "paintpalette").accessibilityLabel(T("Appearance")) }
                    else { Label(T("Appearance"), systemImage: "paintpalette") }
                }.menuStyle(.borderlessButton).fixedSize()
                if tab.connected || tab.busy {
                    Button(T("Disconnect")) { Task { await model.disconnect(tab) } }.accessibilityIdentifier("disconnectButton")
                } else {
                    Button(T(tab.transportLost ? "Reconnect" : "Connect")) { Task { await model.connect(tab) } }.buttonStyle(.borderedProminent).tint(model.theme.accent.color).accessibilityIdentifier("connectButton")
                }
            }
            if settingsExpanded && !tab.isLocal {
                VStack(alignment: .leading, spacing: 12) {
                    Text(T("Connection settings")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                    }.disabled(tab.busy || tab.connected)
                    HStack {
                        IdentityFilePicker(path: $tab.identityPath).disabled(tab.connected || tab.busy)
                        Divider().frame(height: 16)
                        if tab.jumpSessionID == nil {
                            Toggle("SOCKS5", isOn: $tab.useProxy).toggleStyle(.checkbox).disabled(tab.connected || tab.busy)
                            if tab.useProxy {
                                TextField(T("Proxy host"), text: $tab.proxyHost).frame(width: 170).disabled(tab.connected || tab.busy)
                                TextField(T("Port"), text: $tab.proxyPort).frame(width: 65).disabled(tab.connected || tab.busy)
                            }
                        }
                        Spacer()
                        if tab.identityPath == nil {
                            Button(T("Save password")) { Task { await model.savePassword(tab) } }
                                .disabled(model.vaultState != "Unlocked" || (tab.password.isEmpty && !tab.connected) || tab.busy)
                        }
                    }
                    HStack {
                        JumpHostPicker(store: model.sessionTree, excluding: tab.savedSessionID, selection: $tab.jumpSessionID)
                            .frame(maxWidth: 290)
                        if let jump = model.sessionTree.node(tab.jumpSessionID)?.connection {
                            let title = jump.identityPath == nil ? "Jump host password" : "Jump host key passphrase"
                            SecureField(T(title), text: $tab.jumpSecret).frame(maxWidth: 220)
                        }
                    }.disabled(tab.connected || tab.busy)
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            if let progress = tab.progress { ProgressView(value: progress).tint(model.theme.accent.color) }
            if let error = tab.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(T(error)).textSelection(.enabled)
                    Spacer(); Button { tab.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.callout).foregroundStyle(.red).padding(8).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if !tab.isLocal {
            Picker(T("Workspace"), selection: $tab.showsFiles) {
                Label(T("Terminal"), systemImage: "terminal").tag(false)
                Label(T("Remote files"), systemImage: "folder").tag(true)
            }.pickerStyle(.segmented).frame(maxWidth: 310).accessibilityIdentifier("workspaceSections")
            }
            if !tab.showsFiles {
                TerminalDisplay(tab: tab, model: model).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("terminalOutput")
                HStack {
                    Image(systemName: tab.isLocal ? "desktopcomputer" : "lock.fill").foregroundStyle(.tint).font(.caption)
                    Text(T(tab.terminalStarting ? "Opening terminal…" : tab.status))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tab.screen.cols) × \(tab.screen.rows)  ·  UTF-8  ·  \(tab.isLocal ? "LOCAL" : "SSH")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if tab.connected && !tab.terminalReady && !tab.terminalStarting {
                        Button(T("Open terminal")) { Task { await model.startTerminal(tab) } }
                    }
                }
            } else {
                fileBrowser
            }
        }
        .padding(compact ? 9 : 16)
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
        .sheet(isPresented: $forwarding) { PortForwardingView(model: model, tab: tab) }
        .sheet(isPresented: $renameVisible) {
            VStack(alignment: .leading, spacing: 16) {
                Text(T("Rename remote file")).font(.headline)
                TextField(T("New name"), text: $renameTo)
                HStack { Button(T("Cancel")) { renameVisible = false }; Spacer(); Button(T("Rename")) {
                    if let old = selectedFile { Task { await model.rename(tab, from: old, to: renameTo) } }
                    renameVisible = false
                }.disabled(renameTo.isEmpty) }
            }.padding(24).frame(width: 360)
        }
        .alert(T("Delete remote file?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(T("Cancel"), role: .cancel) { deleting = nil }
            Button(T("Delete"), role: .destructive) { if let file = deleting { Task { await model.remove(tab, name: file) } }; deleting = nil }
        } message: { Text(deleting ?? "") }
        .alert(T("Upload this file?"), isPresented: Binding(get: { uploading != nil }, set: { if !$0 { uploading = nil } })) {
            Button(T("Cancel"), role: .cancel) { uploading = nil }
            Button(T("Upload")) { if let url = uploading { Task { await model.upload(tab, local: url, overwrite: true) } }; uploading = nil }
        } message: { Text(String(format: T("%@ will be uploaded to %@. An existing remote file with that name will be replaced."), uploading?.lastPathComponent ?? "", tab.remotePath)) }
        .task { if CommandLine.arguments.contains("--capture-files") { tab.showsFiles = true } }
        .task(id: tab.connected) {
            if tab.connected {
                settingsExpanded = false
                await showSelectedPanel()
            } else if !tab.opensAutomatically || tab.error != nil { settingsExpanded = true }
        }
        .onChange(of: tab.error) { _, error in if error != nil && !tab.connected { settingsExpanded = true } }
        .onChange(of: tab.showsFiles) { _, _ in Task { await showSelectedPanel() } }
        .onChange(of: tab.remotePath) { _, path in selectedFile = nil; pathDraft = path }
        .onChange(of: tab.identityPath) { _, _ in tab.password = ""; tab.keyPassphrase = "" }
        .onChange(of: tab.jumpSessionID) { _, id in
            tab.jumpSecret = ""
            if id != nil { tab.useProxy = false }
        }
        .onChange(of: tab.entries.map(\.name)) { _, names in if let selectedFile, !names.contains(selectedFile) { self.selectedFile = nil } }
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
    private var fileBrowser: some View {
        VStack(spacing: 10) {
            HStack {
                Button { browse((tab.remotePath as NSString).appendingPathComponent("..")) } label: {
                    Image(systemName: "arrow.up")
                }.help(T("Parent folder")).disabled(!tab.filesLoaded || tab.remotePath == "/")
                TextField(T("Remote directory"), text: $pathDraft).onSubmit { browse(pathDraft) }
                    .accessibilityIdentifier("remotePathField")
                Button { browse(pathDraft) } label: { Image(systemName: "arrow.clockwise") }
                    .help(T("Refresh")).accessibilityLabel(T("Refresh")).accessibilityIdentifier("refreshFilesButton")
                Button(T("Upload…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK { uploading = panel.url }
                }.accessibilityIdentifier("uploadButton").disabled(!tab.filesLoaded)
            }.disabled(!tab.connected || tab.busy)
            List(selection: $selectedFile) {
                ForEach(tab.entries.sorted { $0.isDirectory && !$1.isDirectory }, id: \.name) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                        Text(entry.name)
                        Spacer()
                        if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).foregroundStyle(.secondary) }
                    }.tag(entry.name)
                        .onTapGesture(count: 2) {
                            guard entry.isDirectory, !tab.busy else { return }
                            do { browse(try model.remoteFile(entry.name, in: tab)) }
                            catch { tab.error = error.localizedDescription }
                        }
                }
            }.overlay {
                if tab.entries.isEmpty {
                    if tab.busy { ProgressView() }
                    else if !tab.connected { ContentUnavailableView(T("Connect to browse files"), systemImage: "network") }
                    else if tab.filesLoaded { ContentUnavailableView(T("This folder is empty"), systemImage: "folder") }
                    else { ContentUnavailableView(T("No files loaded"), systemImage: "folder") }
                }
            }
            HStack {
                Group {
                Button(T("Download…")) {
                    guard let name = selectedFile else { return }
                    let panel = NSSavePanel(); panel.nameFieldStringValue = name
                    if panel.runModal() == .OK, let url = panel.url { Task { await model.download(tab, name: name, local: url) } }
                }.accessibilityIdentifier("downloadButton")
                Button(T("Rename…")) { renameTo = selectedFile ?? ""; renameVisible = true }
                Button(T("Delete…"), role: .destructive) { deleting = selectedFile }
                }.disabled(!tab.connected || tab.busy || selectedFile == nil ||
                    tab.entries.first(where: { $0.name == selectedFile })?.isDirectory == true)
                Spacer()
                Text(String(format: T("%d entries"), tab.entries.count)).foregroundStyle(.secondary)
            }
        }
    }
    private func browse(_ path: String) {
        guard !path.isEmpty else { return }
        let target = path.hasPrefix("/") || !tab.filesLoaded
            ? path : (tab.remotePath as NSString).appendingPathComponent(path)
        Task {
            await model.refreshFiles(tab, navigateTo: target)
            if tab.error == nil { pathDraft = tab.remotePath }
        }
    }

    private func showSelectedPanel() async {
        guard tab.connected else { return }
        if tab.showsFiles {
            if !tab.filesLoaded { await model.refreshFiles(tab) }
        } else if !tab.terminalReady {
            await model.startTerminal(tab)
        }
    }

    private func importAppearance(highlights: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: highlights ? "hls" : "scs") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do { if highlights { try model.importHighlights(url, tab: tab) } else { try model.importColors(url, tab: tab) } }
            catch { tab.error = error.localizedDescription }
        }
    }
}
