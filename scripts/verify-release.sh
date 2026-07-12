#!/usr/bin/env bash
set -euo pipefail

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
    codesign -dv --verbose=4 "$artifact" 2>&1 | grep 'flags=.*runtime' >/dev/null
    spctl --assess --type execute --verbose=4 "$artifact"
    xcrun stapler validate "$artifact"
    ;;
  *.dmg)
    hdiutil verify "$artifact"
    codesign --verify --verbose=2 "$artifact"
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

    codesign --verify --deep --strict --verbose=2 "$mount_point/MoniArc.app"
    codesign -dv --verbose=4 "$mount_point/MoniArc.app" 2>&1 | grep 'flags=.*runtime' >/dev/null
    spctl --assess --type execute --verbose=4 "$mount_point/MoniArc.app"
    shasum -a 256 "$artifact"
    ;;
  *)
    echo "Expected a .app or .dmg artifact." >&2
    exit 2
    ;;
esac
