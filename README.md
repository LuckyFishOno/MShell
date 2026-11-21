# MShell

[繁體中文](README.zh-TW.md)

MShell is a native macOS SSH client for managing servers from one workspace. Organize saved connections in folders, open an interactive terminal, browse remote files over SFTP, and keep two sessions visible while you work.

## Features

- **Connections** · Organize hosts in a folder tree. Click a folder to open or close it. Hide or show the tree with the sidebar button or ⌃⌘S. Open sessions in tabs or separate windows.
- **Terminal** · Open your local shell with ⌘T. Drag a tab onto the left, right, top, or bottom edge of a pane to split it on that side, or onto the middle of a pane to show it there. A split shows as one **Workspace** tab whose tooltip lists its panes, and each pane has its own header. Drag a pane header to another edge to move it, or onto the tab bar to make it a separate tab again. The × in a pane header disconnects and closes that session. Tabs shrink to fit the bar, down to an icon. You can also use ⌘D to split the current pane side by side or ⇧⌘D to split it top and bottom. Only connected sessions and local terminals split; a tab still showing its sign-in form stays on its own. Every pane can be split again, and the dividers can be dragged. ⇧⌘↩ maximizes or restores a pane, and ⌥⌘I types into all panes at once. A steady block cursor follows the shell while the mouse selects terminal text.
- **Quick commands** · Save and search single-line commands in the right sidebar. Insert one into the selected terminal for editing, or confirm the command and destination before running it.
- **SSH** · Connect with a password, an Ed25519, ECDSA, or RSA key, or keys from `ssh-agent`. Review host fingerprints on first use. Chain up to eight jump hosts or connect through a SOCKS4, SOCKS4a, SOCKS5, or HTTP CONNECT proxy.
- **Port forwarding** · Start local, reverse, and dynamic SOCKS forwards from an SSH tab. Save rules in the connection profile to start them whenever it connects. Listeners use loopback by default.
- **Password vault** · Optional. Without it, a password that signs in is remembered on this Mac with a Secure Enclave key and connects again without asking. Those passwords stay on this Mac when you create the vault. The vault is a separate store under your master password. Unlock it once after opening MShell, and no connection asks for Touch ID or the Mac password until you lock it or quit. While it is locked, a session with **Ask for Touch ID or the Mac password on every connection** asks each time; other sessions connect with the password remembered on this Mac. If only the locked vault holds a password, that one prompt reads it with Touch ID (set up by the first master-password unlock of this launch); the vault stays locked. When the vault section is collapsed and locked, its Touch ID button unlocks it. An account already in the vault shows **In vault** in the connection form; open it to update the password with the one typed, or to remove it. **Add to vault** saves a password before it has signed in.
- **Secure Enclave key** · Choose **Create public key** next to the key picker. MShell creates a P-256 key in this Mac's Secure Enclave, keeps it in its own data folder, and uses it for a connection that has no key yet. The button then becomes **Show public key**, which shows the OpenSSH public key to copy or regenerate. Connections that use it need no fingerprint.
- **Sign in once** · After a password or key passphrase works, MShell keeps it on this Mac, so later connections need no typing. A new connection starts with **Ask for Touch ID or the Mac password on every connection** turned on in its properties; sessions saved earlier keep their setting. While the vault is unlocked, it does not ask. **Saved passwords…** lists them after Touch ID or the Mac password, with the sessions that use each one, to show, copy, or delete. A copied password is cleared from the clipboard after 60 seconds. Removing a key with × asks first. Then the saved session stops using it, and the account's saved password and the key's passphrase are deleted while the vault is unlocked, so the next connection, also from the session tree, needs the password typed again. An older Secure Enclave key that still asks for Touch ID shows **Needs Touch ID**; switch to the MShell key to stop the prompt.
- **Reopen saved connections** · Double-click a saved connection in the tree to open a new tab. If the server's host key changes, verify the new fingerprint before choosing **Update key and reconnect**. Typing `exit` or `logout` closes the tab; if the connection drops instead, the tab stays open with **Reconnect**.
- **SFTP** · Browse, upload, download, rename, and delete remote files from the same SSH connection.
- **Import** · Preview an Xshell session folder or OpenSSH configuration before importing. MShell preserves Xshell folders and reads OpenSSH host aliases, wildcard defaults, includes, identity settings, and jump routes. It reports skipped entries and unsupported settings.
- **Appearance** · Choose from 72 workspace themes in the right sidebar. They include Ubuntu, Kali, GNOME, KDE Breeze, Tango, and Linux console palettes and popular Visual Studio Code themes such as GitHub, One Dark Pro, Dracula, Tokyo Night, Catppuccin, Nord, and Gruvbox. Search the list by name. Every terminal uses the selected workspace theme. The workspace supports English, Traditional Chinese, and Simplified Chinese.
- **Workspace layout** · Pick a layout from the layout menu at the right end of the toolbar. It applies at once and is remembered. Every layout uses the same connections, themes, and tools.
  - **macOS** (default) keeps a Mac toolbar, flat tabs, and floating panes.
  - **Xshell style** adds an icon toolbar, an address bar that takes `ssh://user@host:port`, `user@host`, or a host, the session manager on the left, and boxed tabs. A compose bar under the terminal sends a line to the current session or to every open session. The status bar shows the address, protocol, terminal size, cursor position, session count, and Caps Lock.
  - **MobaXterm style** adds a ribbon of large buttons and a vertical side rail that switches the left panel between Sessions (with quick connect), SFTP, and Macros (quick commands). Tabs are numbered. **Follow terminal folder** under the SFTP browser shows the folder the remote shell is in after each command. If the shell does not report its folder, MShell types a one-line prompt hook into it. A monitoring bar under the terminal shows CPU, memory, network, uptime, users, and disk use for this Mac or for a Linux server.

## Build from source

Requirements are macOS 14 or later and Xcode with Swift Package Manager. The current build has been verified on Apple silicon with Apple Swift 6.4.

```sh
git clone https://github.com/LuckyFishOno/MShell.git
cd MShell
./analysis-app/MShell/scripts/package-app.sh
open analysis-app/build/MShell.app
```

The script builds and ad hoc signs a local app bundle.

## Set the layout from the CLI

```sh
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout get
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout set mobaxterm
```

The available values are `macos`, `xshell` (stored as `terminal`), and `mobaxterm` (stored as `transfer`). A new app process applies the stored choice.

## Verify

```sh
swift test --package-path analysis-app/MShell
```

Tests cover terminal input, session import and persistence, SSH authentication, jump hosts, forwarding, reconnection, and SFTP. Original Xshell fixtures and optional real SSH targets can be configured as described in the [development guide](analysis-app/DEVELOPMENT.md). The AppKit interaction test needs an active macOS desktop session.

## Project status

MShell is an early release. The [roadmap](analysis-app/ROADMAP.md) covers keyboard-interactive authentication for MFA, the full CLI and MCP interfaces, additional file transfer protocols, and other connection types. The [feature backlog](analysis-app/FEATURE-BACKLOG.md) tracks work based on Xshell and MobaXterm.

See the [development guide](analysis-app/DEVELOPMENT.md) for the source layout, local storage, and third-party notices.
