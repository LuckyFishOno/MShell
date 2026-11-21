# MShell roadmap

The [feature backlog](FEATURE-BACKLOG.md) tracks documented workflows from Xshell 8 and MobaXterm 26.6, including their macOS counterparts. Tabby and Termius inform workspace navigation and appearance.

## First milestones

1. Establish the shared application operations and product CLI with saved session listing and connection by profile.
2. Bring current SFTP operations to the CLI and improve the file workspace alongside the terminal.
3. Add FTP and FTPS profiles, then legacy SCP compatibility. Verify each protocol through the GUI and CLI.
4. Extend the same shared operations to the local MCP server and the next connection types.

## Command line and MCP

- [ ] **CLI parity.** Every GUI operation must have a supported `mshell` command. Cover session and folder management, import, authentication and host-key review, terminal and tab control, file transfers, forwarding, saved commands, appearance, and workspace preferences. Apply the same requirement to each new connection type. Commands that display a window can ask the running app to open or arrange it.
- [ ] Share application operations, workspace data, and live session identifiers between the GUI and CLI. Start with session listing and connection by saved profile. Provide stable exit codes and structured output for automation where applicable. Verify each feature through both entry points before marking it complete.
- [ ] **Local MCP server.** Expose selected application operations over [MCP stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports). Allow an agent to list approved sessions, open or locate an approved connection, read a user-shared excerpt of terminal output, and prepare a command for review in MShell.
- [ ] Provide opt-in MCP access, per-session permissions, a visible activity history, and immediate revocation. Show the full command and destination before execution and require confirmation in MShell. Keep credentials inside MShell and bind approvals to a specific live session.

## File transfers

- [x] **SFTP GUI.** Browse, upload, download, rename, and delete files over an existing SSH connection. Saved profiles can open directly to the file browser.
- [x] **SFTP layout.** Show remote files beside the terminal in the MobaXterm-style side rail, optionally following the shell's folder.
- [ ] **SFTP workspace and CLI.** Add optional directory following, Finder drag and drop, folder and batch operations, and remote editing with explicit upload and conflict handling. Provide equivalent file operations through the CLI.
- [ ] **FTP and FTPS.** Save dedicated profiles and support browsing, upload, download, rename, directory creation, and deletion. Start with passive mode. Support explicit and implicit FTPS with certificate validation and encryption for both connections. Require the user to select plain FTP explicitly. [FTPS modes](https://curl.se/docs/faq.html#FTPS_does_not_work)
- [ ] **SCP.** Copy files over SSH using the legacy SCP protocol for servers with no SFTP subsystem. Reuse SSH host-key verification and profile authentication. Verify against an SCP-capable fixture with SFTP disabled. Provide CLI and GUI upload and download and an optional profile-level fallback from SFTP. [OpenSSH SCP manual](https://man.openbsd.org/scp)
- [ ] **Transfers across protocols.** Share progress, cancellation, and overwrite handling. Keep existing files intact on failed downloads. Add transfer queues, retries, and resume where supported. Verify uploads and downloads on disposable fixtures for each protocol.
- [ ] Evaluate rsync for incremental directory synchronization and XMODEM, YMODEM, and ZMODEM for serial or terminal transfers. [MobaXterm transfer tools](https://mobaxterm.mobatek.net/documentation.html) · [Transfer plugins](https://mobaxterm.mobatek.net/plugins.html)

## SSH and terminal

- [x] Three workspace layouts (macOS, Xshell style, MobaXterm style) with a toolbar menu that applies at once, a persisted choice, and CLI get/set.
- [x] Preview and import OpenSSH configuration with includes, wildcard defaults, agent settings, and jump routes. Support Ed25519, ECDSA, and RSA key files and agent keys, up to eight jump hosts, and SOCKS4/4a/5 and HTTP CONNECT proxies.
- [x] Start and stop local, reverse, and dynamic forwarding in the app. Save rules in a connection profile and start them after connect.
- [x] Use Touch ID to reopen the password vault during the same app launch. Create, show, and regenerate an app-managed Secure Enclave SSH key without per-connection Touch ID.
- [x] Save a password or key passphrase on this Mac after it first signs in, so it connects after a restart without unlocking. Optionally ask for Touch ID or the Mac password on every connection.
- [ ] Add keyboard-interactive authentication and multi-factor login, including multi-round prompts and public key plus verification code. The current NIOSSH release lacks RFC 4256 support. [Upstream client implementation](https://github.com/apple/swift-nio-ssh/pull/242)
- [ ] Evaluate SSH certificates, smart cards, and SSH gateways for compatible remote connection types.
- [ ] Connection recovery after sleep and optional automatic reconnect.
- [x] Multi-pane workspace: split any pane side by side or stacked without a pane limit, drag dividers, maximize and restore a pane, and type into all panes at once.
- [ ] Tab duplication and detach/reattach, workspace restoration, and opening session groups together.
- [x] Saved quick commands with search, insertion, and confirmation before running.
- [ ] Broadcast to a user-selected subset of sessions, macro recording and playback, terminal search, plain-text output and session logs, and activity indicators on inactive tabs.
- [ ] Per-session fonts, encodings, key mappings, paste controls, and editable syntax highlights. Expand compatibility testing with Vim, tmux, and Chinese input methods.
- [ ] Session import and export, including MobaXterm and CSV. Support sharing profiles with a team without including credentials.

## Other connections

- [ ] **Windows Remote Desktop (RDP)**. Save an RDP connection in the session tree and open it from MShell. Verify authentication, display resizing, keyboard, and pointer input, then add optional clipboard and drive redirection.
- [ ] **VNC**. Save profiles, support display resizing and clipboard options, and verify keyboard and pointer input. Evaluate connection through an SSH gateway.
- [ ] **macOS serial ports**. Open a built-in or USB serial device. Configure baud rate, data bits, parity, stop bits, and flow control. Handle device removal and reconnection.
- [ ] **X11**. Evaluate SSH X11 forwarding to a macOS display server, remote application rendering, and XDMCP for legacy Unix desktops.
- [ ] **Mosh and legacy terminals**. Evaluate Mosh for roaming connections and explicit Telnet, Rlogin, and Rsh profiles for older equipment.

## Utilities and team use

- [ ] Add resource monitoring and connection diagnostics, file previews and comparisons, and an editor workflow.
- [ ] Add macOS shell and tool integrations, Finder actions, saved browser sessions, and local test services.
- [ ] Add managed profiles, branding, deployment defaults, and security policies for teams. Track optional idle-screen and entertainment integrations separately from remote-work features.
