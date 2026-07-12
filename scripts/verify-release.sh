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

case "$artifact" in
  *.app)
    codesign --verify --deep --strict --verbose=2 "$artifact"
    "$root/scripts/verify-built-app.sh" "$artifact"
    signature="$(codesign -dv --verbose=4 "$artifact" 2>&1)"
    grep 'flags=.*runtime' <<<"$signature" >/dev/null
    grep -F 'Authority=Developer ID Application:' <<<"$signature" >/dev/null
    grep -F 'Timestamp=' <<<"$signature" >/dev/null
    grep -F 'TeamIdentifier=' <<<"$signature" >/dev/null
    spctl --assess --type execute --verbose=4 "$artifact"
    xcrun stapler validate "$artifact"
    ;;
  *.dmg)
    hdiutil verify "$artifact"
    codesign --verify --verbose=2 "$artifact"
    signature="$(codesign -dv --verbose=4 "$artifact" 2>&1)"
    grep -F 'Authority=Developer ID Application:' <<<"$signature" >/dev/null
    grep -F 'Timestamp=' <<<"$signature" >/dev/null
    dmg_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature")"
    if [[ -z "$dmg_team" ]]; then
      echo "Release DMG signature has no TeamIdentifier." >&2
      exit 3
    fi
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
    grep -F 'Authority=Developer ID Application:' <<<"$app_signature" >/dev/null
    grep -F 'Timestamp=' <<<"$app_signature" >/dev/null
    app_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_signature")"
    if [[ "$app_team" != "$dmg_team" ]]; then
      echo "App and DMG were signed by different teams." >&2
      exit 3
    fi
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
