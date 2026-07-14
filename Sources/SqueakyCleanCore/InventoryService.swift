import Foundation

public enum InventoryServiceError: Error {
    case unreadableRoot(URL)
}

public struct LaunchTargetPathResolver: Sendable {
    private let homeDirectory: URL
    private let environment: [String: String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    public func resolve(_ rawPath: String) -> String {
        expandEnvironmentVariables(expandTilde(rawPath))
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let tail = path.dropFirst()
        if tail.isEmpty {
            return homeDirectory.path
        }
        if tail.hasPrefix("/") {
            return homeDirectory.path + tail
        }
        return path
    }

    private func expandEnvironmentVariables(_ path: String) -> String {
        guard path.contains("$") else { return path }

        let nsPath = path as NSString
        let fullRange = NSRange(location: 0, length: nsPath.length)
        var result = ""
        var cursor = 0

        Self.envVarRegex.enumerateMatches(in: path, range: fullRange) { match, _, _ in
            guard let match else { return }
            let matchStart = match.range.location
            let matchEnd = matchStart + match.range.length

            if matchStart > cursor {
                result += nsPath.substring(with: NSRange(location: cursor, length: matchStart - cursor))
            }

            let bracedNameRange = match.range(at: 1)
            let plainNameRange = match.range(at: 2)
            let nameRange = bracedNameRange.location != NSNotFound ? bracedNameRange : plainNameRange
            let varName = nsPath.substring(with: nameRange)

            if let value = environment[varName] {
                result += value
            } else {
                result += nsPath.substring(with: match.range)
            }
            cursor = matchEnd
        }

        if cursor < nsPath.length {
            result += nsPath.substring(with: NSRange(location: cursor, length: nsPath.length - cursor))
        }
        return result
    }

    private static let envVarRegex: NSRegularExpression = {
        // $VAR or ${VAR} where VAR is a typical shell identifier.
        try! NSRegularExpression(pattern: "\\$(?:\\{([A-Za-z_][A-Za-z0-9_]*)\\}|([A-Za-z_][A-Za-z0-9_]*))")
    }()
}

public final class InventoryService: @unchecked Sendable {
    private let fileManager: FileManager
    private let permissionCoordinator: PermissionCoordinator
    private let launchTargetResolver: LaunchTargetPathResolver
    private let blockedPrefixes: [String]

    public init(
        fileManager: FileManager = .default,
        permissionCoordinator: PermissionCoordinator = PermissionCoordinator(),
        launchTargetResolver: LaunchTargetPathResolver = LaunchTargetPathResolver(),
        blockedPrefixes: [String] = [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/private/var/vm",
            "/Volumes/Preboot",
            "/Volumes/VM"
        ]
    ) {
        self.fileManager = fileManager
        self.permissionCoordinator = permissionCoordinator
        self.launchTargetResolver = launchTargetResolver
        self.blockedPrefixes = blockedPrefixes
    }

    public func scan(
        roots: [InventoryRoot],
        scope: ScanScope
    ) throws -> InventorySnapshot {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        let permissionState = permissionCoordinator.evaluate(for: roots, scope: scope)
        let restrictedReasons = Dictionary(uniqueKeysWithValues: permissionState.inaccessibleRoots.map { ($0.root.url.standardizedFileURL.path, $0.reason) })

        var artifacts: [DiscoveredArtifact] = []
        var skippedRoots: [SkippedRoot] = []

        for root in roots where scope.includes(root.minimumScope) {
            try Task.checkCancellation()
            let standardizedPath = root.url.standardizedFileURL.path

            if isBlocked(root.url) {
                skippedRoots.append(
                    SkippedRoot(root: root, reason: "Root is blocked by the system safety policy.")
                )
                continue
            }

            if let restrictedReason = restrictedReasons[standardizedPath] {
                skippedRoots.append(
                    SkippedRoot(root: root, reason: restrictedReason)
                )
                continue
            }

            guard fileManager.fileExists(atPath: standardizedPath) else {
                continue
            }

            let childURLs: [URL]
            do {
                childURLs = try fileManager.contentsOfDirectory(
                    at: root.url,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                skippedRoots.append(
                    SkippedRoot(root: root, reason: "Failed to enumerate root: \(error.localizedDescription)")
                )
                continue
            }

            for childURL in childURLs where !isBlocked(childURL) {
                try Task.checkCancellation()
                guard let resourceValues = try? childURL.resourceValues(forKeys: resourceKeys) else {
                    continue
                }
                let sizeInBytes = itemSizeInBytes(resourceValues: resourceValues)
                let lastModifiedAt = resourceValues.contentModificationDate ?? .distantPast
                let metadata = metadata(for: childURL, root: root)

                artifacts.append(
                    DiscoveredArtifact(
                        url: childURL,
                        kind: root.artifactKind,
                        sizeInBytes: sizeInBytes,
                        lastModifiedAt: lastModifiedAt,
                        metadata: metadata
                    )
                )
            }
        }

        return InventorySnapshot(
            artifacts: artifacts,
            skippedRoots: skippedRoots,
            permissionState: permissionState
        )
    }

    private func isBlocked(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return blockedPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func itemSizeInBytes(resourceValues: URLResourceValues) -> Int64 {
        if resourceValues.isDirectory == true {
            return 0
        }

        return Int64(
            resourceValues.totalFileAllocatedSize
                ?? resourceValues.fileAllocatedSize
                ?? resourceValues.totalFileSize
                ?? resourceValues.fileSize
                ?? 0
        )
    }

    private func metadata(for url: URL, root: InventoryRoot) -> ArtifactMetadata {
        let identity = fileIdentity(for: url)
        let ownerHint: String? = switch root.artifactKind {
        case .applicationSupport, .cache, .log:
            url.lastPathComponent
        case .preference, .launchAgent, .launchDaemon, .installerReceipt:
            url.deletingPathExtension().lastPathComponent
        default:
            nil
        }

        switch root.artifactKind {
        case .launchAgent, .launchDaemon:
            // A malformed plist must never abort the scan. We surface it as a
            // launch item with no resolvable target, which fails closed.
            let rawTargetPath = (try? launchTargetPath(from: url)) ?? nil
            let resolvedTargetPath = rawTargetPath.map { launchTargetResolver.resolve($0) }
            // `launchd` can resolve a bare ProgramArguments command through its
            // executable search path. Checking a relative string against this
            // process's working directory would create a false "missing" result.
            // Only absolute paths provide enough evidence for cleanup.
            let launchTargetExists = resolvedTargetPath.flatMap { path -> Bool? in
                guard (path as NSString).isAbsolutePath else { return nil }
                switch LaunchTargetInspector.availability(at: path, fileManager: fileManager) {
                case .exists:
                    return true
                case .missing:
                    return false
                case .inaccessible:
                    return nil
                }
            }
            return ArtifactMetadata(
                ownerHint: ownerHint,
                launchTargetPath: resolvedTargetPath,
                launchTargetExists: launchTargetExists,
                fileSystemNumber: identity.fileSystemNumber,
                fileSystemFileNumber: identity.fileSystemFileNumber,
                isSymbolicLink: identity.isSymbolicLink
            )
        default:
            return ArtifactMetadata(
                ownerHint: ownerHint,
                fileSystemNumber: identity.fileSystemNumber,
                fileSystemFileNumber: identity.fileSystemFileNumber,
                isSymbolicLink: identity.isSymbolicLink
            )
        }
    }

    private func fileIdentity(for url: URL) -> (
        fileSystemNumber: UInt64?,
        fileSystemFileNumber: UInt64?,
        isSymbolicLink: Bool?
    ) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let fileSystemNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
        let fileSystemFileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        let isSymbolicLink = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        return (fileSystemNumber, fileSystemFileNumber, isSymbolicLink)
    }

    private func launchTargetPath(from plistURL: URL) throws -> String? {
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any] else {
            return nil
        }

        if let program = dictionary["Program"] as? String, !program.isEmpty {
            return program
        }

        if let arguments = dictionary["ProgramArguments"] as? [String], let first = arguments.first, !first.isEmpty {
            return first
        }

        return nil
    }
}
