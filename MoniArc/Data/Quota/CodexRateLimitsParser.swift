import Foundation

enum CodexRateLimitsParser {
    static func parseResponse(
        _ data: Data,
        receivedAt: Date,
        maximumStaleAge: TimeInterval = 15 * 60,
        resetGracePeriod: TimeInterval = 60
    ) throws -> CodexQuotaPayloadSnapshot {
        let root = try dictionary(from: data)
        let result = (root["result"] as? [String: Any]) ?? root
        let bucket = preferredCodexBucket(in: result)

        guard let bucket else {
            throw CodexQuotaError.missingRateLimits
        }

        let values = parseWindows(
            in: bucket,
            receivedAt: receivedAt,
            maximumStaleAge: maximumStaleAge,
            resetGracePeriod: resetGracePeriod
        )

        guard !values.isEmpty else {
            throw CodexQuotaError.noRecognizedWindow
        }

        return CodexQuotaPayloadSnapshot(
            fiveHour: values[.fiveHour],
            weekly: values[.weekly],
            additionalBuckets: additionalBuckets(
                in: result,
                receivedAt: receivedAt,
                maximumStaleAge: maximumStaleAge,
                resetGracePeriod: resetGracePeriod
            ),
            receivedAt: receivedAt
        )
    }

    /// Applies only windows whose duration is present and recognized. Sparse fields never clear
    /// prior values; a full read is still required shortly after every update notification.
    static func parseSparseNotification(
        _ data: Data,
        merging previous: CodexQuotaPayloadSnapshot?,
        receivedAt: Date,
        maximumStaleAge: TimeInterval = 15 * 60,
        resetGracePeriod: TimeInterval = 60
    ) throws -> CodexQuotaPayloadSnapshot? {
        let root = try dictionary(from: data)
        let params = (root["params"] as? [String: Any]) ?? root
        let bucket = (params["rateLimits"] as? [String: Any]) ?? params

        // Multi-bucket notifications use the same shape for every metered bucket.
        // Only the canonical Codex bucket may update the collapsed/main quota.
        if let limitID = bucket["limitId"] as? String, limitID != "codex" {
            return nil
        }

        var fiveHour = previous?.fiveHour
        var weekly = previous?.weekly
        var didConfirmValue = false

        for key in ["primary", "secondary"] {
            guard
                let rawWindow = bucket[key] as? [String: Any],
                let parsed = parseWindow(
                    rawWindow,
                    receivedAt: receivedAt,
                    maximumStaleAge: maximumStaleAge,
                    resetGracePeriod: resetGracePeriod
                )
            else {
                continue
            }

            didConfirmValue = true
            switch parsed.kind {
            case .fiveHour:
                fiveHour = parsed
            case .weekly:
                weekly = parsed
            }
        }

        guard didConfirmValue else { return nil }
        return CodexQuotaPayloadSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            additionalBuckets: previous?.additionalBuckets ?? [],
            receivedAt: receivedAt
        )
    }

    private static func additionalBuckets(
        in result: [String: Any],
        receivedAt: Date,
        maximumStaleAge: TimeInterval,
        resetGracePeriod: TimeInterval
    ) -> [CodexQuotaBucketValue] {
        guard let byID = result["rateLimitsByLimitId"] as? [String: Any] else { return [] }

        return byID.compactMap { id, value -> CodexQuotaBucketValue? in
            guard id != "codex", let bucket = value as? [String: Any] else { return nil }
            let values = parseWindows(
                in: bucket,
                receivedAt: receivedAt,
                maximumStaleAge: maximumStaleAge,
                resetGracePeriod: resetGracePeriod
            )
            guard !values.isEmpty else { return nil }
            return CodexQuotaBucketValue(
                id: id,
                displayName: bucket["limitName"] as? String,
                fiveHour: values[.fiveHour],
                weekly: values[.weekly]
            )
        }
        .sorted {
            let lhs = $0.displayName ?? $0.id
            let rhs = $1.displayName ?? $1.id
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func parseWindows(
        in bucket: [String: Any],
        receivedAt: Date,
        maximumStaleAge: TimeInterval,
        resetGracePeriod: TimeInterval
    ) -> [CodexQuotaWindowKind: CodexQuotaWindowValue] {
        var values: [CodexQuotaWindowKind: CodexQuotaWindowValue] = [:]
        for key in ["primary", "secondary"] {
            guard
                let rawWindow = bucket[key] as? [String: Any],
                let parsed = parseWindow(
                    rawWindow,
                    receivedAt: receivedAt,
                    maximumStaleAge: maximumStaleAge,
                    resetGracePeriod: resetGracePeriod
                )
            else { continue }
            values[parsed.kind] = parsed
        }
        return values
    }

    private static func preferredCodexBucket(in result: [String: Any]) -> [String: Any]? {
        if
            let byID = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = byID["codex"] as? [String: Any]
        {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func parseWindow(
        _ raw: [String: Any],
        receivedAt: Date,
        maximumStaleAge: TimeInterval,
        resetGracePeriod: TimeInterval
    ) -> CodexQuotaWindowValue? {
        guard
            let duration = integer(raw["windowDurationMins"]),
            let kind = CodexQuotaWindowKind(windowDurationMinutes: duration),
            let used = number(raw["usedPercent"])
        else {
            return nil
        }

        let remaining = min(100, max(0, 100 - used))
        let normalizedUsed = 100 - remaining
        let resetsAt = number(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))
        let ageDeadline = receivedAt.addingTimeInterval(maximumStaleAge)
        let resetDeadline = resetsAt?.addingTimeInterval(resetGracePeriod)
        let retainedUntil = min(ageDeadline, resetDeadline ?? ageDeadline)

        return CodexQuotaWindowValue(
            kind: kind,
            usedPercent: normalizedUsed,
            remainingPercent: remaining,
            resetsAt: resetsAt,
            receivedAt: receivedAt,
            retainedUntil: retainedUntil,
            isStale: false
        )
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw CodexQuotaError.malformedMessage
        }
        return dictionary
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = numericNumber(value) else { return nil }
        return number.intValue
    }

    private static func number(_ value: Any?) -> Double? {
        numericNumber(value)?.doubleValue
    }

    private static func numericNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}
