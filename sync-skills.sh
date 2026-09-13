#!/usr/bin/env bash
# sync-skills.sh — Unix variant of sync-skills.ps1: creates symlinks instead of junctions.
# For every skill in the CC Switch skills dir that is missing in a target tool's
# skills dir, create a symlink pointing at the source. Idempotent.
#
# NOTE: keep the sync loop's behavior in sync with sync-skills.ps1 (Windows variant):
# skip/count/log semantics must stay identical across both scripts.
#
# Usage:
#   ./sync-skills.sh                # uses ./config.json
#   ./sync-skills.sh ./my-config.json
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/config.json}"
LOG="$SCRIPT_DIR/sync-skills.log"

if [ ! -f "$CONFIG" ]; then
    echo "[ERROR] config not found: $CONFIG" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] python3 is required to parse $CONFIG (not found on PATH)." >&2
    exit 1
fi

# Read the config in ONE python pass: line 1 = expanded source dir, following
# lines = expanded target dirs. A target whose env var is unset is skipped with
# a warning on stderr (not counted); a broken source aborts the whole run.
read_config() {
    python3 - "$CONFIG" <<'PY'
import json, sys, os

cfg = json.load(open(sys.argv[1]))


def norm(v):
    # Normalize a Windows-style path (backslashes, %VAR%) for this Unix machine.
    v = v.replace("\\", "/")
    v = v.replace("%USERPROFILE%", os.path.expanduser("~"))
    v = v.replace("%APPDATA%", os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")))
    v = v.replace("%LOCALAPPDATA%", os.path.expanduser("~/.local/share"))
    if "HERMES_HOME" in os.environ:
        v = v.replace("%HERMES_HOME%", os.environ["HERMES_HOME"])
    v = os.path.expandvars(v)
    if "%" in v or "\\" in v:
        raise ValueError("unresolved env var or backslash in path: %r" % v)
    return v

print(norm(cfg["source"]))
for v in cfg.get("targets", {}).values():
    try:
        print(norm(v))
    except ValueError as e:
        print("WARN target skipped: %s" % e, file=sys.stderr)
PY
}

config_out="$(read_config)" || {
    echo "[ERROR] failed to read config: $CONFIG" >&2
    exit 1
}
IFS=$'\n' read -r -d '' -a CONFIG_LINES <<< "$config_out" || true
if [ ${#CONFIG_LINES[@]} -lt 1 ]; then
    echo "[ERROR] failed to read config: $CONFIG" >&2
    exit 1
fi
SRC="${CONFIG_LINES[0]}"
TARGETS=("${CONFIG_LINES[@]:1}")

if [ ! -d "$SRC" ]; then
    echo "[ERROR] source dir not found: $SRC" >&2
    echo "        Is CC Switch installed? Set the correct path in config.json (source)." >&2
    exit 1
fi

created=0
pruned=0
skipped=0
failed=0
skill_count=0

for skill in "$SRC"/*/; do
    [ -f "$skill/SKILL.md" ] || continue
    skill_count=$((skill_count+1))
    name="$(basename "$skill")"

    if [ ${#TARGETS[@]} -gt 0 ]; then
        for tdir in "${TARGETS[@]}"; do
            [ -z "$tdir" ] && continue
            mkdir -p "$tdir"
            link="$tdir/$name"
            if [ -e "$link" ] || [ -L "$link" ]; then
                skipped=$((skipped+1))
                continue
            fi
            if err="$(ln -s "$skill" "$link" 2>&1)"; then
                created=$((created+1))
                echo "created  $(basename "$tdir") : $name" >> "$LOG"
            elif printf '%s' "$err" | grep -qi 'exists'; then
                # lost a race with a concurrent run — treat as already linked
                skipped=$((skipped+1))
            else
                failed=$((failed+1))
                echo "FAILED   $(basename "$tdir") : $name -> $err" >> "$LOG"
            fi
        done
    fi
done

if [ "$skill_count" -eq 0 ]; then
    echo "[ERROR] no skills found in source dir: $SRC (no subfolder contains SKILL.md)" >&2
    exit 1
fi

# Prune dead links — entries left behind when a skill is deleted from the source.
# The loop above only walks skills that still exist, so it can never see them.
for tdir in "${TARGETS[@]}"; do
    [ -z "$tdir" ] && continue
    [ -d "$tdir" ] || continue
    for link in "$tdir"/*; do
        # Only symlinks are ours to remove; a real folder belongs to the tool.
        if [ -L "$link" ] && [ ! -e "$link" ]; then
            rm -f "$link"
            pruned=$((pruned+1))
            echo "pruned   $(basename "$tdir") : $(basename "$link")" >> "$LOG"
        fi
    done
done

echo "== done $(date '+%Y-%m-%d %H:%M:%S') | created=$created pruned=$pruned skipped=$skipped failed=$failed ==" | tee -a "$LOG"

# Keep cc-switch.db in step with the skills folder (see check-db-sync.py).
# Optional: silently skipped when python3, the script, or the database is absent.
check_db="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("check_db",True))' "$CONFIG" 2>/dev/null || echo True)"
if [ "$check_db" = "True" ] && [ -f "$SCRIPT_DIR/check-db-sync.py" ] && [ -f "$HOME/.cc-switch/cc-switch.db" ]; then
    python3 "$SCRIPT_DIR/check-db-sync.py" --fix --source "$SRC" --log "$LOG" || true
fi

if [ "$failed" -gt 0 ]; then
    exit 1
fi
