#!/bin/bash
# Builds the Mac release ZIP into dist/: a ready-made "Claude Progress.app"
# and terminal hook for both Apple silicon and Intel Macs, so people who
# download it need no developer tools.
#     ./make-release-mac.sh

set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/task-progress-bar/.claude-plugin/plugin.json" | head -1)"
build="$root/build/mac-release"
stage="$build/task-progress-widget"
zip="$root/dist/task-progress-widget-v$version-mac.zip"
rm -rf "$build" "$zip"

# Claude refuses a mod that fails its validator, silently, so check first.
# Uses `claude` on PATH, or the copy the Claude desktop app ships.
claude="$(command -v claude || true)"
if [ -z "$claude" ]; then
    claude="$(ls -t "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude 2>/dev/null | head -1 || true)"
fi
[ -n "$claude" ] || { echo "Claude Code not found; can't validate the mod" >&2; exit 1; }
echo "Validating the mod..."
"$claude" plugin validate "$root/task-progress-bar" >/dev/null \
    || { echo "The mod failed 'claude plugin validate'; fix it before releasing" >&2; exit 1; }

"$root/mac/build.sh" --universal --out "$build/bin"

mkdir -p "$stage/mac" "$root/dist"
cp "$root/install.command" "$root/uninstall.command" "$root/README.md" "$root/LICENSE" "$stage/"
cp "$root/mac/build.sh" "$root/mac/Info.plist" "$root/mac/settings.js" "$stage/mac/"
ditto "$root/task-progress-bar" "$stage/task-progress-bar"
rm -rf "$stage/task-progress-bar/.claude-plugin/types" "$stage/task-progress-bar/last-error.txt" \
    "$stage/task-progress-bar/widget/TaskProgressWidget.exe" "$stage/task-progress-bar/cli/progress-hook"
find "$stage" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
ditto "$build/bin/Claude Progress.app" "$stage/task-progress-bar/widget/Claude Progress.app"
cp "$build/bin/progress-hook" "$stage/task-progress-bar/cli/progress-hook"

# No Finder metadata in the ZIP (it would unzip as __MACOSX clutter).
xattr -cr "$stage"
(cd "$build" && ditto -c -k --norsrc --noextattr --keepParent task-progress-widget "$zip")
echo "Done: $zip"
