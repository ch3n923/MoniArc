import Foundation
import XCTest
@testable import MoniArc

final class SessionsFSEventsWatcherTests: XCTestCase {
    func testWatcherReceivesSessionDirectoryChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoniArcFSEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watcher = try SessionsFSEventsWatcher(directoryURL: directory, latency: 0.05) {
            pair.continuation.yield(())
        }
        defer { watcher.stop() }

        try Data("event\n".utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let received = await firstEventOrTimeout(from: pair.stream)

        XCTAssertTrue(received)
    }

    func testMissingDirectoryFailsWithoutCreatingIt() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoniArcMissingFSEvents-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try SessionsFSEventsWatcher(directoryURL: directory) {}) { error in
            XCTAssertEqual(error as? SessionsFSEventsWatcherError, .directoryUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func firstEventOrTimeout(from stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
