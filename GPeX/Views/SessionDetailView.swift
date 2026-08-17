import SwiftData
import SwiftUI
import OSLog

struct SessionDetailView: View {
    let sessionID: UUID
    let trackStore: TrackStore

    @Query private var sessions: [TrackSession]
    @Environment(\.dismiss) private var dismiss

    @State private var summary: SessionSummary = .empty
    @State private var exportItem: GPXExportItem?
    @State private var exportProblem: String?
    @State private var editedName = ""
    @State private var isConfirmingDelete = false

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
                ContentUnavailableView("Session Unavailable", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(session?.name ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for session: TrackSession) -> some View {
        // One signature covering everything that changes the exported bytes.
        let exportSignature = "\(session.name)|\(session.cameraClockOffsetSeconds)|\(summary.pointCount)"

        List {
            Section("Name") {
                TextField("Session name", text: $editedName)
                    .submitLabel(.done)
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
                    LabeledContent("Camera Clock Correction") {
                        Text(ClockCorrection(offsetSeconds: session.cameraClockOffsetSeconds).summary)
                            .accessibilityIdentifier("cameraClockCorrectionSummary")
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
                Button("Delete Session", role: .destructive) { isConfirmingDelete = true }
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
        .onDisappear { commitName() }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
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
