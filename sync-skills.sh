#!/usr/bin/env bash
# sync-skills.sh — Unix variant of sync-skills.ps1: creates symlinks instead of junctions
# (or real copies when a target's mode is "copy").
# For every skill in the CC Switch skills dir that is missing in a target tool's
# skills dir, create a symlink pointing at the source. Idempotent.
#
# NOTE: keep the sync loop's behavior in sync with sync-skills.ps1 (Windows variant):
# skip/count/log semantics must stay identical across both scripts.
#
# Usage:
#   ./sync-skills.sh                         # uses ./config.json
#   ./sync-skills.sh ./my-config.json
#   ./sync-skills.sh --copy-into ./.cursor/skills
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=""
COPY_INTO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --copy-into)
            COPY_INTO="${2:-}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--copy-into DIR] [config.json]"
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            exit 1
            ;;
        *)
            CONFIG="$1"
            shift
            ;;
    esac
done
CONFIG="${CONFIG:-$SCRIPT_DIR/config.json}"
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
# lines = "<tool name><TAB><mode><TAB><expanded dir>". A target whose env var
# is unset is skipped with a warning on stderr (not counted); a broken source
# aborts the whole run. Tool names travel with the path so logs don't collapse
# to `basename(dir)` (which is almost always "skills").
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


def spec(value):
    if isinstance(value, dict):
        path = value.get("path") or value.get("skills") or ""
        mode = (value.get("mode") or "link").lower()
        if mode in ("junction", "symlink"):
            mode = "link"
        if mode != "copy":
            mode = "link"
        return mode, path
    return "link", value

print(norm(cfg["source"]))
for name, v in cfg.get("targets", {}).items():
    try:
        mode, path = spec(v)
        print("%s\t%s\t%s" % (name.replace("\t", " "), mode, norm(path)))
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
# Remaining lines are "<tool name><TAB><mode><TAB><path>".
TARGET_NAMES=()
TARGET_MODES=()
TARGET_DIRS=()
if [ ${#CONFIG_LINES[@]} -gt 1 ]; then
    for line in "${CONFIG_LINES[@]:1}"; do
        [ -z "$line" ] && continue
        name="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        mode="${rest%%$'\t'*}"
        tdir="${rest#*$'\t'}"
        TARGET_NAMES+=("$name")
        TARGET_MODES+=("$mode")
        TARGET_DIRS+=("$tdir")
    done
fi

resolve_target_path() {
    local p="$1"
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  printf '%s' "$(pwd)/$p" ;;
    esac
}

if [ -n "$COPY_INTO" ]; then
    TARGET_NAMES+=("CopyInto")
    TARGET_MODES+=("copy")
    TARGET_DIRS+=("$(resolve_target_path "$COPY_INTO")")
fi

if [ ! -d "$SRC" ]; then
    echo "[ERROR] source dir not found: $SRC" >&2
    echo "        Is CC Switch installed? Set the correct path in config.json (source)." >&2
    exit 1
fi

created=0
updated=0
pruned=0
skipped=0
failed=0
skill_count=0
SKILL_NAMES=()

for skill in "$SRC"/*/; do
    [ -d "$skill" ] || continue
    name="$(basename "$skill")"
    case "$name" in
        _*) continue ;;
    esac
    [ -f "$skill/SKILL.md" ] || continue
    skill_count=$((skill_count+1))
    SKILL_NAMES+=("$name")
done

if [ "$skill_count" -eq 0 ]; then
    echo "[ERROR] no skills found in source dir: $SRC (no subfolder contains SKILL.md)" >&2
    exit 1
fi

skill_fingerprint() {
    local dir="$1"
    local md="$dir/SKILL.md"
    local hash=""
    if [ -f "$md" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            hash="$(sha256sum "$md" | awk '{print $1}')"
        else
            hash="$(shasum -a 256 "$md" | awk '{print $1}')"
        fi
    fi
    local count
    count="$(find "$dir" -type f ! -name '.skillbridge-copy' 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s:%s' "$hash" "$count"
}

read_managed() {
    python3 -c 'import json,sys
try:
    print("\n".join(json.load(open(sys.argv[1])).get("skills") or []))
except Exception:
    pass
' "$1" 2>/dev/null || true
}

write_managed() {
    # Names are argv, not stdin: `python3 - <<'PY'` would steal a stdin pipe.
    local file="$1"
    shift
    MANAGED_FILE="$file" python3 - "$@" <<'PY'
import json, os, sys
path = os.environ["MANAGED_FILE"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"skills": list(sys.argv[1:])}, handle)
    handle.write("\n")
PY
}

is_our_link() {
    local dest="$1"
    [ -L "$dest" ] || return 1
    local t abs
    t="$(readlink "$dest")"
    case "$t" in
        /*) abs="$t" ;;
        *)  abs="$(cd "$(dirname "$dest")" && pwd)/$t" ;;
    esac
    abs="${abs%/}"
    local srcn="${SRC%/}"
    case "$abs" in
        "$srcn"|"$srcn"/*) return 0 ;;
    esac
    return 1
}

name_in_list() {
    local needle="$1"
    shift
    local n
    for n in "$@"; do
        [ "$n" = "$needle" ] && return 0
    done
    return 1
}

if [ ${#TARGET_DIRS[@]} -gt 0 ]; then
    i=0
    for tdir in "${TARGET_DIRS[@]}"; do
        tool="${TARGET_NAMES[$i]}"
        mode="${TARGET_MODES[$i]}"
        i=$((i+1))
        [ -z "$tdir" ] && continue
        tdir="$(resolve_target_path "$tdir")"
        mkdir -p "$tdir"
        managed_file="$tdir/.skillbridge-managed.json"
        managed=()
        while IFS= read -r line; do
            [ -n "$line" ] && managed+=("$line")
        done < <(read_managed "$managed_file")
        new_managed=()

        if [ "$mode" = "copy" ]; then
            for dest in "$tdir"/*; do
                [ -e "$dest" ] || [ -L "$dest" ] || continue
                dname="$(basename "$dest")"
                ours=0
                if name_in_list "$dname" "${managed[@]+"${managed[@]}"}"; then
                    ours=1
                elif is_our_link "$dest"; then
                    ours=1
                fi
                if [ "$ours" -eq 1 ] && ! name_in_list "$dname" "${SKILL_NAMES[@]}"; then
                    rm -rf "$dest"
                    pruned=$((pruned+1))
                    echo "pruned   $tool : $dname" >> "$LOG"
                fi
            done
        fi

        for name in "${SKILL_NAMES[@]}"; do
            skill="$SRC/$name"
            dest="$tdir/$name"
            if [ "$mode" = "copy" ]; then
                ours=0
                if [ -e "$dest" ] || [ -L "$dest" ]; then
                    if name_in_list "$name" "${managed[@]+"${managed[@]}"}" || is_our_link "$dest"; then
                        ours=1
                    else
                        skipped=$((skipped+1))
                        continue
                    fi
                    if [ "$ours" -eq 1 ] && [ ! -L "$dest" ]; then
                        if [ "$(skill_fingerprint "$skill")" = "$(skill_fingerprint "$dest")" ]; then
                            skipped=$((skipped+1))
                            new_managed+=("$name")
                            continue
                        fi
                    fi
                    existed=1
                else
                    existed=0
                fi
                if err="$(rm -rf "$dest" && cp -a "$skill" "$dest" 2>&1)"; then
                    if [ "$existed" -eq 1 ]; then
                        updated=$((updated+1))
                        echo "updated  $tool : $name" >> "$LOG"
                    else
                        created=$((created+1))
                        echo "created  $tool : $name" >> "$LOG"
                    fi
                    new_managed+=("$name")
                else
                    failed=$((failed+1))
                    echo "FAILED   $tool : $name -> $err" >> "$LOG"
                fi
                continue
            fi

            if [ -e "$dest" ] || [ -L "$dest" ]; then
                skipped=$((skipped+1))
                continue
            fi
            if err="$(ln -s "$skill" "$dest" 2>&1)"; then
                created=$((created+1))
                echo "created  $tool : $name" >> "$LOG"
            elif printf '%s' "$err" | grep -qi 'exists'; then
                skipped=$((skipped+1))
            else
                failed=$((failed+1))
                echo "FAILED   $tool : $name -> $err" >> "$LOG"
            fi
        done

        if [ "$mode" = "copy" ]; then
            write_managed "$managed_file" "${new_managed[@]+"${new_managed[@]}"}"
        fi
    done
fi

# Prune dead links on link-mode targets.
if [ ${#TARGET_DIRS[@]} -gt 0 ]; then
    i=0
    for tdir in "${TARGET_DIRS[@]}"; do
        tool="${TARGET_NAMES[$i]}"
        mode="${TARGET_MODES[$i]}"
        i=$((i+1))
        [ "$mode" = "copy" ] && continue
        [ -z "$tdir" ] && continue
        tdir="$(resolve_target_path "$tdir")"
        [ -d "$tdir" ] || continue
        for link in "$tdir"/*; do
            [ -e "$link" ] || [ -L "$link" ] || continue
            if [ -L "$link" ]; then
                target="$(readlink "$link")"
                case "$target" in
                    /*) abs="$target" ;;
                    *)  abs="$(cd "$(dirname "$link")" && pwd)/$target" ;;
                esac
                if [ -n "$target" ] && [ ! -e "$abs" ]; then
                    rm -f "$link"
                    pruned=$((pruned+1))
                    echo "pruned   $tool : $(basename "$link")" >> "$LOG"
                fi
            fi
        done
    done
fi

echo "== done $(date '+%Y-%m-%d %H:%M:%S') | created=$created updated=$updated pruned=$pruned skipped=$skipped failed=$failed ==" | tee -a "$LOG"

check_db="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("check_db",True))' "$CONFIG" 2>/dev/null || echo True)"
if [ "$check_db" = "True" ] && [ -f "$SCRIPT_DIR/check-db-sync.py" ] && [ -f "$HOME/.cc-switch/cc-switch.db" ]; then
    python3 "$SCRIPT_DIR/check-db-sync.py" --fix --source "$SRC" --log "$LOG" || true
fi

if [ "$failed" -gt 0 ]; then
    exit 1
fi
