import Foundation
@testable import SqueakyCleanCore

struct TemporaryDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

func testCleanupPathPolicy(
    in sandbox: TemporaryDirectory,
    protecting storeRoot: URL
) -> CleanupPathPolicy {
    CleanupPathPolicy(
        allowedRoots: [sandbox.url],
        protectedRoots: [storeRoot]
    )
}

func testArtifactMetadata(
    at url: URL,
    ownerHint: String? = nil,
    fileManager: FileManager = .default
) -> ArtifactMetadata {
    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    return ArtifactMetadata(
        ownerHint: ownerHint,
        fileSystemNumber: (attributes?[.systemNumber] as? NSNumber)?.uint64Value,
        fileSystemFileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value,
        isSymbolicLink: try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
    )
}

func testModificationDate(
    at url: URL,
    fileManager: FileManager = .default
) -> Date {
    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    return attributes?[.modificationDate] as? Date ?? .distantPast
}
