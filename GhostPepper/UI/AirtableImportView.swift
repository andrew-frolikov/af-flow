import SwiftUI

/// Sheet view for syncing Airtable bases into Ghost Pepper.
///
/// AF Flow hard rule: never add an API key/token entry field. Airtable sync
/// only ever worked via a pasted personal access token, so with the
/// token-entry UI removed this sheet has no functional sync path left. It
/// shows a short "not available" message instead of the former token-entry
/// form.
struct AirtableImportView: View {
    @ObservedObject var importer: AirtableImporter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 36))
                .foregroundColor(.secondary)

            Text("Sync Airtable")
                .font(.title2.bold())

            Text("Airtable sync is not available in AF Flow. It requires pasting a personal access token, and AF Flow never accepts key or token entry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(width: 460)
    }
}
