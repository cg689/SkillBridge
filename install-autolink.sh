#!/usr/bin/env bash
# install-autolink.sh — Register an auto-link on macOS (launchd) / Linux (crontab).
# Runs sync-skills.sh so newly added CC Switch skills are linked into every
# configured target tool. macOS triggers at LOGIN (launchd RunAtLoad); Linux
# triggers at BOOT (crontab @reboot), plus an optional repeating interval.
# Defaults (enabled / at_logon / interval) come from the `autolink` block in
# config.json; --interval overrides the interval.
#
# Usage:
#   ./install-autolink.sh                # config defaults
#   ./install-autolink.sh --interval 30  # override interval (minutes)
#   ./install-autolink.sh --uninstall
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/sync-skills.sh"
LABEL="com.user.ccswitch-skill-sync"
INTERVAL_MIN="${INTERVAL_MIN:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL_MIN="${2:-0}"; shift 2 ;;
        --uninstall)
            if [ "$(uname)" = "Darwin" ]; then
                launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
                rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
            else
                crontab -l 2>/dev/null | grep -v "$SYNC" | crontab -
            fi
            echo "Uninstalled auto-link."
            exit 0
            ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# config.json `autolink` block provides the defaults (enabled / at_logon / interval)
CONFIG="$SCRIPT_DIR/config.json"
AT_LOGON="True"
if [ -f "$CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    read -r AL_ENABLED AL_AT_LOGON AL_INTERVAL < <(python3 - "$CONFIG" <<'PY' 2>/dev/null || echo "True True 0"
import json, sys
cfg = json.load(open(sys.argv[1]))
al = cfg.get("autolink", {})
print("%s %s %s" % (al.get("enabled", True), al.get("at_logon", True), al.get("interval_minutes", 0)))
PY
)
    AT_LOGON="${AL_AT_LOGON:-True}"
    if [ "$AL_ENABLED" = "False" ]; then
        echo "AutoLink disabled by config (autolink.enabled=false). Not installing."
        exit 0
    fi
    if [ -z "$INTERVAL_MIN" ] || [ "$INTERVAL_MIN" = "0" ]; then
        INTERVAL_MIN="${AL_INTERVAL:-0}"
    fi
fi
INTERVAL_MIN="${INTERVAL_MIN:-0}"

if [ "$AT_LOGON" = "False" ] && [ "$INTERVAL_MIN" -le 0 ]; then
    echo "[ERROR] nothing to schedule: at_logon=false and interval_minutes=0." >&2
    exit 1
fi

if [ "$(uname)" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SYNC</string>
    </array>
EOF
    if [ "$AT_LOGON" != "False" ]; then
        cat >> "$PLIST" <<EOF
    <key>RunAtLoad</key><true/>
EOF
    fi
    if [ "$INTERVAL_MIN" -gt 0 ]; then
        cat >> "$PLIST" <<EOF
    <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
EOF
    fi
    cat >> "$PLIST" <<EOF
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl enable "gui/$(id -u)/$LABEL"
    if [ "$AT_LOGON" != "False" ]; then
        if [ "$INTERVAL_MIN" -gt 0 ]; then
            echo "Installed launchd agent '$LABEL' (at login, every ${INTERVAL_MIN}min)."
        else
            echo "Installed launchd agent '$LABEL' (at login)."
        fi
    else
        echo "Installed launchd agent '$LABEL' (at interval only, every ${INTERVAL_MIN}min)."
    fi
else
    # Linux: crontab @reboot (boot, not login) plus optional */N minutes
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$SYNC" > "$tmp"
    if [ "$AT_LOGON" != "False" ]; then
        echo "@reboot /bin/bash $SYNC >> \"$SCRIPT_DIR/sync-skills.log\" 2>&1" >> "$tmp"
    fi
    if [ "$INTERVAL_MIN" -gt 0 ]; then
        echo "*/$INTERVAL_MIN * * * * /bin/bash $SYNC >> \"$SCRIPT_DIR/sync-skills.log\" 2>&1" >> "$tmp"
    fi
    crontab "$tmp"
    rm -f "$tmp"
    if [ "$AT_LOGON" != "False" ]; then
        if [ "$INTERVAL_MIN" -gt 0 ]; then
            echo "Installed crontab entry for '$SYNC' (at boot, every ${INTERVAL_MIN}min)."
        else
            echo "Installed crontab entry for '$SYNC' (at boot)."
        fi
    else
        echo "Installed crontab entry for '$SYNC' (at interval only, every ${INTERVAL_MIN}min)."
    fi
fi
