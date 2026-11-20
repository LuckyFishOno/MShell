# MShell

[繁體中文](README.zh-TW.md)

MShell is a native macOS SSH client for managing servers from one workspace. Organize saved connections in folders, open an interactive terminal, browse remote files over SFTP, and keep two sessions visible while you work.

## Features

- **Connections** · Organize hosts in a folder tree. Press ⌘K to find a saved host or connect to `user@host:port`. Open sessions in tabs or separate windows.
- **Terminal** · Open your local shell with ⌘T. Use ⌘D to split side by side or ⇧⌘D to stack two sessions.
- **SSH** · Connect with a password or OpenSSH Ed25519 key. Review host fingerprints on first use. Use a single SSH jump host, a SOCKS5 proxy, or a local port forward as needed.
- **SFTP** · Browse, upload, download, rename, and delete remote files from the same SSH connection.
- **Import** · Preview an Xshell session folder before importing supported SSH and SFTP entries. MShell preserves the folder structure and shows which entries it skipped. Configure credentials separately.
- **Appearance** · Choose from 18 workspace themes in the right sidebar. The workspace supports English, Traditional Chinese, and Simplified Chinese.

## Build from source

Requirements are macOS 14 or later and Xcode with Swift Package Manager. The current build has been verified on Apple silicon with Apple Swift 6.4.

```sh
git clone https://github.com/LuckyFishOno/MShell.git
cd MShell
./analysis-app/MShell/scripts/package-app.sh
open analysis-app/build/MShell.app
```

The script builds and ad hoc signs a local app bundle.

## Verify

```sh
swift test --package-path analysis-app/MShell
```

Tests cover terminal input, session import and persistence, SSH authentication, jump hosts, forwarding, reconnection, and SFTP. Tests that require original Xshell samples skip unless `XSHELL_DIR` points to a compatible local sample directory. The AppKit interaction test needs an active macOS desktop session.

## Project status

MShell is an early release. Current limits include one SSH jump host per connection, Ed25519 key-file authentication, and local TCP forwarding. Windows Remote Desktop, macOS serial connections, and broader terminal compatibility are tracked in the [roadmap](analysis-app/ROADMAP.md).

See the [development guide](analysis-app/DEVELOPMENT.md) for the source layout, local storage, and third-party notices.
