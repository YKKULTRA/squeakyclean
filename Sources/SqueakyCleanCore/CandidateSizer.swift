import Foundation

// Computes real on-disk sizes for cleanup candidates whose underlying artifact
// is a directory. The InventoryService deliberately stamps directories at 0
// bytes during enumeration (cheap top-level walk); the sizer fills those in
// for things the user might actually approve, so the "X recoverable" headline
// reflects reality. Blocked items are intentionally skipped — they will never
// be acted on, so paying the I/O cost would be wasted work.
public struct CandidateSizer: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func sized(_ candidates: [CleanupCandidate]) throws -> [CleanupCandidate] {
        try candidates.map { candidate in
            try Task.checkCancellation()
            return try resized(candidate)
        }
    }

    private func resized(_ candidate: CleanupCandidate) throws -> CleanupCandidate {
        let artifact = candidate.artifact

        // Files that already have a non-zero size were measured during scan;
        // trust that value to avoid re-statting.
        guard artifact.sizeInBytes == 0, isDirectory(artifact.url) else {
            return candidate
        }

        let resolvedSize = try directorySize(at: artifact.url)
        let updatedArtifact = DiscoveredArtifact(
            id: artifact.id,
            url: artifact.url,
            kind: artifact.kind,
            sizeInBytes: resolvedSize,
            lastModifiedAt: artifact.lastModifiedAt,
            metadata: artifact.metadata
        )
        return CleanupCandidate(
            id: candidate.id,
            artifact: updatedArtifact,
            riskTier: candidate.riskTier,
            proposedAction: candidate.proposedAction,
            reason: candidate.reason,
            evidence: candidate.evidence
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func directorySize(at url: URL) throws -> Int64 {
        let resourceKeys: [URLResourceKey] = [
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSURLErrorKey: url]
            )
        }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            try Task.checkCancellation()
            let values = try childURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.totalFileSize
                    ?? values.fileSize
                    ?? 0
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return total
    }
}
