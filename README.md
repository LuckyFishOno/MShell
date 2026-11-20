# MShell

[繁體中文](README.zh-TW.md)

MShell is a native macOS SSH client for managing servers from one workspace. Organize saved connections in folders, open an interactive terminal, browse remote files over SFTP, and keep two sessions visible while you work.

## Features

- **Connections** · Organize hosts in a folder tree. Click a folder to open or close it. Hide or show the tree with the sidebar button or ⌃⌘S. Open sessions in tabs or separate windows.
- **Terminal** · Open your local shell with ⌘T. Drag a tab onto the left, right, top, or bottom edge of a pane to split it on that side, or onto the middle of a pane to show it there. A split shows as one **Workspace** tab whose tooltip lists its panes, and each pane has its own header. Drag a pane header to another edge to move it, or onto the tab bar to make it a separate tab again. The × in a pane header disconnects and closes that session. Tabs shrink to fit the bar, down to an icon. You can also use ⌘D to split the current pane side by side or ⇧⌘D to split it top and bottom. Every pane can be split again, and the dividers can be dragged. ⇧⌘↩ maximizes or restores a pane, and ⌥⌘I types into all panes at once. A steady block cursor follows the shell while the mouse selects terminal text.
- **Quick commands** · Save and search single-line commands in the right sidebar. Insert one into the selected terminal for editing, or confirm the command and destination before running it.
- **SSH** · Connect with a password or OpenSSH Ed25519 key. Review host fingerprints on first use. Use a single SSH jump host, a SOCKS5 proxy, or a local port forward as needed.
- **Reopen saved connections** · Double-click a saved connection in the tree to open a new tab. MShell reuses a successful password while the app is open. To reuse it across app launches, use **Save password** and unlock the password vault. If the server's host key changes, verify the new fingerprint before choosing **Update key and reconnect**.
- **SFTP** · Browse, upload, download, rename, and delete remote files from the same SSH connection.
- **Import** · Preview an Xshell session folder before importing supported SSH and SFTP entries. MShell preserves the folder structure and shows which entries it skipped. Configure credentials separately.
- **Appearance** · Choose from 72 workspace themes in the right sidebar. They include Ubuntu, Kali, GNOME, KDE Breeze, Tango, and Linux console palettes and popular Visual Studio Code themes such as GitHub, One Dark Pro, Dracula, Tokyo Night, Catppuccin, Nord, and Gruvbox. Search the list by name. Every terminal uses the selected workspace theme. The workspace supports English, Traditional Chinese, and Simplified Chinese.
- **Workspace layout** · MShell opens in the macOS layout. To use the Terminal or Files layout, set it from the CLI as shown below. The Terminal layout places tabs above the workspace and opens Quick Commands. The Files layout places the active SSH file browser beside the terminal. Each layout uses the same connections, themes, and tools.

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
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout set transfer
```

The available values are `macos`, `terminal`, and `transfer`. A new app process applies the stored choice.

## Verify

```sh
swift test --package-path analysis-app/MShell
```

Tests cover terminal input, session import and persistence, SSH authentication, jump hosts, forwarding, reconnection, and SFTP. Tests that require original Xshell samples skip unless `XSHELL_DIR` points to a compatible local sample directory. The AppKit interaction test needs an active macOS desktop session.

## Project status

MShell is an early release. Current limits include one SSH jump host per connection, Ed25519 key-file authentication, and local TCP forwarding. See the [roadmap](analysis-app/ROADMAP.md) for the planned CLI, file transfer protocols, and other connection types. The [feature backlog](analysis-app/FEATURE-BACKLOG.md) tracks work based on Xshell and MobaXterm.

See the [development guide](analysis-app/DEVELOPMENT.md) for the source layout, local storage, and third-party notices.
