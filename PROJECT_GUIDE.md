# 项目说明书（所有 agent 必读）

> 这份文件是**长期有效的干活规矩**。项目"现在怎么样"看根目录 [`HANDOVER.md`](HANDOVER.md)。
> 交接完成后新沉淀的稳定事实请回填到本文件，HANDOVER.md 则应归档到 `docs/handover/`。

## 项目简介

SkillBridge：把 CC Switch 的 skills 目录同步进本机各 agent 工具的 skills 目录（Windows 默认目录联接 junction，不能跟联接的工具用拷贝），配一个只绑回环的本地 Web 仪表盘做监控与手工管理。

## 安全红线（不可违反）

1. **绝不自动删 `cc-switch.db` 的行。** 数据库一行是技能来源的唯一索引。同步里的对比永远只报告；`--fix` 只由用户手动执行。
2. **自动同步已彻底关闭**：计划任务已注销，`autolink.enabled=false`。用户要求"以后只保持手动"——不要再注册任务、不要再打开自跑。
3. **不要改 CC Switch 的存储结构**（源路径 junction/物理路径的切换、`cc-switch.db` 结构）。9/21 那次切换是 CC Switch 出问题的转折点。
4. **删东西前先报**：删源目录里的技能、删目标目录里无法证明归属的条目、清空任何目录，都要先说明再动手。
5. **同名技能绝不覆盖**；zip 条目会跳出包外、绝对路径、符号链接一律拒绝。
6. **不写明文密钥 / token / 私网 IP**。仪表盘 token 每次启动随机，只在运行时从页面读。
7. **提交只留在本地；push 必须用户明确同意。**

## 目录结构

| 路径 | 职责 |
|---|---|
| `common.psm1` | 共享模块：配置读写（UTF-8 无 BOM）、工具扫描、配置序列化、加和式合并 `Merge-SkillBridgeToolTargets`、归属判定 `Test-OurSkillEntry`、拷贝标记、日志、运行状态、toast |
| `sync-skills.ps1` / `.sh` | 同步主逻辑。幂等、不覆盖已有条目、只剪自己拥有的死链。归属看链接**最终落在哪**（逐段跟完 junction/符号链接再和源目录比），不是看它字面写成什么样 |
| `detect-tools.ps1` / `.sh` | 从 `supported-tools.json` **全量重写** config（会丢目标，慎用） |
| `supported-tools.json` | 工具目录，唯一事实来源（23 个） |
| `config.example.json`、`支持的软件列表.md` | 与目录对齐，由 `tests/test-catalog.py` 校验 |
| `web-ui.ps1` / `web-ui.html` | 仪表盘服务端与页面；页面 ES5 内联、无构建 |
| `check-db-sync.py` | skills 目录 ↔ CC Switch 数据库漂移报告；`--fix` 手动删行 |
| `install-autolink.ps1` / `.sh` | 注册登录自跑（本机已关闭，勿启用） |
| `install-webui.ps1` | 注册/注销仪表盘登录自启计划任务（`SkillBridge Web UI`；`-DryRun` 预览、`-Unregister` 注销）。只自启仪表盘，与同步无关 |
| `tests/` | `smoke-windows` / `smoke-webui`（打真 HTTP）/ `smoke-unix` / `test-catalog` / `test-check-db-sync` / `mutate-restyle`（变异验证新断言，自带基线对照） |
| `scanjs.py` | 对页面内联脚本做 `node --check`、未声明调用、图标名检查 |
| `skill-catalog.zh-CN.json` | 手写的技能中文介绍与分类 |

## 依赖与环境

- Windows：PowerShell 5.1+（任意版本），无外部模块。
- macOS / Linux：Bash + `python3`。
- Python 3：目录测试、DB 对比、`scanjs.py`。
- Node 18+：仅 `scanjs.py` 需要（在 PATH 上）。
- 无包管理器、无 `node_modules`、无 CDN 依赖。

## 工具链配置

- CI：GitHub Actions（`.github/workflows/ci.yml`），push `master` 与 PR 触发。
- 无必需 MCP / 外部服务。
- 本地数据：`config.json`（gitignored，机器相关）、CC Switch 数据库 `~/.cc-switch/cc-switch.db`、`sync-skills.log`、`.skillbridge-status.json`。

## 开机自启（与自动同步是两回事）

- 已注册计划任务 **`SkillBridge Web UI`**：登录时以隐藏窗口启动 `web-ui.ps1 -NoBrowser`，随时可开 `http://localhost:8765/`。注册/注销：`powershell -NoProfile -ExecutionPolicy Bypass -File .\install-webui.ps1`（`-Port 9001` 换端口、`-DryRun` 预览、`-Unregister` 注销）。
- 这只是**仪表盘常驻**，不等于自动同步：`sync-skills.ps1` 依然只手动触发，`CCSwitch Skills AutoLink` 任务保持注销、`autolink.enabled=false`（见安全红线第 2 条）。别把这两个任务混在一起，也别为了"仪表盘自启"去改 autolink。
- 若仪表盘已手动在跑（如 `启动WebUI.bat`），自启任务启动时端口被占会退出并报错，属预期行为，不影响手动实例。
- 无执行时限：任务不会因 72 小时默认时限被悄悄杀掉；已设异常退出自动重启（1 分钟后，最多 3 次）——`web-ui.ps1` 被 Ctrl+C 打断等异常死亡会自愈，而页面停止按钮/`POST /api/stop` 的干净退出码为 0，不会触发重启。

## 常用命令

```bash
# 测试（改完必须全跑）
python tests/test-catalog.py && python tests/test-check-db-sync.py
python scanjs.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-webui.ps1
bash tests/smoke-unix.sh          # 仅 Unix

# 同步（只手动）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 仪表盘（改 web-ui.html 后必须重启才生效）
powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1 -NoBrowser
```

## 测试约定

- 任何行为改动都要落到 `tests/smoke-windows.ps1` 或 `tests/smoke-webui.ps1` 的真实断言里（后者会自己起服务、造夹具源目录，跑之前不用停用户的实例）。
- 新工具进 `supported-tools.json` 时，`config.example.json` 和 `支持的软件列表.md` 必须同步，否则 `test-catalog.py` 失败。
- 页面 JS 有改：跑 `python scanjs.py`（`node --check` + 未声明调用 + 图标名）。
- 页面结构断言要能真的失败：改完拿改动前的判断标准反向验一次（比如把拦截分支挪个顺序，看断言是否报错），别写出恒真的 `-match '.'`。
- 反向验证的机器化：`python tests/mutate-restyle.py`。它把页面按十种方式改坏，期望新增的断言每次都以**它自己抛的消息**失败，并把页面按字节还原。它自带基线对照——未变异的页面必须先跑通才继续，否则退出 2 并说明"在此之上谈命中毫无意义"；判定只认新断言的消息而不认任何 `FAIL:`，否则服务没起来（端口被占、node 缺失）会被读成十个命中。断言的消息改了，这里会响亮失败而不是悄悄匹配不到。
- **别让服务端往 stdout 写长行**：`smoke-webui.ps1` 用 `RedirectStandardOutput` 把 web-ui.ps1 的输出接进管道，而 PowerShell 不会提前读它。管道缓冲区只有几 KB，一旦写满，单线程的服务端就阻塞在写日志上，此后的每个请求都要等客户端 180 秒超时（症状是 HTTP -1，服务端却毫发无损）。所以批量操作打日志只打计数和前几个名字。
- 两个平台的同步语义必须一起改（`.sh` ↔ `.ps1`），冒烟要覆盖同一条规则。
- **归属看"落点"不看"拼写"**：链接字面写的路径可以早就失效（CC Switch 的仓库从 C: 搬到 D:，`~/.cc-switch/skills` 里遗留的旧拼写链接依然通过中间 junction 落在源目录里）。先按字面前缀比，比不赢再把两边都跟完联接解析一次（`Get-ResolvedPath` / `resolves_into`）。只看字面会把源目录和自己的链接判成两家，症状就是某目标显示 `0/123, 缺 123, 死链 N` 而里面躺着一整排能用的链接。真实目录仍然是工具自己的，链接解析到源目录外面的一律不是我们的。
- `smoke-unix.sh` 在 Windows 的 Git Bash 里要这样才跑得动（Linux 上直接跑）。**脚本是按 `python3` 这个名字找解释器的**，而这台机器真正的 Python（`D:\Software\python`）只装 `python.exe` 和 `python3.dll`，没有 `python3.exe`，PATH 上第一个 `python3` 是 WindowsApps 的假存根（退出 49）。所以"PATH 前挂一个真 python"是**不够的**——必须让 `python3` 这个名字解析到真解释器：

  ```bash
  # 建一次垫片（把真 python.exe 连同它旁边的三个 DLL 复制过去，改名 python3.exe）
  SHIM=/c/Users/Administrator/AppData/Local/SkillBridgeSmoke/bin
  cp /d/Software/python/python.exe "$SHIM/python3.exe"
  cp /d/Software/python/python3.dll /d/Software/python/python313.dll \
     /d/Software/python/vcruntime140*.dll "$SHIM/"
  # 跑
  PATH="$SHIM:$PATH" MSYS=winsymlinks:nativestrict \
    TMPDIR=/c/Users/Administrator/AppData/Local/SkillBridgeSmoke \
    bash tests/smoke-unix.sh
  ```

  垫片必须复制 DLL，不能写成 `exec .../python.exe "$@"` 的包装脚本：包一层 shell 就丢掉 MSYS 的路径转换，Windows Python 读不到 Git Bash 的 `/c/...` 路径。`TMPDIR` 不能用会被 MSYS 重映射的 Windows 临时目录（会被另看成 `/tmp`，符号链接往返后拼写对不上），也不能用 `/tmp`（本机有外部进程在清它）；`MSYS=winsymlinks:nativestrict` 去掉的话 `ln -s` 会悄悄退化成复制目录。`detect-tools` 那段会读仓库里真实的 `config.json`（本机是 Windows 设置 `junction`），所以**最后一条断言在本机必然失败**（`detect-tools.sh should default link_type=symlink, got 'junction'`），与脚本无关。
- **禁止为了让测试变绿而改断言、降级安全设置或跳过用例。**

## 提交与分支约定

- 分支：`master` 是长期开发分支，`main` 为对外默认分支；PR 走 `origin`。
- commit message：`type(scope): 一句话说明`，type 用 `feat` / `fix` / `docs` / `test` / `chore` / `refactor`；说明写"为什么/做了什么"，不写"更新了文件"。
- 提交只留在本地；**push 必须用户明确同意**。
- `config.json.bak-20260921` 已于 2026-09-30 前后不在工作树（用户自删，未提交也未入库）。本机 `config.json` 仍由 `.gitignore` 挡住；若以后又出现同名备份，同样不提交、等用户决定去留。

## 工作约定

- 动手前先说方案与影响面（尤其涉及删、写 `config.json`、动 CC Switch 数据），用户认可再做。
- 每次改动必须附测试结果；有失败要区分"历史遗留"与"本次新引入"。
- 报数前先实测：源目录的技能数、目标数、链接存活情况，都可能在这期间被别人改掉（这台机器上有多个 agent 会话在跑）。
- 新 agent 入职流程见 `HANDOVER.md` 第 14 节；交接完成后把稳定事实回填到本文件，并把 `HANDOVER.md` 归档到 `docs/handover/`。
