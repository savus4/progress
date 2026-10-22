# Timeline data preparation

Settings now offers timeline switching, creation, renaming, and deletion. Timelines keep
separate photos, reminders, and alignment guides inside the same account; this
does not add sharing between accounts.

## Identity and metadata

- `DailyPhoto.timelineID` is a logical UUID, independent of Core Data object IDs.
- `Timeline` stores its UUID, name, creation date, modification date and optional
  `deletedAt` and local removal `localDeletedAt` markers. Its fields
  are optional for CloudKit compatibility; there are no unique constraints or
  required relationships. Photos and timeline metadata can sync in either order.
- `TimelineIdentity.defaultID` is a permanent constant shared by every device.
  A missing photo owner means this default timeline, including photos received
  later from older app versions. Use `effectiveTimelineID` and
  `TimelineIdentity.photoPredicate(for:)` rather than testing the raw field.
- The default timeline exists logically without a metadata row until renamed or
  deleted. `TimelineStore` supplies its initial name. This avoids
  creating duplicate seed records on offline devices. Metadata reads coalesce
  duplicate UUIDs using the newest modification date. Any deletion marker wins
  over active duplicates or stale renames, including during store-copy merges.
  Active metadata merges prefer the destination on a timestamp tie.
- New capture/import APIs accept an explicit timeline UUID; existing callers
  retain the default. Import duplicate checks are scoped to the destination.
  Upload recovery journals persist ownership, with missing old fields interpreted
  as the default. Original asset identities remain photo-specific.
- An unnamed first timeline appears as `Default`. Every timeline can be renamed,
  including the only timeline. Names are persisted in the mirrored `Timeline` entity;
  local selection is remembered separately in `UserDefaults`.
- `TimelineSelectionStore` observes name changes merged into the view context, so
  names received from iCloud update the switcher without a restart. Unknown
  notification owners retain their UUID while their metadata is still syncing.
- Creation and renaming reject an active timeline's existing name, ignoring
  capitalization, surrounding whitespace, character width and equivalent Unicode
  encodings. The virtual Default reserves its name too. A timeline can change its
  own capitalization; deleted names can be reused with a new identity. The editor
  explains conflicts inline and disables saving, with a second check before the
  context mutates any metadata.
- Existing duplicates and collisions merged from offline devices are repaired
  when the timeline library refreshes. The first timeline in the stable library
  order keeps its name; others receive an available numeric suffix, respecting
  the 80-character limit and names such as `Alex (2)` already in use. The repaired
  names sync normally. Owners, photos and reminders are preserved. This needs no
  further schema migration.

## Existing users

`progressWithTimelinesLivePhotos` is the current Core Data model version. All five
previous versions remain bundled, including the first timeline model. The existing
automatic, inferred lightweight migration adds the optional owner field, metadata
entity and deletion dates as needed without deleting or recreating the store.
Existing photos keep their IDs, original data, assets, flags and dates. There is
no bulk ownership rewrite or re-upload on upgrade: nil ownership remains valid.
The previous timeline model retains its names and ownership, with no timeline
initially marked deleted.

The Xcode project explicitly registers all model versions and selects the current
one. When adding future versions, verify the compiled `progress.momd/VersionInfo.plist`
selects the intended version; this toolchain initially restored the previous
selection when the new model sorted before it.

Device-local reminder preferences migrate to the default timeline only. Other
timelines start with no times and the usual skip-after-photo preference. Reminder
identifiers, notification payloads, schedule state and today's-photo checks carry
the timeline UUID. Old notification payloads still target the default timeline.
Reminders stay device-local, matching current behavior.
The reminder screen briefly notes that they do not sync between devices.

Reminder configuration is reached through Edit Timeline, alongside its name and
deletion controls. The editor opens without focusing the name field, so reminders
are immediately accessible. Reminder navigation captures that timeline's UUID;
returning preserves a draft name. Close saves a valid changed name and dismisses
only after saving succeeds; an unchanged name closes without a metadata write.
Invalid names remain editable. Swipe dismissal is blocked while a name has unsaved
changes, preventing accidental loss. New Timeline retains its Create button. Storage in the main Settings groups Photo Storage with sync status. Photo Storage’s
Advanced section contains Storage Management and Import. Import still captures the
selected timeline as its destination.

Clean local-store copies and iCloud library preparation copy timeline metadata
alongside photo ownership. Removing cloud copies includes mirrored timeline rows
in the durable deletion plan and unknown-record inventory.

## Deleting a timeline

The Edit Timeline sheet also offers Delete Timeline, with a separate destructive
confirmation describing the photos and reminders that will be removed. The last
timeline cannot be deleted; this is checked again inside the context operation,
not only by disabling the button. Deletion is blocked during imports or a
storage-mode migration.

Default can be deleted when another timeline remains. In sync mode its UUID is
permanently retired; local removal can be restored from a kept cloud copy.
Selection moves to a surviving timeline. The app never reassigns
deleted photos to the survivor. A synced deletion never recreates the old Default. If two offline
devices each delete a different survivor, their merged library can have no active
timeline. In that case a fresh, empty timeline named Default is created using an
identity derived from the deleted IDs, so devices with the same deletion history
agree on its identity.

A saved deletion marker is the durable intent. A resumable worker removes owned
photos in batches through the existing photo deletion pipeline, including original
assets, upload ownership and remote asset cleanup when using iCloud. It clears
the timeline's local reminder preferences, scheduled reminders and alignment-guide
keys, including legacy Default keys. The worker runs on startup and subsequent
saves or cloud merges, so photos arriving late from offline devices are also
removed. Capture, import and crash-journal recovery reject deleted owners.

Timeline deletion waits for its queued reminder cleanup. Pending and delivered
notifications for that owner are removed explicitly, including legacy Default
notifications, even if notification authorization is now denied. Stale queued
settings cannot reschedule a deleted owner. When a synced deletion is processed
on another device, that device removes its own local reminder preferences too.

The marker remains synced, with the deleted name cleared. Keeping that minimal
identity prevents stale metadata, legacy nil-owned photos, or switching between
local and cloud stores from resurrecting a deleted timeline. In local-only mode,
the deletion is local until the user re-enables iCloud; the merge then carries its
marker into the cloud library.

## Release and follow-up work

Before shipping, initialize and verify the additive development CloudKit schema,
then deploy `CD_Timeline` (including `CD_deletedAt`, `CD_localDeletedAt`, `CD_livePhotoCaptureEnabled`, and `CD_livePhotoPreferenceModifiedAt`) and the new `CD_DailyPhoto`
owner field to Production.
Production CloudKit schema changes are additive; do not remove existing fields or
reset users' stores. Validate sync on two devices, including offline deletion and
late-arriving photos from an older app client.
See [Apple's schema evolution guidance](https://developer.apple.com/videos/play/wwdc2022/10120/).

Selection scopes grid filters, counts, map/detail contents and exports. Camera
and import operations capture their destination before work begins; switching
later cannot redirect an unfinished import. Alignment guides use separate local
and iCloud keys, retaining the legacy keys for Default. Notification navigation
selects the requested owner before opening the camera, waiting for modal work to
finish. Reminder notifications display timeline names when multiple timelines exist.

Storage limits, backup mode, caches and maintenance remain library-wide. Storage
Management explicitly labels its deletion tools as applying to all timelines.
Creating, renaming and deleting are disabled during storage-mode migration to prevent writes
being lost when the prepared store replaces its source. Older app versions still
show the whole library and do not understand deletion markers. Update clients
before relying on timeline deletion. Photos an older client adds to a retired
Default are removed when an updated app processes them; they are not reassigned.

Reminder requests share the system's 64-request budget across timelines. Timelines
without a photo today retain repeating reminders. Completed timelines share the
remaining capacity using the earliest date-specific occurrences, refreshed on
launch, day/time changes and saves. As with the existing skip-after-photo behavior,
an extended period without opening the app can exhaust a completed timeline's
one-shot horizon. If repeating reminders alone exceed 64, the earliest next
occurrences take priority.

## Verification

`TimelineMigrationTests` creates real SQLite stores from the previous models,
opens them through current persistence, checks preserved content and ownership,
and reopens the migrated store. Additional tests cover metadata copies/merges,
timeline-scoped imports, recovery journals, reminder migration and isolation.

The timeline UI adds focused coverage for remembered selection, name-only changes
from background contexts, input validation, timeline-specific grid filters and
store replacement, alignment-guide migration, and named reminder updates. UI tests
exercise creating, switching, renaming the only timeline, isolated reminder settings,
deleting Default and inline wrapping of the timeline buttons and plus button.

On 21 October 2026, the final focused unit/integration run passed 83 tests with
zero failures on iPhone 18 Pro. Coverage includes all prior model migrations,
deletion cleanup, late saves, interrupted upload journals, concurrent offline
deletions, stale metadata, storage-mode changes, selection, reminders and grid
scoping. All five timeline Settings UI tests passed. Creation, switcher and
wrapping screenshots were visually reviewed. Production schema deployment and
authenticated two-device sync remain release checks.

The name-uniqueness follow-up passed 33 focused checks, including an editor UI
test for creation and renaming. It also covers normalized name comparisons,
Default, name reuse after deletion, stable offline conflict resolution and the
maximum name length.

The Settings reorganization passed five UI checks on iPhone 18 Pro with no build
warnings: Storage navigation, reminder persistence after Storage Management,
reminder toggle persistence and Import access, separate timeline reminders, and
retaining a draft name while visiting Reminders. The Settings and Edit Timeline
screenshots were visually reviewed.

The reminder-deletion follow-up passed 29 focused checks, including timeline
deletion in the UI. Regression coverage includes queued edits, revoked notification
permission, legacy Default identifiers, pending and delivered notification removal,
waiting for cleanup, restart persistence and processing another device's deletion.

## Local removal and sync restoration

`progressWithTimelinesDeletionScope` adds optional `Timeline.localDeletedAt` through
lightweight migration. Existing synced `deletedAt` markers retain their meaning.
Local timeline deletion sets only `localDeletedAt`; it removes local photos,
reminders, guide preferences, and upload ownership without changing kept cloud
copies. Local removal markers survive restarts and local store copies.

Re-enabling iCloud imports the kept cloud library into a fresh store and omits
local removal markers and all locally removed owners' source photos. Before that
merge, their pending save journals and upload ownership are discarded against the
local source, including interrupted cleanup. Kept cloud timelines/photos return;
deleted device reminders do not. Permanent synced deletion markers still win over
stale active metadata. Names edited locally continue to merge normally.

Alignment guides respect the storage preference for reads, writes, and deletion.
Local edits persist with a pending-sync flag and publish after explicit opt-in.
Deletion confirmations distinguish local removal from synced deletion even while
iCloud is temporarily unavailable. Bulk local deletion does not report pending
cloud cleanup. Storage-switch consent describes restored timelines and photos.

The local/sync audit passed 64 focused unit/integration checks and four UI checks
on iPhone 18 Pro. Coverage includes restoring Default and named timelines,
clearing old reminders while allowing fresh ones, dropped stale save journals,
storage changes during bulk deletion, guide sync limits, migration from all four
previous schemas, and preservation of existing synced deletion markers. UI checks
cover both timeline deletion scopes, storage consent cancellation, and capture
saving. Cloud restoration uses an isolated simulated cloud fixture; authenticated
two-device sync remains a release check. Storage switching drains outstanding
timeline cleanup before restored cloud asset access is released.

## Timeline Live Photo preferences

`progressWithTimelinesLivePhotos` adds nullable `livePhotoCaptureEnabled` and
`livePhotoPreferenceModifiedAt` to Timeline with lightweight migration. Missing
preferences default to enabled, without writing defaults to iCloud. Each timeline
keeps its own choice. The preference clock is independent of name edits, so store
merges and duplicate metadata can retain the newest name and camera choice.

An explicit legacy device choice belongs to Default. A capable camera seeds it
only when no synced choice exists, with a baseline timestamp that loses to later
explicit changes. New timelines default to enabled. Unsupported cameras do not
seed or mutate synced preferences: effective capture combines the stored choice
with current hardware capability, and the toggle is disabled when unavailable.
Local mode stores the choice in the local library; enabling iCloud merges it like
other active timeline metadata. Kept cloud timelines restore their cloud choice.

Edit Timeline uses an accessible × button. It retains Close’s save, validation,
error handling, and protection against dismissing unsaved name changes.

Preference changes received while taking a photo apply to the next capture;
the active exposure keeps its original camera-session preference.

The Live Photo follow-up passed 38 focused checks on iPhone 18 Pro, including
migrations from all five prior schemas, independent metadata merges, local/cloud
restoration, unsupported-camera protection, capture saving, and the × editor.
The final camera-session guard passed a further nine focused checks. Cloud merges
use isolated fixtures; authenticated two-device sync and physical Live Photo
capture remain release checks.
