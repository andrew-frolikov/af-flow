import AppKit
import SwiftUI

/// Read-only NSTextView wrapper that highlights matches of `query` in `text`,
/// scrolls the active match into view, and reports the total match count back
/// to the caller. Used by the meeting/article/summary views while a search
/// is active.
struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let query: String
    let currentMatchIndex: Int
    let font: NSFont
    let onMatchCountChange: (Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: font, range: fullRange)
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        let ranges = Self.findMatches(in: nsText, query: query)
        let activeIndex = ranges.indices.contains(currentMatchIndex) ? currentMatchIndex : 0
        // Search highlighting is the brand's signal colour, not the system's
        // orange. This file was never reached by the colour sweep and it is
        // instantiated three times from the transcript viewer.
        for (i, range) in ranges.enumerated() {
            let bg = (i == activeIndex)
                ? NSColor(Brand.accent).withAlphaComponent(0.7)
                : NSColor(Brand.accent).withAlphaComponent(0.3)
            attr.addAttribute(.backgroundColor, value: bg, range: range)
        }

        if storage.string != attr.string || storage.length != attr.length {
            storage.setAttributedString(attr)
        } else {
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: fullRange)
            for (i, range) in ranges.enumerated() {
                let bg = (i == activeIndex)
                    ? NSColor(Brand.accent).withAlphaComponent(0.7)
                    : NSColor(Brand.accent).withAlphaComponent(0.3)
                storage.addAttribute(.backgroundColor, value: bg, range: range)
            }
            storage.endEditing()
        }

        // Report match count after the layout pass so SwiftUI doesn't update mid-render.
        let count = ranges.count
        DispatchQueue.main.async {
            onMatchCountChange(count)
        }

        if ranges.indices.contains(activeIndex) {
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(ranges[activeIndex])
            }
        }
    }

    private static func findMatches(in text: NSString, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.location < text.length {
            let found = text.range(of: query, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: text.length - next)
        }
        return ranges
    }
}
