import Foundation

/// Thrown when a cleanup generation runs past its deadline.
///
/// Deliberately NOT `CancellationError`. The distinction is the whole point of
/// this file: the caller has stopped waiting, and nothing has been cancelled.
struct CleanupGenerationDeadlineExceeded: Error, LocalizedError {
    var errorDescription: String? {
        "Local cleanup took longer than expected."
    }
}

/// Thrown when live LLM work is requested while the model is being released.
struct CleanupModelTeardownInProgress: Error, LocalizedError {
    var errorDescription: String? {
        "The local cleanup model is being unloaded."
    }
}

/// Owns the lifetime of every live `LLM` operation, so the model is never
/// released underneath one and no generation is ever cancelled.
///
/// ## Why this exists (ledger 27)
///
/// The original cleanup path raced generation against a sleep inside a task
/// group and called `group.cancelAll()` on timeout. That cancels the in-flight
/// llama.cpp generation, and a cancelled generation followed by deallocation
/// trips `GGML_ASSERT([rsets->data count] == 0)` in `ggml_metal_device_free`.
/// llama.cpp handles that with `ggml_abort`, which **kills the process**. It is
/// not a Swift error and cannot be caught, so the app simply disappears.
///
/// Observed intermittently on 2026-07-26: different fixtures aborted on
/// different runs and every one succeeded on retry, the signature of a teardown
/// race rather than an input the model cannot handle.
///
/// It stayed latent because a dictation is a few hundred characters and
/// finishes well inside the 15-second deadline. Meeting summarisation sends
/// 5,000-character chunks, which will routinely exceed it.
///
/// ## Scope: ALL live LLM work, not just cleanup
///
/// The first version of this fix tracked only the cleanup probe. Codex found
/// the hole on review: `streamCompletion` and `prefillPromptContext` also drive
/// `llm.core` directly, so termination could see "idle", release the backend,
/// and abort the process while an agent stream was running. Tracking one path
/// and calling the class fixed is this project's signature error, so the unit
/// here is a **use**, and every entry point that touches `llm.core` takes one.
///
/// ## The three invariants
///
/// 1. **A generation is never cancelled.** Work runs in a detached task, which
///    does not inherit cancellation from its caller. On timeout the caller gets
///    `CleanupGenerationDeadlineExceeded` while the work continues.
/// 2. **The model is never released while any use is live.** Teardown calls
///    `beginTeardown()`, which both waits for existing uses and refuses new
///    ones until `endTeardown()`.
/// 3. **Termination can answer synchronously.** `willTerminateNotification`
///    cannot await, so a lock-backed mirror of "any use live" is published
///    before any work can begin.
actor CleanupGenerationTracker {
    /// Mirror of "at least one use is live", readable without `await`.
    ///
    /// Published BEFORE the work starts. Codex round 2 finding 4: publishing it
    /// after spawning the task left a window where termination read "idle"
    /// while `operation()` had already entered llama.cpp.
    private let liveUseFlag = LiveUseFlag()

    /// Whether any LLM work is live, readable synchronously. Only for callers
    /// that genuinely cannot await, such as app termination.
    nonisolated var isGenerationInFlightSynchronously: Bool {
        liveUseFlag.value
    }

    private var activeUses = 0
    private var teardownDepth = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Whether any use is currently live.
    var hasGenerationInFlight: Bool {
        activeUses > 0
    }

    // MARK: - Uses

    /// Registers a live LLM operation.
    ///
    /// - Throws: `CleanupModelTeardownInProgress` if the model is being
    ///   released. Callers must not touch `llm.core` when this throws.
    func beginUse() throws {
        guard teardownDepth == 0 else {
            throw CleanupModelTeardownInProgress()
        }
        activeUses += 1
        liveUseFlag.value = true
    }

    /// Balances `beginUse()`. Safe to call more than once only if paired.
    func endUse() {
        guard activeUses > 0 else { return }
        activeUses -= 1
        if activeUses == 0 {
            liveUseFlag.value = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    // MARK: - Teardown

    /// Blocks new uses and waits for live ones to finish.
    ///
    /// Codex round 2 finding 2: waiting alone was not enough. After a timeout
    /// the cleanup path releases its execution gate, so a second caller can
    /// enter while the first is still draining. A teardown that only waited
    /// could return just as that second caller started, and then release the
    /// model underneath it. Refusing new uses is what closes that.
    ///
    /// Re-entrant: nested teardowns (unload inside shutdown) are counted.
    func beginTeardown() async {
        teardownDepth += 1
        while activeUses > 0 {
            await withCheckedContinuation { continuation in
                idleWaiters.append(continuation)
            }
        }
    }

    func endTeardown() {
        guard teardownDepth > 0 else { return }
        teardownDepth -= 1
    }

    /// Waits for live work to finish WITHOUT holding the barrier afterwards.
    /// Used by tests and by callers that only need to observe quiescence.
    func waitForInFlightGeneration() async {
        await beginTeardown()
        endTeardown()
    }

    // MARK: - Deadline-bounded generation

    /// Runs `operation` as a tracked use and waits up to `deadline` seconds.
    ///
    /// - Returns: the operation's value if it finished in time.
    /// - Throws: `CleanupGenerationDeadlineExceeded` if it did not, or
    ///   `CleanupModelTeardownInProgress` if the model is being released. The
    ///   operation is never cancelled once started.
    func run<T: Sendable>(
        deadline: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        let started = Date()

        // Do not start a second generation alongside a running one: both are
        // driven through a single `LLM` instance, and the cleanup path releases
        // its execution gate on timeout, so an overlap is genuinely reachable.
        //
        // The wait is bounded by the SAME deadline the caller asked for.
        // Serialising without a bound would let one stuck generation make the
        // next dictation wait far past 15 seconds, which is the latency the
        // deadline exists to cap.
        try await waitForIdle(within: deadline)

        let remaining = deadline - Date().timeIntervalSince(started)
        guard remaining > 0 else {
            throw CleanupGenerationDeadlineExceeded()
        }

        // Claim the use BEFORE spawning, so the synchronous flag is true before
        // any llama.cpp work can begin.
        try beginUse()

        let relay = GenerationRelay<T>()

        // Detached: does NOT inherit cancellation from whatever called us, so a
        // cancelled caller can never reach llama.cpp.
        Task.detached(priority: .userInitiated) { [weak self] in
            let value = await operation()
            await relay.deliver(value)
            await self?.endUse()
        }

        return try await relay.awaitValue(deadline: remaining)
    }

    /// Waits up to `seconds` for all uses to finish.
    ///
    /// Codex round 2 finding 3: an earlier version polled with
    /// `try? await Task.sleep`, which swallows cancellation. A cancelled waiter
    /// would then spin the actor at full speed until the deadline, starving the
    /// completion that needs actor time to decrement the count. This suspends
    /// on a continuation instead, so there is nothing to spin.
    private func waitForIdle(within seconds: TimeInterval) async throws {
        guard activeUses > 0 else { return }

        let expiry = Date().addingTimeInterval(seconds)
        while activeUses > 0 {
            guard Date() < expiry else {
                throw CleanupGenerationDeadlineExceeded()
            }

            do {
                // Each suspension releases the actor, so `endUse()` can run.
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                // The WAITER was cancelled. Stop waiting immediately rather
                // than looping, which is what would spin the actor and starve
                // the very completion we are waiting on. The generation itself
                // is detached and is never touched by this.
                throw CleanupGenerationDeadlineExceeded()
            }
        }
    }
}

/// Hands a generation's value to whoever is waiting, or drops it if the wait
/// already timed out. Guarantees the continuation resumes exactly once.
private actor GenerationRelay<T: Sendable> {
    private enum State {
        case pending
        case waiting(CheckedContinuation<T, Error>)
        case delivered(T)
        case abandoned
    }

    private var state: State = .pending

    func deliver(_ value: T) {
        switch state {
        case .waiting(let continuation):
            state = .delivered(value)
            continuation.resume(returning: value)
        case .pending:
            state = .delivered(value)
        case .delivered, .abandoned:
            break
        }
    }

    func awaitValue(deadline: TimeInterval) async throws -> T {
        if case .delivered(let value) = state {
            return value
        }

        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            await self?.abandon()
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ continuation: CheckedContinuation<T, Error>) {
        switch state {
        case .delivered(let value):
            continuation.resume(returning: value)
        case .abandoned:
            continuation.resume(throwing: CleanupGenerationDeadlineExceeded())
        case .pending:
            state = .waiting(continuation)
        case .waiting:
            // Only one caller ever waits on a relay.
            continuation.resume(throwing: CleanupGenerationDeadlineExceeded())
        }
    }

    private func abandon() {
        switch state {
        case .waiting(let continuation):
            state = .abandoned
            continuation.resume(throwing: CleanupGenerationDeadlineExceeded())
        case .pending:
            state = .abandoned
        case .delivered, .abandoned:
            break
        }
    }
}

/// A lock-guarded boolean the actor publishes for synchronous readers.
private final class LiveUseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A lock-guarded stop signal for stream consumers.
///
/// Ledger 27: a consumer that stops reading must not cancel the generation.
/// Cancelling an in-flight llama.cpp run is the abort trigger. The generation
/// finishes; its tokens are simply no longer forwarded.
final class StreamStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
