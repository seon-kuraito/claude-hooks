# Ultra Attention Reminder

在 Claude Code 結束回合或等待介入、而使用者已離開終端機時，發送一則帶音效的 macOS 桌面通知。優先透過隨附的 `Reminder.app` 發送（自訂圖示）；未建置該 app 時退回 `osascript`。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 `LICENSE`

　

## Summary

掛在 `Stop`（回合結束）與 `Notification`（等待權限或輸入）兩個事件的純 side-effect hook。只在「你沒在看正在跑的那個 session」時發送——iTerm 精準到 session、其餘到 App 級。**點擊通知會跳回 Claude 所在的視窗**。通知後端採漸進增強：優先 `Reminder.app`（自訂圖示），未建置時退回 `osascript`。

　

## 設計取向

- **一支腳本、兩個事件**：
  - 同時註冊在 `Stop` 與 `Notification`，以 stdin 的 `hook_event_name` 分流
  - 專案名（cwd basename，轉為 Title Case，如 `claude-hooks` → `Claude Hooks`）放在標題
  - `Stop` 內文 `✅ Task Finished`、`Notification` 內文 `🔔 Task Paused`
  - 不細分 notification 類型（stdin 無 `notification_type` 欄位），涵蓋權限、idle、表單等情境
- **通知方式漸進式增強**：
  - 優先使用 `~/.claude/tools/Reminder.app` 作為通知後端，以支援自訂圖示
  - 若未建置 `Reminder.app`，則自動退回使用 `osascript`
  - `osascript` 無自訂圖示，來源列為執行 `osascript` 的 host（如 Script Editor）
- **只在離開「正在跑的那個 session」時通知**：
  - 事件每回合都觸發
  - 先用 `lsappinfo` 比對最前景 app 是否為執行 Claude 的終端機，是的話再深一層
  - iTerm：以 `osascript` 將「最前景的 session id」與「發通知這個 session」比對，只有正在看著它才靜默（看著同一 App 的別的視窗仍會通知）
  - 其他終端機：沒有 session 探測，維持 App 級（看著該 App 任一視窗即靜默）
- **點擊通知跳回來源**：
  - 點橫幅跳回 Claude 所在的視窗
  - iTerm 以 session id（AppleScript `select`）、VS Code 以專案資料夾，其餘則退回 App 級
  - 跨桌面 / 螢幕由 macOS 自動跟隨（見「設計決策與取捨」）
- **純 side-effect，不阻擋**：
  - 不論成敗一律 `exit 0`，不回傳任何 decision JSON
  - 無法發送通知的環境（遠端、非 macOS、缺 `jq`）一律靜默跳過
- **動態內容走 argv，不內嵌**：
  - 標題與內文皆以引數傳入（app 走 `--args`，osascript 走 argv），不字串內嵌

　

## 設計決策與取捨（閘門與點擊跳回）

閘門與點擊跳回共用同一個想法：**在發通知的當下記住「Claude 在哪個 session」，這個身分用兩次**——判斷該不該通知、以及點擊時跳回哪裡。點擊處理跑在 `Reminder.app` 裡、拿不到原 session 的環境，所以由 hook 在發通知時把身分烤進 `--args`。

身分把手依終端機漸進增強：

| 終端機 | 把手 | 精準度 | 權限 |
|---|---|---|---|
| iTerm | `ITERM_SESSION_ID` | session（視窗／分頁／分割） | 閘門免授權；點擊跳回首次需一次「允許控制 iTerm」 |
| VS Code | 專案資料夾路徑 | 視窗（靠「一資料夾一視窗」慣例） | 無 |
| 其他 | App bundle | App 級 | 無 |

關鍵取捨：

- **iTerm 用 AppleScript `select`，不用官方 reveal URL**：`iterm2:///reveal?sessionid=` 在現行 iTerm（3.6.x）實測無效（scheme 有註冊、`open` 成功，但焦點不動）；AppleScript 按 id 選 session 才真的精準。代價：點擊跳回的 Apple Events 由 `Reminder.app` 發出（不在 iTerm 程序樹內），首次跳一次 Automation 授權；閘門的查詢因在 hook（iTerm 子孫程序）內執行而免授權。
- **跨桌面 / 螢幕不是我們做的，是系統**：靠 macOS「切換 App 時切到有視窗的桌面」設定（`AppleSpacesSwitchOnActivate`，預設開）。關掉它就只在當前桌面生效；hook 不擅自更改（改它要重啟 Dock）。
- **刻意不解的邊角**：
  - VS Code 的「閘門」維持 App 級（VS Code 無法從外部回報前景視窗）——看著 VS Code 視窗 A、視窗 B 完成仍會被靜音
  - 要精準到「VS Code 裡的某個終端分頁」→ 需在該終端跑 tmux
  - 任意終端機、多視窗散在多桌面要命中「那一個」→ 只有私有 SkyLight API 做得到（免 SIP、ad-hoc 可），但私有且會被 macOS 版本改壞，**刻意不採用**，優雅退回 App 級

　

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
  - 依下方對照表把 `TERM_PROGRAM` 對到 macOS App，用於前景判斷與點擊跳回；目前內建支援 iTerm2／Terminal／VS Code／Ghostty／WezTerm
  - 不在表中的終端機：無法判斷前景，退回為一律發送
- **音效**：
  - 預設 `Glass`，可改為其他 macOS 內建的提示音效
