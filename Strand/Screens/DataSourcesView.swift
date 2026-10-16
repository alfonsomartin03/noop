import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandAnalytics

/// Import & Export — the data-ownership screen. Bring in your full WHOOP export, see what NOOP
/// has stored, and take a complete copy of the database out.
// Screen layout: what is stored, WHOOP export import, NOOP-vs-WHOOP accuracy, and full backup/restore.
struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @State private var picking = false
    @State private var backupBusy = false
    @State private var backupTitle = ""
    @State private var backupMessage = ""
    @State private var showBackupAlert = false

    var body: some View {
        ScreenScaffold(title: "Import & Export",
                       subtitle: "Everything WHOOP collects, stored on this Mac. Bring your history in, take a copy out.") {
            storedCard
            whoopCard
            accuracyCard
            backupCard
        }
        // Accepts a zip or an extracted folder; the importer finds the CSVs itself.
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.zip, .folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importWhoop(url: url)
            }
        }
        .alert(backupTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: { Text(backupMessage) }
    }

    private var storedCard: some View {
        card(title: "Stored on this Mac", icon: "internaldrive.fill",
             subtitle: "What NOOP holds right now, from the strap and from imports.") {
            HStack(spacing: 8) {
                Circle().fill(live.bonded ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 8, height: 8)
                Text(live.bonded ? "Strap bonded — collecting." : "Strap not connected — open Live to pair.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("\(repo.days.count) days · \(repo.sleeps.count) sleeps")
                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private var whoopCard: some View {
        card(title: "Import WHOOP export", icon: "square.and.arrow.down.fill",
             subtitle: "Import your full WHOOP history — recovery, strain, sleep, workouts, journal — from a data export (.zip). Works for WHOOP 4.0, 5.0 and MG. Request one at app.whoop.com → Data Management.") {
            HStack(spacing: 12) {
                Button { picking = true } label: {
                    Label(model.importing ? "Importing…" : "Choose export…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.strandPrimary)
                .disabled(model.importing)
                if model.importing { ProgressView().controlSize(.small) }
            }
            if let s = model.importSummary {
                Text(s).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositiveInk)
            }
        }
    }

    /// Official WHOOP scores vs NOOP's own estimates, over days that have both. Hidden until there
    /// is an overlap (needs a WHOOP import plus nights NOOP scored itself).
    @ViewBuilder
    // Hidden until at least one metric has days with both an official and an estimated value.
    private var accuracyCard: some View {
        let rows: [(String, String, EstimateAccuracy.Result?)] = [
            ("Recovery", "points", repo.accuracy { $0.recovery }),
            ("Strain", "of 21", repo.accuracy { $0.strain }),
            ("Sleep", "min", repo.accuracy { $0.totalSleepMin }),
        ]
        if rows.contains(where: { $0.2 != nil }) {
            card(title: "NOOP vs WHOOP", icon: "scalemass.fill",
                 subtitle: "How far NOOP's own estimate is from the score WHOOP reported, on days you have both. NOOP's numbers are estimates, not WHOOP's.") {
                ForEach(rows, id: \.0) { name, unit, r in
                    if let r {
                        HStack {
                            Text(name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text(r.isReliable
                                 ? "off by \(String(format: "%.1f", r.meanAbsError)) \(unit) on average · \(r.days) days"
                                 : "needs \(EstimateAccuracy.minDays) days · have \(r.days)")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                Text("Formulas \(EstimateAccuracy.modelVersion)").font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var backupCard: some View {
        card(title: "Export everything", icon: "square.and.arrow.up.fill",
             subtitle: "Save the entire database — raw strap streams, history, sleeps, workouts — to a single file. Import a backup to restore it on another Mac; that replaces this Mac's data and needs a relaunch.") {
            HStack(spacing: 12) {
                Button { runExport() } label: {
                    Label("Export…", systemImage: "square.and.arrow.up").padding(.horizontal, 6)
                }
                .buttonStyle(.strandPrimary)
                .disabled(backupBusy)

                Button { runImport() } label: {
                    Label("Restore backup…", systemImage: "square.and.arrow.down").padding(.horizontal, 6)
                }
                .buttonStyle(.strandSecondary)
                .disabled(backupBusy)

                if backupBusy { ProgressView().controlSize(.small) }
            }
        }
    }

    // Checkpoint is passed in so the backup gets a consolidated database file.
    private func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runImport() {
        backupBusy = true
        Task { handleBackup(await DataBackup.runImport()) }
    }

    @MainActor
    // Maps the result to alert text; cancelling shows nothing.
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupTitle = "Backup exported"
            backupMessage = "Saved to \(url.lastPathComponent)."
        case .imported:
            backupTitle = "Backup restored"
            backupMessage = "Quit and reopen NOOP for it to take effect."
        case .failure(let message):
            backupTitle = "Backup problem"
            backupMessage = message
        }
        showBackupAlert = true
    }

    @ViewBuilder
    private func card<C: View>(title: String, icon: String, subtitle: String,
                              @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StrandPalette.accentInk)
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            content()
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .strandSurface()
    }
}
