#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-$root/build}"

for command in xcodegen xcodebuild codesign hdiutil ditto xattr; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 2
  fi
done

mkdir -p "$build_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/MoniArc-local-package.XXXXXX")"
derived_data="${DERIVED_DATA:-$work_dir/DerivedData}"
app_path="$derived_data/Build/Products/Release/MoniArc.app"
stage="$work_dir/dmg-root"
working_dmg="$work_dir/MoniArc-preview.dmg"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$stage"
cd "$root"
"$root/scripts/check-release-readiness.sh"
xcodebuild -quiet \
  -project MoniArc.xcodeproj \
  -scheme MoniArc \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  build CODE_SIGNING_ALLOWED=NO

version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
dmg_path="$build_dir/MoniArc-$version-unsigned-preview.dmg"

# Generated bundles may acquire Finder or File Provider metadata while they are
# built inside a synchronized workspace. Remove it only from this disposable
# build product before applying the local ad-hoc signature.
xattr -cr "$app_path"
codesign --force --deep --sign - --options runtime "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
if ! codesign -dv --verbose=4 "$app_path" 2>&1 | grep 'flags=.*runtime' >/dev/null; then
  echo "Local preview app is missing the Hardened Runtime flag." >&2
  exit 3
fi
ditto "$app_path" "$stage/MoniArc.app"
ln -s /Applications "$stage/Applications"
test -d "$stage/MoniArc.app"
test -L "$stage/Applications"
test "$(plutil -extract CFBundleIdentifier raw "$stage/MoniArc.app/Contents/Info.plist")" = "com.moniarc.MoniArc"
codesign --verify --deep --strict --verbose=2 "$stage/MoniArc.app"
hdiutil create \
  -volname "MoniArc Preview" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$working_dmg" >/dev/null
hdiutil verify "$working_dmg" >/dev/null

rm -f "$dmg_path"
ditto "$working_dmg" "$dmg_path"
hdiutil verify "$dmg_path" >/dev/null

echo "Ad-hoc signed local packaging preview: $dmg_path"
echo "Do not distribute this file. Use build-release.sh for a signed and notarized release."
