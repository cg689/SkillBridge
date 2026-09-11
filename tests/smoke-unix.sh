#!/usr/bin/env bash
# tests/smoke-unix.sh — functional smoke test for the Unix (symlink) sync path.
#
# Creates a temp source with one fake skill and a temp target, runs sync-skills.sh
# twice, and asserts: link created, idempotent on second run. Restores the repo
# sync-skills.log afterwards so nothing is polluted.
#
# Usage: bash tests/smoke-unix.sh
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
LOG="$ROOT/sync-skills.log"

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

cat > "$TMP/cfg.json" <<EOF
{
  "link_type": "symlink",
  "source": "$SRC",
  "targets": { "Smoke": "$TGT" }
}
EOF

"$ROOT/sync-skills.sh" "$TMP/cfg.json" >/dev/null
if [ ! -L "$TGT/demo-skill" ]; then
    echo "FAIL: symlink not created at $TGT/demo-skill" >&2
    exit 1
fi

out="$("$ROOT/sync-skills.sh" "$TMP/cfg.json")"
if ! printf '%s\n' "$out" | grep -q 'skipped=1'; then
    echo "FAIL: second run not idempotent (expected skipped=1, got: $out)" >&2
    exit 1
fi

echo "OK: unix smoke (link created, idempotent)"
