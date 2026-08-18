#if DEBUG
import SwiftData
import SwiftUI

/// The app's object graph, built for a canvas.
///
/// Deliberately the *real* `TrackStore` and `RecordingCoordinator` rather than stubs:
/// the only things swapped are the two seams the app already has for exactly this —
/// an in-memory store and `TestLocationUpdatesProvider` in place of Core Location. A
/// preview therefore exercises the real state machine, so a phase that renders wrongly
/// here renders wrongly on a device too.
struct PreviewWorld {
    /// One seeded track. Times are relative to now so the date grouping on the home
    /// screen has something to group.
    struct Seed {
        var name: String
        var startedAgo: TimeInterval
        var duration: TimeInterval?
        var pointCount: Int = 12
        var accuracy: Double = 8

        static let assorted: [Seed] = [
            Seed(name: "Soccer vs Greenwood", startedAgo: 2 * .hour, duration: 1.8 * .hour),
            Seed(name: "JV Football Scrimmage", startedAgo: 6 * .hour, duration: 55 * .minute),
            Seed(name: "Cross Country Invitational", startedAgo: 28 * .hour, duration: 3.2 * .hour),
            Seed(name: "Track Meet — Day 2", startedAgo: 4 * .day, duration: 2.5 * .hour, accuracy: 24),
            Seed(name: "Homecoming Parade", startedAgo: 21 * .day, duration: 40 * .minute),
            Seed(name: "Regional Semifinal", startedAgo: 65 * .day, duration: nil),
        ]
    }

    let container: ModelContainer
    let store: TrackStore
    let provider: TestLocationUpdatesProvider
    let coordinator: RecordingCoordinator
    let router = AppRouter()

    /// The id of the first seeded track, for previewing the detail screen.
    let firstSessionID: UUID?

    init(seeds: [Seed] = Seed.assorted) {
        let schema = Schema([TrackSession.self, TrackPoint.self])
        // Force-unwrapped on purpose: this runs only in previews, where a failure
        // should be a loud, immediate canvas error rather than a silent empty screen.
        container = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        store = TrackStore(modelContainer: container)
        provider = TestLocationUpdatesProvider()

        // A throwaway defaults domain, so a preview can never resurrect a recovery
        // marker into the real app.
        let suiteName = "GPeXPreviews"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        coordinator = RecordingCoordinator(
            trackStore: store,
            markerStore: RecoveryMarkerStore(defaults: defaults),
            provider: provider,
            // Previews never restore: a canvas that resumed a recording on every
            // redraw would be unusable.
            allowsRestore: false
        )

        firstSessionID = Self.seed(seeds, into: container)
    }

    @discardableResult
    private static func seed(_ seeds: [Seed], into container: ModelContainer) -> UUID? {
        guard !seeds.isEmpty else { return nil }
        let context = ModelContext(container)
        var first: UUID?
        let now = Date()

        for seed in seeds {
            let id = UUID()
            if first == nil { first = id }
            let startedAt = now.addingTimeInterval(-seed.startedAgo)
            context.insert(
                TrackSession(
                    id: id,
                    name: seed.name,
                    startedAt: startedAt,
                    endedAt: seed.duration.map { startedAt.addingTimeInterval($0) }
                )
            )
            for index in 0..<seed.pointCount {
                let sample = LocationSample(
                    timestamp: startedAt.addingTimeInterval(Double(index) * 30),
                    latitude: 41.8781 + Double(index) * 0.0001,
                    longitude: -87.6298,
                    altitude: 180,
                    horizontalAccuracy: seed.accuracy,
                    verticalAccuracy: 5,
                    stationary: index > seed.pointCount / 2
                )
                context.insert(TrackPoint(sessionID: id, sample: sample))
            }
        }
        try? context.save()
        return first
    }
}

/// Drives a real recording into a chosen phase, then hands the coordinator to a view.
///
/// The alternative — a fake coordinator with settable properties — would let a preview
/// show a combination the state machine cannot actually produce. Everything below goes
/// through `startRecording()` and the same event stream Core Location would use.
struct RecordingPreviewHost<Content: View>: View {
    enum Stage {
        case waitingForAuthorization
        case acquiring
        case moving
        case stationary
        case unavailable
        case reducedAccuracy
        case backgroundLimited
    }

    let stage: Stage
    @ViewBuilder let content: (RecordingCoordinator) -> Content

    @State private var world = PreviewWorld(seeds: [])

    var body: some View {
        content(world.coordinator)
            .task { await drive() }
    }

    private func drive() async {
        await world.coordinator.startRecording()
        guard stage != .waitingForAuthorization else { return }

        // A clean diagnostic is what moves startup past "waiting for permission".
        world.provider.emit(SessionDiagnostic(source: .serviceSession))
        guard stage != .acquiring else { return }

        world.provider.emit(previewSample())
        await settle()

        switch stage {
        case .waitingForAuthorization, .acquiring, .moving:
            break

        case .stationary:
            world.provider.emit(previewSample(offset: 30, stationary: true))

        case .unavailable:
            var event = LocationUpdateEvent(sample: nil)
            event.locationUnavailable = true
            world.provider.emit(event)

        case .reducedAccuracy:
            var diagnostic = SessionDiagnostic(source: .serviceSession)
            diagnostic.fullAccuracyDenied = true
            world.provider.emit(diagnostic)

        case .backgroundLimited:
            var diagnostic = SessionDiagnostic(source: .backgroundActivitySession)
            diagnostic.insufficientlyInUse = true
            world.provider.emit(diagnostic)
        }
    }

    private func previewSample(offset: TimeInterval = 0, stationary: Bool = false) -> LocationSample {
        LocationSample(
            timestamp: Date().addingTimeInterval(offset),
            latitude: 41.8781,
            longitude: -87.6298,
            altitude: 180,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            stationary: stationary
        )
    }

    /// The event stream is consumed by a task, so a phase change lands a turn later.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }
}

/// Wraps a preview in the navigation chrome its screen really sits in, so titles,
/// toolbars and bottom bars are laid out the way the app lays them out.
struct PreviewNavigation<Content: View>: View {
    var title: String = "GPeX"
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            content.navigationTitle(title)
        }
    }
}

extension TimeInterval {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
}
#endif
