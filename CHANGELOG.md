# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Skills can be managed from the dashboard, and it acts on `config.json`'s
  `source`** — the same folder CC Switch itself keeps its skills in.
  `POST /api/skills/delete` (`Remove-SkillBridgeSkill` in `common.psm1`) removes
  one skill folder; `POST /api/skills/add` (`Import-SkillBridgeSkillZip`)
  installs the skills inside an uploaded `.zip` package there.
  - Installing unpacks the package **entry by entry** into a staging folder
    inside the source and then moves each skill out of it, so an install is a
    rename rather than a copy that can stop half way. `.NET Framework`'s
    `ExtractToDirectory` does not sanitise entry names, so every entry is checked
    first: `..` traversal, an absolute path, a `GetFullPath` that leaves the
    staging directory and a symbolic-link entry (which would otherwise land as a
    regular file carrying link mode bits) are all refused before anything is
    written; macOS archive noise (`__MACOSX/`, `._*`, `.DS_Store`) is skipped, and
    both the packed size and the unpacked total are capped.
  - A skill is a folder containing `SKILL.md` — the same rule the sync uses — so
    one package may carry several skills and anything else in it is left behind;
    a package that is a single skill at its root is named by the `name:` in its
    front matter and warned about when that disagrees with its folder. A name
    that already exists is **never** overwritten: it is reported as skipped,
    because overwriting is how someone loses a skill they were editing. Whatever
    happens, the staging folder is removed again, so a refused upload cannot
    leave a phantom skill in the source.
  - Deleting is refused unless the folder is provably a skill: an illegal folder
    name (`CON`, `..`, a trailing dot), a folder that is not there, or a folder
    without `SKILL.md` (i.e. somebody else's directory) deletes nothing. It is
    *not* a sync: the targets then hold residuals, which the next sync prunes,
    and the `cc-switch.db` row stays behind as drift the report-only check
    shows — both stated in the UI before the button is pressed, because the
    source folder is what every tool on the machine reads and there is no undo.
- **A rebuilt dashboard page**, on top of a shadcn-style semantic token system
  (`--background` / `--foreground` / `--card` / `--muted` / `--muted-foreground` /
  `--border` / `--destructive`, one radius scale) so light and dark are one
  stylesheet with two palettes instead of two designs (the top-bar button
  switches, the choice is kept in `localStorage`). The hero, the target cards,
  the option bar, the skill rows and the two new dialogs are all built from
  those tokens. Interaction and accessibility work on top of that: a real ARIA
  tablist (`role="tablist"` / `role="tab"` / `aria-selected` / `aria-controls`,
  roving `tabindex`, ←/→/Home/End, the open view still in the URL hash); both
  dialogs are `role="dialog"` + `aria-modal="true"` with the page behind them
  made `inert`, a Tab trap, Escape to cancel, focus restored to the button that
  opened them and never to the dialog box itself; a visible `:focus-visible`
  ring on every control; `/` focuses the search box; a skeleton instead of an
  empty panel while the skill list loads, all motion quieted under
  `prefers-reduced-motion`. New in the page itself: the per-row trash button,
  the 添加技能 dialog (a drop zone plus a hidden `.zip` file input, 32 MB
  client-side cap, chunked base64 so a large package does not build a quadratic
  string), a result list that reports what the upload added / skipped / refused,
  and the destructive delete dialog that names the path, the file count and the
  three consequences the page cannot otherwise show. Everything is still
  inlined — no CDN, no build step, nothing fetched but the page's own API.
- `tests/smoke-webui.ps1` now drives both new endpoints end to end over HTTP
  against a throwaway source and asserts what is on disk afterwards: a valid
  package (SKILL.md plus a nested folder), the same package again (skipped, and
  the file already in the source is untouched), an entry that tries to escape
  (`..\..\`) refused without abandoning the rest of the upload, non-zip bytes,
  an illegal name, a missing skill, a folder without `SKILL.md`, `GET` answered
  with 405, no token with 403, no body field with 400, a body past the cap with
  413 — and that the server still answers afterwards, because the refused body
  is drained or the response is lost to a reset. The page guards now also cover
  the tablist, the token system, both dialogs and `#i-chevron` (the carets used
  to be referenced but never defined, so every one of them rendered as an empty
  box).
- **A local dashboard** (`web-ui.ps1` + `web-ui.html`, started by double-clicking
  `启动WebUI.bat`): one page on `http://localhost:<port>/` showing the whole
  state of the sync — the source, a card per target (skills found, links
  created, copies updated, dead links pruned, failures), the tail of
  `sync-skills.log`, and two actions: run a sync, or run the same *report-only*
  CC Switch database check the sync does. It refreshes every 15 seconds and
  stops with the console window or a button in the page.
- **A skill browser in the dashboard**, behind its own option bar: the page is
  split into 同步状况 on the left and 技能列表 on the right, with the open view
  stored in the URL hash so a reload or a bookmark returns to it. The list is
  grouped by category, with a **Chinese one-line intro** per skill coming from
  the new `skill-catalog.zh-CN.json` — a hand-maintained overlay the dashboard
  reads on top of each `SKILL.md`, never instead of it. A skill the catalog has
  not caught up with falls into an 其他 bucket and shows its own (English)
  description, dimmed, under where the Chinese intro would be, so it stays
  readable instead of vanishing. Each row carries the description folded out of
  `SKILL.md`, file count, size, last change, and which targets hold it — as a
  link or as a real copy. Search by name, Chinese intro or description, sort by
  name / coverage / size / last change, filter to the ones that are not
  everywhere yet, fold a whole category away, or expand a row for the
  per-target detail. Served by `GET /api/skills`, backed by
  `Get-SkillBridgeSkills`, `Get-SkillFrontMatter` and `Get-SkillCatalog` in
  `common.psm1` (the front-matter parser joins the folded `>-` / `|` description
  scalars by hand — there is no YAML dependency). The list is read when its view
  is first opened, on 刷新 / after a driven sync, and with its own 重新读取
  button — deliberately **not** by the 15-second poll, since walking 100+
  `SKILL.md` files is seconds of work a poll should not repeat. A dashed copy
  chip means the shape on disk disagrees with the mode `config.json` asks for.
- `skill-catalog.zh-CN.json`: 127 skills across 10 categories (敏捷研发流程,
  规划与协作, 代码与架构, 界面与动效, 视觉与图文, 学术与论文, 调研与检索,
  写作与内容, 商业方法论, 自动化与工具), each with a Chinese one-liner.
  `tools/build-skill-catalog.py` is the one-off generator that produced it and
  validates the categories; the runtime only reads the JSON.
- `Get-SkillBridgeSkills` in `common.psm1`: the skill list behind that browser —
  one entry per source skill with its front matter, size, mtime and a compact
  target→kind map — so the page and the smoke suite share one implementation.
- `Get-SkillBridgeStatus` in `common.psm1`: one snapshot of the whole sync
  state (source, per-target linked / missing / copied / failed, last run
  record) that the dashboard, the smoke suite and any other caller share, so
  "what does the sync think" has exactly one implementation. Gained
  `-IncludeSyncMap`, which fills a per-target name→link-or-copy map on demand:
  the 15-second snapshot does not pay for the extra walk.
- `tests/smoke-webui.ps1`: drives the dashboard's API the way the page does
  and asserts that every call without the per-start token is refused (403),
  that `GET /api/sync` and `GET /api/db-check` are 405, that a driven sync
  really creates the junction and the copy and exits 0, that `GET /api/skills`
  reports the fixture's folded description as one line with its size and
  mtime and its per-target coverage before the sync (`link` for the junction
  target, `copy` for the copy target after it), that
  `POST /api/db-check` leaves `cc-switch.db` byte-identical, that the listener
  is on `127.0.0.1` / `::1` only (a connection to this machine's own LAN
  address is refused), and that `POST /api/stop` shuts it down cleanly. CI now
  runs it in both Windows jobs.
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
- The dashboard is a plain `TcpListener` bound to `127.0.0.1` (and `::1`), not
  an `HttpListener`. HTTP.sys opens a **wildcard** socket for a port whatever
  URL prefixes you register and routes by `Host` header, so a client on the
  LAN that sends `Host: localhost:<port>` was served the dashboard — and with
  it the per-start token. Measured here: `HttpListener` answered that request
  with 200, the loopback listener refuses the connection at TCP level. Every
  `/api/` call must also carry the token the page was served with, which is
  what stops another open page in the same browser from POSTing a sync (CSRF).
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
- Clicking one target card expanded the cards next to it. The target grid is a
  CSS grid, and grid items stretch to the tallest item in their row by default,
  so opening a card with a long detail ballooned the three collapsed cards
  beside it to the same height (measured here: 141px → 317px) — it read as one
  click expanding the whole row. `.targets` sets `align-items: start` now, so
  only the clicked card grows; several cards can still be open at once, which is
  what keeping the open state outside the render is for.
  `tests/smoke-webui.ps1` asserts the declaration is still in the served page,
  because no API-level test can see a layout.
- The dashboard's page could go stale in the browser after a restart. The HTML
  is read into the server process once at startup and `/` carried no
  `Cache-Control`, so a tab holding the previous build kept showing it — which
  is what hid the fix above until a hard reload. The page is `no-store` now, and
  the smoke suite reads the header to keep it that way.
- **Front-end interaction bugs in the dashboard.** `renderTargets()` rebuilds
  the whole grid on every snapshot, so an expanded card collapsed 15 seconds
  later (and after every sync) — the open state now lives outside the render
  and is restored by target name. Clicking a chip or an issue line inside an
  expanded card collapsed it; a click inside `.detail` is now reading, not
  toggling. The log panel was yanked back to the bottom on every auto-refresh,
  so reading earlier lines was impossible; it now sticks to the bottom only when
  it already was. The `s` shortcut started a full sync from one keystroke and
  ignored modifiers, so **Ctrl+S** ("save this page") fired a sync too — refresh
  is the only shortcut left, and it ignores Ctrl/Meta/Alt. A second sync could
  also be started through the shortcut while one was already running. After 停止
  the 15s poll kept hammering the dead server and replaced the "服务已停止"
  message with a connection error every 15 seconds; it stops now. 停止 sat one
  misclick away from 立即同步, and the `window.confirm()` guard froze the page's
  JS thread while it was open — it is a two-click button instead ("停止" →
  "确认停止？", 5s timeout). A request had no deadline, so a server that died
  mid-sync left the button spinning forever; there is now a 10-minute abort whose
  message explains that the server answers one request at a time. A hidden tab
  no longer polls, and refreshes are serialised instead of queueing up behind a
  running sync and firing in a burst.
- The dashboard reported "N-1 联接目标" by subtracting one from the total target
  count, which is only right while exactly one copy-mode target exists; it now
  counts the modes it actually renders.
- Dead-link pruning deleted links it did not own. Every other deletion path
  already required the link to point *into the source*; pruning only required
  the link to be dead, so a junction or symlink whose target had simply gone
  away — a user's link to an unmounted drive, a shortcut into another tool's
  folder — was silently removed with the tool's own skills keeping no record
  of it. Both `sync-skills.ps1` and `sync-skills.sh` now apply the same
  ownership rule here as everywhere else, and the smoke suites grow a fixture
  for it on both platforms.
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
