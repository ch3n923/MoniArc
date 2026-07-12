import Foundation

enum CodexBinaryResolver {
    static let overrideEnvironmentKey = "MONIARC_CODEX_PATH"

    static let fixedCandidatePaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    ]

    static func candidateURLs(
        override: URL?,
        environment: [String: String]
    ) -> [URL] {
        var paths: [String] = []
        if let override {
            paths.append(override.path)
        }
        if let environmentOverride = environment[overrideEnvironmentKey],
           environmentOverride.hasPrefix("/")
        {
            paths.append(environmentOverride)
        }
        paths.append(contentsOf: fixedCandidatePaths)

        if let searchPath = environment["PATH"] {
            paths.append(contentsOf: searchPath
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path })
        }

        var seen: Set<String> = []
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    static func resolve(
        override: URL?,
        environment: [String: String],
        fileManager: FileManager = .default,
        currentUID: UInt32 = UInt32(getuid())
    ) -> URL? {
        var canonicalPaths = Set<String>()
        for candidate in candidateURLs(override: override, environment: environment) {
            guard let trusted = CodexExecutableTrust.canonicalTrustedURL(
                for: candidate,
                fileManager: fileManager,
                currentUID: currentUID
            ) else {
                continue
            }
            if canonicalPaths.insert(trusted.path).inserted {
                return trusted
            }
        }
        return nil
    }
}
