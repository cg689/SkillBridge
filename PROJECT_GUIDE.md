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
| `sync-skills.ps1` / `.sh` | 同步主逻辑。幂等、不覆盖已有条目、只剪自己拥有的死链 |
| `detect-tools.ps1` / `.sh` | 从 `supported-tools.json` **全量重写** config（会丢目标，慎用） |
| `supported-tools.json` | 工具目录，唯一事实来源（23 个） |
| `config.example.json`、`支持的软件列表.md` | 与目录对齐，由 `tests/test-catalog.py` 校验 |
| `web-ui.ps1` / `web-ui.html` | 仪表盘服务端与页面；页面 ES5 内联、无构建 |
| `check-db-sync.py` | skills 目录 ↔ CC Switch 数据库漂移报告；`--fix` 手动删行 |
| `install-autolink.ps1` / `.sh` | 注册登录自跑（本机已关闭，勿启用） |
| `tests/` | `smoke-windows` / `smoke-webui`（打真 HTTP）/ `smoke-unix` / `test-catalog` / `test-check-db-sync` |
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
- 两个平台的同步语义必须一起改（`.sh` ↔ `.ps1`），冒烟要覆盖同一条规则。
- **禁止为了让测试变绿而改断言、降级安全设置或跳过用例。**

## 提交与分支约定

- 分支：`master` 是长期开发分支，`main` 为对外默认分支；PR 走 `origin`。
- commit message：`type(scope): 一句话说明`，type 用 `feat` / `fix` / `docs` / `test` / `chore` / `refactor`；说明写"为什么/做了什么"，不写"更新了文件"。
- 提交只留在本地；**push 必须用户明确同意**。
- 未跟踪的 `config.json.bak-20260921` 不能随手提交。

## 工作约定

- 动手前先说方案与影响面（尤其涉及删、写 `config.json`、动 CC Switch 数据），用户认可再做。
- 每次改动必须附测试结果；有失败要区分"历史遗留"与"本次新引入"。
- 报数前先实测：源目录的技能数、目标数、链接存活情况，都可能在这期间被别人改掉（这台机器上有多个 agent 会话在跑）。
- 新 agent 入职流程见 `HANDOVER.md` 第 14 节；交接完成后把稳定事实回填到本文件，并把 `HANDOVER.md` 归档到 `docs/handover/`。
