#!/usr/bin/env bash
# tests/smoke-unix.sh — functional smoke test for the Unix (symlink) sync path.
#
# Creates a temp source with one fake skill and a temp target, runs sync-skills.sh
# twice, and asserts: link created, idempotent on second run. Also asserts that an
# unset %HERMES_HOME% target is skipped with a warning and never degrades to
# creating /skills at the filesystem root. Restores the repo sync-skills.log
# afterwards so nothing is polluted.
#
# Usage: bash tests/smoke-unix.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
LOG="$ROOT/sync-skills.log"

# make the %HERMES_HOME% case deterministic regardless of the runner env
unset HERMES_HOME

# back up the real log so the smoke run's entries don't pollute it
LOG_BAK="$TMP/log.bak"
if [ -f "$LOG" ]; then cp "$LOG" "$LOG_BAK"; fi

cleanup() {
    if [ -f "$LOG_BAK" ]; then
        cp "$LOG_BAK" "$LOG"
    else
        rm -f "$LOG"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

SRC="$TMP/src"
TGT="$TMP/tgt"
mkdir -p "$SRC/demo-skill" "$TGT"
echo "# demo" > "$SRC/demo-skill/SKILL.md"

# NOTE: unquoted heredoc collapses `\\` to `\`, so we write 4 backslashes to
# emit a valid JSON escape (`\\`) and end up with the real value
# `%HERMES_HOME%\skills` — faithfully mirroring config.example.json.
cat > "$TMP/cfg.json" <<EOF
{
  "link_type": "symlink",
  "source": "$SRC",
  "targets": {
    "Smoke": "$TGT",
    "BadHome": "%HERMES_HOME%\\\\skills"
  }
}
EOF

# invoke via `bash` explicitly: the exec bit is not committed, so `./sync-skills.sh` would fail on a fresh checkout
if ! bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" >/dev/null 2>"$TMP/stderr.log"; then
    echo "FAIL: sync-skills.sh exited non-zero" >&2
    cat "$TMP/stderr.log" >&2
    exit 1
fi
if [ ! -L "$TGT/demo-skill" ]; then
    echo "FAIL: symlink not created at $TGT/demo-skill" >&2
    exit 1
fi
if [ -e /skills ]; then
    echo "FAIL: unset %HERMES_HOME% created /skills at the filesystem root" >&2
    exit 1
fi
if ! grep -q 'WARN target skipped' "$TMP/stderr.log"; then
    echo "FAIL: expected a skip warning for the %HERMES_HOME% target (stderr below)" >&2
    cat "$TMP/stderr.log" >&2
    exit 1
fi

out="$(bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q 'skipped=1'; then
    echo "FAIL: second run not idempotent (expected skipped=1, got: $out)" >&2
    exit 1
fi

echo "OK: unix smoke (link created, idempotent, unset %HERMES_HOME% skipped)"
