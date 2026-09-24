# Claude Hooks

本 repo 用於維護個人使用的 Claude Code [Hooks](https://docs.claude.com/en/docs/claude-code/hooks)。實際檔案由 repo 進行版本控制，並透過 symlink 連結至 Claude Code 的執行環境。

　

## Hooks 一覽

本 repo 目前維護以下 hook：

| hook | 用途 | 來源 |
| --- | --- | --- |
| [`sk-task-notifier`](hooks/sk-task-notifier) | 在回合結束或等待介入時發送 macOS 桌面通知 | 原創 |
| [`sk-tooluse-blocker`](hooks/sk-tooluse-blocker) | 在工具執行前拒絕存取祕密檔案的呼叫，以及在 zsh 中必定出錯的 shell 指令 | 原創 |

　

## 運作方式

Hooks 與 skills 的整合方式不同：hooks 沒有探索目錄，每個 hook 都需在 `~/.claude/settings.json` 中登記指令路徑，而該路徑可指向任意位置。本 repo 因此只將 hook 腳本納入版本控制，不直接管理經常變動的設定檔：

```
~/Developer/<owner>/claude-hooks/hooks/<name>/   ← 實際檔案（本 repo）
~/.claude/hooks/<name>                           ← symlink，逐一建立
```

與 [claude-skills](https://github.com/seon-kuraito/claude-skills) 相同，各 hook 會分別連結至執行環境。直接安裝在 `~/.claude/hooks/` 的官方或第三方 hook 不會納入本 repo。`settings.json` 中的登記指向 `~/.claude/hooks/<hook-name>/hook.sh`，再由 symlink 解析至本 repo。

　

### 為什麼不直接 symlink `settings.json`？

`settings.json` 屬於執行階段狀態；切換 model、theme 或調整權限時，Claude Code 都可能改寫該檔案。若將其鏡射至公開 repo，無關的本機狀態也會進入版本控制，並增加機密資訊外洩的風險。因此，本 repo 採用「宣告與對照」（declare and compare）的管理方式：

- [`settings.hooks.json`](settings.hooks.json) 宣告 `hooks/` 中每個 hook 應如何登記，是 hook 註冊方式的參考來源
- 實際的 `settings.json` 仍手動更新對齊；之後可再加入 check script 自動比對

　

## 使用方式

把 repo 裡的 hook 連結到 Claude Code 執行環境：

```sh
scripts/link-hook.sh <hook-name>
```

`<hook-name>` 是 `hooks/` 下的資料夾名稱（例如：`sk-task-notifier`）。

腳本可重複執行：已連結的 hook 會跳過，也不會覆蓋非本 repo 管理的 symlink（例如：同名的第三方 hook）。若該 hook 附有 `install.sh`，連結後會一併執行，以處理可重複執行的 post-link 設定（例如：建置產物或檢查註冊）。

　

## 驗證

提交前檢查 repo 裡的 hook：

```sh
scripts/run-checks.sh              # 全部 hook
scripts/run-checks.sh <hook-name>  # 單一 hook
```

這支腳本執行結構層與腳本層檢查，兩者都不消耗模型 token。hook 由事件觸發，模型不會路由到它，因此不設模型層。共通規則來自 [claude-skills](https://github.com/seon-kuraito/claude-skills) 的 `sk-skill-author/references/verification.md`；並列 repo 不存在時會跳過規則比對，單獨 clone 本 repo 仍可執行。

　

## 新增 hook

1. 在 `hooks/<hook-name>/` 下撰寫 hook（內含 `hook.sh` 的資料夾）。
2. 執行 `scripts/link-hook.sh <hook-name>` 讓它出現在 `~/.claude/hooks/`（若 hook 帶 `install.sh`，連結後會一併執行其 post-link 設定）。
3. 為 hook 撰寫 `tests/`：以 fixture 事件 JSON 作為輸入，斷言 exit code、stdout 與可觀察的呼叫。每個 hook 都需提供測試，測項依 hook 性質調整。
4. 為 hook 撰寫一份自己的 `README.md`，說明：
   - **用途**：解決什麼問題、何時觸發
   - **來源**：原創，或衍生自哪個上游專案
   - **授權**：適用的 license 與相關聲明
5. commit 前確認來源與授權：
   - **原創作品**：採用本 repo 的授權
   - **衍生自寬鬆授權的上游**：保留上游授權，並在 hook 資料夾內以 `NOTICE` 標明來源、作者與修改內容
   - **來源不明或授權不相容**：不收入本 repo
6. 在 `settings.hooks.json` 宣告 hook 的登記方式。
7. 把登記套用到實際的 `~/.claude/settings.json`。
