import Foundation
import SQLite3
@testable import MoniArc

final class TaskTestSandbox {
    let rootURL: URL
    let sessionsURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoniArcTaskTests-\(UUID().uuidString)", isDirectory: true)
        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func createThreadsDatabase(includeOptionalColumns: Bool = true, omitTitle: Bool = false) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }

        let titleColumn = omitTitle ? "" : ", title TEXT NOT NULL"
        let optionalColumns = includeOptionalColumns ? ", thread_source TEXT, agent_path TEXT" : ""
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0,
                source TEXT NOT NULL
                \(titleColumn)
                \(optionalColumns)
            );
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }

    func insertThread(
        id: String,
        rolloutURL: URL,
        title: String,
        updatedAt: Int64,
        archived: Bool = false,
        source: String = "vscode",
        threadSource: String? = "user",
        agentPath: String? = nil,
        includeOptionalColumns: Bool = true
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }

        let columns = includeOptionalColumns
            ? "id, rollout_path, title, updated_at, archived, source, thread_source, agent_path"
            : "id, rollout_path, title, updated_at, archived, source"
        let values: [String]
        if includeOptionalColumns {
            values = [
                literal(id), literal(rolloutURL.path), literal(title), String(updatedAt),
                archived ? "1" : "0", literal(source), nullableLiteral(threadSource), nullableLiteral(agentPath),
            ]
        } else {
            values = [
                literal(id), literal(rolloutURL.path), literal(title), String(updatedAt),
                archived ? "1" : "0", literal(source),
            ]
        }

        let sql = "INSERT INTO threads (\(columns)) VALUES (\(values.joined(separator: ", ")));"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }

    func rolloutURL(named name: String) -> URL {
        sessionsURL.appendingPathComponent(name).appendingPathExtension("jsonl")
    }

    @discardableResult
    func writeRollout(named name: String, contents: String) throws -> URL {
        let url = rolloutURL(named: name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func nullableLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return literal(value)
    }

    enum FixtureError: Error {
        case sqlite
    }
}

struct StubCodexProcessChecker: CodexProcessAvailabilityChecking {
    let isAvailable: Bool

    func isCodexAvailable() async -> Bool {
        isAvailable
    }
}

func taskStartedLine() -> String {
    #"{"type":"event_msg","payload":{"type":"task_started"}}"#
}

func taskCompletedLine() -> String {
    #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
}

func requestUserInputLine(callID: String, arguments: String = "{}") -> String {
    """
    {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"\(callID)","arguments":"\(arguments)"}}
    """
}

func toolOutputLine(callID: String, output: String = "ok") -> String {
    """
    {"type":"response_item","payload":{"type":"function_call_output","call_id":"\(callID)","output":"\(output)"}}
    """
}
