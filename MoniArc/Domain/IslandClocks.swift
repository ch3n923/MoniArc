import Foundation

public protocol IslandClock: Sendable {
    func now() -> MonotonicInstant
    func sleep(until deadline: MonotonicInstant) async throws
}

public protocol WallClockProvider: Sendable {
    func now() -> Date
}

public struct SystemMonotonicClock: IslandClock {
    public init() {}

    public func now() -> MonotonicInstant {
        let ticks = DispatchTime.now().uptimeNanoseconds
        return MonotonicInstant(nanoseconds: ticks > UInt64(Int64.max) ? .max : Int64(ticks))
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        let remaining = now().duration(to: deadline)
        guard remaining > .zero else { return }
        try await Task.sleep(for: remaining)
    }
}

public struct SystemWallClock: WallClockProvider {
    public init() {}

    public func now() -> Date { Date() }
}

/// A deterministic monotonic clock. Advancing it resumes every waiter whose
/// deadline is reached; no wall-clock sleeps are involved.
public final class ManualMonotonicClock: IslandClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: MonotonicInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant: MonotonicInstant
    private var waiters: [UUID: Waiter] = [:]

    public init(now: MonotonicInstant = .zero) {
        instant = now
    }

    public func now() -> MonotonicInstant {
        withLock { instant }
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResumeImmediately = withLock { () -> Bool in
                    if Task.isCancelled || deadline <= instant {
                        return true
                    }
                    waiters[identifier] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }

                if shouldResumeImmediately {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(identifier)
        }
    }

    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualMonotonicClock cannot move backwards")
        advance(to: now().advanced(by: duration))
    }

    public func advance(to newInstant: MonotonicInstant) {
        let due: [Waiter] = withLock {
            precondition(newInstant >= instant, "ManualMonotonicClock cannot move backwards")
            instant = newInstant
            let dueIDs = waiters.compactMap { key, value in
                value.deadline <= newInstant ? key : nil
            }
            let due = dueIDs.compactMap { waiters.removeValue(forKey: $0) }
            return due.sorted { $0.deadline < $1.deadline }
        }
        due.forEach { $0.continuation.resume() }
    }

    public var pendingSleepCount: Int {
        withLock { waiters.count }
    }

    private func cancelWaiter(_ identifier: UUID) {
        let waiter = withLock { waiters.removeValue(forKey: identifier) }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class FakeWallClock: WallClockProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    public init(now: Date) {
        date = now
    }

    public func now() -> Date {
        withLock { date }
    }

    public func set(_ newDate: Date) {
        withLock { date = newDate }
    }

    public func advance(by interval: TimeInterval) {
        withLock { date = date.addingTimeInterval(interval) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
