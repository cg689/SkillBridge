# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Failure is no longer silent. Every run overwrites `.skillbridge-status.json`
  with `ok` / `warn` / `fail`, a timestamp and a message; `fail` / `warn` also
  raise a Windows toast (`notify-send` on Unix desktops), and `detect-tools`
  replays the last outcome on its next run. Both scripts trap an unhandled
  crash — previously a hidden scheduled task could die leaving nothing but a
  process exit code — and early config / source errors record themselves the
  same way. `SKILLBRIDGE_NO_NOTIFY=1` silences the toast; the status file is
  always written.
- `exclude` array in `config.json`: a permanent per-tool opt-out. A catalog tool
  listed there is never written to `targets`, and `detect-tools` will not add it
  back — not even with `-All` / `--all`. Unknown names are dropped with a warning.
- `同步到仓库给云端用.bat`: one-click `-CopyInto` into a project repo's
  `.cursor/skills` (path argument, drag-and-drop, or prompt). Documents that
  *Sync Skills for Cloud Agents* often leaves website / Grok Bot VMs with an
  empty `~/.cursor/skills`, so committing project-level skills is the reliable path.
- Cursor (`%USERPROFILE%\.cursor\skills`) as a first-class target. 23 targets
  in total. Cursor uses **copy mode** (real directories): Cloud Agents and
  Cursor's own skill discovery do not follow junctions/symlinks, so a live
  link in `~/.cursor/skills` is invisible remotely.
- Per-target `"mode": "copy"` (`{ "path": "...", "mode": "copy" }`) plus
  `sync-skills.ps1 -CopyInto` / `sync-skills.sh --copy-into` to materialize
  skills into a repo's `.cursor/skills` for Cloud Agent checkouts.
- Per-skill `.skillbridge-copy` marker so copy-mode ownership does not depend
  on `.skillbridge-managed.json` (that file is only an index).
- Managed-copy bookkeeping (`.skillbridge-managed.json`) so refreshes and
  deletes never touch a tool's own skills.
- `detect-tools.sh`: Unix counterpart of `detect-tools.ps1`.
- `supported-tools.json`: single catalog for detect-tools (both platforms)
  and `config.example.json`, with a CI check that the lists cannot drift.
- Smoke coverage for dead-link pruning, underscore-prefixed archive folders,
  tool names in the Unix log, and `check-db-sync.py` (temp SQLite DB).
- CI: the Windows smoke suite also runs under Windows PowerShell 5.1 (the shell
  the .bat launchers and the scheduled task actually use), not just pwsh 7.

### Changed
- `check-db-sync.py` is **report-only** when run from a sync, and `check_db`
  now defaults to `false`. A row in `cc-switch.db` is the only record of a
  skill's origin (repo owner/name/branch, readme URL); when a folder merely
  moved — archived into `_archived/`, renamed, or a wrong `--source` — the old
  automatic `--fix` deleted the row, and re-registering the folder later comes
  back with those fields blank. Removing a row is a judgement call about CC
  Switch's own data, so it is manual now: sync reports the drift, you read the
  list, you run `python check-db-sync.py --fix` (it backs the DB up first and
  spells out what the deletes cost). The empty-source refusal from 09-23 stays.
- Copy refresh fingerprints every regular file except the marker (sorted by
  relative path), so a `scripts/`-only edit is picked up.
- Unix copy mode copies file-by-file and skips symlinks, matching Windows.
- Link-mode dead-link pruning on Windows uses the reparse-point attribute when
  `LinkType` is empty.
- `detect-tools` keeps extra targets that are not in `supported-tools.json`.
- `config.example.json` now lists every supported target, not a subset.
- `支持的软件列表.md` uses portable env-var paths instead of a machine-specific
  `C:\Users\Administrator\...` inventory.
- `支持的软件列表.md` now answers "where does each agent actually store its
  data": every target row carries its **data root directory** next to the skills
  directory, plus a status column (`已同步` / `已排除`). Added the locations
  SkillBridge does not cover yet (Qoder international, Pi, OpenClaw, AdaL,
  Claude Desktop) and a section on built-in skill directories that must not be
  confused with user skills (Cursor `.cursor/skills-cursor/`, MiniMax
  `.minimax/.builtin-skills/`). All 21 synced paths were verified on 2026-09-23
  against app-side evidence (usage records, shipped docs/config, the app's own
  skill folders) or official documentation; the evidence types are documented in
  the file itself.

### Fixed
- `tests/test-catalog.py`'s target-count check was conditional on the phrase
  "共 N 个" being present in `支持的软件列表.md`, so deleting the phrase deleted
  the check itself instead of failing — the same class of vacuous guard as the CI
  dry-run assertion below. A missing phrase is now an explicit failure.
- A copy that died halfway was never repaired and never warned about. The
  `.skillbridge-copy` ownership marker was written **after** the files, so a
  partial copy had no marker, was classified as the tool's own folder and
  skipped on every later run — stale content forever. The marker is now written
  **before** the copy starts, so a leftover is recognised as ours and refreshed
  on the next run. `Copy-SkillDirectory` also refuses to claim a directory it
  failed to clear, so a failed delete cannot stamp the marker onto a tool's own
  folder. The Unix `copy_skill_tree` now fails the whole skill copy when a file
  cannot be copied (it used to swallow the error and log `created` for a partial
  copy), matching the Windows twin.
- `check-db-sync.py --fix` could empty CC Switch's entire skill list. An empty
  (or wrong) skills folder makes every database row look like "folder is gone",
  so the repair deleted all of them. It now refuses with exit 2 when the folder
  is empty but the database is not, and points at `--source`; the new
  `--allow-empty-source` flag is the explicit override for "yes, I really
  deleted every skill".
- `install-autolink.ps1 -DryRun` changed things. The `autolink.enabled=false`
  branch — whose whole job is to unregister the task — was checked before the
  dry-run branch, so a "preview" could silently delete the real scheduled task.
  The same guard now also covers `-Unregister -DryRun`.
- `detect-tools.ps1` / `detect-tools.sh` resurrected a deliberately removed
  target: they decide by "does the tool's marker directory exist", and an
  uninstalled tool usually leaves that directory behind, so the target came back
  on every run. Fixed by the new `exclude` array.
- `detect-tools` overwrote a hand-edited `$comment` in `config.json`, discarding
  machine-specific migration notes. It is now preserved.
- `sync-skills.sh --copy-into` and `install-autolink.sh --interval` with a
  missing value spun forever, printing nothing: `shift 2` fails silently when
  only one argument is left, leaving `$1` unchanged, so the option loop never
  advanced. Both now exit 1 immediately, and `--interval` also rejects a
  non-numeric value.
- The CI "AutoLink dry-run" assertion could never fail, in both Windows jobs.
  `install-autolink.ps1` prints with `Write-Host`, which does not land in
  `$out = ...`; `$out` is then "automation null" and `$out -notmatch 'DRY-RUN'`
  returns an **empty array**, which is falsy — so the `throw` was dead code and
  a real dry-run regression would have shipped green. Fixed with `6>&1` (merge
  the information stream) plus an explicit empty-output check. The same trap is
  now guarded in `tests/smoke-windows.ps1`: every sync-summary assertion goes
  through `Assert-HaveSummary` first, so an early `exit 1` (no summary printed)
  can no longer make the idempotency checks pass vacuously.
- Windows dead-link pruning resolved a symlink's *relative* target against the
  process CWD instead of the link's own directory, so a live foreign symlink
  could be declared dead and removed. `sync-skills.ps1` now resolves it the way
  `sync-skills.sh` already did.
- Link ownership accepted any string prefix of the source path, so a junction
  into a sibling folder (`...\cc-switch\skills-backup\...`) was treated as ours
  and overwritten. The check now requires the path separator (Windows only —
  the Unix check was already strict).
- `check-db-sync.py --fix` crashed with a traceback (after the backup, before
  the repair) when the DB schema had no `directory` column, and could never
  delete a row whose `directory` was NULL; a failed repair now exits 2 with the
  transaction rolled back.
- All PowerShell scripts are saved as UTF-8 **with BOM**, fixing mojibake in
  `detect-tools.ps1`'s Chinese output under Windows PowerShell 5.1.
- A leftover `"Cursor": "path"` string in an existing `config.json` is promoted
  to copy mode (same if the path ends with `/.cursor/skills`).
- Copying a target whose dest equals the source is refused, so `rm` + copy
  cannot delete the CC Switch library.
- Unix `write_managed` reads skill names from stdin instead of argv (`ARG_MAX`).
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
