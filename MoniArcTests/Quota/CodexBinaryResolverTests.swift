import Foundation
import XCTest
@testable import MoniArc

final class CodexBinaryResolverTests: XCTestCase {
    func testCandidateOrderIncludesSafeToInspectPATHLocationsLast() {
        let override = URL(fileURLWithPath: "/tmp/harness-codex")
        let candidates = CodexBinaryResolver.candidateURLs(
            override: override,
            environment: [
                CodexBinaryResolver.overrideEnvironmentKey: "/custom/bin/codex",
                "PATH": "/untrusted/bin:/second/bin",
            ]
        ).map(\.path)

        XCTAssertEqual(candidates, [
            "/tmp/harness-codex",
            "/custom/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/untrusted/bin/codex",
            "/second/bin/codex",
        ])
    }

    func testPATHAddsAbsoluteCandidatesAndDeduplicatesDocumentedLocations() {
        let candidates = CodexBinaryResolver.candidateURLs(
            override: nil,
            environment: ["PATH": "/usr/local/bin:/custom/bin"]
        ).map(\.path)

        XCTAssertEqual(candidates, [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/custom/bin/codex",
        ])
    }

    func testRelativeEnvironmentOverrideIsIgnored() {
        let candidates = CodexBinaryResolver.candidateURLs(
            override: nil,
            environment: [CodexBinaryResolver.overrideEnvironmentKey: "relative/codex"]
        ).map(\.path)

        XCTAssertEqual(candidates, CodexBinaryResolver.fixedCandidatePaths)
    }

    func testDuplicateExplicitCandidateIsRemovedWithoutChangingPriority() {
        let override = URL(fileURLWithPath: "/usr/local/bin/codex")
        let candidates = CodexBinaryResolver.candidateURLs(
            override: override,
            environment: [:]
        ).map(\.path)

        XCTAssertEqual(candidates.filter { $0 == "/usr/local/bin/codex" }.count, 1)
        XCTAssertEqual(candidates.first, "/usr/local/bin/codex")
    }
}
