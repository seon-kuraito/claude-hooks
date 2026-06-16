# Claude Hooks

個人撰寫的 Claude Code [hooks](https://docs.claude.com/en/docs/claude-code/hooks)。以這個 repo 作為 single source of truth 進行版控，再透過 symlink 映射進 Claude Code 的執行環境。

　

## 運作方式

Hooks 與 skills 的接線機制不同：它沒有探索目錄。每個 hook 都是在 `~/.claude/settings.json` 中以指令路徑登記，而路徑可以指向任何位置。本 repo 利用這一點，讓 hook 腳本納入版控，同時不去動那份隨時在變動的設定檔：

```
~/Developer/claude-hooks/hooks/<name>/   ← single source of truth（本 repo）
~/.claude/hooks/<name>                   ← symlink，逐一建立
```

與 claude-skills 相同，hook 是逐一連結的：`~/.claude/hooks/` 也可能存放官方或第三方直接安裝的 hooks，它們永遠不會進入本 repo。`settings.json` 中的登記指向 `~/.claude/hooks/<hook-name>/hook.sh`，經由 symlink 解析進本 repo。

　

### 為什麼不直接 symlink `settings.json`？

`settings.json` 是活的執行階段狀態：切換 model、theme 或調整權限時，Claude Code 都會改寫它。把它鏡射進公開 repo，等於對無關的機器狀態做版控，未來也有洩漏機密的風險。因此本 repo 採用「宣告與對照」（declare and compare）的做法：

- [`settings.hooks.json`](settings.hooks.json) 宣告 `hooks/` 中每個 hook 應如何登記，是登記方式的 single source of truth。
- 實際的 `settings.json` 以手動方式更新對齊（之後可能加入 check script 自動比對）。

　

## 使用方式

把 repo 中的 hook 連結進 Claude Code 執行環境：

```sh
scripts/link-hook.sh <hook-name>
```

`<hook-name>` 是 hook 在 `hooks/` 中的資料夾名（例如 `notify-on-stop`）。

腳本具備「冪等性」（Idempotence）：對已連結的 hook 重複執行不會有任何動作，也不會覆蓋任何非自身 symlink 的目標（例如同名的第三方 hook）。

　

## 新增 hook

1. 在 `hooks/<hook-name>/` 下撰寫 hook（內含 `hook.sh` 進入點的資料夾）。
2. 執行 `scripts/link-hook.sh <hook-name>` 讓它出現在 `~/.claude/hooks/`。
3. 為 hook 撰寫一份自己的 `README.md`，說明：
   - **用途**：解決什麼問題、何時觸發
   - **來源**：原創，或衍生自哪個上游專案
   - **授權**：適用的 license 與相關聲明
4. commit 前確認出處：
   - **原創作品**：採用本 repo 的授權
   - **衍生自寬鬆授權的上游**：保留上游授權，並在 hook 資料夾內以 `NOTICE` 標明來源、作者與修改內容
   - **來源不明或授權不相容**：不收入本 repo
5. 在 `settings.hooks.json` 宣告它的登記方式。
6. 把登記套用到實際的 `~/.claude/settings.json`。
