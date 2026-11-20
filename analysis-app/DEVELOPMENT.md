# MShell development guide

## Source layout

The Swift package lives in [MShell](MShell). The `CarveApp` executable launches the native macOS interface. `Sources/app` manages the session tree, windows, tabs, preferences, and credential vault. The `terminal` and `LocalPTY` targets handle terminal state and the local login shell. The `ssh`, `network`, and `file-transfer` targets implement remote sessions and SFTP.

The packaging script builds a local app bundle in `analysis-app/build` by default. To use a different build cache or destination, pass them as the first and second arguments to `package-app.sh`.

## Local data

MShell stores its working files under `~/Library/Application Support/MShell`. The session catalog stores connection settings and key-file paths. Host fingerprints and the optional encrypted password vault have separate data files. Passwords are persisted only when saved to the vault. For UI checks, pass `--workspace /path/to/test-workspace` to the app executable to isolate these files from your regular workspace.

## Tests

Run `swift test --package-path analysis-app/MShell` from the repository root. SSH and forwarding integration tests use loopback fixtures. SFTP tests also use macOS's `sftp-server`. The test suite exercises separate host-key approvals for the destination and jump host, transfer round trips, reconnect after transport loss, and independent local terminals.

Optional format compatibility tests read from the directory specified by `XSHELL_DIR`. The original Xshell installation and fixtures are external test inputs.

## Third-party notices

SwiftPM resolves dependencies using [Package.resolved](MShell/Package.resolved). Bundled Visual Studio Code theme color data is distributed with its [MIT notice](MShell/Sources/app/Resources/vscode-themes-license.txt). MShell's workspace layout and theme picker are native implementations. Xshell session import supports selected fields from compatible profiles.
