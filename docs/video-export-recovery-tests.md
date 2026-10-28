# Video export recovery tests

The tests create synthetic still photos and Live Photo clips, export actual MP4 files, and decode their frames and audio. Each fixture owns a temporary SQLite library, source files, export directory, and unique checkpoint preference keys. Asset requests never access the network.

| Coverage | Verification |
| --- | --- |
| Restoring an export | Reopen SQLite and construct a fresh exporter and asset service; recover the saved checkpoint. |
| Reusing completed work | Delete completed source photos and clips before resuming; check initial progress, subsequent photo loads, preserved segment bytes, and final media. |
| Playback order | Check every output frame in chronological and reverse order, including hidden-photo exclusions. |
| Repeated pauses | Pause before the first frame, during a segment, at the automatic checkpoint boundary, and after the last photo. |
| Interrupted work | Cancel a resume without damaging its checkpoint; interrupt loading before and after the first automatic checkpoint, with and without the background pause request; replace an abandoned partial segment and resume only committed frames. |
| Invalid checkpoints | Restart from zero for missing or unreadable segments, invalid progress, inconsistent failures, duplicate segments, changed settings, and changed photo selection. |
| Checkpoint copies | Recover valid staging data when committed data is absent or corrupt; prefer valid committed data and reject two corrupt copies. |
| Skipped photos | Preserve each failed photo once, including a checkpoint containing only failures and no media. |
| Audio | Check sound and silence on both sides of a restored export in both playback orders; rebuild legacy silent checkpoints. |
| Finishing and cleanup | Repeated finishing cancellations preserve frame count and duration; temporary cleanup retains paused media; discard and successful export remove checkpoint state. |

Run on iPhone 18 Pro with normal simulator signing (CloudKit initialization requires the app's entitlements):

```sh
TEST_RUNNER_STORAGE_TEST_HOST=1 TEST_RUNNER_SIMULATOR_EXAMPLE_PHOTOS=0 \
xcodebuild test -project progress.xcodeproj -scheme progress \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -parallel-testing-enabled NO \
  -only-testing:progressTests/PortraitVideoExportRecoveryTests \
  -only-testing:progressTests/PortraitVideoAudioTests \
  -only-testing:progressTests/PortraitVideoExportConfigurationTests \
  -only-testing:progressTests/PortraitVideoExportedVideoTests
```

Reconstructing the library and exporter verifies persisted recovery within a test process. These tests do not terminate and relaunch the app, drive the Continue button, or force iOS background-time expiration. Those lifecycle scenarios still need device or UI verification.
