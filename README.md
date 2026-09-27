<div align="center">

# SkillBridge

**Sync your CC Switch skills into every AI coding tool — live links, zero copies.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-brightgreen)](.github/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)

[English](README.md) · [中文](README.zh-CN.md)

</div>

---

SkillBridge mirrors the skills in **CC Switch** (`~/.cc-switch/skills`) into **23 AI coding tools** — Claude Code, Cursor, Gemini CLI, Cline, Kilo Code, ZCode, WorkBuddy, Comate, Hermes Agent, TRAE, Cherry Studio, CodeBuddy, AutoClaw, Verdent, Qoder, Doubao, MiniMax, Qwen Office, Grok Bot, Codex, OpenCode and more — using **directory junctions (Windows) / symlinks (Unix)** instead of copies. Skills stay live: edits and removals in CC Switch propagate instantly, and new skills are auto-linked at logon (at boot on Linux).

## Why SkillBridge?

Every AI coding tool maintains its own `skills/` directory. Copying skills around by hand is slow, drifts out of sync, and breaks the moment a tool is reinstalled. SkillBridge makes **CC Switch the single source of truth** and every other tool a live consumer of it:

- **Edits / removals propagate instantly** — a junction is a live reference, not a stale copy.
- **New skills are linked automatically** at logon — at boot on Linux (Windows scheduled task / launchd / cron).
- **Dead links are pruned** — when a skill is deleted, the links it left behind are cleaned up instead of accumulating.
- **CC Switch database drift is reported, never auto-repaired** — a row in `cc-switch.db` is the only record of a skill's origin (repo, branch, readme URL), so the sync reports drift and leaves the decision to you. Off by default (`"check_db": true` enables the report).
- **Failures surface themselves** — the scheduled run is hidden, so every run records its outcome in `.skillbridge-status.json`; a failure also raises a toast, and `detect-tools` replays the last outcome on its next run.
- **Idempotent & safe** — existing entries are never overwritten; a tool's own skills are never touched.
- **Portable** — every path uses environment variables (`%USERPROFILE%`, `%APPDATA%`, `%HERMES_HOME%`), so it runs on any machine as-is.

## Features

- Live sync via junctions / symlinks — no periodic re-copying
- Config-driven targets (`config.json`) — add or drop a tool in one line
- Auto-detection (`detect-tools.ps1` / `detect-tools.sh`) — adapts to whatever is installed on a machine
- Auto-link at logon / boot (`install-autolink.ps1` / `.sh`) with optional interval
- Cross-platform: PowerShell (Windows) and Bash (macOS / Linux)
- Pure scripts, no daemon; Windows needs nothing extra, macOS / Linux need `python3` (for config parsing)

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
chmod +x sync-skills.sh install-autolink.sh detect-tools.sh
./detect-tools.sh         # generate config.json for this machine (or copy config.example.json)
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
   On macOS / Linux: `./detect-tools.sh`. Use `-All` / `--all` to include every supported tool regardless of detection.
4. Double-click `同步CCSwitch技能.bat` (or run `sync-skills.ps1`).
5. Optional: `install-autolink.ps1` for automatic sync at logon.

## Configuration (`config.json`)

> `config.json` is **machine-specific and not committed** (gitignored). Generate it with `detect-tools.ps1` / `detect-tools.sh`, or copy `config.example.json` → `config.json` and edit. The committed template is `config.example.json`; the tool list is defined in `supported-tools.json`.

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

- `source` — the CC Switch skills library (`%USERPROFILE%\.cc-switch\skills` on Windows, `$HOME/.cc-switch/skills` on Unix).
- `targets` — a `name → skills directory` map. A value can be a path string (link) or `{ "path": "...", "mode": "copy" }` for tools that cannot follow junctions (Cursor). A leftover `"Cursor": "path"` string, or any path ending in `/.cursor/skills`, is promoted to copy mode. `%USERPROFILE%`, `%APPDATA%`, `%HERMES_HOME%` (Windows) and `$HOME` (Unix) are expanded automatically. Relative paths like `.cursor/skills` are resolved from the current directory. `detect-tools` keeps extra targets you added that are not in the catalog.
- `exclude` — a **permanent opt-out list** of catalog tool names (spelled exactly as in `supported-tools.json`). A tool listed here is never written to `targets`, and `detect-tools` will not add it back — **not even with `-All` / `--all`**. Use it for a tool you installed but do not want synced, or one you uninstalled whose config directory still lingers. To bring a tool back, remove it from `exclude` and re-run `detect-tools`. Unknown names are ignored with a warning.
- `link_type` — `junction` (Windows, no admin required) or `symlink` (Unix). Used only for `mode: link` targets.

See [支持的软件列表.md](支持的软件列表.md) for the full list of supported tools and their default paths. The catalog file [`supported-tools.json`](supported-tools.json) is the source of truth used by both detect-tools scripts.

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

1. **Junction / Symlink** — `<tool>/skills/<name> → ~/.cc-switch/skills/<name>`. A reference, not a copy: edit once, every tool reads the new version.
2. **Sync script** — scans the source, creates a link in every configured target for each skill that is missing; skips anything that already exists. Links left behind by deleted skills are pruned (reported as `pruned=` in the summary).
3. **Database drift report** — with `"check_db": true` (off by default), the end of every sync compares CC Switch's own skill database (`~/.cc-switch/cc-switch.db`) with the skills folder. CC Switch never rescans the filesystem, so a skill copied in by hand or generated locally is never registered on its own. The sync only **reports**: repairing means deleting rows, and a row is the only record of a skill's origin, so that call is yours — `python check-db-sync.py --fix` (backs the database up first).
4. **Auto-trigger** — Windows Scheduled Task (`install-autolink.ps1`) or launchd/cron (`install-autolink.sh`).

## Repository Layout

```
SkillBridge/
├── 同步CCSwitch技能.bat    # double-click to sync (daily driver)
├── detect-tools.ps1        # auto-detect installed tools -> generate config.json (Windows)
├── detect-tools.sh         # same on macOS / Linux
├── sync-skills.ps1         # Windows sync script (junctions)
├── sync-skills.sh          # Unix sync script (symlinks)
├── check-db-sync.py        # compare/report CC Switch's skill DB (called by sync)
├── install-autolink.ps1    # Windows: register scheduled task
├── install-autolink.sh     # Unix: register launchd / crontab
├── supported-tools.json    # catalog of supported tools (source of truth)
├── .skillbridge-status.json  # last run outcome (written by sync-skills.*); gitignored
├── config.json             # generated per machine (run detect-tools); gitignored
├── config.example.json     # portable env-var based example (all targets)
├── 支持的软件列表.md         # supported tools & paths (中文)
├── tests/                  # smoke tests + catalog / DB-alignment checks
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
Remove it from `targets` **and add its name to `exclude`** (otherwise the next `detect-tools` run adds it straight back), or switch to a copy strategy (`{ "path": "...", "mode": "copy" }`, as Cursor does).

**I removed a tool from `targets`, but `detect-tools` put it back.**
`detect-tools` decides by "does this tool's config directory exist", and an uninstalled tool often leaves that directory behind — so the target comes back. Add the tool name to `exclude` to opt out permanently; `-All` / `--all` will not override it either.

**Does SkillBridge support Cursor?**
Yes. The user-level target is `~/.cursor/skills`, and it uses **copy mode** (real directories, not junctions). Cursor does not follow symlinks when discovering skills or when uploading them via *Sync Skills for Cloud Agents*, so a live link would be invisible in Cloud Agents.

Cloud Agents still run on a separate VM and cannot see your laptop. After SkillBridge copies skills into `~/.cursor/skills`:

1. **Reliable (recommended for cursor.com / Grok Bot):** materialize skills into the **project repo** Cloud Agents check out, then commit and push:

```powershell
# Double-click 同步到仓库给云端用.bat and paste the project path, or:
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-skills.ps1 -CopyInto D:\path\to\your-repo\.cursor\skills
```

```bash
./sync-skills.sh --copy-into /path/to/your-repo/.cursor/skills
```

Then `git add .cursor/skills && git commit && git push`, and start a **new** Cloud Agent on that commit.

2. **Optional / flaky:** turn on **Cursor Settings → Agents → Sync Skills for Cloud Agents**. Even when the toggle is on, agents started from the website or Grok Bot often still have an empty `~/.cursor/skills` on the VM. Prefer the desktop Agents Window if you rely on this path.

Do **not** dump personal skills into the SkillBridge tool repo itself unless you are only testing — put them in the repo you actually work on.

Cursor additionally loads `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills` for compatibility, so if those tools are in `targets` too, the same skill may show up more than once locally — drop the extras you don't want.

**Stale links left behind after deleting a CC Switch skill?**
They are pruned automatically (reported as `pruned=` in the summary). Link-mode targets only remove a reparse point / symlink whose recorded target is gone. Copy-mode targets only remove a directory that has a `.skillbridge-copy` marker (or a leftover link into the CC Switch source). A tool's own skills stay safe even if they were listed in `.skillbridge-managed.json`.

**The script reports `pruned=0` but the folder clearly has broken links?**
Check that the folder is listed in `targets`. Also note that `Test-Path` does not resolve a junction's target — it returns `True` even for a dead one. The script compares the link's recorded `Target` path instead.

**What if a copy is interrupted halfway (power loss, killed process)?**
It cannot leave a dead end. The `.skillbridge-copy` ownership marker is written **before** the files are copied, so the partial directory is still recognised as ours and the next sync re-copies it in full. That run logs a `FAILED` line; the repairing run logs `updated=`.

**Why does the sync no longer repair CC Switch's database by itself?**
Because repairing means deleting rows, and a row is the only record of a skill's origin (repo owner/name/branch, readme URL). When a skill folder merely *moves* — archived into `_archived/`, renamed, or the source pointed at the wrong path — the old automatic repair deleted its row, and re-registering the folder later rebuilds the row with those fields blank. The skill still works, but where it came from is gone for good. Sync runs now **report** drift only (`"check_db": true`), and you decide whether the drift is real.

**Can `check-db-sync.py --fix` wipe the database?**
Not by accident. If the skills folder is empty (wrong `--source`, drive not mounted, folder moved) while the database still has rows, it **refuses** to repair, exits 2 and tells you to check `--source`. Pass `--allow-empty-source` to confirm "yes, I really deleted every skill". Every repair also backs the database up to `~/.cc-switch/backups/` first. Run it by hand — nothing runs it for you any more.

**The scheduled sync keeps failing and I never see it?**
That is what `.skillbridge-status.json` is for. Every run overwrites it with `ok` / `warn` / `fail` plus a timestamp and message; failures also raise a Windows toast (or `notify-send` on Unix desktops), and `detect-tools` prints the last outcome when you run it. `SKILLBRIDGE_NO_NOTIFY=1` silences the toast; the status file is always written.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © SkillBridge contributors
