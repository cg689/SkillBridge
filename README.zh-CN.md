<!-- 中文版说明。English README: [README.md](./README.md) -->

# SkillBridge — CC Switch Skill Sync

把 **CC Switch**（`~/.cc-switch/skills`）里的全部 Agent Skill 自动同步到 Claude Code / Gemini CLI / Cline / Kilo Code / ZCode / WorkBuddy / Comate / Hermes Agent / TRAE 等其他编程工具。

同步方式是**目录联接（Windows junction）/ 符号链接（Unix symlink）**，不是拷贝——所以 CC Switch 里对 skill 的**修改和删除会实时反映**到所有工具；新增的 skill 则由"自动补链"（Windows 计划任务 / Unix launchd·cron）在登录/开机时（或按设定的周期）自动接过去。

- 纯脚本，不装守护进程；Windows 零依赖，macOS/Linux 需 `python3`（用于解析配置）
- 幂等：已存在的条目一律跳过，**绝不覆盖**各工具自己的 skill
- 配置化：`config.json` 里自由增删目标工具
- 可移植：所有路径基于环境变量（`%USERPROFILE%` / `%APPDATA%` / `%HERMES_HOME%`），可在任意电脑使用

## 它解决了什么

- 各 AI 编程工具（ZCode、WorkBuddy、Comate、TRAE、Cherry Studio、Hermes 等）各自维护一套 `skills/` 目录，手动拷贝 skill 又慢又容易漂移。
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
3. **数据库对齐**：同步末尾调用 `check-db-sync.py`，把 CC Switch 自己的技能库（`~/.cc-switch/cc-switch.db`）与技能目录对齐。CC Switch 不会重新扫描文件系统，所以手工拷进来或本地生成的 skill 不会自动登记——这一步负责补上。可在 `config.json` 里用 `"check_db": false` 关闭。
4. **自动触发**：
   - Windows：`install-autolink.ps1` 注册计划任务（登录时触发，可选按分钟重复）。
   - macOS/Linux：`install-autolink.sh` 注册 launchd（macOS）或 crontab（Linux，开机时触发）。

## 目录结构

```
SkillBridge/
├── 同步CCSwitch技能.bat    # 双击即同步（日常用法）
├── detect-tools.ps1        # 自动探测本机已装工具并生成 config.json（适配新电脑）
├── sync-skills.ps1         # Windows 同步脚本（junction）
├── sync-skills.sh          # Unix 同步脚本（symlink）
├── check-db-sync.py        # 对齐 CC Switch 技能数据库（同步末尾自动调用）
├── install-autolink.ps1    # Windows：注册计划任务
├── install-autolink.sh     # Unix：注册 launchd / crontab
├── config.json             # 本机生成（detect-tools.ps1），不入库
├── config.example.json     # 可移植配置示例（基于环境变量）
├── 支持的软件列表.md         # 当前支持的应用与技能目录清单
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
chmod +x sync-skills.sh install-autolink.sh
./sync-skills.sh            # 手动同步
./install-autolink.sh       # 注册自启（macOS 登录时 / Linux 开机时）
```

## 配置（config.json）

> `config.json` 是**本机专属且不入库**（已加入 .gitignore）。用 `detect-tools.ps1` 生成，或把 `config.example.json` 复制为 `config.json` 后自行编辑；入库模板是 `config.example.json`。

```json
{
  "link_type": "junction",
  "source": "%USERPROFILE%\\.cc-switch\\skills",
  "targets": {
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
- `targets`：`名称 → 技能目录` 的映射。想接入新工具，在这里加一行即可；`%USERPROFILE%`、`%APPDATA%`、`%HERMES_HOME%`（Windows）/ `$HOME`（Unix）会被自动展开。
- `link_type`：`junction`（Windows 目录联接，无需管理员权限）/ `symlink`（Unix）。

> 提示：如果某工具的技能目录实际路径不同，直接把 `targets` 里对应行的目录改成工具真正读取的位置即可。

## 在其他电脑上使用（适配/迁移）

所有路径都基于**环境变量**（`%USERPROFILE%` / `%APPDATA%` / `%HERMES_HOME%`），不写死任何用户名或盘符，因此可以原样搬到别的电脑：

1. **复制整个 SkillBridge 文件夹**到新电脑（或 `git clone`）。
2. **Hermes Agent**：如果要用，把环境变量 `HERMES_HOME` 设成它的数据目录（该目录下需有 `skills` 文件夹）。
3. **自动探测**：运行 `detect-tools.ps1`，它会检查本机装了哪些支持的软件，自动生成只含这些软件的 `config.json`（想全部纳入用 `-All` 参数）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1
   ```
4. **同步**：双击 `同步CCSwitch技能.bat`（或运行 `sync-skills.ps1`）。
5. （可选）注册登录自动补链：`install-autolink.ps1`。

macOS / Linux 同理：`sync-skills.sh` 会自动把 `%USERPROFILE%` 映射到 `$HOME`、`%APPDATA%` 映射到 `~/.config`。

## 常见问题

**为什么用链接而不是拷贝？**
链接是"活的"：CC Switch 里改 skill 内容，所有工具下次打开就是新版，不需要重新同步。拷贝则要周期性重跑且容易漂移。缺点（新增 skill 需要补一个链接）由计划任务自动补上。

**新装的工具读不到 skill？**
链接建好后，工具需要**重启会话/界面**才会重新扫描技能目录。

**某工具不认 junction / symlink？**
把该工具从 `targets` 里去掉，或用拷贝方案（自行把 `New-Item -ItemType Junction` 换成 `Copy-Item -Recurse`）。

**删除 CC Switch 里的 skill 后目标目录残留失效链接？**
脚本会自动清理（汇总里的 `pruned=` 即清理数量）。判定依据是链接记录的目标路径已不存在；非链接的真实目录一律不动，所以工具自己装的 skill 不会被误删。

**同步时脚本报 `pruned=0`，但目录里明明有失效链接？**
先确认该目录在 `targets` 里。另外：`Test-Path` 对 junction **不解析目标**，悬空的也返回 `True`，所以不能用它判断——脚本比对的是链接记录的 `Target` 路径。

## License

[MIT](./LICENSE)
