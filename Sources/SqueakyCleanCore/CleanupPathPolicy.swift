import Foundation

public enum CleanupPathPolicyError: Error, LocalizedError {
    case noAllowedRoots
    case outsideAllowedRoots(URL)
    case protectedPath(URL)
    case symbolicLink(URL)
    case unverifiableIdentity(URL)
    case changedSinceScan(URL)
    case evidenceChanged(URL)
    case invalidAction(CleanupAction)

    public var errorDescription: String? {
        switch self {
        case .noAllowedRoots:
            return "Cleanup is disabled because no writable roots were configured."
        case .outsideAllowedRoots(let url):
            return "The item is outside the configured cleanup roots: \(url.path)"
        case .protectedPath(let url):
            return "The item overlaps an app-managed or protected path: \(url.path)"
        case .symbolicLink(let url):
            return "Symbolic links are not eligible for cleanup: \(url.path)"
        case .unverifiableIdentity(let url):
            return "The scan could not record a stable filesystem identity for this item. Run a new scan before trying again: \(url.path)"
        case .changedSinceScan(let url):
            return "The item changed since it was scanned. Run a new scan before trying again: \(url.path)"
        case .evidenceChanged(let url):
            return "The cleanup evidence changed or can no longer be confirmed. Run a new scan before trying again: \(url.path)"
        case .invalidAction(let action):
            return "The candidate does not authorize quarantine; its proposed action is \(action.rawValue)."
        }
    }
}

/// Enforces the cleanup boundary again at approval time. Scan classification is
/// advisory; this policy is the destructive-operation gate.
public struct CleanupPathPolicy: Sendable {
    public let allowedRoots: [URL]
    public let protectedRoots: [URL]

    public init(allowedRoots: [URL], protectedRoots: [URL] = []) {
        self.allowedRoots = allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.protectedRoots = protectedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    public func validate(candidate: CleanupCandidate, fileManager: FileManager) throws -> URL {
        guard candidate.proposedAction == .quarantine else {
            throw CleanupPathPolicyError.invalidAction(candidate.proposedAction)
        }

        let sourceURL = candidate.artifact.url.standardizedFileURL
        let values = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true, candidate.artifact.metadata.isSymbolicLink != true else {
            throw CleanupPathPolicyError.symbolicLink(sourceURL)
        }

        let canonicalSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        try validateLocation(canonicalSource)
        try validateIdentity(candidate.artifact, at: canonicalSource, fileManager: fileManager)
        try validateEvidence(candidate, fileManager: fileManager)
        return canonicalSource
    }

    public func validateRestoreDestination(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonical = parent
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
            .standardizedFileURL
        try validateLocation(canonical)
        return canonical
    }

    private func validateLocation(_ url: URL) throws {
        guard !allowedRoots.isEmpty else {
            throw CleanupPathPolicyError.noAllowedRoots
        }
        guard allowedRoots.contains(where: { isStrictDescendant(url, of: $0) }) else {
            throw CleanupPathPolicyError.outsideAllowedRoots(url)
        }
        guard !protectedRoots.contains(where: {
            isSameOrDescendant(url, of: $0) || isSameOrDescendant($0, of: url)
        }) else {
            throw CleanupPathPolicyError.protectedPath(url)
        }
    }

    private func validateIdentity(
        _ artifact: DiscoveredArtifact,
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard
            let expectedSystem = artifact.metadata.fileSystemNumber,
            let expectedFile = artifact.metadata.fileSystemFileNumber
        else {
            throw CleanupPathPolicyError.unverifiableIdentity(url)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let currentSystem = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let currentFile = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard currentSystem == expectedSystem,
              currentFile == expectedFile else {
            throw CleanupPathPolicyError.changedSinceScan(url)
        }

        if let modifiedAt = attributes[.modificationDate] as? Date,
           abs(modifiedAt.timeIntervalSince(artifact.lastModifiedAt)) > 0.001 {
            throw CleanupPathPolicyError.changedSinceScan(url)
        }
    }

    private func validateEvidence(
        _ candidate: CleanupCandidate,
        fileManager: FileManager
    ) throws {
        guard candidate.evidence.code == "dead-launch-item" else { return }
        guard
            candidate.artifact.metadata.launchTargetExists == false,
            let targetPath = candidate.artifact.metadata.launchTargetPath,
            LaunchTargetInspector.availability(at: targetPath, fileManager: fileManager) == .missing
        else {
            throw CleanupPathPolicyError.evidenceChanged(candidate.artifact.url)
        }
    }

    private func isStrictDescendant(_ url: URL, of root: URL) -> Bool {
        url.path != root.path && isSameOrDescendant(url, of: root)
    }

    private func isSameOrDescendant(_ url: URL, of root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
