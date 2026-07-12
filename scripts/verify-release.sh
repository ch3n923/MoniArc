#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact="${1:-}"
if [[ -z "$artifact" || ! -e "$artifact" ]]; then
  echo "Usage: $0 /path/to/MoniArc.app-or.dmg" >&2
  exit 2
fi

mount_point=""
cleanup() {
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet || true
    rmdir "$mount_point" 2>/dev/null || true
  fi
}
trap cleanup EXIT

verify_developer_id_signature() {
  local label="$1"
  local signature="$2"
  local expected_team="${3:-}"
  local team_count
  local team
  local authority_count
  local timestamp_count
  local timestamp

  team_count="$(/usr/bin/grep -c '^TeamIdentifier=' <<<"$signature" || true)"
  team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
  if [[ "$team_count" != "1" || ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "$label signature must contain exactly one valid Apple TeamIdentifier." >&2
    exit 3
  fi
  if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
    echo "$label was signed by team $team, expected $expected_team." >&2
    exit 3
  fi

  authority_count="$(/usr/bin/grep -Ec "^Authority=Developer ID Application: .+ \\($team\\)$" <<<"$signature" || true)"
  timestamp_count="$(/usr/bin/grep -c '^Timestamp=' <<<"$signature" || true)"
  timestamp="$(sed -n 's/^Timestamp=//p' <<<"$signature")"
  if [[ "$authority_count" != "1" ]]; then
    echo "$label is not signed by exactly one Developer ID Application certificate for team $team." >&2
    exit 3
  fi
  if [[ "$timestamp_count" != "1" || -z "$timestamp" || "$timestamp" == "none" ]]; then
    echo "$label is missing a trusted signing timestamp." >&2
    exit 3
  fi

  printf '%s\n' "$team"
}

case "$artifact" in
  *.app)
    codesign --verify --deep --strict --verbose=2 "$artifact"
    "$root/scripts/verify-built-app.sh" "$artifact"
    signature="$(codesign -dv --verbose=4 "$artifact" 2>&1)"
    grep 'flags=.*runtime' <<<"$signature" >/dev/null
    verify_developer_id_signature "Release app" "$signature" >/dev/null
    spctl --assess --type execute --verbose=4 "$artifact"
    xcrun stapler validate "$artifact"
    ;;
  *.dmg)
    hdiutil verify "$artifact"
    codesign --verify --verbose=2 "$artifact"
    signature="$(codesign -dv --verbose=4 "$artifact" 2>&1)"
    dmg_team="$(verify_developer_id_signature "Release DMG" "$signature")"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$artifact"
    xcrun stapler validate "$artifact"

    mount_point="$(mktemp -d "${TMPDIR:-/tmp}/MoniArc-verify.XXXXXX")"
    hdiutil attach "$artifact" -nobrowse -readonly -mountpoint "$mount_point" -quiet

    if [[ ! -d "$mount_point/MoniArc.app" ]]; then
      echo "MoniArc.app is missing from the DMG." >&2
      exit 3
    fi
    if [[ ! -L "$mount_point/Applications" ]]; then
      echo "Applications shortcut is missing from the DMG." >&2
      exit 3
    fi
    if [[ "$(readlink "$mount_point/Applications")" != "/Applications" ]]; then
      echo "Applications shortcut does not target /Applications." >&2
      exit 3
    fi

    codesign --verify --deep --strict --verbose=2 "$mount_point/MoniArc.app"
    "$root/scripts/verify-built-app.sh" "$mount_point/MoniArc.app"
    app_signature="$(codesign -dv --verbose=4 "$mount_point/MoniArc.app" 2>&1)"
    grep 'flags=.*runtime' <<<"$app_signature" >/dev/null
    verify_developer_id_signature "Bundled app" "$app_signature" "$dmg_team" >/dev/null
    spctl --assess --type execute --verbose=4 "$mount_point/MoniArc.app"
    xcrun stapler validate "$mount_point/MoniArc.app"

    version="$(plutil -extract CFBundleShortVersionString raw "$mount_point/MoniArc.app/Contents/Info.plist")"
    if [[ "$(basename "$artifact")" != "MoniArc-$version.dmg" ]]; then
      echo "DMG filename does not match the bundled app version $version." >&2
      exit 3
    fi

    checksum_path="${artifact%.dmg}.sha256"
    if [[ ! -f "$checksum_path" ]]; then
      echo "Release checksum file is missing: $checksum_path" >&2
      exit 3
    fi
    (
      cd "$(dirname "$artifact")"
      shasum -a 256 -c "$(basename "$checksum_path")"
    )
    ;;
  *)
    echo "Expected a .app or .dmg artifact." >&2
    exit 2
    ;;
esac
