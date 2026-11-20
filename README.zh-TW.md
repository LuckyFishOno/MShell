# MShell

[English](README.md)

MShell 是 macOS 原生 SSH 客戶端。你可以把常用主機分門別類，在同一個工作區開終端、用 SFTP 瀏覽遠端檔案，也能並排查看兩條連線。

## 功能

- **連線管理**：用資料夾整理主機。按 ⌘K 搜尋已儲存的主機，或輸入 `user@host:port`。連線可開在頁籤或獨立視窗。
- **終端**：按 ⌘T 開啟本機 shell、⌘D 左右分割、⇧⌘D 上下分割。
- **SSH**：支援密碼和 OpenSSH Ed25519 金鑰。第一次連線時可核對主機指紋，也支援單段 SSH 跳板、SOCKS5 代理及本機連接埠轉送。
- **SFTP**：沿用目前的 SSH 連線，可瀏覽、上傳、下載、重新命名及刪除遠端檔案。
- **匯入 Xshell**：可先預覽資料夾，再匯入支援的 SSH 與 SFTP 連線。MShell 會保留資料夾結構，並列出略過的項目。登入憑證需另行設定。
- **工作區外觀**：右側主題清單有 18 組配色可選。介面支援英文、繁體中文和簡體中文。

## 從原始碼建置

需要 macOS 14 以上與支援 Swift Package Manager 的 Xcode。目前已在 Apple silicon 上用 Apple Swift 6.4 驗證建置。

```sh
git clone https://github.com/LuckyFishOno/MShell.git
cd MShell
./analysis-app/MShell/scripts/package-app.sh
open analysis-app/build/MShell.app
```

指令會建置 App，並為本機產出的 App 套用 ad hoc 簽章。

## 執行測試

```sh
swift test --package-path analysis-app/MShell
```

測試涵蓋終端輸入、連線匯入與儲存、SSH 驗證、跳板、轉送、重連及 SFTP。需要原始 Xshell 樣本的測試會略過；如有相容的本機樣本，可用 `XSHELL_DIR` 指定資料夾。AppKit 互動測試需要開著 macOS 桌面工作階段。

## 專案進度

目前是初版，SSH 支援單段跳板、Ed25519 金鑰檔登入及本機 TCP 轉送。Windows 遠端桌面、macOS 串列埠與更完整的終端相容性已列在[路線圖](analysis-app/ROADMAP.md)。

開發環境、程式目錄和第三方授權資訊請見[英文開發指南](analysis-app/DEVELOPMENT.md)。
