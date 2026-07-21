import XCTest
@testable import GhostPepper

final class MeetingQASystemPromptTests: XCTestCase {
    func testPromptInterpolatesArchiveRoot() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Root: /tmp/Meetings"), prompt)
    }

    func testPromptDescribesGranolaFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Granola-imported"), prompt)
        XCTAssertTrue(prompt.contains("YAML frontmatter"), prompt)
    }

    func testPromptDescribesNativeFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Native AF Flow"), prompt)
        XCTAssertTrue(prompt.contains("**Date:**"), prompt)
        XCTAssertTrue(prompt.contains("## Notes"), prompt)
    }

    func testPromptRequiresCitations() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("cite"), prompt)
        XCTAssertTrue(prompt.contains("path:line"), prompt)
    }

    func testPromptHasVoiceToTextGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("voice-to-text") || prompt.contains("Voice-to-text"), prompt)
        XCTAssertTrue(prompt.contains("Quinn Adler"), "Should include the canonical artifact example")
    }

    func testPromptDescribesMultiHopGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("multi-hop") || prompt.contains("Multi-hop") || prompt.contains("know each other"), prompt)
    }

    func testPromptDescribesIterationBudget() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("15"), "Iteration cap should be visible to the model")
    }
}
