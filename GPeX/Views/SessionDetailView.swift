import SwiftData
import SwiftUI
import OSLog

struct SessionDetailView: View {
    /// Everything that changes the exported bytes, as one value `task(id:)` can watch.
    ///
    /// A struct rather than an interpolated string so that adding a field is a compile
    /// step rather than a silently-forgotten `|` in a format.
    private struct ExportSignature: Hashable {
        let name: String
        let cameraClockOffsetSeconds: Double
        let pointCount: Int
    }

    let sessionID: UUID
    let trackStore: TrackStore

    @Query private var sessions: [TrackSession]
    @Environment(\.dismiss) private var dismiss

    @State private var summary: SessionSummary = .empty
    @State private var exportItem: GPXExportItem?
    @State private var exportProblem: String?
    @State private var editedName = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool

    init(sessionID: UUID, trackStore: TrackStore) {
        self.sessionID = sessionID
        self.trackStore = trackStore
        _sessions = Query(
            filter: #Predicate<TrackSession> { $0.id == sessionID },
            sort: \TrackSession.startedAt
        )
    }

    private var session: TrackSession? { sessions.first }

    var body: some View {
        Group {
            if let session {
                content(for: session)
            } else {
                // The session was deleted from under us.
                ContentUnavailableView("Track Unavailable", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(session?.name ?? "Track")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for session: TrackSession) -> some View {
        let exportSignature = ExportSignature(
            name: session.name,
            cameraClockOffsetSeconds: session.cameraClockOffsetSeconds,
            pointCount: summary.pointCount
        )

        List {
            Section("Name") {
                TextField("Track name", text: $editedName)
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    .onSubmit { commitName() }
                    .accessibilityIdentifier("sessionName")
            }

            Section {
                LabeledContent("Date", value: Formatters.sessionDate(session.startedAt))
                if let endedAt = session.endedAt {
                    LabeledContent("Time") {
                        Text("\(Formatters.sessionTime(session.startedAt)) – \(Formatters.sessionTime(endedAt))")
                    }
                    LabeledContent(
                        "Duration",
                        value: Formatters.compactDuration(endedAt.timeIntervalSince(session.startedAt))
                    )
                } else {
                    LabeledContent("Time", value: Formatters.sessionTime(session.startedAt))
                    LabeledContent("Status", value: "Unfinished")
                }
            }

            Section {
                LabeledContent("Recorded locations", value: "\(summary.pointCount)")
                if let typical = summary.typicalHorizontalAccuracy {
                    LabeledContent("Typical accuracy", value: Formatters.accuracy(typical))
                }
                if let best = summary.bestHorizontalAccuracy {
                    LabeledContent("Best accuracy", value: Formatters.accuracy(best))
                }
            }

            Section {
                NavigationLink {
                    ClockCorrectionView(
                        sessionID: sessionID,
                        trackStore: trackStore,
                        offsetSeconds: session.cameraClockOffsetSeconds
                    )
                } label: {
                    LabeledContent {
                        Text(ClockCorrection(offsetSeconds: session.cameraClockOffsetSeconds).summary)
                            .accessibilityIdentifier("cameraClockCorrectionSummary")
                    } label: {
                        Label("Camera Clock Correction", systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                    }
                }
                .accessibilityIdentifier("cameraClockCorrection")
            } footer: {
                Text("Applied to exported GPX timestamps only. Recorded positions are never changed.")
            }

            Section {
                exportRow
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    // The destructive role reddens the title but leaves the symbol on
                    // the app tint, which reads as a mixed signal on the one row that
                    // must not be ambiguous.
                    Label("Delete Track", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("deleteSession")
            }
        }
        .task(id: sessionID) {
            editedName = session.name
            await loadSummary()
        }
        .task(id: exportSignature) {
            await prepareExport()
        }
        // Losing focus is the real end of an edit — tapping elsewhere, pulling the
        // keyboard down, or navigating away all resign it. `onDisappear` stays as a
        // backstop for teardowns that skip the focus change; `commitName` is a no-op
        // when the name has not actually changed, so running twice is harmless.
        .onChange(of: isNameFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused else { return }
            commitName()
        }
        .onDisappear { commitName() }
        .confirmationDialog(
            "Delete this track?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Track", role: .destructive) {
                Task { await deleteSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(summary.pointCount) recorded locations will be deleted. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var exportRow: some View {
        if let exportItem {
            // The item is `Transferable`, so the system decides what a `.gpx` means to
            // each destination — a file to AirDrop and Files, an attachment to Mail —
            // instead of GPeX handing everyone the same temporary URL.
            ShareLink(
                item: exportItem,
                // The filename is the useful thing to show: it is what the file will be
                // called wherever it lands.
                preview: SharePreview(
                    exportItem.filename,
                    image: Image(systemName: "doc.text")
                )
            ) {
                Label("Export GPX", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("exportGPX")
        } else if let exportProblem {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export GPX")
                Text(exportProblem)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("exportGPX")
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing export…")
            }
            .accessibilityIdentifier("exportGPX")
        }
    }

    // MARK: - Actions

    private func loadSummary() async {
        summary = (try? await trackStore.summary(sessionID: sessionID)) ?? .empty
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session?.name else { return }
        Task { try? await trackStore.rename(sessionID: sessionID, to: trimmed) }
    }

    /// Builds the exact bytes that will be shared, ahead of the tap.
    ///
    /// Nothing is written to disk here: the document only becomes a file inside
    /// `GPXExportItem`'s transfer representation, at the moment the system asks for
    /// one. What this does is find out early whether there is anything exportable, so
    /// the row can say "no usable locations" instead of failing after the share sheet
    /// is already open.
    private func prepareExport() async {
        exportItem = nil
        exportProblem = nil
        do {
            guard let input = try await trackStore.exportInput(sessionID: sessionID) else {
                exportProblem = "This session is no longer available."
                return
            }
            let xml = try GPXExporter().gpx(session: input.session, samples: input.samples)
            exportItem = GPXExportItem(
                filename: GPXExporter.filename(for: input.session),
                xml: xml
            )
        } catch GPXExportError.noUsableLocations {
            exportProblem = "No usable locations were recorded, so there is nothing to export."
        } catch {
            Log.export.error("Export failed: \(error.localizedDescription, privacy: .public)")
            exportProblem = "GPeX could not prepare the file."
        }
    }

    private func deleteSession() async {
        try? await trackStore.deleteSession(id: sessionID)
        GPXTemporaryFile.purge()
        dismiss()
    }
}

#if DEBUG
private struct SessionDetailPreview: View {
    @State private var world = PreviewWorld()

    var body: some View {
        NavigationStack {
            if let id = world.firstSessionID {
                SessionDetailView(sessionID: id, trackStore: world.store)
            } else {
                Text("No seeded track")
            }
        }
        .modelContainer(world.container)
    }
}

#Preview("Finished track") {
    SessionDetailPreview()
}

// The session was deleted from under the screen — reachable in the app, easy to forget.
#Preview("Unavailable") {
    NavigationStack {
        SessionDetailView(sessionID: UUID(), trackStore: PreviewWorld(seeds: []).store)
    }
    .modelContainer(PreviewWorld(seeds: []).container)
}
#endif
