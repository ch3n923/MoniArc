import Foundation
import XCTest
@testable import MoniArc

final class CodexExecutableTrustTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        let caches = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        testRoot = caches.appendingPathComponent("MoniArcTrustTests-(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: testRoot.path
        )
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testAcceptsExecutableOwnedByCurrentUserInSafeDirectory() throws {
        let executable = try makeExecutable(named: "codex")

        XCTAssertEqual(
            CodexExecutableTrust.canonicalTrustedURL(for: executable),
            executable.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    func testRejectsWorldWritableExecutable() throws {
        let executable = try makeExecutable(named: "codex", permissions: 0o707)

        XCTAssertNil(CodexExecutableTrust.canonicalTrustedURL(for: executable))
    }

    func testRejectsExecutableInsideWorldWritableDirectory() throws {
        let unsafeDirectory = testRoot.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeDirectory.path
        )
        let executable = try makeExecutable(
            named: "codex",
            directory: unsafeDirectory
        )

        XCTAssertNil(CodexExecutableTrust.canonicalTrustedURL(for: executable))
    }

    func testSafeSymlinkResolvesToCanonicalExecutable() throws {
        let target = try makeExecutable(named: "codex-target")
        let link = testRoot.appendingPathComponent("codex-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        XCTAssertEqual(
            CodexExecutableTrust.canonicalTrustedURL(for: link),
            target.standardizedFileURL
        )
    }

    func testRejectsSearchDirectorySymlinkedToWorldWritableTarget() throws {
        let unsafeDirectory = testRoot.appendingPathComponent("unsafe-search")
        try FileManager.default.createDirectory(
            at: unsafeDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: unsafeDirectory.path
        )
        let link = testRoot.appendingPathComponent("search-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: unsafeDirectory
        )

        XCTAssertNil(CodexExecutableTrust.trustedSearchDirectory(link))
    }

    func testInstalledChatGPTCodexIsAcceptedWhenPresent() throws {
        let bundledCodex = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
        guard FileManager.default.fileExists(atPath: bundledCodex.path) else {
            throw XCTSkip("ChatGPT is not installed on this test machine")
        }

        XCTAssertNotNil(CodexExecutableTrust.canonicalTrustedURL(for: bundledCodex))
    }

    func testLaunchPlanUsesTrustedOverrideAndDropsUnrelatedCredentials() throws {
        let executable = try makeExecutable(named: "codex")
        let plan = try XCTUnwrap(CodexLaunchPlanner.make(
            override: executable,
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": testRoot.path,
                "OPENAI_API_KEY": "openai-secret",
                "GITHUB_TOKEN": "github-secret",
            ]
        ))

        XCTAssertEqual(plan.executableURL, executable.standardizedFileURL)
        XCTAssertEqual(plan.arguments, ["app-server", "--stdio"])
        XCTAssertEqual(plan.environment["OPENAI_API_KEY"], "openai-secret")
        XCTAssertNil(plan.environment["GITHUB_TOKEN"])
        XCTAssertTrue(plan.environment["PATH"]?.contains(testRoot.path) == true)
    }

    private func makeExecutable(
        named name: String,
        directory: URL? = nil,
        permissions: Int = 0o700
    ) throws -> URL {
        let url = (directory ?? testRoot).appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        return url
    }
}
