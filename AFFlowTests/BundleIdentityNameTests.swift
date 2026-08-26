import XCTest
@testable import AFFlow

/// One bundle, one name, in every macOS list a person can open.
///
/// WHY THIS EXISTS. On 2026-08-25 Andrew opened System Settings > Privacy and
/// Security > Input Monitoring and found "AF Flow" listed TWICE, both allowed.
/// The second row was the TEST HOST. Since 2026-07-26 the test host has carried
/// its own bundle identifier, `com.frolikov.afflow.testhost`, deliberately, so
/// that it can never be installed as his app and can never reach his settings.
/// But only the IDENTIFIER was ever given a separate identity. `Info.plist`
/// hardcoded `CFBundleName` and `CFBundleDisplayName` as the literal `AF Flow`,
/// and macOS labels a privacy row with the bundle's display name. Two allowed
/// rows, one label, nothing on screen to tell them apart.
///
/// The naming decision is `docs/design/af-flow-system-list-names.md`: the bare
/// name "AF Flow" belongs to exactly one bundle, the app; every other bundle in
/// the family is "AF Flow " plus plain words naming its job.
///
/// WHAT THIS FILE CAN AND CANNOT PROVE, said plainly because a green test that
/// could never go red is a defect here. This runs inside the test host, and
/// `scripts/run-tests.sh` sets the test host's identifier unconditionally on
/// every `build-for-testing`. So `Bundle.main` here is ALWAYS the test host, and
/// there is no sanctioned path on which it is the app. **This file covers the
/// test host only.** The app's own two name keys are verified where they can
/// actually be observed, by PlistBuddy against the built bundle in the
/// `AF_FLOW_APP_BUILD=1` branch of `scripts/run-tests.sh`, which refuses to
/// report success on a wrong name the same way it already refuses on a wrong
/// identifier. Both were seen failing on 2026-08-25.
///
/// The third surface is `scripts/system-list-check.py`, which reads the TCC
/// databases and LaunchServices at session start. Three layers, because none of
/// them can see what the other two see.
final class BundleIdentityNameTests: XCTestCase {
    private func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// The test host must not be wearing the app's name.
    ///
    /// The `default:` arm is the one that catches an unknown bundle, so nothing
    /// else needs to assert that separately: a third identifier reaching this
    /// suite fails here, once, rather than in two places that could disagree.
    func testTheDisplayNameSaysWhichBundleThisIs() throws {
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier, "Bundle.main has no identifier")
        let displayName = try XCTUnwrap(
            infoString("CFBundleDisplayName"),
            "CFBundleDisplayName is missing; macOS would label this row with the executable name"
        )

        switch identifier {
        case "com.frolikov.afflow.testhost":
            XCTAssertEqual(
                displayName, "AF Flow Tests",
                """
                The test host is showing the app's own name. This is the 2026-08-25 \
                defect: Input Monitoring lists one row per bundle labelled with its \
                display name, so an identically named test host is a second \
                indistinguishable "AF Flow" in Andrew's privacy settings.
                """
            )
        case "com.frolikov.afflow":
            // Unreachable under scripts/run-tests.sh, and kept only so that a
            // future change which stops overriding the identifier fails loudly
            // rather than silently skipping. Not counted as coverage of the app.
            XCTAssertEqual(displayName, "AF Flow")
        default:
            XCTFail(
                """
                Unknown bundle identifier '\(identifier)'. TCC keys on the \
                identifier, so a new one earns its own permanent row in System \
                Settings and inherits none of the existing grants. Every bundle in \
                this family needs a decided name before it can request a \
                permission: see docs/design/af-flow-system-list-names.md.
                """
            )
        }
    }

    /// Different macOS surfaces read different keys, and letting the two
    /// disagree invites ONE bundle to appear under TWO names.
    ///
    /// Today both keys expand from the same `$(AF_FLOW_DISPLAY_NAME)` token in a
    /// single file, so this can only fire if someone hand-edits `Info.plist` to
    /// unlink them. That is exactly the edit worth catching, and it is the whole
    /// claim this test makes: it does NOT prove the value is right, only that
    /// one value reaches both keys.
    func testBothNameKeysCarryTheSameValue() throws {
        let bundleName = try XCTUnwrap(infoString("CFBundleName"), "CFBundleName is missing")
        let displayName = try XCTUnwrap(infoString("CFBundleDisplayName"), "CFBundleDisplayName is missing")

        XCTAssertEqual(
            bundleName, displayName,
            "CFBundleName and CFBundleDisplayName must always be identical."
        )
    }
}
