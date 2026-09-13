# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub-standard repository layout: `CHANGELOG.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue templates, CI workflow.
- `Codex` (`%USERPROFILE%\.codex\skills`) and `OpenCode`
  (`%USERPROFILE%\.config\opencode\skills`) targets — the two CC Switch
  destinations that were not covered yet (22 targets in total).
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
- 20 supported target tools out of the box.
- Bilingual documentation (`README.md` / `README.zh-CN.md`) and
  `支持的软件列表.md` (supported tools list).

[Unreleased]: https://github.com/your-name/SkillBridge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/your-name/SkillBridge/releases/tag/v1.0.0
