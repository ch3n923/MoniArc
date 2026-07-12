import Darwin
import Foundation

struct CodexLaunchPlan: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
}

enum CodexLaunchPlanner {
    static func make(
        override: URL?,
        environment: [String: String],
        fileManager: FileManager = .default,
        currentUID: UInt32 = UInt32(getuid())
    ) -> CodexLaunchPlan? {
        guard let executableURL = CodexBinaryResolver.resolve(
            override: override,
            environment: environment,
            fileManager: fileManager,
            currentUID: currentUID
        ) else {
            return nil
        }

        return CodexLaunchPlan(
            executableURL: executableURL,
            arguments: ["app-server", "--stdio"],
            environment: CodexSubprocessEnvironment.sanitized(
                environment,
                executableURL: executableURL,
                fileManager: fileManager,
                currentUID: currentUID
            )
        )
    }
}

/// Accepts an executable only when both its lexical location and resolved
/// target are controlled by root or the current user and are not publicly
/// replaceable. This preserves safe Homebrew, npm, nvm, asdf and mise installs
/// without silently trusting arbitrary world-writable PATH entries.
enum CodexExecutableTrust {
    static func canonicalTrustedURL(
        for candidate: URL,
        fileManager: FileManager = .default,
        currentUID: UInt32 = UInt32(getuid())
    ) -> URL? {
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            return nil
        }

        let lexicalURL = candidate.standardizedFileURL
        guard
            lexicalChainIsSafe(
                from: lexicalURL.deletingLastPathComponent(),
                currentUID: currentUID
            ),
            finalLexicalNodeIsSafe(at: lexicalURL, currentUID: currentUID)
        else {
            return nil
        }

        let canonicalURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        guard
            fileManager.isExecutableFile(atPath: canonicalURL.path),
            let target = metadata(at: canonicalURL, followingSymlink: true),
            target.fileType == S_IFREG,
            metadataIsSafe(target, currentUID: currentUID),
            lexicalChainIsSafe(
                from: canonicalURL.deletingLastPathComponent(),
                currentUID: currentUID
            )
        else {
            return nil
        }

        return canonicalURL
    }

    static func trustedSearchDirectory(
        _ directory: URL,
        currentUID: UInt32 = UInt32(getuid())
    ) -> URL? {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            return nil
        }

        let lexicalURL = directory.standardizedFileURL
        guard lexicalChainIsSafe(from: lexicalURL, currentUID: currentUID) else {
            return nil
        }

        let canonicalURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        guard
            let target = metadata(at: canonicalURL, followingSymlink: true),
            target.fileType == S_IFDIR,
            directoryMetadataIsSafe(
                target,
                at: canonicalURL,
                currentUID: currentUID
            ),
            lexicalChainIsSafe(from: canonicalURL, currentUID: currentUID)
        else {
            return nil
        }
        return canonicalURL
    }

    private struct NodeMetadata {
        let owner: UInt32
        let group: UInt32
        let mode: mode_t

        var fileType: mode_t {
            mode & mode_t(S_IFMT)
        }
    }

    private static func metadata(
        at url: URL,
        followingSymlink: Bool
    ) -> NodeMetadata? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let flags = followingSymlink ? 0 : AT_SYMLINK_NOFOLLOW
            return Darwin.fstatat(AT_FDCWD, path, &value, flags)
        }
        guard result == 0 else { return nil }
        return NodeMetadata(
            owner: UInt32(value.st_uid),
            group: UInt32(value.st_gid),
            mode: value.st_mode
        )
    }

    private static func lexicalChainIsSafe(
        from startingURL: URL,
        currentUID: UInt32
    ) -> Bool {
        var current = startingURL.standardizedFileURL
        while true {
            guard let node = metadata(at: current, followingSymlink: false) else {
                return false
            }

            if node.fileType == S_IFLNK {
                guard
                    let target = metadata(at: current, followingSymlink: true),
                    target.fileType == S_IFDIR,
                    directoryMetadataIsSafe(
                        target,
                        at: current,
                        currentUID: currentUID
                    )
                else {
                    return false
                }
            } else {
                guard
                    node.fileType == S_IFDIR,
                    directoryMetadataIsSafe(
                        node,
                        at: current,
                        currentUID: currentUID
                    )
                else {
                    return false
                }
            }

            if current.path == "/" {
                return true
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { return false }
            current = parent
        }
    }

    private static func finalLexicalNodeIsSafe(
        at url: URL,
        currentUID: UInt32
    ) -> Bool {
        guard let node = metadata(at: url, followingSymlink: false) else {
            return false
        }
        if node.fileType == S_IFLNK {
            return true
        }
        return node.fileType == S_IFREG
            && metadataIsSafe(node, currentUID: currentUID)
    }

    private static func metadataIsSafe(
        _ node: NodeMetadata,
        currentUID: UInt32
    ) -> Bool {
        guard node.owner == 0 || node.owner == currentUID else {
            return false
        }
        if node.mode & mode_t(S_IWOTH) != 0 {
            return false
        }
        if node.mode & mode_t(S_IWGRP) != 0, node.owner != currentUID {
            return false
        }
        return true
    }

    private static func directoryMetadataIsSafe(
        _ node: NodeMetadata,
        at url: URL,
        currentUID: UInt32
    ) -> Bool {
        guard node.owner == 0 || node.owner == currentUID else {
            return false
        }
        guard node.mode & mode_t(S_IWOTH) == 0 else {
            return false
        }
        guard node.mode & mode_t(S_IWGRP) != 0 else {
            return true
        }

        if node.owner == currentUID {
            return true
        }

        // macOS ships /Applications as root:admin 0775. It is the documented
        // location of the signed ChatGPT bundle and is the only root-owned,
        // group-writable parent accepted by the resolver.
        return node.owner == 0
            && node.group == 80
            && url.standardizedFileURL.path == "/Applications"
    }
}

/// Limits what MoniArc forwards to the dedicated Codex subprocess. This keeps
/// unrelated credentials and loader hooks out of a process that only needs
/// local Codex account and rate-limit access.
enum CodexSubprocessEnvironment {
    private static let exactKeys: Set<String> = [
        "ALL_PROXY",
        "HOME",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "LANG",
        "LOGNAME",
        "NO_PROXY",
        "SHELL",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "TMPDIR",
        "TZ",
        "USER",
        "all_proxy",
        "https_proxy",
        "http_proxy",
        "no_proxy",
    ]

    private static let allowedPrefixes = [
        "CODEX_",
        "LC_",
        "OPENAI_",
        "XDG_",
    ]

    private static let baselineSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func sanitized(
        _ environment: [String: String],
        executableURL: URL,
        fileManager: FileManager = .default,
        currentUID: UInt32 = UInt32(getuid())
    ) -> [String: String] {
        var sanitized = environment.filter { key, _ in
            exactKeys.contains(key)
                || allowedPrefixes.contains(where: key.hasPrefix)
        }

        var searchDirectories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        searchDirectories.append(executableURL.deletingLastPathComponent().path)
        searchDirectories.append(contentsOf: baselineSearchDirectories)

        var seen = Set<String>()
        let safeSearchPath = searchDirectories.compactMap { path -> String? in
            guard path.hasPrefix("/") else { return nil }
            guard let trusted = CodexExecutableTrust.trustedSearchDirectory(
                URL(fileURLWithPath: path),
                currentUID: currentUID
            ) else {
                return nil
            }
            guard fileManager.fileExists(atPath: trusted.path),
                  seen.insert(trusted.path).inserted
            else {
                return nil
            }
            return trusted.path
        }
        sanitized["PATH"] = safeSearchPath.joined(separator: ":")
        return sanitized
    }
}
