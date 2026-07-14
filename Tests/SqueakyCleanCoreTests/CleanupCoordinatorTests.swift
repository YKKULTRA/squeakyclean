import CryptoKit
import Foundation
import Testing
@testable import SqueakyCleanCore

struct CleanupCoordinatorTests {
    @Test
    func multiChunkFileHashesIdenticallyToWholeBufferSHA256() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        // Write a payload larger than the streaming chunk so we exercise
        // multiple read passes through the FileHandle.
        let chunkSize = 1 << 20
        let bigData = Data((0..<(chunkSize * 2 + 17)).map { UInt8($0 & 0xFF) })
        let originalFile = sourceRoot.appending(path: "big.cache")
        try bigData.write(to: originalFile)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: originalFile,
                kind: .cache,
                sizeInBytes: Int64(bigData.count),
                lastModifiedAt: testModificationDate(at: originalFile),
                metadata: testArtifactMetadata(at: originalFile, ownerHint: "com.example.OldApp")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-cache", summary: "...")
        )

        let store = try QuarantineStore(baseURL: storeRoot)
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        )
        let record = try cleanup.quarantine(candidate: candidate)

        var fingerprintInput = Data("squeakyclean-v2|file\n".utf8)
        fingerprintInput.append(bigData)
        let expected = SHA256.hash(data: fingerprintInput)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        #expect(record.contentHash == expected)
    }

    @Test
    func directoryManifestUsesPrefixStripNotGlobalReplace() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        // The directory and a child use the same name so a naive
        // replacingOccurrences(of: parent, with: "") would zero out both.
        let cacheDir = sourceRoot.appending(path: "node_modules", directoryHint: .isDirectory)
        let nestedRepeat = cacheDir.appending(path: "pkg/node_modules/leaf.js")
        try FileManager.default.createDirectory(at: nestedRepeat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: nestedRepeat)
        try Data("beta".utf8).write(to: cacheDir.appending(path: "manifest"))

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: cacheDir,
                kind: .cache,
                sizeInBytes: 0,
                lastModifiedAt: testModificationDate(at: cacheDir),
                metadata: testArtifactMetadata(at: cacheDir, ownerHint: "node_modules")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-cache", summary: "...")
        )

        let store = try QuarantineStore(baseURL: storeRoot)
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        )
        let firstRecord = try cleanup.quarantine(candidate: candidate)

        // Recreate the same content at a different absolute location and quarantine
        // it. Because the relative manifest is what we hash, the fingerprints must
        // still match — proving the prefix strip is anchored, not a global replace.
        let twinRoot = sandbox.url.appending(path: "Twin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: twinRoot, withIntermediateDirectories: true)
        let twinDir = twinRoot.appending(path: "node_modules", directoryHint: .isDirectory)
        let twinNested = twinDir.appending(path: "pkg/node_modules/leaf.js")
        try FileManager.default.createDirectory(at: twinNested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: twinNested)
        try Data("beta".utf8).write(to: twinDir.appending(path: "manifest"))

        let twinCandidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: twinDir,
                kind: .cache,
                sizeInBytes: 0,
                lastModifiedAt: testModificationDate(at: twinDir),
                metadata: testArtifactMetadata(at: twinDir, ownerHint: "node_modules")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-cache", summary: "...")
        )
        let twinRecord = try cleanup.quarantine(candidate: twinCandidate)

        #expect(firstRecord.contentHash == twinRecord.contentHash)
    }


    @Test
    func quarantineAndRestoreRoundTrip() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let originalFile = sourceRoot.appending(path: "orphaned.log")
        try Data("stale".utf8).write(to: originalFile)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: originalFile,
                kind: .log,
                sizeInBytes: 5,
                lastModifiedAt: testModificationDate(at: originalFile),
                metadata: testArtifactMetadata(at: originalFile, ownerHint: "com.example.OldApp")
            ),
            riskTier: .safe,
            proposedAction: .quarantine,
            reason: "Orphaned log data",
            evidence: RuleEvidence(
                code: "orphaned-log",
                summary: "Belongs to an app that is no longer installed."
            )
        )

        let quarantineStore = try QuarantineStore(baseURL: storeRoot)
        let pathPolicy = testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        let cleanupCoordinator = CleanupCoordinator(
            quarantineStore: quarantineStore,
            pathPolicy: pathPolicy
        )
        let restoreCoordinator = RestoreCoordinator(
            quarantineStore: quarantineStore,
            pathPolicy: pathPolicy
        )

        let record = try cleanupCoordinator.quarantine(candidate: candidate)

        #expect(FileManager.default.fileExists(atPath: originalFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: record.quarantinedURL.path))
        #expect(record.reason == candidate.reason)
        #expect(record.evidenceSummary == candidate.evidence.summary)

        let restoredURL = try restoreCoordinator.restore(recordID: record.id)

        #expect(restoredURL == originalFile)
        #expect(FileManager.default.fileExists(atPath: originalFile.path))
        #expect(try Data(contentsOf: originalFile) == Data("stale".utf8))
    }

    @Test
    func purgeRemovesPayloadAndManifestEntry() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let originalFile = sourceRoot.appending(path: "ghost.cache")
        try Data("doomed".utf8).write(to: originalFile)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: originalFile,
                kind: .cache,
                sizeInBytes: 6,
                lastModifiedAt: testModificationDate(at: originalFile),
                metadata: testArtifactMetadata(at: originalFile, ownerHint: "com.example.OldApp")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-cache", summary: "...")
        )

        let store = try QuarantineStore(baseURL: storeRoot)
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        )

        let record = try cleanup.quarantine(candidate: candidate)
        #expect(FileManager.default.fileExists(atPath: record.quarantinedURL.path))
        #expect(try store.allRecords().count == 1)

        try cleanup.purge(recordID: record.id)

        #expect(FileManager.default.fileExists(atPath: record.quarantinedURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: record.quarantinedURL.deletingLastPathComponent().path) == false)
        #expect(try store.allRecords().isEmpty)
    }

    @Test
    func purgeAllOnlyClearsStillQuarantinedItems() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let firstFile = sourceRoot.appending(path: "first.log")
        let secondFile = sourceRoot.appending(path: "second.log")
        try Data("one".utf8).write(to: firstFile)
        try Data("two".utf8).write(to: secondFile)

        func candidate(at url: URL) -> CleanupCandidate {
            CleanupCandidate(
                artifact: DiscoveredArtifact(
                    url: url,
                    kind: .log,
                    sizeInBytes: 3,
                    lastModifiedAt: testModificationDate(at: url),
                    metadata: testArtifactMetadata(at: url, ownerHint: "com.example.OldApp")
                ),
                riskTier: .review,
                proposedAction: .quarantine,
                reason: "Orphaned log data",
                evidence: RuleEvidence(code: "orphaned-log", summary: "...")
            )
        }

        let store = try QuarantineStore(baseURL: storeRoot)
        let pathPolicy = testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        let cleanup = CleanupCoordinator(quarantineStore: store, pathPolicy: pathPolicy)
        let restore = RestoreCoordinator(quarantineStore: store, pathPolicy: pathPolicy)

        let firstRecord = try cleanup.quarantine(candidate: candidate(at: firstFile))
        let secondRecord = try cleanup.quarantine(candidate: candidate(at: secondFile))

        // Restore the first one — it should survive purgeAll as audit history.
        _ = try restore.restore(recordID: firstRecord.id)

        let purged = try cleanup.purgeAll()

        #expect(purged.count == 1)
        #expect(purged.first?.id == secondRecord.id)
        let remaining = try store.allRecords()
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == firstRecord.id)
        #expect(remaining.first?.status == .restored)
        #expect(FileManager.default.fileExists(atPath: secondRecord.quarantinedURL.path) == false)
    }

    @Test
    func purgeIsIdempotentWhenPayloadAlreadyRemoved() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let originalFile = sourceRoot.appending(path: "ghost.cache")
        try Data("doomed".utf8).write(to: originalFile)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: originalFile,
                kind: .cache,
                sizeInBytes: 6,
                lastModifiedAt: testModificationDate(at: originalFile),
                metadata: testArtifactMetadata(at: originalFile, ownerHint: "com.example.OldApp")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-cache", summary: "...")
        )

        let store = try QuarantineStore(baseURL: storeRoot)
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        )

        let record = try cleanup.quarantine(candidate: candidate)
        // Simulate an external mutation that removed the payload behind our back.
        try FileManager.default.removeItem(at: record.quarantinedURL)

        try cleanup.purge(recordID: record.id)
        #expect(try store.allRecords().isEmpty)
    }

    @Test
    func restoreCollisionCreatesUniquePath() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appending(path: "Source", directoryHint: .isDirectory)
        let storeRoot = sandbox.url.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

        let originalFile = sourceRoot.appending(path: "leftover.cache")
        try Data("first".utf8).write(to: originalFile)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: originalFile,
                kind: .cache,
                sizeInBytes: 5,
                lastModifiedAt: testModificationDate(at: originalFile),
                metadata: testArtifactMetadata(at: originalFile, ownerHint: "com.example.OldApp")
            ),
            riskTier: .safe,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(
                code: "orphaned-cache",
                summary: "Belongs to an app that is no longer installed."
            )
        )

        let quarantineStore = try QuarantineStore(baseURL: storeRoot)
        let pathPolicy = testCleanupPathPolicy(in: sandbox, protecting: storeRoot)
        let cleanupCoordinator = CleanupCoordinator(
            quarantineStore: quarantineStore,
            pathPolicy: pathPolicy
        )
        let restoreCoordinator = RestoreCoordinator(
            quarantineStore: quarantineStore,
            pathPolicy: pathPolicy
        )

        let record = try cleanupCoordinator.quarantine(candidate: candidate)
        try Data("replacement".utf8).write(to: originalFile)

        let restoredURL = try restoreCoordinator.restore(recordID: record.id)

        #expect(restoredURL != originalFile)
        #expect(restoredURL.lastPathComponent.contains("restored"))
        #expect(try Data(contentsOf: restoredURL) == Data("first".utf8))
        #expect(try Data(contentsOf: originalFile) == Data("replacement".utf8))
    }
}
