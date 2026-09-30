---
交接状态: PENDING
交接时间: 2026-09-28
交出方: ZCode
接收方: 待定
---

# SkillBridge 项目交接文档

回滚点：`git tag handover-before-20260928-1115`（指向 `8b1bd14`）。这份文档写完只做了一次本地提交，**没有 push**——是否推送到 `origin`（github.com/cg689/SkillBridge）要用户明确同意，本地 `master` 目前领先 `origin/master` 3 个提交。

## 1. 项目是什么

SkillBridge 把 CC Switch 的 skills 目录同步进本机每个已安装 agent 工具的 skills 目录：Windows 上默认建**目录联接（junction）**，不能跟联接的工具（Cursor 的 Cloud Agents）用**拷贝**。它解决的痛点是：技能装在 CC Switch 里，但 Claude Code / Cursor / Gemini / 豆包 / Codex 等工具各认各的目录，手工复制又慢又会过期。

附带一个本地 Web 仪表盘（只绑回环地址、每次启动一个随机 token）：看同步状况、按卡片看每个目标的明细、立即同步、只读地对比 CC Switch 数据库、浏览技能、在页面上增删技能、以及手动触发「扫描本机装了哪些 agent 工具并加进同步列表」。

当前阶段：功能完整、测试全绿、日常由用户手动使用。**没有正在做的功能开发。**

## 2. 技术栈

| 层 | 用什么 | 备注 |
|---|---|---|
| 核心逻辑 | PowerShell 5.1+（`common.psm1` + 各 `*.ps1`） | 无外部依赖，5.1 和 7 都能跑 |
| Unix 变体 | Bash + `python3` | `sync-skills.sh` 的跳过/计数/日志语义必须和 `.ps1` 完全一致 |
| 仪表盘 | 原生 ES5 内联 `<script>` + `TcpListener` 手写 HTTP/1.1 | **没有构建步骤、没有框架、没有 import**；只绑 `127.0.0.1` / `::1` |
| 前端资源 | `assets/vendor/` 里的 Lucide、Motion One、Inter/JetBrains Mono 可变字体 | 全部本地化，不引 CDN |
| 数据校验/DB 对比 | Python 3（`check-db-sync.py`、`tests/test-catalog.py`） | CI 也在用 |
| CI | GitHub Actions（push master / PR） | JSON 校验、目录对比测试、PS 语法检查、三套冒烟、autolink dry-run、scanjs |

## 3. 目录结构

```
common.psm1 (1535 行)      共享模块：配置读写、工具扫描、配置序列化、
                           加和式合并、归属判定、拷贝标记、日志、运行状态、toast
sync-skills.ps1 (291)      Windows 同步主逻辑（幂等，不覆盖已有条目，剪自己拥有的死链）
sync-skills.sh (519)       Unix 同步主逻辑（语义必须与 .ps1 一致）
detect-tools.ps1/.sh       从 supported-tools.json 全量重写 config.json（⚠️ 会丢目标，见第 8 节）
supported-tools.json        工具目录（23 个），唯一事实来源；config.example.json 与
                           「支持的软件列表.md」由 test-catalog.py 对齐校验
web-ui.ps1 (588)           仪表盘服务端：HTTP 路由 + token 门禁（只绑回环）
web-ui.html (2448)         仪表盘页面（ES5 内联脚本，无构建）
check-db-sync.py           对比 skills 目录与 CC Switch 数据库；--fix 删行，只允许手动
install-autolink.ps1/.sh   注册登录自跑计划任务（本机已关闭，见第 9 节）
tests/                     smoke-windows / smoke-webui (1098 行，真的打 HTTP) /
                           smoke-unix / test-catalog / test-check-db-sync
tools/build-skill-catalog.py  生成中文技能清单的辅助脚本
skill-catalog.zh-CN.json   手写的技能中文介绍+分类（叠在每个 SKILL.md 之上）
scanjs.py                  node --check + 未声明调用 + 图标名检查（页面唯一的静态门禁）
*.bat                      同步CCSwitch技能 / 启动WebUI / 同步到仓库并使用
```

文档：`README.md`、`README.zh-CN.md`、`CHANGELOG.md`、`CONTRIBUTING.md`、`SECURITY.md`。

## 4. 已完成的功能

- 双平台同步：junction / copy 两种模式，幂等；已存在的条目一律跳过（工具自己的技能永不被覆盖）
- 死链清理（只删能证明是自己的链接）；相对路径 symlink 的目标解析按链接所在目录解析
- 工具目录 23 个 + `exclude` 排除名单 + `detect-tools` 全量重写 + 仪表盘「扫描工具」**加和式**合并（`POST /api/scan-tools`）
- 仪表盘：同步状况、每目标卡片可展开明细、立即同步、只读数据库检查、15 秒轮询快照、日志尾部
- 技能库：按分类列出源技能、中文介绍叠加在原描述上、搜索/排序/只看未同步全、一键复制清单
- 页面上增删技能：`.zip` 逐条目解压到临时目录再改名（"装好"是一次 rename）、同名绝不覆盖、拒绝 zip-slip/绝对路径/符号链接、删除前确认框写明三件页面上看不到的后果
- 失败可见化：`.skillbridge-status.json` + 通知 toast（登录自跑是隐藏窗口，崩溃必须留痕）
- 仪表盘门禁：只绑回环 + 每次启动随机 token（注入到页面的 `meta[name="sb-token"]`，请求头 `x-sb-token`）

## 5. 进行中 / 未完成

- 无功能在开发中。上一次任务（Codex 和 Doubao 重新加入同步）只改了**机器本地的 `config.json`**（gitignored），仓库无可提交内容。
- 可选的后续（用户未要求）：把豆包 `DoubaoWork\skills` 里指向旧路径的死链清掉（见第 6 节第 2 条）；给 `sync-skills.sh` 补一个和 `.ps1` 等价的扫描路由。

## 6. 已知问题与技术债

1. **这台机器上 CC Switch 源目录正在被别人删技能**（P0，正在发生）。2026-09-28 10:52–10:54，源目录从 133 个子目录掉到 130：`content-research-writer`、`writing-fragments`、`writing-shape` 被直接删除（不进回收站、`_archived` 没动）。元凶指向一个正在运行的 `Doubao.exe` 会话，主窗口标题「判断本机skill删除可行性」。**不是本仓库代码删的**：sync 从不写源目录，且删除都发生在 sync 自己的剪枝跑完之后。当前源目录 123 个可同步技能，三个链接现在是死链，下一次同步会剪掉它们。接手后先看 `Get-Process` 里还有没有 agent 在跑删除类任务。
2. **豆包的链接指向 9/21 之前的旧路径**（P2，已绕过）。`C:\Users\Administrator\DoubaoWork\skills` 里有 170 个旧联接，指向 `%USERPROFILE%\.cc-switch\skills\...`（CC Switch 自己的 junction），其中 45+ 个早已是死链（指向多年前删掉的 `competition-*` 技能）。同步**故意不动它们**——归属判定要求链接目标的前缀就是配置里的 `source`，这些不是；而且"不覆盖已有条目"是硬规矩。副作用：豆包里随源删除而死的链接永远清不掉，要靠用户手动决定。
3. **cc-switch.db 与 skills 目录有漂移**（P2，只报告）。当前 123 个目录 / 127 行，多出来的 `yuanbao` 行的文件夹早就没了。`check_db=true` 时同步会打印这段报告并写进日志，**不改库**。要修只能用户手动 `python check-db-sync.py --fix`（会先备份）。
4. `detect-tools.ps1` / `.sh` 是全量重写：目标工具的标记目录一旦不在，对应目标就悄悄消失。当初想要一个"只加不减"的入口，才有了第 8 节那条决策。
5. 仪表盘页面在**服务启动时一次性读进内存**：改 `web-ui.html` 不重启服务端不生效（这个坑踩过至少两次）。
6. `tests/smoke-webui.ps1` 1098 行，撑住了大部分仪表盘行为；但它自己起服务、自己造夹具源目录，跑之前不需要停用户的 8765 实例。

## 7. 踩过的坑（复现条件 + 规避）

- **PowerShell 5.1 没有三元运算符、没有 `if` 当表达式用**：`$x = if (...) {'a'} else {'b'}` 直接 ParseError。必须先赋值再判断式求值。
- **PowerShell 变量名大小写不敏感**：`$configPath` 和 `$ConfigPath` 是同一个变量，删掉一个名字后另一个照样工作，能悄悄掩盖笔误。写死一个大小写风格。
- **`Get-Content -Raw` 按 ANSI 解码**，含中文的 `config.json` 会变乱码（`同步CCSwitch技能.bat` 变成 `鍚屾��...`）。所以 `Read-ConfigFile` 用 `[IO.File]::ReadAllBytes` + UTF8 解码，写回一律 `UTF8Encoding($false)`（无 BOM）。
- **`ConvertFrom-Json` 对空的 `targets` 块会返回一个名字为 `$null` 的属性**，`[ordered]@{}` 不收 `$null` 键，要先过滤。
- **`[char]0xFEFF` 不能写成 `[char]"`uFEFF"`**；去 BOM 要用字节判断。
- **`Test-Path` 对断掉的 junction 会返回 `$true`**（它不解引用目标）。判断死链必须去测 `$item.Target` 这个路径本身。曾经因此把 170 个联接全数成"活的"。
- **Windows 的 `python` 打不开 Git Bash 的 `/tmp/...` 路径**，要用 `cygpath -w` 或绝对 Windows 路径。
- **Git Bash 里 `powershell -File .\x.ps1` 的反斜杠会被吃掉**，写成 `-File E:/Project/SkillBridge/x.ps1`。
- **IAB/Playwright 表面**：`locator.waitFor({timeout})` 不被接受（报 `unrecognized_keys`），要用 `waitForTimeout` 轮询；单次浏览器操作有 3 秒上限，两次定位失败就该换 `tab.playwright.evaluate(...)` 走 DOM。
- 冒烟日志里有 CR/NUL，`grep` 要加 `-a`。

## 8. 重要设计决策（为什么）

- **「扫描工具」不走 `detect-tools.ps1`，而是进程内的加和式合并 `Merge-SkillBridgeToolTargets`**：detect-tools 会按目录重写整个 `targets` 块，标记目录一没就丢目标，且永远写 `$PSScriptRoot\config.json`。加和式合并只加名字：已有目标的 path/mode 不动，`source`/`exclude`/`autolink`/`check_db`/`$comment` 原样写回，没有可加的就一个字节都不写；重写后回读校验，少了目标就整体回滚。因此 `config.json` 里那段手写注释（迁移历史）能一直活着。
- **归属判定 `Test-OurSkillEntry`**：要么有 `.skillbridge-managed.json` 之类的本方标记，要么链接目标的前缀就是配置里的 `source`（按 `\` 或 `/` 分段比较，防止 `...\skills-backup\demo` 误配成 `...\skills` 的子路径）。这一条是"剪死链不误删用户文件"的全部依据。
- **链接模式下已有条目一律跳过**：工具的 skills 目录里可能有它自己的技能，也可能是别的工具建的链接——不判断、不重指、不删。
- **`check_db` 只报告**：CC Switch 数据库的一行是技能来源（仓库、分支、readme 链接）的唯一索引，重建补不回来。删不删由用户决定。
- **失败必须留痕**：登录自跑是隐藏窗口，静默崩溃等于没有。所以每次同步都写 `.skillbridge-status.json`、失败弹 toast，`detect-tools.ps1` 会把上一次的结果读出来显示。
- **链接优先，copy 只给不能跟联接的工具**（Cursor Cloud Agents 是唯一例子；`Get-TargetSpec` 会把 `.cursor/skills` 自动提升成 copy）。

## 9. 安全红线与不可违反的约定

1. **绝不自动删 `cc-switch.db` 的行。** 只有用户明确要求、由用户自己跑 `python check-db-sync.py --fix`。同步里的对比永远是只报告。
2. **自动同步已彻底关闭**：计划任务「CCSwitch Skills AutoLink」已注销，`config.json` 的 `autolink.enabled=false`。用户明确要求"以后只保持手动"。不要再注册、不要再打开。
3. **不要改 CC Switch 的存储结构。** 9/21 把源路径从 junction 换成物理路径那次切换，正是 CC Switch 开始出问题的转折点。
4. **删源目录里的技能、删目标目录里不能证明归属的条目**，都要先报给用户，不自动做。
5. **同名技能绝不覆盖；会跳出包外的 zip 条目、绝对路径、符号链接一律拒绝。**
6. **提交只留在本地；push 必须用户明确同意。** 目前 `master` 领先 `origin/master` 3 个提交。
7. **`config.json.bak-20260921`（仓库根目录、未跟踪）必须保持未跟踪未提交**，等用户决定去留。
8. **不要在文档、代码、提交信息里写明文 token / 密钥。** 仪表盘 token 每次启动随机，只从运行中的页面 `meta[name="sb-token"]` 读。
9. 只改一个平台时，另一个平台的语义要同步改（`sync-skills.sh` ↔ `.ps1`），并在 CHANGELOG 记录。

## 10. 常用命令

```bash
# 跑测试（改完必须全跑）
python tests/test-catalog.py && python tests/test-check-db-sync.py
python scanjs.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-webui.ps1
bash tests/smoke-unix.sh          # 仅 macOS/Linux

# 手动同步（本机唯一被授权的同步方式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 仪表盘
powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1 -NoBrowser
#   → http://localhost:8765/  （服务启动时读一次 web-ui.html；改页面必须重启）

# 扫描工具（会写 config.json，加和式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1 -ConfigPath .\config.json
```

调用仪表盘 API：从 `http://localhost:8765/` 的 HTML 里取 `meta[name="sb-token"]`，请求头带 `x-sb-token`。路由：`/api/status`、`/api/skills`、`/api/log`、`/api/sync`、`/api/db-check`、`/api/scan-tools`、`/api/skills/add`、`/api/skills/delete`、`/api/stop`。非 POST 一律 405，无 token 一律 403。

## 11. 工具链与持久化配置

- **MCP / 外部服务**：无必需项。CI 只用 GitHub Actions。
- **本地数据**：
  - `config.json`（**gitignored，机器相关**）。当前值：`source = D:\Software\CCSwitch\cc-switch-data\skills`，`exclude = []`，**23 个目标**（`Codex`、`Doubao` 在最后），`link_type = junction`，`check_db = true`，`autolink.enabled = false`。
  - CC Switch 技能源：`D:\Software\CCSwitch\cc-switch-data\skills`（同时可从旧 junction `%USERPROFILE%\.cc-switch\skills` 到达，两者是同一份内容）。
  - CC Switch 数据库：`C:\Users\Administrator\.cc-switch\cc-switch.db`。
  - 日志与状态：`sync-skills.log`、`.skillbridge-status.json`（均 gitignored）。
- **配置备份**：仓库根目录的 `config.json.bak-20260921`（未跟踪，用户决定去留）。

## 12. 🔴 上一份交接文档里失效的条目

**没有上一份——这是本项目第一次交接**，`docs/handover/` 目录也是新的。以下三件事容易被误认为是"还在等做"，其实已经做完，别重复实现：

- ✅ 「扫描本机装了哪些 agent 工具并加进同步列表」：已实现并提交（`8b1bd14`，前端按钮 + `POST /api/scan-tools` + 加和式合并 + 冒烟覆盖）。
- ✅ 「仪表盘 UI 用组件库和动效库重做」：已完成，用的是本地 vendor 的 Lucide + Motion One + 可变字体，不引 CDN。
- ✅ 「删垃圾代码」：已做（`a12c5c2`）。

## 13. 这台机器此刻的状态（快照，可能已变）

- 源目录：130 个子目录，**123 个可同步技能**（本日被外部会话删了 3 个，见第 6 节第 1 条）。
- `C:\Users\Administrator\.codex\skills`：126 个联接 + 它自己的 `.system`（2026-09-28 新建，其中 3 个已因外部删除变死链）。
- `C:\Users\Administrator\DoubaoWork\skills`：170 个旧联接（约 125 活 / 45+ 死），本次同步一条没建、一条没删。
- 其他 21 个目标：各 ~126 条，其中 Cursor 是 copy 模式。
- 仪表盘：**正在运行**，PID 约 12928，端口 8765，`http://localhost:8765/`。要停就用页面上的停止按钮或 `POST /api/stop`。
- 最近一次同步：2026-09-28 10:52，`created=126 pruned=21 skipped=2772 failed=0`；运行状态记为 `warn`（cc-switch.db 漂移，只报告）。

## 14. 给接收方的入职建议顺序

1. 读 `PROJECT_GUIDE.md`（长期规矩）→ 本文档（现状）。
2. `python tests/test-catalog.py && python tests/test-check-db-sync.py && python scanjs.py` 确认环境可用。
3. `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1` 和 `smoke-webui.ps1` 跑一遍（现在应该全绿）。
4. 起仪表盘、打开页面、点一次「扫描工具」（应回报"没有可添加的工具"且一个字节都不写 `config.json`）。
5. 先确认第 6 节第 1 条的外部删除是否还在发生，再决定要不要跑同步。
