#!/bin/bash
# Sets Claude up, for the person running it, to use the progress widget:
# the mod and terminal hook in ~/.claude, Claude's settings, opening at login,
# and the widget itself. Runs from inside Claude Progress.app
# (Contents/Resources/setup.sh): the .pkg installer runs it as the person
# installing, and install.command runs it after putting the app in place.
# Running it again is safe; it replaces what an earlier run set up.
#
#   bash "/Applications/Claude Progress.app/Contents/Resources/setup.sh"
#
# Options (mostly for testing):
#     --claude-home DIR     set up somewhere other than ~/.claude (a test: it
#                           then leaves the real widget and launchd alone)
#     --no-login-item       don't open the widget at login
#     --no-launch           don't open the widget now
#     --no-terminal-hooks   skip the hooks for Claude Code in a terminal
#     --ask-restart         if Claude is open and needs a restart to load the
#                           mod, ask whether to restart it now (in Terminal
#                           when run from one, else in a window)

set -u
res="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$res/../.." && pwd)"
mod_src="$res/task-progress-bar"
hook_src="$app/Contents/Helpers/progress-hook"
claude_home="$HOME/.claude"
login=1; launch=1; hooks=1; ask_restart=0
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-home) claude_home="$2"; shift ;;
        --no-login-item) login=0 ;;
        --no-launch) launch=0 ;;
        --no-terminal-hooks) hooks=0 ;;
        --ask-restart) ask_restart=1 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

dest="$claude_home/mods/task-progress-bar"
settings="$claude_home/settings.json"
plugin_dir="~/.claude/mods/task-progress-bar"
[ "$claude_home" = "$HOME/.claude" ] || plugin_dir="$dest"
label="io.github.ohmygoditisme.claude-progress"
real=1
[ "$claude_home" = "$HOME/.claude" ] || { real=0; login=0; launch=0; }
agent="$HOME/Library/LaunchAgents/$label.plist"
uid="$(id -u)"

say() { printf '%s\n' "$*"; }

if [ ! -x "$app/Contents/MacOS/ClaudeProgress" ] || [ ! -d "$mod_src" ] || [ ! -x "$hook_src" ]; then
    say "This script has to run from inside Claude Progress.app ($res doesn't look like it)."
    exit 1
fi

# 1. Close a running widget, ours only. (Taken out of launchd first, or
#    launchd would start it again.)
if [ "$real" = 1 ]; then
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
    pkill -u "$uid" -x ClaudeProgress >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        pgrep -u "$uid" -x ClaudeProgress >/dev/null 2>&1 || break
        sleep 0.25
    done
    pkill -9 -u "$uid" -x ClaudeProgress >/dev/null 2>&1
fi

# 2. The mod and the terminal hook. Claude reads the mod when it starts, so
#    note whether the parts it loads are changing.
mod_changed=0
for f in .claude-plugin/plugin.json hooks/hooks.json hooks/register.tsx types/index.d.ts; do
    cmp -s "$mod_src/$f" "$dest/$f" || mod_changed=1
done
mkdir -p "$claude_home/mods" "$claude_home/task-progress" || exit 1
rm -rf "$dest"
if ! ditto "$mod_src" "$dest" || ! cp -f "$hook_src" "$dest/cli/progress-hook"; then
    say "Couldn't copy the files to $dest"
    exit 1
fi
chmod +x "$dest/cli/progress-hook"
# Copies of downloaded files keep a "downloaded from the internet" mark.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null
say "[ok] Files copied to $dest"

# 3. Turn the mod on in Claude's settings, keeping every other setting, and
#    add the hooks for Claude Code in a terminal.
if ! out="$(osascript -l JavaScript "$res/settings.js" install "$settings" "$plugin_dir" \
        "$dest/cli/progress-hook" "$hooks" 2>&1)"; then
    if printf '%s' "$out" | grep -q NOT_JSON; then
        say "Could not read $settings (it is not valid JSON). Nothing was changed there."
        say "Add this to it by hand:  \"env\": { \"CLAUDE_CODE_PLUGIN_DIRS\": \"$plugin_dir\" }"
    else
        say "Could not update $settings:"
        say "$out"
    fi
    exit 1
fi
say "$out"
case "$out" in
    *"Mod already turned on"*) ;;
    *) mod_changed=1 ;;  # Claude hasn't been loading it yet
esac

# 4. An older copy installed by install.command in your own Applications
#    folder, now that the app lives elsewhere.
own="$HOME/Applications/Claude Progress.app"
if [ "$real" = 1 ] && [ -d "$own" ] && [ "$own" != "$app" ]; then
    if [ "$(defaults read "$own/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$label" ]; then
        rm -rf "$own" && say "[ok] Removed the older copy in $HOME/Applications"
    fi
fi

# 5. Open it at login (a launch agent, which also reopens it if it ever
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

# 6. Open the widget.
if [ "$launch" = 1 ]; then
    if [ "$login" = 1 ] && launchctl bootstrap "gui/$uid" "$agent" >/dev/null 2>&1; then
        say "[ok] Widget opened (top-right corner of your main screen)"
    elif open "$app"; then
        say "[ok] Widget opened (top-right corner of your main screen)"
    else
        say "Couldn't open the widget; open Claude Progress from Applications"
    fi
fi

# 7. Claude loads the mod when it starts, so a Claude that was already open
#    when this mod was put in place needs a restart. The moment is kept in
#    a small file, compared with when Claude started.
since="$claude_home/task-progress/.mod-installed-at"
if [ "$mod_changed" = 1 ] || [ ! -f "$since" ]; then date +%s > "$since"; fi
claude_pid="$(pgrep -a -u "$uid" -x Claude 2>/dev/null | head -1)"
claude_started=""
if [ -n "$claude_pid" ]; then
    started_text="$(LC_ALL=C ps -o lstart= -p "$claude_pid" | sed 's/ *$//')"
    claude_started="$(LC_ALL=C date -j -f "%a %b %e %T %Y" "$started_text" +%s 2>/dev/null)"
fi
if [ "$real" = 1 ]; then
    if [ -z "$claude_pid" ]; then
        say "[ok] Claude picks the mod up the next time you open it"
    elif [ -n "$claude_started" ] && [ "$claude_started" -ge "$(cat "$since")" ]; then
        say "[ok] Claude has already loaded this mod; no restart needed"
    elif [ "$ask_restart" = 1 ] && [ -t 0 ]; then
        read -r -p "Restart Claude now? Anything it's working on stops when it quits. [Y/n] " answer
        case "$answer" in
            [nN]*) say "Later, then: fully quit Claude (Command-Q) and open it again." ;;
            *) open -n "$app" --args --restart-claude && say "[ok] Restarting Claude" ;;
        esac
    elif [ "$ask_restart" = 1 ] && open -n "$app" --args --ask-restart-claude; then
        say "[ok] Asked whether to restart Claude now"
    else
        say "Last step: fully quit Claude (Command-Q) and open it again."
    fi
fi
exit 0
