# Secret Blocker

在 `PreToolUse` 事件上攔下任何碰到祕密檔案（`.env` 家族、私鑰、憑證庫）的工具呼叫，在工具執行前直接拒絕。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 [`LICENSE`](LICENSE)

　

## 為什麼做這個 hook（WHY）

- **權限允許不等於可以被讀到**：
  - 祕密檔案存放資料庫連線字串、API 金鑰與私鑰，一旦讀進對話就會留在 transcript 裡，直到 session 結束
- **靠提示詞約束不可靠**：
  - `CLAUDE.md` 的規則由模型判讀，模型可能在多步驟任務中忽略；hook 由 harness 執行，不受模型判斷影響
- **有可能被繞過**：
  - 除了 `Read`，`cat`、`grep`、`sed` 等 Bash 指令與 `Glob` 搜尋都能取得同樣內容
- **祕密不只在 `.env`**：
  - SSH 私鑰、`~/.aws/credentials`、`.npmrc` 的 registry token 與憑證庫外洩的後果一樣嚴重，只擋 `.env` 會留下太大的空隙

　

## 這個 hook 做什麼（WHAT）

- **攔截時機**：
  - `PreToolUse`，matcher 為 `Read|Edit|Write|NotebookEdit|Glob|Grep|Bash|mcp__.*`
- **判定清單**：
  - 完整檔名：`.env`、`.dev.vars`、`credentials`、`.git-credentials`、`.netrc`、`_netrc`、`.npmrc`、`.pypirc`、`.htpasswd`、`id_rsa`、`id_ed25519`、`id_ecdsa`、`id_dsa`
  - 前綴家族：`.env.*`、`.dev.vars.*`
  - 後綴家族：`*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore`
  - 祕密目錄：`.ssh`、`.aws`、`.gnupg`
  - 白名單：`cert.pem`、`fullchain.pem`、`chain.pem`、`ca.pem`、`cacert.pem`、`ca-bundle.pem` 一律放行
- **五條判定規則**：
  - 具體路徑欄位（`file_path`、`notebook_path`、`path`）比對 basename；寫入類工具另對範例檔放行
  - glob 樣式欄位（`Glob` 的 `pattern`、`Grep` 的 `glob`）取最後一段做雙向比對
  - `Bash` 的 `command` 字串分兩層比對，dotfile 需要前方邊界，裸名與後綴不需要
  - 其餘工具（含所有 MCP）掃描 `tool_input` 裡的每一個字串與物件鍵
  - `Grep` 在 `output_mode` 為 `content` 時，額外比對 `path` 的每一段是否為祕密目錄
- **比對不分大小寫**：
  - macOS 的 APFS 預設不分大小寫，`.ENV` 與 `.SSH/ID_RSA` 打得開真正的檔案，因此五條規則一律不分大小寫比對
- **決定方式**：
  - 輸出 `permissionDecision: "deny"` 的結構化 JSON 並 `exit 0`，把理由與替代做法一併傳給 Claude
- **主要實作集中在 hook.sh**：
  - 事件解析、清單比對與決定邏輯見 [`hook.sh`](hook.sh)

　

## 如何使用這個 hook（HOW）

### 安裝

- **手動安裝**：
  - 把整個 hook 目錄複製進 `~/.claude/hooks/`
  - 確認 `hook.sh` 具執行權限（`chmod +x`），再依下方「註冊」手動登記
- **執行腳本**：

  ```sh
  cd claude-hooks
  scripts/link-hook.sh sk-secret-blocker
  ```

  - 連結進 `~/.claude/hooks/`
  - 註冊仍需手動完成（見下方）
- **註冊到 `settings.json`（手動，兩種安裝方式都需要）**：
  1. 打開 `~/.claude/settings.json`（沒有就新建）
  2. 在頂層 `hooks` 下加入 `PreToolUse`，matcher 為 `Read|Edit|Write|NotebookEdit|Glob|Grep|Bash|mcp__.*`
  3. 該項目的 `command` 指向 `~/.claude/hooks/sk-secret-blocker/hook.sh`，並設 `timeout` 為 `5`
  4. 完整宣告見 repo 的 [`settings.hooks.json`](../../settings.hooks.json)，照抄或合併進去後存檔即生效

　

### 設計取向

- **採用 `deny`，不使用 `ask`**：
  - `deny` 是唯一在所有 permission mode 下都保證生效的決定，官方文件載明它在 `bypassPermissions` 與 `--dangerously-skip-permissions` 之下仍然擋得住
  - `ask` 沒有同等保證，而且曾被回報會蓋掉 `permissions.deny` 規則（見 [anthropics/claude-code#39344](https://github.com/anthropics/claude-code/issues/39344)）
  - 真正需要存取時，可以暫時關掉這個 hook；把決定改得比較寬鬆反而會削弱保護
- **拒絕不會中斷回合**：
  - `command` hook 的 `deny` 會把 `permissionDecisionReason` 當成工具錯誤回傳給 Claude，讓它改走其他路徑，整個回合不會因此中斷
  - `continueOnBlock` 是 `prompt` 與 `agent` hook 的欄位，`command` hook 不接受它，也不需要
- **比對策略往精準收**：
  - 在 `deny` 之下，每一次多攔都是一堵牆，正當操作會被直接擋住
  - 所以每條規則都往精準的方向收，寧可用白名單處理已知的公開檔案，也不放寬整個家族
- **`Grep` 的 `pattern` 不納入比對**：
  - 該欄位是正規表達式而非路徑，比對它會擋掉在程式碼裡搜尋 `\.env` 的正當需求
- **glob 樣式取最後一段做雙向比對**：
  - 只做精確比對會漏掉 `**/.env*` 這類樣式，因為它的最後一段是 `.env*`，和 `.env` 不完全相同
  - 做法是把該段的萬用字元與大括號去掉，用剩下的字面文字與清單雙向比對（例如：`**/.env*` 剩 `.env`、`**/*.pem` 剩 `.pem`、`**/{.env,.npmrc}` 剩 `.env,.npmrc`）
  - 清單上最短的項目是四個字元（`.env`），所以字面文字不足四個字元的樣式不視為命中，否則 `**/*.py` 會因為 `.py` 是 `.pypirc` 的片段而誤中
  - 完全沒有字面文字的樣式（例如：`**/*`、`.*`）同樣不視為命中，因為列出檔名不等於取得內容
- **Bash 比對分兩層**：
  - dotfile 名稱需要前方邊界，因此 `process.env`、`import.meta.env` 與 `next-env.d.ts` 不會被誤攔
  - `id_rsa` 這類裸名與 `<字幹>.key` 這類後綴不需要前方的 `/`，因此 `cat private.key` 與 `ssh-keygen -f id_rsa` 擋得到
  - 後綴要求至少一個字幹字元，否則 `jq -r '.key'` 會誤中
  - jq 濾鏡中的欄位路徑會先遮蔽再比對：包含 `gh` 的 `--jq` 值，以及 `jq` 的第一個位置引數，因此 `gh api … --jq '.licenseInfo.key'` 不會誤中
  - jq 濾鏡本身不會開啟檔案，因此遮蔽只套用在濾鏡內容；`jq` 的輸入檔、`--slurpfile`／`--rawfile` 的值，以及 `-f`／`--from-file` 指定的檔案仍會比對
  - `credentials` 綁定在 `.aws/` 之下，因為它是一般英文字，放寬會讓 `grep -rn credentials src/` 與 `cd packages/credentials` 一起誤中
- **Bash 以指令文字作為比對範圍**：
  - 指令字串中出現祕密檔名時會拒絕執行，即使該文字是要寫入文件或作為資料使用（例如：heredoc 內容提到 `.env`、`echo 'rotate id_rsa' >> todo.md`）
  - 這項誤攔屬於已知取捨：heredoc 內容可能直接交由直譯器執行（例如 `python3 - <<'PY'`），若排除在比對範圍外，會增加繞過風險
  - 遇到誤攔時，可改寫用詞，或暫時停用這個 hook；不建議以字串拼接規避比對
  - `tests/fixtures/` 的 `deny-bash-heredoc-mentions-dotenv.json` 與 `deny-bash-echo-mentions-private-key.json` 覆蓋這項行為，避免後續改動誤將其視為 bug
- **MCP 工具掃描整份 `tool_input`**：
  - MCP 的參數欄位名不固定，無法逐一指定，因此掃過 `tool_input` 的每個字串與物件鍵
  - 這條規則同時看得到內容離開本機的方向（例如：把祕密檔案路徑貼進遠端頁面）
  - MCP 的酬載大多是散文，`<字>.key` 出現在句子裡通常只是文字，不一定是路徑，所以這條規則沿用要求 `/` 的嚴格樣式；`.env` 這類 dotfile 名稱不受影響
  - MCP 的酬載可能有數 MB，而 bash 3.2 的 glob 比對是 O(n²)，因此正規表達式只跑一次整份掃描，逐字串的 basename 比對只套用在沒有空白、長度在 512 字元以內的路徑形狀字串上
- **`TodoWrite` 直接放行**：
  - matcher 的正規表達式沒有錨定，`Write` 會連帶匹配到 `TodoWrite`
  - 待辦事項提到祕密檔案路徑並不會碰到檔案，不應該被擋
- **失敗時一律放行**：
  - `jq` 缺失、stdin 為空或內容無法解析時 `exit 0`
  - 反向做法會讓每一次工具呼叫都被拒絕，代價遠高於漏擋
- **fixture 測試**：
  - `tests/fixtures/` 依 `deny-` 與 `allow-` 前綴標示預期結果，每條規則都配有命中與放行案例
  - 以 `bash tests/run.sh` 執行全部案例，離開碼非零表示有案例未通過

　

### 預設與相依

- **相依**：
  - 需要 `jq` 與 `bash`；腳本相容 macOS 內建的 bash 3.2
- **不在範圍內的檔名**：
  - `.envrc`、`.environment`、`terraform.tfvars`、`secrets.*` 不擋，因為它們常常只是一般設定
  - 需要納入時，修改 [`hook.sh`](hook.sh) 的 `is_secret_basename` 與 `SECRET_TOKENS`
- **範例檔只放行寫入**：
  - `Write`、`Edit`、`NotebookEdit` 碰到 `.example`、`.sample`、`.template` 結尾的檔案放行，因為 `Write` 的內容由 Claude 產生、`Edit` 的 `old_string` 也得先從別處取得，兩者都不可能外洩
  - `Read` 與其餘四條規則仍然攔下，因為真值被貼進範例檔是已知的外洩途徑
  - 要改動範圍時，修改 [`hook.sh`](hook.sh) 的 `is_example_name`
- **公開憑證白名單**：
  - `*.pem` 同時涵蓋憑證鏈與私鑰，一律攔下會讓 TLS 相關工作整片讀不到，因此六個標準的公開憑證檔名放行
  - `privkey.pem` 與其餘 `*.pem` 仍然攔下；要增減清單，修改 [`hook.sh`](hook.sh) 的 `is_public_cert`
- **已知的誤判**：
  - Bash 指令裡只要提到祕密檔案名就會被擋，即使它並未真的讀檔（例如：`echo ".env" >> .gitignore`、`git commit -m "fix config.key parsing"`）
  - 白名單以外的公開憑證仍會被擋（例如：`cat certs/server.pem`）
  - jq 濾鏡以外的屬性存取仍會被擋（例如：`node -e "console.log(obj.key)"`）；`gh` 的簡寫 `-q` 不會視為 jq 濾鏡；需使用 `--jq` 套用遮蔽
  - 超過 4096 字元的指令不做 jq 濾鏡遮蔽，濾鏡中的欄位路徑會照常比對
- **已知的漏擋**：
  - Bash 指令裡 `.aws/` 以外的 `credentials` 檔不會命中（例如：`cat /etc/app/credentials`）；`Read` 仍會命中
  - MCP 酬載裡不帶 `/` 的裸檔名不會命中（例如：散文中的 `private.key`）；`Read` 與 `Bash` 仍會命中
  - glob 樣式若不含清單上的字面片段就不會命中（例如：`*.local` 匹配得到 `.env.local`，但樣式本身看不出來）
  - `Grep` 的 `content` 模式若指向祕密目錄清單以外、但內含祕密檔案的目錄（例如：專案根目錄），仍會取得內容
- **未涵蓋的取得路徑**：
  - 環境變數本身（例如：`printenv`、`env`）不在攔截範圍內
- **hook 仍需搭配 permission 規則**：
  - matcher 與 `if` 會 fail open，硬性保證仍應搭配 permission 規則
