import Foundation

/// Where a point in the exported track came from.
nonisolated enum GPXPointOrigin: Sendable, Equatable {
    /// A real Core Location observation.
    case observed
    /// The first good fix duplicated back to the session start time.
    case sessionStartAnchor
    /// A stationary coordinate held until just before the photographer moved again.
    case stationaryBridge
    /// The final stationary coordinate extended to the session end time.
    case sessionEndAnchor

    var isObserved: Bool { self == .observed }
}

/// One point in the exported track. Exists only inside the export pipeline.
nonisolated struct GPXTrackPoint: Sendable, Equatable {
    /// The camera-clock-corrected timestamp that will be written to the file.
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var elevation: Double?
    var origin: GPXPointOrigin
    /// Carried only to break ties between two fixes in the same second.
    var horizontalAccuracy: Double

    init(sample: LocationSample, at timestamp: Date? = nil, origin: GPXPointOrigin) {
        self.timestamp = timestamp ?? sample.timestamp
        self.latitude = sample.latitude
        self.longitude = sample.longitude
        self.elevation = sample.altitude
        self.origin = origin
        self.horizontalAccuracy = sample.horizontalAccuracy
    }
}

nonisolated enum GPXExportError: Error, Equatable {
    /// The session has no fix that could describe a position, so any file produced
    /// would be misleading rather than merely sparse.
    case noUsableLocations
    /// The generated document did not parse. Never expected; the guard exists so a
    /// malformed file is not handed to Lightroom.
    case malformedDocument
}

/// Turns a session and its raw observations into a GPX 1.1 tracklog.
///
/// Pure and deterministic: no Core Location, no SwiftData, no `Date()`, no locale
/// lookups. The same inputs always produce the same bytes, which is what makes the
/// stationary-bridge behaviour testable.
nonisolated struct GPXExporter {
    /// Tuning for the export transformations.
    struct Configuration: Sendable, Equatable {
        /// How long a stationary gap must be before it gets a bridge point. Shorter
        /// gaps are left alone because interpolating across a few seconds is harmless.
        var minimumStationaryGap: TimeInterval = 15
        /// How far the photographer must have moved before a bridge is worth adding.
        /// Standing in one place produces gaps whose endpoints are metres apart, and
        /// bridging those would only add redundant points.
        var minimumBridgeDistance: Double = 15
        /// How far back to look for a better fix when choosing the stationary anchor.
        var stationaryAnchorWindow: TimeInterval = 30
        /// How far before the resumed fix the bridge point is placed.
        var bridgeLead: TimeInterval = 1
        /// How soon after the session start a first fix may be backdated to it.
        var startAnchorWindow: TimeInterval = 30
        /// How stale a non-stationary final fix may be and still cover the session end.
        var endAnchorWindowWhileMoving: TimeInterval = 30
        /// Above this speed the photographer counts as moving, so a fix must not be
        /// projected backwards onto the session start.
        var movementSpeedThreshold: Double = 1.0

        static let standard = Configuration()
    }

    var configuration: Configuration = .standard

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    // MARK: - Planning

    /// Builds the exact sequence of points that will be written, without rendering XML.
    ///
    /// The camera clock correction is applied up front, to the observations *and* to
    /// the session's start and end times, so every subsequent decision is made in the
    /// same time base that the file will use.
    func plan(session: TrackSessionSnapshot, samples: [LocationSample]) -> [GPXTrackPoint] {
        let offset = session.cameraClockOffsetSeconds
        let startedAt = session.startedAt.addingTimeInterval(offset)
        let endedAt = session.endedAt?.addingTimeInterval(offset)

        let observations = Self.collapseToOnePerSecond(
            samples
                .filter(Self.isUsable)
                .map { Self.shifting($0, by: offset) }
                .sorted { $0.timestamp < $1.timestamp }
        )

        guard let first = observations.first, let last = observations.last else { return [] }

        var planned: [GPXTrackPoint] = []

        // Session start anchor: cover photographs taken in the seconds between Start
        // and the first fix — but only when that fix arrived promptly and there is no
        // evidence the photographer was already walking.
        if first.timestamp > startedAt,
           first.timestamp.timeIntervalSince(startedAt) <= configuration.startAnchorWindow,
           !first.indicatesMovement(fasterThan: configuration.movementSpeedThreshold) {
            planned.append(GPXTrackPoint(sample: first, at: startedAt, origin: .sessionStartAnchor))
        }

        for (index, observation) in observations.enumerated() {
            planned.append(GPXTrackPoint(sample: observation, origin: .observed))

            // Stationary bridge. Without this, a reader interpolating between the last
            // fix at position A and the resumed fix at position B would place the
            // photographer somewhere along that line for the whole stationary period —
            // which is exactly wrong. Holding A until one second before B turns the
            // move into a near-step instead.
            guard index + 1 < observations.count else { break }
            let resumed = observations[index + 1]
            guard observation.stationary else { continue }

            let gap = resumed.timestamp.timeIntervalSince(observation.timestamp)
            guard gap >= configuration.minimumStationaryGap else { continue }

            let anchor = Self.stationaryAnchor(
                endingAt: index,
                in: observations,
                window: configuration.stationaryAnchorWindow
            )
            guard Self.distance(from: anchor, to: resumed) >= configuration.minimumBridgeDistance else {
                continue
            }

            let bridgeTimestamp = resumed.timestamp.addingTimeInterval(-configuration.bridgeLead)
            // Never let the bridge precede the stationary observation it holds.
            guard bridgeTimestamp > observation.timestamp else { continue }
            planned.append(GPXTrackPoint(sample: anchor, at: bridgeTimestamp, origin: .stationaryBridge))
        }

        // Session end anchor. A photographer standing still when they tap Stop was at
        // that position for the whole remaining time, however stale the fix looks. One
        // who was moving was not, so their last position is not projected forward.
        if let endedAt, endedAt > last.timestamp {
            let staleness = endedAt.timeIntervalSince(last.timestamp)
            if last.stationary || staleness <= configuration.endAnchorWindowWhileMoving {
                planned.append(GPXTrackPoint(sample: last, at: endedAt, origin: .sessionEndAnchor))
            }
        }

        return Self.normalize(planned)
    }

    // MARK: - Rendering

    /// Renders a GPX 1.1 tracklog. Throws rather than emit a file with no positions.
    func gpx(session: TrackSessionSnapshot, samples: [LocationSample]) throws -> String {
        let points = plan(session: session, samples: samples)
        guard !points.isEmpty else { throw GPXExportError.noUsableLocations }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="PhotoTrack"
             xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(Self.escapingXML(session.name))</name>
            <trkseg>

        """

        for point in points {
            xml += "      <trkpt lat=\"\(Self.decimal(point.latitude, places: 7))\" lon=\"\(Self.decimal(point.longitude, places: 7))\">\n"
            if let elevation = point.elevation {
                xml += "        <ele>\(Self.decimal(elevation, places: 1))</ele>\n"
            }
            xml += "        <time>\(Self.iso8601UTC(point.timestamp))</time>\n"
            xml += "      </trkpt>\n"
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>

        """

        guard Self.isWellFormedXML(xml) else { throw GPXExportError.malformedDocument }
        return xml
    }

    // MARK: - Filenames

    /// A filename like `2026-08-17-Soccer-vs-Greenwood.gpx`.
    ///
    /// The date is the session's local start date, so the file sorts by shooting day.
    static func filename(for session: TrackSessionSnapshot, timeZone: TimeZone = .current) -> String {
        let stamp = dateStamp(session.startedAt, timeZone: timeZone)
        let name = sanitizedForFilename(session.name)
        return name.isEmpty ? "\(stamp)-PhotoTrack.gpx" : "\(stamp)-\(name).gpx"
    }

    /// Reduces a user-entered name to characters that are safe in a filename on every
    /// platform the file is likely to reach.
    static func sanitizedForFilename(_ name: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in name {
            if character.isLetter || character.isNumber || character == "_" {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.append(character)
            } else {
                // Any run of spaces, punctuation or dashes collapses to one dash.
                pendingSeparator = true
            }
        }
        return String(result.prefix(60))
    }

    private static func dateStamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Formatting helpers

    /// Locale-independent decimal formatting. A comma decimal separator would make the
    /// file unreadable, so the locale is pinned to `nil` (non-localized) explicitly.
    static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: nil, value)
    }

    /// Whole-second UTC ISO 8601, e.g. `2026-08-17T21:42:01Z`.
    ///
    /// Built from a fixed Gregorian calendar in UTC rather than a formatter, so no
    /// locale, calendar preference or format-style default can change the output.
    static func iso8601UTC(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            locale: nil,
            c.year ?? 0, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    static func escapingXML(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Parses the document to confirm it is well formed before it is shared.
    static func isWellFormedXML(_ xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        return parser.parse()
    }

    // MARK: - Point selection

    private static func isUsable(_ sample: LocationSample) -> Bool {
        sample.latitude.isFinite && sample.longitude.isFinite
            && abs(sample.latitude) <= 90 && abs(sample.longitude) <= 180
            && sample.horizontalAccuracy.isFinite && sample.horizontalAccuracy >= 0
    }

    private static func shifting(_ sample: LocationSample, by offset: TimeInterval) -> LocationSample {
        guard offset != 0 else { return sample }
        var shifted = sample
        shifted.timestamp = sample.timestamp.addingTimeInterval(offset)
        return shifted
    }

    /// GPX timestamps are whole seconds, so two fixes in the same second cannot both
    /// be represented. Keeps the more accurate one and preserves a stationary report
    /// made by either.
    private static func collapseToOnePerSecond(_ sorted: [LocationSample]) -> [LocationSample] {
        var result: [LocationSample] = []
        result.reserveCapacity(sorted.count)
        for sample in sorted {
            guard let previous = result.last,
                  wholeSecond(previous.timestamp) == wholeSecond(sample.timestamp)
            else {
                result.append(sample)
                continue
            }
            var winner = sample.horizontalAccuracy < previous.horizontalAccuracy ? sample : previous
            winner.stationary = previous.stationary || sample.stationary
            result[result.count - 1] = winner
        }
        return result
    }

    /// The coordinate to hold across a stationary period.
    ///
    /// Prefers the most accurate recent fix rather than averaging noisy coordinates,
    /// looking back only as far as the configured window around the transition.
    private static func stationaryAnchor(
        endingAt index: Int,
        in observations: [LocationSample],
        window: TimeInterval
    ) -> LocationSample {
        let transition = observations[index]
        var best = transition
        var candidate = index - 1
        while candidate >= 0 {
            let sample = observations[candidate]
            guard transition.timestamp.timeIntervalSince(sample.timestamp) <= window else { break }
            if sample.horizontalAccuracy < best.horizontalAccuracy { best = sample }
            candidate -= 1
        }
        return best
    }

    /// Great-circle distance in metres. Local to the exporter so it stays free of
    /// Core Location and remains a pure function.
    static func distance(from a: LocationSample, to b: LocationSample) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    private static func wholeSecond(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    /// Floors every timestamp to the second it will be written as, then guarantees the
    /// output is strictly increasing. Where a synthetic point lands in the same second
    /// as a real observation, the observation wins.
    private static func normalize(_ points: [GPXTrackPoint]) -> [GPXTrackPoint] {
        let floored = points.map { point -> GPXTrackPoint in
            var copy = point
            copy.timestamp = Date(timeIntervalSince1970: Double(wholeSecond(point.timestamp)))
            return copy
        }

        let ordered = floored.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            if lhs.element.origin.isObserved != rhs.element.origin.isObserved {
                return lhs.element.origin.isObserved
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var result: [GPXTrackPoint] = []
        result.reserveCapacity(ordered.count)
        for point in ordered {
            if let last = result.last, point.timestamp <= last.timestamp { continue }
            result.append(point)
        }
        return result
    }
}
