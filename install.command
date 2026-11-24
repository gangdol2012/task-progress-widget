#!/bin/bash
# Installs the Claude progress widget for the current macOS user, from this
# folder (a clone of the repository, or the release ZIP). The release's
# Claude-Progress .pkg does the same with a double-click.
# Double-click it in Finder, or run it in Terminal:
#     bash install.command
#
# Options (mostly for testing):
#     --claude-home DIR     install somewhere other than ~/.claude (a test: it
#                           then leaves the real widget and launchd alone)
#     --apps-dir DIR        put the app somewhere other than ~/Applications
#     --no-login-item       don't open the widget when you log in
#     --no-launch           don't open the widget now
#     --no-terminal-hooks   skip the hooks for Claude Code in a terminal
#     --no-pause            don't wait for Return at the end

set -u
here="$(cd "$(dirname "$0")" && pwd)"
apps_dir="$HOME/Applications"
setup_args=()
pause=1
real=1
while [ $# -gt 0 ]; do
    case "$1" in
        --claude-home) setup_args+=(--claude-home "$2"); real=0; shift ;;
        --apps-dir) apps_dir="$2"; shift ;;
        --no-login-item|--no-launch|--no-terminal-hooks) setup_args+=("$1") ;;
        --no-pause) pause=0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
    shift
done

app="$apps_dir/Claude Progress.app"
label="io.github.ohmygoditisme.claude-progress"
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

# 1. The app: ready-made in the release ZIP, or else built here from source
#    with Apple's command line tools. It carries the mod and hook too.
new_app="$here/task-progress-bar/widget/Claude Progress.app"
if [ -f "$new_app/Contents/Resources/setup.sh" ]; then
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
    say "[ok] Built"
else
    say "The widget needs building, and that needs Apple's command line tools."
    say "Either download the installer for Mac (Claude-Progress-….pkg), which"
    say "includes a ready-made app:"
    say "    https://github.com/OhMyGodItIsMe/task-progress-widget/releases/latest"
    say "or install the tools (a window asks first), then run this installer again:"
    say "    xcode-select --install"
    finish 1
fi

# 2. Close a running widget so the app can be replaced. (Taken out of
#    launchd first, or launchd would start it again.)
if [ "$real" = 1 ]; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
    pkill -u "$(id -u)" -x ClaudeProgress >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        pgrep -u "$(id -u)" -x ClaudeProgress >/dev/null 2>&1 || break
        sleep 0.25
    done
fi

# 3. The app, in your Applications folder (Launchpad and Spotlight find it).
mkdir -p "$apps_dir"
rm -rf "$app"
if ! ditto "$new_app" "$app"; then
    say "Couldn't copy the app to $app"
    finish 1
fi
# Files from a downloaded ZIP carry a "downloaded from the internet" mark.
xattr -dr com.apple.quarantine "$app" 2>/dev/null
say "[ok] Claude Progress added to $apps_dir"

# 4. Everything else, from inside the app: the mod and hook, Claude's
#    settings, opening at login, and the widget itself.
[ "$real" = 1 ] && setup_args+=(--ask-restart)
if ! bash "$app/Contents/Resources/setup.sh" ${setup_args[@]+"${setup_args[@]}"}; then
    finish 1
fi

say ""
say "Done. Claude Code sessions you start in a terminal show up on their own."
say ""
finish 0
