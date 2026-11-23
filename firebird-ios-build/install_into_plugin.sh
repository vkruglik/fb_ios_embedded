#!/usr/bin/env bash
# install_into_plugin.sh — put the output of build_firebird_ios.sh into the
# fb_ios_embedded plugin:
#   <ios-out>/xcframeworks/*.xcframework -> <plugin>/ios/Frameworks/
#   <ios-out>/assets/*                   -> <plugin>/assets/fb/
# <ios-out> may also be a release archive (.zip) with the same two folders.
#
# Usage: install_into_plugin.sh <ios-out directory | .zip> <plugin directory>
#
# After the set of frameworks changes, run `pod install` in the app:
# vendored_frameworks is a glob that CocoaPods expands only at pod install.
set -euo pipefail

SRC="${1:?usage: install_into_plugin.sh <ios-out | .zip> <plugin directory>}"
PLUGIN="${2:?usage: install_into_plugin.sh <ios-out | .zip> <plugin directory>}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$PLUGIN/pubspec.yaml" ] && grep -q '^name: fb_ios_embedded' "$PLUGIN/pubspec.yaml" \
  || die "$PLUGIN is not the fb_ios_embedded plugin"

if [ -f "$SRC" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  unzip -q "$SRC" -d "$TMP"
  SRC="$(dirname "$(find "$TMP" -type d -name xcframeworks | head -n1)")"
fi
[ -d "$SRC/xcframeworks" ] && [ -d "$SRC/assets" ] || die "no xcframeworks/ and assets/ in $SRC"

# The set the plugin requires (lib/fb_ios_embedded.dart); device slice, platform IOS.
for fw in Firebird FirebirdEngine FirebirdIntl ICUdata ICUuc ICUi18n; do
  bin="$SRC/xcframeworks/$fw.xcframework/ios-arm64/$fw.framework/$fw"
  [ -f "$bin" ] || die "no $fw.xcframework (ios-arm64 slice) in $SRC"
  if command -v vtool >/dev/null 2>&1; then
    vtool -show-build "$bin" | grep -q 'platform IOS$' || die "$fw is not platform IOS"
  fi
done
for a in firebird.msg fbintl.conf icu_version.txt plugin_frameworks.txt; do
  [ -f "$SRC/assets/$a" ] || die "no asset $a in $SRC/assets"
done

mkdir -p "$PLUGIN/ios/Frameworks" "$PLUGIN/assets/fb"
find "$PLUGIN/ios/Frameworks" -mindepth 1 -maxdepth 1 -name '*.xcframework' -exec rm -rf {} +
find "$PLUGIN/assets/fb" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
cp -R "$SRC"/xcframeworks/*.xcframework "$PLUGIN/ios/Frameworks/"
cp "$SRC"/assets/* "$PLUGIN/assets/fb/"

echo "Installed into $PLUGIN:"
echo "  frameworks: $(ls "$PLUGIN/ios/Frameworks" | grep -c xcframework), $(du -sh "$PLUGIN/ios/Frameworks" | cut -f1)"
echo "  ICU $(cat "$PLUGIN/assets/fb/icu_version.txt"); plugins: $(tr '\n' ' ' < "$PLUGIN/assets/fb/plugin_frameworks.txt")"
