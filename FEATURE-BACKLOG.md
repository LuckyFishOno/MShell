# Xshell and MobaXterm feature backlog

Baseline reviewed on November 20, 2026. The backlog covers documented product features, settings, and integration workflows in Xshell 8 and MobaXterm 26.6, including the Professional Customizer and the November 11 Xshell update. Windows-specific workflows have macOS counterparts below. Each checkbox is an MShell development item. An open item can include capabilities already present in the app.

- **Xshell** · [Features and specifications](https://www.netsarang.com/en/xshell-all-features/) · [Version 8 manual](https://www.netsarang.com/docs/Xshell8_manual.pdf) · [What's new](https://www.xshell.com/en/whats-new/) · [Update history](https://www.xshell.com/en/xshell-update-history/)
- **MobaXterm** · [Features](https://mobaxterm.mobatek.net/features.html) · [User guide](https://mobaxterm.mobatek.net/documentation.html) · [Release history](https://mobaxterm.mobatek.net/download-home-edition.html) · [Plugin catalog](https://mobaxterm.mobatek.net/plugins.html) · [Home and Professional editions](https://mobaxterm.mobatek.net/download.html)

## Sessions and workspace

- [x] Start with a local terminal tab. Keep saved sessions in a searchable folder tree with add, edit, rename, duplicate through copy/paste, move, and remove operations.
- [x] Open saved sessions in tabs and in their own windows. Preview Xshell folder imports and keep the imported folder hierarchy.
- [x] Show two independent terminals in side-by-side or stacked layouts.
- [x] Offer macOS, Terminal, and Files layout presets from the top bar and CLI. Apply the saved layout on the next app launch.
- [ ] Add a start page with recently used sessions, favorites, examples, session search, and the choice to start with the local shell.
- [ ] Support direct ad hoc connection URLs, a configurable default profile, command completion, and saved and live sessions from the address bar, menu, local prompt, CLI, or a macOS shortcut.
- [ ] Add profile icons and comments, live indicators in the session tree, and navigation from a saved profile to any of its open tabs.
- [ ] Add multi-select and batch editing, inheritable folder settings, protocol presets, session groups, and opening a folder or group in one action.
- [ ] Restore session lists and layouts after restart. Allow selected startup sessions and handle a failed startup connection independently of the rest.
- [ ] Add a tab manager with independent session counts, shortcut navigation, reorder, rename, lock, duplicate, detach, reattach, and merge. Support multiple tab groups and four-pane layouts.
- [ ] Save layouts with movable and auto-hiding panels, a configurable toolbar and favorites bar, window cycling, full screen, a compact view, and an optional global terminal shortcut.
- [ ] Support preset or per-session titles, session icons, and selected-line count, connection status, and traffic in the status area.
- [ ] Import and export session and folder collections with compatibility reports. Cover Xshell/Xftp profiles, MobaXterm exports, OpenSSH config, CSV, PuTTY/SuperPuTTY, RDM, and Exceed where formats can be verified.
- [ ] Add local backup and restore, configurable workspace locations, shared profiles and settings, and credential-free team exports. Maintain separate storage for each macOS account.

## SSH, trust, and networking

- [x] Support SSH password and OpenSSH Ed25519 key-file login, host-key review and pinning, and an optional encrypted password vault.
- [x] Support a single SSH jump host, SOCKS5 proxy, local TCP forwarding, and manual reconnect.
- [ ] Add reusable authentication profiles with bulk assignment, password and passphrase handling, keyboard-interactive/PAM and multi-factor prompts, saved login prompts, and macOS Keychain integration.
- [ ] Support OpenSSH agent identity selection and explicit agent forwarding. Add agent management, key ordering, key generation, import/export, and user and host key managers. Cover RSA, ECDSA, Ed25519, and PPK/PEM/PKCS8/OpenSSH conversion with compatibility checks.
- [ ] Add OpenSSH user certificates per session, OpenSSH CA trust, PKCS#11, PIV smart cards and security keys, and GSSAPI/Kerberos. Map CAPI/CNG and Windows authentication workflows to compatible macOS system credential providers.
- [ ] Support OpenSSH and legacy server compatibility profiles, including a feasibility and isolation check for SSH1, DSA, and legacy ciphers/MACs. Keep current SSH2 policies as the default and put compatibility settings behind explicit per-profile choices.
- [ ] Add address family selection, IPv6 and link-local addresses, multi-hop jump hosts, SOCKS4/5 and HTTP proxy profiles, bypass rules, and separate gateway authentication. Reuse gateways for supported remote desktop and legacy connections.
- [ ] Add compression, negotiated algorithm visibility, session-specific policy, configurable keepalive, response to network and sleep changes, and optional automatic reconnect.
- [ ] Add saved local, reverse, and dynamic tunnels. Provide a tunnel manager, connection counts, and the ability to change forwarding rules during an active connection. Default local listeners to loopback.

## Terminal, appearance, and logging

- [x] Render UTF-8, Unicode line drawing, ANSI attributes, 256 colors, and RGB colors in the terminal. Offer whole-workspace color presets and language settings.
- [x] Show a steady block at the terminal cursor position. Support mouse text selection independently and honor terminal cursor visibility.
- [ ] Add terminal behavior profiles for xterm, VT100/220/320, Linux, SCO ANSI, and ANSI, with capability tests for cursor and mouse modes, line drawing, fixed dimensions, and horizontal scrolling.
- [ ] Add general and per-session fonts, separate Latin and non-Latin font choices, ligatures, spacing and margins, cursor shape/color/blink, zoom and reset, transparency, and interface scaling.
- [ ] Support configurable character encodings, wide characters, emoji, configurable scrollback, reflow on resize, IME composition, and interactive compatibility with tmux, Vim, and full-screen console apps.
- [ ] Add terminal search with literal and regular-expression modes, find-next and match highlights, word and line selection, configurable word boundaries, rectangular selection, and copy-on-select as an option.
- [ ] Add customizable shortcuts and key maps, Linux Meta and Backspace behavior, paste on right-click as an option, a multiline paste preview and editor, bracketed-paste controls, per-line delay, and opt-in OSC 52 clipboard writes.
- [ ] Add per-session palette editing/import/export, text-based color changes, and editable syntax or keyword rules for logs, shells, and network equipment.
- [ ] Add inactive-tab activity, disconnect and bell indicators, audio and visual bells, macOS notifications, close confirmation, a read-only terminal, and a manual or timed workspace lock.
- [ ] Add terminal output capture, screen snapshots, export to the default text editor, plain-text and terminal-sequence logs, configurable log filenames, start/pause/stop controls, connection history, automatic history clearing, and SSH/Telnet connection tracing with secret redaction.
- [ ] Add an integrated log viewer, hex viewer, print preview and print/export actions, and configurable browser search for selected text.

## Commands, macros, and automation

- [x] Save, search, edit and delete single-line quick commands. Insert them into the selected terminal or confirm before running them.
- [ ] Add quick-command sets, import/export, a configurable command bar and manager, named destinations, and colors indicating where a command will run.
- [ ] Add a single-line compose bar and multiline editor with preview. Support sending to one tab, a user-selected group, or an explicitly selected set of sessions. Indicate active broadcast recipients and allow exiting broadcast immediately.
- [ ] Add per-session login prompts and startup commands, reusable command aliases, approved login scripts, and temporary return to a local shell.
- [ ] Add macro recording, editing, replay, a selectable startup macro, and steps that wait for expected output. Exclude authentication input from recordings.
- [ ] Add scripting for live sessions, terminal output, interaction, and script arguments, including multi-session execution with explicit targets. Provide a migration path for Xshell Python, VBScript/JScript and other legacy scripts through documented equivalents or import diagnostics.
- [ ] Add output triggers with literal or regex patterns, user-configured actions, and system notifications. Give users a way to inspect, limit, edit, and disable rules.
- [ ] Release a supported CLI with operation parity across the GUI. Use the same application operations and workspace, stable session IDs, terminal mode, machine-readable output, cancellation, exit codes, and shell completion. Document installation and test both entry points for each GUI feature.
- [ ] Ship a local MCP server for approved sessions and transfer actions. Provide short shared terminal excerpts, proposed commands, visible activity, per-session permissions, review for writes, and revocation. Leave credential material under MShell control.

## File transfer and remote editing

- [x] Browse directories and upload, download, rename, and delete files from an SSH/SFTP session in the GUI. Preserve local files on failed downloads.
- [x] Show the remote file list alongside the terminal in the Files layout.
- [ ] Add an adjacent local file list, optional remote current-directory following, location history and bookmarks, sortable columns, hidden files, symlink navigation, and a direct SFTP tab for a saved SSH profile.
- [ ] Add folder creation/removal, permissions where supported, timestamps and labels, drag and drop to/from Finder or local file view, recursive copies, multiple selection, and progress by file and by batch.
- [ ] Add transfer queue, pause/cancel, retry, conflict decisions, and resume where the protocol permits. Support binary and text mode when available. Test local and remote destination handling after interruption.
- [ ] Add FTP profiles, passive and active modes, and explicit and implicit FTPS with certificate checks and protected data. Support browse, put/get, rename, remove, and directory operations through GUI and CLI.
- [ ] Add real legacy SCP uploads and downloads using the saved SSH trust and authentication. Support a profile setting for SFTP, SCP, or optional SCP fallback when SFTP is unavailable. Verify the fallback against a fixture without an SFTP subsystem. [OpenSSH SCP manual](https://man.openbsd.org/scp)
- [ ] Add local and remote previews, editor choice, download/edit/upload with a conflict check, file and folder comparison, and controlled permission changes. Provide a way to open the same connection in a compatible external transfer app.
- [ ] Add terminal ASCII file sending with configurable delays and XMODEM, YMODEM, and ZMODEM transfer with test fixtures. Add rsync directory synchronization and HTTP(S) downloads, and track legacy rcp compatibility as a separate task.
- [ ] Add S3 bucket and object browsing, upload/download, and permitted object management. Include GUI/CLI file operations with user-approved credentials and paths.

## Desktop and alternate connection types

- [ ] **RDP** · Add saved profiles, NLA/CredSSP, resizing and scaling, multi-display and full screen, clipboard, Windows shortcuts, key and pointer input, and reconnection. Add gateway and separate credentials, optional drive, audio, printer and device redirection, and advanced options for console sessions, Restricted Admin, Remote Credential Guard, smart cards, and WebAuthn where supported.
- [ ] **VNC** · Add profiles, authentication and supported encodings, resolution changes, input, clipboard, and optional SSH gateway.
- [ ] **X11 and XDMCP** · Add secure SSH X11 forwarding to a local macOS display server. Verify app rendering and input, clipboard, keyboard layouts, scaling, monitor placement, and graphics extensions. Add XDMCP compatibility for remote Unix desktops.
- [ ] **Serial** · List macOS serial and USB devices. Support fixed devices or a picker at connect time, baud rate, data bits, stop bits, parity, break, flow control, reconnect and line ending settings.
- [ ] **Mosh** · Add saved and ad hoc sessions with SSH startup authentication and roaming network recovery.
- [ ] **Telnet, Rlogin, and Rsh** · Add explicitly selected compatibility profiles, terminal and connection settings, proxy support where applicable, and documented use for legacy systems.
- [ ] **Local and browser sessions** · Support configurable login shells, starting local programs in tabs, opening local files/folders, and optional saved web views. Use macOS build tools and optional integrations to cover local shell, navigation, and Linux environment workflows found in ConPTY, Cygwin, CMD, PowerShell, and WSL.

## Utilities and distribution

- [ ] Add remote resource panels for CPU, memory, storage, uptime, and network activity. Provide local networking utilities for DNS, reachability, connection status, listening services, throughput, Wake-on-LAN, and packet capture through macOS integrations.
- [ ] Add on-demand local services for test and administration workflows. Cover HTTP, SSH/SFTP, FTP, TFTP, Telnet, VNC, NFS, scheduled jobs, and bandwidth testing using app-owned instances or system integrations. Show listening scope, state, and start/stop controls.
- [ ] Add macOS Finder actions for opening a terminal in a folder, opening associated files and URLs, previews, mounted volumes and network shares, and a configurable external editor. Use macOS services for the local system information and filesystem workflows described by the MobaXterm guide.
- [ ] Add a native text viewer/editor workflow with syntax highlighting, search across files, diff and folder comparison, gzip text handling, and remote save review. Support opening files and comparisons in user-chosen tools.
- [ ] Add integration and tool discovery for Unix commands, package managers, language runtimes, terminal multiplexers, editors, and other plugin categories. Document installation and updates using macOS tooling. Treat third-party plugin contents as separate dependencies with their own licenses.
- [ ] Add signed macOS distributions with documented installation, updates, portable workspace configuration, and backup/restore checks. Keep per-user settings isolated and verify migrations of previous workspaces.
- [ ] Add managed deployment presets with startup settings, profile distribution, logo/welcome configuration, logging and security policies, and the ability to disable optional tools and integrations. This covers the team administration workflows described for the Professional Customizer.
- [ ] Plan optional idle-screen and entertainment integrations independently of connection features, with an organization setting to disable them and macOS-native presentation.

## Beyond the Xshell and MobaXterm baseline

These items come from a November 20, 2026 brainstorm. They cover macOS-native, modern terminal, fleet, and quality work that the reference products do not define.

### macOS integration

- [ ] Generate non-exportable SSH keys in the Secure Enclave and require Touch ID or a user presence check for each signature. Show the public key for copying to servers.
- [ ] Unlock the password vault with Touch ID and allow Touch ID confirmation for sensitive actions.
- [ ] Add a menu bar extra for quick connect, recent sessions, and starting, stopping, and checking saved tunnels.
- [ ] Expose saved sessions and common operations through App Intents for Shortcuts and index saved hosts in Spotlight. Use the same shared operations as the CLI.
- [ ] Preview remote files with Quick Look. Offer optional iCloud sync of profiles, folders, quick commands, and appearance without credentials or host trust decisions.

### Modern terminal features

- [ ] Add shell integration with OSC 133 prompt marks: jump between prompts, select a command's output, show exit status, and notify when a long-running command finishes in an inactive tab.
- [ ] Track the remote working directory through OSC 7 and use it for the file pane's directory following and for opening new tabs in the same location.
- [ ] Support OSC 8 hyperlinks and detected URLs. Evaluate inline images through the sixel, kitty, and iTerm2 protocols with size limits.
- [ ] Measure terminal throughput and input latency with repeatable benchmarks. Evaluate Metal rendering against the current renderer.
- [ ] Add a ⌘⇧P command palette that lists every operation through the shared application operations.

### Fleet and environment workflows

- [ ] Discover hosts from Bonjour `_ssh._tcp` services, Tailscale peers, and AWS EC2 or SSM inventories. Preview discovered hosts before adding them to the session tree.
- [ ] Add `docker exec` and `kubectl exec` session types with saved context, namespace, container, and shell settings.
- [ ] Tag sessions as production or another environment. Show the tag on tabs, panes, and the window, and require extra confirmation for configurable destructive command patterns in tagged sessions.
- [ ] Show reachability in the session tree and keep a local audit history of host-key changes and approvals.

### Runbooks, recordings, and assistance

- [ ] Add Markdown runbooks with executable blocks bound to a selected session. Show each command and destination before it runs and record the results.
- [ ] Record terminal sessions with secret redaction, replay them in the app, and export to the asciinema format.
- [ ] Add an optional built-in assistant that explains selected output and proposes commands. Use the same review and confirmation flow as the MCP server, and never run commands without approval.

### Quality and distribution

- [ ] Add GitHub Actions CI on a macOS runner for build and Swift tests. Run AppKit interaction tests in a separate job that has an active window session.
- [ ] Add automated terminal compatibility tests based on vttest and esctest, and fuzz the escape-sequence parser.
- [ ] Make the terminal and workspace accessible with VoiceOver, keyboard-only navigation, and Dynamic Type equivalents.
- [ ] Notarize releases, add Sparkle updates, and publish a Homebrew cask.
