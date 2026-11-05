# Capturing a slow video export

Install a build containing `VideoExportDiagnostics` on the phone before starting
the reproduction. No logging switch, launch argument, or debug configuration is
required. The export uses notice-level unified logging (errors use error level)
under the app's bundle identifier, category `VideoExport`. Each line starts with
`[VideoExport]` and carries a unique `run` identifier for that export attempt.

## Capture

1. Connect the phone to the Mac. Open Console, select the phone under Devices,
   and start streaming before starting the export. Alternatively, run the app
   from Xcode and capture its debug console output.
2. Filter messages for `[VideoExport]` (or category `VideoExport` in Console).
   Confirm that `event=export.begin` appears when the export starts.
3. Use the same photo selection and export settings that previously became slow.
   Keep capturing through the slowdown, ideally for another one or two minutes.
4. Save/copy the full matching log, including the fast beginning. Include the
   approximate time and photo count when the slowdown became visible. If you
   pause or cancel, keep those final lines too.

Capture live: unified log retention is controlled by iOS, so retrieving every
notice message after a long export is not guaranteed. These changes do not add
an in-app log file or a share-logs button.

## Recorded evidence

- Export configuration, app/build/OS, concurrency, start/end/pause/cancellation.
- Per-photo index and total, opaque asset tag, monotonic elapsed milliseconds.
- Prefetch permit wait, local/staged/offline/readable-cache/cloud source and bytes.
- CloudKit fetch operation ID, configured QoS, network state and timeouts.
- CloudKit error domain/code, retry-after, throttle flag, underlying errors and
  a bounded sample of partial errors. MapKit throttle-window numbers, if present.
- Actual retry attempt and next delay, application download deadline expiration.
- Separate asset wait, image decoding, rendering, banner/geocoding, segment
  checkpoint and final concatenation timings.
- Low Power Mode and thermal state at start/end and every 50 completed photos.
  Thermal raw values: 0 nominal, 1 fair, 2 serious, 3 critical.

Asset tags correlate prefetches with photos without exposing filenames. These
diagnostics do not log image contents, dates, coordinates, resolved locations,
local paths, or complete error user-info dictionaries. Logging is scoped to the
export task and inherited prefetch tasks; unrelated sync work is excluded.

## Interpretation

- `cloudkit=requestRateLimited` or `cloudkit=serviceUnavailable` together with
  `retry_after_s`/`should_throttle` supports CloudKit throttling.
- Slow successful `cloudkit.fetch` spans alone do not establish rate limiting.
- A transition from local/cache sources to `source=cloudkit` explains a cache
  advantage at the beginning. CloudKit may also reuse its internal asset cache;
  the app cannot tell whether a successful CloudKit fetch transferred all bytes.
- Long `location.geocode` spans or GEO/MapKit throttle errors identify location
  lookup delays. Long `still.render`, `live.render`, or `segment.finish` spans
  identify media processing delays.
- `request.timeout` followed by a timed-out request identifies the app's
  deadline. `photo.attempt-failed` preserves the current retry behavior so the
  reproduction can reveal whether its delay conflicts with a server cooldown.

## Previous experiment: CloudKit fetch priority

The earlier `cloudkit-user-initiated-v1` experiment set CloudKit asset fetches requested
by the video exporter to `.userInitiated`, including prefetches and retry loads.
Other callers retained their existing priority. Batching, concurrency, timeouts,
retries, cache retention, and video settings stayed unchanged.

That build logged `event=export.experiment name=cloudkit-user-initiated-v1` and
`download_qos=userInitiated`. Actual `cloudkit.fetch.begin` lines showed
`qos=25`, instead of the previous unspecified value `qos=-1`.

Repeat the same photo selection, settings, and network conditions. The baseline
capture processed 382 photos: the first 250 were fast, then mean CloudKit fetch
duration grew from about 0.45 seconds to 16 seconds by photos 351–382. Continue
the new run beyond 500 photos if practical, because assets from the previous
run may now be cached. Compare fetch durations and source fields; early progress
alone cannot establish an improvement, and internal CloudKit cache reuse remains
unobservable. No speed improvement is assumed until the phone comparison.

## Current experiment: batched original fetches

`cloudkit-batch-six-v1` keeps `.userInitiated`, the 30-photo lookahead, and the
six-asset permit limit. Compatible remote original requests join a CloudKit
operation with up to six distinct records. A full batch submits immediately;
a partial batch schedules its flush after 10 ms so the tail does not wait for
six requests. Local/cache hits bypass batching. As individual
records finish, their callers continue immediately; a slower peer does not hold
the completed record or its permit. Timeout/cancellation removes only that
subscriber; the underlying operation is cancelled once no subscribers remain.
CloudKit may finish a cancelled record while its batch peers are still active;
the six-permit bound applies to active app requests, not CloudKit's internal
transfer scheduling.

The per-photo 30-second deadline and 15/30-second CloudKit request/resource
timeouts stay unchanged. Retries use the same batch scope. Background/offline
downloads and metadata fetches keep their existing request behavior.

Verify `event=export.experiment name=cloudkit-batch-six-v1`. Each
`cloudkit.batch.begin` includes the actual `record_count` and operation ID.
Individual `cloudkit.fetch.begin` lines use `mode=batch` and `qos=25`;
`cloudkit.fetch.submitted` associates their span with the shared operation and
records elapsed time before submission. Batch sizes may be smaller than six
when cache hits or staggered completion leave fewer compatible requests ready.

`cloudkit.fetch.progress` records the first callback, first positive progress,
and roughly 25/50/75/100 percent milestones, with elapsed milliseconds from that
record's fetch beginning and time since the previous report. The final
`progress-summary` includes `first_callback_ms`, `first_positive_ms`, and
`last_percent`. A -1 means CloudKit never reported that observation. These are
framework progress reports, not packet-level network measurements; absence or
coarseness of callbacks cannot by itself prove where a delay occurred.

Capture the same selection/settings/network through a slow wave and its recovery.
Compare batch operation count, per-record latency, submission delay, progress,
and bytes. The previous priority run showed shared 25–30-second stalls around
528–533 and 735–740, recovery around 751–850, and originals increasing from
roughly 0.4 MB to 1.5–2.1 MB after 900. Internal CloudKit cache reuse still
confounds early-run comparisons. Actual speed benefit needs another phone run.

Native CloudKit callbacks can deliver NSError rather than a Swift CKError. Error
normalization now preserves retry-after and nested partial errors in either form;
this also keeps missing-record translation consistent for batched callbacks.

Focused verification includes native-operation callback mocks (no network) for
six-record coalescing, partial failures, early completion, per-subscriber and
whole-batch cancellation, late callbacks, policy isolation, partial-tail flush,
and CloudKitService returning stable original bytes. Export recovery/audio tests
exercise the unchanged media and pause/resume paths.
