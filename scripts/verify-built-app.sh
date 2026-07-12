#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "Usage: $0 /path/to/MoniArc.app" >&2
  exit 2
fi

info="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/MoniArc"
privacy_manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"

test -f "$info"
test -x "$binary"
test -f "$privacy_manifest"

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw "$info")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Bundle metadata mismatch for $key: expected '$expected', found '$actual'" >&2
    exit 3
  fi
}

assert_plist_value CFBundleName MoniArc
assert_plist_value CFBundleIdentifier com.moniarc.MoniArc
assert_plist_value LSUIElement true

marketing_version="$(plutil -extract CFBundleShortVersionString raw "$info")"
build_number="$(plutil -extract CFBundleVersion raw "$info")"
if [[ ! "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Invalid CFBundleShortVersionString: $marketing_version" >&2
  exit 3
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid CFBundleVersion: $build_number" >&2
  exit 3
fi

plutil -lint "$privacy_manifest" >/dev/null

privacy_api="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType' "$privacy_manifest")"
privacy_reason="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0' "$privacy_manifest")"
if [[ "$privacy_api" != "NSPrivacyAccessedAPICategoryUserDefaults" || "$privacy_reason" != "CA92.1" ]]; then
  echo "Privacy manifest is missing the app-only UserDefaults reason CA92.1." >&2
  exit 3
fi

architectures="$(lipo -archs "$binary")"
for architecture in arm64 x86_64; do
  if ! grep -qw "$architecture" <<<"$architectures"; then
    echo "Release binary is missing required architecture: $architecture" >&2
    exit 3
  fi
done

if find "$app" -type d -name '*.xctest' -print -quit | grep -q .; then
  echo "Release app unexpectedly contains a test bundle." >&2
  exit 4
fi

if find "$app" -type f -name '*.debug.dylib' -print -quit | grep -q .; then
  echo "Release app unexpectedly contains a debug dylib." >&2
  exit 4
fi

if strings "$binary" | /usr/bin/grep -E 'MoniArc Harness|HarnessController|\+59[.]999s' >/dev/null; then
  echo "Release binary unexpectedly contains Debug Harness content." >&2
  exit 5
fi

if strings "$binary" | /usr/bin/grep -E 'auth[.]json' >/dev/null; then
  echo "Release binary unexpectedly references auth.json." >&2
  exit 5
fi

file "$binary"
echo "MoniArc release bundle contents are valid."
