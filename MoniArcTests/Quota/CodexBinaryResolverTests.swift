import Foundation
import XCTest
@testable import MoniArc

final class CodexBinaryResolverTests: XCTestCase {
    func testCandidateOrderIsOverrideThenDocumentedLocationsThenPATH() {
        let override = URL(fileURLWithPath: "/tmp/harness-codex")
        let candidates = CodexBinaryResolver.candidateURLs(
            override: override,
            environment: ["PATH": "/custom/bin:/second/bin"]
        ).map(\.path)

        XCTAssertEqual(candidates, [
            "/tmp/harness-codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/custom/bin/codex",
            "/second/bin/codex",
        ])
    }

    func testDuplicatePATHCandidateIsRemovedWithoutChangingPriority() {
        let candidates = CodexBinaryResolver.candidateURLs(
            override: nil,
            environment: ["PATH": "/usr/local/bin:/custom/bin"]
        ).map(\.path)

        XCTAssertEqual(candidates.filter { $0 == "/usr/local/bin/codex" }.count, 1)
        XCTAssertEqual(candidates.last, "/custom/bin/codex")
    }
}
