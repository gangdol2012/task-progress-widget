#!/bin/bash
# Builds the Mac release into dist/:
#   Claude-Progress-<version>.pkg            the installer most people want
#   task-progress-widget-v<version>-mac.zip  the same app, with install.command
# Both hold a ready-made app for Apple silicon and Intel Macs.
#
#   ./make-release-mac.sh [--notarize PROFILE]
#
# With --notarize, the app is signed with your Developer ID Application
# certificate and the .pkg with your Developer ID Installer certificate,
# both are notarized by Apple with the notarytool keychain profile PROFILE
# (made once with `xcrun notarytool store-credentials`), and the tickets
# are stapled, so macOS opens them without warnings. Set APP_IDENTITY or
# PKG_IDENTITY to pick a certificate when you have more than one. Without
# --notarize everything is ad-hoc signed and unsigned: fine for testing on
# this Mac, not for handing out.

set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
profile=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notarize) profile="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/task-progress-bar/.claude-plugin/plugin.json" | head -1)"
build="$root/build/mac-release"
stage="$build/task-progress-widget"
app="$build/bin/Claude Progress.app"
zip="$root/dist/task-progress-widget-v$version-mac.zip"
pkg="$root/dist/Claude-Progress-$version.pkg"
pkg_id="io.github.ohmygoditisme.claude-progress.pkg"
rm -rf "$build" "$zip" "$pkg"
mkdir -p "$build" "$root/dist"

fail() { echo "$*" >&2; exit 1; }

# Claude refuses a mod that fails its validator, silently, so check first.
# Uses `claude` on PATH, or the copy the Claude desktop app ships.
claude="$(command -v claude || true)"
if [ -z "$claude" ]; then
    claude="$(ls -t "$HOME/Library/Application Support/Claude/claude-code"/*/*/claude.app/Contents/MacOS/claude 2>/dev/null | head -1 || true)"
fi
[ -n "$claude" ] || fail "Claude Code not found; can't validate the mod"
echo "Validating the mod..."
"$claude" plugin validate "$root/task-progress-bar" >/dev/null \
    || fail "The mod failed 'claude plugin validate'; fix it before releasing"

# The Windows widget's About line shows its own VERSION (the Mac app takes
# its version from plugin.json by itself); it must match the mod's.
widget_version="$(sed -n 's/^VERSION = "\([^"]*\)".*/\1/p' "$root/task-progress-bar/widget/progress_widget.py" | head -1)"
[ "$widget_version" = "$version" ] \
    || fail "progress_widget.py has VERSION = \"$widget_version\" but plugin.json says $version; make them match"

app_identity="" pkg_identity=""
if [ -n "$profile" ]; then
    app_identity="${APP_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
    pkg_identity="${PKG_IDENTITY:-$(security find-identity -v -p basic | sed -n 's/.*"\(Developer ID Installer: .*\)"/\1/p' | head -1)}"
    [ -n "$app_identity" ] || fail "No Developer ID Application certificate in your keychain"
    [ -n "$pkg_identity" ] || fail "No Developer ID Installer certificate in your keychain"
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || fail "notarytool can't use the keychain profile \"$profile\" (make it with: xcrun notarytool store-credentials $profile ...)"
fi

# notarize <file>: send it to Apple, wait for the verdict, staple the ticket.
notarize() {
    local file="$1" upload="$1" result="$build/notary-$(basename "$1").json"
    if [ -d "$file" ]; then  # an app goes up as a ZIP; the ticket goes on the app
        upload="$build/notary-upload.zip"
        ditto -c -k --keepParent "$file" "$upload"
    fi
    echo "Notarizing $(basename "$file") (usually a few minutes)..."
    xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json > "$result" || true
    local status id
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
    id="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo "")"
    if [ "$status" != "Accepted" ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || cat "$result" >&2
        fail "Apple did not accept $(basename "$file") (status: $status)"
    fi
    xcrun stapler staple "$file" >/dev/null
    rm -f "$build/notary-upload.zip"
}

# The app: universal, carrying the mod, the hook and the setup scripts.
if [ -n "$app_identity" ]; then
    "$root/mac/build.sh" --universal --sign "$app_identity" --out "$build/bin"
    notarize "$app"
    spctl --assess --type execute "$app" || fail "macOS doesn't accept the notarized app"
else
    "$root/mac/build.sh" --universal --out "$build/bin"
fi

# The ZIP: the app plus the scripts, for install.command.
mkdir -p "$stage/mac"
cp "$root/install.command" "$root/uninstall.command" "$root/README.md" "$root/LICENSE" "$stage/"
cp "$root/mac/build.sh" "$root/mac/Info.plist" "$root/mac/settings.js" "$root/mac/setup.sh" "$stage/mac/"
ditto "$root/mac/pkg" "$stage/mac/pkg"
ditto "$root/task-progress-bar" "$stage/task-progress-bar"
rm -rf "$stage/task-progress-bar/.claude-plugin/types" "$stage/task-progress-bar/last-error.txt" \
    "$stage/task-progress-bar/widget/TaskProgressWidget.exe" "$stage/task-progress-bar/cli/progress-hook"
find "$stage" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
ditto "$app" "$stage/task-progress-bar/widget/Claude Progress.app"
# No Finder metadata in the ZIP (it would unzip as __MACOSX clutter); the
# app's stapled ticket lives inside it, not in metadata.
xattr -cr "$stage"
(cd "$build" && ditto -c -k --norsrc --noextattr --keepParent task-progress-widget "$zip")
echo "Built $zip"

# The .pkg: the app in /Applications, then setup.sh for the person installing.
mkdir -p "$build/pkgroot/Applications"
ditto "$app" "$build/pkgroot/Applications/Claude Progress.app"
pkgbuild --analyze --root "$build/pkgroot" "$build/component.plist" >/dev/null
# Install exactly in /Applications, not wherever another copy happens to be.
plutil -replace 0.BundleIsRelocatable -bool NO "$build/component.plist"
pkgbuild --root "$build/pkgroot" --component-plist "$build/component.plist" \
    --identifier "$pkg_id" --version "$version" --install-location / \
    --scripts "$root/mac/pkg/scripts" "$build/component.pkg" >/dev/null
sed "s/__VERSION__/$version/g" "$root/mac/pkg/distribution.xml" > "$build/distribution.xml"
sign_pkg=()
[ -n "$pkg_identity" ] && sign_pkg=(--sign "$pkg_identity" --timestamp)
productbuild --distribution "$build/distribution.xml" --resources "$root/mac/pkg/resources" \
    --package-path "$build" ${sign_pkg[@]+"${sign_pkg[@]}"} "$pkg" >/dev/null
if [ -n "$profile" ]; then
    notarize "$pkg"
    spctl --assess --type install "$pkg" || fail "macOS doesn't accept the notarized installer"
fi
echo "Built $pkg"
