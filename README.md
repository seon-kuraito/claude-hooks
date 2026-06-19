# Claude Hooks

個人維護的 Claude Code [Hooks](https://docs.claude.com/en/docs/claude-code/hooks)。這個 repo 保存實際檔案並負責版控，再透過 symlink 掛進 Claude Code 的執行環境。

　

## Hooks 一覽

本 repo 目前維護以下 hook：

| hook | 用途 | 來源 |
| --- | --- | --- |
| [`ultra-attention-reminder`](hooks/ultra-attention-reminder) | 在回合結束或等待介入時發送 macOS 桌面通知 | 原創 |

　

## 運作方式

Hooks 和 skills 的接線方式不同：hooks 沒有探索目錄。每個 hook 都是在 `~/.claude/settings.json` 裡登記指令路徑，而路徑可以指向任何位置。本 repo 利用這一點，把 hook 腳本納入版控，同時避免直接管理那份經常變動的設定檔：

```
~/Developer/claude-hooks/hooks/<name>/   ← 實際檔案（本 repo）
~/.claude/hooks/<name>                   ← symlink，逐一建立
```

和 [claude-skills](https://github.com/seon-kuraito/claude-skills) 一樣，hook 會逐一連結到執行環境：`~/.claude/hooks/` 中官方或第三方直接安裝的 hooks 不會進入本 repo。`settings.json` 中的登記指向 `~/.claude/hooks/<hook-name>/hook.sh`，再透過 symlink 解析回本 repo。

　

### 為什麼不直接 symlink `settings.json`？

`settings.json` 是執行階段狀態：切換 model、theme 或調整權限時，Claude Code 都可能改寫它。把它鏡射進公開 repo，等於把無關的機器狀態一起版控，也增加洩漏機密的風險。因此本 repo 採用「宣告與對照」（declare and compare）的做法：

- [`settings.hooks.json`](settings.hooks.json) 宣告 `hooks/` 中每個 hook 應如何登記，是 hook 註冊方式的參考來源
- 實際的 `settings.json` 仍手動更新對齊；之後可再加入 check script 自動比對

　

## 使用方式

把 repo 裡的 hook 連結到 Claude Code 執行環境：

```sh
scripts/link-hook.sh <hook-name>
```

`<hook-name>` 是 `hooks/` 下的資料夾名稱（例如：`ultra-attention-reminder`）。

腳本可重複執行：已連結的 hook 會略過，也不會覆蓋非自身管理的 symlink（例如：同名的第三方 hook）。若該 hook 自帶 `install.sh`，連結後會一併執行，用來處理可重複的 post-link 設定（例如：建置產物或檢查註冊）。

　

## 新增 hook

1. 在 `hooks/<hook-name>/` 下撰寫 hook（內含 `hook.sh` 的資料夾）。
2. 執行 `scripts/link-hook.sh <hook-name>` 讓它出現在 `~/.claude/hooks/`（若 hook 帶 `install.sh`，連結後會一併執行其 post-link 設定）。
3. 為 hook 撰寫一份自己的 `README.md`，說明：
   - **用途**：解決什麼問題、何時觸發
   - **來源**：原創，或衍生自哪個上游專案
   - **授權**：適用的 license 與相關聲明
4. commit 前確認來源與授權：
   - **原創作品**：採用本 repo 的授權
   - **衍生自寬鬆授權的上游**：保留上游授權，並在 hook 資料夾內以 `NOTICE` 標明來源、作者與修改內容
   - **來源不明或授權不相容**：不收入本 repo
5. 在 `settings.hooks.json` 宣告 hook 的登記方式。
6. 把登記套用到實際的 `~/.claude/settings.json`。
