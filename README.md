# Progress - Daily Photo Tracking App

A beautiful iOS app for capturing daily photos with alignment guides, Live Photos support, geolocation, and iCloud sync.

## Features

### 📸 Camera with Alignment Guides
- **Adjustable horizontal guidelines** for eyes and mouth positioning
- **Fixed vertical center line** for consistent face alignment
- **Transparent overlay** of previous photo for better consistency
- **Front/back camera switching**
- **Live Photo capture** with video recording

### 🖼️ Photo Grid
- **Performant lazy loading** with thumbnail generation
- **Infinite scroll** with date indicator
- **Live Photo badges** on grid items
- **Empty state** with call-to-action
- **Tap to view** photo details

### 📍 Photo Details
- **Full-resolution image viewing**
- **Live Photo playback** with video player
- **Location display** with interactive map
- **Photo metadata** (date, time, location)
- **Share functionality**
- **Delete capability**

### ☁️ iCloud Sync
- **Automatic CloudKit sync** across devices
- **Efficient storage strategy**:
  - Thumbnails stored in Core Data for fast grid loading
  - Full-resolution images stored as CloudKit assets
  - Live Photo videos stored as CloudKit assets
- **Location data** synchronized with photos

### 🎨 Modern Design
- **Liquid glass/glassmorphism** UI with 
- **iOS 26 design language**
- **Smooth animations** and transitions
- **Dark mode support**

## Architecture

### Core Data Model
**DailyPhoto Entity:**
- `id`: UUID - Unique identifier
- `captureDate`: Date - When the photo was taken
- `thumbnailData`: Binary Data - Compressed thumbnail for grid
- `fullImageAssetName`: String - CloudKit asset identifier for full image
- `livePhotoImageAssetName`: String - CloudKit asset for Live Photo still
- `livePhotoVideoAssetName`: String - CloudKit asset for Live Photo video
- `latitude`: Double - Photo location latitude
- `longitude`: Double - Photo location longitude
- `createdAt`: Date - Creation timestamp
- `modifiedAt`: Date - Last modification timestamp

### Services Layer

#### LocationService
- Manages Core Location permissions and updates
- Provides current location for photo capture
- Handles authorization states

#### CameraService
- Manages AVCaptureSession and camera configuration
- Handles Live Photo capture
- Supports front/back camera switching
- Photo quality prioritization

#### CloudKitService
- Manages CloudKit asset storage and retrieval
- Handles image and video file operations
- Error handling for sync operations

#### ThumbnailService
- Generates compressed thumbnails for grid performance
- Configurable target sizes
- JPEG compression optimization

#### PhotoStorageService
- High-level photo management API
- Coordinates between Core Data and CloudKit
- Handles full save/load/delete operations

### Views

#### PhotoGridView
- Main grid interface with LazyVGrid
- Date-based scrolling with position indicator
- Empty state handling
- Navigation to camera and detail views

#### CameraView
- Live camera preview with AVFoundation
- Overlay alignment guides (adjustable)
- Previous photo overlay (toggleable)
- Settings sheet for guide customization
- Location capture integration

#### PhotoDetailView
- Full-screen photo display
- Live Photo playback controls
- Map view for photo location
- Share and delete actions

## Requirements

- iOS 18.0+ (or iOS 26.2 as configured)
- Xcode 16.2+
- Swift 5.0+
- iCloud account for sync

## Permissions

The app requires the following permissions:
- **Camera**: To capture photos
- **Location (When In Use)**: To save location data with photos
- **Photo Library (Add Only)**: Optional, for saving photos to library

## Setup

1. **Open the project** in Xcode
2. **Configure signing** with your Apple Developer account
3. **Enable iCloud capability** in your App ID
4. **Run on device** (camera requires physical device)

### iCloud Configuration

The app uses CloudKit with the default container:
- Container ID: `iCloud.$(CFBundleIdentifier)`
- Database: Private (user's iCloud account)

## Storage Strategy

### Performance Optimization
- **Grid**: Displays 300x300px JPEG thumbnails from Core Data
- **Detail View**: Loads full-resolution images on demand from CloudKit
- **Live Photos**: Video files loaded only when playback is initiated

### CloudKit Sync
- Automatic sync via `NSPersistentCloudKitContainer`
- No manual sync code required
- Works across all user's devices with the app installed

## User Settings

### Alignment Guides (Stored in UserDefaults)
- `eyeLinePosition`: Default 0.35 (35% from top)
- `mouthLinePosition`: Default 0.65 (65% from top)
- `showOverlay`: Toggle for previous photo overlay

## Future Enhancements

- [ ] Movie creation from photo sequence
- [ ] Time-lapse video export
- [ ] Face detection for auto-alignment
- [ ] Daily reminders/notifications
- [ ] Photo editing capabilities
- [ ] Multiple alignment guide presets
- [ ] Photo filters/effects
- [ ] Social sharing features
- [ ] Statistics and insights
- [ ] Search and filtering

## Known Limitations

1. **Live Photos** require physical device (not supported in simulator)
2. **CloudKit sync** requires iCloud account and network connection
3. **Location services** require user permission and GPS availability
4. **Storage space** will grow with daily photos (plan accordingly)

## Troubleshooting

### Camera not working
- Ensure camera permission is granted in Settings > Privacy > Camera
- Must run on physical device (simulator doesn't support camera)

### Photos not syncing
- Verify iCloud account is signed in
- Check iCloud Drive is enabled for the app
- Ensure network connectivity
- Check iCloud storage availability

### Location not saving
- Grant location permission in Settings > Privacy > Location Services
- Ensure location services are enabled on device

## Development Notes

### Testing
- Preview support in Xcode with sample data
- In-memory Core Data for previews
- Placeholder images for grid preview

### Build Configuration
- Bundle ID: `me.riepl.progress`
- Development Team: AEHX3J775Q
- Deployment Target: iOS 18.0+

## License

Copyright © 2026 Simon Riepl. All rights reserved.
