import AppKit
import CoreAudio
import Foundation

/// Detected meeting app info.
struct DetectedMeeting {
    let appName: String
    let bundleIdentifier: String
    let suggestedName: String // e.g. "Zoom — 10:03 AM"
    var isVideo: Bool = false
    var sourceURL: String? = nil
}

/// Monitors for running meeting/video call apps and notifies when one is detected.
/// Off by default — must be explicitly enabled via Settings.
@MainActor
final class MeetingDetector {
    var onMeetingDetected: ((DetectedMeeting) -> Void)?

    private var pollTimer: Timer?
    private var isRunning = false

    /// Bundle IDs that have been detected and dismissed this session (don't re-prompt).
    private var dismissedBundleIDs: Set<String> = []

    /// Bundle IDs of known meeting/video call apps.
    private static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.google.hangouts": "Google Meet",
        "com.slack.Slack": "Slack",
        "discord": "Discord",
        "com.hnc.Discord": "Discord",
    ]

    /// Window title patterns that suggest a browser-based meeting is active.
    private static let browserMeetingPatterns: [String] = [
        "meet.google.com",
        "google meet",
        "meet -",
        "zoom.us/j/",
        "zoom.us/wc/",
        "teams.microsoft.com",
        "teams.live.com",
        "whereby.com",
    ]

    /// Video site detection rules. `titlePattern` is checked against browser window titles.
    /// `playing` prefix (e.g. "▶") is optional — when present, only matches actively playing videos.
    private struct VideoSiteRule {
        let urlPattern: String
        let siteName: String
        let playingPrefix: String? // e.g. "▶" for YouTube
    }

    private static let videoSiteRules: [VideoSiteRule] = [
        VideoSiteRule(urlPattern: "- youtube", siteName: "YouTube", playingPrefix: nil),
        VideoSiteRule(urlPattern: "youtube.com", siteName: "YouTube", playingPrefix: nil),
        VideoSiteRule(urlPattern: "loom.com", siteName: "Loom", playingPrefix: nil),
        VideoSiteRule(urlPattern: "- vimeo", siteName: "Vimeo", playingPrefix: nil),
        VideoSiteRule(urlPattern: "vimeo.com", siteName: "Vimeo", playingPrefix: nil),
        VideoSiteRule(urlPattern: "twitch.tv", siteName: "Twitch", playingPrefix: nil),
        VideoSiteRule(urlPattern: "- twitch", siteName: "Twitch", playingPrefix: nil),
        VideoSiteRule(urlPattern: "netflix.com", siteName: "Netflix", playingPrefix: nil),
        VideoSiteRule(urlPattern: "dailymotion.com", siteName: "Dailymotion", playingPrefix: nil),
    ]

    /// Bundle IDs of common browsers.
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.operasoftware.Opera",
    ]

    /// Start polling for meeting apps.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Poll every 5 seconds — cheap operation.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForMeetingApps()
        }

        // Also check immediately.
        checkForMeetingApps()
    }

    /// Stop polling.
    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Mark a meeting app as dismissed so we don't prompt again this session.
    func dismiss(bundleID: String) {
        dismissedBundleIDs.insert(bundleID)
    }

    /// Reset dismissed state (e.g. when the user re-enables detection).
    func resetDismissals() {
        dismissedBundleIDs.removeAll()
    }

    // MARK: - Private

    private func checkForMeetingApps() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let frontmostBundleID = frontmost.bundleIdentifier else { return }

        // Check known meeting apps — only when frontmost to avoid false positives
        // from Zoom/Teams running in the background.
        if let appName = Self.knownMeetingApps[frontmostBundleID],
           !dismissedBundleIDs.contains(frontmostBundleID) {
            dismiss(bundleID: frontmostBundleID)
            let titles = AccessibilityWindowTitles.all(for: frontmost)
            let suggestedName = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
                ?? Self.suggestedMeetingName(appName: appName)
            let meeting = DetectedMeeting(
                appName: appName,
                bundleIdentifier: frontmostBundleID,
                suggestedName: suggestedName
            )
            onMeetingDetected?(meeting)
            return
        }

        // Check browsers for meeting URLs or video sites.
        if Self.browserBundleIDs.contains(frontmostBundleID) {
            let bundleID = frontmostBundleID
            let titles = AccessibilityWindowTitles.all(for: frontmost)

            // Check meetings first.
            if !dismissedBundleIDs.contains("browser-meeting"),
               let meetingName = matchMeetingPattern(in: titles) {
                dismiss(bundleID: "browser-meeting")
                let meeting = DetectedMeeting(
                    appName: meetingName,
                    bundleIdentifier: bundleID,
                    suggestedName: Self.suggestedMeetingName(appName: meetingName)
                )
                onMeetingDetected?(meeting)
                return
            }

            // Check video sites.
            if let (siteName, videoTitle) = matchVideoSite(in: titles) {
                let dismissKey = "video-\(siteName)"
                guard !dismissedBundleIDs.contains(dismissKey) else { return }
                dismiss(bundleID: dismissKey)

                let suggestedName: String
                if let videoTitle = videoTitle {
                    suggestedName = "\(siteName) - \(videoTitle)"
                } else {
                    suggestedName = Self.suggestedMeetingName(appName: siteName)
                }
                let url = browserURL(app: frontmost)
                let meeting = DetectedMeeting(
                    appName: siteName,
                    bundleIdentifier: bundleID,
                    suggestedName: suggestedName,
                    isVideo: true,
                    sourceURL: url
                )
                onMeetingDetected?(meeting)
            }
        }
    }

    /// Get all window titles from a browser app.
    /// Read the URL from the browser's address bar via Accessibility API.
    private func browserURL(app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused window
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success else {
            return nil
        }
        let window = windowValue as! AXUIElement

        // Search for a text field with role AXTextField that contains a URL-like value
        func findURLField(in element: AXUIElement) -> String? {
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String, role == "AXTextField" {
                var valueRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                   let value = valueRef as? String,
                   value.contains(".com") || value.contains("http") || value.contains(".") {
                    return value
                }
            }

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else {
                return nil
            }
            for child in children.prefix(20) { // limit depth
                if let url = findURLField(in: child) { return url }
            }
            return nil
        }

        return findURLField(in: window)
    }

    /// Check if any window title matches a browser-based meeting.
    private func matchMeetingPattern(in titles: [String]) -> String? {
        for title in titles {
            let lowered = title.lowercased()
            for pattern in Self.browserMeetingPatterns {
                if lowered.contains(pattern) {
                    if lowered.contains("meet.google.com") || lowered.contains("google meet") || lowered.hasPrefix("meet -") { return "Google Meet" }
                    if lowered.contains("zoom.us") { return "Zoom" }
                    if lowered.contains("teams.microsoft.com") || lowered.contains("teams.live.com") { return "Microsoft Teams" }
                    if lowered.contains("whereby.com") { return "Whereby" }
                    return "Video Call"
                }
            }
        }
        return nil
    }

    /// Check if any window title matches a video site. Returns (siteName, videoTitle?).
    /// For sites with a `playingPrefix` (e.g. YouTube's "▶"), only matches when the prefix is present.
    private func matchVideoSite(in titles: [String]) -> (String, String?)? {
        for title in titles {
            let lowered = title.lowercased()
            for rule in Self.videoSiteRules {
                guard lowered.contains(rule.urlPattern) || title.contains(rule.urlPattern) else {
                    continue
                }

                // If rule has a playing prefix, only match when video is actively playing.
                if let prefix = rule.playingPrefix {
                    guard title.hasPrefix(prefix) else { continue }
                    // Extract video title: "▶ How to Cook Pasta - YouTube" → "How to Cook Pasta"
                    let stripped = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    let videoTitle = stripped
                        .replacingOccurrences(of: " - YouTube", with: "")
                        .replacingOccurrences(of: " - Vimeo", with: "")
                        .replacingOccurrences(of: " on Vimeo", with: "")
                        .replacingOccurrences(of: " - Dailymotion", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    return (rule.siteName, videoTitle.isEmpty ? nil : videoTitle)
                }

                // No prefix required — site URL in title is enough.
                // Try to extract a video title by removing the site name suffix.
                let videoTitle = title
                    .replacingOccurrences(of: " | Loom", with: "")
                    .replacingOccurrences(of: " - Loom", with: "")
                    .replacingOccurrences(of: " - Twitch", with: "")
                    .replacingOccurrences(of: " - Netflix", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return (rule.siteName, videoTitle == title ? nil : videoTitle)
            }
        }
        return nil
    }

    /// Generate a default meeting name like "Zoom — 10:03 AM".
    /// Identifies the meeting app in front RIGHT NOW, once, on demand.
    ///
    /// This is the whole of detection as far as the menu is concerned. The
    /// class still contains the fork's polling machinery, which is not started
    /// anywhere: it ran every five seconds for the app's lifetime and walked
    /// every browser window's accessibility tree, in a dictation app, while
    /// Andrew was speaking. Reviving the feature must not revive that, so
    /// detection is a question asked at the moment he clicks rather than a loop
    /// that runs all day.
    @MainActor
    static func detectFrontmostMeetingNow() -> DetectedMeeting? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier else { return nil }

        if let appName = knownMeetingApps[bundleID] {
            let titles = AccessibilityWindowTitles.all(for: frontmost)
            let name = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
                ?? suggestedMeetingName(appName: appName)
            return DetectedMeeting(
                appName: appName,
                bundleIdentifier: bundleID,
                suggestedName: name
            )
        }

        // A browser in front: check its window titles for a call URL. One pass
        // over the frontmost app only, not every window of every browser.
        //
        // The bundle-id check matters: without it any frontmost app with
        // "meet.google.com" or "zoom.us/j/" in a window title is reported as a
        // live meeting, which includes a notes window, an editor, or a terminal
        // showing this very source file.
        guard browserBundleIDs.contains(bundleID) else { return nil }

        let titles = AccessibilityWindowTitles.all(for: frontmost)
        let lowercased = titles.map { $0.lowercased() }
        for pattern in browserMeetingPatterns {
            guard lowercased.contains(where: { $0.contains(pattern) }) else { continue }
            let appName = frontmost.localizedName ?? "Browser"
            let name = MeetingWindowHeuristics.bestMeetingTitle(in: titles, appName: appName)
                ?? suggestedMeetingName(appName: appName)
            return DetectedMeeting(
                appName: appName,
                bundleIdentifier: bundleID,
                suggestedName: name
            )
        }

        return nil
    }

    /// Fallback name when nothing recognisable is in front.
    static func defaultMeetingName() -> String {
        suggestedMeetingName(appName: "Meeting")
    }

    private static func suggestedMeetingName(appName: String) -> String {
        meetingName(appName: appName, at: Date())
    }

    /// What a recording is called before anything better is known.
    ///
    /// **Date and time first, then the app**, e.g. `2026-08-02 14:30 Zoom`.
    /// It used to be app first on a 12-hour clock, which produced
    /// `zoom-10-21-am.md`, and his verdict on 2026-07-29 was that it tells him
    /// nothing. Leading with the timestamp costs two things and buys two:
    ///
    /// 1. It says when, in the name, without opening anything.
    /// 2. **It sorts.** `MeetingHistory` orders a day's files by filename
    ///    descending to get newest first, so an app-first name sorted the day
    ///    by app: a 09:00 Teams call listed above a 14:30 Zoom one. The clock
    ///    is 24-hour for the same reason, because as text "10-21-am" sorts
    ///    after "02-30-pm".
    ///
    /// A calendar event name, when one is found, replaces this. This is the
    /// answer for the meetings that are not on his calendar, which he has said
    /// is some of them.
    ///
    /// The formatter is pinned to POSIX and takes an explicit time zone: the
    /// name is an identifier that ends up in a filename, so it must not move
    /// around when the machine's locale does. There is deliberately no locale
    /// parameter — a caller able to change it is a caller able to reintroduce
    /// a 12-hour clock, which is half of what this replaces.
    nonisolated static func meetingName(
        appName: String,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(appName)"
    }
}
