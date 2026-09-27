<!-- 中文版说明。English README: [README.md](./README.md) -->

# SkillBridge — CC Switch Skill Sync

把 **CC Switch**（`~/.cc-switch/skills`）里的全部 Agent Skill 自动同步到 **23 个**编程工具：Claude Code、Cursor、Gemini CLI、Cline、Kilo Code、ZCode、WorkBuddy、Comate、Hermes Agent、TRAE 等。

同步方式是**目录联接（Windows junction）/ 符号链接（Unix symlink）**，不是拷贝——所以 CC Switch 里对 skill 的**修改和删除会实时反映**到所有工具；新增的 skill 则由"自动补链"（Windows 计划任务 / Unix launchd·cron）在登录/开机时（或按设定的周期）自动接过去。

- 纯脚本，不装守护进程；Windows 零依赖，macOS/Linux 需 `python3`（用于解析配置）
- 幂等：已存在的条目一律跳过，**绝不覆盖**各工具自己的 skill
- 配置化：`config.json` 里自由增删目标工具
- 可移植：所有路径基于环境变量（`%USERPROFILE%` / `%APPDATA%` / `%HERMES_HOME%`），可在任意电脑使用
- 本地仪表盘：`启动WebUI.bat` 把同步状态和技能库搬进浏览器的一个标签页（见 [Web UI](#web-ui)）

## 它解决了什么

- 各 AI 编程工具（Cursor、ZCode、WorkBuddy、Comate、TRAE、Cherry Studio、Hermes 等）各自维护一套 `skills/` 目录，手动拷贝 skill 又慢又容易漂移。
- 本项目让 **CC Switch 成为唯一真源**，其他工具通过"活链接"实时跟随，新增 skill 也无需逐个手动安装。

## 原理（三个部件）

```
┌────────────────────┐        junction/symlink         ┌─────────────────┐
│  CC Switch 技能库    │  ───────────────────────────▶  │ ZCode skills/   │
│  ~/.cc-switch/skills│  每个工具目录里建一个"引用"        ├─────────────────┤
│  （唯一真源）        │                                  │ WorkBuddy skills/│
└────────┬───────────┘                                  ├─────────────────┤
         │ ① 修改/删除 → 实时生效（链接是活的）            │ Comate skills/  │
         │ ② 新增 skill → 需要建一个新链接                 └─────────────────┘
         └──▶ sync-skills 脚本 + 计划任务/launchd（登录/开机时自动补链）
```

1. **Junction / Symlink（活链接）**：`<工具>/skills/<name> → ~/.cc-switch/skills/<name>`。因为是引用而非拷贝，源文件一改，所有工具立刻读到新版。
2. **同步脚本（幂等补链 + 清理死链）**：扫描真源目录，对每个含 `SKILL.md` 的 skill，在配置的每个目标目录里**缺哪个补哪个**链接；已存在的一律跳过。删除 skill 后残留在目标目录的失效链接会被自动清理（见汇总里的 `pruned=`）。
3. **数据库漂移只报告、不自动修**：同步末尾调用 `check-db-sync.py`，对比 CC Switch 自己的技能库（`~/.cc-switch/cc-switch.db`）与技能目录。CC Switch 不会重新扫描文件系统，所以手工拷进来或本地生成的 skill 不会自动登记。但修复意味着删行，而**一行记录是 skill 来源信息（仓库、分支、README 链接）的唯一载体**，移走/归档过的文件夹被"顺手补删"后这些字段无法重建——所以同步只报告，修不修由你决定：日志里看到漂移后手动 `python check-db-sync.py --fix`（会自动先备份数据库）。默认关闭，`"check_db": true` 开启。
4. **自动触发**：
   - Windows：`install-autolink.ps1` 注册计划任务（登录时触发，可选按分钟重复）。
   - macOS/Linux：`install-autolink.sh` 注册 launchd（macOS）或 crontab（Linux，开机时触发）。

## 目录结构

```
SkillBridge/
├── 同步CCSwitch技能.bat    # 双击即同步（日常用法）
├── detect-tools.ps1        # 自动探测本机已装工具并生成 config.json（Windows）
├── detect-tools.sh         # 同上（macOS / Linux）
├── sync-skills.ps1         # Windows 同步脚本（junction）
├── sync-skills.sh          # Unix 同步脚本（symlink）
├── check-db-sync.py        # 对比/报告 CC Switch 技能数据库（同步末尾调用）
├── web-ui.ps1              # 本地仪表盘服务（Windows，仅回环地址）
├── web-ui.html             # 仪表盘页面，由 web-ui.ps1 提供
├── skill-catalog.zh-CN.json   # 仪表盘叠加数据：每个技能的分类与中文介绍
├── tools/                  # 生成 skill-catalog.zh-CN.json 的一次性脚本
├── 启动WebUI.bat           # 双击即打开仪表盘
├── .skillbridge-status.json # 最近一次运行结果（sync-skills.* 写入），不入库
├── install-autolink.ps1    # Windows：注册计划任务
├── install-autolink.sh     # Unix：注册 launchd / crontab
├── supported-tools.json    # 支持的工具目录（detect-tools 的唯一真源）
├── config.json             # 本机生成（detect-tools），不入库
├── config.example.json     # 可移植配置示例（含全部目标）
├── 支持的软件列表.md         # 当前支持的应用与技能目录清单
├── tests/                  # 冒烟测试 + 目录/数据库对齐检查
├── README.md / README.zh-CN.md
├── LICENSE                 # MIT
└── .gitignore
```

## 快速开始（Windows）

**日常用法：直接双击 `同步CCSwitch技能.bat`**，它会立即把 CC Switch 的全部 skill 链接到所有已配置工具。

首次安装（一次性）：

```powershell
# 1. 生成 config.json（首次必做，该文件不入库）：
#    - 运行 detect-tools.ps1 自动探测本机已装工具；或把 config.example.json 复制为 config.json 后编辑

# 2. 手动同步一次（建好当前所有 skill 的链接）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 3.（可选）注册"登录时自动补链"计划任务（-IntervalMinutes 30 开启周期模式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1
```

macOS / Linux：

```bash
chmod +x sync-skills.sh install-autolink.sh detect-tools.sh
./detect-tools.sh           # 为本机生成 config.json（或复制 config.example.json）
./sync-skills.sh            # 手动同步
./install-autolink.sh       # 注册自启（macOS 登录时 / Linux 开机时）
```

## Web UI（本地仪表盘）

仅 Windows（PowerShell）。双击 **`启动WebUI.bat`**：启动服务、自动打开浏览器 `http://localhost:8765/`，用命令行窗口或页面上的 **停止** 按钮关掉它。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1                  # 默认 8765 端口
powershell -NoProfile -ExecutionPolicy Bypass -File .\web-ui.ps1 -Port 9001 -NoBrowser
```

页面给每个已配置目标一张卡片（找到的 skill 数、新建链接、更新拷贝、剪除死链、失败数），外加 `sync-skills.log` 的尾部，和两个动作：**立即同步**（真正跑一遍 `sync-skills.ps1` 并显示汇总）和 **数据库检查**（跑同步里那套**只报告**的 CC Switch 数据库对比，绝不删行）。每张卡片可以展开看该目标的逐条明细。快照每 15 秒自动刷新一次。

标题下面多了一条选项栏，把页面分成两块：左边是**同步状况**（上面这些），右边是**技能列表**。当前打开哪一块记在 URL 的 `#skills` 里，刷新页面、打开书签都会回到同一块。技能清单要把 100 多个 `SKILL.md` 读一遍，所以它是在这一栏第一次被点开时才读取的，也可以用它自己的**重新读取**按钮重读；15 秒轮询刻意不碰它。

**技能库**按分类把源目录里的每个 skill 分组列出，每个 skill 带一句**中文介绍**。分类和中文介绍来自 `skill-catalog.zh-CN.json` 这份手写的数据文件，仪表盘把它叠在每个 `SKILL.md` 之上；技能自己的原描述仍然会保留并显示在中文介绍下方（调暗了），所以某条还没补上中文介绍的技能照样能看，不会从列表里消失。点分类图标可以只看某一类，停在「全部」则可以点分组标题把这一组折起来。搜索时同时匹配名称、中文介绍和原描述；可以按名称 / 覆盖度 / 体积 / 最近修改排序，也可以只看还没同步全的；点开任意一行看文件数、体积、最后修改时间，以及它被哪些目标持有——是链接还是真实副本。（副本模式的虚线图标，表示磁盘上的形态和 `config.json` 里要的形态不一致。）

两个值得知道的设计点：

- **它只听本机。** 套接字只绑定 `127.0.0.1`（以及 `::1`），局域网来的连接在 TCP 层就被拒绝。这也是 `web-ui.ps1` 用裸 `TcpListener` 而不是 `HttpListener` 的原因：HTTP.sys 不管你给什么前缀都会为这个端口开一个**通配符**套接字、自己按 `Host` 头路由，所以局域网上一个发 `Host: localhost:8765` 的客户端会被正常服务——连 token 一起给它。`tests/smoke-webui.ps1` 会断言「连本机局域网 IP 必须被拒」，防止这条悄悄退化。
- **每个 API 调用都带一个本次启动生成的 token**，只写进页面本身。这是防止同一个浏览器里别的网站的 JS 朝仪表盘 POST 一次同步（CSRF）的手段。它证明请求来自你打开的这个页面，而不是来自陌生人——对只监听回环的服务来说正好够用。

## 配置（config.json）

> `config.json` 是**本机专属且不入库**（已加入 .gitignore）。用 `detect-tools.ps1` / `detect-tools.sh` 生成，或把 `config.example.json` 复制为 `config.json` 后自行编辑；入库模板是 `config.example.json`，工具名单以 `supported-tools.json` 为准。

```json
{
  "link_type": "junction",
  "source": "%USERPROFILE%\\.cc-switch\\skills",
  "exclude": [],
  "targets": {
    "Claude Code": "%USERPROFILE%\\.claude\\skills",
    "Cursor":         { "path": "%USERPROFILE%\\.cursor\\skills", "mode": "copy" },
    "ZCode":          "%USERPROFILE%\\.zcode\\skills",
    "WorkBuddy":      "%USERPROFILE%\\.workbuddy\\skills",
    "Comate":         "%USERPROFILE%\\.comate\\skills",
    "Hermes Agent":   "%HERMES_HOME%\\skills",
    "TRAE Work CN":   "%USERPROFILE%\\.trae-cn\\skills",
    "Cherry Studio":  "%APPDATA%\\CherryStudio\\Data\\Skills"
  },
  "autolink": {
    "enabled": true,
    "at_logon": true,
    "interval_minutes": 0
  }
}
```

- `source`：CC Switch 技能库路径。Windows 上默认 `%USERPROFILE%\.cc-switch\skills`，Unix 上默认 `$HOME/.cc-switch/skills`。
- `targets`：`名称 → 技能目录` 的映射。值可以是路径字符串（链接），或 `{ "path": "...", "mode": "copy" }`（拷贝真实文件，给不能跟随 junction 的工具，例如 Cursor）。旧配置里的 `"Cursor": "路径"` 字符串、或路径以 `/.cursor/skills` 结尾的项，会自动升为 copy。`%USERPROFILE%`、`%APPDATA%`、`%HERMES_HOME%`（Windows）/ `$HOME`（Unix）会自动展开。相对路径（如 `.cursor/skills`）相对当前目录解析。`detect-tools` 会保留你加过、但不在目录里的自定义目标。
- `exclude`：**永久排除名单**，写工具名（要跟 `supported-tools.json` 里的名字一致）。列在这里的工具不会出现在 `targets` 里，而且 `detect-tools` **不会再把它加回来 —— 加 `-All` / `--all` 也不会**。适合「这个工具我装了但不想同步」或「工具卸载了但配置目录还在」的情况。想恢复就把名字从 `exclude` 里删掉再跑一次 `detect-tools`。写错的名字会被忽略并在输出里警告。
- `link_type`：`junction`（Windows 目录联接，无需管理员权限）/ `symlink`（Unix）。只作用于 `mode: link` 的目标。

> 提示：如果某工具的技能目录实际路径不同，直接把 `targets` 里对应行的目录改成工具真正读取的位置即可。

## 在其他电脑上使用（适配/迁移）

所有路径都基于**环境变量**（`%USERPROFILE%` / `%APPDATA%` / `%HERMES_HOME%`），不写死任何用户名或盘符，因此可以原样搬到别的电脑：

1. **复制整个 SkillBridge 文件夹**到新电脑（或 `git clone`）。
2. **Hermes Agent**：如果要用，把环境变量 `HERMES_HOME` 设成它的数据目录（该目录下需有 `skills` 文件夹）。
3. **自动探测**：运行 `detect-tools.ps1`（Windows）或 `detect-tools.sh`（macOS / Linux），它会检查本机装了哪些支持的软件，自动生成只含这些软件的 `config.json`（想全部纳入用 `-All` / `--all`）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1
   ```
   ```bash
   ./detect-tools.sh
   ```
4. **同步**：双击 `同步CCSwitch技能.bat`（或运行 `sync-skills.ps1` / `./sync-skills.sh`）。
5. （可选）注册登录自动补链：`install-autolink.ps1` / `install-autolink.sh`。

macOS / Linux 同理：`sync-skills.sh` 会自动把 `%USERPROFILE%` 映射到 `$HOME`、`%APPDATA%` 映射到 `~/.config`。完整名单见 [支持的软件列表.md](支持的软件列表.md)。

## 常见问题

**为什么用链接而不是拷贝？**
链接是"活的"：CC Switch 里改 skill 内容，所有工具下次打开就是新版，不需要重新同步。拷贝则要周期性重跑且容易漂移。缺点（新增 skill 需要补一个链接）由计划任务自动补上。

**新装的工具读不到 skill？**
链接建好后，工具需要**重启会话/界面**才会重新扫描技能目录。

**某工具不认 junction / symlink？**
把该工具从 `targets` 里去掉，**并把它的名字写进 `exclude`**（否则下次跑 `detect-tools` 会被自动加回来），或改用拷贝方案（`{ "path": "...", "mode": "copy" }`，参照 Cursor）。

**我从 `targets` 里删了一个工具，跑 detect-tools 它又回来了？**
`detect-tools` 的判断依据是「这个工具的配置目录在不在」，而卸载后目录往往还留着，于是它被重新加回 `targets`。把工具名写进 `exclude` 即可永久排除——`-All` / `--all` 也不会加回来。

**支持 Cursor 吗？为什么云端项目调用不到本地 skill？**
支持。用户级目标是 `~/.cursor/skills`，并且默认是 **copy 模式**（拷贝真实目录，不是 junction/symlink）。Cursor 发现 skill、以及「Sync Skills for Cloud Agents」上传时都**不会跟随符号链接**，所以活链接在云端等于不存在。

Cloud Agent 跑在独立虚拟机里，看不到你电脑上的 `~/.cc-switch`。SkillBridge 把 skill 拷进 `~/.cursor/skills` 之后还要任选其一：

1. **稳妥（cursor.com / Grok Bot 推荐）：** 把 skill 落到 **Cloud Agent 会 checkout 的那个项目仓库**，再提交并推送：

```powershell
# 双击「同步到仓库给云端用.bat」，粘贴项目路径；或：
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1 -CopyInto D:\path\to\your-repo\.cursor\skills
```

```bash
./sync-skills.sh --copy-into /path/to/your-repo/.cursor/skills
```

然后 `git add .cursor/skills && git commit && git push`，再在该提交上开一个 **新的** Cloud Agent。

2. **可选 / 经常失效：** 打开 **Cursor Settings → Agents → Sync Skills for Cloud Agents**。开关打开后，从网页或 Grok Bot 拉起的云端任务在虚拟机里仍然经常是空的 `~/.cursor/skills`。若坚持走这条路，请从桌面 Agents 窗口启动。

不要把个人 skill 长期提交进 SkillBridge 工具仓库本身（除非只是验证）——放到你真正干活的那个项目仓库里。

Cursor 为兼容还会读取 `~/.claude/skills`、`~/.codex/skills`、`~/.agents/skills`；这些若也在 `targets` 里，本地可能看到重复——不需要的行删掉即可。

**删除 CC Switch 里的 skill 后目标目录残留失效链接？**
脚本会自动清理（汇总里的 `pruned=` 即清理数量）。link 模式只删目标已不存在的重解析点 / 符号链接；copy 模式只删带 `.skillbridge-copy` 标记的目录（或仍指向 CC Switch 源的残留链接）。工具自己的 skill 即使被写进 `.skillbridge-managed.json` 也不会被误删。

**拷贝到一半失败（断电、被中断）会怎样？**
不会留下死结。归属标记 `.skillbridge-copy` 是**先写标记、再拷文件**，所以半截目录仍被认作"我们的"，下一次同步发现内容对不上就会整体重拷。汇总里那次会记一条 `FAILED`，修好后那次记 `updated=`。

**为什么同步不再"顺手"修复 CC Switch 的数据库？**
因为修复就是删行，而一行记录是 skill 来源信息（repo owner/名称/分支、README 链接）的唯一载体。skill 文件夹只是被挪走时——归档进 `_archived/`、改名、或 `--source` 指错——旧的自动修复会把它的行删掉，之后即使重新登记也只能填回空白的来源字段：技能还能用，但它从哪来彻底说不清了。现在同步**只报告**漂移（`"check_db": true`），是否修复由人判断。

**`check-db-sync.py --fix` 会不会把数据库清空？**
不会误清。如果技能目录是空的（路径写错、盘没挂上、目录被挪走）而数据库里还有记录，它会**拒绝修复**并以退出码 2 结束，提示你先检查 `--source`。确实要清空时显式加 `--allow-empty-source`。另外每次修复前都会先备份数据库到 `~/.cc-switch/backups/`。它只由人手动运行——没有任何脚本会自动调用它。

**计划任务老是在失败，但我根本看不到？**
这正是 `.skillbridge-status.json` 的用途。每次运行都会把它覆盖成 `ok` / `warn` / `fail` 外加时间和说明；失败时还会弹一个 Windows 通知（Unix 桌面用 `notify-send`），下次跑 `detect-tools` 也会把最近一次结果打出来。想安静点设 `SKILLBRIDGE_NO_NOTIFY=1`（只关通知，状态文件照写）。

**同步时脚本报 `pruned=0`，但目录里明明有失效链接？**
先确认该目录在 `targets` 里。另外：`Test-Path` 对 junction **不解析目标**，悬空的也返回 `True`，所以不能用它判断——脚本比对的是链接记录的 `Target` 路径。

## License

[MIT](./LICENSE)
