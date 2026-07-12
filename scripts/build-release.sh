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

identity_record_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"([^"]+)"[[:space:]]*$'
declare -a developer_id_hashes=()
declare -a developer_id_names=()
while IFS= read -r identity_record; do
  if [[ "$identity_record" =~ $identity_record_pattern ]]; then
    identity_hash="$(tr '[:lower:]' '[:upper:]' <<<"${BASH_REMATCH[1]}")"
    identity_name="${BASH_REMATCH[2]}"
    if [[ "$identity_name" == "Developer ID Application: "* \
      && "$identity_name" == *" ($DEVELOPMENT_TEAM)" ]]; then
      developer_id_hashes+=("$identity_hash")
      developer_id_names+=("$identity_name")
    fi
  fi
done < <(security find-identity -v -p codesigning 2>/dev/null || true)

if [[ -n "${DEVELOPER_ID_IDENTITY:-}" ]]; then
  requested_identity_hash="$(tr '[:lower:]' '[:upper:]' <<<"$DEVELOPER_ID_IDENTITY")"
  matching_identity_index=""
  matching_identity_count=0
  for index in "${!developer_id_hashes[@]}"; do
    if [[ "${developer_id_hashes[$index]}" == "$requested_identity_hash" \
      || "${developer_id_names[$index]}" == "$DEVELOPER_ID_IDENTITY" ]]; then
      matching_identity_index="$index"
      matching_identity_count=$((matching_identity_count + 1))
    fi
  done
  if [[ "$matching_identity_count" != "1" ]]; then
    echo "DEVELOPER_ID_IDENTITY must exactly equal one valid Developer ID Application name or SHA-1 for team $DEVELOPMENT_TEAM." >&2
    exit 2
  fi
  developer_id_identity="${developer_id_hashes[$matching_identity_index]}"
else
  developer_id_count="${#developer_id_hashes[@]}"
  if [[ "$developer_id_count" != "1" ]]; then
    echo "Expected exactly one Developer ID Application identity for team $DEVELOPMENT_TEAM; found $developer_id_count." >&2
    echo "Set DEVELOPER_ID_IDENTITY to the exact full identity name or SHA-1 if this Mac has multiple matching identities." >&2
    exit 2
  fi
  developer_id_identity="${developer_id_hashes[0]}"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/MoniArc-release.XXXXXX")"
archive_path="$work_dir/MoniArc.xcarchive"
app_path="$archive_path/Products/Applications/MoniArc.app"
submission_zip="$work_dir/MoniArc-notarization.zip"
dmg_stage="$work_dir/dmg-root"
working_dmg="$work_dir/MoniArc.dmg"
publish_dir=""

cleanup() {
  rm -rf "$work_dir"
  if [[ -n "$publish_dir" && -d "$publish_dir" ]]; then
    rm -rf "$publish_dir"
  fi
}
trap cleanup EXIT

verify_developer_id_signature() {
  local label="$1"
  local signature="$2"
  local expected_team="$3"
  local authority_count
  local team_count
  local timestamp_count
  local timestamp

  authority_count="$(/usr/bin/grep -Ec "^Authority=Developer ID Application: .+ \\($expected_team\\)$" <<<"$signature" || true)"
  team_count="$(/usr/bin/grep -Fxc "TeamIdentifier=$expected_team" <<<"$signature" || true)"
  timestamp_count="$(/usr/bin/grep -c '^Timestamp=' <<<"$signature" || true)"
  timestamp="$(sed -n 's/^Timestamp=//p' <<<"$signature")"

  if [[ "$authority_count" != "1" || "$team_count" != "1" ]]; then
    echo "$label is not signed by exactly one Developer ID Application certificate for team $expected_team." >&2
    exit 3
  fi
  if [[ "$timestamp_count" != "1" || -z "$timestamp" || "$timestamp" == "none" ]]; then
    echo "$label is missing a trusted signing timestamp." >&2
    exit 3
  fi
}

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
candidate_dir="$work_dir/release-candidate"
candidate_dmg="$candidate_dir/$(basename "$dmg_path")"
candidate_checksum="$candidate_dir/$(basename "$checksums_path")"
mkdir -p "$candidate_dir"

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
verify_developer_id_signature "Release app" "$app_signature" "$DEVELOPMENT_TEAM"
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
verify_developer_id_signature "Release DMG" "$dmg_signature" "$DEVELOPMENT_TEAM"
xcrun notarytool submit "$working_dmg" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$working_dmg"
xcrun stapler validate "$working_dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$working_dmg"

ditto "$working_dmg" "$candidate_dmg"
(
  cd "$candidate_dir"
  shasum -a 256 "$(basename "$candidate_dmg")" >"$(basename "$candidate_checksum")"
)
cat "$candidate_checksum"
"$root/scripts/verify-release.sh" "$candidate_dmg"

# Nothing under the public build path is replaced until the complete candidate
# has passed signature, notarization, structure, version and checksum checks.
publish_dir="$(mktemp -d "$build_dir/.MoniArc-publish.XXXXXX")"
ditto "$candidate_dmg" "$publish_dir/$(basename "$dmg_path")"
ditto "$candidate_checksum" "$publish_dir/$(basename "$checksums_path")"
(
  cd "$publish_dir"
  shasum -a 256 -c "$(basename "$checksums_path")"
)
mv -f "$publish_dir/$(basename "$dmg_path")" "$dmg_path"
mv -f "$publish_dir/$(basename "$checksums_path")" "$checksums_path"
rmdir "$publish_dir"
publish_dir=""

echo "Release artifact: $dmg_path"
echo "Checksum file: $checksums_path"
