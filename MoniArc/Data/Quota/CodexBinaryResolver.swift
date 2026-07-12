import Foundation

enum CodexBinaryResolver {
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
        paths.append(contentsOf: fixedCandidatePaths)

        if let path = environment["PATH"] {
            paths.append(contentsOf: path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
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
        fileManager: FileManager = .default
    ) -> URL? {
        candidateURLs(override: override, environment: environment)
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
