# Architecture

This document explains the implementation choices behind GPeX: how it records location efficiently in the background, how recordings recover across launches, how raw observations are stored, and how GPX output is generated for photography workflows.

For setup and basic usage, see the [README](../README.md). For test procedures, see [TESTING.md](TESTING.md).

## Core Location strategy

GPeX uses `CLLocationUpdate.liveUpdates()` rather than polling for location.

That API fits the intended use case well: a sports photographer can stand in one place for long stretches, then move to a new position. Core Location can recognize stationary periods, reduce delivery, let the process suspend, and resume when the device moves again.

Each update also reports state through values such as `stationary`, `accuracyLimited`, `locationUnavailable`, `insufficientlyInUse`, and authorization diagnostics.

GPeX therefore does not use:

- `Timer`-driven polling
- repeated `requestLocation()` calls
- `startUpdatingLocation()`
- significant-location-change monitoring
- visit monitoring
- geofences
- `BGTaskScheduler`
- Core Motion

The live configuration is chosen in one place, `CoreLocationUpdatesProvider.liveConfiguration`, and it is `.default`. That hands power management to Core Location, which is the whole strategy: it decides which hardware to run, how often to fix a position, and when to stop delivering because the device has not moved. It is deliberately not exposed as a user setting.

Exactly one `CLLocationUpdate.liveUpdates(.default)` stream, one `CLServiceSession` and one `CLBackgroundActivitySession` exist per recording. `RecordingCoordinator.beginStreams(for:)` refuses to create a second stream, `TestLocationUpdatesProvider` counts both streams and sessions, and the invariant is asserted directly in `RecordingCadenceTests.exactlyOneStreamPerRecording`.

### No activity classification

GPeX makes **no claim about whether the photographer is moving.** It has no Core Motion, no speed thresholds and no timers, so an activity classification would be a guess presented as a fact.

There are three running states, and only one of them is inferred from anything:

| State | When |
|---|---|
| `tracking` | the ordinary state — Core Location has not said anything more specific |
| `stationary` | Core Location set `stationary` on the update itself |
| `temporarilyUnavailable` | Core Location set `locationUnavailable` |

`stationary` therefore requires an explicit report, and it ends the moment Core Location delivers a non-stationary location again — at which point the recording returns to plain `tracking`, not to anything called "Moving". Nothing stops or restarts a session to make that happen; Core Location resumes delivery on its own.

## The saved-location interval

How often Core Location *delivers* is Apple's decision. How often GPeX *saves* is the photographer's, and the two are entirely separate.

`LocationSaveInterval` offers 10 s, 20 s, 30 s (the default and the one marked recommended) and 1 minute. It is a **minimum persistence interval, not a GPS polling interval**: nothing about it reaches `liveConfiguration`, requests a location, or schedules anything. Choosing one minute costs no more battery than choosing ten seconds — it simply keeps fewer of the fixes Core Location was going to send anyway.

`SavedLocationGate` is the whole implementation, and it is a pure value with no clock of its own. It is handed a fix that already passed the coordinator's validation and answers one question: save it, or let it go.

- The **first fix** of a recording is always saved, so a session is never empty while it waits.
- Otherwise the interval is a floor: fixes arriving inside it are coalesced.
- Four things are more informative than a stopwatch and get in early:
  - **meaningful displacement** — further apart than the two fixes' combined horizontal accuracies, with a 10 m floor. A fixed `distance > 10` rule would call 55 m between two ±50 m fixes movement, which is well inside what standing still produces; the same 55 m between two ±8 m fixes really is a walk down the touchline.
  - **materially improved accuracy** — at least halved *and* at least 5 m tighter. Both conditions are needed: the ratio alone fires on 2 m → 0.9 m, the absolute figure alone on 800 m → 790 m.
  - **explicit stationary information** — the arrival of `stationary`, so becoming stationary is always recorded. Repeats of it obey the interval again, so an hour parked in one place is not an hour of identical rows.
  - **the first usable fix after stationary** — the moment the interval would otherwise hide for a whole minute.

Only a write that actually succeeded advances the gate, so a failed append does not make the next fix look early.

The active interval is fixed for a recording's lifetime, is written into the recovery marker, and is restored from it — so an interrupted recording resumes at the cadence it was interrupted at rather than at today's preference. A marker written before the setting existed is honoured rather than discarded, and fills in 30 seconds.

The preference itself lives in `RecordingPreferences` (`UserDefaults`, stored as a plain number of seconds) and is read in exactly one place: `RecordingCoordinator.startRecording()`. Every way in — a tap, an App Intent, a Shortcut — arrives at that line, which is what makes App Intents use the saved preference without knowing it exists.

## Background activity sessions

A `CLBackgroundActivitySession` is created when the user starts a recording and is invalidated only when the recording stops or a failed recording is cleaned up.

It is intentionally **not** invalidated when `stationary == true`.

That is important because automatic resume is central to the design. Ending the background session during a stationary period could prevent the app from receiving the update that says the device is no longer stationary.

`RecordingCoordinatorTests.stationaryKeepsSessionsAlive` asserts this behavior directly.

## Location authorization

GPeX uses **When In Use + temporary full accuracy + a background activity session**. It never requests Always authorization.

The app also does not call `requestWhenInUseAuthorization()` directly. Instead, it creates and retains:

```swift
CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "GPeXTracking")
```

Creating the service session is what prompts the user. Its diagnostics sequence reports the result, including `fullAccuracyDenied` when Precise Location is disabled.

Reduced accuracy is not treated as a recording failure. Recording continues and the UI warns that Precise Location is off and photo positioning may be inaccurate.

`CLRequireExplicitServiceSession` is deliberately not set in Info.plist. GPeX already creates a service session before consuming updates, so the key would not change the intended behavior, and `serviceSessionRequired` diagnostics are handled either way.

## Recording recovery

A small recovery marker is stored in `UserDefaults`. No location history is stored there.

```text
recordingRequested        Bool
activeRecordingSessionID  UUID
activeRecordingStartedAt  Date
```

`recordingRequested` is written last and cleared first so a partially written marker does not appear active.

`AppDelegate.application(_:didFinishLaunchingWithOptions:)`, bridged through `@UIApplicationDelegateAdaptor`, calls `RecordingCoordinator.restoreInterruptedRecordingIfNeeded()` early in launch.

The restoration path is synchronous until Core Location interest has been re-established:

1. Read the recovery marker.
2. Create the `CLServiceSession` and `CLBackgroundActivitySession`.
3. Start consuming `liveUpdates()`.
4. Resolve the matching SwiftData recording asynchronously.

Opening the persistent store can take too long to do before expressing renewed interest in location updates.

Points that arrive before the SwiftData row is resolved are not buffered as orphaned model objects. `TrackPoint.sessionID` is a plain `UUID`, and each write waits for a small `sessionPreparation` task. If no matching open session exists, the marker is treated as stale and the recording is abandoned rather than invented.

Start and restore are both idempotent. `ActiveRecording` owns the single set of stream tasks, and `beginStreams` refuses to create a second set, so one recording cannot have two concurrent live-update streams.

### Force quit

Force-quitting the app is not treated as continuous background recording.

If the user force-quits and later reopens GPeX while a recovery marker is still present, the recording is restored into the same session and continues. The gap is left as a gap. GPeX does not fabricate coordinates to hide it.

An unfinished recording is not silently deleted. The exception is a recording that failed on authorization before capturing a single fix; that empty row is rolled back so denied permission does not leave an unusable recording in the list.

## SwiftData model

### `TrackSession`

Stores:

- `id`
- `name`
- `startedAt`
- `endedAt?`
- `cameraClockOffsetSeconds`
- `createdAt`

A session is active while `endedAt == nil` and its id matches the recovery marker.

### `TrackPoint`

Stores:

- `id`
- `sessionID`
- `timestamp`
- `latitude`
- `longitude`
- `altitude?`
- `horizontalAccuracy`
- `verticalAccuracy?`
- `speed?`
- `course?`
- `stationary`
- `isSimulatedBySoftware?`
- `isProducedByAccessory?`

Indexes exist on `sessionID`, `timestamp`, and `(sessionID, timestamp)`.

Optional values are `nil` when Core Location reports the corresponding value as invalid. Altitude is stored only with valid vertical accuracy; speed and course are stored only when their own accuracy values are non-negative.

Only raw observations are persisted. GPX bridge points and session start/end anchors are generated during export and never written back to the database. This keeps the original observations intact if the export algorithm changes later.

`TrackPoint` intentionally has no SwiftData relationship to `TrackSession`; deleting a session explicitly deletes its points in the same store operation.

All SwiftData access goes through `TrackStore`, a `@ModelActor`. Model objects do not cross the actor boundary; only `Sendable` snapshots and `LocationSample` values do.

## GPX stationary-bridge algorithm

This is the key export behavior for photography.

Suppose a photographer stands at position A from 12:00 to 12:10, then walks to position B. Core Location may stop delivering updates while the phone is stationary, leaving raw observations like this:

```text
12:00:00  A
12:00:10  A   stationary
12:10:00  B   resumed
```

Software that linearly interpolates between the second and third points can conclude that the photographer spent ten minutes drifting across the field. Photos taken during the stationary period can then receive incorrect positions.

`GPXExporter` instead holds the stationary coordinate until one second before the resumed fix:

```text
12:00:00  A
12:00:10  A   real observation, real timestamp
12:09:59  A   GPX-only bridge point
12:10:00  B   real observation, real timestamp
```

The move becomes a near-step rather than a fabricated ten-minute drift.

### Bridge rules

- **Anchor choice:** the bridge holds the most accurate fix within 30 seconds of the stationary transition. It does not average coordinates, because an average would invent a location that was never observed.
- **When a bridge is added:** only when the previous point is stationary, the gap is at least 15 seconds, and the resumed fix is at least 15 meters away.
- **Unknown gaps:** a gap without a stationary report might represent a tunnel or dropped fix. GPeX preserves that gap rather than assuming the photographer stood still.
- **Multiple stationary periods:** each period can receive its own bridge.
- **Session start anchor:** if the first good fix arrives within 30 seconds of Start and shows no evidence of movement, its coordinate can be duplicated at `startedAt` so photos taken immediately after Start have coverage. A much later first fix, or one whose reported speed shows the photographer was walking, is not backdated.
- **Session end anchor:** if the photographer is stationary when Stop is tapped, the last stationary coordinate can extend to `endedAt`. A stale non-stationary fix is never projected forward.

These two anchors are the only places anything in GPeX consults a reported speed, and they are export decisions about whether a coordinate may be projected onto a timestamp — not a status the app displays. The recording itself makes no claim about whether the photographer is moving.
- **Ordering:** generated points are sorted by effective timestamp, floored to whole seconds, and filtered to be strictly increasing. A real observation wins when a synthetic point lands in the same second. Two real fixes in one second collapse to the more accurate fix while preserving a stationary report from either one.

The exporter emits GPX 1.1 with UTC ISO 8601 timestamps built from a fixed Gregorian calendar, coordinates at seven decimal places using locale-independent formatting, `<ele>` only when valid altitude exists, XML-escaped names, and no proprietary extensions.

The completed document is parsed with `XMLParser` before it is shared.

`GPXExporter` is pure: it does not depend on Core Location, SwiftData, or `Date()`. The same inputs produce the same bytes, which keeps the export behavior deterministic and testable.

## Camera clock correction

`cameraClockOffsetSeconds` is defined as:

```text
cameraClockOffsetSeconds = camera time - actual iPhone time
```

| Situation | Offset |
|---|---:|
| Camera is 5 seconds slow | `-5` |
| Camera is 90 seconds fast | `+90` |

The offset is added to every exported GPX timestamp and to the exported session start/end anchors so every generated timestamp uses the same time base.

For example, a location fix recorded at 11:07:42 with an offset of `-5` is exported as 11:07:37, matching what a camera that is five seconds slow would have written into the photo metadata.

Raw stored timestamps are never changed. Camera correction belongs to the export transformation, so changing it causes a different export rather than rewriting recorded history.

Resolution is in seconds. `ClockCorrection` is the single place where the sign is converted for display/export semantics so the UI and exporter cannot disagree.

The **Camera Clock** screen shows a large local clock to tenths of a second, the local date, UTC time, and the current UTC offset. A photographer can photograph that screen before an event and compare it with the camera clock to measure drift. The screen keeps the display awake while visible and restores normal idle behavior when dismissed.

## System integrations

Four system integrations sit outside the recording engine. None of them is allowed to
become a second source of truth: `RecordingCoordinator` still owns recording state,
`TrackStore` still owns persistence, and `GPXExporter` still owns the exported bytes.

### App Intents

Two intents, no parameters, no Stop intent yet:

- `StartRecordingIntent` calls `RecordingCoordinator.startRecording()` — the same path
  the Start button takes. Idempotence is therefore the coordinator's, not the intent's:
  idle starts, and starting, recording or stopping all decline to create a second
  session. An intent that filtered on state itself would be a second state machine.
- `OpenCameraClockIntent` navigates to the existing `CameraClockView`.

Both set `openAppWhenRun`. For the Camera Clock that is obvious — there is nothing to
show otherwise. For Start it is a requirement: creating the `CLServiceSession` is what
asks for When In Use and for temporary full accuracy, and those are foreground
questions with UI attached.

Intents reach the app through one narrow dependency:

```swift
protocol GPeXIntentActions: Sendable {
    @MainActor func startRecording() async
    @MainActor func openCameraClock()
}
```

`AppServices` registers the production implementation with `AppDependencyManager` at
launch. `AppDependencyManager` only resolves inside the system's perform flow, so tests
assign `intent.actions` directly — which is possible precisely because there is nothing
else for an intent to reach.

### GPX export as a Transferable

```text
TrackStore → session snapshot + points → GPXExporter → GPX string
           → GPXExportItem → ShareLink
```

`GPXExportItem` is a carrier and nothing more. It holds the string `GPXExporter`
produced and the filename `GPXExporter.filename(for:)` chose, and exposes them through
a `FileRepresentation` for `UTType.gpx`, because a `.gpx` is a document rather than a
blob. `SessionDetailView` builds the item ahead of the tap so the row can say "no usable
locations" instead of failing after the share sheet is already open; the bytes only
become a file at the instant the system asks for one.

### MetricKit

One `PerformanceMonitor` for the life of the process, owned by `AppServices` and started
from `didFinishLaunchingWithOptions` *after* recording recovery. It observes and never
acts: nothing it does can influence a recording, and nothing in recording waits on it.

- **iOS 27** uses `MetricManager`, consuming `metricReports` and `diagnosticReports` as
  async sequences. Exactly one manager exists per process. The recording domain is
  enabled on it, so hangs and terminations can be attributed to what the app was doing.
- **iOS 26** uses `MXMetricManager` and `MXMetricManagerSubscriber`. All of it lives in
  `LegacyMetricKitReceiver`; when the deployment target reaches iOS 27 that file is
  deleted and nothing else changes.

Reports are summarised to `Log.metrics` and, at most, five of each kind are kept as JSON
in Caches for a developer with the device in hand. Nothing is uploaded, and there is no
analytics SDK, backend or networking of any kind.

### StateReporting

On iOS 27 and later, GPeX describes its recording state to the system under the stable
domain `com.gbyo.gpex.recording`. The domain is deliberately not derived from
`PRODUCT_BUNDLE_IDENTIFIER`: `com.example.GPeX` is a placeholder that will change before
shipping, and a domain that changed with it would split the historical data in two.

The reported vocabulary is fixed and small, and carries no metadata at all — no session
IDs, coordinates, filenames or accuracy values:

```text
waitingForAuthorization → authorization
acquiringLocation       → acquiring
tracking                → tracking
stationary              → stationary
temporarilyUnavailable  → unavailable
stopping                → stopping
failed                  → failed
idle                    → no active state
```

Every failure reports the same label on purpose: a `RecordingProblem` can carry an
arbitrary storage-error message, and that must not become high-cardinality metadata.

Reporting happens in exactly one place. `RecordingCoordinator.setState(_:)` is the only
writer of `state`, so every real transition — start, restore, diagnostics, activity
updates, stop, failure, recovery — passes through a single
`RecordingPerformanceReporting.transition(to:)` call, and a phase that has not actually
changed is not reported at all. On iOS 26 the implementation is a no-op.

## Component overview

```text
GPeXApp / AppDelegate       @UIApplicationDelegateAdaptor; restores on launch
AppServices                 composition root
AppRouter                   @Observable navigation path, so an App Intent can
                            reach a screen from outside the view hierarchy

RecordingCoordinator        @MainActor @Observable; owns the state machine,
                            retained CL sessions, and stream tasks
RecordingState              enum carrying ActiveRecording; RecordingPhase is
                            the flat Equatable projection for views and tests
LocationUpdatesProvider     Core Location seam
  CoreLocationUpdatesProvider / TestLocationUpdatesProvider
LocationSample              Sendable value type; intrinsic validation
LocationUpdateEvent         flattened liveUpdates() delivery
RecoveryMarker(Store)       UserDefaults lifecycle marker

TrackStore                  @ModelActor; all SwiftData access
TrackSession / TrackPoint   models; snapshots cross the actor boundary

GPXExporter                 pure export transformation
GPXExportItem               Transferable carrier for ShareLink; generates
                            nothing, carries the exporter's bytes and filename
UTType.gpx                  imported com.topografix.gpx, declared in Info.plist
GPXTemporaryFile            staging for the file representation, purged at launch

GPeXIntentActions           the only surface App Intents touch
  AppIntentActions          production implementation over coordinator + router
StartRecordingIntent        calls RecordingCoordinator.startRecording()
OpenCameraClockIntent       routes to the existing Camera Clock screen
GPeXShortcuts               AppShortcutsProvider phrases; no parameters

PerformanceMonitor          one per process; MetricManager on iOS 27,
                            MXMetricManager on iOS 26. Observes only.
LegacyMetricKitReceiver     the whole deprecated MetricKit surface, isolated
PerformanceReportArchive    bounded local report copies in Caches
RecordingPerformanceReporting  seam from the state machine to StateReporting
  StateReportingRecordingReporter (iOS 27) / NoOpRecordingPerformanceReporter

RecordingLiveSnapshot       flat value the coordinator hands the Live Activity
RecordingLiveActivityManager  start / update / reconcile / end, nothing else
RecordingActivityHost       the ActivityKit seam
RecordingActivityAttributes   the only file shared with the widget extension

Views                       RootView, HomeView, ActiveRecordingView,
                            SessionDetailView, CameraClockView,
                            ClockCorrectionView
  Cards                       StatCard / NoticeCard, shared by Home and recording
  RecordingStatusText         phase → plain sentences (no SwiftUI)
  RecordingStatusStyle        phase → symbol + tint (SwiftUI)
  SessionGrouping             tracks → Today / Yesterday / month sections
  PhotographableScreen        awake, bright, overlay-free while visible
  PreviewSupport              in-memory world for #Preview (DEBUG only)
```

Everything user-visible runs on the main actor. Location updates are infrequent enough that adding a second isolation domain would add coordination complexity without a meaningful benefit for this app.

## The view layer

Two screens carry the app, and they are shaped differently on purpose.

**The recording screen is a hero, not a list.** A photographer reads it mid-event for under a second, so it is a status pill, an elapsed timer and two figures, centred in the screen with Stop pinned to the bottom in its own bar. It uses `Text(timerInterval:)` rather than a `TimelineView`: the text updates itself without invalidating the view every second, and it is the same construct the Live Activity uses, so the Lock Screen and the app cannot drift apart. The content is laid out with `minHeight: proxy.size.height` and centre alignment, so it sits in the middle when short and scrolls rather than clipping when a notice or an accessibility text size makes it tall.

**The home screen is content plus one action.** The list holds nothing but recorded tracks, grouped by `SessionGrouping` into Today / Yesterday / Earlier This Week / month. The Camera Clock is a tool rather than a track, so it lives in the toolbar. Start Recording sits in a bottom bar where it is reachable one-handed and cannot scroll away — which is also why search is pinned to `.navigationBarDrawer`: left to itself iOS 26 puts the search field in a bottom bar, directly underneath the primary action.

Nothing depends on colour alone. `RecordingStatusText` maps a phase to sentences and stays free of SwiftUI — it is unit tested, and the Live Activity's `Codable` state carries the same `String`s — while `RecordingStatusStyle` adds the symbol and tint beside that wording. Only the two genuinely in-progress phases animate their symbol, so motion means "something is happening" rather than decoration.

`SessionGrouping` takes `now` as a parameter and never consults the real clock; `Calendar.isDateInToday` would silently ignore that parameter, so day comparisons go through `isDate(_:inSameDayAs:)` against the injected value instead.

Every screen has `#Preview`s, built on `PreviewSupport`. Previews use the *real* `TrackStore` and `RecordingCoordinator` with only the two seams the app already has swapped — an in-memory store and `TestLocationUpdatesProvider`. A fake coordinator with settable properties could show a combination the state machine cannot produce; `RecordingPreviewHost` instead drives `startRecording()` and the real event stream, so a phase that renders wrongly in the canvas renders wrongly on a device too.

## The Live Activity

The Live Activity answers one question while the phone is locked and in a pocket: **is GPeX still recording correctly?** It is not a second application surface.

```text
● GPeX Recording                          1:42:18

Stationary
Saving battery
Accuracy ±7 m                        38 locations
```

It is a **read-only projection** of the recording state described above. There is no second state machine, no timer, no background task, and no Core Location or SwiftData in the widget extension.

### Why the timer is not an ActivityKit update

`Text(timerInterval:pauseTime:countsDown:showsHours:)` is rendered and advanced *by the system* from the static `startedAt` in the activity attributes. No elapsed value is ever sent through ActivityKit, and nothing wakes the app to move a clock. A Live Activity that pushed a new content state every second would undo the power behaviour the rest of this document describes.

ActivityKit hears from the app only when what is *displayed* changes — a status transition, a newly accepted fix that changes the shown accuracy, a new persisted point count, or reduced accuracy appearing. `RecordingLiveActivityManager` compares each candidate content state against the last one it sent and drops duplicates.

`staleDate` is deliberately `nil`. Core Location goes quiet on purpose while the photographer stands still, sometimes for hours, so any stale date would routinely mark a healthy recording as stale during exactly the situation this app is built for.

Two rendering details were found on a real Lock Screen rather than in a preview, and both are load-bearing:

- **`timerInterval`, not `Text(_:style: .timer)`.** The style renders a coarse relative phrase — "1 minute" — where a multi-hour track needs `1:42:18`. The interval must also be finite; `Date.distantFuture` leaves the timer with no sane ideal width.
- **No `.fixedSize()` on the timer.** A system-rendered timer's ideal width is wide enough that refusing to compress it overflows the row and the activity renders as an empty black capsule — silently, with `chronod` still logging a successful render.

### Statuses

Six presentation states, a lossy projection of `RecordingPhase` chosen for a two-second glance. Core Location vocabulary never reaches them, and neither does any claim about what the photographer is doing.

| `RecordingPhase` | Lock Screen |
|---|---|
| `waitingForAuthorization` | Waiting for Location Access |
| `acquiringLocation` | Acquiring Location |
| `tracking` | Recording — *Tracking location* |
| `stationary` | Stationary — *Saving battery* |
| `temporarilyUnavailable` | Location Temporarily Unavailable |
| `stopping` | Finishing Recording |
| `idle`, `failed` | no activity — it is ended, not relabelled |

**Stationary never says "Paused."** The recording is still running and resumes by itself, so calling it paused would invite the user to stop and restart — the one reaction that would actually lose data.

**And nothing ever says "Moving."** GPeX has no Core Motion, no speed thresholds and no timers, so an activity classification would be a guess dressed up as a fact. The ordinary state says what is actually true — locations are being tracked — and `Stationary` appears only when Core Location sets `stationary` on an update itself.

### Privacy

The content state has **nowhere to put a coordinate**: `status`, `horizontalAccuracy`, `pointCount`, `reducedAccuracy`, and nothing else. Accuracy is also *dropped* rather than shown stale whenever the status says no fix is current, because a radius from the last observation does not describe where the device is now.

### Where it attaches

One place: `RecordingCoordinator`. It builds a `RecordingLiveSnapshot` — id, start date, phase, accuracy, count, flag — and hands it over. The manager never sees an `ActiveRecording`, a `LocationSample` or a Core Location object, and dependencies point one way only. Nothing in `CoreLocationUpdatesProvider`, `TrackStore`, the views, `AppDelegate` or `GPXExporter` mentions ActivityKit.

`@preconcurrency import ActivityKit` is confined to `RecordingActivityHost.swift`: `Activity` is not `Sendable` yet its `update`/`end` are `@concurrent`, so the framework's supported API cannot otherwise be called from an isolated context.

### Failure only ever points one way

Every call into the manager is one-way and non-throwing. Recording proceeds normally if Live Activities are disabled, if ActivityKit throws, if the user dismisses the activity, or if the extension is unavailable — the failure is logged and that is the end of it. Conversely, a recording that stops, fails or is abandoned **ends** its activity, immediately rather than leaving "Recording Complete" on the Lock Screen for hours. `end()` is idempotent, and Stop works normally when there is no activity at all.

### Recovery

Restoration order is unchanged, and the GPX track stays authoritative:

1. rejoin the GPS recording exactly as described above;
2. *then* look through `Activity<RecordingActivityAttributes>.activities`;
3. adopt the one whose static `sessionID` matches — by id, never "the first one";
4. update it to the restored state, and end any leftovers from other sessions.

If Core Location relaunched the app in the background and no matching activity exists, none is created: recovery must not depend on ActivityKit. Once the user brings GPeX to the foreground with a recording still running, `reconcileLiveActivity()` recreates a missing one.

One deliberate exception: if the user *swiped the activity away* while this process kept running, it is not pushed back. A dismissal is a decision, and re-adding the activity on every foreground would be obnoxious.

### Interaction

Tapping opens `gpex://recording`, which calls `AppRouter.showActiveRecording()` — the same thing `StartRecordingIntent` does, because it is the same destination. The root already shows the active recording whenever one is running, so this needs nothing beyond popping to it. There is deliberately **no Stop button**: ending a multi-hour track by brushing a Lock Screen control would be costly, and an App Intent that mutated recording state would open a second route into the state machine.

## Info.plist and capabilities

GPeX uses:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationTemporaryUsageDescriptionDictionary` → `GPeXTracking`
- `UIBackgroundModes` → `location`
- `NSSupportsLiveActivities` → `true`
- `CFBundleURLTypes` → scheme `gpex`, the Live Activity's tap target
- `ITSAppUsesNonExemptEncryption` → `false`
- `UTImportedTypeDeclarations` → `com.topografix.gpx`, conforming to `public.xml`,
  with `gpx` as the filename extension. Imported rather than exported: GPX is an
  open interchange format GPeX writes, not a GPeX format.

There is no `NSLocationAlwaysAndWhenInUseUsageDescription` because Always authorization is never requested.

There is deliberately **no `NSSupportsLiveActivitiesFrequentUpdates`**. GPeX does not use ActivityKit push notifications and has no business asking for a frequent-update budget — it requests with `pushType: nil` and updates only when the displayed state changes.

The extension's own Info.plist (`Config/GPeXLiveActivity-Info.plist`) contains only `NSExtension` → `NSExtensionPointIdentifier` → `com.apple.widgetkit-extension`.

The project has no networking capability, App Group, CloudKit dependency, or third-party package requirement. Adding ActivityKit added no network capability, no push capability, no APNs, and no backend.
