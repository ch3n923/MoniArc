import Foundation
import XCTest
@testable import MoniArc

final class CodexSubprocessEnvironmentTests: XCTestCase {
    func testKeepsOnlySystemCodexOpenAIAndNetworkConfiguration() {
        let environment = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin",
            "CODEX_HOME": "/Users/tester/.codex",
            "OPENAI_API_KEY": "openai-secret",
            "LC_ALL": "zh_CN.UTF-8",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "XDG_CONFIG_HOME": "/Users/tester/.config",
        ]

        let sanitized = CodexSubprocessEnvironment.sanitized(
            environment,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        for (key, value) in environment where key != "PATH" {
            XCTAssertEqual(sanitized[key], value)
        }
        let searchPath = sanitized["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(searchPath.contains("/usr/bin"))
        XCTAssertTrue(searchPath.contains("/bin"))
    }

    func testDropsUnrelatedCredentialsAndLoaderOverrides() {
        let sanitized = CodexSubprocessEnvironment.sanitized(
            [
                "HOME": "/Users/tester",
                "AWS_SECRET_ACCESS_KEY": "aws-secret",
                "GITHUB_TOKEN": "github-secret",
                "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
            ],
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        XCTAssertEqual(sanitized["HOME"], "/Users/tester")
        XCTAssertNil(sanitized["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(sanitized["GITHUB_TOKEN"])
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
    }

    func testSearchPathDropsRelativeAndWorldWritableDirectories() {
        let sanitized = CodexSubprocessEnvironment.sanitized(
            ["PATH": "relative:/tmp:/usr/bin"],
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let searchPath = sanitized["PATH"]?.split(separator: ":").map(String.init) ?? []

        XCTAssertFalse(searchPath.contains("relative"))
        XCTAssertFalse(searchPath.contains("/tmp"))
        XCTAssertTrue(searchPath.contains("/usr/bin"))
    }
}
