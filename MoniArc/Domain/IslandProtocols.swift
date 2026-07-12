import Foundation

public enum QuotaSourceEvent: Equatable, Sendable {
    case snapshot(QuotaSnapshot)
    case healthChanged(SourceHealth)
}

public enum TaskSourceEvent: Equatable, Sendable {
    case snapshot([TaskSummary])
    case healthChanged(SourceHealth)
    case terminalError(taskID: String?)
    case lifecycleActivity(taskID: String?)
}

public protocol QuotaSource: Sendable {
    func events() async -> AsyncStream<QuotaSourceEvent>
    func start() async
    func stop() async
    func refresh() async
}

public protocol TaskSource: Sendable {
    func events() async -> AsyncStream<TaskSourceEvent>
    func start() async
    func stop() async
}

@MainActor
public protocol PanelDriver: AnyObject, Sendable {
    /// Returns only after the requested animation (if any) has completed.
    func apply(_ transition: PanelTransition) async
}

public protocol ScreenProvider: Sendable {
    func layouts() async -> AsyncStream<PanelLayoutSnapshot?>
    func refresh(for preference: PlacementPreference) async
}

public protocol PointerSensor: Sendable {
    func hoverEvents() async -> AsyncStream<Bool>
    func start() async
    func stop() async
}
