import SwiftUI

/// Searchable list of all entries in a given index kind. Shown as a tab when
/// the user clicks "People" in the sidebar. Each row is a tappable name that
/// navigates the current tab to the dossier; right-click opens in a new tab.
struct IndexListView: View {
    @Environment(\.appTheme) private var theme
    let kind: IndexKind
    let items: [IndexHistoryItem]
    var onOpenEntry: (_ kind: IndexKind, _ slug: String) -> Void = { _, _ in }
    var onOpenEntryInNewTab: (_ kind: IndexKind, _ slug: String) -> Void = { _, _ in }
    var onBuild: () -> Void = {}

    @State private var searchText: String = ""

    private var filtered: [IndexHistoryItem] {
        guard !searchText.isEmpty else { return items }
        let needle = searchText.lowercased()
        return items.filter { $0.canonicalName.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separator)
            if items.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: kind.iconSystemName)
                    .font(theme.textFont(size: 22))
                Text(kind.displayName)
                    .font(theme.textFont(size: 22, weight: 600))
                Text("(\(items.count))")
                    .font(theme.textFont(size: 14))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(theme.textFont(size: 12))
                    .foregroundStyle(theme.textSecondary)
                TextField("Search \(kind.displayName.lowercased())", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(theme.textFont(size: 13))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(theme.textFont(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.textBackground)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.separator, lineWidth: 1))
            )
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: kind.iconSystemName)
                .font(theme.textFont(size: 36))
                .foregroundStyle(theme.textSecondary)
            Text("No \(kind.displayName.lowercased()) yet")
                .font(theme.textFont(size: 15, weight: 500))
            Text("Build the index from your meeting archive to populate this list.")
                .font(theme.textFont(size: 12))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: onBuild) {
                Label("Build \(kind.displayName) index", systemImage: "wand.and.stars")
            }
            .buttonStyle(AFFlowPrimaryButtonStyle())
            .tint(theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    Text("No matches for \"\(searchText)\"")
                        .font(theme.textFont(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                } else {
                    ForEach(filtered) { item in
                        row(for: item)
                        Divider().overlay(theme.separator)
                    }
                }
            }
        }
    }

    private func row(for item: IndexHistoryItem) -> some View {
        Button(action: { onOpenEntry(item.kind, item.slug) }) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(theme.textFont(size: 14))
                    .foregroundStyle(theme.textSecondary)
                Text(item.canonicalName)
                    .font(theme.textFont(size: 14))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(theme.textFont(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in new tab") {
                onOpenEntryInNewTab(item.kind, item.slug)
            }
        }
    }
}
