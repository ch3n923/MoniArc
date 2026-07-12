#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

required_files=(
  LICENSE
  PRIVACY.md
  NOTICE.md
  CONTRIBUTING.md
  SECURITY.md
  CHANGELOG.md
  README.md
  docs/DISTRIBUTION.md
  MoniArc/PrivacyInfo.xcprivacy
  scripts/build-local-dmg.sh
  scripts/verify-built-app.sh
  .github/workflows/ci.yml
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/feature_request.yml
  .github/pull_request_template.md
)

for path in "${required_files[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Required repository file is missing: $path" >&2
    exit 3
  fi
done

plutil -lint MoniArc/Info.plist >/dev/null
plutil -lint MoniArc/PrivacyInfo.xcprivacy >/dev/null
bash -n scripts/build-local-dmg.sh scripts/build-release.sh scripts/verify-built-app.sh scripts/verify-release.sh
xcodegen generate >/dev/null

settings="$(xcodebuild -project MoniArc.xcodeproj -scheme MoniArc -configuration Release -showBuildSettings 2>/dev/null)"

assert_setting() {
  local key="$1"
  local expected="$2"
  if ! grep -Eq "^[[:space:]]*$key = $expected$" <<<"$settings"; then
    echo "Release setting mismatch: expected $key = $expected" >&2
    exit 4
  fi
}

assert_setting PRODUCT_NAME MoniArc
assert_setting PRODUCT_BUNDLE_IDENTIFIER com.zhengzipeng.MoniArc
assert_setting ENABLE_HARDENED_RUNTIME YES
assert_setting ENABLE_APP_SANDBOX NO

marketing_version="$(awk '/MARKETING_VERSION/ && !found { print $3; found = 1 }' <<<"$settings")"
build_number="$(awk '/CURRENT_PROJECT_VERSION/ && !found { print $3; found = 1 }' <<<"$settings")"
if [[ ! "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "MARKETING_VERSION is not a valid semantic release version: $marketing_version" >&2
  exit 4
fi
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "CURRENT_PROJECT_VERSION must be a positive integer: $build_number" >&2
  exit 4
fi

if rg -n -i \
  'codex([_-]| )?(halo|island)' \
  . \
  --glob '!MoniArc.xcodeproj/**' \
  --glob '!scripts/check-release-readiness.sh' >/dev/null; then
  echo "Legacy product naming remains in the repository." >&2
  exit 5
fi

echo "MoniArc release metadata and repository files are ready."
