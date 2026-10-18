#!/bin/zsh
set -euo pipefail

# Builds Foresight and installs it on a connected iPhone, signed with your Apple team. Works with a
# free Apple account; those installs stop opening after 7 days, so run this again each week (the
# journal survives a reinstall).
#
#   ./Scripts/install-on-iphone.sh [--team TEAMID] [--device NAME|UDID] [--release] [--no-app-group]
#
# The first run writes Config/Signing.local.xcconfig (gitignored) with your team ID and a bundle ID
# prefix of your own, and later runs reuse it. Without --team, it uses the team in that file, or the
# one team Xcode is signed in to. --release installs "Foresight" instead of "Foresight QA" (the QA
# build adds sample history in Settings). --no-app-group turns off the App Group the widget reads the
# journal through, for a team that can't register one; pick it before you start journaling.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
local_config="$project_root/Config/Signing.local.xcconfig"
derived_data="$project_root/build/device"
scheme="Foresight QA"

team_id=""
device_query=""
configuration="Debug"
app_name="Foresight QA"
app_group=1

while (( $# > 0 )); do
  case "$1" in
    --team) team_id="${2:?--team needs a team ID}"; shift 2 ;;
    --device) device_query="${2:?--device needs a name or UDID}"; shift 2 ;;
    --release) configuration="Release"; app_name="Foresight"; shift ;;
    --no-app-group) app_group=0; shift ;;
    -h|--help) sed -n '4,15p' "$0"; exit 0 ;;
    *) print "Unknown option: $1"; exit 2 ;;
  esac
done

for tool in xcodebuild xcodegen jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print "$tool is required. Install Xcode, then: brew install xcodegen jq"
    exit 2
  fi
done

# MARK: Team

config_value() {
  [[ -f "$local_config" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]]*).*/\\1/p" "$local_config" | tail -n 1
}

if [[ -z "$team_id" ]]; then
  team_id="$(config_value DEVELOPMENT_TEAM)"
  [[ "$team_id" == "YOURTEAMID" ]] && team_id=""
fi
# Team IDs in the subjects (OU) of the Apple Development certificates Xcode made for you.
certificate_teams() {
  security find-certificate -a -c "Apple Development" -p 2>/dev/null | awk '
    /BEGIN CERTIFICATE/ { pem = "" }
    { pem = pem $0 "\n" }
    /END CERTIFICATE/ { cmd = "openssl x509 -noout -subject"; printf "%s", pem | cmd; close(cmd) }' \
    | sed -n -E 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | sort -u || true
}

if [[ -z "$team_id" ]]; then
  # Xcode lists the teams of every account in Settings > Accounts here. The setting isn't
  # documented, so fall back to the signing certificates.
  teams=("${(@f)$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -n -E 's/.*teamID = "?([A-Z0-9]{10})"?;.*/\1/p' | sort -u || true)}")
  teams=(${teams:#})
  if (( ${#teams} == 0 )); then
    teams=("${(@f)$(certificate_teams)}")
    teams=(${teams:#})
  fi
  if (( ${#teams} == 1 )); then
    team_id="${teams[1]}"
  elif (( ${#teams} > 1 )); then
    print "Found more than one team (${teams[*]}). Pick one with --team."
    exit 2
  else
    print "Couldn't find your team. Sign in under Xcode > Settings > Accounts, or pass --team."
    exit 2
  fi
fi
if [[ ! "$team_id" =~ '^[A-Z0-9]{10}$' ]]; then
  print "\"$team_id\" doesn't look like a team ID (10 letters and digits)."
  exit 2
fi

if [[ ! -f "$local_config" ]]; then
  # Bundle IDs and App Group IDs are unique across all Apple teams, so take a prefix that's yours.
  # Changing it later installs a separate app with an empty journal.
  {
    print "// Written by Scripts/install-on-iphone.sh. Gitignored: your team stays out of the repo."
    print ""
    print "DEVELOPMENT_TEAM = $team_id"
    print "CODE_SIGNING_ALLOWED = YES"
    print "BUNDLE_ID_PREFIX = com.foresight.${(L)team_id}"
    if (( ! app_group )); then
      print ""
      print "// No App Group: the journal stays in the app and the widget asks to open Foresight."
      print "FORESIGHT_APP_ENTITLEMENTS ="
      print "FORESIGHT_WIDGET_ENTITLEMENTS ="
    fi
  } > "$local_config"
  print "Wrote Config/Signing.local.xcconfig for team $team_id."
else
  configured_team="$(config_value DEVELOPMENT_TEAM)"
  if [[ "$configured_team" != "$team_id" ]]; then
    print "Config/Signing.local.xcconfig signs with team ${configured_team:-(none)}, not $team_id. Edit or delete it, then run this again."
    exit 2
  fi
  if (( ! app_group )) && ! grep -q -E '^[[:space:]]*FORESIGHT_APP_ENTITLEMENTS[[:space:]]*=[[:space:]]*$' "$local_config"; then
    print "--no-app-group only applies to a new Config/Signing.local.xcconfig. Uncomment the FORESIGHT_*_ENTITLEMENTS lines in it instead."
    exit 2
  fi
fi

# MARK: iPhone

devices_json="$(mktemp)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null
# Paired iPhones and iPads, plugged-in ones first. tunnelState can read "disconnected" for a phone
# on a cable until Xcode opens a tunnel, so go by the cable instead.
matches="$(jq -c --arg q "$device_query" '
  [.result.devices[]
   | select(.hardwareProperties.platform == "iOS" and .hardwareProperties.reality == "physical")
   | select((.connectionProperties.pairingState // "paired") == "paired")
   | select($q == "" or .deviceProperties.name == $q or .hardwareProperties.udid == $q or .identifier == $q)]
  | sort_by(.connectionProperties.transportType != "wired")' "$devices_json")"
wired_count="$(jq '[.[] | select(.connectionProperties.transportType == "wired")] | length' <<< "$matches")"
match_count="$(jq 'length' <<< "$matches")"
if (( match_count == 0 )); then
  print "No iPhone found${device_query:+ matching \"$device_query\"}. Connect it with a cable, unlock it, and tap Trust if it asks."
  exit 3
fi
if (( match_count > 1 && wired_count != 1 )) && [[ -z "$device_query" ]]; then
  print "More than one device could be the iPhone. Plug in just the one you want, or pick it with --device:"
  jq -r '.[] | "  \(.deviceProperties.name)  iOS \(.deviceProperties.osVersionNumber // "?")  \(.connectionProperties.transportType // "not connected")  \(.hardwareProperties.udid)"' <<< "$matches"
  exit 3
fi
device="$(jq -c 'first' <<< "$matches")"

device_udid="$(jq -r '.hardwareProperties.udid' <<< "$device")"
device_name="$(jq -r '.deviceProperties.name' <<< "$device")"
os_version="$(jq -r '.deviceProperties.osVersionNumber // "unknown"' <<< "$device")"
developer_mode="$(jq -r '.deviceProperties.developerModeStatus // "unknown"' <<< "$device")"
print "Installing $app_name on $device_name (iOS $os_version) with team $team_id."

if [[ "$os_version" =~ '^[0-9]+' ]] && (( ${MATCH} < 26 )); then
  print "Foresight needs iOS 26 or later. Update the iPhone in Settings > General > Software Update."
  exit 3
fi
if [[ "$developer_mode" == "disabled" ]]; then
  print "Turn on Developer Mode on the iPhone (Settings > Privacy & Security > Developer Mode), let it restart, then run this again."
  exit 3
fi

# MARK: Build and install

cd "$project_root"
xcodegen generate --spec project.yml
if ! git diff --quiet -- Foresight.xcodeproj 2>/dev/null; then
  print "Note: regenerating changed Foresight.xcodeproj. That's harmless for the install; discard it with git checkout -- Foresight.xcodeproj."
fi

# Automatic signing registers the iPhone, the app IDs and the App Group with your team.
xcodebuild build \
  -project Foresight.xcodeproj \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "id=$device_udid" \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

app_path="$derived_data/Build/Products/$configuration-iphoneos/$app_name.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
xcrun devicectl device install app --device "$device_udid" "$app_path"

if ! launch_output="$(xcrun devicectl device process launch --device "$device_udid" "$bundle_id" 2>&1)"; then
  print ""
  if [[ "${(L)launch_output}" == *trust* ]]; then
    print "$app_name is installed. The first time, iOS won't open it until you trust your developer profile:"
    print "Settings > General > VPN & Device Management > your Apple account > Trust. Then open $app_name."
    exit 0
  fi
  if [[ "${(L)launch_output}" == *lock* ]]; then
    print "$app_name is installed, but the iPhone is locked. Unlock it and open $app_name."
    exit 4
  fi
  print "$app_name is installed, but it didn't open:"
  print -r -- "$launch_output"
  exit 4
fi
print "$app_name is running on $device_name. Run this again within 7 days to keep it opening."
