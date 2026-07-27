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
        let lease = LLMLease()

        // A generation slower than the deadline. It checks its own
        // cancellation state, which is the exact signal that would reach
        // llama.cpp and abort the process.
        let deadlineExceeded: Bool
        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
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
        await lease.waitUntilIdle()

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
        let lease = LLMLease()

        let result = try await lease.run(deadline: 5.0) { () -> String in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return "cleaned text"
        }

        XCTAssertEqual(result, "cleaned text")
    }

    // MARK: - Invariant 2: teardown waits for the generation

    func testWaitingForInFlightGenerationBlocksUntilItCompletes() async throws {
        let recorder = CompletionRecorder()
        let lease = LLMLease()

        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
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
        await lease.waitUntilIdle()

        let finished = await recorder.finished
        XCTAssertTrue(
            finished,
            "Teardown returned while a generation was still running. Releasing the model here is what aborts the process."
        )
    }

    func testWaitingWithNoGenerationInFlightReturnsImmediately() async {
        let lease = LLMLease()
        await lease.waitUntilIdle()
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
        let lease = LLMLease()

        XCTAssertFalse(
            lease.isHeldSynchronously,
            "Nothing has run yet."
        )

        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        XCTAssertTrue(
            lease.isHeldSynchronously,
            "Termination must be able to see, without awaiting, that a generation is still running. Shutting the backend down here aborts the process."
        )

        await lease.waitUntilIdle()

        XCTAssertFalse(
            lease.isHeldSynchronously,
            "Once drained, termination must be free to shut the backend down normally."
        )
    }

    // MARK: - Bounding the wait for a PREVIOUS generation

    /// Serialising behind a stuck generation without a bound would let one slow
    /// cleanup make the next dictation wait far past its deadline, which is the
    /// latency the deadline exists to cap. Codex raised this on the first
    /// review round.
    func testASecondCallDoesNotWaitLongerThanItsOwnDeadline() async throws {
        let lease = LLMLease()

        // First generation runs long and the caller gives up on it.
        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
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
            _ = try await lease.run(deadline: 0.1) { () -> String in "fast" }
            XCTFail("Expected the second call to give up rather than queue behind the stuck generation.")
        } catch is CleanupGenerationDeadlineExceeded {
            let waited = Date().timeIntervalSince(started)
            XCTAssertLessThan(
                waited,
                1.0,
                "The second caller waited \(waited)s behind a stuck generation. Its own deadline was 0.1s."
            )
        }

        await lease.waitUntilIdle()
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
        let lease = LLMLease()
        var shutdownCount = 0
        let manager = TextCleanupManager(
            backendShutdownOverride: { shutdownCount += 1 },
            llmLease: lease
        )

        // Put a generation in flight and abandon the wait, exactly as a
        // timed-out cleanup does.
        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
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

        await lease.waitUntilIdle()

        manager.shutdownBackendForTermination()

        XCTAssertEqual(
            shutdownCount,
            1,
            "With nothing running, termination must shut the backend down as it always did."
        )
    }

    @MainActor
    func testUnloadWaitsForAnInFlightGeneration() async throws {
        let lease = LLMLease()
        let manager = TextCleanupManager(llmLease: lease)
        let recorder = CompletionRecorder()

        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
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
        let lease = LLMLease()

        await lease.beginTeardown()

        // A caller arriving mid-teardown must be refused rather than allowed to
        // start on a model that is about to be released.
        do {
            _ = try await lease.run(deadline: 1.0) { () -> String in "should never run" }
            XCTFail("A generation started while teardown held the barrier.")
        } catch is CleanupModelTeardownInProgress {
            // Expected.
        }

        await lease.endTeardown()

        // Once the barrier is released, work proceeds normally again.
        let result = try await lease.run(deadline: 1.0) { () -> String in "ran" }
        XCTAssertEqual(result, "ran")
    }

    func testTeardownWaitsForLiveWorkBeforeReturning() async throws {
        let lease = LLMLease()
        let recorder = CompletionRecorder()

        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 250_000_000)
                await recorder.markFinished()
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        await lease.beginTeardown()
        let finished = await recorder.finished
        await lease.endTeardown()

        XCTAssertTrue(
            finished,
            "beginTeardown() returned while work was still live, so the model would be released underneath it."
        )
    }

    // MARK: - The synchronous flag is published before work starts

    /// Codex round 2, finding 4. Publishing the flag after spawning the task
    /// left a window in which termination read "idle" while `operation()` had
    /// already entered llama.cpp.
    /// The first version of this test WROTE a value it never read, so an
    /// implementation that spawned the work first and published the flag
    /// shortly afterwards passed it. Codex found that; I did not. It is the
    /// project's own signature error: a gate you wrote yourself is a claim, not
    /// a proof, and the way to tell is to ask what the test does when the code
    /// is wrong.
    ///
    /// This version asks the operation itself what it saw on entry, which is the
    /// only place the answer distinguishes the two implementations.
    func testSynchronousFlagIsTrueBeforeTheOperationCanRun() async throws {
        let lease = LLMLease()
        let observed = FirstObservation()

        do {
            _ = try await lease.run(deadline: 0.02) { [observed] () -> String in
                // Read the flag from INSIDE the work. If publication happened
                // after spawning, this is the window where it reads false.
                await observed.record(lease.isHeldSynchronously)
                try? await Task.sleep(nanoseconds: 250_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        await lease.waitUntilIdle()

        let firstSeen = await observed.value
        XCTAssertEqual(
            firstSeen,
            true,
            "The operation was already running while a synchronous reader saw the model idle. Termination in that window releases the backend under live work."
        )

        XCTAssertFalse(lease.isHeldSynchronously)
    }

    /// Records only the first value observed, so a later correct reading cannot
    /// paper over an incorrect one at entry.
    private actor FirstObservation {
        private(set) var value: Bool?

        func record(_ seen: Bool) {
            guard value == nil else { return }
            value = seen
        }
    }

    // MARK: - The lease covers every LLM path, not just cleanup

    /// Codex round 2 finding 1: `streamCompletion` and `prefillPromptContext`
    /// drive `llm.core` directly and were untracked, so termination could see
    /// idle and release the backend while an agent stream was generating. Those
    /// paths now take the same lease, so a plain `acquire()` must be as visible
    /// as a cleanup generation.
    func testAPlainAcquisitionIsVisibleAndExclusive() async throws {
        let lease = LLMLease()

        let ticket = try await lease.acquire()

        XCTAssertTrue(
            lease.isHeldSynchronously,
            "A stream or prefill holding the model must be visible to a synchronous reader, or termination releases the backend under it."
        )

        let held = await lease.isHeld
        XCTAssertTrue(held)

        // Exclusivity: nobody else may take the model while this holds it.
        do {
            _ = try await lease.acquire(within: 0.05)
            XCTFail("Two callers held the model at once. They share one LLM instance.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        await lease.release(ticket)
        XCTAssertFalse(lease.isHeldSynchronously)

        // And it is available again afterwards.
        let second = try await lease.acquire(within: 0.5)
        await lease.release(second)
    }

    /// A release from someone who no longer holds the lease must not free work
    /// that is still running.
    func testAStaleReleaseCannotFreeSomeoneElsesLease() async throws {
        let lease = LLMLease()

        let first = try await lease.acquire()
        await lease.release(first)

        let second = try await lease.acquire()

        // The previous holder releasing late must not free the current holder.
        await lease.release(first)

        XCTAssertTrue(
            lease.isHeldSynchronously,
            "A stale release freed the lease out from under the current holder."
        )

        await lease.release(second)
        XCTAssertFalse(lease.isHeldSynchronously)
    }

    func testTrackerReportsWhetherAGenerationIsInFlight() async throws {
        let lease = LLMLease()

        let idleBefore = await lease.isHeld
        XCTAssertFalse(idleBefore)

        do {
            _ = try await lease.run(deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 200_000_000)
                return "done"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        let busyAfterTimeout = await lease.isHeld
        XCTAssertTrue(
            busyAfterTimeout,
            "A generation the caller stopped waiting for is still in flight and must be reported as such."
        )

        await lease.waitUntilIdle()

        let idleAfter = await lease.isHeld
        XCTAssertFalse(idleAfter)
    }
    // MARK: - Non-reentrancy, and the API that exists because of it

    /// The lease is deliberately NOT re-entrant, and that is a trap: a caller
    /// holding it that calls `run(deadline:)` waits out the whole deadline
    /// against itself and then fails without ever reaching the model.
    ///
    /// Codex found exactly that in `probe()`, where it would have broken every
    /// real cleanup. Pinned here so the property is visible rather than
    /// discovered again.
    func testTheLeaseIsNotReentrantAndSaysSoQuickly() async throws {
        let lease = LLMLease()
        let ticket = try await lease.acquire()

        let started = Date()
        do {
            _ = try await lease.run(deadline: 0.1) { () -> String in "never runs" }
            XCTFail("A holder re-acquired its own lease. That is the self-deadlock.")
        } catch is CleanupGenerationDeadlineExceeded {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        }

        await lease.release(ticket)
    }

    /// `run(holding:)` is the way a caller that already holds the lease runs
    /// work under it. It must not re-acquire, and it takes over releasing.
    func testRunHoldingUsesTheExistingTicketAndReleasesItWhenWorkEnds() async throws {
        let lease = LLMLease()
        let recorder = CompletionRecorder()

        let ticket = try await lease.acquire()

        let result = try await lease.run(holding: ticket, deadline: 2.0) { () -> String in
            await recorder.markFinished()
            return "generated"
        }

        XCTAssertEqual(result, "generated", "run(holding:) must run the work rather than deadlocking on its own lease.")

        await lease.waitUntilIdle()
        XCTAssertFalse(
            lease.isHeldSynchronously,
            "run(holding:) took ownership of the ticket and must release it when the work ends."
        )

        // And the lease is usable again, so nothing leaked.
        let next = try await lease.acquire(within: 0.5)
        await lease.release(next)
    }

    /// A caller that abandons `run(holding:)` on deadline must still leave the
    /// lease held until the work truly finishes, then released.
    func testRunHoldingKeepsTheLeaseUntilAbandonedWorkFinishes() async throws {
        let lease = LLMLease()
        let recorder = CompletionRecorder()

        let ticket = try await lease.acquire()

        do {
            _ = try await lease.run(holding: ticket, deadline: 0.05) { () -> String in
                try? await Task.sleep(nanoseconds: 250_000_000)
                await recorder.markFinished()
                return "slow"
            }
            XCTFail("Expected the deadline to be exceeded.")
        } catch is CleanupGenerationDeadlineExceeded {
            // Expected.
        }

        XCTAssertTrue(
            lease.isHeldSynchronously,
            "The caller gave up, but the work is still running and the model must stay marked in use."
        )

        await lease.waitUntilIdle()

        let finished = await recorder.finished
        XCTAssertTrue(finished)
        XCTAssertFalse(lease.isHeldSynchronously)
    }
    /// A ticket that no longer owns the lease must not be able to start work.
    /// Codex found that `run(holding:)` checked nothing, so a stale ticket could
    /// run its operation alongside the real holder on the same LLM, and only its
    /// release was ignored, which is far too late to matter.
    func testRunHoldingRefusesAStaleTicketAndDoesNotRunTheWork() async throws {
        let lease = LLMLease()
        let recorder = CompletionRecorder()

        let stale = try await lease.acquire()
        await lease.release(stale)

        // Someone else now owns the lease.
        let current = try await lease.acquire()

        do {
            _ = try await lease.run(holding: stale, deadline: 1.0) { () -> String in
                await recorder.markFinished()
                return "should never run"
            }
            XCTFail("A stale ticket started work while another holder owned the lease.")
        } catch is CleanupModelTeardownInProgress {
            // Expected.
        }

        let ran = await recorder.finished
        XCTAssertFalse(
            ran,
            "The stale ticket's work executed. It would have driven the same LLM as the real holder."
        )

        await lease.release(current)
    }
}
