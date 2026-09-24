# Tooluse Blocker

在 `PreToolUse` 事件中，於工具執行前拒絕存取祕密檔案（`.env` 家族、私鑰、憑證庫）的呼叫，以及在 zsh 中必定出錯的 Bash 指令。

　

## 聲明

- **來源**：
  - 原創
- **授權**：
  - MIT
  - 完整條款見同目錄 [`LICENSE`](LICENSE)

　

## 為什麼做這個 hook（WHY）

- **避免祕密內容進入對話紀錄**：
  - 祕密檔案可能包含資料庫連線字串、API 金鑰或私鑰；檔案一旦讀入對話，內容就會保留在 transcript 中，直到 session 結束
- **在模型之外執行限制**：
  - `CLAUDE.md` 的規則由模型判讀，在多步驟任務中可能遭到忽略；hook 由 harness 執行，不依賴模型判斷
- **涵蓋各種檔案存取方式**：
  - `Read` 以外，`cat`、`grep`、`sed` 等 Bash 指令及 `Glob` 搜尋也能取得檔案內容
- **涵蓋常見的祕密檔案**：
  - 除了 `.env`，也涵蓋 SSH 私鑰、`~/.aws/credentials`、`.npmrc` 中的 registry token 及憑證庫
- **避免工作目錄延續至後續呼叫**：
  - Bash 工具會沿用前一次呼叫的工作目錄。執行頂層 `cd` 後，後續指令與 subagent 都會從變更後的目錄開始
- **避免 zsh 特有的指令錯誤**：
  - zsh 會把 `=` 開頭的字展開成指令路徑，`echo ===` 與 `[ "$a" == "$b" ]` 因此以「not found」中止
  - zsh 會將變數 `path` 綁定至 `PATH`；對 `path` 賦值會清空指令搜尋路徑，使後續指令無法解析
- **避免 perl 單行腳本造成 CJK 亂碼**：
  - perl 會將 `-e` 腳本視為 Latin-1；腳本中的 CJK 字面值可能在輸出時變成亂碼，CJK 樣式也可能無法比對，且不會產生錯誤。若未提交的內容因此損毀，`git checkout` 無法還原原始內容

　

## 這個 hook 做什麼（WHAT）

- **攔截時機**：
  - `PreToolUse`，matcher 為 `Read|Edit|Write|NotebookEdit|Glob|Grep|Bash|mcp__.*`
- **兩組規則**：
  - 祕密檔案規則（`secret`）：適用於所有環境，執行順序固定在前
  - shell 陷阱規則（`shelltrap`）：僅檢查 `Bash`；三條 zsh 陷阱僅在使用者的 shell 為 zsh 時生效，perl 陷阱則適用於任何 shell
- **祕密檔案的判定清單**：
  - 完整檔名：`.env`、`.dev.vars`、`credentials`、`.git-credentials`、`.netrc`、`_netrc`、`.npmrc`、`.pypirc`、`.htpasswd`、`id_rsa`、`id_ed25519`、`id_ecdsa`、`id_dsa`
  - 前綴家族：`.env.*`、`.dev.vars.*`
  - 後綴家族：`*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore`、`*.env`
  - 祕密目錄：`.ssh`、`.aws`、`.gnupg`
  - 白名單：`cert.pem`、`fullchain.pem`、`chain.pem`、`ca.pem`、`cacert.pem`、`ca-bundle.pem` 一律放行；指令字串中的 `process.env`、`import.meta.env`、`Deno.env`、`Bun.env` 視為程式物件，同樣放行
- **祕密檔案的五條判定規則**：
  - 具體路徑欄位（`file_path`、`notebook_path`、`path`）比對 basename；寫入類工具另對範例檔放行
  - glob 樣式欄位（`Glob` 的 `pattern`、`Grep` 的 `glob`）取最後一段做雙向比對
  - `Bash` 的 `command` 字串分兩層比對，dotfile 需要前方邊界，裸名與後綴不需要
  - 其餘工具（含所有 MCP）掃描 `tool_input` 裡的每一個字串與物件鍵
  - `Grep` 在 `output_mode` 為 `content` 時，額外比對 `path` 的每一段是否為祕密目錄
- **shell 陷阱的四條判定規則**：
  - 拒絕頂層的 `cd`、`pushd`、`popd`；若位於 `( … )` 或 `$( … )` 內則放行，因為工作目錄的變更會在 subshell 結束時失效
  - 不在引號內、以 `=` 開頭且長度至少兩個字元的字拒絕；`[[ … ]]` 之內與 `=( … )` 放行
  - 把 `path` 當成變數名稱時拒絕（例如：`path=/tmp`、`for path in …`、`local path`、`read -r path`）
  - `perl -e`／`-pe`／`-ne` 的腳本含有非 ASCII 位元組時拒絕（例如：`perl -pe 's/舊詞/新詞/g'`）；此規則僅檢查 perl 指令中的字，`echo -e` 與 `sed -e` 不受影響；命令列含有 `-Mutf8`，或腳本內含有 `use utf8` 時放行
- **比對不分大小寫**：
  - macOS 的 APFS 預設不分大小寫，`.ENV` 與 `.SSH/ID_RSA` 打得開真正的檔案，因此祕密檔案的五條規則一律不分大小寫比對
- **決定方式**：
  - 輸出 `permissionDecision: "deny"` 的結構化 JSON 並 `exit 0`，把理由傳給 Claude
  - 祕密檔案規則的理由會要求停止重試或規避；shell 陷阱規則則提供可接受的改寫方式，供修正後重新送出
- **拒絕紀錄**：
  - 在 `~/.claude/logs/sk-tooluse-blocker.log` 追加一行：時間、規則組、工具、來自主 session 或 subagent、命中的目標（截短至 120 個字元）
- **實作結構**：
  - [`hook.sh`](hook.sh) 負責載入與分派。共用工具位於 [`lib/core.sh`](lib/core.sh)，jq 遮蔽濾鏡位於 [`lib/jqmask.sh`](lib/jqmask.sh)，指令斷詞邏輯位於 [`lib/tokens.awk`](lib/tokens.awk)。祕密檔名清單定義於 [`rules/secret-list.sh`](rules/secret-list.sh)；兩組規則分別位於 [`rules/secret.sh`](rules/secret.sh) 與 [`rules/shelltrap.sh`](rules/shelltrap.sh)

　

## 如何使用這個 hook（HOW）

### 安裝

- **手動安裝**：
  - 把整個 hook 目錄複製進 `~/.claude/hooks/`
  - 確認 `hook.sh` 具執行權限（`chmod +x`），再依下方「註冊」手動登記
- **執行腳本**：

  ```sh
  cd claude-hooks
  scripts/link-hook.sh sk-tooluse-blocker
  ```

  - 連結進 `~/.claude/hooks/`
  - 註冊仍需手動完成（見下方）
- **註冊到 `settings.json`（手動，兩種安裝方式都需要）**：
  1. 打開 `~/.claude/settings.json`（沒有就新建）
  2. 在頂層 `hooks` 下加入 `PreToolUse`，matcher 為 `Read|Edit|Write|NotebookEdit|Glob|Grep|Bash|mcp__.*`
  3. 該項目的 `command` 指向 `~/.claude/hooks/sk-tooluse-blocker/hook.sh`，並設 `timeout` 為 `5`
  4. 完整宣告見 repo 的 [`settings.hooks.json`](../../settings.hooks.json)，可直接複製或合併至既有設定
- **從 `sk-secret-blocker` 升級**：
  - 此 hook 原名為 `sk-secret-blocker`。由於 `settings.json` 中的 `command` 路徑包含目錄名稱，改名後需手動更新設定
  1. 執行 `scripts/link-hook.sh sk-tooluse-blocker` 建立新名稱的連結
  2. 將 `settings.json` 中的 `command` 路徑改為 `~/.claude/hooks/sk-tooluse-blocker/hook.sh`；執行中的 session 會立即套用新設定
  3. 將舊連結指向新目錄，使改名前啟動的 session 繼續套用此 hook：`ln -sfn <repo>/hooks/sk-tooluse-blocker ~/.claude/hooks/sk-secret-blocker`
  4. 待改名前啟動的 session 全部結束後，移除 `~/.claude/hooks/sk-secret-blocker`

　

### 設計取向

- **採用 `deny`，不使用 `ask`**：
  - `deny` 是唯一保證在所有 permission mode 下生效的決定；官方文件載明，即使使用 `bypassPermissions` 或 `--dangerously-skip-permissions`，仍會套用此決定
  - `ask` 不具備相同保證，且曾有覆蓋 `permissions.deny` 規則的回報（見 [anthropics/claude-code#39344](https://github.com/anthropics/claude-code/issues/39344)）
  - 如需存取受保護的檔案，可暫時停用此 hook；放寬決定會降低保護範圍
- **拒絕不會中斷回合**：
  - `command` hook 的 `deny` 會把 `permissionDecisionReason` 當成工具錯誤回傳給 Claude，讓它改走其他路徑，整個回合不會因此中斷
  - `continueOnBlock` 是 `prompt` 與 `agent` hook 的欄位，`command` hook 不接受它，也不需要
- **兩組規則放在同一個 hook**：
  - 多個 `PreToolUse` hook 之間只要有一個 `deny` 就算拒絕，一個 hook 無法撤銷另一個 hook 的決定，因此例外必須和它放寬的規則放在一起
  - 兩組規則共用同一次註冊、同一份紀錄與同一套測試；每組規則各自一個檔案，`hook.sh` 只負責載入與分派
  - 祕密檔案規則一律先執行；shell 陷阱的規則檔載入失敗時只會略過該組，不影響祕密檔案規則
- **兩組規則各自處理例外**：
  - shell 陷阱規則會排除引號內的文字、heredoc 內容、註解及 `[[ … ]]` 內部。例如，`echo "cd foo"` 不會變更工作目錄。這些情況由 [`lib/tokens.awk`](lib/tokens.awk) 統一處理
  - 祕密檔案規則不套用上述例外，因為 `cat ".env"` 仍會讀取檔案，heredoc 內容也可能直接交由直譯器執行
- **shell 陷阱只在 zsh 生效**：
  - 三條規則均針對 zsh 行為；`$SHELL` 為其他 shell 時，整組規則直接放行
  - 指令裡完全沒有 `cd`、`pushd`、`popd`、`=`、`path` 時，不會啟動斷詞
- **shell 陷阱的替代寫法**：
  - 三條規則的拒絕理由均會提供替代寫法，例如 `( cd <dir> && <command> )`、`git -C <dir>`、為文字加上引號，或改用其他變數名稱
  - 無法完成斷詞的內容會予以略過，因此解析失敗可能造成漏擋，但不會造成誤擋
- **只有 shell 陷阱可以單獨關閉**：
  - 設定環境變數 `SK_TOOLUSE_OFF=shelltrap`，或在 `~/.claude/sk-tooluse-blocker.off` 寫入 `shelltrap`
  - 祕密檔案規則不提供單獨開關，以免 Claude 透過修改單一檔案停用保護；如需存取，須停用整個 hook
- **降低誤擋範圍**：
  - `deny` 會直接阻止操作，因此規則採取較精確的比對條件；已知的公開檔案透過白名單處理，不放寬整個檔名家族
- **集中維護祕密檔案清單**：
  - 祕密檔名統一定義於 [`rules/secret-list.sh`](rules/secret-list.sh) 的 `SECRET_NAMES`、`SECRET_FAMILIES`、`SECRET_EXTS` 三個陣列。載入時，程式會由這些陣列產生 basename 比對項目、glob 使用的字面片段及兩條正規表達式
  - 產生過程只使用參數展開，不開 subshell，因為這個檔案在每一次工具呼叫前都會載入
- **`Grep` 的 `pattern` 不納入比對**：
  - 該欄位是正規表達式而非路徑，比對它會擋掉在程式碼裡搜尋 `\.env` 的正當需求
- **glob 樣式取最後一段做雙向比對**：
  - 只做精確比對會漏掉 `**/.env*` 這類樣式，因為它的最後一段是 `.env*`，和 `.env` 不完全相同
  - 做法是把該段的萬用字元與大括號去掉，用剩下的字面文字與清單雙向比對（例如：`**/.env*` 剩 `.env`、`**/*.pem` 剩 `.pem`、`**/{.env,.npmrc}` 剩 `.env,.npmrc`）
  - 清單上最短的項目是四個字元（`.env`），所以字面文字不足四個字元的樣式不視為命中，否則 `**/*.py` 會因為 `.py` 是 `.pypirc` 的片段而誤中
  - 完全沒有字面文字的樣式（例如：`**/*`、`.*`）同樣不視為命中，因為這類操作只列出檔名，不會取得檔案內容
- **Bash 比對分兩層**：
  - dotfile 名稱需要前方邊界，因此 `next-env.d.ts` 不會被誤攔
  - `id_rsa` 這類裸名與 `<字幹>.key`、`<字幹>.env` 這類後綴不需要前方的 `/`，因此 `cat private.key`、`cat prod.env` 與 `ssh-keygen -f id_rsa` 擋得到
  - `process.env`、`import.meta.env` 與 `<字幹>.env` 形狀相同，命中之後以白名單排除；`process.env.HOME` 這類寫法後面接的是 `.`，不構成邊界，本來就不會命中
  - 後綴要求至少一個字幹字元，否則 `jq -r '.key'` 會誤中
  - jq 濾鏡中的欄位路徑會先遮蔽再比對：包含 `gh` 的 `--jq` 值，以及 `jq` 的第一個位置引數，因此 `gh api … --jq '.licenseInfo.key'` 不會誤中
  - jq 濾鏡本身不會開啟檔案，因此遮蔽只套用在濾鏡內容；`jq` 的輸入檔、`--slurpfile`／`--rawfile` 的值，以及 `-f`／`--from-file` 指定的檔案仍會比對
  - `credentials` 綁定在 `.aws/` 之下，因為它是一般英文字，放寬會讓 `grep -rn credentials src/` 與 `packages/credentials` 這類路徑一起誤中
- **Bash 以指令文字作為祕密檔案的比對範圍**：
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
- **失敗時放行並顯示警告**：
  - `jq` 缺失，或 `lib/core.sh`、`lib/jqmask.sh`、`rules/secret-list.sh`、`rules/secret.sh` 任一檔案載入失敗時，程式會以 `exit 0` 結束，並透過 `systemMessage` 告知使用者保護目前失效。此訊息使用固定的 JSON，不依賴 `jq`
  - stdin 為空或內容無法解析時同樣 `exit 0`
  - 若在失敗時拒絕，所有工具呼叫都會遭到阻擋，因此此處採用放行策略
  - 規則放在被載入的檔案裡還有一個理由：`hook.sh` 本身若有語法錯誤，bash 會以離開碼 2 結束，而 `PreToolUse` 會把它視為拒絕，所有符合 matcher 的工具都會被鎖住；載入失敗則只會放行
- **紀錄位置**：
  - 紀錄可能包含真實路徑，因此寫入 `~/.claude/logs/`，不存放於 hook 目錄；寫入失敗不影響規則判定
- **fixture 測試**：
  - `tests/fixtures/` 依 `deny-` 與 `allow-` 前綴標示預期結果，每條規則都配有命中與放行案例
  - 每個案例都在固定的環境執行：`SHELL` 為 `/bin/zsh`（檔名含 `-bashshell-` 時為 `/bin/bash`）、`HOME` 為暫存目錄、檔名含 `-off-shelltrap-` 時設定 `SK_TOOLUSE_OFF`
  - 另外驗證兩件事：紀錄的行數等於 `deny-` 案例的數量，以及規則檔損壞時 hook 會放行並發出警告
  - 以 `bash tests/run.sh` 執行全部案例，離開碼非零表示有案例未通過

　

### 預設與相依

- **相依**：
  - 需要 `jq`、`awk` 與 `bash`；腳本相容 macOS 內建的 bash 3.2
- **不在範圍內的檔名**：
  - `.envrc`、`.environment`、`terraform.tfvars`、`secrets.*`、`.mcp.json` 不擋，因為它們常常只是一般設定
  - 如需納入其他檔名，修改 [`rules/secret-list.sh`](rules/secret-list.sh) 的 `SECRET_NAMES`、`SECRET_FAMILIES` 或 `SECRET_EXTS`
- **範例檔只放行寫入**：
  - `Write`、`Edit`、`NotebookEdit` 遇到以 `.example`、`.sample`、`.template` 結尾的檔案時放行。`Write` 的內容由 Claude 產生，`Edit` 的 `old_string` 也必須先由其他來源取得，因此這些操作不會直接讀取祕密內容
  - `Read` 與其餘四條規則仍然攔下，因為真值被貼進範例檔是已知的外洩途徑
  - 如需調整放行範圍，修改 [`rules/secret-list.sh`](rules/secret-list.sh) 的 `is_example_name`
- **公開憑證白名單**：
  - `*.pem` 同時涵蓋憑證鏈與私鑰，一律攔下會讓 TLS 相關工作整片讀不到，因此六個標準的公開憑證檔名放行
  - `privkey.pem` 與其餘 `*.pem` 仍會遭到攔截。如需調整清單，修改 [`rules/secret-list.sh`](rules/secret-list.sh) 的 `is_public_cert`
- **已知的誤判**：
  - Bash 指令裡只要提到祕密檔案名就會被擋，即使它並未真的讀檔（例如：`echo ".env" >> .gitignore`、`git commit -m "fix config.key parsing"`）
  - 存放一般設定但以 `.env` 結尾的檔案同樣會被擋（例如：`defaults.env`）
  - 白名單以外的公開憑證仍會被擋（例如：`cat certs/server.pem`）
  - jq 濾鏡以外的屬性存取仍會被擋（例如：`node -e "console.log(obj.key)"`）；`gh` 的簡寫 `-q` 不會視為 jq 濾鏡；需使用 `--jq` 套用遮蔽
  - 超過 4096 字元的指令不做 jq 濾鏡遮蔽，濾鏡中的欄位路徑會照常比對
- **已知的漏擋**：
  - Bash 指令裡 `.aws/` 以外的 `credentials` 檔不會命中（例如：`cat /etc/app/credentials`）；`Read` 仍會命中
  - MCP 酬載裡不帶 `/` 的裸檔名不會命中（例如：散文中的 `private.key`）；`Read` 與 `Bash` 仍會命中
  - glob 樣式若不含清單上的字面片段就不會命中（例如：`*.local` 匹配得到 `.env.local`，但樣式本身看不出來）
  - `Grep` 的 `content` 模式若指向祕密目錄清單以外、但內含祕密檔案的目錄（例如：專案根目錄），仍會取得內容
  - shell 陷阱僅進行有限的斷詞；`builtin cd`、`eval "cd foo"`、引號未閉合的指令及超過 16384 字元的指令均不會命中
  - zsh 的另外兩個陷阱無法從指令文字判定，因此不在範圍內：glob 沒有符合的檔案時整行中止，以及未加引號的變數不會斷詞
- **未涵蓋的取得路徑**：
  - 環境變數本身（例如：`printenv`、`env`）不在攔截範圍內
- **hook 仍需搭配 permission 規則**：
  - matcher 與 `if` 會 fail open；如需強制限制，仍應搭配 permission 規則
  - 在 `settings.json` 的 `permissions.deny` 中加入與祕密檔案清單對應的 `Read` 規則，例如 `Read(//**/.env)` 與 `Read(~/.aws/credentials)`。[`deny-rules.sh`](deny-rules.sh) 會依據 [`rules/secret-list.sh`](rules/secret-list.sh) 的同一份清單產生完整規則；加上 `--json` 執行，即可輸出可直接貼入設定的陣列
  - `scripts/link-hook.sh` 建立連結後會執行 [`install.sh`](install.sh)。此腳本僅讀取 `settings.json`，並回報 hook 是否已註冊、缺少哪些建議的 `deny` 規則，以及是否存在以 `**/` 開頭而無法涵蓋工作目錄以外路徑的規則
  - 若需涵蓋工作目錄以外的路徑，樣式必須以 `//**/` 開頭。`Read(**/.env)` 以 session 的工作目錄為基準，實測不會阻擋該目錄以外的檔案
  - `deny` 規則不支援例外，因此不應加入 `*.pem`，以免同時阻擋白名單中的公開憑證。由於 `credentials` 也是一般英文字，規則僅列入 `~/.aws/credentials`
  - 根據[官方文件](https://code.claude.com/docs/en/permissions#read-and-edit)，`Read` 的 `deny` 規則適用於內建讀檔工具、同一路徑上的 `Edit` 與 `Write`（包含建立新檔），以及 Claude Code 可辨識的 Bash 檔案指令（例如 `cat`、`head`、`tail`、`sed`、`tee`）和重新導向目標
  - `Read(//**/.env.*)` 也會阻擋 `.env.example` 等範例檔的寫入。hook 會放行範例檔的寫入，因此兩層規則在此情況下的行為不同
  - `deny` 規則與 hook 均無法辨識未指定檔名的指令（例如在檔案所在目錄執行 `grep -r pattern .`），或由子程序自行開啟檔案的操作（例如 Python 或 Node 腳本）。如需作業系統層級的強制限制，官方建議啟用 [sandbox](https://code.claude.com/docs/en/sandboxing)
  - hook 通常會先於 `deny` 規則拒絕相同的檔名，因此無法從一般操作確認 `deny` 規則是否生效。驗證時可暫時加入僅由 `deny` 層處理的規則（例如：`Read(//**/*.zzprobe)`），再讀取對應的測試檔。預期訊息為「File is in a directory that is denied by your permission settings」。完成驗證後，移除規則與測試檔
