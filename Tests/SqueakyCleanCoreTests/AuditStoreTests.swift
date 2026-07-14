import Foundation
import Testing
@testable import SqueakyCleanCore

struct AuditStoreTests {
    @Test
    func auditStorePersistsSnapshotsAndApprovals() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let store = try AuditStore(baseURL: sandbox.url)
        let snapshot = ScanSnapshotRecord(
            scannedAt: Date(timeIntervalSince1970: 1_800_000_000),
            scope: .deep,
            scannedArtifactCount: 10,
            candidateCount: 2,
            blockedCount: 3,
            inaccessibleRootCount: 1
        )
        let approval = ApprovalRecord(
            executedAt: Date(timeIntervalSince1970: 1_800_000_100),
            artifactURL: URL(fileURLWithPath: "/tmp/orphaned.log"),
            action: .quarantine,
            reason: "Orphaned log data",
            evidenceSummary: "Belongs to an app that is no longer installed."
        )

        try store.append(snapshot: snapshot)
        try store.append(approval: approval)

        let snapshots = try store.loadScanSnapshots()
        let approvals = try store.loadApprovals()

        #expect(snapshots == [snapshot])
        #expect(approvals == [approval])
    }

    @Test
    func concurrentApprovalAppendsDoNotLoseEvents() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let store = try AuditStore(baseURL: sandbox.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try store.append(
                        approval: ApprovalRecord(
                            executedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                            artifactURL: sandbox.url.appendingPathComponent("item-\(index)"),
                            action: .quarantine,
                            reason: "Concurrent test",
                            evidenceSummary: "Event \(index)"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let approvals = try store.loadApprovals()
        #expect(approvals.count == 50)
        #expect(Set(approvals.map(\.evidenceSummary)).count == 50)
    }
}
