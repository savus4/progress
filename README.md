# Work in Progress

`Work in Progress` is an iOS app for taking one photo a day, keeping the framing consistent with adjustable face guides, and building a personal visual timeline over time. The repository name is still `progress`, but the current in-app display name is `Work in Progress`.

# Todo
- Make photos heartable, so app knows to focus on them and can include live photos in the video. so add heart button to photo detail view (bottom middle) (this hearts also have to sync to icloud like the rest) and then in video creator create new toggle which when on, includes for the hearted photos the video part of the photo instead of the photo (video length is influenced by that, so estimate this change)

## What The App Does Today

- Capture still photos and Live Photos from a custom full-screen camera.
- Adjust and persist eye and mouth alignment guides for more consistent framing.
- Review photos in a scrollable grid with upload state badges and month overlays while scrolling.
- Open photos in a full-screen pager with zoom, metadata, location info, and sharing actions.
- Save photos to the system Photos library.
- Import photos, Live Photos, and full albums from the user’s photo library.
- Schedule up to seven daily reminder notifications that can deep-link straight into the camera.
- Export selected photos or the entire library through the system document picker.
- Delete selected photos, delete photos in a date range, or wipe the library completely.
- Sync photo metadata through Core Data + CloudKit, while original assets upload in the background.

## Main Screens

### Introduction

- First launch opens a short introduction with a portrait video preview, followed by highlights for large libraries, Live Photos, video creation, saved locations, and privacy.
- Swipe between the two pages or use Continue to advance. The page indicator and Get Started action follow the current page.
- The preview grows to fit the available space, and the video animates in when playback is ready. Feature content is centered vertically, with a separate entrance for each row and scrolling for longer text. Get Started completes the intro's exit before opening the library; Reduce Motion uses short fades.
- The video entrance starts after 0.7 seconds, followed by the title, subtitle, page indicator, and button, using slower spring animations. Soft background particles stay still with Reduce Motion and pause while the app is inactive.
- The bundled `Resources/Introduction.mp4` preview loops silently, pauses outside the active page or scene, and respects Reduce Motion. Replace this file to update the preview; an animated placeholder is shown if the video is missing.
- Completing the introduction is remembered on this device. Press and hold the **Settings** title for three seconds to show the introduction on the next launch. A confirmation appears immediately; the current session stays open.

### Grid

- After the introduction, the app launches into `PhotoGridView`.
- Empty state includes a direct “Take Your First Photo” action.
- Existing photos appear in an adaptive grid.
- Tapping opens a paged fullscreen viewer.
- Selection mode supports bulk export, bulk delete, and hiding or unhiding photos from videos.
- Hidden photos remain in the grid with a small eye-slash badge. Hiding clears both favorite types; hidden photos cannot be favorited until they are unhidden.
- The bottom-left filter menu includes Hidden to show only photos excluded from videos.
- Photos show status badges such as uploading, retrying, paused, or downloading.

### Camera

- `ExperimentalCameraView` uses a custom `AVCaptureSession` flow.
- Capture supports still photos and Live Photos when the device supports them.
- Eye and mouth guides can be edited directly in the camera UI.
- After capture, the app shows a preview step with retake/save before committing to storage.
- Captured location is attached when permission is available.

### Photo Viewer

- `PhotoPagerView` presents photos fullscreen in a horizontal pager.
- Still photos can be shared directly.
- Live Photos can be shared as paired asset files.
- Photos can be saved back to the system Photos library.
- The ellipsis menu can hide or unhide the current photo from videos.
- Trying to favorite a hidden photo shows a five-second explanation with instructions to unhide it first.
- An info sheet shows timestamps, location name, coordinates, and a map when available.

### Settings

`NotificationSettingsView` currently acts as the app’s main settings and maintenance screen.

- Notifications submenu with daily reminder times, notification permission handling, and a default-on “Skip Reminders After Taking a Photo” toggle.
- Import submenu with photo picker, private import (experimental), and album import.
- iCloud sync status and failed upload retry action.
- Delete by date range.
- Delete all local photo records and assets.
- Optional snack-themed tips at the bottom: chips (US$3), fries (US$5), and custom tips from US$10 to US$100 in US$10 steps. The App Store supplies localized prices and currency. Verified tips show a thank-you screen; cancellation, pending approval, and errors never show success.

#### In-app purchase setup

Create these **consumable** products in App Store Connect for `me.riepl.progress`, with the United States as the base storefront:

| Product ID | US price |
| --- | --- |
| `me.riepl.progress.tip.chips` | $3.00 |
| `me.riepl.progress.tip.fries` | $5.00 |
| `me.riepl.progress.tip.custom` | $10.00 per unit |

Custom tips buy 1–10 units of the custom product in a single Apple confirmation sheet (`Product.PurchaseOption.quantity` has a ten-unit maximum). They are one-time tips, with no feature unlock or subscription. Use the exact base prices above rather than $2.99/$4.99/$9.99. Complete the paid-app agreement, banking, tax, product availability/localization, and App Review setup in App Store Connect before release. Product creation and approval happen outside this repository.

The shared Debug scheme selects `progress/Resources/Tips.storekit` under **Edit Scheme → Run → Options → StoreKit Configuration** for local testing. Set it to **None** when testing actual App Store Connect products in Sandbox. The tests create StoreKit Test sessions from the bundled configuration. The app uses SwiftUI's `PurchaseAction`, verifies signed transactions, finishes consumables, and listens for both transaction updates and unfinished transactions from launch.

API references: [PurchaseAction](https://developer.apple.com/documentation/storekit/purchaseaction), [quantity](https://developer.apple.com/documentation/storekit/product/purchaseoption/quantity(_:)), and [transaction price (includes quantity)](https://developer.apple.com/documentation/storekit/transaction/price).

Reminders skip the rest of the local calendar day when a saved photo has today's capture date, including imported and synced photos. Unsaved captures and older imports do not count. Turning the toggle off restores every configured reminder. The schedule refreshes after library changes, on app activation, and when the day or system time changes.

Daily repeating notification triggers cannot omit a single occurrence. After skipping today, the app queues the next 64 individual reminders starting tomorrow (at least nine days with seven reminder times). Opening the app on a later day restores indefinite daily repeats when no photo exists for that day. If the app stays closed past the queued reminders, reminders stop until it opens again.

## Architecture

### Stack

- SwiftUI app
- Core Data with `NSPersistentCloudKitContainer`
- CloudKit private database for original asset storage
- Background processing for deferred asset uploads
- UserNotifications for reminders
- Photos / PhotosUI for import, Live Photo handling, and save-back flows

### Storage Model

The `DailyPhoto` Core Data entity currently stores:

- `id`
- `captureDate`
- `thumbnailData`
- `fullImageAssetName`
- `livePhotoImageAssetName`
- `livePhotoVideoAssetName`
- `latitude`
- `longitude`
- `locationName`
- `createdAt`
- `modifiedAt`
- `importFingerprint`
- `isHearted`, `isFavoriteLivePhoto`, and `isHiddenFromVideo`
- upload bookkeeping fields such as `uploadStateRaw`, `uploadAttemptCount`, `uploadErrorMessage`, and `uploadRetryAfter`

`progressVideoVisibility` is the current Core Data model version. The original model remains bundled for lightweight migration; existing and newly captured/imported photos default to inclusion in videos. `isHiddenFromVideo` syncs with the photo metadata and excludes both still and Live Photo video frames, including paused exports. Before release, deploy the additive `CD_isHiddenFromVideo` field on `CD_DailyPhoto` to the production CloudKit schema.

### Sync Model

The current sync setup is split into two parts:

1. Core Data metadata sync uses `NSPersistentCloudKitContainer`.
2. Original photo and Live Photo video files are staged locally and uploaded to CloudKit by `PhotoUploadService`.

That means the grid can show records immediately, while large original assets continue uploading in the background. The app also tracks retryable and paused uploads and surfaces those states in the UI.

Missing-file upload pauses recover automatically when the upload queue next runs, including older `CKError(16)` pauses. Recovery requires this device's persisted upload ownership: it checks missing assets in iCloud first, then copies available offline, readable-cache, or legacy originals back into upload staging. Existing originals remain intact, Live Photo resources recover independently, and success is recorded only after every resource is confirmed or uploaded. Unfinished local uploads protect their offline recovery copies from eviction. Manual retry also includes owned photos with missing staging files; missing originals remain paused, and failed cloud checks use the normal retry queue.

Capture processing waits for the final camera callback before pairing still and Live Photo resources; a failed movie preserves a valid still, and failed captures report an error instead of leaving the camera busy. Pending originals are included in device backup. A handled save failure removes its staged files and upload ownership without deleting the capture's source movie, so saving can be retried. Crash recovery skips active saves and serializes recovery attempts. Upload workers reserve each photo before sending it, retry transient failures on a timer while the app remains running, and retain files until CloudKit confirms every save. Deletion waits for an in-flight asset upload before remote cleanup, preventing a late upload from recreating a deleted asset. iOS background scheduling still controls retries while the app is suspended.

Settings → Photo Storage → Advanced → Storage Management can keep all originals, or photos marked with either heart, available offline on this device. Both options include Live Photo motion. Cloud-backed offline originals are stored separately from caches and pending uploads and are excluded from device backup. Turning a keep setting off releases copies no longer selected; unuploaded originals are preserved.

Keep Recently Opened Photos adds a persistent cache ordered by last opening, with new captures and imports treated as openings. Its limit is adjustable from 100 MB to currently free device storage (default 1 GB). Exceeding or lowering the limit evicts the least recently opened cloud-backed photos, including their complete Live Photo resources. Hearted photos selected by Keep Hearted Photos are protected outside this limit, and Keep All Photos overrides it. Pending uploads are never evicted; after upload, retained staging files are handed off within the cache budget. Background downloads, thumbnail loads, and adjacent-page prefetching do not update access order. Settings shows a storage bar with hearted photos, other retained photos, pending uploads, cache, and the recent-photo limit.

Automatic offline downloads use Wi-Fi unless cellular downloads are enabled. They pause in Low Data Mode, Low Power Mode, or low device storage, preserve a 0.5 GB reserve (500 MB), and resume at 0.55 GB (550 MB), with room for the next transfer. Full iCloud storage pauses uploads while preserving local originals; keeping offline copies does not free iCloud space.

Opening a photo always checks local originals and readable caches before the network. Uncached photos fail immediately while offline; connection loss cancels active downloads, and each remote request has a 30-second deadline. The viewer keeps its thumbnail or downloaded still, shows an offline or timeout message, offers a manual retry, and retries the current photo when connectivity returns.

### Key Services

- `PhotoStorageService`: save, import, export, delete, and asset loading logic
- `PhotoUploadService`: staged CloudKit uploads, retry handling, background processing
- `CloudKitService`: asset staging, upload/download, local cache management
- `PhotoOfflineCoordinator` / `PhotoOfflineStore`: offline selection, persistent originals, download progress, and storage safeguards
- `CloudSyncMonitor`: sync/upload state exposed to the UI
- `DailyReminderNotificationService`: recurring reminders and notification payload handling
- `AlignmentGuideStore`: guide persistence via `UserDefaults` and iCloud key-value store
- `LocationService`: capture-time location access
- `LocationNameCacheService`: cached reverse-geocoded display names

## Project Requirements

- iOS deployment target is currently `26.2` in the Xcode project
- A physical device is strongly recommended for camera capture and Live Photos
- An iCloud-capable signing setup is required for sync behavior

## Permissions

The app currently requests or uses:

- Camera
- Location When In Use
- Photo Library access for imports
- Photo Library Add Only for save-to-library actions
- Notifications for daily reminders

## Setup

1. Open `progress.xcodeproj` in Xcode.
2. Configure signing for your team.
3. Enable the capabilities used by the app:
   - iCloud / CloudKit
   - Push Notifications
   - Background Modes
     - `processing`
     - `remote-notification`
4. Run on a device if you want to test the full capture flow.

The app is configured to use the default CloudKit container:

- `iCloud.$(CFBundleIdentifier)`

## Testing

### Photo storage switching

Settings → Photo Storage controls this device’s metadata sync and original-asset uploads together. Existing installations default to iCloud. Local-only mode excludes the library, retained originals, staging, and legacy originals from future device backups. Existing iCloud device backups and photos saved to Apple Photos are managed separately by iOS.

Switching locally estimates original sizes, temporary download copies, a possible clean database copy, and a safety margin before committing. The margin is 10% of the working footprint, with a 50 MB minimum and 500 MB maximum; it stays free on the device. The confirmation lists originals, working space, and this safety margin separately. The same margin is checked before each original is retained, and completed originals remain safe if space runs out. Users choose whether to retain or remove existing cloud copies. Every still and Live Photo resource is hashed and retained before remote deletion. Atomic device-only checkpoints resume interrupted downloads, verification, upload preparation, and deletion. Adding/deleting photos is paused during a switch. Downloads can be cancelled before deletion begins.

The removal option enumerates cloud metadata and original records, refuses to delete unknown photos that have not synced to this device, and verifies every deletion and final absence. A fresh local database preserves photo UUIDs, thumbnails, dates, locations, and flags without old CloudKit record mappings; deletion tombstones cannot erase the retained local library when iCloud is later enabled. Other devices should stop syncing before removal because they can upload copies again afterward. The original database remains retained locally for recovery and is excluded from backups in local mode.

**CloudKit release setup:** Enable a QUERYABLE index for the `PhotoAsset` record type’s `recordName` system field (shown as Record ID in CloudKit Console), and deploy the index to production. The removal preflight requires enumeration of originals; a query/index failure stops the operation before any deletion. No Core Data schema change is required. See [Apple’s querying guidance](https://developer.apple.com/documentation/cloudkit/handling-an-icloud-container-s-data).

Apple exposes account availability and quota-exceeded errors, but no remaining-iCloud-capacity API. Re-enabling iCloud therefore shows the original-byte estimate, explains private upload of the complete library, and requires users to confirm they checked capacity in iOS Settings. Upload ownership is persisted before sync resumes; quota errors retain originals and pause uploads. The estimate excludes future photos and additional cloud metadata overhead.

Re-enabling iCloud first imports the server library into a fresh SQLite store, then merges the surviving local photos by UUID. Deletions made while local-only was enabled remain local: retained iCloud photos return, new local photos upload, and photos present in both libraries keep one row and their server record identity. The original local database stays intact until the merged database opens and its filename is checkpointed. Failed or interrupted imports leave that local database available for retry. Local deletions never enqueue cloud-original cleanup; older cleanup requests for originals referenced by the merged library are cancelled before cloud operations resume.

`PhotoStorageModeTests` and `PhotoStorageFailureTests` cover existing-install defaults, atomic checkpoints, corrupt/unwritable journals, empty libraries, space preflight and mid-download exhaustion, missing/corrupt originals, all Live resource roles, resumable partial downloads/deletions, account changes/sign-out, unknown remote photos, batch deletion and final-absence verification, cancellation, mutation/upload guards, repeated switches, durable upload ownership, and quota/network/authentication failures after enabling iCloud. Restart scenarios reconstruct SQLite, preferences, cache inventory, and upload journals from disk. `PhotoStorageSettingsUITests` cover empty-state navigation, settings navigation, and cancellation of the storage-choice dialog.

Run deterministic storage tests on iPhone 18 Pro:

```sh
TEST_RUNNER_STORAGE_TEST_HOST=1 TEST_RUNNER_SIMULATOR_EXAMPLE_PHOTOS=0 \
xcodebuild test -project progress.xcodeproj -scheme progress -parallel-testing-enabled NO \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:progressTests/PhotoStorageModeTests \
  -only-testing:progressTests/PhotoStorageFailureTests \
  -only-testing:progressTests/PhotoCloudLibraryMergeTests
```

`PhotoStorageLiveCloudTests` and `PhotoStorageLiveMirroringTests` are opt-in integration tests requiring an iCloud account on the selected simulator. The asset tests create a unique `StorageTests-UUID` private zone, exercise the real upload/download/metadata APIs, verify byte equality through both storage directions, request one-record enumeration pages, refuse unknown photos and cross-zone deletion targets, and remove only that test zone afterward. A separate read-only test verifies production library enumeration and the required `PhotoAsset` query index. The mirroring test uses a temporary SQLite library and one synthetic photo UUID: it verifies export, detached local editing, re-enabled export with the same CloudKit record identity, and deletes only that synthetic record. Imported account photos are never modified or included in deletion plans.

`PhotoCloudLibraryLiveMergeTests` exercises the production coordinator with a retained photo grid in two real-iCloud scenarios: three cloud photos deleted locally plus a new local photo, and three local photos with one matching cloud photo. It verifies the merged UUIDs, preserved server identities, refreshed grid results, and export of new photos. Cleanup targets only each scenario’s synthetic UUIDs.

`PhotoGridStoreTransitionTests` forces a debounced upload-status refresh during database replacement, checks recovery after a store is temporarily removed, and verifies rebinding to a different view context. Cached fetched results and thumbnail requests must never resolve object IDs from a removed store.

```sh
TEST_RUNNER_STORAGE_TEST_HOST=1 TEST_RUNNER_SIMULATOR_EXAMPLE_PHOTOS=0 \
TEST_RUNNER_RUN_LIVE_CLOUDKIT_TESTS=1 \
xcodebuild test -project progress.xcodeproj -scheme progress -parallel-testing-enabled NO \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:progressTests/PhotoStorageLiveCloudTests \
  -only-testing:progressTests/PhotoStorageLiveMirroringTests \
  -only-testing:progressTests/PhotoCloudLibraryLiveMergeTests
```

`STORAGE_TEST_HOST=1` works only in Debug simulator builds. It keeps the normal app library in memory and stops normal app background services while fixtures explicitly open their own temporary disk libraries. Live tests fail with the account status if iCloud is unavailable; they do not silently pass or switch to mocks. Simulated quota/space/account failures do not fill storage or sign the user out. Two-device re-upload races and OS force-kills during an in-flight CloudKit operation still need dedicated device testing; reconstructing a checkpoint is not an OS termination test.

### Simulator example library

Debug simulator builds automatically show the local examples in `SimulatorFixtures/Photos/`.
The current fixture set contains 51 stills, including 49 Live Photos. Capture dates and
embedded locations are preserved. Missing examples are restored on launch without
duplicating existing ones or resetting favorites. The simulator uses a separate local
store with iCloud disabled. Settings identifies the simulator example library and shows its fixed local-only storage mode; the normal library’s saved storage preference is preserved. Personal fixtures are Git-ignored, and device/Release
builds exclude both the media and the seeding code. Ordinary UI tests keep their empty stores; the simulator-example regression test explicitly opens the example library.

Set `SIMULATOR_EXAMPLE_PHOTOS=0` in the Run environment to disable this mode.
See [SimulatorFixtures/README.md](SimulatorFixtures/README.md) to replace the examples.

- `progressTests` uses Swift Testing for service and model coverage.
- `progressUITests` includes a mocked capture flow that verifies saving from camera preview back into the grid.
- UI tests support an in-memory store via the `UI_TEST_IN_MEMORY_STORE` launch argument.

## Current Notes

- Live Photo capture is device-dependent.
- “Import Privately” is still marked experimental in the UI.
- Asset uploads can be delayed and retried in the background depending on network/account state.
- The repo still contains the old project name `progress` in code and paths, while the visible app name is `Work in Progress`.
