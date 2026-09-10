#!/usr/bin/env bash
# install-autolink.sh — Register an auto-link on macOS (launchd) / Linux (crontab).
# Runs sync-skills.sh at login so newly added CC Switch skills are linked into
# every configured target tool.
#
# Usage:
#   ./install-autolink.sh                # at logon
#   ./install-autolink.sh --interval 30  # at logon + every 30 minutes
#   ./install-autolink.sh --uninstall
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/sync-skills.sh"
LABEL="com.user.ccswitch-skill-sync"
INTERVAL_MIN="${INTERVAL_MIN:-0}"

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
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

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
    <key>RunAtLoad</key><true/>
EOF
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
    echo "Installed launchd agent '$LABEL' (at login${INTERVAL_MIN:+, every ${INTERVAL_MIN}min})."
else
    # Linux: crontab @reboot (plus optional */N minutes)
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$SYNC" > "$tmp"
    echo "@reboot /bin/bash $SYNC >> \"$SCRIPT_DIR/sync-skills.log\" 2>&1" >> "$tmp"
    if [ "$INTERVAL_MIN" -gt 0 ]; then
        echo "*/$INTERVAL_MIN * * * * /bin/bash $SYNC >> \"$SCRIPT_DIR/sync-skills.log\" 2>&1" >> "$tmp"
    fi
    crontab "$tmp"
    rm -f "$tmp"
    echo "Installed crontab entry for '$SYNC' (at boot${INTERVAL_MIN:+, every ${INTERVAL_MIN}min})."
fi
