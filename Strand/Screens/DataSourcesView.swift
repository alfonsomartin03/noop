import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

/// Import & Export — the data-ownership screen. Bring in your full WHOOP export, see what NOOP
/// has stored, and take a complete copy of the database out.
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
            backupCard
        }
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
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(model.importing)
                if model.importing { ProgressView().controlSize(.small) }
            }
            if let s = model.importSummary {
                Text(s).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
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
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(backupBusy)

                Button { runImport() } label: {
                    Label("Restore backup…", systemImage: "square.and.arrow.down").padding(.horizontal, 6)
                }
                .buttonStyle(.bordered).tint(StrandPalette.accent)
                .disabled(backupBusy)

                if backupBusy { ProgressView().controlSize(.small) }
            }
        }
    }

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
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
    }
}
