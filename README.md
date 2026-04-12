# Work in Progress

`Work in Progress` is an iOS app for taking one photo a day, keeping the framing consistent with adjustable face guides, and building a personal visual timeline over time. The repository name is still `progress`, but the current in-app display name is `Work in Progress`.

## What The App Does Today

- Capture still photos and Live Photos from a custom full-screen camera.
- Adjust and persist eye and mouth alignment guides for more consistent framing.
- Review photos in a scrollable grid with upload state badges and month overlays while scrolling.
- Open photos in a full-screen pager with zoom, metadata, location info, and sharing actions.
- Save photos to the system Photos library.
- Import photos, Live Photos, and full albums from the user’s photo library.
- Schedule up to three daily reminder notifications that can deep-link straight into the camera.
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

- Daily reminder times with notification permission handling.
- Photo import from picker, private import (experimental), and album import.
- iCloud sync status and failed upload retry action.
- Delete by date range.
- Delete all local photo records and assets.

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

### Key Services

- `PhotoStorageService`: save, import, export, delete, and asset loading logic
- `PhotoUploadService`: staged CloudKit uploads, retry handling, background processing
- `CloudKitService`: asset staging, upload/download, local cache management
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
