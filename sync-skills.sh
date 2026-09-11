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
# lines = expanded target dirs. Fail loudly instead of silently defaulting.
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
    v = v.replace("%HERMES_HOME%", os.environ.get("HERMES_HOME", ""))
    v = os.path.expandvars(v)
    if "%" in v or "\\" in v:
        raise SystemExit("unresolved env var or backslash in path: %r" % v)
    return v

print(norm(cfg["source"]))
for v in cfg.get("targets", {}).values():
    print(norm(v))
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
skipped=0
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
            if ln -s "$skill" "$link" 2>>"$LOG"; then
                created=$((created+1))
                echo "created  $(basename "$tdir") : $name" >> "$LOG"
            else
                echo "FAILED   $(basename "$tdir") : $name" >> "$LOG"
            fi
        done
    fi
done

if [ "$skill_count" -eq 0 ]; then
    echo "[ERROR] no skills found in source dir: $SRC (no subfolder contains SKILL.md)" >&2
    exit 1
fi

echo "== done $(date '+%Y-%m-%d %H:%M:%S') | created=$created skipped=$skipped ==" | tee -a "$LOG"
