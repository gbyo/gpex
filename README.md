# GPeX

A GPS track recorder for photographers. Start a recording, pocket the phone, shoot the
game, stop, export a `.gpx` file, and let Lightroom Classic assign coordinates to your
camera's photos by matching timestamps.

iPhone only. iOS 26.0 minimum. SwiftUI, SwiftData, Swift Testing. No third-party
packages, no backend, no networking, no accounts, no analytics, no Photos access.

- **Toolchain note:** built with Xcode 27.0 beta (iOS 27 SDK) with the deployment target
  held at iOS 26.0 and no iOS 27-only APIs. If `xcode-select` points at the Command Line
  Tools, build with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- **Before shipping:** `PRODUCT_BUNDLE_IDENTIFIER` is the placeholder
  `com.example.GPeX`. Change it and set a development team.

## 1. What it does

1. Open GPeX, tap **Start Recording**, grant location access.
2. Lock the phone and put it away. Shoot. Move position occasionally.
3. Tap **Stop**. Optionally enter a camera clock correction.
4. **Export GPX** and share it to your Mac.

There is no map, no route drawing, no statistics. Timestamps are the entire point of the
app, so the design protects them and nothing else.

## 2. Why `CLLocationUpdate`

`CLLocationUpdate.liveUpdates()` is the modern live-update API and it already solves the
hard problem for this use case: a sports photographer stands still for long stretches.
Core Location detects that on its own, stops delivering, lets the process suspend, and
resumes by itself when the device moves — and reports what it is doing through the
`stationary`, `accuracyLimited`, `locationUnavailable`, `insufficientlyInUse` and
authorization flags on each update.

So GPeX does not poll. There is no `Timer`, no repeated `requestLocation()`, no
`startUpdatingLocation()`, no significant-location-change or visit monitoring, no
geofences, no `BGTaskScheduler`, and no Core Motion. Relying on Core Location's own power
management is both less code and better battery life than trying to outsmart it.

The live configuration is chosen in exactly one place —
`CoreLocationUpdatesProvider.liveConfiguration` — so field testing can compare
`.default` against `.fitness` by changing one line. It starts at `.default` and is
deliberately not a user setting.

## 3. Why the background activity session stays alive while stationary

`CLBackgroundActivitySession` is created when the user taps Start and is invalidated
**only** when the user stops the recording (or when the recording fails and is cleaned
up). It is specifically *not* invalidated when `stationary == true`.

That matters: the automatic-resume behaviour is the whole reason the architecture works.
Tearing the session down during a stationary period would mean the app is no longer
eligible to receive the update that says the photographer started walking to the other
end of the field — which is exactly the update we care most about.

`RecordingCoordinatorTests.stationaryKeepsSessionsAlive` asserts this directly.

## 4. Why When In Use rather than Always

The authorization model is **When In Use + temporary full accuracy + a background
activity session**. Always authorization is never requested.

GPeX also never calls `requestWhenInUseAuthorization()`. Instead it creates and
retains:

```swift
CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "GPeXTracking")
```

Creating that session is what prompts the user, and its `diagnostics` sequence is what
reports the outcome — including `fullAccuracyDenied` when Precise Location is off. This
gives a scoped, honest permission story: location is used while a recording is running,
and not otherwise.

Reduced accuracy is not treated as a failure. Recording continues and the UI says
**Reduced Accuracy — Precise Location is off. Photo positioning may be inaccurate.**

`CLRequireExplicitServiceSession` is deliberately *not* set in Info.plist. GPeX
always creates a service session before consuming updates, so the key would change
nothing about its behaviour, and the `serviceSessionRequired` diagnostic is handled
either way.

## 5. How background restoration works

A tiny recovery marker lives in `UserDefaults` — and *only* this marker; no location
history is ever stored there:

```
recordingRequested        Bool
activeRecordingSessionID  UUID
activeRecordingStartedAt  Date
```

`recordingRequested` is written last and cleared first, so a half-written marker never
reads as active.

`AppDelegate.application(_:didFinishLaunchingWithOptions:)` — bridged in with
`@UIApplicationDelegateAdaptor`, because SwiftUI alone has no hook this early — calls
`RecordingCoordinator.restoreInterruptedRecordingIfNeeded()`. That method is
**synchronous** up to the point where Core Location is rejoined:

1. read the marker,
2. create the `CLServiceSession` and `CLBackgroundActivitySession`,
3. start consuming `liveUpdates()`,

and only *then* resolves the SwiftData row asynchronously. Opening a store is too slow to
do before expressing renewed interest.

Points arriving before the row is resolved are neither buffered in memory nor orphaned:
`TrackPoint.sessionID` is a plain `UUID` rather than a relationship, and each write awaits
a small `sessionPreparation` task. If that task finds no matching open session, the
marker was stale and the recording is abandoned rather than invented.

Start and restore are both idempotent. `ActiveRecording` owns the single set of stream
tasks, and `beginStreams` refuses to start a second one — so one recording can never have
two concurrent live-update tasks.

**Force-quit is not background recording.** GPeX does not claim otherwise. If the
user force-quits and later reopens the app with a marker still present, the recording is
restored and continues, and the gap in the data is left as a gap. No coordinates are
fabricated to hide it.

An unfinished recording is never silently deleted. The one exception is a start that
failed on authorization before capturing a single fix: that empty row is rolled back so a
denied permission does not litter the list, and the failure is shown explicitly.

## 6. The SwiftData model

**`TrackSession`** — `id`, `name`, `startedAt`, `endedAt?`, `cameraClockOffsetSeconds`,
`createdAt`. Active while `endedAt == nil` and the id matches the recovery marker.

**`TrackPoint`** — `id`, `sessionID`, `timestamp`, `latitude`, `longitude`, `altitude?`,
`horizontalAccuracy`, `verticalAccuracy?`, `speed?`, `course?`, `stationary`,
`isSimulatedBySoftware?`, `isProducedByAccessory?`. Indexed on `sessionID`, `timestamp`,
and the compound `(sessionID, timestamp)`.

Optional fields are `nil` when Core Location reported the value invalid: altitude only
when vertical accuracy is valid, speed and course only when their own accuracies are
non-negative.

**Only raw observations are persisted.** GPX bridge, start and end anchors are generated
at export time and never written to the database, so the original data survives a change
to the export algorithm. `TrackPoint` has no relationship to `TrackSession`, so
`deleteSession` deletes the points explicitly in the same save.

All SwiftData access goes through `TrackStore`, a `@ModelActor`. Nothing that crosses that
boundary is a model object — only `Sendable` snapshots and `LocationSample` values.

## 7. The GPX stationary-bridge algorithm

This is the part that makes the file correct.

A photographer stands at A from 12:00 to 12:10, then walks to B. Core Location stops
delivering while they stand still, so the raw data is:

```
12:00:00  A
12:00:10  A   stationary
12:10:00  B   resumed
```

Anything that interpolates between the second and third points believes the photographer
spent ten minutes drifting across the field. Every photo taken during those ten minutes
gets a wrong position.

So `GPXExporter` holds the stationary coordinate until one second before the resumed fix:

```
12:00:00  A
12:00:10  A   real observation, real timestamp
12:09:59  A   GPX-only bridge point
12:10:00  B   real observation, real timestamp
```

The move becomes a near-step instead of a fabricated drift.

Details:

- **Anchor choice.** The bridge holds the most *accurate* fix within 30 s of the
  stationary transition, not an average of noisy coordinates. Averaging would invent a
  position that was never observed. The raw observations are still exported untouched.
- **When a bridge is added.** Only when the previous point is `stationary`, the gap is at
  least 15 s, and the resumed fix is at least 15 m away. A gap with no stationary report
  could be a tunnel or a dropped fix — guessing the photographer stood still would be
  inventing data, so that gap is preserved as-is.
- **Multiple stationary periods** each get their own bridge.
- **Session start anchor.** If the first good fix arrives within 30 s of Start and shows
  no evidence of movement, its coordinate is duplicated at `startedAt` so photos taken
  immediately after Start have coverage. A first fix minutes later is *not* backdated,
  and neither is one taken while walking.
- **Session end anchor.** A photographer standing still when they tap Stop was there for
  the whole remaining time, so the final stationary coordinate extends to `endedAt`,
  however stale it looks. One who was moving was not, so a stale moving fix is never
  projected forward.
- **Ordering.** Everything is sorted by effective timestamp, floored to whole seconds,
  and filtered to be strictly increasing. Where a synthetic point lands in the same second
  as a real observation, the observation wins. Two fixes in one second collapse to the
  more accurate one, and a stationary report made by either is preserved.

Also: GPX 1.1, UTC ISO 8601 timestamps built from a fixed Gregorian calendar (no locale,
no format-style defaults), coordinates at 7 decimal places via `String(format:locale:nil)`
so a comma decimal separator is impossible, `<ele>` only when a valid altitude exists,
XML-escaped names, no proprietary extensions, and the document is parsed with `XMLParser`
before it is shared.

`GPXExporter` is pure: no Core Location, no SwiftData, no `Date()`. Same inputs, same
bytes — which is what makes all of the above testable.

## 8. `cameraClockOffsetSeconds`

Defined as:

```
cameraClockOffsetSeconds = camera time - actual iPhone time
```

| Situation | Offset |
|---|---|
| Camera is 5 seconds slow | `-5` |
| Camera is 90 seconds fast | `+90` |

The offset is **added to every exported GPX timestamp**, and to the session's start and
end times so anchors land in the same time base. A fix at 11:07:42 with an offset of `-5`
is written as 11:07:37, which is what the camera wrote into the photo.

The raw persisted timestamps are never altered. The correction belongs to the export
transformation alone, and changing it re-exports rather than rewriting history.

Resolution is seconds, not whole minutes. `ClockCorrection` is the only place the sign is
converted, so the UI and the exporter cannot disagree; it shows both a sentence
("Camera was 5 seconds slow") and a signed adjustment ("−00:00:05"), with the direction
spelled out for VoiceOver because a minus sign is easy to miss.

**Camera Clock** on the home screen shows a large local time to tenths, the local date,
UTC time and the current UTC offset. Photograph it with your camera before an event, then
compare the two to find the drift. It keeps the display awake while it is open and
restores normal idle behaviour when you leave.

## 9. Testing background location on a physical iPhone

The simulator cannot demonstrate any of the behaviour that matters here. Use a real
iPhone.

1. Run on device from Xcode, then **stop the debugger** — an attached debugger changes
   suspension behaviour and will mislead you.
2. Tap Start, accept location access and Precise Location.
3. Lock the phone and put it in a pocket.
4. Stand still for 10–15 minutes. Walk 30–50 m. Stand still again. Repeat.
5. Reopen the app and confirm the location count grew while it was locked.
6. Export and inspect the file: you should see the step transitions described in §7, not a
   smooth line between standing positions.

To read the log while it is running, use Console.app filtered to subsystem
`com.example.GPeX` (categories `recording`, `lifecycle`, `persistence`, `export`).
**Coordinates are never logged in release builds**; the only coordinate-aware helper is
compiled out and marks its values `.private` even in debug.

To exercise restoration, start a recording, then force-quit the app from the app switcher,
then reopen it. The recording should resume into the same session with the gap intact.

## 10. Importing the GPX into Lightroom Classic

1. Export the GPX from GPeX and share it to the Mac (AirDrop or Save to Files).
2. In Lightroom Classic, open the **Map** module.
3. Load the GPX tracklog.
4. Select the photos from that session.
5. Auto-Tag the selected photos.

Lightroom Classic accepts GPX tracklogs and matches tracklog times against photo capture
times, which is why this app is built around getting the timestamps right. The exact menu
wording varies between Lightroom versions — follow Adobe's current documentation for the
version you have rather than the labels above, which have not been verified against a
specific release.

If positions look shifted by a constant amount, the camera clock correction (§8) is what
to fix — and the Camera Clock screen is how to measure it.

## Architecture

```
GPeXApp / AppDelegate       @UIApplicationDelegateAdaptor; restores on launch
AppServices                 composition root

RecordingCoordinator        @MainActor @Observable; owns the state machine,
                            the retained CL sessions and the stream tasks
RecordingState              enum carrying ActiveRecording, so "recording without
                            sessions" is unrepresentable; RecordingPhase is the
                            flat Equatable projection for views and tests
LocationUpdatesProvider     the Core Location seam
  CoreLocationUpdatesProvider / TestLocationUpdatesProvider
LocationSample              Sendable value type; intrinsic validation
LocationUpdateEvent         one flattened liveUpdates() delivery
RecoveryMarker(Store)       the UserDefaults lifecycle marker

TrackStore                  @ModelActor; all SwiftData access
TrackSession / TrackPoint   models; snapshots cross the actor boundary

GPXExporter                 pure transformation
GPXTemporaryFile            temp file for sharing, purged at launch

Views  RootView, HomeView, ActiveRecordingView, SessionDetailView,
       CameraClockView, ClockCorrectionView
```

Everything user-visible runs on the main actor. Location updates arrive a few times a
minute at most, so a second isolation domain would buy nothing and would add ways for two
streams to exist at once.

## Info.plist and capabilities

- `NSLocationWhenInUseUsageDescription`
- `NSLocationTemporaryUsageDescriptionDictionary` → `GPeXTracking`
- `UIBackgroundModes` → `location`
- `ITSAppUsesNonExemptEncryption` → `false`

No `NSLocationAlwaysAndWhenInUseUsageDescription`, because Always is never requested. No
entitlements file, no network capability, no App Group, no CloudKit.

## Building and testing

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project GPeX.xcodeproj -scheme GPeX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`GPeXTests` is Swift Testing and covers the GPX document, the stationary bridge, session
anchors, camera clock corrections, accuracy handling, filename sanitisation, raw point
acceptance, the store, and recording state management — including that two sessions cannot
start, that restore happens once, that stop is idempotent, and that stationary does not
release the background session. `GPeXUITests` is a small XCUITest suite driven by a
`-GPeXUITesting` launch argument that swaps in scripted locations and an in-memory store,
so it never depends on GPS or the system permission alert.

## Privacy

Track data is local. There is no networking code, no analytics, no advertising SDK, no
account, no CloudKit, no Photos access, no reverse geocoding, and no street addresses.
Nothing leaves the device unless the user exports it. Exported files go to a temporary
directory that is purged at launch and on each new export, so a track only persists
outside the database if the user saved or sent it.
