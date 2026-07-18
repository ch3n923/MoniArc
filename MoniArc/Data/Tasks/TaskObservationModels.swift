import Foundation

/// A privacy-safe task model. Rollout paths and JSONL payloads intentionally never
/// cross the task-observation boundary.
struct CodexObservedTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let runState: CodexObservedTaskRunState
    let updatedAt: Date?
    let lightingProfile: TaskLightingProfile
}

enum CodexObservedTaskRunState: String, Equatable, Sendable {
    case running
    case waitingForUser
    case error
    case unknown
}

enum CodexTaskObservationHealth: String, Equatable, Sendable {
    case connected
    case disconnected
    case incompatible
}

enum CodexTaskObservationSignal: Equatable, Sendable {
    case terminalError(
        taskID: String,
        taskUpdatedAt: Date?,
        lightingProfile: TaskLightingProfile
    )
    case lifecycleActivity(taskID: String)
}

struct CodexTaskObservationSnapshot: Equatable, Sendable {
    let tasks: [CodexObservedTask]
    let health: CodexTaskObservationHealth
    let capturedAt: Date
    /// Ephemeral, offset-deduplicated events. The observer does not replay these
    /// to subscribers that attach after publication.
    let signals: [CodexTaskObservationSignal]

    init(
        tasks: [CodexObservedTask],
        health: CodexTaskObservationHealth,
        capturedAt: Date,
        signals: [CodexTaskObservationSignal] = []
    ) {
        self.tasks = tasks
        self.health = health
        self.capturedAt = capturedAt
        self.signals = signals
    }

    static func unavailable(
        _ health: CodexTaskObservationHealth,
        at date: Date
    ) -> CodexTaskObservationSnapshot {
        CodexTaskObservationSnapshot(tasks: [], health: health, capturedAt: date)
    }
}

struct CodexTaskObserverConfiguration: Sendable {
    static let defaultCandidateLimit = 32
    static let defaultPerFileByteLimit = 8 * 1_024 * 1_024
    static let defaultTotalByteLimit = 32 * 1_024 * 1_024
    static let defaultFSEventsCoalescingNanoseconds: UInt64 = 300_000_000
    static let defaultReconciliationNanoseconds: UInt64 = 2_000_000_000

    let codexDirectory: URL
    let databaseURL: URL
    let sessionsURL: URL
    let candidateLimit: Int
    let perFileByteLimit: Int
    let totalByteLimit: Int
    let fseventsCoalescingNanoseconds: UInt64
    let reconciliationNanoseconds: UInt64

    init(
        codexDirectory: URL,
        databaseURL: URL? = nil,
        sessionsURL: URL? = nil,
        candidateLimit: Int = defaultCandidateLimit,
        perFileByteLimit: Int = defaultPerFileByteLimit,
        totalByteLimit: Int = defaultTotalByteLimit,
        fseventsCoalescingNanoseconds: UInt64 = defaultFSEventsCoalescingNanoseconds,
        reconciliationNanoseconds: UInt64 = defaultReconciliationNanoseconds
    ) {
        let root = codexDirectory.standardizedFileURL
        self.codexDirectory = root
        self.databaseURL = (databaseURL ?? root.appendingPathComponent("state_5.sqlite")).standardizedFileURL
        self.sessionsURL = (sessionsURL ?? root.appendingPathComponent("sessions", isDirectory: true)).standardizedFileURL
        self.candidateLimit = max(1, min(candidateLimit, Self.defaultCandidateLimit))
        self.perFileByteLimit = max(1, min(perFileByteLimit, Self.defaultPerFileByteLimit))
        self.totalByteLimit = max(1, min(totalByteLimit, Self.defaultTotalByteLimit))
        self.fseventsCoalescingNanoseconds = fseventsCoalescingNanoseconds
        self.reconciliationNanoseconds = max(1, reconciliationNanoseconds)
    }

    static var live: CodexTaskObserverConfiguration {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        return CodexTaskObserverConfiguration(codexDirectory: root)
    }
}

struct TaskCandidate: Equatable, Sendable {
    let id: String
    let rolloutURL: URL
    let title: String
    let updatedAt: Date?
    let lightingProfile: TaskLightingProfile
}

enum TaskCandidateIndexError: Error, Equatable, Sendable {
    case databaseUnavailable
    case incompatibleSchema
    case queryFailed
}

enum TaskLifecycleState: Equatable, Sendable {
    case running
    case waitingForUser
    case error
    case unknown
}

struct TaskLifecycleScanResult: Equatable, Sendable {
    let activeState: TaskLifecycleState?
    let lightingProfile: TaskLightingProfile
    let bytesRead: Int
    let recognizedEnvelopeCount: Int
    let recognizedLifecycleCount: Int
    let latestTerminalErrorOffset: UInt64?
    let latestResetActivityOffset: UInt64?
}

protocol CodexProcessAvailabilityChecking: Sendable {
    func isCodexAvailable() async -> Bool
}
