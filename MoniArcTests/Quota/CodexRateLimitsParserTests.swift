import Foundation
import XCTest
@testable import MoniArc

final class CodexRateLimitsParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testNormalLegacyBucketMapsFiveHourAndWeekly() throws {
        let snapshot = try parse(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 26,
                  "windowDurationMins": 300,
                  "resetsAt": 2000000300
                },
                "secondary": {
                  "usedPercent": 61,
                  "windowDurationMins": 10080,
                  "resetsAt": 2000600000
                }
              }
            }
            """
        )

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 74)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 39)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 2_000_000_300))
        XCTAssertFalse(try XCTUnwrap(snapshot.fiveHour).isStale)
    }

    func testCodexMultiBucketTakesPriorityOverLegacyAndOtherBuckets() throws {
        let snapshot = try parse(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 99, "windowDurationMins": 300}
              },
              "rateLimitsByLimitId": {
                "other": {
                  "primary": {"usedPercent": 88, "windowDurationMins": 300}
                },
                "codex": {
                  "limitId": "codex",
                  "primary": {"usedPercent": 12, "windowDurationMins": 300},
                  "secondary": {"usedPercent": 34, "windowDurationMins": 10080}
                }
              }
            }
            """
        )

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 88)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 66)
        XCTAssertEqual(snapshot.additionalBuckets.map(\.id), ["other"])
        XCTAssertEqual(snapshot.additionalBuckets.first?.fiveHour?.remainingPercent, 12)
    }

    func testMissingWeeklyWindowIsAValidSnapshot() throws {
        let snapshot = try parse(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 44, "windowDurationMins": 300},
                "secondary": {"usedPercent": 10, "windowDurationMins": 1440}
              }
            }
            """
        )

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 56)
        XCTAssertNil(snapshot.weekly)
    }

    func testRemainingPercentIsClampedWithoutTrustingServerRange() throws {
        let snapshot = try parse(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": -20, "windowDurationMins": 300},
                "secondary": {"usedPercent": 130, "windowDurationMins": 10080}
              }
            }
            """
        )

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 100)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 0)
    }

    func testBadJSONLineIsRejectedWithoutIncludingPayloadInError() {
        let sentinel = "SECRET_PROMPT_SENTINEL"
        let data = Data("{bad \(sentinel)".utf8)

        XCTAssertThrowsError(
            try CodexRateLimitsParser.parseResponse(data, receivedAt: now)
        ) { error in
            XCTAssertEqual(error as? CodexQuotaError, .malformedMessage)
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
        }
    }

    func testSparseNotificationPublishesRecognizedFieldAndPreservesOtherWindow() throws {
        let previous = try parse(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 10, "windowDurationMins": 300},
                "secondary": {"usedPercent": 20, "windowDurationMins": 10080}
              }
            }
            """
        )

        let notification = Data(
            """
            {
              "rateLimits": {
                "primary": {"usedPercent": 40, "windowDurationMins": 300}
              }
            }
            """.utf8
        )
        let merged = try XCTUnwrap(CodexRateLimitsParser.parseSparseNotification(
            notification,
            merging: previous,
            receivedAt: now.addingTimeInterval(1)
        ))

        XCTAssertEqual(merged.fiveHour?.remainingPercent, 60)
        XCTAssertEqual(merged.weekly, previous.weekly)
    }

    func testSparseNotificationWithoutDurationDoesNotGuessAWindow() throws {
        let notification = Data(
            """
            {"rateLimits":{"primary":{"usedPercent":40}}}
            """.utf8
        )

        let merged = try CodexRateLimitsParser.parseSparseNotification(
            notification,
            merging: nil,
            receivedAt: now
        )
        XCTAssertNil(merged)
    }

    func testSparseNotificationForExtraBucketCannotOverwriteMainQuota() throws {
        let previous = try parse(
            """
            {
              "rateLimitsByLimitId": {
                "codex": {
                  "primary": {"usedPercent": 16, "windowDurationMins": 300},
                  "secondary": {"usedPercent": 18, "windowDurationMins": 10080}
                }
              }
            }
            """
        )
        let notification = Data(
            """
            {
              "rateLimits": {
                "limitId": "codex_bengalfox",
                "primary": {"usedPercent": 1, "windowDurationMins": 300},
                "secondary": {"usedPercent": 1, "windowDurationMins": 10080}
              }
            }
            """.utf8
        )

        let merged = try CodexRateLimitsParser.parseSparseNotification(
            notification,
            merging: previous,
            receivedAt: now.addingTimeInterval(1)
        )
        XCTAssertNil(merged)
        XCTAssertEqual(previous.fiveHour?.remainingPercent, 84)
        XCTAssertEqual(previous.weekly?.remainingPercent, 82)
    }

    func testStaleRetentionUsesEarlierOfAgeAndResetGrace() throws {
        let snapshot = try parse(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 10,
                  "windowDurationMins": 300,
                  "resetsAt": 2000000010
                },
                "secondary": {
                  "usedPercent": 20,
                  "windowDurationMins": 10080,
                  "resetsAt": 2000100000
                }
              }
            }
            """
        )

        let stale = snapshot.markedStale(at: now.addingTimeInterval(30))
        XCTAssertTrue(try XCTUnwrap(stale.fiveHour).isStale)
        XCTAssertTrue(try XCTUnwrap(stale.weekly).isStale)

        let afterFiveHourDeadline = stale.markedStale(at: now.addingTimeInterval(71))
        XCTAssertNil(afterFiveHourDeadline.fiveHour)
        XCTAssertNotNil(afterFiveHourDeadline.weekly)
    }

    private func parse(_ fixture: String) throws -> CodexQuotaPayloadSnapshot {
        try CodexRateLimitsParser.parseResponse(
            Data(fixture.utf8),
            receivedAt: now
        )
    }
}

@MainActor
final class IslandViewModelQuotaSelectionTests: XCTestCase {
    func testWeeklyOnlyQuotaSelectsWeeklyPage() {
        let model = IslandViewModel()
        model.activeQuotaPage = .fiveHour
        model.fiveHourQuota = .unavailable
        model.weeklyQuota = QuotaPresentation(
            remainingPercent: 68,
            resetsAt: nil,
            isStale: false
        )

        model.normalizeActiveQuotaPage()

        XCTAssertEqual(model.activeQuotaPage, .weekly)
    }

    func testBothAvailablePreservesRotationSelection() {
        let model = IslandViewModel()
        model.activeQuotaPage = .fiveHour
        model.fiveHourQuota = QuotaPresentation(
            remainingPercent: 80,
            resetsAt: nil,
            isStale: false
        )
        model.weeklyQuota = QuotaPresentation(
            remainingPercent: 68,
            resetsAt: nil,
            isStale: false
        )

        model.normalizeActiveQuotaPage()

        XCTAssertEqual(model.activeQuotaPage, .fiveHour)
    }
}
