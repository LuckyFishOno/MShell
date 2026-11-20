# MShell development guide

## Source layout

The Swift package lives in [MShell](MShell). The `CarveApp` executable launches the native macOS interface. `Sources/app` manages the session tree, windows, tabs, preferences, and credential vault. The `terminal` and `LocalPTY` targets handle terminal state and the local login shell. The `ssh`, `network`, and `file-transfer` targets implement remote sessions and SFTP.

The packaging script builds an optimized release app bundle in `analysis-app/build` by default. Debug builds parse and draw terminal output several times slower, so use the packaged app to judge responsiveness. To use a different build cache or destination, pass them as the first and second arguments to `package-app.sh`.

## Local data

MShell stores its working files under `~/Library/Application Support/MShell`. The session catalog stores connection settings and key-file paths. Host fingerprints and the optional encrypted password vault have separate data files. Passwords are persisted only when saved to the vault. Quick commands are stored as plain text in `quick-commands.json`. Keep secrets out of saved commands. For UI checks, pass `--workspace /path/to/test-workspace` to the app executable to isolate these files from your regular workspace.

The `mshell layout` command sets the `layout.json` preference. The top bar no longer shows a layout selector. The layout is loaded at process startup. Pass `--workspace PATH` at the end of a layout command to target an isolated workspace.

## Tests

Run `swift test --package-path analysis-app/MShell` from the repository root. SSH and forwarding integration tests use loopback fixtures. SFTP tests also use macOS's `sftp-server`. The test suite exercises separate host-key approvals for the destination and jump host, transfer round trips, reconnect after transport loss, and independent local terminals.

Optional format compatibility tests read from the directory specified by `XSHELL_DIR`. The original Xshell installation and fixtures are external test inputs.

## Third-party notices

SwiftPM resolves dependencies using [Package.resolved](MShell/Package.resolved). Bundled Visual Studio Code theme color data is distributed with its [MIT notice](MShell/Sources/app/Resources/vscode-themes-license.txt). Workbench colors from MIT-licensed Marketplace themes are distributed with their [license notices](MShell/Sources/app/Resources/vscode-community-themes-licenses.txt). To change the bundled themes, edit the selection in [build-vscode-themes.py](MShell/scripts/build-vscode-themes.py) and run it with a local Visual Studio Code app and the downloaded `.vsix` packages. Linux distribution palettes are defined in `ThemeGallery.swift`; [THEME-INVENTORY.md](THEME-INVENTORY.md) records their sources. MShell's workspace layout and theme picker are native implementations. Xshell session import supports selected fields from compatible profiles.
