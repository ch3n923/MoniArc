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
  scripts/build-release.sh
  scripts/verify-built-app.sh
  scripts/verify-release.sh
  MoniArc.xcodeproj/xcshareddata/xcschemes/MoniArc.xcscheme
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

for script in scripts/*.sh; do
  if [[ ! -x "$script" ]]; then
    echo "Release script is not executable: $script" >&2
    exit 3
  fi
done

plutil -lint MoniArc/Info.plist >/dev/null
plutil -lint MoniArc/PrivacyInfo.xcprivacy >/dev/null
bash -n scripts/build-local-dmg.sh scripts/build-release.sh scripts/check-release-readiness.sh scripts/verify-built-app.sh scripts/verify-release.sh

privacy_api="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPIType' MoniArc/PrivacyInfo.xcprivacy)"
privacy_reason="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes:0:NSPrivacyAccessedAPITypeReasons:0' MoniArc/PrivacyInfo.xcprivacy)"
if [[ "$privacy_api" != "NSPrivacyAccessedAPICategoryUserDefaults" || "$privacy_reason" != "CA92.1" ]]; then
  echo "Privacy manifest is missing the app-only UserDefaults reason CA92.1." >&2
  exit 3
fi

generated_root="$(mktemp -d "${TMPDIR:-/tmp}/MoniArc-project-check.XXXXXX")"
cleanup() {
  rm -rf "$generated_root"
}
trap cleanup EXIT

cp project.yml "$generated_root/project.yml"
ln -s "$root/MoniArc" "$generated_root/MoniArc"
ln -s "$root/MoniArcTests" "$generated_root/MoniArcTests"
xcodegen generate --spec "$generated_root/project.yml" --project "$generated_root" --quiet

if ! cmp -s MoniArc.xcodeproj/project.pbxproj "$generated_root/MoniArc.xcodeproj/project.pbxproj"; then
  echo "MoniArc.xcodeproj is out of sync with project.yml; run xcodegen generate and commit the result." >&2
  exit 3
fi

shared_scheme="MoniArc.xcodeproj/xcshareddata/xcschemes/MoniArc.xcscheme"
generated_scheme="$generated_root/$shared_scheme"
if [[ ! -f "$generated_scheme" ]] || ! cmp -s "$shared_scheme" "$generated_scheme"; then
  echo "The shared MoniArc scheme is out of sync with project.yml; run xcodegen generate and commit the result." >&2
  exit 3
fi

settings="$(xcodebuild -project "$generated_root/MoniArc.xcodeproj" -scheme MoniArc -configuration Release -showBuildSettings 2>/dev/null)"

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

if /usr/bin/grep -rIinE \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=.swiftpm \
  --exclude-dir=build \
  --exclude-dir=DerivedData \
  --exclude-dir=MoniArc.xcodeproj \
  --exclude=check-release-readiness.sh \
  'codex([_-]| )?(halo|island)' . >/dev/null; then
  echo "Legacy product naming remains in the repository." >&2
  exit 5
fi

echo "MoniArc release metadata and repository files are ready."
