#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$project_root/build"
scheme="Foresight QA"

license_check="$(xcodebuild -license check 2>&1 || true)"
if [[ "$license_check" == *"not agreed to the Xcode license"* ]] || [[ "$license_check" == *"not agreed to the Xcode license agreements"* ]]; then
  print "Xcode's license has not been accepted. Run: sudo xcodebuild -license accept"
  exit 2
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  print "Xcode is unavailable, or its license has not been accepted. Run: sudo xcodebuild -license accept"
  exit 2
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  print "XcodeGen is required. Install it with: brew install xcodegen"
  exit 2
fi

cd "$project_root"
xcodegen generate --spec project.yml

# CI can pin a simulator with SIMULATOR_UDID, skip the final install/launch with
# VERIFY_SKIP_LAUNCH=1, and keep test results with RESULT_BUNDLE_PATH.
simulator_udid="${SIMULATOR_UDID:-}"
if [[ -z "$simulator_udid" ]]; then
  devices_json="$(xcrun simctl list devices available --json)"
  simulator_udid="$(print -r -- "$devices_json" | jq -r '
    .devices
    | to_entries
    | sort_by(.key)
    | reverse
    | map(.value[] | select(.isAvailable == true and (.name | startswith("iPhone"))))
    | first
    | .udid // empty
  ')"
fi

if [[ -z "$simulator_udid" ]]; then
  print "No available iPhone simulator was found. Install an iOS simulator runtime in Xcode."
  exit 3
fi

xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b

xcodebuild build \
  -project Foresight.xcodeproj \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

result_bundle_args=()
if [[ -n "${RESULT_BUNDLE_PATH:-}" ]]; then
  rm -rf "$RESULT_BUNDLE_PATH"
  result_bundle_args=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi

xcodebuild test \
  -project Foresight.xcodeproj \
  -scheme "$scheme" \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  "${result_bundle_args[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

if [[ -n "${VERIFY_SKIP_LAUNCH:-}" ]]; then
  print "Build and tests passed on $simulator_udid"
  exit 0
fi

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Foresight QA.app"
xcrun simctl install "$simulator_udid" "$app_path"
xcrun simctl launch "$simulator_udid" com.foresight.journal.testing
print "Foresight QA is running on $simulator_udid"
