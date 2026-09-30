---
交接状态: PENDING
交接时间: 2026-09-30
交出方: ZCode
接收方: 待定
---

# SkillBridge 项目交接文档

回滚点：`git tag handover-before-202609301057`（指向本次文档写入前的 `git status` 干净状态）。
上一份交接文档已归档到 [`docs/handover/HANDOVER_20260928_ZCode_to_pending.md`](docs/handover/HANDOVER_20260928_ZCode_to_pending.md)，
**没有 push**——本地 `master` 目前领先 `origin/master` 15 个提交，是否推送要用户明确同意。

> 本项目的长期规矩看 [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md)，那份不随交接过期；本文档只写"现在怎么样"。

## 1. 项目是什么

SkillBridge 把 CC Switch 的 skills 目录同步进本机每个已安装 agent 工具的 skills 目录：Windows 上默认建**目录联接（junction）**，不能跟联接的工具（Cursor 的 Cloud Agents）用**拷贝**。它解决的痛点是：技能装在 CC Switch 里，但 Claude Code / Cursor / Gemini / 豆包 / Codex 等工具各认各的目录，手工复制又慢又会过期。

附带一个本地 Web 仪表盘（只绑回环地址、每次启动一个随机 token）：看同步状况、按卡片看每个目标的明细、立即同步、只读地对比 CC Switch 数据库、浏览技能、在页面上增删技能、批量勾选删除、以及手动触发「扫描本机装了哪些 agent 工具并加进同步列表」。

当前阶段：功能完整、测试全绿、日常由用户手动使用。**没有正在做的功能开发。**

## 2. 技术栈

| 层 | 用什么 | 备注 |
|---|---|---|
| 核心逻辑 | PowerShell 5.1+（`common.psm1` + 各 `*.ps1`） | 无外部依赖，5.1 和 7 都能跑 |
| Unix 变体 | Bash + `python3`（`sync-skills.sh`） | 的跳过/计数/日志语义必须和 `.ps1` 完全一致 |
| 仪表盘 | 原生 **ES5** 内联 `<script>` + `TcpListener` 手写 HTTP/1.1 | **没有构建步骤、没有框架、没有 import**；只绑 `127.0.0.1` / `::1` |
| 前端资源 | `assets/vendor/` 里的 Lucide、Motion One、Inter/JetBrains Mono 可变字体 | 全部本地化，不引 CDN |
| 数据校验/DB 对比 | Python 3（`check-db-sync.py`、`tests/test-catalog.py`） | CI 也在用 |
| CI | GitHub Actions（push master / PR） | JSON 校验、目录对比测试、PS 语法检查、三套冒烟、autolink dry-run、scanjs |

## 3. 目录结构

```
common.psm1 (1685)        共享模块：配置读写、工具扫描、配置序列化、加和式合并、
                          归属判定、拷贝标记、日志、运行状态、toast
sync-skills.ps1 (291)     Windows 同步主逻辑（幂等，不覆盖已有条目，剪自己拥有的死链）
sync-skills.sh (550)      Unix 同步主逻辑（语义必须与 .ps1 一致）
detect-tools.ps1/.sh      从 supported-tools.json 全量重写 config.json（⚠️ 会丢目标，见第 8 节）
supported-tools.json       工具目录（23 个），唯一事实来源；config.example.json 与
                           「支持的软件列表.md」由 test-catalog.py 对齐校验
web-ui.ps1 (656)          仪表盘服务端：HTTP 路由 + token 门禁（只绑回环）
web-ui.html (3050)        仪表盘页面（ES5 内联脚本，无构建）
check-db-sync.py           skills 目录 ↔ CC Switch 数据库漂移报告；--fix 删行，只允许手动
install-webui.ps1         注册/注销仪表盘登录自启计划任务（SkillBridge Web UI）；
                           -Port 换端口、-DryRun 预览、-Unregister 注销。只自启仪表盘，与同步无关
tests/                    smoke-windows / smoke-webui (1452 行，真的打 HTTP) / smoke-unix /
                           test-catalog / test-check-db-sync / mutate-restyle (167 行，变异验证)
scanjs.py                 node --check + 未声明调用 + 图标名检查（页面唯一的静态门禁）
*.bat                     同步CCSwitch技能 / 启动WebUI / 同步到仓库并使用
docs/handover/            历史交接文档归档
```

文档：`README.md`、`README.zh-CN.md`、`CHANGELOG.md`、`CONTRIBUTING.md`、`SECURITY.md`。

## 4. 已完成的功能

- 双平台同步：junction / copy 两种模式，幂等；已存在的条目一律跳过（工具自己的技能永不被覆盖）
- 死链清理（只删能证明是自己的链接）；相对路径 symlink 的目标解析按链接所在目录解析
- 工具目录 23 个 + `exclude` 排除名单 + `detect-tools` 全量重写 + 仪表盘「扫描工具」**加和式**合并（`POST /api/scan-tools`）
- 归属判定按链接**最终落点**比较（跟完中间联接再和源目录比），修掉了仓库搬家后的假 `0/123, 缺 123`
- 仪表盘：同步状况、每目标卡片可展开明细、立即同步、只读数据库检查、15 秒轮询快照、日志尾部
- 技能库：按分类列出源技能、中文介绍叠加在原描述上、搜索/排序/只看未同步全、一键复制清单
- 页面上增删技能：`.zip` 逐条目解压到临时目录再改名（"装好"是一次 rename）、同名绝不覆盖、拒绝 zip-slip/绝对路径/符号链接、删除前确认框写明三件页面上看不到的后果
- **批量勾选删除**：Shift 范围选择按屏幕上真实渲染的行取范围、选中数实时播报给读屏软件、半批失败后用失败的名字与原因重装对话框、选中条会计出被当前筛选藏住的项
- 失败可见化：`.skillbridge-status.json` + 通知 toast（登录自跑是隐藏窗口，崩溃必须留痕）
- 仪表盘门禁：只绑回环 + 每次启动随机 token（注入到页面的 `meta[name="sb-token"]`，请求头 `x-sb-token`）
- 仪表盘登录自启：计划任务 **SkillBridge Web UI**（`install-webui.ps1` 注册/注销，异常退出 1 分钟后自动重启最多 3 次，页面停止按钮的干净退出码 0 不触发重启）
- **整套界面按 shadcn/ui 重做**（视觉参考，非依赖）：36 px 按钮/3 px 焦点环、40 px 表头吸顶并带滚动投影、356 px toast 带倒计时条、双主题共用同一组 52 个令牌名。这套改动的断言由 `tests/mutate-restyle.py` 做变异验证（十种破坏方式全部被捕获）

## 5. 进行中 / 未完成

- **无功能在开发中。** 上一份交接后可选的后续仍有两件没做，都不紧急：
  1. 给 `sync-skills.sh` 补一个和 `.ps1` 等价的「扫描工具」路由（`web-ui.ps1` 只有 Windows 版，Unix 上目前没有）。
  2. 豆包 `DoubaoWork\skills` 里指向 9/21 之前旧路径的历史死链（见第 6 节第 2 条，已绕过，是否清理要用户决定）。

## 6. 已知问题与技术债

1. **`cc-switch.db` 与 skills 目录有大面积漂移**（P2，只报告）。当前 **19 个文件夹 / 122 行**，多出来的 **103 行**的文件夹早就没了（`python check-db-sync.py` 能列出完整名单）。这是**用户手动精简源目录的结果，不是 bug**：2026-09-28 前后用户把源技能从 122 个删到 33 个，9/30 又到 19 个。要修只能用户手动 `python check-db-sync.py --fix`（会先备份）——**不要替用户跑 `--fix`**。
2. **豆包的链接指向 9/21 之前的旧路径**（P2，已绕过）。历史上有 170 个旧联接，其中 45+ 指向多年前删掉的 `competition-*` 技能。同步**故意不动它们**——归属判定要求链接最终落进配置里的 `source`，这些不是；而且"不覆盖已有条目"是硬规矩。副作用：豆包里随源删除而死的链接永远清不掉，要靠用户手动决定。（2026-09-30 实测：`.codex` / `.claude` / `DoubaoWork` 各 19 条链接，**全部可解析，0 死链**——说明最近一次同步已经把随源删除而死的链接剪干净了，剩下的旧拼写链接仍然靠中间联接落在真实源目录里。）
3. **源目录 `~/.cc-switch/skills` 的字面目标已失效**（P3，符合预期）。这个链接的字面 target 是 `C:\Software\CCSwitch\cc-switch-data\skills`，而 `C:\Software` 这个路径在本机已不存在；真正的内容在 `D:\Software\CCSwitch\cc-switch-data\skills`。**读这个链接仍然拿得到全部 26 个目录**（走的是中间联接）。这正是 `PROJECT_GUIDE.md` 里"归属看落点不看拼写"和提交 `b1ee54a` 存在的理由。**不要去"修"这个拼写**——它归 CC Switch 管。
4. `detect-tools.ps1` / `.sh` 是全量重写：目标工具的标记目录一旦不在，对应目标就悄悄消失。当初想要一个"只加不减"的入口，才有了第 8 节那条决策。
5. 仪表盘页面在**服务启动时一次性读进内存**：改 `web-ui.html` 不重启服务端不生效（这个坑踩过至少两次）。
6. `tests/smoke-webui.ps1` 1452 行，撑住了大部分仪表盘行为；它自己起服务、自己造夹具源目录，跑之前不需要停用户的 8765 实例。
7. **本机跑 `smoke-unix.sh` 需要三步环境设置**，否则第一步就失败（详见 `PROJECT_GUIDE.md` 测试约定）。唯一必然失败的那条断言是 `detect-tools.sh should default link_type=symlink, got 'junction'`——它读仓库里真实的 `config.json`，而本机是 Windows 设置，与脚本无关。

## 7. 踩过的坑（复现条件 + 规避）

- **PowerShell 5.1 没有三元运算符、没有 `if` 当表达式用**：`$x = if (...) {'a'} else {'b'}` 直接 ParseError。必须先赋值再判断式求值。
- **PowerShell 变量名大小写不敏感**：`$configPath` 和 `$ConfigPath` 是同一个变量，删掉一个名字后另一个照样工作，能悄悄掩盖笔误。写死一个大小写风格。
- **`Get-Content -Raw` 按 ANSI 解码**，含中文的 `config.json` 会变乱码（`同步CCSwitch技能.bat` 变成乱码）。所以 `Read-ConfigFile` 用 `[IO.File]::ReadAllBytes` + UTF8 解码，写回一律 `UTF8Encoding($false)`（无 BOM）。
- **`ConvertFrom-Json` 对空的 `targets` 块会返回一个名字为 `$null` 的属性**，`[ordered]@{}` 不收 `$null` 键，要先过滤。
- **`[char]0xFEFF` 不能写成 `[char]"`uFEFF"`**；去 BOM 要用字节判断。
- **`Test-Path` 对断掉的 junction 会返回 `$true`**（它不解引用目标）。判断死链必须去测 `$item.Target` 这个路径本身。曾经因此把 170 个联接全数成"活的"。
- **`Test-Path -LiteralPath` 对"C:\ 下不存在的路径"返回 `False`，但那不等于链接坏了**：`~/.cc-switch/skills` 就是字面目标不存在、内容照样读得到的例子。判断链接可用性要 `Get-ChildItem` 真的列一次。
- **Windows 的 `python` 打不开 Git Bash 的 `/tmp/...` 路径**，要用 `cygpath -w` 或绝对 Windows 路径。
- **Git Bash 里 `powershell -File .\x.ps1` 的反斜杠会被吃掉**，写成 `-File E:/Project/SkillBridge/x.ps1`。
- **脚本按 `python3` 这个名字找解释器**：`sync-skills.sh` 直接调 `python3`，而本机真 Python（`D:\Software\python`）只装 `python.exe` + `python3.dll`，没有 `python3.exe`；PATH 第一个 `python3` 是 WindowsApps 假存根（退出 49）。造垫片必须复制 DLL，不能写 shell 包装（会丢 MSYS 路径转换）。
- **IAB/Playwright 表面**：`locator.waitFor({timeout})` 不被接受（报 `unrecognized_keys`），要用 `waitForTimeout` 轮询；单次浏览器操作有 3 秒上限，两次定位失败就该换 `tab.playwright.evaluate(...)` 走 DOM。
- **IAB 浏览器里 `locator.click()` 必超时**（rAF 被节流，实测等一个 `requestAnimationFrame` 能挂 32 秒）。元素可见、命中测试都正常，就是点不动。要用 `tab.playwright.evaluate(() => el.click())`；截图只能用 `tab.screenshot()`；滚动和主题切换后的事件要再等 2-3 秒才到。
- 冒烟日志里有 CR/NUL，`grep` 要加 `-a`。

## 8. 重要设计决策（为什么）

- **「扫描工具」不走 `detect-tools.ps1`，而是进程内的加和式合并 `Merge-SkillBridgeToolTargets`**：detect-tools 会按目录重写整个 `targets` 块，标记目录一没就丢目标，且永远写 `$PSScriptRoot\config.json`。加和式合并只加名字：已有目标的 path/mode 不动，`source`/`exclude`/`autolink`/`check_db`/`$comment` 原样写回，没有可加的就一个字节都不写；重写后回读校验，少了目标就整体回滚。因此 `config.json` 里那段手写注释（迁移历史）能一直活着。
- **归属判定 `Test-OurSkillEntry`**：要么有 `.skillbridge-managed.json` 之类的本方标记，要么链接**最终落点**在配置里的 `source` 之内（按落点比，不是按字面前缀）。这一条是"剪死链不误删用户文件"的全部依据，也是仓库搬家后不出假 `0/123` 的原因（`b1ee54a`）。
- **链接模式下已有条目一律跳过**：工具的 skills 目录里可能有它自己的技能，也可能是别的工具建的链接——不判断、不重指、不删。
- **`check_db` 只报告**：CC Switch 数据库的一行是技能来源（仓库、分支、readme 链接）的唯一索引，重建补不回来。删不删由用户决定。
- **失败必须留痕**：登录自跑是隐藏窗口，静默崩溃等于没有。所以每次同步都写 `.skillbridge-status.json`、失败弹 toast，`detect-tools.ps1` 会把上一次的结果读出来显示。
- **链接优先，copy 只给不能跟联接的工具**（Cursor Cloud Agents 是唯一例子；`Get-TargetSpec` 会把 `.cursor/skills` 自动提升成 copy）。
- **UI 重构用 shadcn/ui 当"设计参考"而不是依赖**：本页没有构建、没有 CDN、没有网络，所以尺寸/圆角/间距/动效是照 shadcn 组件定义读出来直接写进样式表的；shadcn 里用 `oklch()` 写的颜色一律转 hex，否则老版本 Edge 上整个页面没有颜色。落地后用一个可检不变式锁住：两个主题块必须回答**同一组 52 个令牌名**。
- **变异测试代替"人肉反向验证"**：`tests/mutate-restyle.py` 把页面按十种方式改坏，期望新增断言每次都以它自己抛的消息失败。它自带基线对照（未变异页先跑通才继续）且只认新断言的消息，否则"服务没起来"会被读成十个命中。

## 9. 安全红线与不可违反的约定

1. **绝不自动删 `cc-switch.db` 的行。** 只有用户明确要求、由用户自己跑 `python check-db-sync.py --fix`。同步里的对比永远是只报告。当前漂移很大（103 行），但**不要**主动修。
2. **自动同步已彻底关闭**：计划任务「CCSwitch Skills AutoLink」已注销且本机不存在，`config.json` 的 `autolink.enabled = false`。用户明确要求"以后只保持手动"。不要再注册、不要再打开。（注意 `autolink.at_logon` 仍是 `true`——任务不在，所以不会自跑，但**不要**据此认为可以重新注册。）
3. **不要改 CC Switch 的存储结构。** 9/21 把源路径从 junction 换成物理路径那次切换，正是 CC Switch 开始出问题的转折点。同理：不要"修" `~/.cc-switch/skills` 那个失效的字面拼写。
4. **删源目录里的技能、删目标目录里不能证明归属的条目**，都要先报给用户，不自动做。**源目录从 122 → 33 → 19 全部是用户自己的主动精简，别再当事故调查。**
5. **同名技能绝不覆盖；会跳出包外的 zip 条目、绝对路径、符号链接一律拒绝。**
6. **提交只留在本地；push 必须用户明确同意。** 目前 `master` 领先 `origin/master` **15 个提交**。
7. `config.json.bak-20260921` 已不在工作树（用户自删，未提交也未入库）。若以后再出现同名备份，同样不提交、等用户决定去留。
8. **不要在文档、代码、提交信息里写明文 token / 密钥。** 仪表盘 token 每次启动随机，只从运行中的页面 `meta[name="sb-token"]` 读。
9. 只改一个平台时，另一个平台的语义要同步改（`sync-skills.sh` ↔ `.ps1`），并在 CHANGELOG 记录。
10. **禁止为了让测试变绿而改断言、降级安全设置或跳过用例。**

## 10. 常用命令

```bash
# 跑测试（改完必须全跑）
python tests/test-catalog.py && python tests/test-check-db-sync.py
python scanjs.py
python tests/mutate-restyle.py                        # 变异验证新断言（自带基线对照）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-webui.ps1
bash tests/smoke-unix.sh          # 仅 Unix；本机需三步环境设置，见 PROJECT_GUIDE

# 手动同步（本机唯一被授权的同步方式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 仪表盘
powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1 -NoBrowser
#   → http://localhost:8765/  （服务启动时读一次 web-ui.html；改页面必须重启）

# 扫描工具（会写 config.json，加和式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1 -ConfigPath .\config.json

# 数据库漂移（只报告）
python check-db-sync.py
```

调用仪表盘 API：从 `http://localhost:8765/` 的 HTML 里取 `meta[name="sb-token"]`，请求头带 `x-sb-token`。路由：`/api/status`、`/api/skills`、`/api/log`、`/api/sync`、`/api/db-check`、`/api/scan-tools`、`/api/skills/add`、`/api/skills/delete`、`/api/stop`。非 POST 一律 405，无 token 一律 403。

## 11. 工具链与持久化配置

- **MCP / 外部服务**：无必需项。CI 只用 GitHub Actions。
- **本地数据**：
  - `config.json`（**gitignored，机器相关**）。当前值：`source = D:\Software\CCSwitch\cc-switch-data\skills`，`exclude = []`，**23 个目标**，`link_type = junction`，`check_db = true`，`autolink.enabled = false`（`at_logon` 仍为 `true`，见第 9 节第 2 条）。
  - CC Switch 技能源：`D:\Software\CCSwitch\cc-switch-data\skills`（同时可从旧链接 `~/.cc-switch/skills` 到达，字面拼写已失效但内容相同，见第 6 节第 3 条）。
  - CC Switch 数据库：`~/.cc-switch/cc-switch.db`。
  - 日志与状态：`sync-skills.log`、`.skillbridge-status.json`（均 gitignored）。
- **`python3` 垫片**：本机跑 `smoke-unix.sh` / `sync-skills.sh` 需要它，位置 `C:\Users\Administrator\AppData\Local\SkillBridgeSmoke\bin\python3.exe`（真 `python.exe` + 三个 DLL 的副本）。重建命令见 `PROJECT_GUIDE.md` 测试约定。
- **这台机器上有多个 agent 会话在跑**。报任何数字前先实测，别引用本文档的快照。

## 12. 上一份里已经失效的条目（对照 `docs/handover/HANDOVER_20260928_ZCode_to_pending.md`）

这是全篇性价比最高的一节。上一份之后本仓库有 **11 个提交**，其中 10 个是新增能力（见下表）。逐条对照上一份的「进行中 / 已知问题」：

- ❌ **「这台机器上 CC Switch 源目录正在被别人删技能」（上一份的 P0，"元凶指向 Doubao.exe 会话，窗口标题『判断本机skill删除可行性』」）——整条作废。** 那些删除是**用户自己的主动精简**，2026-09-28 122→33 是人工清理。别再立案侦查、别再取证、别再等一个不存在的攻击者。
- ❌ **「豆包里有 170 个旧联接 / 45+ 死链」——数字作废。** 2026-09-30 实测 `.codex` / `.claude` / `DoubaoWork` 各 19 条链接、全部可解析、0 死链。上一份「同步故意不动它们」的**设计依据仍然有效**，但"有一大堆死链"这个现状已经不成立。
- ⚠️ **「cc-switch.db 与 skills 目录有漂移（以前是 127 行 / 123 个目录）」——仍然有效，而且更严重**：现在是 19 个文件夹 / 122 行，103 行待删。处理方式不变（只报告，`--fix` 用户手动）。
- ⚠️ **「页面在服务启动时一次性读进内存」——仍然有效**，未改。
- ⚠️ **「detect-tools 是全量重写」——仍然有效**，设计约束未变。
- ❌ **「`config.json.bak-20260921` 必须保持未跟踪」——整条作废**，文件已不在工作树。
- ❌ **「本地 master 领先 origin 3 个提交」——数字作废**，现在是 **14 个**。
- ❌ **上一份第 13 节「这台机器此刻的状态」整节作废**，换成下面第 13 节。
- ✅ 上一份第 12 节标 ✅ 的三件事（扫描工具、UI 重做、删垃圾代码）本身没错，但**「UI 重做」已经被再一次重做超过**：见下面新增能力里的 shadcn 重做。接收方不要以为 UI 这块已经完结到不用再动。
- 📌 上一份第 5 节「可选的后续」两条**仍然没做**：给 `sync-skills.sh` 补扫描路由（仍然没有）；豆包旧死链清理（已随同步自然变干净大半，见第 6 节第 2 条）。

**上一份之后新增的能力**（按提交顺序，共 11 个提交）：

| 提交 | 加了什么 |
|---|---|
| `c3ae2eb` | 上一份 HANDOVER.md + PROJECT_GUIDE.md |
| `ca85f84` | 仪表盘登录自启计划任务 `SkillBridge Web UI`（`install-webui.ps1`） |
| `80507d8` | 仪表盘任务异常退出后自动重启（1 分钟，最多 3 次） |
| `11b2921` | 卡片明细里点名哪些拷贝已经过期 |
| `054fa05` | 页面自己的 favicon / 品牌图标 |
| `b1ee54a` | **归属判定改为按链接最终落点比较**，修掉仓库搬家后的假 `0/123, 缺 123` |
| `d700173` | 批量勾选 + 一次确认批量删除 |
| `3e45f12` | 多选删除的四处交互缺陷修复（label 冒泡、Shift 按渲染行取范围、读屏播报、半批失败重试） |
| `a57ddac` | **整套界面按 shadcn/ui 重做**（含表头吸顶、双主题 52 令牌一致、`.th-mod` 响应式） |
| `50b4b94` | 变异脚本 `mutate-restyle.py` 的基线对照与判定口径收紧 |
| `ba13910` | CHANGELOG 三处与实现不符的陈述纠正 |

## 13. 这台机器此刻的状态（快照 2026-09-30，可能已变）

- **源目录：26 个子目录，其中 19 个是技能**（有 `SKILL.md`）。**这 19 个全部同时存在于 `C:\Users\Administrator\.zcode\skills` 和 `C:\Users\Administrator\.agents\skills`** —— 也就是说，被同步的"源"其实就是这台机器自己的 agent 技能库镜像（agent-handover、code-review-mattpocock、computer-use、deai-core、deai-guard、dogfood、ensp-topo-generate、grbj-ensp-smart-config、guizang-social-card-skill、human-writing、ian-xiaohei-illustrations、impeccable、infographic-maker、last30days、latex-thesis-zh、paper-download-proxy、parallel-large-download、ui-ux-pro-max、yuwen-publish-precheck）。另外 7 个目录不是技能：`burp-mcp-full`、`docs`、`examples`、`kali`、`reports`、`scripts`、`_archived`。**在页面上增删技能等于改这份镜像，会传播到所有目标工具**——同理，删之前必须报用户。
- **目标目录**：抽查 `.codex` / `.claude` / `DoubaoWork` 各 **19 条链接，全部可解析，0 死链**；另有部分目标（`.qwen`、`.iflow`）条目更多（27 条），含工具自己的技能。
- **cc-switch.db**：122 行，对应 19 个文件夹 → **103 行待删**，`python check-db-sync.py` 可列名单。**`--fix` 只由用户手动跑。**
- **`~/.cc-switch/skills`**：字面 target `C:\Software\CCSwitch\cc-switch-data\skills` 已不存在（`C:\Software` 整个路径不存在），但仍读得出 26 个目录。
- **最近一次同步**：2026-09-30 10:25:01，`.skillbridge-status.json` 记 `status: warn`，原因只有 cc-switch.db 漂移。
- **仪表盘：当前【没有】在运行。** 8765 无监听、无 `web-ui.ps1` 进程。计划任务 `SkillBridge Web UI` 状态 `Ready`，但 `LastRunTime = 2026-09-30 00:09:09`、`LastTaskResult = 3221225786`（`STATUS_CONTROL_C_EXIT`，即被 Ctrl+C / 关窗口打断），此后再没有登录事件所以没重启。**接收方如果看到浏览器开着 `http://localhost:8765/#skills`，那是一个已经死掉的页面**——要么起服务（`web-ui.ps1 -NoBrowser` 或重新登录触发计划任务），要么明确告诉用户当前没有服务。
- **本地领先 origin/master 15 个提交，未推送。**
- 回滚点：`handover-before-202609301057`（本次）、`handover-before-20260928-1115`（上一份）、`v1.0.0`。

## 14. 给接收方的入职建议顺序

1. 读 `PROJECT_GUIDE.md`（长期规矩）→ 本文档（现状），**第 12 节务必逐条看**，别在作废的 P0 上白费时间。
2. 确认门禁可用：`python tests/test-catalog.py && python tests/test-check-db-sync.py && python scanjs.py`。
3. 跑 `python tests/mutate-restyle.py`（自带基线对照，应该 10/10 CAUGHT、页面字节还原）、`tests/smoke-webui.ps1`、`tests/smoke-windows.ps1`。`smoke-unix.sh` 本机需要三步环境设置，且最后一条断言必然失败（见 `PROJECT_GUIDE.md`）。
4. **先问用户仪表盘要不要现在起来**（当前没在跑，且用户浏览器正开在一个死掉的地址上），再决定动不动它。
5. 动手前照 `PROJECT_GUIDE.md` 的"工作约定"说方案与影响面；涉及删、写 `config.json`、动 CC Switch 数据的三类事必须先报。
6. 任何行为改动都要落到真实断言里，并用 `mutate-restyle.py` 反向验证。
