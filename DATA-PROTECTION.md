# MShell data protection inventory

Reviewed on November 21, 2026, against the 0.10.0 working tree. This inventory lists the data MShell stores or handles and its current protection. It also covers planned features from the [roadmap](ROADMAP.md) and [feature backlog](FEATURE-BACKLOG.md).

## Protection classes

| Class | Meaning | Required protection |
|---|---|---|
| **S1 · Secret** | Grants access to systems or other secrets. | Encrypted at rest with authenticated encryption and a key that never leaves MShell in plaintext. Never written to logs, recordings, macros, crash reports, exports, sync, the CLI, or MCP. Kept in memory only while needed and cleared on lock. |
| **S2 · Sensitive content** | Can reveal secrets or private infrastructure, but does not authenticate by itself. | Encrypted at rest by default or by a clear user setting. Secret redaction before it leaves the app. Explicit user action before it is shared. |
| **I · Integrity critical** | Tampering would weaken security, for example by redirecting a connection or approving a host. | Tamper detection with a key held by MShell. Refuse or flag modified data. |
| **L · Low** | Preferences with no security impact. | Private file permissions. |

## Current storage

MShell stores working files in `~/Library/Application Support/MShell`. The directory is `0700` and files are written with `writePrivate` as `0600`. The language preference is in `UserDefaults`.

| Data | Location | Class | Current protection | Gap |
|---|---|---|---|---|
| Saved sign-ins (passwords and key passphrases) | `saved-sign-ins.json` | S1 | Each entry is sealed with AES-GCM, with its ID bound as associated data, under a key derived (HKDF-SHA256) from a Secure Enclave P-256 key agreement. The file holds only the enclave's wrapped key handle, usable on this Mac only. No unlock is needed, so a session connects after a restart. A session can require Touch ID or the Mac password before each connection. The saved passwords list opens only after Touch ID or the Mac password, reveals a secret only on request, and clears a copied password from the clipboard after 60 seconds if nothing else was copied. | Any process running as the user can read the file and ask the Secure Enclave to rebuild the key, the same exposure as an unprotected Keychain item. No MAC over the entry list, so entries can be deleted or rolled back. Not cleared on lock. |
| Passwords added to the vault | `password-vault.json` | S1 | PBKDF2-HMAC-SHA256 (210,000 iterations) derives a key from the master password. Each entry is sealed with AES-GCM. | Entry IDs are not bound as associated data, so sealed entries can be swapped between IDs without detection. No automatic lock. PBKDF2 iteration count is below the current OWASP guidance of 600,000 for PBKDF2-HMAC-SHA256, and PBKDF2 is not memory-hard. |
| Master password and derived key | Memory only | S1 | Manual lock discards the unwrapped key. On a compatible Mac, MShell retains a copy sealed with a key derived through Secure Enclave key agreement, gated by the current Touch ID enrollment. The sealed copy lasts for the app process. | No lock after idle, sleep, screen lock, or app deactivation. Swift `String` and `SymmetricKey` copies cannot be reliably zeroed. |
| Passwords remembered for the session | `CredentialVault.sessionPasswords` in memory | S1 | A password or key passphrase that signs in is saved to `saved-sign-ins.json` at once, with or without a vault. On a Mac without a Secure Enclave it goes to the vault when it is unlocked, otherwise at the next unlock. Entries read from the locked vault with Touch ID for one connection are held here too. Cleared on vault lock. | Not cleared on idle or sleep. Kept after the tab closes until the vault is locked. |
| Password, key passphrase, and jump host secret fields | `SessionTab` published properties | S1 | Cleared after connect and on disconnect. | Values live in SwiftUI state while typed. Acceptable, but keep them out of view-state restoration and diagnostics. |
| Private key files | User path in `identityPath` | S1 | MShell stores only the path. The passphrase is used for a single load. | The decrypted key stays in memory for the session. A planned key manager, key generation, and import must not write unencrypted keys. |
| Secure Enclave SSH identity | `ssh-key-secure-enclave` in the app data folder | S1 | A P-256 signing key stays inside the Secure Enclave and cannot be exported. The file contains only the enclave-sealed representation, usable on this Mac only. Signing needs no Touch ID; keys from 0.10.0 builds still ask once per launch. | A replacement Mac needs a new key and server-side public key enrollment. |
| Session catalog and forwarding rules | `sessions.json` | S2 and I | Plaintext JSON, `0600`. No credentials. Forward listeners are limited to loopback by the app. | Hostnames, usernames, ports, proxies, jump hosts, and key paths form a map of the user's infrastructure. Plaintext is copied into Time Machine and other backups. A modified host, jump entry, or forwarding rule can redirect a connection. |
| Known hosts | `known-hosts.json` | I | Plaintext JSON, `0600`. A changed key blocks the connection. | No tamper detection. Malware running as the user can add a trusted key and enable a man-in-the-middle connection without a prompt. |
| Quick commands | `quick-commands.json` | S2 | Plaintext JSON, `0600`. | Users often paste tokens, passwords, or internal URLs into commands. |
| Terminal scrollback | Memory, 1,000 lines per terminal | S2 | Not persisted. | Output can contain secrets. Future search, logs, and MCP excerpts read from it. |
| Clipboard | System pasteboard | S2 | MShell reads it on paste. | Planned copy-on-select and OSC 52 writes could place secrets on the shared pasteboard and Universal Clipboard. |
| SFTP downloads | User-chosen folder plus `.mshell-<UUID>.partial` | S2 | The partial file is removed on failure. | Partial files use default permissions. Downloaded files are the user's responsibility, but the partial file should be `0600`. |
| Appearance and layout | `appearance.json`, `layout.json` | L | `0600`. | None. |
| Language | `UserDefaults` | L | System defaults. | None. |

### Other findings

- `writePrivate` writes atomically and then sets `0600`. The temporary file is created with the process umask, usually `0644`. The `0700` directory blocks other users, but an existing directory with wider permissions is not corrected. Create files with `0600` from the start and verify directory permissions on launch.
- The vault salt uses `UInt8.random(in:)`, which uses the system random generator on Apple platforms. Use `SecRandomCopyBytes` or `SymmetricKey(size:)` explicitly so the source of randomness is clear in review.
- The vault file has no version-bound integrity check over the full set of entries. An attacker who can write the file can delete or roll back individual entries.

## Planned data

Each planned feature must meet its class requirements before release.

| Planned feature | Data | Class | Requirement |
|---|---|---|---|
| Key manager, generation, import, and conversion | Private keys and passphrases | S1 | Write only encrypted OpenSSH keys or vault entries. Never write a temporary plaintext key to disk. |
| SSH agent and agent forwarding | Agent socket access | S1 | Forward only per session after explicit approval. Show the active forwarding state. |
| Keyboard-interactive, MFA, and saved login prompts | Answers, OTP seeds | S1 | Store only in the vault. Never store one-time codes. |
| FTP, FTPS, RDP, VNC, Telnet, and gateway credentials | Passwords | S1 | Use the same vault. Warn before sending a password over plain FTP or Telnet. |
| Cloud discovery (AWS, Tailscale) and S3 | Access keys, tokens | S1 | Prefer the provider's own credential source. Store any key in the vault. |
| CLI | Session operations | S1 boundary | The CLI never prints or accepts secrets as arguments. Use the running app or an interactive prompt for secrets. |
| Local MCP server | Approved session access, terminal excerpts | S1 boundary and S2 | Credentials never cross the MCP boundary. Excerpts are chosen by the user and redacted. Permissions are per session and revocable. |
| Session logs and recordings | Terminal output and input | S2 | Encrypt at rest with the workspace key. Redact passwords typed at prompts. Exclude no-echo input. |
| Macros, runbooks, and startup commands | Command text | S2 | Encrypt at rest. Exclude authentication input from recordings. Reference vault entries instead of embedding secrets. |
| Connection history, audit history, and session restoration | Hosts, times, approvals | S2 and I | Encrypt at rest. Sign the audit history so entries cannot be removed silently. |
| iCloud sync | Profiles, folders, commands, appearance | S2 | End-to-end encryption with a key that Apple cannot read. Never sync S1 data or host trust decisions unless the user enables an end-to-end encrypted vault sync. |
| Backup, restore, and team export | Workspace | S2 | Encrypt backups with a user-chosen password. Team exports contain no credentials or host trust. |
| Crash reports and diagnostics | Memory, state | S1 risk | Strip terminal buffers, secrets, and file paths. Ask before sending. |
| Updates | Application code | I | Notarized builds. Sparkle with EdDSA signatures. |

## Recommended design

1. **Vault version 2.** Generate a random 256-bit data key. Wrap it with a key derived from the master password and, optionally, with a Keychain item that requires Touch ID. Use Argon2id, or PBKDF2-HMAC-SHA256 with at least 600,000 iterations if a dependency is not acceptable. Bind each entry's ID as AES-GCM associated data. Add a MAC over the entry list and a version counter. Migrate version 1 vaults on the first unlock.
2. **Encrypted workspace store.** Encrypt S2 files with keys derived from the vault data key: the session catalog, quick commands, logs, recordings, runbooks, and history. Keep a plaintext index only when it is needed before unlock, and make it contain no host or user names.
3. **Host trust integrity.** Add an HMAC to `known-hosts.json` with a key stored in the Keychain. Treat a failed check as an untrusted host and prompt again with a clear warning.
4. **Lock policy.** Lock after a configurable idle time, on sleep, on screen lock, and on quit. Clear remembered session passwords on lock.
5. **Memory handling.** Keep secrets in `Data` or byte buffers where possible and overwrite them after use. Do not place secrets in view-state restoration, undo stacks, or diagnostics.
6. **File handling.** Create private files with `0600` directly. Verify `0700` on the workspace directory at launch. Create SFTP partial files with `0600`.

## Verification

- Unit tests: vault version 2 round trip, entry swap and rollback detection, wrong password, migration from version 1, and lock on each trigger.
- Tamper tests for `known-hosts.json` and the session catalog.
- A scan of logs, recordings, crash output, CLI output, and MCP responses for test secrets after each feature that adds a new output path.
- Manual check that workspace files are unreadable without unlocking and that Time Machine copies contain no plaintext S1 or S2 data.

## Decisions needed

- **Decided 2026-11-21: the vault is optional and outranks the per-session check.** Without a vault, a password that signs in is remembered in `saved-sign-ins.json` and connects again without a prompt, also after a restart; a session with **Ask for Touch ID or the Mac password on every connection** (on for new sessions) asks each time. Creating the vault moves those passwords into it and deletes `saved-sign-ins.json`; from then on the vault is unlocked once per launch, and while it is unlocked no session asks again.
- **Decided 2026-11-21 (revised): a locked vault brings back the per-session check, and `saved-sign-ins.json` stays.** Creating the vault no longer moves remembered passwords into it. While the vault is locked, a session set to ask on every connection asks (Touch ID or the Mac password), and other sessions connect with the copy on this Mac, so locking the vault does not protect those copies. A password that only the locked vault holds is read with Touch ID for that connection; the vault stays locked.

- ~~Default unlock~~ **Decided 2026-11-20: both.** The master password always works and is required to create the vault and after a restart or a Touch ID failure. The local 0.10.0 build uses a Secure Enclave-protected key in memory for Touch ID during the same app launch. This works with ad hoc signing.
- Minimum master password length. The current policy is 6 to 50 characters.
- Whether the session catalog and quick commands are encrypted by default, which requires unlocking before the session tree appears.
- Whether vault sync through iCloud is offered at all.
