import SwiftUI

/// Sheet view for importing Granola meetings into Ghost Pepper.
///
/// AF Flow hard rule: never add an API key entry field. Granola import only
/// ever worked via a pasted personal API key (local Granola cache reads are
/// intentionally disabled in `GranolaImporter`), so with the key-entry UI
/// removed this sheet has no functional import path left. It shows a short
/// "not available" message instead of the former key-entry flow.
struct GranolaImportView: View {
    @ObservedObject var importer: GranolaImporter
    @ObservedObject var state: MeetingWindowState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("Import from Granola")
                .font(.title2.bold())

            Text("Granola import is not available in AF Flow. It requires pasting a Granola API key, and AF Flow never accepts key or token entry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 420)
    }
}
