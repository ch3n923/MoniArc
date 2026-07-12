import Foundation

/// The only Codex rolling windows MoniArc names. Unknown windows are ignored.
enum CodexQuotaWindowKind: String, Sendable, Equatable, CaseIterable {
    case fiveHour
    case weekly

    init?(windowDurationMinutes: Int) {
        switch windowDurationMinutes {
        case 300:
            self = .fiveHour
        case 10_080:
            self = .weekly
        default:
            return nil
        }
    }
}

/// A sanitized rate-limit value. It intentionally contains no account or authentication data.
struct CodexQuotaWindowValue: Sendable, Equatable {
    let kind: CodexQuotaWindowKind
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
    let receivedAt: Date
    let retainedUntil: Date
    var isStale: Bool

    func markedStale(at date: Date) -> CodexQuotaWindowValue? {
        guard date < retainedUntil else { return nil }
        var copy = self
        copy.isStale = true
        return copy
    }
}

struct CodexQuotaBucketValue: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String?
    var fiveHour: CodexQuotaWindowValue?
    var weekly: CodexQuotaWindowValue?

    var hasKnownWindow: Bool {
        fiveHour != nil || weekly != nil
    }

    func markedStale(at date: Date) -> CodexQuotaBucketValue? {
        let copy = CodexQuotaBucketValue(
            id: id,
            displayName: displayName,
            fiveHour: fiveHour?.markedStale(at: date),
            weekly: weekly?.markedStale(at: date)
        )
        return copy.hasKnownWindow ? copy : nil
    }
}

/// Parser/transport-facing snapshot. The domain adapter publishes only its display-safe fields.
struct CodexQuotaPayloadSnapshot: Sendable, Equatable {
    var fiveHour: CodexQuotaWindowValue?
    var weekly: CodexQuotaWindowValue?
    var additionalBuckets: [CodexQuotaBucketValue]
    let receivedAt: Date

    var hasKnownWindow: Bool {
        fiveHour != nil || weekly != nil
    }

    var isStale: Bool {
        let values = [fiveHour, weekly].compactMap { $0 }
        return !values.isEmpty && values.allSatisfy(\.isStale)
    }

    var nextRetentionDeadline: Date? {
        ([fiveHour?.retainedUntil, weekly?.retainedUntil]
            + additionalBuckets.flatMap { [$0.fiveHour?.retainedUntil, $0.weekly?.retainedUntil] })
            .compactMap { $0 }
            .min()
    }

    func markedStale(at date: Date) -> CodexQuotaPayloadSnapshot {
        CodexQuotaPayloadSnapshot(
            fiveHour: fiveHour?.markedStale(at: date),
            weekly: weekly?.markedStale(at: date),
            additionalBuckets: additionalBuckets.compactMap { $0.markedStale(at: date) },
            receivedAt: receivedAt
        )
    }
}

enum CodexQuotaConnectionState: Sendable, Equatable {
    case stopped
    case connecting
    case connected
    case reconnecting(delaySeconds: Double)
    case unavailable
}

enum CodexQuotaSourceUpdate: Sendable, Equatable {
    case snapshot(CodexQuotaPayloadSnapshot)
    case connection(CodexQuotaConnectionState)
}

enum CodexQuotaError: Error, LocalizedError, Sendable, Equatable {
    case binaryUnavailable
    case processLaunchFailed
    case transportClosed
    case requestTimedOut
    case requestCancelled
    case malformedMessage
    case rpcError(code: Int?)
    case missingRateLimits
    case noRecognizedWindow

    var errorDescription: String? {
        switch self {
        case .binaryUnavailable:
            "Codex executable is unavailable."
        case .processLaunchFailed:
            "Codex App Server could not be started."
        case .transportClosed:
            "Codex App Server disconnected."
        case .requestTimedOut:
            "Codex App Server request timed out."
        case .requestCancelled:
            "Codex App Server request was cancelled."
        case .malformedMessage:
            "Codex App Server returned an unsupported message."
        case let .rpcError(code):
            if let code {
                "Codex App Server returned RPC error \(code)."
            } else {
                "Codex App Server returned an RPC error."
            }
        case .missingRateLimits:
            "Codex rate limits are missing."
        case .noRecognizedWindow:
            "No supported Codex quota window was present."
        }
    }
}

struct CodexQuotaSourceConfiguration: Sendable {
    var binaryOverride: URL?
    var environment: [String: String]
    var requestTimeout: Duration
    var pollingInterval: Duration
    var sparseNotificationDebounce: Duration
    var reconnectDelays: [Duration]
    var maximumStaleAge: TimeInterval
    var resetGracePeriod: TimeInterval
    var now: @Sendable () -> Date

    static var live: CodexQuotaSourceConfiguration {
        CodexQuotaSourceConfiguration(
            binaryOverride: nil,
            environment: ProcessInfo.processInfo.environment,
            requestTimeout: .seconds(10),
            pollingInterval: .seconds(60),
            sparseNotificationDebounce: .milliseconds(250),
            reconnectDelays: [
                .seconds(1),
                .seconds(2),
                .seconds(5),
                .seconds(10),
                .seconds(30),
            ],
            maximumStaleAge: 15 * 60,
            resetGracePeriod: 60,
            now: { Date() }
        )
    }
}
