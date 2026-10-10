# Checked bug review

Reviewed 2026-10-08 against the current working tree at `c1cbe22`, including the existing uncommitted changes. Four agents reviewed the app and bundled plugin; the primary reviewer independently checked every entry. Application source was not changed during the initial review. The follow-up below records the requested P1 fixes.

**23 verified findings: all 5 P1 issues are now fixed and regression-tested; 18 P2 issues remain open.** P1 means serious loss or failure requiring prompt attention; P2 means a reproducible functional defect. Source-verified cloud/device failures are distinguished from simulator reproductions below.

## P1 fixes and verification — 2026-10-09

Each P1 had a regression that failed before its fix. The original findings below describe the reviewed version; their original source line numbers are historical.

| Finding | Resolution | Regression evidence |
| --- | --- | --- |
| 1. Legacy originals | Recover retained Core Data blobs and older filesystem assets into durable staging; keep the original bytes. Recover at startup and through name-based readers, sharing, and export. Queue every distinct Live Photo resource locally. | Still blob, separate Live image/video blobs, and older-file reads failed with `assetNotFound` before the fix and now pass. Added coverage for late-arriving blobs, backfill, and ownership surviving restart. |
| 2. Failed capture saves | Propagate the error, show it, retain the preview and Live resources for retry, and block duplicate saves through the success animation. Remove only the failed inserted row and its pending ownership, preserving other context edits. | Camera UI test first failed because no error alert appeared; it now retries and saves exactly one photo. A separately injected Core Data save failure first left a duplicate inserted row; retry now preserves the unrelated row and saves only one capture. |
| 3. Lost cloud tombstones | Delete All preserves the existing persistent store and SQLite deletion history. An unrelated CloudKit export completion cannot confirm the deletion. | Failure and timeout cases first destroyed actual SQLite tombstones. They now retain them; unrelated successful export remains unconfirmed. |
| 4. New captures deleted by maintenance | Snapshot deletion object IDs before the first upload wait; remove the store rebuild from the entire maintenance action; retain the staging grace period. | Photos inserted during upload draining and during remote cleanup first disappeared. Newly staged capture bytes were also purged. All three now survive the complete maintenance flow. |
| 5. Mirrored upload bookkeeping | Store attempts, state, errors, and retry times in an atomic, device-local journal. Claim only complete staged originals on this device. Keep production Core Data schema fields for compatibility without reading or writing them as upload authority. Refresh UI from local journal notifications. Retain every Live resource until durable upload success. | A remote pending row first was claimed and mutated; an owned staged original first was blocked by mirrored pause/max-attempt values. Both now pass. Additional verification proves partial Live upload, restart, retry, and completion leave mirrored fields untouched and retain originals until success is durable. |

Final simulator run: **60 passed, 4 skipped, 0 failures** (64 distinct tests; parameterized executions count separately). This includes all unit tests and camera retry, normal capture saving, and pager UI tests on iPhone 17 Pro / iOS 26.5. The four existing CloudKit tests require an authenticated simulator and were skipped; an actual two-device cloud exercise was not performed.

Regression sources: [legacy originals, capture-row cleanup, and upload ownership](/Users/simonriepl/Developer/progress/progressTests/Services/LegacyOriginalAndUploadOwnershipTests.swift), [Delete All safety](/Users/simonriepl/Developer/progress/progressTests/DeleteAllPhotosSafetyTests.swift), and [camera retry UI](/Users/simonriepl/Developer/progress/progressUITests/progressUITests.swift).

Evidence bundles are in `/private/tmp`: `progress-p1-camera-red.xcresult`, `progress-p1-storage-red-2.xcresult`, `progress-p1-delete-and-retry-red.xcresult`, and `progress-p1-full-green.xcresult`. The local upload test transport is injected; its restart/retention assertions do not depend on a CloudKit account.

Release archive: **succeeded**, version **0.6.2 (9)**, bundle `me.riepl.progress`, team `PRMMZ6KL9P`. Archive: `/private/tmp/progress-p1-release.xcarchive`; log: `/private/tmp/progress-p1-release-archive.log`.

App Store Connect upload: **attempted through `xcodebuild -exportArchive`, but blocked before upload**. Xcode reported `Failed to Use Accounts` because its saved Apple accounts lack valid `Xcode-Token` credentials. No API key was found in the standard command-line locations or relevant environment configuration. Upload log: `/private/tmp/progress-p1-appstore-upload.log`. No computer-use tools were used. The archive and export-options plist (`/private/tmp/progress-appstore-export-options.plist`) are ready for retry after access is restored.

## Checked findings

### 1. [P1] Legacy originals become inaccessible after upgrading

- **Location:** [PhotoStorageService.swift:956](/Users/simonriepl/Developer/progress/progress/Services/PhotoStorageService.swift:956).
- **Trigger:** Upgrade a library written by `58302e3^` or earlier. Those versions stored originals in Core Data binary fields or older local asset directories, without the current CloudKit `PhotoAsset` records.
- **Impact:** Thumbnails survive, but full photos, Live Photos, sharing, and video export cannot find their originals. Existing data is still present but no longer read or migrated.
- **Verification:** Independently compared the historical write/read paths with current `loadFullImage`, `CloudKitService.loadAssetURL` (143–163), nil upload state defaulting to uploaded (70–75), and migration stubs (889–908). The stubs always return zero; current reads do not consult retained blobs or old directories.
- **Repair sketch:** Restore the legacy fallback and migrate originals into staging before removing it. Sketch: `loadAssetURL(name)` → `loadCurrentAssetOrMigrateLegacyPayload(photo)`.

### 2. [P1] Failed capture saves silently discard the preview

- **Location:** [ExperimentalCameraView.swift:686](/Users/simonriepl/Developer/progress/progress/Views/ExperimentalCameraView.swift:686).
- **Trigger:** Tap Done when local file staging or Core Data saving throws, such as when disk space runs out.
- **Impact:** The catch only prints the error. The caller always animates success, deletes pending Live Photo resources, and dismisses. The user loses the opportunity to retry the capture.
- **Verification:** Traced throwing staging operations and `context.save()` in `PhotoStorageService.savePhoto` (122–133,175–181) through the swallowed error and unconditional caller cleanup (623–653). Asset network uploads are queued later and are not this failure trigger.
- **Repair sketch:** Propagate failure and retain the preview/resources. Sketch: `await savePhoto(...); dismiss()` → `do { try await savePhoto(...); dismiss() } catch { showSaveError(error) }`.

### 3. [P1] Delete All destroys unexported cloud deletion history

- **Location:** [PhotoStorageService.swift:715](/Users/simonriepl/Developer/progress/progress/Services/PhotoStorageService.swift:715).
- **Trigger:** Delete an already synced library while cloud export fails or exceeds its 30-second timeout, with the account still considered available.
- **Impact:** The result requests a store rebuild even when cloud metadata deletion is pending or failed. Destroying SQLite discards unexported tombstones/history; remote metadata can return after reconnecting, while original-asset deletion proceeds separately.
- **Verification:** Checked all export outcomes (696–704), unconditional `shouldRebuildPersistentStore: true`, the maintenance caller (339–340), and `Persistence.rebuildPersistentStore` (188–194). Cloud deletion was reviewed by source; an authenticated offline-device integration run was not available.
- **Repair sketch:** Preserve the store/history until the actual deletion transaction is acknowledged. Sketch: `shouldRebuildPersistentStore: true` → `shouldRebuildPersistentStore: false` for failed or pending deletion; a successful unrelated export must not count as confirmation.

### 4. [P1] Delayed Delete All rebuild also deletes newly captured photos

- **Location:** [SettingsMaintenanceView.swift:339](/Users/simonriepl/Developer/progress/progress/Views/SettingsMaintenanceView.swift:339).
- **Trigger:** Start Delete All, leave maintenance while it waits for cloud completion, close Settings, and capture/import a new photo before the delayed task rebuilds the store.
- **Impact:** The rebuild destroys every row, including the new photo that was never part of the original deletion set or confirmation. Its staged original is left without its journal entry.
- **Verification:** Independently traced the unstructured maintenance task (332 onward), its awaits, the unconditional whole-store destruction, and the absence of a service-level capture/import gate. Navigation and Settings Close remain enabled; camera capture is gated only on import activity. An independent temporary SQLite reproduction of the same rebuild sequence had one newly saved row before rebuilding and zero afterward.
- **Repair sketch:** Avoid whole-store reconstruction after deleting a snapshot of rows; otherwise coordinate deletion and writes globally. Sketch: `deleteSnapshot(); await cloudCleanup(); rebuildStore()` → `deleteSnapshot(); await cloudCleanup()`.

### 5. [P1] Upload bookkeeping is mirrored and can block the device owning the original

- **Location:** [contents:21](/Users/simonriepl/Developer/progress/progress/progress.xcdatamodeld/progress.xcdatamodel/contents:21).
- **Trigger:** Device A exports pending/failed/uploading photo metadata before its original finishes uploading. Device B receives it and launches/foregrounds the app, with no matching staged original and no remote original yet.
- **Impact:** B claims the upload, fails reconciliation, and saves paused state into the same mirrored record. That state can reach A before its next scan, excluding the photo from automatic upload. Manual retry is then needed. An already present remote original or A finishing its active upload avoids the failure.
- **Verification:** Independently compiled the current model and a variant changing only `syncable="NO"` to `YES`: the resulting `.mom` files were byte-identical. Checked claim selection (2299–2334), missing-file reconciliation (2277–2284), pause classification (2529–2530), and paused-state persistence (2377–2387). Apple requires the model to be completely mirrored; the cross-device outcome is a control-flow inference from the verified model behavior, not a live two-device reproduction.
- **Repair sketch:** Keep upload attempts/retry state in a local store or local manifest and only claim photos whose original exists on this device. Sketch: mirrored `DailyPhoto.uploadStateRaw` → local state keyed by photo ID. Preserve existing production schema fields for compatibility while replacing their use with local tracking.
- **Framework evidence:** [Apple TN3164](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer) describes complete model mirroring.

### 6. [P2] Batch imports read a private Core Data context from the main actor

- **Location:** [PhotoStorageService.swift:309](/Users/simonriepl/Developer/progress/progress/Services/PhotoStorageService.swift:309).
- **Trigger:** Use a default batch import, which creates a private-queue background context.
- **Impact:** Both `hasChanges` checks (309 and 352) access that context outside its queue. Core Data concurrency diagnostics trap; ordinary runs perform unsupported cross-queue access and can race merges.
- **Verification:** Independently reran an isolated equivalent `hasChanges` access with `-com.apple.CoreData.ConcurrencyDebug 1`; it exited 133 in the Core Data queue-confinement assertion. Confirmed the service uses main-actor default isolation and default imports create a background context (244–245).
- **Repair sketch:** Check and save inside `perform`. Sketch: `if importContext.hasChanges { await importContext.perform { save() } }` → `await importContext.perform { if importContext.hasChanges { try importContext.save() } }`.

### 7. [P2] Capture-processing errors leave the camera controls disabled

- **Location:** [CameraService.swift:363](/Users/simonriepl/Developer/progress/progress/Services/CameraService.swift:363).
- **Trigger:** A still-photo processing error, invalid returned image bytes, or Live Photo movie processing failure occurs.
- **Impact:** Errors are printed without publishing a failure result. The final callback leaves the view in processing state, disabling shutter, Close, guide editing, and Live toggle. A successful still is also not offered when only Live video processing fails. Swipe dismissal remains an escape.
- **Verification:** Checked the early returns at 363–367 and 394–396, unconditional final callback at 412–415, the view handler at 234–238, and the disabled-state predicates at 69–74. This was verified by callback/state flow; physical camera failure injection was not run.
- **Repair sketch:** Publish a terminal failure, clear busy feedback, and permit retry; offer the still when only the movie fails. Sketch: `print(error); return` → `publishCaptureFailure(error); return`.

### 8. [P2] Removing the last matching favorite leaves its viewer stuck

- **Location:** [PhotoGridView.swift:426](/Users/simonriepl/Developer/progress/progress/Views/PhotoGridView.swift:426).
- **Trigger:** Open the only Hearted photo through the Hearted filter, unheart it, then close. The last Favorite Live Photo has the equivalent problem when unfavorited.
- **Impact:** The now-empty filtered snapshot removes `UIKitPhotoGridView`; closing still waits solely for a centering callback from that absent grid, leaving the full-screen viewer presented.
- **Verification:** Independently traced the conditional grid branch (122–126), favorite save/filter refresh, close request (437–438), and sole dismissal callback (441–445). Simple deletion of the last detail item is exempt because it calls `onClose(nil)`.
- **Repair sketch:** Dismiss directly when there is no grid to center. Sketch: `gridCenteringRequest = request` → `if dataController.isEmpty { finalizePhotoDetailDismissal() } else { gridCenteringRequest = request }`.

### 9. [P2] Filtered grid counts can hide newly captured or imported photos

- **Location:** [UIKitPhotoGridView.swift:144](/Users/simonriepl/Developer/progress/progress/Views/UIKitPhotoGridView.swift:144).
- **Trigger:** Delete the last Hearted photo while the Hearted filter is active, then capture/import an unhearted photo.
- **Impact:** Global counts refresh only when the filtered fetched results change. The new photo does not match, so `hasAnyPhotos` remains false: the app shows No Photos Yet and hides the filter button, making the saved photo inaccessible until relaunch or another matching change.
- **Verification:** Simulator probe confirmed a filtered insertion leaves model count 1 while the store contains 2. The strengthened probe reproduced the empty-library sequence: the store contained one new photo while the controller still reported zero. Source checks show `refreshCounts` has no independent observer for changes outside the active predicate.
- **Repair sketch:** Observe unfiltered library counts independently. Sketch: `filteredFRC.didChange → refreshCounts()` → `allPhotoChanges → refreshCounts()` plus the filtered snapshot update.

### 10. [P2] Normal picker import silently drops Live Photo video with limited/denied access

- **Location:** [PhotoImportCoordinator.swift:233](/Users/simonriepl/Developer/progress/progress/Services/PhotoImportCoordinator.swift:233).
- **Trigger:** Choose a Live Photo outside the app’s limited library selection, or with Photos read permission already denied, using ordinary Import Photos.
- **Impact:** When `PHAsset` cannot be fetched, the fallback loads an image-only transferable and creates a payload with no video, despite `preserveLivePhotos` and the UI’s promise to keep Live Photos.
- **Verification:** Independently checked inaccessible-asset fallback (233–248), `.image` FileRepresentation (593–599), and the missing movie field. Apple confirms picker selection does not expand limited-library access. This is not a claim that every first import fails; an accessible PHAsset uses the paired-video path.
- **Repair sketch:** Provide a paired-resource import or explicitly handle permission failure before promising a Live Photo import. Sketch: image-only fallback under `preserveLivePhotos` → paired fallback or an explicit recoverable error.
- **Framework evidence:** [Apple Photos picker guidance](https://developer.apple.com/forums/thread/650902) confirms limited access does not expand for picker selections.

### 11. [P2] Historical imports lose Photos-library date and location metadata

- **Location:** [PhotoImportCoordinator.swift:184](/Users/simonriepl/Developer/progress/progress/Services/PhotoImportCoordinator.swift:184).
- **Trigger:** Import an older screenshot/PNG or an asset with library-assigned date/location but no corresponding EXIF fields.
- **Impact:** The importer discards `PHAsset.creationDate` and `location`; storage substitutes today’s import time and zero coordinates. Historical photos appear in the wrong place in the timeline and map.
- **Verification:** Independently checked byte-only payload construction (184,199–201,317), payload fields, and EXIF-only fallback (PhotoStorageService 1346–1352). Apple exposes the asset’s creation date separately from its image bytes. Existing valid EXIF avoids this fallback.
- **Repair sketch:** Carry library metadata through the payload. Sketch: `captureDate: exifDate ?? createdAt` → `captureDate: exifDate ?? payload.libraryCreationDate ?? createdAt`, with the same fallback for location.
- **Framework evidence:** [PHAsset.creationDate](https://developer.apple.com/documentation/photos/phasset/creationdate) is separate asset creation metadata.

### 12. [P2] Revoking location access leaves stale coordinates attached to new captures

- **Location:** [LocationService.swift:30](/Users/simonriepl/Developer/progress/progress/Services/LocationService.swift:30).
- **Trigger:** Obtain a location fix in the camera, background it, revoke location permission in system Settings, return to the same camera, and capture.
- **Impact:** Denied/restricted authorization neither clears `currentLocation` nor prevents capture/save from reading it. New photos receive the old location even after permission is revoked.
- **Verification:** Independently checked the retained StateObject, authorization callback (30–35), capture usage (ExperimentalCameraView 490), and save usage (667–671). A newly created service with no retained location avoids this specific sequence.
- **Repair sketch:** Clear the fix and stop updates when unauthorized, and gate location consumption. Sketch: denied branch doing nothing → `stopUpdatingLocation(); currentLocation = nil`.

### 13. [P2] Pausing during final video assembly duplicates the last photos on resume

- **Location:** [PortraitVideoExportService.swift:756](/Users/simonriepl/Developer/progress/progress/Services/PortraitVideoExportService.swift:756).
- **Trigger:** A multi-segment export reaches finishing, then background fallback cancellation runs with a pause requested.
- **Impact:** The paused session combines the last checkpoint’s completed count with filenames that already include the completed final segment. Resume repeats the tail and concatenates duplicates.
- **Verification:** Simulator probe: eight photos at 30/s paused with completed count 5 and two segments covering all eight. Resume yielded 0.3667 seconds (11 frames), rather than 0.2667 seconds (8 frames). Independently checked the final segment append (709–710), stale-count catch (749–763), and background cancellation path (sheet 1017–1023).
- **Repair sketch:** Checkpoint count and files together before concatenation. Sketch: `completedPhotoCount: lastStoredCompletedPhotoCount` → use the completed count corresponding to the retained segment filenames.

### 14. [P2] Selected video speed differs from the exported speed

- **Location:** [PortraitVideoExportService.swift:553](/Users/simonriepl/Developer/progress/progress/Services/PortraitVideoExportService.swift:553).
- **Trigger:** Choose a non-divisor speed below 30, such as 20 or 21 photos per second, with ordinary still photos.
- **Impact:** Rounding a fixed number of 30-fps frames per photo yields 15 photos/s at the 20 setting, or 30 photos/s at the 21 setting. Duration estimates still use the requested rate.
- **Verification:** Simulator probe with eight stills at 20/s produced 0.5333 seconds instead of 0.4 seconds. Independently checked integer rounding and that the UI permits every integer from 1 through 60 (sheet 205–218).
- **Repair sketch:** Schedule frame boundaries from cumulative requested timing or use an appropriate frame rate. Sketch: constant `round(fps / pps)` per photo → cumulative boundaries derived from `index / pps`.

### 15. [P2] Canceling Save to Files silently deletes the generated video

- **Location:** [PortraitVideoExportSheet.swift:142](/Users/simonriepl/Developer/progress/progress/Views/PortraitVideoExportSheet.swift:142).
- **Trigger:** Create a video, open Save to Files, then cancel the document picker.
- **Impact:** Unconditional sheet dismissal cleanup deletes the only unsaved export and removes Video Ready, requiring export to run again. Other discard actions in this screen require confirmation.
- **Verification:** Independently checked that picker cancellation reports false, the result callback handles only true, and `onDismiss` always removes the file via `cleanupExportedVideo` (1103–1106).
- **Repair sketch:** Retain the export on cancel. Sketch: unconditional `onDismiss { cleanupExportedVideo() }` → cleanup only after `didExport == true` or explicit discard.

### 16. [P2] Saving one photo can mark a different photo as already saved

- **Location:** [PhotoDetailView.swift:555](/Users/simonriepl/Developer/progress/progress/Views/PhotoDetailView.swift:555).
- **Trigger:** Start Save to Photos on photo A, then swipe to photo B while A’s download/library save is pending.
- **Impact:** A’s completion sets the current view’s saved flag, so B displays Saved to Library and its save button is disabled even though B was not saved.
- **Verification:** Independently checked the captured item at 549–553, unconditional saved-state write, paging remaining enabled at 338–343, and the selected-index reset at 377–379.
- **Repair sketch:** Key saved state by object ID or guard against a changed current item. Sketch: `hasSavedCurrentItemToLibrary = true` → `if self.currentItem?.objectID == savedID { hasSavedCurrentItemToLibrary = true }`.

### 17. [P2] Map annotations disappear across the International Date Line

- **Location:** [PhotoRouteMapView.swift:1342](/Users/simonriepl/Developer/progress/progress/Views/PhotoRouteMapView.swift:1342).
- **Trigger:** View a map region centered at longitude 179° with a 20° span and a photo at −179°, or the reverse.
- **Impact:** The photo is only 2° away and inside the map, but the raw longitude bounds exclude it, so viewport filtering removes its annotation.
- **Verification:** Independently checked the numeric bounds including 0.18 padding and their use in annotation filtering (241–242). Longitudes wrap at ±180°; latitude is unaffected.
- **Repair sketch:** Compare normalized angular longitude distance. Sketch: raw lower/upper longitude bounds → `abs(wrappedLongitudeDifference) <= halfLongitudeDelta`.

### 18. [P2] Reminder edits after returning from Storage Management are lost

- **Location:** [NotificationSettingsView.swift:419](/Users/simonriepl/Developer/progress/progress/Views/NotificationSettingsView.swift:419).
- **Trigger:** Open Storage Management from Settings, return, change/add/remove a reminder, then close Settings.
- **Impact:** The first disappearance sets `didPersistChanges` permanently. The same view state survives the navigation round trip, so the later close skips all subsequent reminder edits.
- **Verification:** Independently checked the root Form’s onDisappear (230–231), NavigationLink push, persistent State flag, and all mutations: none reset the guard. A second reviewer confirmed this state path.
- **Repair sketch:** Persist whenever the configuration changes or reset the guard on new edits. Sketch: permanent `didPersistChanges` → a dirty flag cleared after saving and set by reminder mutations.

### 19. [P2] Metadata repair repeatedly selects GPS-less photos and starves older records

- **Location:** [PhotoStorageService.swift:402](/Users/simonriepl/Developer/progress/progress/Services/PhotoStorageService.swift:402).
- **Trigger:** At least 24 recent records lack GPS, with an older record needing capture-date/location repair from its asset.
- **Impact:** Every repair run selects the same newest GPS-less records. Valid images without GPS remain candidates forever, so the older repairable record is never visited.
- **Verification:** Independently checked the fixed newest-first limit, predicate accepting zero coordinates, and the lack of an inspected marker/cursor after a no-op. Grid passes limit 24 and marks its session repair complete after that single batch. An independent Core Data reproduction using the production query selected the same 24 records twice and never selected the older missing-date record. This affects repair of incomplete existing metadata; fresh imports usually extract metadata upfront.
- **Repair sketch:** Persist inspection progress or page through candidates even when no metadata changes. Sketch: fixed newest batch every run → cursor/inspection marker plus complete traversal.

### 20. [P2] Compression repair exceptions leave invalid output in the original file

- **Location:** [compress.py:196](/Users/simonriepl/Developer/progress/plugins/caveman/skills/compress/scripts/compress.py:196).
- **Trigger:** An initial compression changes protected fenced code, validation rejects it, and the repair API/CLI call throws.
- **Impact:** The original file has already been overwritten. The repair exception bypasses restoration, leaving invalid output in place; a backup exists but must be restored manually.
- **Verification:** Independently reproduced using temporary files and a mocked compressor: a changed fenced command followed by a repair RuntimeError left `restored original: False`. No external API was called.
- **Repair sketch:** Validate a temporary candidate before committing or restore on every exception after backup. Sketch: `write(); repair()` → guarded transactional validation/replace.

### 21. [P2] Compression validation accepts altered inline commands

- **Location:** [validate.py:150](/Users/simonriepl/Developer/progress/plugins/caveman/skills/compress/scripts/validate.py:150).
- **Trigger:** Compression changes an inline command while preserving heading count and fenced blocks.
- **Impact:** The validator can report success even if an inline `npm test` becomes `rm -rf project`, contrary to the compressor’s exact-code requirements. Indented code is also not validated.
- **Verification:** Independently ran the actual validator on temporary original/compressed Markdown; the altered inline command returned `is_valid=True`. Heading/path mismatches are warnings rather than rejection.
- **Repair sketch:** Validate inline/indented code exactly and reject required structural changes. Sketch: fenced-only comparison → comparison of every protected code span/block.

### 22. [P2] Hook installation overwrites shared module configuration

- **Location:** [install.sh:108](/Users/simonriepl/Developer/progress/plugins/caveman/hooks/install.sh:108).
- **Trigger:** Install into a hooks directory that already contains `package.json` with `type: module` and an unrelated ES-module JavaScript hook.
- **Impact:** The installer overwrites that shared file with `type: commonjs`, breaking unrelated hooks. Uninstall also deletes the shared package file.
- **Verification:** Independently reproduced under a temporary `CLAUDE_CONFIG_DIR`: custom hook exit code changed from 0 before installation to 1 after it; installation itself succeeded. Equivalent Windows code exists in install.ps1.
- **Repair sketch:** Use a dedicated Caveman directory or `.cjs` files without altering shared package configuration. Sketch: `$HOOKS_DIR/package.json` → `$HOOKS_DIR/caveman/package.json` with corresponding script paths.

### 23. [P2] Hook uninstallation deletes unrelated hooks grouped with Caveman

- **Location:** [uninstall.sh:69](/Users/simonriepl/Developer/progress/plugins/caveman/hooks/uninstall.sh:69).
- **Trigger:** A SessionStart or UserPromptSubmit entry contains both a Caveman hook and an unrelated custom hook.
- **Impact:** The uninstaller removes the entire parent entry when any child mentions Caveman, deleting the unrelated sibling too.
- **Verification:** Independently reproduced with a temporary grouped configuration: uninstall transformed it into `{}`, losing both commands. Equivalent Windows filtering exists at uninstall.ps1 75–85.
- **Repair sketch:** Filter only owned child commands, then remove a parent only if empty. Sketch: `entries.filter(e => !containsCaveman(e))` → remove matching children inside each entry and preserve remaining siblings.

The two compressor defects occur in all three identical script copies: `skills/compress/scripts`, `caveman-compress/scripts`, and `plugins/caveman/skills/compress/scripts` under the bundled Caveman directory.

## Validation and limits

- Simulator Debug build and test bundle succeeded with Xcode 27 and an iOS 26.5 simulator.
- Existing tests: **44 passed, 4 skipped, 0 failed**. This includes the mocked capture/save and pager UI tests. Four authenticated CloudKit tests were skipped.
- Three temporary simulator probes reproduced video-rate rounding, finishing-pause tail duplication, and stale filtered counts. The strengthened suite passed all three probes, including the hidden-new-photo sequence. Assertions in these probes describe observed defects, not desired behavior. The temporary test file was removed from the project after verification.
- Isolated Core Data confinement probe independently reproduced the off-queue trap. Independent temporary SQLite probes also reproduced the metadata-selection starvation and loss of a new row during delayed store rebuilding.
- Two independently compiled model variants produced identical binary models despite opposite syncable flags.
- Four plugin defects independently reproduced using temporary files/configuration and mocked compression responses.
- An initial unsigned test attempt failed for missing CloudKit entitlements; the correctly signed rerun passed. This was a test setup failure, not a project finding.
- No authenticated two-device CloudKit scenario or physical camera-error injection was available. Those findings were verified from model compilation, historical data paths, framework guidance, and explicit control flow.

Evidence: [existing test log](/private/tmp/progress-adversarial-review-signed-tests.log), [simulator probe log](/private/tmp/progress-adversarial-review-probes.log), [strengthened probe log](/private/tmp/progress-adversarial-review-grid-probe.log), [temporary probe source](/private/tmp/progress-review-probes.swift), [Core Data probe](/private/tmp/progress-coredata-confinement.swift), [confinement output](/private/tmp/progress-review-context-probe.log), [SQLite follow-up source](/private/tmp/progress-storage-followup-probes.swift), [SQLite follow-up output](/private/tmp/progress-review-storage-followup.log).

## Examined but excluded

- Retake animation completion potentially clearing a subsequent capture: no proven interaction/callback sequence within the animation window.
- Remote deletion racing an in-flight original upload: deleting its staging file can fail the upload; actual CloudKit commit ordering was not reproduced.
- Export retries after partial frame writes and asynchronous writer-readiness failure: plausible failure paths without injected reproduction.
- Importing original versus edited Live Photo resources: intended edit-preservation semantics were ambiguous.
- Suspected dictionary-fetch object ID failure: an actual Core Data probe disproved it.

Fix sketches describe the direction, not complete patches. Resolve the P1 data retention and sync problems first, then add regression coverage for the confirmed P2 scenarios.
