import Foundation

/// Domain adapter for the privacy-safe, read-only local task observer.
actor CodexTaskSource: TaskSource {
    typealias EventStream = AsyncStream<TaskSourceEvent>

    private let observer: CodexTaskObserver
    private var continuations: [UUID: EventStream.Continuation] = [:]
    private var observationTask: Task<Void, Never>?
    private var previousSnapshot: CodexTaskObservationSnapshot?
    private var isStarted = false

    init(observer: CodexTaskObserver = CodexTaskObserver()) {
        self.observer = observer
    }

    func events() -> EventStream {
        let id = UUID()
        return EventStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true

        let updates = await observer.updates()
        observationTask = Task { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await self?.consume(snapshot)
            }
        }
        await observer.start()
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        observationTask?.cancel()
        observationTask = nil
        await observer.stop()
        previousSnapshot = nil
    }

    private func consume(_ snapshot: CodexTaskObservationSnapshot) {
        if previousSnapshot?.health != snapshot.health {
            yield(.healthChanged(map(snapshot.health)))
        }

        for signal in snapshot.signals {
            switch signal {
            case let .terminalError(taskID, taskUpdatedAt, lightingProfile):
                yield(.terminalError(
                    taskID: taskID,
                    taskUpdatedAt: taskUpdatedAt,
                    lightingProfile: lightingProfile
                ))
            case let .lifecycleActivity(taskID):
                yield(.lifecycleActivity(taskID: taskID))
            }
        }

        let summaries = snapshot.tasks.map { task in
            TaskSummary(
                id: task.id,
                title: task.title,
                runState: map(task.runState),
                updatedAt: task.updatedAt,
                lightingProfile: task.lightingProfile
            )
        }
        yield(.snapshot(summaries))
        previousSnapshot = snapshot
    }

    private func yield(_ event: TaskSourceEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func map(_ health: CodexTaskObservationHealth) -> SourceHealth {
        switch health {
        case .connected: .connected
        case .disconnected: .disconnected
        case .incompatible: .incompatible
        }
    }

    private func map(_ state: CodexObservedTaskRunState) -> TaskRunState {
        switch state {
        case .running: .running
        case .waitingForUser: .waitingForUser
        case .error: .error
        case .unknown: .unknown
        }
    }
}
