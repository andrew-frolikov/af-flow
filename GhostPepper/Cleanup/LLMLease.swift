import Foundation

/// Thrown when a caller waits past its deadline for the model.
///
/// Deliberately NOT `CancellationError`. The distinction is the point of this
/// file: the caller has stopped waiting, and nothing has been cancelled.
struct CleanupGenerationDeadlineExceeded: Error, LocalizedError {
    var errorDescription: String? {
        "Local cleanup took longer than expected."
    }
}

/// Thrown when the model is requested while it is being released.
struct CleanupModelTeardownInProgress: Error, LocalizedError {
    var errorDescription: String? {
        "The local cleanup model is being unloaded."
    }
}

/// Exclusive access to the single `LLM` instance, and the sole thing that
/// decides when it is safe to release.
///
/// ## Why this replaced two mechanisms with one (ledger 27)
///
/// The original bug: cleanup raced generation against a sleep inside a task
/// group and called `group.cancelAll()` on timeout. Cancelling an in-flight
/// llama.cpp generation trips `GGML_ASSERT` in `ggml_metal_device_free`, and
/// llama.cpp answers with `ggml_abort`, which **kills the process**. Not a Swift
/// error, not catchable: the app disappears.
///
/// The first fix added a generation tracker beside the existing
/// `CleanupProbeExecutionGate`. Three Codex rounds each found real new defects,
/// and by round 3 all of them lived in the same place: **two mechanisms both
/// claimed to serialise one `LLM`, and every remaining bug was in the gap
/// between them.** The gate was released when a caller gave up; the tracker
/// thought work was still live; neither owned the decision. Patching the seam
/// produced a fresh crop each round, so Andrew chose to collapse them.
///
/// ## The design, and why each part is load-bearing
///
/// **The lease is released by the WORK, not by the caller.** This is the whole
/// fix. When a cleanup exceeds its deadline the caller walks away, but the lease
/// stays held until the generation genuinely finishes. A second caller therefore
/// cannot start on a model the first is still using, and teardown cannot release
/// a model that is still in use, without either of them coordinating.
///
/// **A deadline bounds waiting, never work.** Work runs detached, so it cannot
/// inherit cancellation from a caller who gave up. No cancellation signal can
/// reach llama.cpp by any path.
///
/// **Teardown is a barrier, not a wait.** `beginTeardown()` refuses new
/// acquisitions as well as waiting for the current holder, and the caller holds
/// it across the entire release, including `LLM.shutdownBackend()`.
///
/// **Termination gets a synchronous answer.** `willTerminateNotification`
/// arrives while the process is already going away and cannot await, so a
/// lock-backed mirror of "held" is published before any work can begin.
actor LLMLease {
    /// Proof that the holder acquired the lease. Only the holder can release it,
    /// so a stale release cannot free someone else's lease.
    struct Ticket: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    private let heldFlag = HeldFlag()

    /// Whether the model is in use, readable without `await`. Only for callers
    /// that genuinely cannot await, such as app termination.
    nonisolated var isHeldSynchronously: Bool {
        heldFlag.value
    }

    private var holder: Ticket?
    private var nextTicketID: UInt64 = 1
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var teardownDepth = 0

    /// Whether the model is currently in use.
    var isHeld: Bool { holder != nil }

    // MARK: - Acquiring

    /// Takes exclusive use of the model, waiting up to `deadline` seconds.
    ///
    /// - Throws: `CleanupModelTeardownInProgress` if the model is being
    ///   released, or `CleanupGenerationDeadlineExceeded` if the wait expires.
    ///   Callers must not touch `llm.core` when this throws.
    func acquire(within deadline: TimeInterval) async throws -> Ticket {
        let expiry = Date().addingTimeInterval(deadline)

        while true {
            guard teardownDepth == 0 else {
                throw CleanupModelTeardownInProgress()
            }
            if holder == nil {
                return claim()
            }
            guard Date() < expiry else {
                throw CleanupGenerationDeadlineExceeded()
            }
            try await waitTick()
        }
    }

    /// Takes exclusive use of the model, waiting as long as necessary.
    ///
    /// For work with no latency budget of its own, such as prefill. Callers on
    /// the dictation path should use `acquire(within:)` so a stuck generation
    /// cannot make the next dictation wait indefinitely.
    func acquire() async throws -> Ticket {
        while true {
            guard teardownDepth == 0 else {
                throw CleanupModelTeardownInProgress()
            }
            if holder == nil {
                return claim()
            }
            try await waitTick()
        }
    }

    /// Releases the lease. Ignored unless `ticket` is the current holder, so a
    /// late or duplicated release cannot free work that is still running.
    func release(_ ticket: Ticket) {
        guard holder == ticket else { return }
        holder = nil
        heldFlag.value = false

        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func claim() -> Ticket {
        let ticket = Ticket(id: nextTicketID)
        nextTicketID += 1
        holder = ticket
        heldFlag.value = true
        return ticket
    }

    /// Suspends briefly so the holder can make progress and release.
    ///
    /// Cancellation of the WAITER ends the wait and never reaches the work,
    /// which is detached. Exiting rather than looping is deliberate: a cancelled
    /// task's `Task.sleep` throws immediately, so continuing to loop would spin
    /// the actor and starve the very release being waited on.
    private func waitTick() async throws {
        do {
            try await Task.sleep(nanoseconds: 10_000_000)
        } catch {
            throw CleanupGenerationDeadlineExceeded()
        }
    }

    // MARK: - Teardown

    /// Blocks new acquisitions and waits for the current holder to finish.
    ///
    /// The caller must hold this across the ENTIRE release, including
    /// `LLM.shutdownBackend()`, and balance it with `endTeardown()`. Releasing
    /// the barrier before the backend is torn down reopens the window this
    /// exists to close.
    ///
    /// Re-entrant, so an unload nested inside a shutdown is counted rather than
    /// deadlocking.
    func beginTeardown() async {
        teardownDepth += 1
        while holder != nil {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
    }

    func endTeardown() {
        guard teardownDepth > 0 else { return }
        teardownDepth -= 1
    }

    /// Waits for the model to fall idle without holding the barrier afterwards.
    /// For observers; teardown must use `beginTeardown()`.
    func waitUntilIdle() async {
        await beginTeardown()
        endTeardown()
    }

    // MARK: - Deadline-bounded work

    /// Runs `operation` under the lease and waits up to `deadline` for its
    /// value.
    ///
    /// The lease is released when `operation` actually finishes, not when this
    /// call returns. So a caller that gives up leaves the model correctly marked
    /// in use, and nothing else can touch or release it until the work is done.
    ///
    /// - Throws: `CleanupGenerationDeadlineExceeded` if the value does not
    ///   arrive in time, or `CleanupModelTeardownInProgress` if the model is
    ///   being released. The operation is never cancelled once started.
    func run<T: Sendable>(
        deadline: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        let started = Date()
        let ticket = try await acquire(within: deadline)
        let remaining = deadline - Date().timeIntervalSince(started)
        return try await run(holding: ticket, deadline: remaining, operation: operation)
    }

    /// Runs `operation` under a lease the caller ALREADY holds, and takes over
    /// releasing it.
    ///
    /// This exists because the lease is not re-entrant. A caller that acquires
    /// the lease so it can safely look up the model must not then call
    /// `run(deadline:)`, which would try to acquire it a second time and wait
    /// out the whole deadline against itself. Codex found exactly that
    /// self-deadlock in `probe()`: every real cleanup would have failed without
    /// ever reaching the model.
    ///
    /// Ownership of `ticket` transfers here. The caller must not release it.
    func run<T: Sendable>(
        holding ticket: Ticket,
        deadline: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        // A ticket that no longer owns the lease must not start work. Without
        // this, a stale ticket runs its operation alongside the real holder on
        // the same `LLM`, and only its release is ignored, which is far too
        // late. The `release(_:)` guard alone does not cover this.
        guard holder == ticket else {
            throw CleanupModelTeardownInProgress()
        }

        guard deadline > 0 else {
            release(ticket)
            throw CleanupGenerationDeadlineExceeded()
        }

        let remaining = deadline
        let relay = GenerationRelay<T>()

        // Detached: does NOT inherit cancellation from whatever called us, so a
        // cancelled or abandoned caller can never reach llama.cpp.
        Task.detached(priority: .userInitiated) { [weak self] in
            let value = await operation()
            await relay.deliver(value)
            await self?.release(ticket)
        }

        return try await relay.awaitValue(deadline: remaining)
    }
}

/// Hands a value to whoever is waiting, or drops it if the wait already timed
/// out. Guarantees the continuation resumes exactly once.
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

/// A lock-guarded mirror of "the lease is held", for synchronous readers.
private final class HeldFlag: @unchecked Sendable {
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
