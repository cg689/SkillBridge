# Contributing to SkillBridge

Thanks for taking the time to contribute! SkillBridge is a small, script-based
project — any help is appreciated, from fixing a typo to adding support for a
new AI coding tool.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How to Contribute](#how-to-contribute)
  - [Reporting Bugs](#reporting-bugs)
  - [Suggesting Features](#suggesting-features)
  - [Adding Support for a New Tool](#adding-support-for-a-new-tool)
  - [Improving the Code](#improving-the-code)
- [Development](#development)
- [Style Guide](#style-guide)
- [Pull Request Process](#pull-request-process)

## Code of Conduct

Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md). Participation
in this project implies agreement with it.

## How to Contribute

### Reporting Bugs

Open an issue using the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.yml).
Include:

- Your OS and shell version (e.g. Windows 11, PowerShell 5.1).
- The tool and skills directory involved.
- The exact command you ran and the full output/error.

### Suggesting Features

Open an issue using the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.yml),
describing the use case and the expected behavior.

### Adding Support for a New Tool

1. Find where the tool stores its skills (install a skill in the tool and see
   which folder it writes to).
2. Add an entry to [`supported-tools.json`](supported-tools.json) (`name`,
   `marker`, `skills`, optional `mode`). Prefer environment variables over
   hardcoded paths. Use `"mode": "copy"` when the tool cannot follow
   junctions/symlinks (Cursor Cloud Agents are the example). This file is the
   source of truth: `detect-tools.ps1` and `detect-tools.sh` both read it.
3. Add the same `name → skills` line to `config.example.json` (CI fails if the
   two lists drift).
4. Update `支持的软件列表.md` and the supported-tools mention in `README.md` /
   `README.zh-CN.md`.
5. Run `sync-skills.ps1` or `./sync-skills.sh` and verify the link is created.

### Improving the Code

Open a PR. Keep changes focused and small; if a change is large, open an issue
first to discuss it.

## Development

- **Windows**: PowerShell 5.1+ (any edition). No external dependencies.
- **macOS / Linux**: Bash + `python3` (used for config parsing and `detect-tools.sh`).
- Catalog / DB tests (any OS with Python 3):
  `python tests/test-catalog.py && python tests/test-check-db-sync.py`
- Unix smoke: `bash tests/smoke-unix.sh`
- Windows smoke: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\smoke-windows.ps1`

## Style Guide

- **PowerShell**: clear function names, `$ErrorActionPreference = 'Continue'`
  for non-fatal sync errors, comments in English.
- **Bash**: `set -u`, `#!/usr/bin/env bash`, avoid pipelines into subshells
  where counters need to propagate.
- **JSON**: 2-space indent; keep `targets` keys ordered.
- Paths in config **must** use environment variables (`%USERPROFILE%`,
  `%APPDATA%`, `%HERMES_HOME%`, `$HOME`) — never hardcode a username or drive.

## Pull Request Process

1. Fork the repo and create a feature branch.
2. Make your changes and verify them locally.
3. Update the relevant docs (`README.md`, `README.zh-CN.md`, `CHANGELOG.md`).
4. Ensure CI (JSON validation, PSScriptAnalyzer, shellcheck) passes.
5. Submit the PR with a clear description of the change and why it is needed.
