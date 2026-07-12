import AppKit
import Foundation

struct WorkspaceCodexProcessChecker: CodexProcessAvailabilityChecking {
    private static let knownBundleIdentifiers: Set<String> = [
        "com.openai.codex",
    ]

    func isCodexAvailable() async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { application in
                if let identifier = application.bundleIdentifier,
                   Self.knownBundleIdentifiers.contains(identifier.lowercased()) {
                    return true
                }
                return application.localizedName?.lowercased() == "codex"
            }
        }
    }
}

private struct PendingTaskObservationSignal {
    let sortDate: Date
    let offset: UInt64
    let signal: CodexTaskObservationSignal
}

actor CodexTaskObserver {
    typealias SnapshotStream = AsyncStream<CodexTaskObservationSnapshot>

    private let configuration: CodexTaskObserverConfiguration
    private let candidateIndex: SQLiteTaskCandidateIndex
    private let lifecycleScanner: JSONLTaskLifecycleScanner
    private let processChecker: any CodexProcessAvailabilityChecking
    private let now: @Sendable () -> Date

    private var continuations: [UUID: SnapshotStream.Continuation] = [:]
    private var lastSnapshot: CodexTaskObservationSnapshot?
    private var watcher: SessionsFSEventsWatcher?
    private var debounceTask: Task<Void, Never>?
    private var isStarted = false
    private var watcherStartupFailed = false
    private var refreshGeneration: UInt64 = 0
    private var seenTerminalErrorOffsets: [String: UInt64] = [:]
    private var seenResetActivityOffsets: [String: UInt64] = [:]
    private var hasCompletedInitialScan = false

    init(
        configuration: CodexTaskObserverConfiguration = .live,
        processChecker: any CodexProcessAvailabilityChecking = WorkspaceCodexProcessChecker(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.candidateIndex = SQLiteTaskCandidateIndex(databaseURL: configuration.databaseURL)
        self.lifecycleScanner = JSONLTaskLifecycleScanner()
        self.processChecker = processChecker
        self.now = now
    }

    func updates() -> SnapshotStream {
        let id = UUID()
        return SnapshotStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            if let lastSnapshot {
                continuation.yield(lastSnapshot)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        do {
            watcher = try SessionsFSEventsWatcher(
                directoryURL: configuration.sessionsURL,
                latency: 0.01
            ) { [weak self] in
                Task { await self?.sessionsDidChange() }
            }
            watcherStartupFailed = false
        } catch {
            watcher = nil
            watcherStartupFailed = true
        }

        await refresh()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        refreshGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        watcher?.stop()
        watcher = nil
        watcherStartupFailed = false
        seenTerminalErrorOffsets.removeAll()
        seenResetActivityOffsets.removeAll()
        hasCompletedInitialScan = false
    }

    func refresh() async {
        let capturedAt = now()
        guard await processChecker.isCodexAvailable() else {
            publish(.unavailable(.disconnected, at: capturedAt))
            return
        }
        guard !isStarted || !watcherStartupFailed else {
            publish(.unavailable(.disconnected, at: capturedAt))
            return
        }

        let candidates: [TaskCandidate]
        do {
            candidates = try candidateIndex.recentCandidates(limit: configuration.candidateLimit)
        } catch TaskCandidateIndexError.incompatibleSchema {
            publish(.unavailable(.incompatible, at: capturedAt))
            return
        } catch {
            publish(.unavailable(.disconnected, at: capturedAt))
            return
        }

        var remainingByteBudget = configuration.totalByteLimit
        var tasks: [CodexObservedTask] = []
        var allowedCandidateCount = 0
        var existingFileCount = 0
        var compatibleEnvelopeCount = 0
        var pendingSignals: [PendingTaskObservationSignal] = []

        for candidate in candidates where remainingByteBudget > 0 {
            guard isAllowedRolloutURL(candidate.rolloutURL) else {
                continue
            }
            allowedCandidateCount += 1

            let fileLimit = min(configuration.perFileByteLimit, remainingByteBudget)
            do {
                let result = try lifecycleScanner.scan(fileURL: candidate.rolloutURL, byteLimit: fileLimit)
                existingFileCount += 1
                remainingByteBudget -= result.bytesRead
                compatibleEnvelopeCount += result.recognizedEnvelopeCount

                if let offset = result.latestTerminalErrorOffset {
                    let previousOffset = seenTerminalErrorOffsets[candidate.id]
                    seenTerminalErrorOffsets[candidate.id] = offset
                    let supersededByResetActivity = result.latestResetActivityOffset
                        .map { $0 > offset } ?? false
                    if previousOffset != offset,
                       !supersededByResetActivity,
                       isRecentTerminalError(candidate, capturedAt: capturedAt) {
                        pendingSignals.append(
                            PendingTaskObservationSignal(
                                sortDate: candidate.updatedAt ?? capturedAt,
                                offset: offset,
                                signal: .terminalError(taskID: candidate.id)
                            )
                        )
                    }
                }

                if let offset = result.latestResetActivityOffset {
                    let previousOffset = seenResetActivityOffsets[candidate.id]
                    seenResetActivityOffsets[candidate.id] = offset
                    if hasCompletedInitialScan, previousOffset != offset {
                        pendingSignals.append(
                            PendingTaskObservationSignal(
                                sortDate: candidate.updatedAt ?? capturedAt,
                                offset: offset,
                                signal: .lifecycleActivity(taskID: candidate.id)
                            )
                        )
                    }
                }

                guard let state = result.activeState else { continue }
                tasks.append(
                    CodexObservedTask(
                        id: candidate.id,
                        title: candidate.title,
                        runState: map(state),
                        updatedAt: candidate.updatedAt
                    )
                )
            } catch {
                // Missing, rotating and temporarily unreadable rollout files are skipped.
                // We deliberately do not include paths or file contents in diagnostics.
                continue
            }
        }

        if !candidates.isEmpty, allowedCandidateCount == 0 {
            publish(.unavailable(.incompatible, at: capturedAt))
            return
        }
        if allowedCandidateCount > 0, existingFileCount == 0 {
            publish(.unavailable(.disconnected, at: capturedAt))
            return
        }
        if !candidates.isEmpty, existingFileCount > 0, compatibleEnvelopeCount == 0 {
            publish(.unavailable(.incompatible, at: capturedAt))
            return
        }

        tasks.sort {
            switch ($0.updatedAt, $1.updatedAt) {
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                return lhs > rhs
            default:
                return $0.id > $1.id
            }
        }

        let candidateIDs = Set(candidates.map(\.id))
        seenTerminalErrorOffsets = seenTerminalErrorOffsets.filter { candidateIDs.contains($0.key) }
        seenResetActivityOffsets = seenResetActivityOffsets.filter { candidateIDs.contains($0.key) }
        pendingSignals.sort {
            if $0.sortDate != $1.sortDate {
                return $0.sortDate < $1.sortDate
            }
            return $0.offset < $1.offset
        }
        hasCompletedInitialScan = true
        publish(
            CodexTaskObservationSnapshot(
                tasks: tasks,
                health: .connected,
                capturedAt: capturedAt,
                signals: pendingSignals.map(\.signal)
            )
        )
    }

    private func sessionsDidChange() {
        guard isStarted else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        debounceTask?.cancel()

        let delay = configuration.fseventsCoalescingNanoseconds
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self else { return }
            await self.refreshAfterDebounce(generation: generation)
        }
    }

    private func refreshAfterDebounce(generation: UInt64) async {
        guard isStarted, generation == refreshGeneration else { return }
        await refresh()
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func publish(_ snapshot: CodexTaskObservationSnapshot) {
        lastSnapshot = CodexTaskObservationSnapshot(
            tasks: snapshot.tasks,
            health: snapshot.health,
            capturedAt: snapshot.capturedAt
        )
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func isAllowedRolloutURL(_ rolloutURL: URL) -> Bool {
        let sessionsPath = configuration.sessionsURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let rolloutPath = rolloutURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let directoryPrefix = sessionsPath.hasSuffix("/") ? sessionsPath : sessionsPath + "/"
        return rolloutPath.hasPrefix(directoryPrefix)
    }

    private func map(_ state: TaskLifecycleState) -> CodexObservedTaskRunState {
        switch state {
        case .running: .running
        case .waitingForUser: .waitingForUser
        case .error: .error
        case .unknown: .unknown
        }
    }

    private func isRecentTerminalError(_ candidate: TaskCandidate, capturedAt: Date) -> Bool {
        guard let updatedAt = candidate.updatedAt else { return true }
        let age = capturedAt.timeIntervalSince(updatedAt)
        return age >= -5 && age <= 30
    }
}
