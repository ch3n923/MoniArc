import Combine
import Foundation

public struct IslandDependencies: Sendable {
    public var clock: any IslandClock
    public var wallClock: any WallClockProvider
    public var quotaSource: (any QuotaSource)?
    public var taskSource: (any TaskSource)?
    public var panelDriver: (any PanelDriver)?
    public var screenProvider: (any ScreenProvider)?
    public var pointerSensor: (any PointerSensor)?

    public init(
        clock: any IslandClock = SystemMonotonicClock(),
        wallClock: any WallClockProvider = SystemWallClock(),
        quotaSource: (any QuotaSource)? = nil,
        taskSource: (any TaskSource)? = nil,
        panelDriver: (any PanelDriver)? = nil,
        screenProvider: (any ScreenProvider)? = nil,
        pointerSensor: (any PointerSensor)? = nil
    ) {
        self.clock = clock
        self.wallClock = wallClock
        self.quotaSource = quotaSource
        self.taskSource = taskSource
        self.panelDriver = panelDriver
        self.screenProvider = screenProvider
        self.pointerSensor = pointerSensor
    }
}

@MainActor
public final class IslandStore: ObservableObject {
    @Published public private(set) var state: IslandState

    private var reducer: IslandReducer
    private let dependencies: IslandDependencies
    private var timers: [IslandTimer: Task<Void, Never>] = [:]
    private var observationTasks: [Task<Void, Never>] = []

    public init(
        initialState: IslandState = .init(),
        reducer: IslandReducer = .init(),
        dependencies: IslandDependencies = .init()
    ) {
        state = initialState
        self.reducer = reducer
        self.dependencies = dependencies
    }

    deinit {
        timers.values.forEach { $0.cancel() }
        observationTasks.forEach { $0.cancel() }
    }

    public func start() {
        send(.start)
    }

    public func stop() {
        send(.stop)
    }

    public func send(_ action: IslandAction) {
        let now = dependencies.clock.now()
        let effects = reducer.reduce(state: &state, action: action, now: now)
        effects.forEach(handle)
    }

    private func handle(_ effect: IslandEffect) {
        switch effect {
        case let .scheduleTimer(timer, token, delay):
            timers[timer]?.cancel()
            let clock = dependencies.clock
            let deadline = clock.now().advanced(by: delay)
            timers[timer] = Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.timerFired(timer, token: token)
            }

        case let .cancelTimer(timer):
            timers.removeValue(forKey: timer)?.cancel()

        case .startSources:
            startObservations()

        case .stopSources:
            stopObservations()

        case .refreshQuota:
            guard let quotaSource = dependencies.quotaSource else { return }
            Task { await quotaSource.refresh() }

        case let .requestPanelLayout(preference):
            guard let screenProvider = dependencies.screenProvider else { return }
            Task { await screenProvider.refresh(for: preference) }

        case let .submitPanel(transition):
            guard let panelDriver = dependencies.panelDriver else {
                send(.panelTransitionCompleted(transition.revision))
                return
            }
            Task { [weak self] in
                await panelDriver.apply(transition)
                guard !Task.isCancelled else { return }
                self?.send(.panelTransitionCompleted(transition.revision))
            }
        }
    }

    private func timerFired(_ timer: IslandTimer, token: GenerationToken) {
        timers.removeValue(forKey: timer)
        switch timer {
        case .quotaRotation:
            send(.quotaRotationTimerFired(token))
        case .hoverExpansion:
            send(.hoverExpansionTimerFired(token))
        case .hoverCollapse:
            send(.hoverCollapseTimerFired(token))
        case .terminalError:
            send(.terminalErrorTimerFired(token))
        }
    }

    private func startObservations() {
        guard observationTasks.isEmpty else { return }

        if let quotaSource = dependencies.quotaSource {
            observationTasks.append(Task { [weak self] in
                let stream = await quotaSource.events()
                await quotaSource.start()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self?.send(.quotaSourceEvent(event))
                }
            })
        }

        if let taskSource = dependencies.taskSource {
            observationTasks.append(Task { [weak self] in
                let stream = await taskSource.events()
                await taskSource.start()
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self?.send(.taskSourceEvent(event))
                }
            })
        }

        if let screenProvider = dependencies.screenProvider {
            observationTasks.append(Task { [weak self] in
                let stream = await screenProvider.layouts()
                for await layout in stream {
                    guard !Task.isCancelled else { break }
                    self?.send(.panelLayoutUpdated(layout))
                }
            })
        }

        if let pointerSensor = dependencies.pointerSensor {
            observationTasks.append(Task { [weak self] in
                let stream = await pointerSensor.hoverEvents()
                await pointerSensor.start()
                for await isInside in stream {
                    guard !Task.isCancelled else { break }
                    self?.send(.hoverChanged(isInside))
                }
            })
        }
    }

    private func stopObservations() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()

        if let quotaSource = dependencies.quotaSource {
            Task { await quotaSource.stop() }
        }
        if let taskSource = dependencies.taskSource {
            Task { await taskSource.stop() }
        }
        if let pointerSensor = dependencies.pointerSensor {
            Task { await pointerSensor.stop() }
        }
    }
}
