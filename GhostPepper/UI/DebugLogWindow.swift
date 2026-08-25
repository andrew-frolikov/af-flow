import SwiftUI
import AppKit

/// No longer `private`: since 2026-08-24 this is a SECTION of AF Flow's one
/// window, not the content of a floating panel of its own.
struct DebugLogWindowView: View {
    @ObservedObject var debugLogStore: DebugLogStore
    @State private var shouldFollowTail = true

    private let bottomAnchorID = "debug-log-bottom"
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Copy Log") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(debugLogStore.formattedText, forType: .string)
                }
                .disabled(debugLogStore.entries.isEmpty)

                Button("Clear") {
                    debugLogStore.clear()
                }
                .disabled(debugLogStore.entries.isEmpty)

                Spacer()
            }

            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if debugLogStore.entries.isEmpty {
                                Text("No debug events yet.")
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                ForEach(debugLogStore.entries) { entry in
                                    Text(formattedText(for: entry))
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(entry.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: DebugLogBottomOffsetPreferenceKey.self,
                                            value: geometry.frame(in: .named("debug-log-scroll")).maxY
                                        )
                                    }
                                )
                        }
                    }
                    .coordinateSpace(name: "debug-log-scroll")
                    .onAppear {
                        scrollToBottom(with: proxy)
                    }
                    .onChange(of: debugLogStore.entries.count) { _, _ in
                        guard shouldFollowTail else {
                            return
                        }
                        scrollToBottom(with: proxy)
                    }
                    .onPreferenceChange(DebugLogBottomOffsetPreferenceKey.self) { bottomOffset in
                        shouldFollowTail = bottomOffset - outer.size.height <= 32
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        // No `minWidth`. It was 640, sized for the floating panel this used to
        // live in; embedded in the detail pane there is about 630 points at the
        // default window width and about 530 at the minimum, and the enclosing
        // ScrollView scrolls only vertically — so the old floor clipped the
        // trailing end of every line. Codex, 2026-08-24. The section sets the
        // height it wants.
        .frame(minHeight: 420)
    }

    private func formattedText(for entry: DebugLogEntry) -> String {
        "[\(formattedTime(for: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)"
    }

    private func formattedTime(for timestamp: Date) -> String {
        Self.timeFormatter.string(from: timestamp)
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
}

private struct DebugLogBottomOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
