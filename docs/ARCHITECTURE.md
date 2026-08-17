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

The live configuration is chosen in one place, `CoreLocationUpdatesProvider.liveConfiguration`, so field testing can compare `.default` and `.fitness` without spreading configuration through the app. It currently uses `.default` and is deliberately not exposed as a user setting.

## Background activity sessions

A `CLBackgroundActivitySession` is created when the user starts a recording and is invalidated only when the recording stops or a failed recording is cleaned up.

It is intentionally **not** invalidated when `stationary == true`.

That is important because automatic resume is central to the design. Ending the background session during a stationary period could prevent the app from receiving the update that says the photographer has started moving again.

`RecordingCoordinatorTests.stationaryKeepsSessionsAlive` asserts this behavior directly.

## Location authorization

GPeX uses **When In Use + temporary full accuracy + a background activity session**. It never requests Always authorization.

The app also does not call `requestWhenInUseAuthorization()` directly. Instead, it creates and retains:

```swift
CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "PhotoTracking")
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
- **Session start anchor:** if the first good fix arrives within 30 seconds of Start and shows no evidence of movement, its coordinate can be duplicated at `startedAt` so photos taken immediately after Start have coverage. A much later first fix, or one observed while moving, is not backdated.
- **Session end anchor:** if the photographer is stationary when Stop is tapped, the last stationary coordinate can extend to `endedAt`. A stale moving fix is never projected forward.
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

## Component overview

```text
GpExApp / AppDelegate       @UIApplicationDelegateAdaptor; restores on launch
AppServices                 composition root

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
GPXTemporaryFile            temporary share file, purged at launch

Views                       RootView, HomeView, ActiveRecordingView,
                            SessionDetailView, CameraClockView,
                            ClockCorrectionView
```

Everything user-visible runs on the main actor. Location updates are infrequent enough that adding a second isolation domain would add coordination complexity without a meaningful benefit for this app.

## Info.plist and capabilities

GPeX uses:

- `NSLocationWhenInUseUsageDescription`
- `NSLocationTemporaryUsageDescriptionDictionary` → `PhotoTracking`
- `UIBackgroundModes` → `location`
- `ITSAppUsesNonExemptEncryption` → `false`

There is no `NSLocationAlwaysAndWhenInUseUsageDescription` because Always authorization is never requested.

The project has no networking capability, App Group, CloudKit dependency, or third-party package requirement.
