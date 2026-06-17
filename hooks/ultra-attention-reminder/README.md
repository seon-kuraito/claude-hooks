# Ultra Attention Reminder

在 Claude Code 結束回合或等待介入、而使用者已離開終端機時，發送一則帶音效的 macOS 桌面通知。優先透過隨附的 `Reminder.app` 發送（自訂圖示）；未建置該 app 時退回 `osascript`。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 `LICENSE`

　

## Summary

掛在 `Stop`（回合結束）與 `Notification`（等待權限或輸入）兩個事件的純 side-effect hook。兩者都僅在執行 Claude 的終端機非前景時發送，前景仍是該終端機則靜默跳過。通知後端採漸進增強：優先 `Reminder.app`（自訂圖示），未建置時退回 `osascript`。

　

## 設計取向

- **一支腳本、兩個事件**：
  - 同時註冊在 `Stop` 與 `Notification`，以 stdin 的 `hook_event_name` 分流
  - 專案名（cwd basename，轉為 Title Case，如 `claude-hooks` → `Claude Hooks`）放在標題——系統會自動以粗體放大，最醒目
  - `Stop` 內文 `✅ Task Finished`、`Notification` 內文 `🔔 Task Paused`
  - 不細分 notification 類型（stdin 無 `notification_type` 欄位），涵蓋權限、idle、表單等情境
- **通知方式漸進式增強**：
  - 優先使用 `~/.claude/tools/Reminder.app` 作為通知後端，以支援自訂圖示
  - 若未建置 `Reminder.app`，則自動退回使用 `osascript`
  - `osascript` 無自訂圖示，來源列為執行 `osascript` 的 host（如 Script Editor）
- **只在離開終端機時通知**：
  - 事件每回合都觸發
  - 以 `lsappinfo` 讀取最前景 app、比對 `TERM_PROGRAM` 對應的終端機 bundle
  - 前景仍是執行 Claude 的終端機（代表正在檢視）則 `exit 0` 跳過
- **純 side-effect，不阻擋**：
  - 不論成敗一律 `exit 0`，不回傳任何 decision JSON
  - 無法發送通知的環境（遠端、非 macOS、缺 `jq`）一律靜默跳過
- **動態內容走 argv，不內嵌**：
  - 標題與內文皆以引數傳入（app 走 `--args`，osascript 走 argv），不字串內嵌

　

## Reminder.app

原始碼在同目錄 `app/`：

- `Reminder.swift` — 以 `UNUserNotificationCenter` 發通知
- `Info.plist` — bundle id `dev.seonkuraito.claude-code`、`LSUIElement`
- `icon.png` — 1024×1024 圖示來源
- `build.sh` — `swiftc` 編譯 + 組 `.app` + 由 `icon.png` 產生 `AppIcon.icns` + ad-hoc 簽章，產到 `~/.claude/tools/Reminder.app`

建置與使用：

- **建置**：執行 `app/build.sh`（可重複執行，每次重建並覆蓋產物）
- **無第三方相依**：只用系統內建的 `swiftc` / `codesign` / `sips` / `iconutil`，ad-hoc 簽章免 Apple Developer 帳號
- **僅首次授權**：第一次發送會跳「允許通知」，按一次即可
- **產物不進版控**：`.app` 是 runtime 產物，置於 `~/.claude/tools/`
- **更換圖示**：替換 `app/icon.png`（1024×1024）再重新執行 `build.sh` 即可

　

## 預設與相依（可依需求抽換）

- **平台**：
  - 僅 macOS——app 後端靠 `UserNotifications`，osascript 後端靠 `osascript`；焦點偵測靠 `lsappinfo`、事件解析靠 `jq`
- **事件**：
  - `Stop`（無 matcher）與 `Notification`（空 matcher，涵蓋所有通知類型）
- **終端機辨識**：
  - 依下方對照表把 `TERM_PROGRAM` 對到 macOS App，用於前景判斷；目前內建支援 iTerm2／Terminal／VS Code／Ghostty／WezTerm
  - 不在表中的終端機：無法判斷前景，退回為一律發送
- **音效**：
  - 預設 `Glass`，可改為其他 macOS 內建的提示音效
