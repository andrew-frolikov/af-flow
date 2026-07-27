import XCTest
@testable import GhostPepper

/// Ledger 27. A cleanup generation that runs past the deadline used to be
/// CANCELLED, and cancelling an in-flight llama.cpp generation is what trips
/// `GGML_ASSERT` in `ggml_metal_device_free`. llama.cpp responds with
/// `ggml_abort`, which kills the process rather than throwing, so the failure
/// is not catchable anywhere in Swift.
///
/// These tests pin the two invariants that make that unreachable:
///
/// 1. A slow generation is never cancelled. The caller stops WAITING; the
///    generation keeps running to completion on its own.
/// 2. The model is never released while a generation is in flight.
///
/// Both are asserted against observable behaviour rather than against the
/// implementation, so a future refactor that reintroduces cancellation fails
/// these rather than quietly passing.
///
/// Neither test loads a model. They exercise the lifetime primitives directly
/// with stub work, which is why they run in milliseconds and need no network.
final class CleanupGenerationLifetimeTests: XCTestCase {

    /// Records whether a stub "generation" ran to completion or was cut short.
    private actor CompletionRecorder {
        private(set) var finished = false
        private(set) var observedCancellation = false

        func markFinished() { finished = true }
        func markCancelled() { observedCancellation = true }
    }

    // MARK: - Invariant 1: the deadline bounds the wait, not the generation

    func testGenerationOutlivingTheDeadlineIsNotCancelled() async throws {
        let recorder = CompletionRecorder()
        let tracker = CleanupGenerationTracker()

        // A generation slower than the deadline. It checks its own
        // cancellation state, which is the exact signal that would reach
        // llama.cpp and abort the process.
        let deadlineExceeded: Bool
        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled {
                    await recorder.markCancelled()
                }
                await recorder.markFinished()
                return "done"
            }
            deadlineExceeded = false
        } catch is CleanupGenerationDeadlineExceeded {
            deadlineExceeded = true
        }

        XCTAssertTrue(
            deadlineExceeded,
            "The caller must stop waiting once the deadline passes."
        )

        // The caller has already been handed its timeout. The generation is
        // still running, and must be allowed to finish untouched.
        await tracker.waitForInFlightGeneration()

        let cancelled = await recorder.observedCancellation
        let finished = await recorder.finished

        XCTAssertFalse(
            cancelled,
            "The generation saw a cancellation signal. That signal is what calls ggml_abort and kills the process."
        )
        XCTAssertTrue(
            finished,
            "The generation must run to completion after the caller gives up on it."
        )
    }

    func testGenerationFinishingBeforeTheDeadlineReturnsItsValue() async throws {
        let tracker = CleanupGenerationTracker()

        let result = try await tracker.run(deadline: 5.0) { () -> String in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return "cleaned text"
        }

        XCTAssertEqual(result, "cleaned text")
    }

    // MARK: - Invariant 2: teardown waits for the generation

    func testWaitingForInFlightGenerationBlocksUntilItCompletes() async throws {
        let recorder = CompletionRecorder()
        let tracker = CleanupGenerationTracker()

        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 200_000_000)
                await recorder.markFinished()
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        // This is what the three `activeLLM = nil` sites must do before
        // releasing the model. If it returns early, the model is freed under a
        // running generation and the process dies.
        await tracker.waitForInFlightGeneration()

        let finished = await recorder.finished
        XCTAssertTrue(
            finished,
            "Teardown returned while a generation was still running. Releasing the model here is what aborts the process."
        )
    }

    func testWaitingWithNoGenerationInFlightReturnsImmediately() async {
        let tracker = CleanupGenerationTracker()
        await tracker.waitForInFlightGeneration()
    }

    // MARK: - The synchronous flag, for termination

    /// App termination cannot await. `prepareForTermination()` runs from
    /// `willTerminateNotification` while the process is already going away, so
    /// it needs a synchronous answer to "is a generation running?".
    ///
    /// The first attempt at this fix spawned a Task there instead, which
    /// silently disabled backend shutdown at quit because the Task never got to
    /// run. An existing test caught it. This pins the primitive that replaced
    /// it, so the synchronous reader cannot rot back into an async one.
    func testSynchronousFlagTracksGenerationLifetime() async throws {
        let tracker = CleanupGenerationTracker()

        XCTAssertFalse(
            tracker.isGenerationInFlightSynchronously,
            "Nothing has run yet."
        )

        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        XCTAssertTrue(
            tracker.isGenerationInFlightSynchronously,
            "Termination must be able to see, without awaiting, that a generation is still running. Shutting the backend down here aborts the process."
        )

        await tracker.waitForInFlightGeneration()

        XCTAssertFalse(
            tracker.isGenerationInFlightSynchronously,
            "Once drained, termination must be free to shut the backend down normally."
        )
    }

    // MARK: - Bounding the wait for a PREVIOUS generation

    /// Serialising behind a stuck generation without a bound would let one slow
    /// cleanup make the next dictation wait far past its deadline, which is the
    /// latency the deadline exists to cap. Codex raised this on the first
    /// review round.
    func testASecondCallDoesNotWaitLongerThanItsOwnDeadline() async throws {
        let tracker = CleanupGenerationTracker()

        // First generation runs long and the caller gives up on it.
        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return "slow"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        // Second caller arrives while the first is still running. It must be
        // bounded by its own deadline, not by the first generation's runtime.
        let started = Date()
        do {
            _ = try await tracker.run(deadline: 0.1) { () -> String in "fast" }
            XCTFail("Expected the second call to give up rather than queue behind the stuck generation.")
        } catch is CleanupGenerationDeadlineExceeded {
            let waited = Date().timeIntervalSince(started)
            XCTAssertLessThan(
                waited,
                1.0,
                "The second caller waited \(waited)s behind a stuck generation. Its own deadline was 0.1s."
            )
        }

        await tracker.waitForInFlightGeneration()
    }

    // MARK: - TextCleanupManager actually uses the tracker

    /// The tracker being correct proves nothing if `TextCleanupManager` does not
    /// consult it. Codex raised exactly this on the first review round: the
    /// standalone tests could pass while the manager still released the model
    /// under a running generation.
    ///
    /// Driving a real timeout through the manager needs a loaded llama.cpp
    /// model, which no unit test can have. So the tracker is injected instead,
    /// a generation is put in flight through it directly, and the manager's
    /// teardown paths are asserted against that.
    @MainActor
    func testTerminationSkipsBackendShutdownWhileAGenerationRuns() async throws {
        let tracker = CleanupGenerationTracker()
        var shutdownCount = 0
        let manager = TextCleanupManager(
            backendShutdownOverride: { shutdownCount += 1 },
            generationTracker: tracker
        )

        // Put a generation in flight and abandon the wait, exactly as a
        // timed-out cleanup does.
        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 400_000_000)
                return "still going"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        manager.shutdownBackendForTermination()

        XCTAssertEqual(
            shutdownCount,
            0,
            "The backend was shut down while a generation was running. That is the ggml_abort path: the app dies on quit instead of quitting."
        )

        await tracker.waitForInFlightGeneration()

        manager.shutdownBackendForTermination()

        XCTAssertEqual(
            shutdownCount,
            1,
            "With nothing running, termination must shut the backend down as it always did."
        )
    }

    @MainActor
    func testUnloadWaitsForAnInFlightGeneration() async throws {
        let tracker = CleanupGenerationTracker()
        let manager = TextCleanupManager(generationTracker: tracker)
        let recorder = CompletionRecorder()

        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await recorder.markFinished()
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        await manager.unloadModel()

        let finished = await recorder.finished
        XCTAssertTrue(
            finished,
            "unloadModel() returned while a generation was still running, so it would have released the model underneath it."
        )
    }

    // MARK: - The teardown barrier (Codex round 2, finding 2)

    /// Waiting for live work is not enough. After a cleanup times out, the
    /// execution gate is released, so a second caller can enter while the first
    /// is still draining. A teardown that only waited could return just as that
    /// second caller started, and then release the model underneath it.
    func testTeardownRefusesNewWorkWhileItHoldsTheBarrier() async throws {
        let tracker = CleanupGenerationTracker()

        await tracker.beginTeardown()

        // A caller arriving mid-teardown must be refused rather than allowed to
        // start on a model that is about to be released.
        do {
            _ = try await tracker.run(deadline: 1.0) { () -> String in "should never run" }
            XCTFail("A generation started while teardown held the barrier.")
        } catch is CleanupModelTeardownInProgress {
            // Expected.
        }

        await tracker.endTeardown()

        // Once the barrier is released, work proceeds normally again.
        let result = try await tracker.run(deadline: 1.0) { () -> String in "ran" }
        XCTAssertEqual(result, "ran")
    }

    func testTeardownWaitsForLiveWorkBeforeReturning() async throws {
        let tracker = CleanupGenerationTracker()
        let recorder = CompletionRecorder()

        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 250_000_000)
                await recorder.markFinished()
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        await tracker.beginTeardown()
        let finished = await recorder.finished
        await tracker.endTeardown()

        XCTAssertTrue(
            finished,
            "beginTeardown() returned while work was still live, so the model would be released underneath it."
        )
    }

    // MARK: - The synchronous flag is published before work starts

    /// Codex round 2, finding 4. Publishing the flag after spawning the task
    /// left a window in which termination read "idle" while `operation()` had
    /// already entered llama.cpp.
    func testSynchronousFlagIsTrueBeforeTheOperationCanRun() async throws {
        let tracker = CleanupGenerationTracker()
        let gate = CompletionRecorder()

        do {
            _ = try await tracker.run(deadline: 0.02) { () -> String in
                // If the flag were published after spawning, this could already
                // be executing while a synchronous reader saw false.
                await gate.markFinished()
                try? await Task.sleep(nanoseconds: 250_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        XCTAssertTrue(
            tracker.isGenerationInFlightSynchronously,
            "Work is live but a synchronous reader sees idle. Termination would release the backend under it."
        )

        await tracker.waitForInFlightGeneration()
        XCTAssertFalse(tracker.isGenerationInFlightSynchronously)
    }

    // MARK: - Uses cover every LLM path, not just cleanup

    /// Codex round 2, finding 1: `streamCompletion` and `prefillPromptContext`
    /// drive `llm.core` directly and were untracked, so termination could see
    /// idle and release the backend while an agent stream was generating.
    /// The unit is now a use rather than a cleanup generation.
    func testAnyRegisteredUseBlocksTeardownAndShowsInTheSyncFlag() async throws {
        let tracker = CleanupGenerationTracker()

        try await tracker.beginUse()

        XCTAssertTrue(
            tracker.isGenerationInFlightSynchronously,
            "A registered use must be visible to a synchronous reader even though no cleanup generation is running."
        )

        let inFlight = await tracker.hasGenerationInFlight
        XCTAssertTrue(inFlight)

        await tracker.endUse()

        XCTAssertFalse(tracker.isGenerationInFlightSynchronously)
    }

    func testTrackerReportsWhetherAGenerationIsInFlight() async throws {
        let tracker = CleanupGenerationTracker()

        let idleBefore = await tracker.hasGenerationInFlight
        XCTAssertFalse(idleBefore)

        do {
            _ = try await tracker.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        let busyAfterTimeout = await tracker.hasGenerationInFlight
        XCTAssertTrue(
            busyAfterTimeout,
            "A generation the caller stopped waiting for is still in flight and must be reported as such."
        )

        await tracker.waitForInFlightGeneration()

        let idleAfter = await tracker.hasGenerationInFlight
        XCTAssertFalse(idleAfter)
    }
}
