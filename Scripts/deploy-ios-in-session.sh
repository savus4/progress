#!/bin/zsh
# Run a remote deployment in the user's existing Aqua security session.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

if (( $# != 1 )); then
  print -u2 -- 'Expected one device identifier or name.'
  exit 2
fi

readonly device=$1
readonly deploy_script="${0:A:h}/deploy-ios.sh"
readonly gui_domain="gui/$(/usr/bin/id -u)"
if ! /bin/launchctl print "$gui_domain" >/dev/null 2>&1; then
  print -u2 -- 'Remote signing needs your logged-in Mac session. Log in on the Mac, then retry.'
  exit 1
fi

readonly log_dir=${IOS_DEPLOY_LOG_DIR:-$HOME/Library/Logs/ProgressDeploy}
/bin/mkdir -p "$log_dir"
readonly session_dir=$(/usr/bin/mktemp -d "$log_dir/session.XXXXXXXX")
readonly job_plist="$session_dir/job.plist"
readonly job_output="$session_dir/output.log"
readonly job_result="$session_dir/result"
readonly job_label="me.riepl.progress.phone-deploy.${session_dir:t}"
readonly service="$gui_domain/$job_label"

# Pass values as separate plist strings and shell arguments, never shell code.
/usr/bin/plutil -create xml1 "$job_plist"
/usr/bin/plutil -insert Label -string "$job_label" "$job_plist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$job_plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$job_plist"
/usr/bin/plutil -insert StandardOutPath -string "$job_output" "$job_plist"
/usr/bin/plutil -insert StandardErrorPath -string "$job_output" "$job_plist"
/usr/bin/plutil -insert WorkingDirectory -string "${deploy_script:h:h}" "$job_plist"
/usr/bin/plutil -insert EnvironmentVariables -dictionary "$job_plist"
/usr/bin/plutil -insert EnvironmentVariables.IOS_DEPLOY_IN_GUI_SESSION -string 1 "$job_plist"
for variable in IOS_DEPLOY_DERIVED_DATA IOS_DEPLOY_LOG_DIR DEVELOPER_DIR; do
  if (( ${+parameters[$variable]} )); then
    /usr/bin/plutil -insert "EnvironmentVariables.$variable" -string "${(P)variable}" "$job_plist"
  fi
done
/usr/bin/plutil -insert ProgramArguments -array "$job_plist"
readonly runner='"$1" "$2"
deploy_exit=$?
/usr/bin/printf "%s\n" "$deploy_exit" > "$3.tmp"
/bin/mv "$3.tmp" "$3"
exit "$deploy_exit"'
for argument in /bin/zsh -c "$runner" progress-phone-deploy "$deploy_script" "$device" "$job_result"; do
  /usr/bin/plutil -insert ProgramArguments -string "$argument" -append "$job_plist"
done

cleanup() {
  /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

print -- 'Running deployment in your logged-in Mac session…'
if ! /bin/launchctl bootstrap "$gui_domain" "$job_plist"; then
  print -u2 -- "Could not start deployment in the Mac session. Details: $session_dir"
  exit 1
fi

# The worker publishes its exit status atomically after all output is written.
readonly deadline=$(( SECONDS + 1800 ))
while [[ ! -f "$job_result" ]]; do
  if (( SECONDS >= deadline )); then
    [[ ! -f "$job_output" ]] || /bin/cat "$job_output" >&2
    print -u2 -- "Deployment timed out after 30 minutes. Session log: $job_output"
    exit 1
  fi
  /bin/sleep 1
done

[[ ! -f "$job_output" ]] || /bin/cat "$job_output"
readonly deploy_exit=$(< "$job_result")
if [[ "$deploy_exit" != <0-255> ]]; then
  print -u2 -- "Invalid deployment result. Session log: $job_output"
  exit 1
fi
exit "$deploy_exit"
