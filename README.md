<div align="center">

# SkillBridge

**Sync your CC Switch skills into every AI coding tool — live links, zero copies.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-brightgreen)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)

[English](README.md) · [中文](README.zh-CN.md)

</div>

---

SkillBridge mirrors the skills in **CC Switch** (`~/.cc-switch/skills`) into **16 AI coding tools** — ZCode, WorkBuddy, Comate, Hermes Agent, TRAE, Cherry Studio, CodeBuddy, AutoClaw, Verdent, Qoder, Doubao, MiniMax, Qwen Office, Grok Bot and more — using **directory junctions (Windows) / symlinks (Unix)** instead of copies. Skills stay live: edits and removals in CC Switch propagate instantly, and new skills are auto-linked at logon (at boot on Linux).

## Why SkillBridge?

Every AI coding tool maintains its own `skills/` directory. Copying skills around by hand is slow, drifts out of sync, and breaks the moment a tool is reinstalled. SkillBridge makes **CC Switch the single source of truth** and every other tool a live consumer of it:

- **Edits / removals propagate instantly** — a junction is a live reference, not a stale copy.
- **New skills are linked automatically** at logon — at boot on Linux (Windows scheduled task / launchd / cron).
- **Idempotent & safe** — existing entries are never overwritten; a tool's own skills are never touched.
- **Portable** — every path uses environment variables (`%USERPROFILE%`, `%APPDATA%`, `%HERMES_HOME%`), so it runs on any machine as-is.

## Features

- Live sync via junctions / symlinks — no periodic re-copying
- Config-driven targets (`config.json`) — add or drop a tool in one line
- Auto-detection (`detect-tools.ps1`) — adapts to whatever is installed on a machine
- Auto-link at logon / boot (`install-autolink.ps1` / `.sh`) with optional interval
- Cross-platform: PowerShell (Windows) and Bash (macOS / Linux)
- Pure scripts, no external dependencies, no daemon

## Quick Start (Windows)

**Daily use:** double-click **`同步CCSwitch技能.bat`** — it links every CC Switch skill into all configured tools immediately.

One-time setup:

```powershell
# 1. Generate config.json for THIS machine — required on first run (it is not committed)
powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1

# 2. Sync once
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1

# 3. Optional: auto-link new skills at logon (-IntervalMinutes 30 for periodic)
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autolink.ps1
```

macOS / Linux:

```bash
chmod +x sync-skills.sh install-autolink.sh
./sync-skills.sh          # sync once
./install-autolink.sh     # register auto-link (macOS: at login / Linux: at boot)
```

## Installation on a New Machine

1. Clone or copy the repository.
2. If you use **Hermes Agent**, set the `HERMES_HOME` environment variable to its data directory (containing a `skills` folder).
3. Auto-detect installed tools and generate a matching `config.json`:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\detect-tools.ps1
   ```
   (Use `-All` to include every supported tool regardless of detection.)
4. Double-click `同步CCSwitch技能.bat` (or run `sync-skills.ps1`).
5. Optional: `install-autolink.ps1` for automatic sync at logon.

## Configuration (`config.json`)

> `config.json` is **machine-specific and not committed** (gitignored). Generate it with `detect-tools.ps1`, or copy `config.example.json` → `config.json` and edit. The committed template is `config.example.json`.

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

- `source` — the CC Switch skills library (`%USERPROFILE%\.cc-switch\skills` on Windows, `$HOME/.cc-switch/skills` on Unix).
- `targets` — a `name → skills directory` map. Add a tool in one line; `%USERPROFILE%`, `%APPDATA%`, `%HERMES_HOME%` (Windows) and `$HOME` (Unix) are expanded automatically.
- `link_type` — `junction` (Windows, no admin required) or `symlink` (Unix).

See [支持的软件列表.md](支持的软件列表.md) for the full list of supported tools and their default paths.

## How It Works

```
┌────────────────────┐        junction/symlink         ┌─────────────────┐
│  CC Switch skills  │  ───────────────────────────▶  │ ZCode skills/   │
│  ~/.cc-switch/skills│  one live reference per tool    ├─────────────────┤
│  (single source)   │                                 │ WorkBuddy skills/│
└────────┬───────────┘                                 ├─────────────────┤
         │ ① edits/removals propagate instantly         │ Comate skills/  │
         │ ② new skills need one new link               └─────────────────┘
         └──▶ sync-skills script + task/launchd (auto-link at logon / boot)
```

1. **Junction / Symlink** — `<tool>/skills/<name> → ~/.cc-switch/skills/<name>`. A reference, not a copy: edit once, every tool reads the new version; deleting a skill leaves a harmless dangling link.
2. **Sync script** — scans the source, creates a link in every configured target for each skill that is missing; skips anything that already exists.
3. **Auto-trigger** — Windows Scheduled Task (`install-autolink.ps1`) or launchd/cron (`install-autolink.sh`).

## Repository Layout

```
SkillBridge/
├── 同步CCSwitch技能.bat    # double-click to sync (daily driver)
├── detect-tools.ps1        # auto-detect installed tools -> generate config.json
├── sync-skills.ps1         # Windows sync script (junctions)
├── sync-skills.sh          # Unix sync script (symlinks)
├── install-autolink.ps1    # Windows: register scheduled task
├── install-autolink.sh     # Unix: register launchd / crontab
├── config.json             # generated per machine (run detect-tools.ps1); gitignored
├── config.example.json     # portable env-var based example
├── 支持的软件列表.md         # supported tools & paths (中文)
├── .github/workflows/      # CI
├── README.md / README.zh-CN.md
└── LICENSE                 # MIT
```

## FAQ

**Why links instead of copies?**
Links are live: change a skill in CC Switch and every tool reads the new version on next open. Copies require periodic re-runs and drift. The one downside (a new skill needs a new link) is handled automatically by the scheduled task.

**A tool doesn't see the new skills?**
Tools re-scan their skills directory on session/UI restart — restart the tool.

**A tool doesn't follow junctions / symlinks?**
Remove it from `targets`, or switch to a copy strategy (replace `New-Item -ItemType Junction` with `Copy-Item -Recurse`).

**Stale links left behind after deleting a CC Switch skill?**
Harmless. The script intentionally never cleans up, to avoid deleting a tool's own entries. Remove leftover directories manually if you like.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © SkillBridge contributors
