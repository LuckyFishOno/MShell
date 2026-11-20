# MShell

[English](README.md)

MShell 是 macOS 原生 SSH 客戶端。你可以把常用主機分門別類，在同一個工作區開終端、用 SFTP 瀏覽遠端檔案，也能並排查看兩條連線。

## 功能

- **連線管理**：用資料夾整理主機。點一下資料夾即可展開或收起。按側欄按鈕或 ⌃⌘S 收起或展開連線樹。連線可開在頁籤或獨立視窗。
- **終端**：按 ⌘T 開啟本機 shell。把分頁拖到任一格的左、右、上、下邊緣，就會往那一側分割；拖到正中間則改在那一格顯示。分割後在分頁列只佔一個「工作區」分頁，滑過可看到裡面有哪些連線，每一格有自己的標頭；把標頭拖到別的邊緣可搬移那一格，拖回分頁列就會拆成獨立分頁。標頭的 × 會中斷連線並關閉那個工作階段。分頁多時會等比例縮小，最小只剩圖示。也可以按 ⌘D 把目前這格左右分割、⇧⌘D 上下分割。每一格都能再切，分隔線可以拖動。⇧⌘↩ 放大或還原這一格，⌥⌘I 同步輸入到所有格。方塊游標固定顯示在 shell 的輸入位置，仍可用滑鼠選取和複製文字。
- **常用指令**：在右側面板儲存、搜尋單行指令。可插入目前選取的終端再編輯，也可確認指令與目的地後直接執行。
- **SSH**：支援密碼和 OpenSSH Ed25519 金鑰。第一次連線時可核對主機指紋，也支援單段 SSH 跳板、SOCKS5 代理及本機連接埠轉送。
- **重開已儲存的連線**：在左側連線樹按兩下，會在主視窗開新分頁。App 開著時會沿用上次成功登入的密碼。若要在重開 App 後繼續使用，先用「儲存密碼」存進密碼庫，下次解鎖即可。若主機金鑰變更，查證新指紋後再選「更新金鑰並重新連線」。
- **SFTP**：沿用目前的 SSH 連線，可瀏覽、上傳、下載、重新命名及刪除遠端檔案。
- **匯入 Xshell**：可先預覽資料夾，再匯入支援的 SSH 與 SFTP 連線。MShell 會保留資料夾結構，並列出略過的項目。登入憑證需另行設定。
- **工作區外觀**：右側主題清單有 72 組配色可選，包含 Ubuntu、Kali、GNOME、KDE Breeze、Tango、Linux 主控台配色，以及 GitHub、One Dark Pro、Dracula、Tokyo Night、Catppuccin、Nord、Gruvbox 等熱門 VS Code 主題。可以用名稱搜尋。所有終端都使用目前的工作區主題。介面支援英文、繁體中文和簡體中文。
- **工作區版面**：預設為 macOS 版面。若要改用「終端」或「檔案」版面，請依下方說明從命令列設定。「終端」將頁籤移到最上方，並預設展開常用指令。「檔案」把目前 SSH 連線的檔案瀏覽器放在終端右側。三種版面共用連線、配色與工具。

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
./analysis-app/build/MShell.app/Contents/Resources/bin/mshell layout set transfer
```

可選 `macos`、`terminal` 或 `transfer`，下次啟動 App 時套用。

## 執行測試

```sh
swift test --package-path analysis-app/MShell
```

測試涵蓋終端輸入、連線匯入與儲存、SSH 驗證、跳板、轉送、重連及 SFTP。需要原始 Xshell 樣本的測試會略過；如有相容的本機樣本，可用 `XSHELL_DIR` 指定資料夾。AppKit 互動測試需要開著 macOS 桌面工作階段。

## 專案進度

目前是初版，SSH 支援單段跳板、Ed25519 金鑰檔登入及本機 TCP 轉送。CLI、更多檔案傳輸協定與遠端桌面已排入[路線圖](analysis-app/ROADMAP.md)。參考 Xshell 和 MobaXterm 整理的開發項目，請見[英文功能清單](analysis-app/FEATURE-BACKLOG.md)。

開發環境、程式目錄和第三方授權資訊請見[英文開發指南](analysis-app/DEVELOPMENT.md)。
