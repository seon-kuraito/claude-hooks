# Ultra Attention Reminder

在 Claude Code 結束回合或等待介入、而使用者已離開終端機時，發送一則帶音效的 macOS 桌面通知。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 `LICENSE`

　

## Summary

掛在 `Stop`（回合結束）與 `Notification`（等待權限或輸入）兩個事件的純 side-effect hook。兩者都僅在執行 Claude 的終端機非前景時發送，前景仍是該終端機則靜默跳過。

　

## 設計取向

- **一支腳本、兩個事件**：
  - 同時註冊在 `Stop` 與 `Notification`，以 stdin 的 `hook_event_name` 分流
  - 專案名（cwd basename，轉為 Title Case，如 `claude-hooks` → `Claude Hooks`）放在標題——系統會自動以粗體放大，最醒目
  - `Stop` 內文 `✅ Claude Code Finished`、`Notification` 內文 `🔔 Claude Code Paused`（emoji 提供顏色與語意符號）
  - 不細分 notification 類型（stdin 無 `notification_type` 欄位），涵蓋權限、idle、表單等情境
- **只在離開終端機時通知**：
  - 事件每回合都觸發
  - 以 `lsappinfo` 讀取最前景 app、比對 `TERM_PROGRAM` 對應的終端機 bundle
  - 前景仍是執行 Claude 的終端機（代表正在檢視）則 `exit 0` 跳過
- **純 side-effect，不阻擋**：
  - 不論成敗一律 `exit 0`，不回傳任何 decision JSON
  - 無法發送通知的環境（遠端、非 macOS、缺 `osascript` 或 `jq`）一律靜默跳過
- **動態內容走 argv，不內嵌腳本**：
  - 內文與標題（專案名）皆以引數傳入 `osascript`，不字串內嵌進 AppleScript

　

## 預設與相依（可依需求抽換）

- **平台**：
  - 僅 macOS——通知靠 `osascript`、焦點偵測靠 `lsappinfo`、事件解析靠 `jq`
- **事件**：
  - `Stop`（無 matcher）與 `Notification`（空 matcher，涵蓋所有通知類型）
- **終端機辨識**：
  - 「只在離開終端機時通知」會根據下方對照表，判斷執行 Claude 的終端機屬於哪個 macOS App；目前內建支援 iTerm2／Terminal／VS Code／Ghostty／WezTerm
  - 若使用的終端機不在對照表中，系統就無法確認該終端機是否仍在前景，因此會退回為「一律發送通知」
- **音效**：
  - 預設 `Glass`，可改為其他 macOS 內建的提示音效
