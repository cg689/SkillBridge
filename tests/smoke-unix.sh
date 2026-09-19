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
# A live symlink with a RELATIVE target must survive pruning: it resolves
# against the link's own directory, not the process CWD. rel-link sits in
# $TGT, so its ../rel-real target must exist one level UP, in $TMP.
mkdir -p "$TMP/rel-real"
ln -s "../rel-real" "$TGT/rel-link"

# NOTE: unquoted heredoc collapses `\\` to `\`, so we write 4 backslashes to
# emit a valid JSON escape (`\\`) and end up with the real value
# `%HERMES_HOME%\skills` — faithfully mirroring config.example.json.
cat > "$TMP/cfg.json" <<EOF
{
  "link_type": "symlink",
  "source": "$SRC",
  "targets": {
    "Smoke": "$TGT",
    "SmokeCopy": { "path": "$TGT-copy", "mode": "copy" },
    "SelfCopy": { "path": "$SRC", "mode": "copy" },
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
if [ -L "$TGT-copy/demo-skill" ] || [ ! -f "$TGT-copy/demo-skill/SKILL.md" ]; then
    echo "FAIL: copy-mode dest must be a real directory with SKILL.md" >&2
    exit 1
fi
if [ ! -f "$TGT-copy/.skillbridge-managed.json" ]; then
    echo "FAIL: copy-mode dest is missing .skillbridge-managed.json" >&2
    exit 1
fi
if [ ! -f "$TGT-copy/demo-skill/.skillbridge-copy" ]; then
    echo "FAIL: copy-mode dest is missing .skillbridge-copy marker" >&2
    exit 1
fi
if [ -f "$SRC/demo-skill/.skillbridge-copy" ]; then
    echo "FAIL: copy dest==source wrote a marker into the source skill" >&2
    exit 1
fi
if [ ! -f "$SRC/demo-skill/SKILL.md" ]; then
    echo "FAIL: copy dest==source removed the source skill" >&2
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
if [ ! -L "$TGT/rel-link" ] || [ ! -e "$TGT/rel-link" ]; then
    echo "FAIL: live relative-target symlink was pruned" >&2
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
mkdir -p "$TGT-copy/own-skill"
echo "# mine" > "$TGT-copy/own-skill/SKILL.md"
python3 - "$TGT-copy/.skillbridge-managed.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
skills = list(data.get("skills") or [])
if "own-skill" not in skills:
    skills.append("own-skill")
json.dump({"skills": skills}, open(path, "w", encoding="utf-8"))
PY

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
if ! printf '%s\n' "$out" | grep -q 'skipped=2'; then
    echo "FAIL: second run not idempotent (expected skipped=2, got: $out)" >&2
    exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'pruned=0'; then
    echo "FAIL: second run expected pruned=0, got: $out" >&2
    exit 1
fi
if [ ! -d "$TGT-copy/own-skill" ] || [ ! -f "$TGT-copy/own-skill/SKILL.md" ]; then
    echo "FAIL: polluted managed list deleted a tool-owned own-skill" >&2
    exit 1
fi
if [ -f "$TGT-copy/own-skill/.skillbridge-copy" ]; then
    echo "FAIL: polluted managed list treated own-skill as ours" >&2
    exit 1
fi

echo "# demo-v2" > "$SRC/demo-skill/SKILL.md"
out="$(bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q 'updated=1'; then
    echo "FAIL: copy target should refresh after SKILL.md change (got: $out)" >&2
    exit 1
fi
if ! grep -q 'demo-v2' "$TGT-copy/demo-skill/SKILL.md"; then
    echo "FAIL: copied SKILL.md was not refreshed" >&2
    exit 1
fi

mkdir -p "$SRC/demo-skill/scripts"
echo 'echo hi' > "$SRC/demo-skill/scripts/run.sh"
echo hidden > "$SRC/demo-skill/.hidden-note"
echo payload > "$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$SRC/demo-skill/outside-link"
out="$(bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q 'updated=1'; then
    echo "FAIL: copy target should refresh after scripts/ change (got: $out)" >&2
    exit 1
fi
if [ ! -f "$TGT-copy/demo-skill/scripts/run.sh" ]; then
    echo "FAIL: scripts/ was not copied" >&2
    exit 1
fi
if [ ! -f "$TGT-copy/demo-skill/.hidden-note" ]; then
    echo "FAIL: hidden file inside skill was not copied" >&2
    exit 1
fi
if [ -e "$TGT-copy/demo-skill/outside-link" ] || [ -L "$TGT-copy/demo-skill/outside-link" ]; then
    echo "FAIL: copy mode must skip source symlinks" >&2
    exit 1
fi

mkdir -p "$SRC/gone-skill"
echo "# gone" > "$SRC/gone-skill/SKILL.md"
bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" >/dev/null
rm -rf "$SRC/gone-skill"
out="$(bash "$ROOT/sync-skills.sh" "$TMP/cfg.json" 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q 'pruned=2'; then
    echo "FAIL: expected pruned=2 after deleting gone-skill (link+copy), got: $out" >&2
    exit 1
fi
if [ -e "$TGT-copy/gone-skill" ] || [ -L "$TGT/gone-skill" ]; then
    echo "FAIL: gone-skill was not pruned from copy/link targets" >&2
    exit 1
fi

if ! bash "$ROOT/sync-skills.sh" --copy-into "$TMP/proj/.cursor/skills" "$TMP/cfg.json" >/dev/null; then
    echo "FAIL: --copy-into exited non-zero" >&2
    exit 1
fi
if [ -L "$TMP/proj/.cursor/skills/demo-skill" ] || [ ! -f "$TMP/proj/.cursor/skills/demo-skill/SKILL.md" ]; then
    echo "FAIL: --copy-into did not materialize a real skill directory" >&2
    exit 1
fi

if [ ! -f "$TMP/proj/.cursor/skills/demo-skill/.skillbridge-copy" ]; then
    echo "FAIL: --copy-into dest is missing .skillbridge-copy marker" >&2
    exit 1
fi

LEGACY="$TMP/legacy-cursor"
mkdir -p "$LEGACY"
cat > "$TMP/cfg-legacy.json" <<EOF
{
  "link_type": "symlink",
  "source": "$SRC",
  "targets": {
    "Cursor": "$LEGACY"
  },
  "check_db": false
}
EOF
if ! bash "$ROOT/sync-skills.sh" "$TMP/cfg-legacy.json" >/dev/null 2>"$TMP/legacy.err"; then
    echo "FAIL: legacy Cursor string target exited non-zero" >&2
    cat "$TMP/legacy.err" >&2
    exit 1
fi
if [ -L "$LEGACY/demo-skill" ] || [ ! -f "$LEGACY/demo-skill/SKILL.md" ]; then
    echo "FAIL: legacy Cursor string target must copy, not symlink" >&2
    exit 1
fi
if [ ! -f "$LEGACY/demo-skill/.skillbridge-copy" ]; then
    echo "FAIL: legacy Cursor copy is missing .skillbridge-copy marker" >&2
    exit 1
fi
if ! grep -q 'using copy mode' "$TMP/legacy.err"; then
    echo "FAIL: expected NOTE that Cursor string target was promoted to copy" >&2
    cat "$TMP/legacy.err" >&2
    exit 1
fi

# A symlink into a SIBLING of the source shares its string prefix but is not
# ours: ownership requires the separator (src vs src-backup).
mkdir -p "${SRC}-backup/demo-skill" "$TMP/own-tgt"
echo "# backup" > "${SRC}-backup/demo-skill/SKILL.md"
ln -s "${SRC}-backup/demo-skill" "$TMP/own-tgt/demo-skill"
cat > "$TMP/cfg-own.json" <<EOF
{
  "link_type": "symlink",
  "source": "$SRC",
  "targets": { "Own": "$TMP/own-tgt" },
  "check_db": false
}
EOF
bash "$ROOT/sync-skills.sh" "$TMP/cfg-own.json" >/dev/null 2>&1
if [ ! -L "$TMP/own-tgt/demo-skill" ]; then
    echo "FAIL: symlink into a source-sibling was treated as ours and overwritten" >&2
    exit 1
fi
if ! grep -q 'backup' "$TMP/own-tgt/demo-skill/SKILL.md"; then
    echo "FAIL: source-sibling symlink no longer points at the backup copy" >&2
    exit 1
fi

echo "OK: unix smoke (link+copy, marker ownership, relative-target symlink kept, sibling-prefix not ours, scripts refresh, dest!=src, Cursor upgrade, --copy-into)"

# detect-tools.sh --all writes a config that includes every catalogued tool
if ! bash "$ROOT/detect-tools.sh" --all >/dev/null; then
    echo "FAIL: detect-tools.sh --all exited non-zero" >&2
    exit 1
fi
if ! python3 - "$REPO_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
targets = cfg.get("targets") or {}
cur = targets.get("Cursor")
if not (isinstance(cur, dict) and cur.get("mode") == "copy"):
    sys.exit("FAIL: detect-tools.sh --all Cursor must be copy mode, got %r" % cur)
if cfg.get("link_type") != "symlink":
    sys.exit("FAIL: detect-tools.sh should default link_type=symlink, got %r" % cfg.get("link_type"))
if len(targets) < 1:
    sys.exit("FAIL: detect-tools.sh produced no targets")
targets["MyCustom"] = "/tmp/skillbridge-custom-skills"
json.dump(cfg, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
print("OK: detect-tools.sh (%d targets)" % len(targets))
PY
then
    exit 1
fi
if ! bash "$ROOT/detect-tools.sh" --all >/dev/null; then
    echo "FAIL: detect-tools.sh --all (second run) exited non-zero" >&2
    exit 1
fi
if ! python3 - "$REPO_CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
if cfg.get("targets", {}).get("MyCustom") != "/tmp/skillbridge-custom-skills":
    sys.exit("FAIL: detect-tools.sh dropped extra target MyCustom, got %r" % cfg.get("targets"))
print("OK: detect-tools.sh kept extra target")
PY
then
    exit 1
fi
