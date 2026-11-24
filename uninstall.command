#!/bin/bash
# Removes the Claude progress widget for the current macOS user.
# Double-click it in Finder, or run it in Terminal:
#     bash uninstall.command
#
# Options (for testing): --claude-home DIR, --apps-dir DIR, --no-pause

set -u
here="$(cd "$(dirname "$0")" && pwd)"
claude_home="$HOME/.claude"
apps_dir="$HOME/Applications"
pause=1
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-home) claude_home="$2"; shift ;;
        --apps-dir) apps_dir="$2"; shift ;;
        --no-pause) pause=0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

dest="$claude_home/mods/task-progress-bar"
settings="$claude_home/settings.json"
label="io.github.ohmygoditisme.claude-progress"
agent="$HOME/Library/LaunchAgents/$label.plist"

finish() {
    if [ "$pause" = 1 ] && [ -t 0 ]; then
        read -r -p "Press Return to close this window. " _
    fi
    exit "$1"
}

echo ""
echo "Removing the Claude progress widget..."

launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
rm -f "$agent"
pkill -x ClaudeProgress >/dev/null 2>&1
rm -rf "$apps_dir/Claude Progress.app"

if [ -f "$settings" ]; then
    if ! out="$(osascript -l JavaScript "$here/mac/settings.js" uninstall "$settings" \
            "~/.claude/mods/task-progress-bar" "$dest" 2>&1)"; then
        echo "Could not update $settings, so the mod and hooks are still listed there:"
        echo "$out"
    elif [ -n "$out" ]; then
        echo "$out"
    fi
fi

rm -rf "$dest" "$claude_home/task-progress" \
    "$claude_home/task-progress-widget.json" "$claude_home/task-progress-widget.log" \
    "$claude_home/task-progress-widget.lock" "$claude_home/task-progress-hook-debug.jsonl"

echo "Done. Restart Claude to finish."
echo ""
finish 0
