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


def is_cursor_copy(name, path):
    if (name or "").lower() == "cursor":
        return True
    norm_path = (path or "").replace("\\", "/").rstrip("/")
    return norm_path.lower().endswith("/.cursor/skills") or norm_path.lower() == ".cursor/skills"


def spec(name, value):
    promoted = False
    if isinstance(value, dict):
        path = value.get("path") or value.get("skills") or ""
        mode = (value.get("mode") or "link").lower()
        if mode in ("junction", "symlink"):
            mode = "link"
        if mode != "copy":
            mode = "link"
    else:
        mode, path = "link", value
    if mode != "copy" and is_cursor_copy(name, path):
        mode = "copy"
        promoted = True
    return mode, path, promoted

print(norm(cfg["source"]))
for name, v in cfg.get("targets", {}).items():
    try:
        mode, path, promoted = spec(name, v)
        if promoted:
            print(
                "NOTE: target %s is Cursor / .cursor/skills — using copy mode"
                % name,
                file=sys.stderr,
            )
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

COPY_MARKER=".skillbridge-copy"

skill_fingerprint() {
    # Hash every regular file except the dest-only copy marker, in relative-path
    # order. Including the marker would make dest never equal source.
    python3 - "$1" "$COPY_MARKER" <<'PY'
import hashlib, os, sys
root, marker = sys.argv[1], sys.argv[2]
h = hashlib.sha256()
files = []
for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
    for name in filenames:
        if name == marker:
            continue
        path = os.path.join(dirpath, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, root).replace("\\", "/")
        files.append(rel)
files.sort()
for rel in files:
    path = os.path.join(root, rel)
    h.update(rel.encode("utf-8"))
    h.update(b"\0")
    with open(path, "rb") as handle:
        h.update(handle.read())
    h.update(b"\0")
sys.stdout.write("%s:%d" % (h.hexdigest(), len(files)))
PY
}

write_managed() {
    # Names on stdin (one per line) so a large skill set cannot hit ARG_MAX.
    local file="$1"
    python3 -c '
import json, sys
path = sys.argv[1]
names = [line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"skills": names}, handle)
    handle.write("\n")
' "$file"
}

same_path() {
    python3 -c 'import os,sys; print("1" if os.path.realpath(sys.argv[1])==os.path.realpath(sys.argv[2]) else "0")' "$1" "$2"
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

is_our_entry() {
    local dest="$1"
    if [ -d "$dest" ] && [ ! -L "$dest" ] && [ -f "$dest/$COPY_MARKER" ]; then
        return 0
    fi
    is_our_link "$dest"
}

rm_skill_entry() {
    local dest="$1"
    if [ -L "$dest" ]; then
        rm -f "$dest"
    elif [ -d "$dest" ]; then
        rm -rf "$dest"
    elif [ -e "$dest" ]; then
        rm -f "$dest"
    fi
}

copy_skill_tree() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    local item name dest_item
    while IFS= read -r -d '' item; do
        name="$(basename "$item")"
        [ "$name" = "$COPY_MARKER" ] && continue
        dest_item="$dest/$name"
        if [ -L "$item" ]; then
            continue
        elif [ -d "$item" ]; then
            copy_skill_tree "$item" "$dest_item"
        elif [ -f "$item" ]; then
            cp -f "$item" "$dest_item"
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
}

write_copy_marker() {
    printf 'skillbridge-copy\n' > "$1/$COPY_MARKER"
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
        if [ "$mode" = "copy" ] && [ "$(same_path "$tdir" "$SRC")" = "1" ]; then
            echo "WARN: skip $tool : copy dest equals source ($tdir)" >&2
            echo "SKIP     $tool : copy dest equals source" >> "$LOG"
            continue
        fi
        mkdir -p "$tdir"
        managed_file="$tdir/.skillbridge-managed.json"
        new_managed=()

        if [ "$mode" = "copy" ]; then
            while IFS= read -r -d '' dest; do
                dname="$(basename "$dest")"
                [ "$dname" = ".skillbridge-managed.json" ] && continue
                [ "$dname" = "$COPY_MARKER" ] && continue
                if is_our_entry "$dest" && ! name_in_list "$dname" "${SKILL_NAMES[@]}"; then
                    rm_skill_entry "$dest"
                    pruned=$((pruned+1))
                    echo "pruned   $tool : $dname" >> "$LOG"
                fi
            done < <(find "$tdir" -mindepth 1 -maxdepth 1 -print0)
        fi

        for name in "${SKILL_NAMES[@]}"; do
            skill="$SRC/$name"
            dest="$tdir/$name"
            if [ "$mode" = "copy" ]; then
                ours=0
                if [ -e "$dest" ] || [ -L "$dest" ]; then
                    if is_our_entry "$dest"; then
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
                if err="$( { rm_skill_entry "$dest" && copy_skill_tree "$skill" "$dest" && write_copy_marker "$dest"; } 2>&1 )"; then
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
            printf '%s\n' "${new_managed[@]+"${new_managed[@]}"}" | write_managed "$managed_file"
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
        while IFS= read -r -d '' link; do
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
        done < <(find "$tdir" -mindepth 1 -maxdepth 1 -print0)
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
