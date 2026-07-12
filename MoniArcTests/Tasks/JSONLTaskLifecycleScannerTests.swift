import Foundation
import XCTest
@testable import MoniArc

final class JSONLTaskLifecycleScannerTests: XCTestCase {
    private let scanner = JSONLTaskLifecycleScanner()

    func testTaskStartedIsRunning() throws {
        let url = try temporaryJSONL(taskStartedLine() + "\n")
        let result = try scanner.scan(fileURL: url, byteLimit: 8 * 1_024 * 1_024)

        XCTAssertEqual(result.activeState, .running)
        XCTAssertEqual(result.recognizedLifecycleCount, 1)
    }

    func testUnmatchedRequestUserInputWaitsAndMatchingOutputResumes() throws {
        let waitingURL = try temporaryJSONL([
            taskStartedLine(),
            requestUserInputLine(callID: "call-1"),
        ].joined(separator: "\n"))
        XCTAssertEqual(
            try scanner.scan(fileURL: waitingURL, byteLimit: 1_024 * 1_024).activeState,
            .waitingForUser
        )

        let resumedURL = try temporaryJSONL([
            taskStartedLine(),
            requestUserInputLine(callID: "call-1"),
            toolOutputLine(callID: "different-call"),
            toolOutputLine(callID: "call-1"),
        ].joined(separator: "\n"))
        XCTAssertEqual(
            try scanner.scan(fileURL: resumedURL, byteLimit: 1_024 * 1_024).activeState,
            .running
        )
    }

    func testTaskCompleteAndInterruptionRemoveTaskWithoutError() throws {
        let completed = try temporaryJSONL([
            taskStartedLine(),
            taskCompletedLine(),
        ].joined(separator: "\n"))
        XCTAssertNil(try scanner.scan(fileURL: completed, byteLimit: 1_024 * 1_024).activeState)

        let interrupted = try temporaryJSONL([
            taskStartedLine(),
            #"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"unknown"}}"#,
        ].joined(separator: "\n"))
        XCTAssertNil(try scanner.scan(fileURL: interrupted, byteLimit: 1_024 * 1_024).activeState)
    }

    func testTerminalErrorMarkerSurvivesFollowingTaskComplete() throws {
        let url = try temporaryJSONL([
            taskStartedLine(),
            #"{"type":"event_msg","payload":{"type":"systemError"}}"#,
            taskCompletedLine(),
        ].joined(separator: "\n"))

        let result = try scanner.scan(fileURL: url, byteLimit: 1_024 * 1_024)

        XCTAssertNil(result.activeState)
        XCTAssertNotNil(result.latestTerminalErrorOffset)
        XCTAssertLessThan(
            try XCTUnwrap(result.latestResetActivityOffset),
            try XCTUnwrap(result.latestTerminalErrorOffset)
        )
    }

    func testExplicitErrorsAreRedButUnknownEventsAreNot() throws {
        for eventName in ["error", "systemError", "failed"] {
            let url = try temporaryJSONL([
                taskStartedLine(),
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(eventName)\"}}",
            ].joined(separator: "\n"))
            XCTAssertEqual(
                try scanner.scan(fileURL: url, byteLimit: 1_024 * 1_024).activeState,
                .error,
                eventName
            )
        }

        let unknown = try temporaryJSONL([
            taskStartedLine(),
            #"{"type":"event_msg","payload":{"type":"future_lifecycle_event"}}"#,
        ].joined(separator: "\n"))
        XCTAssertEqual(try scanner.scan(fileURL: unknown, byteLimit: 1_024 * 1_024).activeState, .running)
    }

    func testTrailingHalfLineIsIgnored() throws {
        let url = try temporaryJSONL(
            taskStartedLine() + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete""#
        )

        let result = try scanner.scan(fileURL: url, byteLimit: 1_024 * 1_024)
        XCTAssertEqual(result.activeState, .running)
        XCTAssertEqual(result.recognizedLifecycleCount, 1)
    }

    func testUnknownFormatReportsNoCompatibleEnvelope() throws {
        let url = try temporaryJSONL(#"{"schema":99,"new_container":{"state":"running"}}"#)
        let result = try scanner.scan(fileURL: url, byteLimit: 1_024 * 1_024)

        XCTAssertNil(result.activeState)
        XCTAssertEqual(result.recognizedEnvelopeCount, 0)
        XCTAssertEqual(result.recognizedLifecycleCount, 0)
    }

    func testSensitivePromptCodeArgumentsAndOutputNeverEnterResult() throws {
        let sentinel = "PRIVATE_SENTINEL_DO_NOT_RETAIN_7F21"
        let url = try temporaryJSONL([
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":"PRIVATE_SENTINEL_DO_NOT_RETAIN_7F21"}}"#,
            taskStartedLine(),
            requestUserInputLine(callID: "call-1", arguments: sentinel),
            toolOutputLine(callID: "call-1", output: sentinel),
        ].joined(separator: "\n"))

        let result = try scanner.scan(fileURL: url, byteLimit: 1_024 * 1_024)
        let reflectedResult = String(reflecting: result)

        XCTAssertEqual(result.activeState, .running)
        XCTAssertFalse(reflectedResult.contains(sentinel))
    }

    func testTailReadHonorsByteLimitAndStillFindsRecentLifecycle() throws {
        let oldPadding = String(repeating: "x", count: 4_096)
        let url = try temporaryJSONL(oldPadding + "\n" + taskStartedLine() + "\n")

        let result = try scanner.scan(fileURL: url, byteLimit: 512)

        XCTAssertLessThanOrEqual(result.bytesRead, 512)
        XCTAssertEqual(result.activeState, .running)
    }

    private func temporaryJSONL(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoniArcLifecycle-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try Data(contents.utf8).write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
