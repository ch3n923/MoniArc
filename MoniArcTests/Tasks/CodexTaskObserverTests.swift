import Foundation
import XCTest
@testable import MoniArc

final class CodexTaskObserverTests: XCTestCase {
    func testRefreshPublishesPrivacySafeActiveTaskSnapshot() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rollout = try sandbox.writeRollout(named: "active", contents: taskStartedLine() + "\n")
        try sandbox.insertThread(
            id: "task-1",
            rolloutURL: rollout,
            title: "Build native panel",
            updatedAt: 1_700_000_000
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let observer = makeObserver(sandbox: sandbox, available: true, now: capturedAt)

        await observer.refresh()
        let snapshot = await latestSnapshot(from: observer)

        XCTAssertEqual(snapshot?.health, .connected)
        XCTAssertEqual(snapshot?.capturedAt, capturedAt)
        XCTAssertEqual(snapshot?.tasks, [
            CodexObservedTask(
                id: "task-1",
                title: "Build native panel",
                runState: .running,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lightingProfile: .fallback
            ),
        ])
    }

    func testUnavailableProcessIsDisconnectedWithoutTouchingDatabase() async throws {
        let sandbox = try TaskTestSandbox()
        let observer = makeObserver(sandbox: sandbox, available: false)

        await observer.refresh()
        let snapshot = await latestSnapshot(from: observer)

        XCTAssertEqual(snapshot?.health, .disconnected)
        XCTAssertEqual(snapshot?.tasks, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.databaseURL.path))
    }

    func testUnknownJSONLFormatIsIncompatible() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rollout = try sandbox.writeRollout(
            named: "future",
            contents: #"{"future_schema":{"task":"running"}}"#
        )
        try sandbox.insertThread(
            id: "future-task",
            rolloutURL: rollout,
            title: "Future task",
            updatedAt: 1_700_000_000
        )
        let observer = makeObserver(sandbox: sandbox, available: true)

        await observer.refresh()
        let snapshot = await latestSnapshot(from: observer)

        XCTAssertEqual(snapshot?.health, .incompatible)
        XCTAssertEqual(snapshot?.tasks, [])
    }

    func testRolloutOutsideSessionsDirectoryIsNeverRead() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let sentinel = "OUTSIDE_DIRECTORY_PRIVATE_SENTINEL"
        let outsideURL = sandbox.rootURL.appendingPathComponent("outside.jsonl")
        try Data((taskStartedLine() + sentinel).utf8).write(to: outsideURL)
        try sandbox.insertThread(
            id: "outside",
            rolloutURL: outsideURL,
            title: "Outside",
            updatedAt: 1_700_000_000
        )
        let observer = makeObserver(sandbox: sandbox, available: true)

        await observer.refresh()
        let snapshot = await latestSnapshot(from: observer)

        XCTAssertEqual(snapshot?.health, .incompatible)
        XCTAssertEqual(snapshot?.tasks, [])
        XCTAssertFalse(String(reflecting: snapshot).contains(sentinel))
    }

    func testDomainAdapterEmitsHealthLifecycleAndSnapshot() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rollout = try sandbox.writeRollout(named: "adapter", contents: taskStartedLine() + "\n")
        try sandbox.insertThread(
            id: "adapter-task",
            rolloutURL: rollout,
            title: "Adapter task",
            updatedAt: 1_700_000_000
        )
        let observer = makeObserver(sandbox: sandbox, available: true)
        let source = CodexTaskSource(observer: observer)
        let stream = await source.events()
        var iterator = stream.makeAsyncIterator()

        await source.start()
        let first = await iterator.next()
        let second = await iterator.next()
        await source.stop()

        XCTAssertEqual(first, .healthChanged(.connected))
        XCTAssertEqual(second, .snapshot([
            TaskSummary(
                id: "adapter-task",
                title: "Adapter task",
                runState: .running,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]))
    }

    func testDomainAdapterEmitsRecentTerminalErrorEvenWhenTaskAlreadyCompleted() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rollout = try sandbox.writeRollout(
            named: "terminal-error",
            contents: [
                taskStartedLine(),
                #"{"type":"event_msg","payload":{"type":"failed"}}"#,
                taskCompletedLine(),
            ].joined(separator: "\n")
        )
        try sandbox.insertThread(
            id: "failed-task",
            rolloutURL: rollout,
            title: "Failed task",
            updatedAt: 1_700_000_000
        )
        let observer = makeObserver(
            sandbox: sandbox,
            available: true,
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let source = CodexTaskSource(observer: observer)
        let stream = await source.events()
        var iterator = stream.makeAsyncIterator()

        await source.start()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        await source.stop()

        XCTAssertEqual(first, .healthChanged(.connected))
        XCTAssertEqual(second, .terminalError(
            taskID: "failed-task",
            taskUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lightingProfile: .fallback
        ))
        XCTAssertEqual(third, .snapshot([]))
    }

    func testPeriodicReconciliationClearsCompletedTask() async throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rollout = try sandbox.writeRollout(named: "reconcile", contents: taskStartedLine() + "\n")
        try sandbox.insertThread(
            id: "reconcile-task",
            rolloutURL: rollout,
            title: "Reconcile task",
            updatedAt: 1_700_000_000
        )
        let observer = CodexTaskObserver(
            configuration: CodexTaskObserverConfiguration(
                codexDirectory: sandbox.rootURL,
                databaseURL: sandbox.databaseURL,
                sessionsURL: sandbox.sessionsURL,
                reconciliationNanoseconds: 20_000_000
            ),
            processChecker: StubCodexProcessChecker(isAvailable: true)
        )
        let stream = await observer.updates()
        var iterator = stream.makeAsyncIterator()

        await observer.start()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.tasks.first?.runState, .running)

        try Data((taskStartedLine() + "\n" + taskCompletedLine() + "\n").utf8)
            .write(to: rollout, options: .atomic)

        let completed = await iterator.next()
        await observer.stop()

        XCTAssertEqual(completed?.tasks, [])
    }

    private func makeObserver(
        sandbox: TaskTestSandbox,
        available: Bool,
        now: Date = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> CodexTaskObserver {
        CodexTaskObserver(
            configuration: CodexTaskObserverConfiguration(
                codexDirectory: sandbox.rootURL,
                databaseURL: sandbox.databaseURL,
                sessionsURL: sandbox.sessionsURL
            ),
            processChecker: StubCodexProcessChecker(isAvailable: available),
            now: { now }
        )
    }

    private func latestSnapshot(from observer: CodexTaskObserver) async -> CodexTaskObservationSnapshot? {
        let stream = await observer.updates()
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

}
