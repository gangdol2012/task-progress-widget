#!/bin/bash
# Builds the macOS widget, "Claude Progress.app", from source. The app is
# self-contained: besides the widget it carries the mod, the terminal hook
# and the per-person setup and uninstall scripts, so the .pkg installer and
# install.command both set Claude up from what's inside it. Needs Apple's
# command line tools (xcode-select --install) or Xcode.
#
#   mac/build.sh [--universal] [--sign IDENTITY] [--out DIR]
#
# --universal  build for both Apple silicon and Intel Macs (for releases);
#              without it, only for this Mac.
# --sign       sign with this Developer ID Application identity, with the
#              hardened runtime and a secure timestamp, ready to notarize.
#              Without it the app gets an ad-hoc signature, which is enough
#              to run on the Mac that built it.
# --out        where to put the app (default: build/mac).

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mod="$root/task-progress-bar"
out="$root/build/mac"
universal=0
identity=""
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) universal=1 ;;
        --sign) identity="$2"; shift ;;
        --out) out="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mod/.claude-plugin/plugin.json" | head -1)"
[ -n "$version" ] || version="0.0.0"
min_macos="11.0"
if [ "$universal" = 1 ]; then archs="arm64 x86_64"; else archs="$(uname -m)"; fi

work="$(mktemp -d "${TMPDIR:-/tmp}/claude-progress-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# compile <output> <source> [frameworks...]: one slice per arch, then glued.
compile() {
    local output="$1" source="$2"; shift 2
    local slices=()
    for arch in $archs; do
        xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos$min_macos" \
            -o "$work/$(basename "$output").$arch" "$source" "$@"
        slices+=("$work/$(basename "$output").$arch")
    done
    if [ "${#slices[@]}" -gt 1 ]; then
        xcrun lipo -create -output "$output" "${slices[@]}"
    else
        cp "${slices[0]}" "$output"
    fi
}

mkdir -p "$out"
app="$out/Claude Progress.app"
res="$app/Contents/Resources"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$res"

echo "Building the widget ($archs)..."
compile "$app/Contents/MacOS/ClaudeProgress" "$mod/widget/ProgressWidget.swift" -framework AppKit
sed "s/__VERSION__/$version/g" "$here/Info.plist" > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# The icon is drawn by the widget itself, so it always matches its colors.
"$app/Contents/MacOS/ClaudeProgress" --render-icon "$work/AppIcon.iconset"
iconutil -c icns -o "$res/AppIcon.icns" "$work/AppIcon.iconset"

echo "Building the terminal hook ($archs)..."
compile "$app/Contents/Helpers/progress-hook" "$mod/cli/progress-hook.swift"

# What setup.sh installs for each person: the mod (without Windows
# binaries or anything built), plus the scripts themselves.
ditto "$mod" "$res/task-progress-bar"
rm -rf "$res/task-progress-bar/.claude-plugin/types" "$res/task-progress-bar/last-error.txt" \
    "$res/task-progress-bar/widget/TaskProgressWidget.exe" "$res/task-progress-bar/widget/Claude Progress.app" \
    "$res/task-progress-bar/cli/progress-hook"
find "$res/task-progress-bar" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
cp "$here/setup.sh" "$here/settings.js" "$res/"
cp "$root/uninstall.command" "$res/uninstall.command"
chmod +x "$res/setup.sh" "$res/uninstall.command"
xattr -cr "$app"

# Inside out: the hook first, then the app, which seals everything in it.
if [ -n "$identity" ]; then
    echo "Signing with $identity..."
    sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
    # Ad-hoc: required to run on Apple silicon, and ties the app's
    # Info.plist to its code. (Not a Developer ID; nothing to notarize.)
    sign=(codesign --force --sign -)
fi
"${sign[@]}" "$app/Contents/Helpers/progress-hook"
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"

echo "Built v$version: $app"
