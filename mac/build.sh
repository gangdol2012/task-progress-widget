#!/bin/bash
# Builds the macOS widget ("Claude Progress.app") and the terminal hook
# (progress-hook) from source. Needs Apple's command line tools
# (xcode-select --install) or Xcode.
#
#   mac/build.sh [--universal] [--out DIR]
#
# --universal builds for both Apple silicon and Intel Macs (for releases);
# without it, only for this Mac. Output goes to build/mac unless --out says
# otherwise.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mod="$root/task-progress-bar"
out="$root/build/mac"
universal=0
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) universal=1 ;;
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
rm -rf "$app" "$out/progress-hook"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "Building the widget ($archs)..."
compile "$app/Contents/MacOS/ClaudeProgress" "$mod/widget/ProgressWidget.swift" -framework AppKit
sed "s/__VERSION__/$version/g" "$here/Info.plist" > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# The icon is drawn by the widget itself, so it always matches its colors.
"$app/Contents/MacOS/ClaudeProgress" --render-icon "$work/AppIcon.iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$work/AppIcon.iconset"

echo "Building the terminal hook ($archs)..."
compile "$out/progress-hook" "$mod/cli/progress-hook.swift"

# Ad-hoc signatures: required to run on Apple silicon, and they tie the
# app's Info.plist to its code. (Not a Developer ID; see the README.)
codesign --force --sign - "$out/progress-hook"
codesign --force --sign - "$app"

echo "Built v$version:"
echo "    $app"
echo "    $out/progress-hook"
