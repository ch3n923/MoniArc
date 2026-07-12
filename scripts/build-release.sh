#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Set DEVELOPMENT_TEAM to your Apple Developer Team ID." >&2
  exit 2
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-$root/build}"

for command in xcodegen xcodebuild codesign xcrun hdiutil ditto security; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is unavailable: $command" >&2
    exit 2
  fi
done

mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"

if [[ ! "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "DEVELOPMENT_TEAM must be a 10-character Apple Team ID." >&2
  exit 2
fi

identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  developer_id_identity="$DEVELOPER_ID_IDENTITY"
  matching_identities="$(grep -F "$developer_id_identity" <<<"$identities" || true)"
  matching_identity_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$matching_identities")"
  if [[ "$matching_identity_count" != "1" ]]; then
    echo "DEVELOPER_ID_IDENTITY must match exactly one valid local code-signing identity." >&2
    exit 2
  fi
else
  developer_id_candidates="$(
    grep -F 'Developer ID Application:' <<<"$identities" \
      | grep -F "($DEVELOPMENT_TEAM)" || true
  )"
  developer_id_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$developer_id_candidates")"
  if [[ "$developer_id_count" != "1" ]]; then
    echo "Expected exactly one Developer ID Application identity for team $DEVELOPMENT_TEAM; found $developer_id_count." >&2
    echo "Set DEVELOPER_ID_IDENTITY explicitly if this Mac has multiple matching identities." >&2
    exit 2
  fi
  developer_id_identity="$(awk 'NF { print $2; exit }' <<<"$developer_id_candidates")"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/MoniArc-release.XXXXXX")"
archive_path="$work_dir/MoniArc.xcarchive"
app_path="$archive_path/Products/Applications/MoniArc.app"
submission_zip="$work_dir/MoniArc-notarization.zip"
dmg_stage="$work_dir/dmg-root"
working_dmg="$work_dir/MoniArc.dmg"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$dmg_stage"
cd "$root"
"$root/scripts/check-release-readiness.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/MoniArc/Info.plist" 2>/dev/null || true)"
if [[ "$version" == '$(MARKETING_VERSION)' || -z "$version" ]]; then
  build_settings="$(xcodebuild -project "$root/MoniArc.xcodeproj" -scheme MoniArc -configuration Release -showBuildSettings 2>/dev/null)"
  version="$(awk '/MARKETING_VERSION/ && !found { print $3; found = 1 }' <<<"$build_settings")"
fi

if [[ ! "$version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Unable to determine a valid release version: $version" >&2
  exit 2
fi

dmg_path="$build_dir/MoniArc-$version.dmg"
checksums_path="$build_dir/MoniArc-$version.sha256"
rm -f "$dmg_path" "$checksums_path"

xcodebuild -project MoniArc.xcodeproj \
  -scheme MoniArc \
  -configuration Release \
  -archivePath "$archive_path" \
  archive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$developer_id_identity" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

codesign --verify --deep --strict --verbose=2 "$app_path"
"$root/scripts/verify-built-app.sh" "$app_path"
app_signature="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if ! grep 'flags=.*runtime' <<<"$app_signature" >/dev/null; then
  echo "Release app is missing the Hardened Runtime flag." >&2
  exit 3
fi
for expected in \
  'Authority=Developer ID Application:' \
  "TeamIdentifier=$DEVELOPMENT_TEAM" \
  'Timestamp='; do
  if ! grep -F "$expected" <<<"$app_signature" >/dev/null; then
    echo "Release app signature is missing: $expected" >&2
    exit 3
  fi
done
ditto -c -k --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

ditto "$app_path" "$dmg_stage/MoniArc.app"
ln -s /Applications "$dmg_stage/Applications"
hdiutil create \
  -volname MoniArc \
  -srcfolder "$dmg_stage" \
  -ov \
  -format UDZO \
  "$working_dmg"

codesign --force --timestamp --sign "$developer_id_identity" "$working_dmg"
codesign --verify --verbose=2 "$working_dmg"
dmg_signature="$(codesign -dv --verbose=4 "$working_dmg" 2>&1)"
for expected in \
  'Authority=Developer ID Application:' \
  "TeamIdentifier=$DEVELOPMENT_TEAM" \
  'Timestamp='; do
  if ! grep -F "$expected" <<<"$dmg_signature" >/dev/null; then
    echo "Release DMG signature is missing: $expected" >&2
    exit 3
  fi
done
xcrun notarytool submit "$working_dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$working_dmg"
xcrun stapler validate "$working_dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$working_dmg"

ditto "$working_dmg" "$dmg_path"
(
  cd "$build_dir"
  shasum -a 256 "$(basename "$dmg_path")" >"$(basename "$checksums_path")"
)
cat "$checksums_path"
"$root/scripts/verify-release.sh" "$dmg_path"

echo "Release artifact: $dmg_path"
echo "Checksum file: $checksums_path"
