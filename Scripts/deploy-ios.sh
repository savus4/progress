#!/bin/zsh
# Build the current working tree, install it, and launch it on a paired iPhone.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

if [[ ${1:-} == --help ]]; then
  cat <<'HELP'
Usage: deploy-ios.sh [device identifier or name]

Builds the progress Debug app, signs it using the project's Xcode settings,
then installs and launches it on the paired physical iPhone.

Defaults to "Simons iPhone". The installed ~/bin/deploy-ios.sh launcher pins
the device identifier. An argument or IOS_DEPLOY_DEVICE overrides the default.
Optional: IOS_DEPLOY_DERIVED_DATA, IOS_DEPLOY_LOG_DIR.
HELP
  exit 0
fi
if (( $# > 1 )); then
  print -u2 -- 'Expected at most one device identifier or name. Use --help.'
  exit 2
fi

readonly project_root=${0:A:h:h}
readonly project="$project_root/progress.xcodeproj"
readonly device=${1:-${IOS_DEPLOY_DEVICE:-Simons iPhone}}
readonly derived=${IOS_DEPLOY_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/ProgressPhoneDeploy}
readonly log_dir=${IOS_DEPLOY_LOG_DIR:-$HOME/Library/Logs/ProgressDeploy}
readonly lock_dir="${derived}.deploy-lock"

[[ -d "$project" ]] || { print -u2 -- "Project missing: $project"; exit 1; }
/usr/bin/xcode-select -p >/dev/null
/bin/mkdir -p "${derived:h}" "$log_dir"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
  print -u2 -- "Another deployment may be running. Lock: $lock_dir"
  print -u2 -- 'If a previous run was forcibly stopped, verify it has exited before removing that directory.'
  exit 1
fi
trap '/bin/rmdir "$lock_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

readonly log_file=$(/usr/bin/mktemp "$log_dir/deploy-$(/bin/date +%Y%m%d-%H%M%S).XXXXXX")
print -- "Deployment log: $log_file"
# Keep the Mac awake for this invocation, including when started over SSH.
/usr/bin/caffeinate -is -w $$ >/dev/null 2>&1 &

run_step() {
  local label=$1
  shift
  print -- "$label"
  print >> "$log_file"
  print -r -- "$label" >> "$log_file"
  if "$@" >> "$log_file" 2>&1; then
    return 0
  else
    local result=$?
    /usr/bin/tail -n 70 "$log_file" >&2
    print -u2 -- "Failed: $label (exit $result). Full log: $log_file"
    exit "$result"
  fi
}

run_step "Checking iPhone: $device" \
  /usr/bin/xcrun devicectl device info details --device "$device" --timeout 30
run_step 'Building and signing progress (Debug)…' \
  /usr/bin/xcodebuild -project "$project" -scheme progress \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" build

readonly app="$derived/Build/Products/Debug-iphoneos/progress.app"
[[ -d "$app" ]] || { print -u2 -- "Built app missing: $app"; exit 1; }
readonly bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
[[ "$bundle_id" == me.riepl.progress ]] || {
  print -u2 -- "Unexpected app bundle identifier: $bundle_id"
  exit 1
}
run_step 'Installing on iPhone… Keep your iPhone unlocked.' \
  /usr/bin/xcrun devicectl device install app --device "$device" --timeout 180 "$app"
run_step 'Launching progress…' \
  /usr/bin/xcrun devicectl device process launch --device "$device" \
  --timeout 60 --terminate-existing "$bundle_id"
print -- "Deployment completed: $bundle_id is running on $device."
