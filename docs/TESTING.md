# Testing

This document covers automated tests and the physical-device checks needed to validate GPeX's background-location behavior.

For project setup and basic usage, see the [README](../README.md). For implementation details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Automated tests

`GPeXTests` uses Swift Testing and covers:

- GPX document generation
- stationary bridge behavior
- session start and end anchors
- camera clock corrections
- location accuracy handling
- filename sanitization
- raw point acceptance
- SwiftData store behavior
- recording state management
- prevention of duplicate recording sessions
- idempotent restore behavior
- idempotent stop behavior
- retaining the background activity session while stationary
- App Intents invoking the normal recording path, idempotently
- App Intent dependency substitution and Camera Clock routing
- the GPX `UTType`, the preserved filename, and the transferred bytes matching
  `GPXExporter` (including clock correction and stationary bridging)
- recording phases mapping to the correct performance state labels
- duplicate phase transitions being ignored
- recording completing normally with a failing or absent performance reporter

The Live Activity is covered by three further suites:

- **content** — every status label, point counts, accuracy included when a fix is current, omitted when absent, and dropped rather than shown stale when it is not; reduced accuracy; and that the encoded payload contains no coordinate keys
- **manager** — one activity per recording, identical content not re-sent, update ordering, idempotent ending, and reassociation by session UUID rather than by position
- **integration with the coordinator** — a refusing or disabled ActivityKit does not stop recording, and stopping, failing or abandoning all end the activity

The widget's own presentations are checked with `#Preview` blocks in `GPeXLiveActivity/RecordingLiveActivityWidget.swift`, covering the Lock Screen and all three Dynamic Island presentations for acquiring, moving, stationary, temporarily unavailable, and reduced accuracy.

`GPeXUITests` is a small XCUITest suite. The `-GPeXUITesting` launch argument swaps in scripted locations and an in-memory store so UI tests do not depend on live GPS or the system location-permission prompt.

## Running the test suite

With the Xcode beta toolchain selected explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project GPeX.xcodeproj -scheme GPeX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The simulator is useful for unit and UI tests, but it cannot reproduce the background suspension and resume behavior that matters most to the app.

## Physical-device background-location test

Use a real iPhone for this test.

1. Build and run GPeX on the device from Xcode.
2. Stop the debugger before testing. An attached debugger changes process suspension behavior and can make the results misleading.
3. Tap **Start Recording**.
4. Accept location access and enable Precise Location.
5. Lock the iPhone and put it in a pocket.
6. Stand still for 10 to 15 minutes.
7. Walk roughly 30 to 50 meters.
8. Stand still again.
9. Repeat the move-and-wait cycle if practical.
10. Reopen GPeX and confirm that the recording continued while the phone was locked.
11. Stop and export the recording.
12. Inspect the GPX and confirm stationary periods produce step-like transitions rather than a smooth interpolated path between standing positions.

The important behavior is that Core Location may stop delivering fixes while stationary, then resume when movement begins. GPeX should keep the background activity session alive across that stationary period so it remains eligible for the resumed update.

## Live Activity test

The same walk validates the Live Activity, on a Dynamic Island iPhone. This still needs a device: the simulator can show the Lock Screen presentation, but not the Dynamic Island, and not real movement transitions.

1. With the phone locked, confirm the Lock Screen activity appears.
2. Confirm the elapsed timer advances **while the app is not running**. It should keep counting through a long stationary stretch with no ActivityKit traffic at all — the `recording` log category will be silent.
3. Stand still until Core Location reports stationary. Confirm the activity reads **Stationary — Saving battery**, not "Paused".
4. Walk 30 to 50 meters. Confirm it returns to **Moving**, and that accuracy and the location count change only after real fixes arrive.
5. Check the compact, minimal, and expanded Dynamic Island presentations.
6. Leave it running for 30 to 60 minutes and compare battery and CPU against a build without the feature. Adding the Live Activity should not change them materially. If it does, something is sending updates it should not.
7. Stop the recording from inside GPeX. The activity should disappear promptly.
8. Export and confirm the GPX is unchanged.

Also confirm the failure paths are inert: turn Live Activities off in Settings and record normally, and dismiss the activity mid-recording. Neither should affect the track.

## Restoration test

To exercise recording recovery:

1. Start a recording on a physical iPhone.
2. Capture at least one valid location fix.
3. Force-quit GPeX from the app switcher.
4. Reopen the app.
5. Confirm the same recording is restored rather than a new one being created.
6. Continue moving and confirm new fixes are added after restoration.

A force quit creates a real gap in recording coverage. GPeX does not claim to record through that gap and must not fabricate coordinates to fill it.

## Reduced-accuracy test

To verify behavior with Precise Location disabled:

1. Disable Precise Location for GPeX in iOS Settings.
2. Start a recording.
3. Confirm recording is allowed to continue.
4. Confirm the UI reports reduced accuracy rather than treating it as a fatal error.

## Logging

For device testing, use Console.app and filter to the app's logging subsystem.

The current placeholder bundle identifier is:

```text
com.example.GPeX
```

Useful log categories are:

- `recording`
- `lifecycle`
- `persistence`
- `export`
- `metrics`

Coordinates are never logged in release builds. The coordinate-aware debug helper is compiled out for release and marks coordinate values private in debug logging.

## GPX checks

A representative stationary sequence should look conceptually like this before export:

```text
12:00:00  A
12:00:10  A   stationary
12:10:00  B   resumed
```

The exported GPX should add a synthetic hold point near the end of the stationary gap:

```text
12:00:00  A
12:00:10  A   real observation
12:09:59  A   GPX-only bridge
12:10:00  B   real observation
```

The synthetic point belongs only to the export. Raw stored observations must remain unchanged.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full bridge rules and edge cases.

## System-integration checks that need a physical iPhone

The unit and UI suites cover everything GPeX itself decides. These depend on system
behavior the simulator does not reproduce:

1. **Intent from a cold start.** Say "Start recording with GPeX" with the app not
   running, on a device where location has never been granted. GPeX should come to the
   foreground, show the location prompt, and land on the active recording screen.
   "Open Camera Clock in GPeX" should land on the clock.
2. **Shortcuts and Spotlight.** Confirm both shortcuts appear in the Shortcuts app
   without being added manually, and that the phrases are recognized.
3. **Share sheet.** Export a session and check that AirDrop, Files and Mail each receive
   a `.gpx` document under the exporter's filename, and that the received bytes match
   what the app shows. Only a real share sheet exercises the file representation.
4. **StateReporting on iOS 26.** `StateReporting.framework` is weak-linked, so an iOS 26
   device must launch and record normally. Verify on an actual iOS 26 device, not just
   by building.
5. **MetricKit delivery.** Reports arrive roughly once a day and only on device. Filter
   Console to the `metrics` category and confirm summaries appear, that they contain no
   coordinates or session names, and that the local archive stays capped.
