# MShell

[English](README.md)

MShell 是 macOS 原生 SSH 客戶端。你可以把常用主機分門別類，在同一個工作區開終端、用 SFTP 瀏覽遠端檔案，也能並排查看兩條連線。

## 功能

- **連線管理**：用資料夾整理主機。點一下資料夾即可展開或收起。按側欄按鈕或 ⌃⌘S 收起或展開連線樹。連線可開在頁籤或獨立視窗。
- **終端**：按 ⌘T 開啟本機 shell。把分頁拖到任一格的左、右、上、下邊緣，就會往那一側分割；拖到正中間則改在那一格顯示。分割後在分頁列只佔一個「工作區」分頁，滑過可看到裡面有哪些連線，每一格有自己的標頭；把標頭拖到別的邊緣可搬移那一格，拖回分頁列就會拆成獨立分頁。標頭的 × 會中斷連線並關閉那個工作階段。分頁多時會等比例縮小，最小只剩圖示。也可以按 ⌘D 把目前這格左右分割、⇧⌘D 上下分割。只有已連線的工作階段和本機終端可以分割，還在登入表單的分頁不能分割。每一格都能再切，分隔線可以拖動。⇧⌘↩ 放大或還原這一格，⌥⌘I 同步輸入到所有格。方塊游標固定顯示在 shell 的輸入位置，仍可用滑鼠選取和複製文字。
- **常用指令**：在右側面板儲存、搜尋單行指令。可插入目前選取的終端再編輯，也可確認指令與目的地後直接執行。
- **SSH**：可用密碼、Ed25519、ECDSA、RSA 金鑰檔或 `ssh-agent` 登入。第一次連線時可核對主機指紋。最多可串接八台跳板，也可透過 SOCKS4、SOCKS4a、SOCKS5 或 HTTP CONNECT 代理連線。
- **連接埠轉發**：可在 SSH 分頁啟動本機轉發、反向轉發或動態 SOCKS 代理。把規則存進連線設定，每次連線後就會自動啟動。監聽限於本機或 SSH 伺服器的回送介面。
- **密碼庫**：可選用。沒有建立密碼庫時，登入成功的密碼會用 Secure Enclave 金鑰記在這台 Mac，之後直接連線、不再詢問。建立密碼庫後，這些密碼仍留在這台 Mac；密碼庫是另一個用主密碼保護的地方。開啟 MShell 後解鎖一次，在鎖上或結束 App 前，任何連線都不再要求 Touch ID 或 Mac 密碼。密碼庫鎖定時，勾選「每次連線都要求 Touch ID 或 Mac 密碼」的工作階段每次都會詢問，其他的用這台 Mac 記住的密碼直接連線。若密碼只存在鎖定的密碼庫，這一次詢問會用 Touch ID 讀出它（這次開 App 期間第一次用主密碼解鎖後啟用），密碼庫仍維持鎖定。密碼庫區塊收合且鎖定時，可按旁邊的指紋圖示解鎖。已在密碼庫的帳號，連線表單會顯示「已存入密碼庫」，點開可用輸入的密碼更新或移除；「存入密碼庫」可在登入前先存。
- **Secure Enclave 金鑰**：在金鑰選擇旁按「建立公鑰」。MShell 會在這台 Mac 的 Secure Enclave 建立 P-256 金鑰，存在 App 自己的資料夾；若這條連線還沒選金鑰，會直接套用。建立後按鈕會變成「查看公鑰」，按下才會顯示 OpenSSH 公鑰，可拷貝或重新產生。使用這把金鑰連線不需要按指紋。
- **登入一次就好**：密碼或金鑰 passphrase 登入成功後，MShell 會記在這台 Mac，之後連線不用再輸入。新建立的連線預設勾選「每次連線都要求 Touch ID 或 Mac 密碼」，先前存的工作階段維持原設定；密碼庫解鎖期間不會詢問。「已存密碼…」通過 Touch ID 或 Mac 密碼後會列出所有已存密碼和使用它的工作階段，可顯示、複製或刪除；複製的密碼 60 秒後會從剪貼簿清除。按金鑰旁的 × 會先確認，確認後已存的工作階段就不再使用它，密碼庫解鎖時會一併刪除該帳號已存的密碼和金鑰 passphrase；之後從工作階段樹連線也必須重新輸入密碼。仍會要求 Touch ID 的舊版 Secure Enclave 金鑰會顯示「需要 Touch ID」，改用 MShell 金鑰就不會再跳出。
- **重開已儲存的連線**：在左側連線樹按兩下，會在主視窗開新分頁。若主機金鑰變更，查證新指紋後再選「更新金鑰並重新連線」。在終端輸入 `exit` 或 `logout` 會關閉分頁；若是連線中斷，分頁會保留並提供「重新連線」。
- **SFTP**：沿用目前的 SSH 連線，可瀏覽、上傳、下載、重新命名及刪除遠端檔案。
- **匯入連線**：可預覽 Xshell 資料夾或 OpenSSH 設定再匯入。MShell 會保留 Xshell 的資料夾結構，也能讀取 OpenSSH 的主機別名、萬用字元預設值、包含檔案、金鑰與跳板設定。略過的項目會列在預覽裡。
- **工作區外觀**：右側主題清單有 72 組配色可選，包含 Ubuntu、Kali、GNOME、KDE Breeze、Tango、Linux 主控台配色，以及 GitHub、One Dark Pro、Dracula、Tokyo Night、Catppuccin、Nord、Gruvbox 等熱門 VS Code 主題。可以用名稱搜尋。所有終端都使用目前的工作區主題。介面支援英文、繁體中文和簡體中文。
- **工作區版面**：從工具列最右邊的版面選單切換，立即套用並記住選擇。三種版面共用連線、配色與工具。
  - **macOS**（預設）：Mac 工具列、扁平分頁、浮動窗格。
  - **Xshell 風格**：圖示工具列，以及可輸入 `ssh://使用者@主機:連接埠`、`使用者@主機` 或主機名稱的網址列。左側是工作階段管理員，分頁為方框樣式。終端下方的輸入列可把一行文字送到目前或所有工作階段。狀態列顯示位址、協定、終端大小、游標位置、工作階段數和 Caps Lock。
  - **MobaXterm 風格**：大圖示功能列。左側直立分頁可切換「工作階段」（含快速連線）、「SFTP」和「巨集」（常用指令）三個面板。分頁會編號。勾選 SFTP 下方的「跟隨終端資料夾」後，每執行一個指令，就會切到遠端 shell 所在的資料夾；如果 shell 不會回報資料夾，MShell 會在終端輸入一行提示字元掛鉤。終端下方的監控列會顯示這台 Mac 或 Linux 伺服器的 CPU、記憶體、網路、開機時間、使用者數和磁碟用量。

## 從原始碼建置

需要 macOS 14 以上與支援 Swift Package Manager 的 Xcode。目前已在 Apple silicon 上用 Apple Swift 6.4 驗證建置。

```sh
git clone https://github.com/LuckyFishOno/MShell.git
cd MShell
./analysis-app/MShell/scripts/package-app.sh
open analysis-app/build/MShell.app
```

指令會建置 App，並為本機產出的 App 套用 ad hoc 簽章。

## 從命令列設定版面

```sh
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout get
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout set mobaxterm
```

可選 `macos`、`xshell`（存成 `terminal`）或 `mobaxterm`（存成 `transfer`），下次啟動 App 時套用。

## 執行測試

```sh
swift test --package-path analysis-app/MShell
```

測試涵蓋終端輸入、連線匯入與儲存、SSH 驗證、跳板、轉送、重連及 SFTP。需要原始 Xshell 樣本的測試會略過；如有相容的本機樣本，可用 `XSHELL_DIR` 指定資料夾。AppKit 互動測試需要開著 macOS 桌面工作階段。

## 專案進度

目前仍是初版。SSH 互動式驗證與多因素驗證、完整 CLI 和 MCP、更多檔案傳輸協定以及遠端桌面都列在[路線圖](analysis-app/ROADMAP.md)。參考 Xshell 和 MobaXterm 整理的開發項目，請見[英文功能清單](analysis-app/FEATURE-BACKLOG.md)。

開發環境、程式目錄和第三方授權資訊請見[英文開發指南](analysis-app/DEVELOPMENT.md)。
