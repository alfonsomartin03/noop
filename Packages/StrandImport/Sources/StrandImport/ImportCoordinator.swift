import Foundation

/// Entry point for NOOP's data import: parses a WHOOP CSV export (`.zip` or folder) into normalized rows plus an
/// `ImportSummary`. Parsing only — persistence happens in the app (`WhoopImporter`).
public struct ImportCoordinator {
    private let whoop: WhoopExportImporter

    public init(whoop: WhoopExportImporter = WhoopExportImporter()) {
        self.whoop = whoop
    }

    /// Parse a WHOOP CSV export (`.zip` or folder).
    public func importWhoopExport(from url: URL) throws -> WhoopImportResult {
        try whoop.import(from: url)
    }
}
