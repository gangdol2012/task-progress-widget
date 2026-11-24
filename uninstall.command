#!/bin/bash
# Removes the Claude progress widget for the current macOS user, however it
# was installed (the .pkg, or install.command). A copy is inside the app:
#     bash "/Applications/Claude Progress.app/Contents/Resources/uninstall.command"
# or run this one from the repository or release ZIP:
#     bash uninstall.command
#
# Options (for testing): --claude-home DIR, --apps-dir DIR, --no-pause. With
# another --claude-home it leaves the real widget and launchd alone.

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
pkg_id="$label.pkg"
system_app="/Applications/Claude Progress.app"
# Next to this script inside the app; in mac/ in the repository and ZIP.
settings_js="$here/settings.js"
[ -f "$settings_js" ] || settings_js="$here/mac/settings.js"

finish() {
    if [ "$pause" = 1 ] && [ -t 0 ]; then
        read -r -p "Press Return to close this window. " _
    fi
    exit "$1"
}

echo ""
echo "Removing the Claude progress widget..."

if [ "$claude_home" = "$HOME/.claude" ]; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
    rm -f "$agent"
    pkill -u "$(id -u)" -x ClaudeProgress >/dev/null 2>&1
fi

if [ -f "$settings" ]; then
    if ! out="$(osascript -l JavaScript "$settings_js" uninstall "$settings" \
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

# The app: in your own Applications folder (install.command), and in the
# Mac's (the .pkg), which only an administrator can remove; macOS asks for
# your password for that.
rm -rf "$apps_dir/Claude Progress.app"
if [ "$apps_dir" = "$HOME/Applications" ] && [ -d "$system_app" ]; then
    if rm -rf "$system_app" 2>/dev/null && [ ! -d "$system_app" ]; then
        echo "[ok] Removed $system_app"
    elif osascript -e "do shell script \"rm -rf '$system_app'; pkgutil --forget '$pkg_id' >/dev/null 2>&1; true\" with administrator privileges with prompt \"Remove Claude Progress from Applications.\"" >/dev/null 2>&1; then
        echo "[ok] Removed $system_app"
    else
        echo "Claude Progress is still in Applications; drag it to the Trash to finish."
    fi
fi

echo "Done. Restart Claude to finish."
echo ""
finish 0
