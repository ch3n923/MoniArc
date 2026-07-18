import Foundation
import SQLite3

struct SQLiteTaskCandidateIndex: Sendable {
    let databaseURL: URL

    func recentCandidates(limit requestedLimit: Int) throws -> [TaskCandidate] {
        let limit = max(1, min(requestedLimit, CodexTaskObserverConfiguration.defaultCandidateLimit))
        var database: OpaquePointer?

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw TaskCandidateIndexError.databaseUnavailable
        }
        defer { sqlite3_close(database) }

        guard sqlite3_db_readonly(database, "main") == 1,
              sqlite3_exec(database, "PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            throw TaskCandidateIndexError.databaseUnavailable
        }

        let columns = try threadColumns(in: database)
        let requiredColumns: Set<String> = [
            "id", "rollout_path", "title", "updated_at", "archived", "source"
        ]
        guard requiredColumns.isSubset(of: columns) else {
            throw TaskCandidateIndexError.incompatibleSchema
        }

        let threadSourceExpression = columns.contains("thread_source")
            ? "thread_source"
            : "NULL AS thread_source"
        let agentPathExpression = columns.contains("agent_path")
            ? "agent_path"
            : "NULL AS agent_path"
        let modelExpression = columns.contains("model")
            ? "model"
            : "NULL AS model"
        let reasoningEffortExpression = columns.contains("reasoning_effort")
            ? "reasoning_effort"
            : "NULL AS reasoning_effort"
        let threadSourceFilter = columns.contains("thread_source")
            ? "AND (thread_source IS NULL OR LOWER(TRIM(thread_source)) NOT IN ('subagent', 'exec'))"
            : ""
        let agentPathFilter = columns.contains("agent_path")
            ? "AND (agent_path IS NULL OR TRIM(agent_path) = '')"
            : ""
        let query = """
            SELECT id, rollout_path, title, updated_at, archived, source,
                   \(threadSourceExpression), \(agentPathExpression),
                   \(modelExpression), \(reasoningEffortExpression)
            FROM threads
            WHERE archived = 0
              AND LOWER(TRIM(source)) <> 'subagent'
              AND LOWER(TRIM(source)) <> 'exec'
              AND LOWER(source) NOT LIKE 'exec:%'
              AND LOWER(source) NOT LIKE '%"subagent"%'
              AND LOWER(source) NOT LIKE '%"exec"%'
              \(threadSourceFilter)
              \(agentPathFilter)
            ORDER BY updated_at DESC, id DESC
            LIMIT ?1;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TaskCandidateIndexError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
            throw TaskCandidateIndexError.queryFailed
        }

        var candidates: [TaskCandidate] = []
        candidates.reserveCapacity(limit)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = text(in: statement, column: 0),
                      let rolloutPath = text(in: statement, column: 1),
                      let title = text(in: statement, column: 2),
                      let source = text(in: statement, column: 5),
                      !id.isEmpty,
                      !rolloutPath.isEmpty else {
                    continue
                }

                let archived = sqlite3_column_int(statement, 4) != 0
                let threadSource = text(in: statement, column: 6)
                let agentPath = text(in: statement, column: 7)
                let model = text(in: statement, column: 8)
                let reasoningEffort = text(in: statement, column: 9)
                guard !archived,
                      !Self.isSubagent(source: source, threadSource: threadSource, agentPath: agentPath),
                      !Self.isExecTask(source: source, threadSource: threadSource) else {
                    continue
                }

                let rawTimestamp = sqlite3_column_int64(statement, 3)
                let seconds = rawTimestamp > 10_000_000_000
                    ? TimeInterval(rawTimestamp) / 1_000
                    : TimeInterval(rawTimestamp)
                let updatedAt = rawTimestamp > 0 ? Date(timeIntervalSince1970: seconds) : nil

                candidates.append(
                    TaskCandidate(
                        id: id,
                        rolloutURL: URL(fileURLWithPath: rolloutPath).standardizedFileURL,
                        title: title,
                        updatedAt: updatedAt,
                        lightingProfile: TaskLightingProfile.normalized(
                            model: model,
                            serviceTier: nil,
                            reasoningEffort: reasoningEffort
                        )
                    )
                )

            case SQLITE_DONE:
                return candidates

            default:
                throw TaskCandidateIndexError.queryFailed
            }
        }
    }

    private func threadColumns(in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TaskCandidateIndexError.incompatibleSchema
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = text(in: statement, column: 1) {
                    columns.insert(name)
                }
            case SQLITE_DONE:
                return columns
            default:
                throw TaskCandidateIndexError.incompatibleSchema
            }
        }
    }

    private func text(in statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: bytes)
    }

    private static func isSubagent(
        source: String,
        threadSource: String?,
        agentPath: String?
    ) -> Bool {
        if let agentPath, !agentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        let normalizedThreadSource = threadSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedThreadSource == "subagent" {
            return true
        }

        let normalizedSource = source.lowercased()
        return normalizedSource == "subagent" || normalizedSource.contains("\"subagent\"")
    }

    private static func isExecTask(source: String, threadSource: String?) -> Bool {
        let normalizedThreadSource = threadSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedThreadSource == "exec" {
            return true
        }

        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedSource == "exec"
            || normalizedSource.hasPrefix("exec:")
            || normalizedSource.contains("\"exec\"")
    }
}
