# GPeX

A simple GPS track recorder for photographers.

Start a recording, put your iPhone in your pocket, and shoot. When you're done, export a standard `.gpx` tracklog and use it in Lightroom Classic to add locations to your photos based on their capture times.

GPeX is built for situations like sports photography, where you may stay in one place for several minutes before moving somewhere else.

## How it works

1. Tap **Start Recording** before you begin shooting.
2. Lock your iPhone and keep it with you while you move around.
3. Tap **Stop** when you're finished.
4. Correct for any difference between your camera and iPhone clocks if needed.
5. Export the recording as a `.gpx` file.
6. Load the tracklog in Lightroom Classic and match it to your photos.

GPeX focuses on recording useful location and timestamp data. It does not include maps, route planning, statistics, accounts, or cloud sync.

## Features

* Background GPS recording
* Designed for long stationary periods with occasional movement
* GPX 1.1 export
* Camera clock correction down to the second
* Camera Clock screen for measuring camera time drift
* Recording recovery after the app is relaunched
* Local-only storage
* No account or backend
* No third-party packages
* No Photos library access
* No analytics or advertising

## Built for photography

A normal GPS track can produce bad results when a photographer stays in one place for several minutes. If a track jumps from one recorded position to another after a long gap, software may assume you gradually moved between them.

GPeX accounts for stationary periods when generating its GPX output so that photos taken while you were standing still remain associated with that position.

The original location observations are kept unchanged. Adjustments needed for GPX export are generated only when the file is exported.

For implementation details, see [Architecture](docs/ARCHITECTURE.md).

## Camera clock correction

GPS timestamps and photo timestamps need to agree for geotagging to work correctly.

GPeX includes a **Camera Clock** screen that you can photograph before an event. Compare the time shown by your camera with the time displayed by GPeX, then enter the difference before exporting.

The correction is applied to the exported GPX timestamps without modifying the original recorded data.

## Lightroom Classic

After exporting a recording:

1. Transfer the `.gpx` file to your Mac.
2. Open the **Map** module in Lightroom Classic.
3. Load the GPX tracklog.
4. Select the photos from the same session.
5. Use Lightroom's tracklog geotagging tools to assign locations.

If every photo appears shifted by roughly the same amount of time, check the camera clock correction.

## Requirements

* iPhone
* iOS 26.0 or later
* Xcode 27.0 beta or later for the current project

GPeX is written with SwiftUI, SwiftData, Core Location, and Swift Testing.

The deployment target remains iOS 26.0 and the project does not currently depend on iOS 27-only APIs.

## Building

Clone the repository and open `GPeX.xcodeproj` in Xcode.

Before running on a device:

1. Set your development team.
2. Replace the placeholder bundle identifier with your own.

The current placeholder is:

```text
com.example.GPeX
```

If your active developer directory is not the Xcode beta installation, tests can also be run with:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project GPeX.xcodeproj -scheme GPeX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Some background-location behavior cannot be meaningfully tested in the simulator. See [Testing](docs/TESTING.md) for the physical-device test procedure.

## Privacy

GPeX keeps track data on the device.

There is:

* no networking
* no account
* no analytics
* no advertising SDK
* no CloudKit
* no Photos access
* no reverse geocoding

Nothing leaves the device unless you explicitly export and share a GPX file.

## Documentation

Detailed implementation notes live in `/docs`:

* [Architecture](docs/ARCHITECTURE.md) — Core Location, background recording, recovery, persistence, GPX generation, and clock correction
* [Testing](docs/TESTING.md) — automated tests and physical-device background-location testing
