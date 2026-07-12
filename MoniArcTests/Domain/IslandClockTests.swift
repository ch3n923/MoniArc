import XCTest
@testable import MoniArc

final class IslandClockTests: XCTestCase {
    func testManualClockOnlyResumesWaitersAtTheirDeadline() async throws {
        let clock = ManualMonotonicClock()
        let resumed = ExpectationFlag()
        let sleeper = Task {
            try await clock.sleep(until: .zero.advanced(by: .seconds(1)))
            await resumed.setTrue()
        }

        for _ in 0..<1_000 {
            if clock.pendingSleepCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(clock.pendingSleepCount, 1)

        clock.advance(by: .milliseconds(999))
        await Task.yield()
        let beforeDeadline = await resumed.value
        XCTAssertFalse(beforeDeadline)

        clock.advance(by: .milliseconds(1))
        try await sleeper.value
        let afterDeadline = await resumed.value
        XCTAssertTrue(afterDeadline)
    }

    func testFakeWallClockIsIndependentFromMonotonicClock() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let wallClock = FakeWallClock(now: start)
        let monotonicClock = ManualMonotonicClock()

        monotonicClock.advance(by: .seconds(45))
        XCTAssertEqual(wallClock.now(), start)

        wallClock.advance(by: 60)
        XCTAssertEqual(wallClock.now(), start.addingTimeInterval(60))
        XCTAssertEqual(monotonicClock.now(), MonotonicInstant.zero.advanced(by: .seconds(45)))
    }
}

private actor ExpectationFlag {
    private(set) var value = false

    func setTrue() {
        value = true
    }
}
