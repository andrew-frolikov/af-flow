import XCTest
@testable import AFFlow

@MainActor
final class RuntimeModelInventoryTests: XCTestCase {
    func testRuntimeModelRowsIncludeAllSpeechAndCleanupModels() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: ["openai_whisper-tiny.en"],
            cleanupState: .downloading(kind: .qwen35_4b_q4_k_m, progress: 0.4),
            selectedCleanupModelKind: .qwen35_4b_q4_k_m,
            cachedCleanupKinds: [.qwen35_0_8b_q4_k_m, .qwen35_2b_q4_k_m]
        )

        XCTAssertTrue(rows.map(\.name).contains("Whisper tiny.en (speed)"))
        XCTAssertTrue(rows.map(\.name).contains("Whisper small.en (accuracy)"))
        XCTAssertTrue(rows.map(\.name).contains("Whisper small (multilingual)"))
        XCTAssertTrue(rows.map(\.name).contains("Parakeet v3 (25 languages)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 0.8B Q4_K_M (Very fast)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 2B Q4_K_M (Fast)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 4B Q4_K_M (Full)"))

        XCTAssertEqual(row(named: "Whisper tiny.en (speed)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Whisper tiny.en (speed)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Whisper small.en (accuracy)", in: rows)?.status, .downloading(progress: nil))
        XCTAssertEqual(row(named: "Whisper small.en (accuracy)", in: rows)?.isSelected, true)

        XCTAssertEqual(row(named: "Whisper small (multilingual)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Whisper small (multilingual)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Parakeet v3 (25 languages)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Parakeet v3 (25 languages)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 4B Q4_K_M (Full)", in: rows)?.status, .downloading(progress: 0.4))
        XCTAssertEqual(row(named: "Qwen 3.5 4B Q4_K_M (Full)", in: rows)?.isSelected, true)
    }

    func testRuntimeModelRowsSeparateSelectedSpeechModelFromActiveDownload() throws {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-tiny.en",
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: [],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )

        // Property: the row for the model currently being downloaded must
        // never be conflated with the row for the model the user has
        // selected. Looked up by catalog id (not array position) so that
        // SpeechModelCatalog.baseModels growing or reordering -- e.g. the
        // 2026-07-19 change that prepended two new default models ahead of
        // whisperTiny/whisperSmallEnglish -- cannot silently disable this
        // assertion again the way positional indices did.
        let activeDownloadRow = try XCTUnwrap(
            rows.first(where: { $0.id == SpeechModelCatalog.whisperTiny.id })
        )
        XCTAssertEqual(activeDownloadRow.status, .downloading(progress: nil))
        XCTAssertFalse(activeDownloadRow.isSelected)

        let selectedRow = try XCTUnwrap(
            rows.first(where: { $0.id == SpeechModelCatalog.whisperSmallEnglish.id })
        )
        XCTAssertEqual(selectedRow.status, .notLoaded)
        XCTAssertTrue(selectedRow.isSelected)
    }

    func testRuntimeModelRowsShowCachedSpeechModelAsLoadingInsteadOfDownloading() throws {
        // Exercise the "cached but loading" property against the model AF
        // Flow actually ships as the default (multilingual large-v3-turbo)
        // rather than the demoted English-only small.en, so this coverage
        // follows the model users actually run instead of parking itself on
        // one they are steered away from.
        let defaultModelID = SpeechModelCatalog.defaultModelID
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: defaultModelID,
            activeSpeechModelName: defaultModelID,
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: [defaultModelID],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )

        // Property: a model that is already on disk and merely being loaded
        // into memory must render as "loading", never as a phantom
        // "downloading". Looked up by catalog id, not array position, so
        // catalog reordering cannot silently disable this assertion again.
        let row = try XCTUnwrap(rows.first(where: { $0.id == defaultModelID }))
        XCTAssertEqual(row.status, .loading)
        XCTAssertNil(RuntimeModelInventory.activeDownloadText(rows: rows))
    }

    func testRuntimeModelRowsShowActiveCleanupLoadForNonSelectedCleanupModel() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .ready,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: ["openai_whisper-small.en"],
            cleanupState: .loadingModel(kind: .qwen35_0_8b_q4_k_m),
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: [.qwen35_0_8b_q4_k_m]
        )

        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.status, .loading)
        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.isSelected, false)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.isSelected, true)
    }

    func testSpeechAnalyzerRowIsSystemManagedWithoutManualActions() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
            activeSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
            speechModelState: .ready,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: [],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )
        let row = try XCTUnwrap(rows.first { $0.id == SpeechModelCatalog.speechAnalyzer.id })

        XCTAssertEqual(row.name, "Apple SpeechAnalyzer")
        XCTAssertEqual(row.sizeDescription, "Managed by macOS")
        XCTAssertEqual(row.status, .systemManaged)
        XCTAssertFalse(row.allowsManualDownload)
        XCTAssertFalse(row.allowsDeletion)
    }

    func testSpeechAnalyzerRowShowsAssetDownloadProgressWithoutManualActions() throws {
        guard #available(macOS 26, *) else {
            throw XCTSkip("SpeechAnalyzer requires macOS 26 or later.")
        }

        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
            activeSpeechModelName: SpeechModelCatalog.speechAnalyzer.id,
            speechModelState: .loading,
            speechDownloadProgress: 0.35,
            cachedSpeechModelNames: [SpeechModelCatalog.speechAnalyzer.id],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )
        let row = try XCTUnwrap(rows.first { $0.id == SpeechModelCatalog.speechAnalyzer.id })

        XCTAssertEqual(row.status, .downloading(progress: 0.35))
        XCTAssertFalse(row.allowsManualDownload)
        XCTAssertFalse(row.allowsDeletion)
        XCTAssertEqual(
            RuntimeModelInventory.activeDownloadText(rows: rows),
            "Downloading Apple SpeechAnalyzer (35%)..."
        )
    }

    private func row(named name: String, in rows: [RuntimeModelRow]) -> RuntimeModelRow? {
        rows.first(where: { $0.name == name })
    }
}
