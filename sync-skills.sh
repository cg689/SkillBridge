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

# Expand %VAR% (Windows-style, e.g. %USERPROFILE%/%APPDATA%/%HERMES_HOME%) and $HOME
# into a path usable on this Unix machine.
read_targets() {
    python3 - "$CONFIG" <<'PY'
import json, sys, os
cfg = json.load(open(sys.argv[1]))
def norm(v):
    v = v.replace("%USERPROFILE%", os.path.expanduser("~"))
    v = v.replace("%APPDATA%", os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")))
    v = v.replace("%LOCALAPPDATA%", os.path.expanduser("~/.local/share"))
    return os.path.expandvars(v)
for v in cfg.get("targets", {}).values():
    print(norm(v))
PY
}

SRC="$(python3 - "$CONFIG" <<'PY' 2>/dev/null || echo "$HOME/.cc-switch/skills"
import json, sys, os
cfg = json.load(open(sys.argv[1]))
v = cfg["source"]
v = v.replace("%USERPROFILE%", os.path.expanduser("~"))
print(os.path.expandvars(v))
PY
)"

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
