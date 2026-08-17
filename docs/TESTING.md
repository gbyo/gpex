# Testing

This document covers automated tests and the physical-device checks needed to validate GPeX's background-location behavior.

For project setup and basic usage, see the [README](../README.md). For implementation details, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Automated tests

`GpExTests` uses Swift Testing and covers:

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

`GpExUITests` is a small XCUITest suite. The `-GpExUITesting` launch argument swaps in scripted locations and an in-memory store so UI tests do not depend on live GPS or the system location-permission prompt.

## Running the test suite

With the Xcode beta toolchain selected explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project GpEx.xcodeproj -scheme GpEx \
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
com.example.PhotoTrack
```

Useful log categories are:

- `recording`
- `lifecycle`
- `persistence`
- `export`

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
