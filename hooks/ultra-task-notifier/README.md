# Ultra Task Notifier

當 Claude Code 結束回合或等待介入，而使用者已離開終端機時，發送一則帶音效的 macOS 桌面通知。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 [`LICENSE`](LICENSE)

　

## 為什麼做這個 hook（WHY）

- **畫面離開就錯過**：
  - Claude Code 結束回合或等待輸入時，如果畫面不在終端機前，就很容易錯過並空等
- **多個 session 分不清**：
  - 同時開多個終端機或視窗跑 Claude 時，通知響了也不一定知道是哪個 session 需要處理
- **需要反覆回頭確認**：
  - 沒有主動提醒時，就得一直切回終端機確認是否已經跑完

　

## 這個 hook 做什麼（WHAT）

- **掛在 `Stop` 與 `Notification` 兩個事件**：
  - 回合結束、等待權限或輸入時，發一則帶音效的 macOS 桌面通知
- **看不到來源 session 時才提醒**：
  - iTerm 可精準判斷 session；其他終端機則退回 App 層級判斷，會嘗試跳回原本的視窗
- **通知後端漸進式增強（Progressive Enhancement）**：
  - 優先使用 `Reminder.app`（自訂圖示），未建立時退回 `osascript`
- **主要實作集中在 hook.sh**：
  - 事件解析、通知判斷與後端呼叫集中在 [`hook.sh`](hook.sh)

　

## 如何使用這個 hook（HOW）

### 安裝

- **手動安裝**：
  - 把整個 hook 目錄複製進 `~/.claude/hooks/`
  - 跑 `app/build.sh` 自行建立 `Reminder.app`（細節見下方 Reminder.app）
  - 依下方「註冊」手動登記
- **執行腳本**：

  ```sh
  cd claude-hooks
  scripts/link-hook.sh ultra-task-notifier
  ```

  - 連結進 `~/.claude/hooks/`；本 hook 帶有 `install.sh`，連結後會自動建立 `Reminder.app`，並**檢查（不改寫）**註冊狀態
  - 註冊仍需你手動完成（見下方）
- **註冊到 `settings.json`（手動，兩種安裝方式都需要）**：
  1. 打開 `~/.claude/settings.json`（沒有就新建）
  2. 在頂層 `hooks` 下，加入 `Stop` 與 `Notification`（matcher 為空字串 `""`）兩個事件
  3. 兩者的 `command` 都填 `~/.claude/hooks/ultra-task-notifier/hook.sh`
  4. 完整 JSON 見 repo 的 [`settings.hooks.json`](../../settings.hooks.json)，照抄或合併進去後存檔即生效

　

### 設計取向

- **同一支腳本處理兩種事件**：
  - hook 同時註冊在 `Stop` 與 `Notification` 事件上，並透過 stdin 中的 `hook_event_name` 判斷目前事件類型
  - 通知標題包含專案名稱；專案名稱由 cwd basename 轉成 Title Case（例如：`claude-hooks` → `Claude Hooks`）
  - `Stop` 事件顯示 `✅ Task Finished`，`Notification` 事件顯示 `🔔 Task Paused`
- **通知方式採漸進式增強**：
  - 優先使用 `~/.claude/tools/Reminder.app` 作為通知後端，支援自訂圖示
  - 若尚未建立 `Reminder.app`，則自動退回 `osascript`
  - `osascript` 無自訂圖示，通知來源會顯示為執行 `osascript` 的 host（例如：Script Editor）
- **依來源 session 判斷提醒與跳轉位置**：
  - 只有在使用者沒有看著來源 session 時，才會發送通知；點擊通知橫幅後，會嘗試回到該 session
  - iTerm 可精準定位到 session（視窗／分頁／分割）；其他終端機則退回 App 層級判斷
  - 判斷是否需要提醒、以及點擊後要回到哪裡，都取決於「Claude Code 當下所在的 session」
  - 定位精準度、各終端機差異與授權取捨，請見 [`references/session-targeting.md`](references/session-targeting.md)
- **保持純 side effect，不阻擋主流程**：
  - hook 不論成功或失敗都一律 `exit 0`，也不回傳任何 decision JSON
  - 若執行環境不適合發送通知（例如：遠端環境、非 macOS 或缺少 `jq`），則靜默跳過
- **動態內容一律透過 argv 傳入**：
  - 通知標題與內文皆以引數傳入，不把動態字串內嵌進腳本
  - `Reminder.app` 使用 `--args` 傳遞，`osascript` 則使用 argv 傳遞

　

### Reminder.app

- **原始碼在同目錄 `app/`**：
  - `Reminder.swift`：以 `UNUserNotificationCenter` 發通知
  - `Info.plist`：bundle id `dev.seonkuraito.claude-code`、`LSUIElement`
  - `icon.png`：1024×1024 圖示來源
  - `build.sh`：`swiftc` 編譯 + 組 `.app` + 由 `icon.png` 產生 `AppIcon.icns` + ad-hoc 簽章，產到 `~/.claude/tools/Reminder.app`
- **首次建立**：
  - 安裝時由 `install.sh` 自動處理
  - 若 `Reminder.app` 尚未存在，會建立到 `~/.claude/tools/Reminder.app`
- **重新建立**：
  - 修改 `app/` 內的原始碼或圖示後，執行 `app/build.sh` 即可重建
  - 此腳本可重複執行，每次都會覆蓋既有產物
- **產物不進版控**：
  - `.app` 是 runtime 產物，置於 `~/.claude/tools/`，不納入 repo
- **使用方式**：
  - 建立完成後由 hook 自動呼叫，使用者不需要手動開啟 `Reminder.app`
- **無第三方相依**：
  - 只用 macOS 系統內建的 `swiftc` / `codesign` / `sips` / `iconutil`
  - ad-hoc 簽章免 Apple Developer 帳號
- **僅首次授權**：
  - 第一次發送會跳「允許通知」，按一次即可
- **更換圖示**：
  - 替換 `app/icon.png`（1024×1024）再重新執行 `build.sh` 即可

　

### 預設與相依

- **平台**：
  - 僅 macOS：app 後端靠 `UserNotifications`，osascript 後端靠 `osascript`；焦點偵測靠 `lsappinfo`、事件解析靠 `jq`
- **事件**：
  - `Stop`（無 matcher）與 `Notification`（空 matcher，涵蓋所有通知類型）
- **終端機辨識**：
  - 依下方對照表把 `TERM_PROGRAM` 對到 macOS App，用於前景判斷與點擊跳回
  - 目前內建支援 iTerm2／Terminal／VS Code／Ghostty／WezTerm
  - 不在表中的終端機：無法判斷前景，退回為一律發送
- **音效**：
  - 預設 `Glass`，可改為其他 macOS 內建的提示音效
