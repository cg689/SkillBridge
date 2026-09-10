# SkillBridge — CC Switch Skill Sync

把 **CC Switch**（`~/.cc-switch/skills`）里的全部 Agent Skill 自动同步到 ZCode / WorkBuddy / Comate 等其他编程工具。

同步方式是**目录联接（Windows junction）/ 符号链接（Unix symlink）**，不是拷贝——所以 CC Switch 里对 skill 的**修改和删除会实时反映**到所有工具；新增的 skill 则由"自动补链"（Windows 计划任务 / Unix launchd·cron）在登录时（或按设定的周期）自动接过去。

- 纯脚本，无外部依赖，不装守护进程
- 幂等：已存在的条目一律跳过，**绝不覆盖**各工具自己的 skill
- 配置化：`config.json` 里自由增删目标工具

## 它解决了什么

- 各 AI 编程工具（ZCode、WorkBuddy、Comate、Codex、Claude Code、Gemini 等）各自维护一套 `skills/` 目录，手动拷贝 skill 又慢又容易漂移。
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
         └──▶ sync-skills 脚本 + 计划任务/launchd（登录时自动补链）
```

1. **Junction / Symlink（活链接）**：`<工具>/skills/<name> → ~/.cc-switch/skills/<name>`。因为是引用而非拷贝，源文件一改，所有工具立刻读到新版；删除 skill 时链接失效（无害）。
2. **同步脚本（幂等补链）**：扫描真源目录，对每个含 `SKILL.md` 的 skill，在配置的每个目标目录里**缺哪个补哪个**链接；已存在的一律跳过。
3. **自动触发**：
   - Windows：`install-autolink.ps1` 注册计划任务（登录时触发，可选按分钟重复）。
   - macOS/Linux：`install-autolink.sh` 注册 launchd（macOS）或 crontab（Linux）。

## 目录结构

```
SkillBridge/
├── 同步CCSwitch技能.bat    # 双击即同步（日常用法）
├── sync-skills.ps1        # Windows 同步脚本（junction）
├── sync-skills.sh         # Unix 同步脚本（symlink）
├── install-autolink.ps1   # Windows：注册计划任务
├── install-autolink.sh    # Unix：注册 launchd / crontab
├── config.json            # 目标工具配置（可增删）
├── README.md
├── LICENSE                # MIT
└── .gitignore
```

## 快速开始（Windows）

**日常用法：直接双击 `同步CCSwitch技能.bat`**，它会立即把 CC Switch 的全部 skill 链接到所有已配置工具。

首次安装（一次性）：

```powershell
# 1. 配置：编辑 config.json 里的 targets（增删要同步的工具）

# 2. 手动同步一次（建好当前所有 skill 的链接）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 3.（可选）注册"登录时自动补链"计划任务（-IntervalMinutes 30 开启周期模式）
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1
```

macOS / Linux：

```bash
chmod +x sync-skills.sh install-autolink.sh
./sync-skills.sh            # 手动同步
./install-autolink.sh       # 注册登录自启
```

## 配置（config.json）

```json
{
  "link_type": "junction",
  "source": "%USERPROFILE%\\.cc-switch\\skills",
  "targets": {
    "ZCode":          "%USERPROFILE%\\.zcode\\skills",
    "WorkBuddy":      "%USERPROFILE%\\.workbuddy\\skills",
    "WorkBuddy AI":   "%USERPROFILE%\\.workbuddy-ai\\skills",
    "Comate":         "%USERPROFILE%\\.comate\\skills",
    "TRAE Work CN":   "%USERPROFILE%\\.trae-cn\\skills",
    "Cherry Studio":  "%APPDATA%\\CherryStudio\\Data\\Skills",
    "CodeBuddy CN":   "%USERPROFILE%\\.codebuddycn\\skills",
    "DeepSeek Harness": "%USERPROFILE%\\.agents\\skills",
    "AutoClaw":       "%USERPROFILE%\\.openclaw-autoclaw\\skills",
    "Verdent":        "%USERPROFILE%\\.verdent\\skills",
    "Coze":           "%USERPROFILE%\\.coze\\skills",
    "Qoder CN":       "%USERPROFILE%\\.qoder-cn\\skills",
    "Doubao":         "%USERPROFILE%\\DoubaoWork\\skills",
    "MiniMax Code":   "%USERPROFILE%\\.minimax\\skills",
    "Qwen Office":    "%USERPROFILE%\\.qwenworkcn\\skills",
    "Grok Bot":       "%USERPROFILE%\\.grok\\skills"
  },
  "autolink": {
    "enabled": true,
    "at_logon": true,
    "interval_minutes": 0
  }
}
```

- `source`：CC Switch 技能库路径。Windows 上默认 `%USERPROFILE%\.cc-switch\skills`，Unix 上默认 `$HOME/.cc-switch/skills`。
- `targets`：`名称 → 技能目录` 的映射。想接入新工具，在这里加一行即可；`%USERPROFILE%`、`%APPDATA%`（Windows）/ `$HOME`（Unix）会被自动展开。
- `link_type`：`junction`（Windows 目录联接，无需管理员权限）/ `symlink`（Unix）。

> 提示：如果某工具的技能目录实际路径不同，直接把 `targets` 里对应行的目录改成工具真正读取的位置即可。

## 常见问题

**为什么用链接而不是拷贝？**
链接是"活的"：CC Switch 里改 skill 内容，所有工具下次打开就是新版，不需要重新同步。拷贝则要周期性重跑且容易漂移。缺点（新增 skill 需要补一个链接）由计划任务自动补上。

**新装的工具读不到 skill？**
链接建好后，工具需要**重启会话/界面**才会重新扫描技能目录。

**某工具不认 junction / symlink？**
把该工具从 `targets` 里去掉，或用拷贝方案（自行把 `New-Item -ItemType Junction` 换成 `Copy-Item -Recurse`）。

**删除 CC Switch 里的 skill 后目标目录残留失效链接？**
无害；脚本默认不清理，避免误删工具自己的东西。如需清理可手动删掉对应目录。

## License

[MIT](./LICENSE)
