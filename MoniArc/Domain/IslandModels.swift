import Foundation

public enum PlacementPreference: String, CaseIterable, Codable, Sendable {
    case automatic
    case overlay
    case floating
}

public enum PanelPlacement: String, Codable, Sendable {
    case overlay
    case floating
}

public enum PanelPhase: String, Codable, Sendable {
    case collapsed
    case expandPending
    case expanded
    case collapsePending
}

public enum QuotaKind: String, CaseIterable, Codable, Sendable {
    case fiveHour
    case weekly
}

public enum TaskRunState: String, Codable, Sendable {
    case running
    case waitingForUser
    case error
    case unknown
}

public enum SourceHealth: String, Codable, Sendable {
    case connected
    case stale
    case disconnected
    case failed
    case incompatible
}

public enum IslandVisualStatus: String, Codable, Sendable {
    case disconnected
    case error
    case waitingForUser
    case running
    case idle
}

public enum QuotaPauseReason: String, CaseIterable, Codable, Sendable {
    case panelInteraction
    case screenUnavailable
    case appSuspended
    case windowRehosting
}

public struct GenerationToken: Hashable, Comparable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PanelRevision: Hashable, Comparable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A process-local, monotonic timestamp expressed in nanoseconds.
/// It intentionally has no relationship to wall-clock time.
public struct MonotonicInstant: Hashable, Comparable, Codable, Sendable {
    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static let zero = Self(nanoseconds: 0)

    public func advanced(by duration: Duration) -> Self {
        let delta = duration.nanosecondsClamped
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        if overflow {
            return Self(nanoseconds: delta >= 0 ? .max : .min)
        }
        return Self(nanoseconds: sum)
    }

    public func duration(to other: Self) -> Duration {
        let (delta, overflow) = other.nanoseconds.subtractingReportingOverflow(nanoseconds)
        return .nanoseconds(overflow ? (other > self ? Int64.max : Int64.min) : delta)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

public extension Duration {
    var nanosecondsClamped: Int64 {
        let parts = components
        let (whole, secondsOverflow) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let fractional = parts.attoseconds / 1_000_000_000
        let (result, additionOverflow) = whole.addingReportingOverflow(fractional)
        if secondsOverflow || additionOverflow {
            return parts.seconds >= 0 ? .max : .min
        }
        return result
    }
}

public struct QuotaWindow: Equatable, Sendable {
    public var kind: QuotaKind
    public var remainingPercent: Double
    public var resetsAt: Date?
    public var isStale: Bool

    public init(
        kind: QuotaKind,
        remainingPercent: Double,
        resetsAt: Date?,
        isStale: Bool = false
    ) {
        self.kind = kind
        self.remainingPercent = min(max(remainingPercent, 0), 100)
        self.resetsAt = resetsAt
        self.isStale = isStale
    }
}

public struct QuotaBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String?
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?

    public init(
        id: String,
        displayName: String?,
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?
    ) {
        self.id = id
        self.displayName = displayName
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    public subscript(kind: QuotaKind) -> QuotaWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        }
    }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public var fiveHour: QuotaWindow?
    public var weekly: QuotaWindow?
    public var additionalBuckets: [QuotaBucket]
    public var receivedAt: Date

    public init(
        fiveHour: QuotaWindow?,
        weekly: QuotaWindow?,
        additionalBuckets: [QuotaBucket] = [],
        receivedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.additionalBuckets = additionalBuckets
        self.receivedAt = receivedAt
    }

    public subscript(kind: QuotaKind) -> QuotaWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        }
    }
}

public struct TaskSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var runState: TaskRunState
    public var updatedAt: Date?

    public init(id: String, title: String, runState: TaskRunState, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.runState = runState
        self.updatedAt = updatedAt
    }
}

/// CoreGraphics is deliberately kept out of the domain so geometry remains
/// deterministic and usable by the Debug harness without an AppKit process.
public struct PanelFrame: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PanelLayoutSnapshot: Equatable, Sendable {
    public var placement: PanelPlacement
    public var collapsedFrame: PanelFrame
    public var expandedFrame: PanelFrame
    public var notchFrame: PanelFrame?

    public init(
        placement: PanelPlacement,
        collapsedFrame: PanelFrame,
        expandedFrame: PanelFrame,
        notchFrame: PanelFrame? = nil
    ) {
        self.placement = placement
        self.collapsedFrame = collapsedFrame
        self.expandedFrame = expandedFrame
        self.notchFrame = notchFrame
    }
}

public enum PanelAnimationCurve: String, Codable, Sendable {
    case easeIn
    case easeOut
}

public struct PanelTransition: Equatable, Sendable {
    public var revision: PanelRevision
    public var frame: PanelFrame
    public var animated: Bool
    public var duration: Duration
    public var curve: PanelAnimationCurve

    public init(
        revision: PanelRevision,
        frame: PanelFrame,
        animated: Bool,
        duration: Duration,
        curve: PanelAnimationCurve
    ) {
        self.revision = revision
        self.frame = frame
        self.animated = animated
        self.duration = duration
        self.curve = curve
    }
}

public struct TerminalErrorLatch: Equatable, Sendable {
    public var taskID: String?
    public var expiresAt: MonotonicInstant
    public var generation: GenerationToken

    public init(taskID: String?, expiresAt: MonotonicInstant, generation: GenerationToken) {
        self.taskID = taskID
        self.expiresAt = expiresAt
        self.generation = generation
    }
}

public struct QuotaRotationState: Equatable, Sendable {
    public var visibleKind: QuotaKind
    public var remaining: Duration
    public var runningSince: MonotonicInstant?
    public var generation: GenerationToken

    public init(
        visibleKind: QuotaKind = .fiveHour,
        remaining: Duration = .seconds(60),
        runningSince: MonotonicInstant? = nil,
        generation: GenerationToken = .init()
    ) {
        self.visibleKind = visibleKind
        self.remaining = remaining
        self.runningSince = runningSince
        self.generation = generation
    }
}

public struct IslandState: Equatable, Sendable {
    public var placementPreference: PlacementPreference
    public var resolvedPlacement: PanelPlacement
    public var panelPhase: PanelPhase
    public var panelLayout: PanelLayoutSnapshot?
    public var panelRevision: PanelRevision
    public var isPointerInside: Bool
    public var isAwaitingRehostLayout: Bool

    public var quotaRotation: QuotaRotationState
    public var quotaPauseReasons: Set<QuotaPauseReason>
    public var quotaSnapshot: QuotaSnapshot?
    public var quotaSourceHealth: SourceHealth

    public var tasks: [TaskSummary]
    public var selectedTaskID: String?
    public var taskSourceHealth: SourceHealth
    public var terminalErrorLatch: TerminalErrorLatch?

    public var interactionGeneration: GenerationToken
    public var pendingPanelDeadline: MonotonicInstant?
    public var terminalErrorGeneration: GenerationToken
    public var isStarted: Bool

    public init(
        placementPreference: PlacementPreference = .automatic,
        resolvedPlacement: PanelPlacement = .floating,
        panelPhase: PanelPhase = .collapsed,
        panelLayout: PanelLayoutSnapshot? = nil,
        panelRevision: PanelRevision = .init(),
        isPointerInside: Bool = false,
        isAwaitingRehostLayout: Bool = false,
        quotaRotation: QuotaRotationState = .init(),
        quotaPauseReasons: Set<QuotaPauseReason> = [],
        quotaSnapshot: QuotaSnapshot? = nil,
        quotaSourceHealth: SourceHealth = .disconnected,
        tasks: [TaskSummary] = [],
        selectedTaskID: String? = nil,
        taskSourceHealth: SourceHealth = .disconnected,
        terminalErrorLatch: TerminalErrorLatch? = nil,
        interactionGeneration: GenerationToken = .init(),
        pendingPanelDeadline: MonotonicInstant? = nil,
        terminalErrorGeneration: GenerationToken = .init(),
        isStarted: Bool = false
    ) {
        self.placementPreference = placementPreference
        self.resolvedPlacement = resolvedPlacement
        self.panelPhase = panelPhase
        self.panelLayout = panelLayout
        self.panelRevision = panelRevision
        self.isPointerInside = isPointerInside
        self.isAwaitingRehostLayout = isAwaitingRehostLayout
        self.quotaRotation = quotaRotation
        self.quotaPauseReasons = quotaPauseReasons
        self.quotaSnapshot = quotaSnapshot
        self.quotaSourceHealth = quotaSourceHealth
        self.tasks = tasks
        self.selectedTaskID = selectedTaskID
        self.taskSourceHealth = taskSourceHealth
        self.terminalErrorLatch = terminalErrorLatch
        self.interactionGeneration = interactionGeneration
        self.pendingPanelDeadline = pendingPanelDeadline
        self.terminalErrorGeneration = terminalErrorGeneration
        self.isStarted = isStarted
    }

    public var selectedTaskIndex: Int? {
        guard let selectedTaskID else { return nil }
        return tasks.firstIndex { $0.id == selectedTaskID }
    }

    public var selectedTask: TaskSummary? {
        guard let selectedTaskIndex else { return nil }
        return tasks[selectedTaskIndex]
    }

    public var effectiveStatus: IslandVisualStatus {
        guard taskSourceHealth == .connected else { return .disconnected }
        if terminalErrorLatch != nil || tasks.contains(where: { $0.runState == .error }) {
            return .error
        }
        if tasks.contains(where: { $0.runState == .waitingForUser }) {
            return .waitingForUser
        }
        if tasks.contains(where: { $0.runState == .running }) {
            return .running
        }
        return .idle
    }
}
