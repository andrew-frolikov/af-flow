import Foundation
import Combine

/// Holds the full event log for the current question. Powers the expandable trace UI.
/// Stores **full** tool inputs and outputs (not summaries) so tap-to-copy works.
@MainActor
final class QATranscript: ObservableObject {
    @Published private(set) var events: [QAEvent] = []

    func append(_ event: QAEvent) {
        events.append(event)
    }

    func clear() {
        events.removeAll()
    }
}
