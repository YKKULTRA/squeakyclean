import Foundation
import Testing
@testable import SqueakyCleanCore

struct CandidateSizerTests {
    @Test
    func cancellingTheTaskAbortsSizing() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        var candidates: [CleanupCandidate] = []
        for i in 0..<50 {
            let dir = sandbox.url.appendingPathComponent("dir_\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 1024).write(to: dir.appendingPathComponent("blob"))
            candidates.append(
                CleanupCandidate(
                    artifact: DiscoveredArtifact(
                        url: dir,
                        kind: .cache,
                        sizeInBytes: 0,
                        lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        metadata: ArtifactMetadata(ownerHint: "owner_\(i)")
                    ),
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Orphaned cache",
                    evidence: RuleEvidence(code: "orphaned-purgeable", summary: "...")
                )
            )
        }

        let sizer = CandidateSizer()
        let task = Task { try sizer.sized(candidates) }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled sizer to throw CancellationError.")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func directoryCandidateGetsSummedSize() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let cacheDir = sandbox.url.appendingPathComponent("com.example.OldApp", isDirectory: true)
        let nested = cacheDir.appendingPathComponent("v1/blob.bin")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4_096).write(to: nested)
        try Data(repeating: 0xCD, count: 1_024).write(to: cacheDir.appendingPathComponent("manifest"))

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: cacheDir,
                kind: .cache,
                sizeInBytes: 0,
                lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: ArtifactMetadata(ownerHint: "com.example.OldApp")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-purgeable", summary: "...")
        )

        let resized = try CandidateSizer().sized([candidate])

        #expect(resized.count == 1)
        #expect(resized[0].id == candidate.id)
        // The product reports allocated bytes rather than logical payload bytes.
        // Allocation granularity is filesystem-dependent, but it must account
        // for at least all 5,120 logical bytes in the fixture.
        #expect(resized[0].artifact.sizeInBytes >= 5_120)
    }

    @Test
    func nonZeroFileSizeIsLeftUntouched() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let plistURL = sandbox.url.appendingPathComponent("com.example.OldApp.plist")
        try Data(repeating: 0x01, count: 256).write(to: plistURL)

        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: plistURL,
                kind: .preference,
                sizeInBytes: 256,
                lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: ArtifactMetadata(ownerHint: "com.example.OldApp")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Preference file for a removed app",
            evidence: RuleEvidence(code: "orphaned-preference", summary: "...")
        )

        let resized = try CandidateSizer().sized([candidate])

        #expect(resized[0].artifact.sizeInBytes == 256)
    }

    @Test
    func missingDirectoryFallsBackToZeroWithoutThrowing() throws {
        let candidate = CleanupCandidate(
            artifact: DiscoveredArtifact(
                url: URL(fileURLWithPath: "/tmp/SqueakyCleanTests/does-not-exist-\(UUID().uuidString)"),
                kind: .cache,
                sizeInBytes: 0,
                lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: ArtifactMetadata(ownerHint: "ghost")
            ),
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Orphaned cache",
            evidence: RuleEvidence(code: "orphaned-purgeable", summary: "...")
        )

        let resized = try CandidateSizer().sized([candidate])

        #expect(resized[0].artifact.sizeInBytes == 0)
    }
}
