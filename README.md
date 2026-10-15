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

### Grid

- The app launches into `PhotoGridView`.
- Empty state includes a direct “Take Your First Photo” action.
- Existing photos appear in an adaptive grid.
- Tapping opens a paged fullscreen viewer.
- Selection mode supports bulk export and bulk delete.
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
- An info sheet shows timestamps, location name, coordinates, and a map when available.

### Settings

`NotificationSettingsView` currently acts as the app’s main settings and maintenance screen.

- Notifications submenu with daily reminder times, notification permission handling, and a default-on “Skip Reminders After Taking a Photo” toggle.
- Import submenu with photo picker, private import (experimental), and album import.
- iCloud sync status and failed upload retry action.
- Delete by date range.
- Delete all local photo records and assets.

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
- upload bookkeeping fields such as `uploadStateRaw`, `uploadAttemptCount`, `uploadErrorMessage`, and `uploadRetryAfter`

### Sync Model

The current sync setup is split into two parts:

1. Core Data metadata sync uses `NSPersistentCloudKitContainer`.
2. Original photo and Live Photo video files are staged locally and uploaded to CloudKit by `PhotoUploadService`.

That means the grid can show records immediately, while large original assets continue uploading in the background. The app also tracks retryable and paused uploads and surfaces those states in the UI.

Missing-file upload pauses recover automatically when the upload queue next runs, including older `CKError(16)` pauses. Recovery requires this device's persisted upload ownership: it checks missing assets in iCloud first, then copies available offline, readable-cache, or legacy originals back into upload staging. Existing originals remain intact, Live Photo resources recover independently, and success is recorded only after every resource is confirmed or uploaded. Unfinished local uploads protect their offline recovery copies from eviction. Manual retry also includes owned photos with missing staging files; missing originals remain paused, and failed cloud checks use the normal retry queue.

Capture processing waits for the final camera callback before pairing still and Live Photo resources; a failed movie preserves a valid still, and failed captures report an error instead of leaving the camera busy. Pending originals are included in device backup. A handled save failure removes its staged files and upload ownership without deleting the capture's source movie, so saving can be retried. Crash recovery skips active saves and serializes recovery attempts. Upload workers reserve each photo before sending it, retry transient failures on a timer while the app remains running, and retain files until CloudKit confirms every save. Deletion waits for an in-flight asset upload before remote cleanup, preventing a late upload from recreating a deleted asset. iOS background scheduling still controls retries while the app is suspended.

Settings → Storage Management can keep all originals, or photos marked with either heart, available offline on this device. Both options include Live Photo motion. Cloud-backed offline originals are stored separately from caches and pending uploads and are excluded from device backup. Turning a keep setting off releases copies no longer selected; unuploaded originals are preserved.

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

- `progressTests` uses Swift Testing for service and model coverage.
- `progressUITests` includes a mocked capture flow that verifies saving from camera preview back into the grid.
- UI tests support an in-memory store via the `UI_TEST_IN_MEMORY_STORE` launch argument.

## Current Notes

- Live Photo capture is device-dependent.
- “Import Privately” is still marked experimental in the UI.
- Asset uploads can be delayed and retried in the background depending on network/account state.
- The repo still contains the old project name `progress` in code and paths, while the visible app name is `Work in Progress`.
