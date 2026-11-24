#!/bin/bash
# Installs the Claude progress widget for the current macOS user.
# Double-click it in Finder, or run it in Terminal:
#     bash install.command
#
# Options (mostly for testing):
#     --claude-home DIR     install somewhere other than ~/.claude
#     --apps-dir DIR        put the app somewhere other than ~/Applications
#     --no-login-item       don't open the widget when you log in
#     --no-launch           don't open the widget now
#     --no-terminal-hooks   skip the hooks for Claude Code in a terminal
#     --no-pause            don't wait for Return at the end

set -u
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/task-progress-bar"
claude_home="$HOME/.claude"
apps_dir="$HOME/Applications"
login=1; launch=1; hooks=1; pause=1
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-home) claude_home="$2"; shift ;;
        --apps-dir) apps_dir="$2"; shift ;;
        --no-login-item) login=0 ;;
        --no-launch) launch=0 ;;
        --no-terminal-hooks) hooks=0 ;;
        --no-pause) pause=0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

dest="$claude_home/mods/task-progress-bar"
settings="$claude_home/settings.json"
plugin_dir="~/.claude/mods/task-progress-bar"
[ "$claude_home" = "$HOME/.claude" ] || plugin_dir="$dest"
app="$apps_dir/Claude Progress.app"
label="io.github.ohmygoditisme.claude-progress"
agent="$HOME/Library/LaunchAgents/$label.plist"
work="$(mktemp -d "${TMPDIR:-/tmp}/claude-progress-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

say() { printf '%s\n' "$*"; }
finish() {
    if [ "$pause" = 1 ] && [ -t 0 ]; then
        read -r -p "Press Return to close this window. " _
    fi
    exit "$1"
}

say ""
say "Installing the Claude progress widget..."
say ""

if [ "$(uname -s)" != "Darwin" ]; then
    say "This installer is for macOS. On Windows, double-click install.bat instead."
    finish 1
fi

# 1. The widget: the ready-made app from the release download, or else
#    built here from source with Apple's command line tools.
new_app="$src/widget/Claude Progress.app"
new_hook="$src/cli/progress-hook"
if [ -x "$new_app/Contents/MacOS/ClaudeProgress" ] && [ -x "$new_hook" ]; then
    say "[ok] Using the included Claude Progress.app (nothing to build)"
elif xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then
    say "Building the widget from source (takes a few seconds)..."
    if ! "$here/mac/build.sh" --out "$work/build" >"$work/build.log" 2>&1; then
        cat "$work/build.log"
        say ""
        say "The build failed (above). Nothing was installed."
        finish 1
    fi
    new_app="$work/build/Claude Progress.app"
    new_hook="$work/build/progress-hook"
    say "[ok] Built"
else
    say "The widget needs building, and that needs Apple's command line tools."
    say "Either download the release ZIP for Mac, which includes a ready-made app:"
    say "    https://github.com/OhMyGodItIsMe/task-progress-widget/releases/latest"
    say "or install the tools (a window asks first), then run this installer again:"
    say "    xcode-select --install"
    finish 1
fi

# 2. Close a running widget so its files can be replaced. (Taken out of
#    launchd first, or launchd would start it again.)
launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
pkill -x ClaudeProgress >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pgrep -x ClaudeProgress >/dev/null 2>&1 || break
    sleep 0.25
done
pkill -9 -x ClaudeProgress >/dev/null 2>&1

# 3. Copy the mod and the terminal hook. (The app goes to Applications.)
mkdir -p "$claude_home/mods" "$claude_home/task-progress" || finish 1
rm -rf "$dest"
if ! ditto "$src" "$dest"; then
    say "Couldn't copy the files to $dest"
    finish 1
fi
rm -rf "$dest/widget/Claude Progress.app" "$dest/widget/TaskProgressWidget.exe" "$dest/.claude-plugin/types"
find "$dest" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
cp -f "$new_hook" "$dest/cli/progress-hook" 2>/dev/null || true
chmod +x "$dest/cli/progress-hook"
# Files from a downloaded ZIP carry a "downloaded from the internet" mark;
# macOS would refuse to run the unsigned hook with it.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null
say "[ok] Files copied to $dest"

# 4. Turn the mod on in Claude's settings, keeping every other setting, and
#    add the hooks for Claude Code in a terminal.
if ! out="$(osascript -l JavaScript "$here/mac/settings.js" install "$settings" "$plugin_dir" \
        "$dest/cli/progress-hook" "$hooks" 2>&1)"; then
    if printf '%s' "$out" | grep -q NOT_JSON; then
        say "Could not read $settings (it is not valid JSON). Nothing was changed there."
        say "Add this to it by hand:  \"env\": { \"CLAUDE_CODE_PLUGIN_DIRS\": \"$plugin_dir\" }"
    else
        say "Could not update $settings:"
        say "$out"
    fi
    finish 1
fi
say "$out"

# 5. The app, in your Applications folder (Launchpad and Spotlight find it).
mkdir -p "$apps_dir"
rm -rf "$app"
if ! ditto "$new_app" "$app"; then
    say "Couldn't copy the app to $app"
    finish 1
fi
xattr -dr com.apple.quarantine "$app" 2>/dev/null
say "[ok] Claude Progress added to $apps_dir"

# 6. Open it at login (a launch agent, which also reopens it if it ever
#    crashes; closing it yourself keeps it closed).
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
if [ "$login" = 1 ]; then
    mkdir -p "$(dirname "$agent")"
    cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$app/Contents/MacOS/ClaudeProgress")</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$label</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
EOF
    say "[ok] It opens when you log in"
fi

# 7. Open the widget.
if [ "$launch" = 1 ]; then
    if [ "$login" = 1 ] && launchctl bootstrap "gui/$(id -u)" "$agent" >/dev/null 2>&1; then
        say "[ok] Widget opened (top-right corner of your main screen)"
    elif open "$app"; then
        say "[ok] Widget opened (top-right corner of your main screen)"
    else
        say "Couldn't open the widget; open Claude Progress from $apps_dir"
    fi
fi

say ""
say "Done. Last step: fully quit Claude and open it again (Claude menu > Quit"
say "Claude, or Command-Q). Sessions only show up in the widget after that"
say "restart. Terminal sessions you start from now on show up on their own."
say ""
finish 0
