import Foundation
import XCTest
@testable import MoniArc

final class SQLiteTaskCandidateIndexTests: XCTestCase {
    func testLoadsOnlyRootUnarchivedNonExecCandidatesWithoutMutatingDatabase() throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        let rootRollout = sandbox.rolloutURL(named: "root")

        try sandbox.insertThread(
            id: "root",
            rolloutURL: rootRollout,
            title: "Root task",
            updatedAt: 1_700_000_100
        )
        try sandbox.insertThread(
            id: "archived",
            rolloutURL: sandbox.rolloutURL(named: "archived"),
            title: "Archived",
            updatedAt: 1_700_000_099,
            archived: true
        )
        try sandbox.insertThread(
            id: "subagent-source",
            rolloutURL: sandbox.rolloutURL(named: "subagent-source"),
            title: "Subagent",
            updatedAt: 1_700_000_098,
            source: #"{"subagent":{"depth":1}}"#,
            threadSource: "subagent"
        )
        try sandbox.insertThread(
            id: "subagent-path",
            rolloutURL: sandbox.rolloutURL(named: "subagent-path"),
            title: "Subagent path",
            updatedAt: 1_700_000_097,
            agentPath: "/root/worker"
        )
        try sandbox.insertThread(
            id: "exec",
            rolloutURL: sandbox.rolloutURL(named: "exec"),
            title: "Exec",
            updatedAt: 1_700_000_096,
            source: "exec",
            threadSource: "exec"
        )

        let dataBefore = try Data(contentsOf: sandbox.databaseURL)
        let siblingNamesBefore = try FileManager.default.contentsOfDirectory(atPath: sandbox.rootURL.path).sorted()

        let index = SQLiteTaskCandidateIndex(databaseURL: sandbox.databaseURL)
        let candidates = try index.recentCandidates(limit: 32)

        let dataAfter = try Data(contentsOf: sandbox.databaseURL)
        let siblingNamesAfter = try FileManager.default.contentsOfDirectory(atPath: sandbox.rootURL.path).sorted()
        XCTAssertEqual(candidates.map(\.id), ["root"])
        XCTAssertEqual(candidates.first?.title, "Root task")
        XCTAssertEqual(candidates.first?.rolloutURL, rootRollout.standardizedFileURL)
        XCTAssertEqual(dataAfter, dataBefore)
        XCTAssertEqual(siblingNamesAfter, siblingNamesBefore)
    }

    func testSupportsSchemaWithoutOptionalFilteringColumns() throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase(includeOptionalColumns: false)
        try sandbox.insertThread(
            id: "legacy-root",
            rolloutURL: sandbox.rolloutURL(named: "legacy"),
            title: "Legacy",
            updatedAt: 1_700_000_000,
            includeOptionalColumns: false
        )

        let candidates = try SQLiteTaskCandidateIndex(databaseURL: sandbox.databaseURL)
            .recentCandidates(limit: 32)

        XCTAssertEqual(candidates.map(\.id), ["legacy-root"])
    }

    func testMissingRequiredColumnIsIncompatible() throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase(omitTitle: true)

        XCTAssertThrowsError(
            try SQLiteTaskCandidateIndex(databaseURL: sandbox.databaseURL).recentCandidates(limit: 32)
        ) { error in
            XCTAssertEqual(error as? TaskCandidateIndexError, .incompatibleSchema)
        }
    }

    func testCandidateCountNeverExceedsThirtyTwo() throws {
        let sandbox = try TaskTestSandbox()
        try sandbox.createThreadsDatabase()
        for index in 0..<40 {
            try sandbox.insertThread(
                id: "task-\(index)",
                rolloutURL: sandbox.rolloutURL(named: "task-\(index)"),
                title: "Task \(index)",
                updatedAt: Int64(1_700_000_000 + index)
            )
        }

        let candidates = try SQLiteTaskCandidateIndex(databaseURL: sandbox.databaseURL)
            .recentCandidates(limit: 100)

        XCTAssertEqual(candidates.count, 32)
        XCTAssertEqual(candidates.first?.id, "task-39")
    }
}
