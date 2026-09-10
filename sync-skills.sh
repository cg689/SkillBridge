#!/usr/bin/env bash
# sync-skills.sh — Unix variant of sync-skills.ps1: creates symlinks instead of junctions.
# For every skill in the CC Switch skills dir that is missing in a target tool's
# skills dir, create a symlink pointing at the source. Idempotent.
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

HOME_DIR="${HOME}"

read_targets() {
    python3 - "$CONFIG" "$HOME_DIR" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for v in cfg.get("targets", {}).values():
    print(v.replace("%USERPROFILE%", sys.argv[2]).replace("$HOME", sys.argv[2]))
PY
}

SRC="$(python3 -c "import json,sys;c=json.load(open('$CONFIG'));print(c['source'].replace('%USERPROFILE%',sys.argv[1]).replace('\$HOME',sys.argv[1]))" "$HOME_DIR" 2>/dev/null || echo "$HOME_DIR/.cc-switch/skills")"

mkdir -p "$SRC"
created=0
skipped=0

for skill in "$SRC"/*/; do
    [ -f "$skill/SKILL.md" ] || continue
    name="$(basename "$skill")"

    while IFS= read -r tdir; do
        [ -z "$tdir" ] && continue
        mkdir -p "$tdir"
        link="$tdir/$name"
        if [ -e "$link" ] || [ -L "$link" ]; then
            skipped=$((skipped+1))
            continue
        fi
        if ln -s "$skill" "$link" 2>>"$LOG"; then
            created=$((created+1))
            echo "created  $(basename "$tdir") : $name" >> "$LOG"
        else
            echo "FAILED   $(basename "$tdir") : $name" >> "$LOG"
        fi
    done < <(read_targets)
done

echo "== done $(date '+%Y-%m-%d %H:%M:%S') | created=$created skipped=$skipped ==" | tee -a "$LOG"
