import SwiftData
import SwiftUI

/// The idle screen: everything already recorded, and one way to start recording more.
///
/// The list is content and nothing else. The primary action sits in its own bar at the
/// bottom where it is reachable one-handed and cannot scroll away, and the Camera Clock
/// — a tool rather than a track — lives in the toolbar.
struct HomeView: View {
    let coordinator: RecordingCoordinator
    let trackStore: TrackStore

    @Query(sort: \TrackSession.startedAt, order: .reverse) private var sessions: [TrackSession]

    @State private var searchText = ""
    @State private var renamingSessionID: UUID?
    @State private var renameText = ""
    @State private var sessionPendingDelete: TrackSession?

    var body: some View {
        List {
            if case .failed(let problem) = coordinator.phase {
                Section {
                    NoticeCard(
                        title: Text(problem.title),
                        detail: Text(problem.detail),
                        symbolName: "exclamationmark.triangle.fill",
                        tint: .red,
                        showsSettingsLink: problem.suggestsSettings,
                        onDismiss: { coordinator.dismissFailure() }
                    )
                    .accessibilityIdentifier("recordingProblem")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(sessions(in: group)) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Explicitly in the navigation bar. Left to itself, iOS 26 puts the search
        // field in a bottom bar, where it would land underneath Start Recording and
        // read as an afterthought below the screen's primary action.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search tracks"
        )
        .overlay { emptyState }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: AppRouter.Destination.cameraClock) {
                    Label("Camera Clock", systemImage: "clock")
                }
                .accessibilityIdentifier("cameraClock")
            }
        }
        .safeAreaInset(edge: .bottom) { startBar }
        .alert("Rename Track", isPresented: isRenamingBinding) {
            TextField("Track name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Rename") { commitRename() }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingSessionID = nil }
        }
        .confirmationDialog(
            "Delete this track?",
            isPresented: isDeletingBinding,
            titleVisibility: .visible,
            presenting: sessionPendingDelete
        ) { session in
            Button("Delete Track", role: .destructive) {
                let id = session.id
                Task { await delete(sessionID: id) }
            }
            Button("Cancel", role: .cancel) { sessionPendingDelete = nil }
        } message: { session in
            Text("“\(session.name)” and all of its recorded locations will be deleted. This cannot be undone.")
        }
    }

    // MARK: - Rows

    private func sessionRow(_ session: TrackSession) -> some View {
        NavigationLink(value: AppRouter.Destination.session(session.id)) {
            HStack(spacing: 12) {
                Image(systemName: session.endedAt == nil ? "exclamationmark.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.title3)
                    .foregroundStyle(session.endedAt == nil ? Color.orange : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .lineLimit(1)
                    Text(
                        Formatters.groupedSessionSubtitle(
                            startedAt: session.startedAt,
                            endedAt: session.endedAt
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("session-\(session.id.uuidString)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                sessionPendingDelete = session
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            Button {
                beginRename(session)
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button(role: .destructive) {
                sessionPendingDelete = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        if sessions.isEmpty {
            ContentUnavailableView {
                Label("No Tracks Yet", systemImage: "location.viewfinder")
            } description: {
                Text("Start a recording before you shoot. GPeX saves where you were, so Lightroom can put your photos on the map.")
            }
            .accessibilityIdentifier("noTracks")
        } else if filteredSessions.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    // MARK: - Start

    private var startBar: some View {
        VStack(spacing: 8) {
            saveIntervalPicker

            Button {
                Task { await coordinator.startRecording() }
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("startRecording")

            Text("Tracks stay on this iPhone until you export or delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// How often the next recording writes a location down.
    ///
    /// A menu picker rather than a segmented control: four options with words on them do
    /// not fit across an iPhone at accessibility text sizes, and the choice is made once
    /// and then left alone. It sits above Start because it applies to the recording the
    /// photographer is about to begin — a running recording keeps the cadence it started
    /// with, and this screen is not on display while one is running.
    private var saveIntervalPicker: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Spelled out beside the menu rather than left to the picker's own label: a
            // menu picker outside a List shows only its selected value, and "30 seconds"
            // on its own says nothing about what it measures.
            Text("Save a location every")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            Picker("Save a location every", selection: saveIntervalBinding) {
                ForEach(LocationSaveInterval.allCases) { interval in
                    Text(interval.pickerLabel).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Save a location every")
            .accessibilityHint("Sets the shortest time between saved locations. It does not change how often GPeX checks your position.")
            .accessibilityIdentifier("saveInterval")
        }
    }

    private var saveIntervalBinding: Binding<LocationSaveInterval> {
        Binding(
            get: { coordinator.preferredSaveInterval },
            set: { coordinator.setPreferredSaveInterval($0) }
        )
    }

    // MARK: - Data

    private var filteredSessions: [TrackSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedStandardContains(query) }
    }

    private var groups: [SessionGrouping.Group] {
        SessionGrouping.groups(
            startedAtByID: filteredSessions.map { (id: $0.id, startedAt: $0.startedAt) },
            now: .now
        )
    }

    private func sessions(in group: SessionGrouping.Group) -> [TrackSession] {
        let wanted = Set(group.sessionIDs)
        return filteredSessions.filter { wanted.contains($0.id) }
    }

    // MARK: - Actions

    private var isRenamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSessionID != nil },
            set: { if !$0 { renamingSessionID = nil } }
        )
    }

    private var isDeletingBinding: Binding<Bool> {
        Binding(
            get: { sessionPendingDelete != nil },
            set: { if !$0 { sessionPendingDelete = nil } }
        )
    }

    private func beginRename(_ session: TrackSession) {
        renameText = session.name
        renamingSessionID = session.id
    }

    private func commitRename() {
        guard let id = renamingSessionID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingSessionID = nil
        guard !trimmed.isEmpty else { return }
        Task { try? await trackStore.rename(sessionID: id, to: trimmed) }
    }

    private func delete(sessionID: UUID) async {
        sessionPendingDelete = nil
        try? await trackStore.deleteSession(id: sessionID)
        // Any prepared export for that session is now stale bytes on disk.
        GPXTemporaryFile.purge()
    }
}

#if DEBUG
private struct HomePreview: View {
    var seeds: [PreviewWorld.Seed] = PreviewWorld.Seed.assorted
    @State private var world: PreviewWorld

    init(seeds: [PreviewWorld.Seed] = PreviewWorld.Seed.assorted) {
        self.seeds = seeds
        _world = State(initialValue: PreviewWorld(seeds: seeds))
    }

    var body: some View {
        NavigationStack {
            HomeView(coordinator: world.coordinator, trackStore: world.store)
                .navigationTitle("GPeX")
        }
        .modelContainer(world.container)
    }
}

#Preview("With tracks") {
    HomePreview()
}

// The screen every new user sees first, and the easiest one to leave unfinished.
#Preview("Empty") {
    HomePreview(seeds: [])
}

#Preview("One track") {
    HomePreview(seeds: [PreviewWorld.Seed(name: "Soccer vs Greenwood", startedAgo: .hour, duration: 1.5 * .hour)])
}

#Preview("With tracks · AX3") {
    HomePreview()
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
