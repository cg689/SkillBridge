# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Cursor (`%USERPROFILE%\.cursor\skills`) as a first-class target. 23 targets
  in total. Cursor uses **copy mode** (real directories): Cloud Agents and
  Cursor's own skill discovery do not follow junctions/symlinks, so a live
  link in `~/.cursor/skills` is invisible remotely.
- Per-target `"mode": "copy"` (`{ "path": "...", "mode": "copy" }`) plus
  `sync-skills.ps1 -CopyInto` / `sync-skills.sh --copy-into` to materialize
  skills into a repo's `.cursor/skills` for Cloud Agent checkouts.
- Managed-copy bookkeeping (`.skillbridge-managed.json`) so refreshes and
  deletes never touch a tool's own skills.
- `detect-tools.sh`: Unix counterpart of `detect-tools.ps1`.
- `supported-tools.json`: single catalog for detect-tools (both platforms)
  and `config.example.json`, with a CI check that the lists cannot drift.
- Smoke coverage for dead-link pruning, underscore-prefixed archive folders,
  tool names in the Unix log, and `check-db-sync.py` (temp SQLite DB).

### Changed
- `config.example.json` now lists every supported target, not a subset.
- `支持的软件列表.md` uses portable env-var paths instead of a machine-specific
  `C:\Users\Administrator\...` inventory.

### Fixed
- Windows copy-mode bookkeeping: `Write-ManagedSkills` took `IEnumerable`,
  so PowerShell split a HashSet into individual characters and later
  refreshes treated our copies as foreign (skipped, never updated).
- Unix sync log used `basename` of the skills directory, so every line said
  `created  skills : ...` instead of the tool name.
- Sync scripts now skip `_`-prefixed source folders (archives), matching
  `check-db-sync.py`.
- Unix dead-link pruning compares `readlink` of the symlink, aligning with
  the Windows "recorded Target" check.
- Changelog and security-policy links pointed at the `your-name/SkillBridge`
  placeholder.

## [1.1.0] - 2026-09-13

### Added
- `Codex` (`%USERPROFILE%\.codex\skills`) and `OpenCode`
  (`%USERPROFILE%\.config\opencode\skills`) targets — the two CC Switch
  destinations that were not covered yet.
- `check-db-sync.py`: keeps CC Switch's own skill database
  (`~/.cc-switch/cc-switch.db`) in step with the skills folder. Skills that
  arrive by copying a folder, or by being generated locally, are never
  registered by CC Switch itself; this closes that gap. Runs automatically at
  the end of every sync unless `check_db` is `false` in `config.json`.
- Dead-link pruning: links whose target was deleted from the source are removed
  from every target directory (reported as `pruned=` in the summary).

### Fixed
- Removing a broken junction/symlink now goes through
  `[System.IO.Directory]::Delete` instead of `Remove-Item`. Shells that wrap
  `Remove-Item` in a safe-delete helper fail closed on such links, because
  trashing one cannot resolve its missing target.

## [1.0.0] - 2026-09-10

### Added
- Sync CC Switch skills into agent tools via **directory junctions** (Windows)
  and **symlinks** (Unix).
- `sync-skills.ps1` / `sync-skills.sh`: idempotent link-sync; never overwrites
  a tool's own skills.
- `同步CCSwitch技能.bat`: double-click to sync (daily driver).
- `detect-tools.ps1`: auto-detect installed tools and generate `config.json`
  for the current machine.
- `config.json` / `config.example.json`: env-var based, portable configuration
  (`%USERPROFILE%`, `%APPDATA%`, `%HERMES_HOME%`).
- `install-autolink.ps1` / `install-autolink.sh`: register auto-link at logon
  (Windows Scheduled Task / launchd / crontab), with optional interval.
- GitHub-standard repository layout: `CHANGELOG.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue templates, CI workflow.
- Bilingual documentation (`README.md` / `README.zh-CN.md`) and
  `支持的软件列表.md` (supported tools list).

[Unreleased]: https://github.com/cg689/SkillBridge/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/cg689/SkillBridge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/cg689/SkillBridge/releases/tag/v1.0.0
