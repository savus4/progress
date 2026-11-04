# Run progress on your iPhone

The Mac launcher is installed at `/Users/simonriepl/bin/deploy-ios.sh`. It runs
the version-controlled [deployment script](../Scripts/deploy-ios.sh) against
this checkout, including saved, uncommitted changes. It targets Simons iPhone
by its paired device identifier.

```zsh
"$HOME/bin/deploy-ios.sh"
```

The script uses the `progress` scheme and Debug configuration, builds and signs
with the project's existing settings, installs with `devicectl`, then launches
`me.riepl.progress`. Xcode's interactive debugger is not attached.

When called over SSH, the script starts a temporary `launchd` job in your
logged-in Mac session and waits for its result. This lets signing use the same
keychain context as a local build. Stay logged in on the Mac. The job is
unloaded when deployment finishes; no login item or persistent agent is installed.

## iPhone Shortcut

The signed Shortcut file is installed on this Mac at:

`/Users/simonriepl/bin/Shortcuts/Run Progress on iPhone.shortcut`

1. On the Mac, open System Settings → General → Sharing → Remote Login. Enable
   Remote Login and allow access for `simonriepl` under “Only these users”.
2. Double-click the signed `.shortcut` file and add it to Shortcuts. With
   Shortcuts iCloud sync enabled on both devices, it should appear on iPhone.
   Alternatively, transfer the file to the iPhone and open it there.
3. Enter your Mac login password in the Shortcut's setup question, or in its
   **Run Script over SSH** action. The generated file contains no password.
   You can instead configure an SSH key in that action and authorize its public
   key on the Mac.
4. Keep the Mac awake and reachable on the same network. Keep the iPhone
   unlocked during installation and launch. Run **Run Progress on iPhone**.

The SSH action is preconfigured with:

| Field | Value |
| --- | --- |
| Host | `Simons-MBP.local` |
| Port | `22` |
| User | `simonriepl` |
| Script | `"$HOME/bin/deploy-ios.sh"` |

The Shortcut displays the deployment output after a successful run. The Mac
stays awake during an active deployment; the script cannot wake an already
sleeping Mac. Wi-Fi pairing and Developer Mode were verified on the iPhone.

## Logs and troubleshooting

Full build, install, and launch logs are saved in
`~/Library/Logs/ProgressDeploy/`. The script prints the log path and shows the
last 70 lines when a step fails. Build products use
`~/Library/Developer/Xcode/DerivedData/ProgressPhoneDeploy`.

- **Connection refused:** enable Remote Login on the Mac.
- **SSH authentication failed:** check the username and credential in the action.
- **Device unavailable:** unlock the iPhone, check network connectivity, and run
  `xcrun devicectl list devices` on the Mac. Pair in Xcode if needed.
- **Signing failed:** open the project in Xcode and check its Apple account,
  development team, certificate, and provisioning profile. The script uses
  existing signing assets and does not change signing settings or automatically
  register devices.
- **`errSecInternalComponent` during CodeSign:** this can happen when SSH cannot
  access the signing key in the login keychain. SSH deployments now run in your
  logged-in Mac session automatically. If signing still fails, unlock the login
  keychain on the Mac and respond to any `codesign` authorization dialog there.
  [Apple's troubleshooting guide](https://developer.apple.com/forums/thread/712005)
  explains the keychain and execution-context requirements.
- **Deployment already running:** wait for it to finish. If it was forcibly
  stopped, verify no deployment is running before removing
  `~/Library/Developer/Xcode/DerivedData/ProgressPhoneDeploy.deploy-lock`.

Override the phone with `"$HOME/bin/deploy-ios.sh" 'device name or identifier'`
or `IOS_DEPLOY_DEVICE`. `IOS_DEPLOY_DERIVED_DATA` and `IOS_DEPLOY_LOG_DIR`
override the build and log directories.

## Verification

On 2026-10-25, the installed launcher successfully built and signed the current
checkout, installed `me.riepl.progress` on Simons iPhone, and launched it over
the local network. The built app's signature was also verified with `codesign`.
On 2026-11-04, an iPhone-triggered build reached signing and failed with
`errSecInternalComponent`. A signing probe in the Mac's Aqua session succeeded;
SSH deployments now use that session through
[deploy-ios-in-session.sh](../Scripts/deploy-ios-in-session.sh).
The updated SSH dispatch path was exercised locally and successfully built,
signed, installed, and launched the app on Simons iPhone. The temporary job and
deployment lock were removed afterward. The existing iPhone Shortcut command
does not need to change.

Apple references: [Xcode command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference),
[importing Shortcuts](https://support.apple.com/guide/shortcuts-mac/apd02bffbaac/mac),
and [Remote Login](https://support.apple.com/guide/mac-help/mchlp1066/mac).
