#!/usr/bin/env bash
# tests/smoke-unix.sh — functional smoke test for the Unix (symlink) sync path.
#
# Creates a temp source with one fake skill and a temp target, runs sync-skills.sh
# twice, and asserts: link created, idempotent on second run. Also asserts that an
# unset %HERMES_HOME% target is skipped with a warning and never degrades to
# creating /skills at the filesystem root; that underscore-prefixed archives are
# not linked; that dead symlinks are pruned; and that detect-tools.sh --all
# writes a valid config.json. Restores the repo log and config.json afterwards.
#
# Usage: bash tests/smoke-unix.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
LOG="$ROOT/sync-skills.log"
REPO_CONFIG="$ROOT/config.json"

# make the %HERMES_HOME% case deterministic regardless of the runner env
unset HERMES_HOME

LOG_BAK="$TMP/log.bak"
if [ -f "$LOG" ]; then cp "$LOG" "$LOG_BAK"; fi
CFG_BAK="$TMP/config.bak"
if [ -f "$REPO_CONFIG" ]; then cp "$REPO_CONFIG" "$CFG_BAK"; fi

cleanup() {
    if [ -f "$LOG_BAK" ]; then
        cp "$LOG_BAK" "$LOG"
    else
        rm -f "$LOG"
    fi
    if [ -f "$CFG_BAK" ]; then
        cp "$CFG_BAK" "$REPO_CONFIG"
    else
        rm -f "$REPO_CONFIG"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

SRC="$TMP/src"
TGT="$TMP/tgt"
mkdir -p "$SRC/demo-skill" "$SRC/_archived" "$TGT/own-skill"
echo "# demo" > "$SRC/demo-skill/SKILL.md"
echo "# archive" > "$SRC/_archived/SKILL.md"
ln -s /nonexistent/skillbridge-dead "$TGT/dead-skill"

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
  },
  "check_db": false
}
EOF

# Truncate the repo log so this run's lines are easy to grep; cleanup restores it.
: > "$LOG"

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
if [ -e "$TGT/_archived" ] || [ -L "$TGT/_archived" ]; then
    echo "FAIL: underscore-prefixed archive was linked" >&2
    exit 1
fi
if [ -L "$TGT/dead-skill" ] || [ -e "$TGT/dead-skill" ]; then
    echo "FAIL: dead symlink was not pruned" >&2
    exit 1
fi
if [ ! -d "$TGT/own-skill" ]; then
    echo "FAIL: tool's own real directory was removed" >&2
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
if ! grep -q 'created  Smoke : demo-skill' "$LOG"; then
    echo "FAIL: log did not record tool name 'Smoke' (got:)" >&2
    cat "$LOG" >&2
    exit 1
fi
if ! grep -q 'pruned   Smoke : dead-skill' "$LOG"; then
    echo "FAIL: log did not record prune of dead-skill (got:)" >&2
    cat "$LOG" >&2
    exit 1
fi

out="$(bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q 'skipped=1'; then
    echo "FAIL: second run not idempotent (expected skipped=1, got: $out)" >&2
    exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'pruned=0'; then
    echo "FAIL: second run expected pruned=0, got: $out" >&2
    exit 1
fi

echo "OK: unix smoke (link created, idempotent, archive skipped, dead link pruned, tool name logged)"

# detect-tools.sh --all writes a config that includes every catalogued tool
if ! bash "$ROOT/detect-tools.sh" --all >/dev/null; then
    echo "FAIL: detect-tools.sh --all exited non-zero" >&2
    exit 1
fi
if ! python3 - "$REPO_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
targets = cfg.get("targets") or {}
if "Cursor" not in targets:
    sys.exit("FAIL: detect-tools.sh --all did not include Cursor")
if cfg.get("link_type") != "symlink":
    sys.exit("FAIL: detect-tools.sh should default link_type=symlink, got %r" % cfg.get("link_type"))
if len(targets) < 1:
    sys.exit("FAIL: detect-tools.sh produced no targets")
print("OK: detect-tools.sh (%d targets)" % len(targets))
PY
then
    exit 1
fi
