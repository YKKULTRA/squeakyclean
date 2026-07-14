import Foundation
import Testing
@testable import SqueakyCleanCore

struct ScanCoordinatorTests {
    @Test
    func scanProducesCandidatesAndBlockedFindingsAndPersistsSnapshot() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let launchAgents = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        let appSupport = sandbox.url.appendingPathComponent("Application Support", isDirectory: true)
        let auditRoot = sandbox.url.appendingPathComponent("Audit", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let deadLaunchItem = launchAgents.appendingPathComponent("com.example.OldApp.plist")
        let deadLaunchPlist = try PropertyListSerialization.data(
            fromPropertyList: ["Program": sandbox.url.appendingPathComponent("missing-agent").path],
            format: .xml,
            options: 0
        )
        try deadLaunchPlist.write(to: deadLaunchItem)
        let installedSupport = appSupport.appendingPathComponent("com.example.ActiveApp", isDirectory: true)
        try FileManager.default.createDirectory(at: installedSupport, withIntermediateDirectories: true)

        let roots = [
            InventoryRoot(name: "LaunchAgents", url: launchAgents, artifactKind: .launchAgent, minimumScope: .standard),
            InventoryRoot(name: "Application Support", url: appSupport, artifactKind: .applicationSupport, minimumScope: .standard)
        ]
        let auditStore = try AuditStore(baseURL: auditRoot)
        let coordinator = ScanCoordinator(
            roots: roots,
            inventoryService: InventoryService(permissionCoordinator: PermissionCoordinator { _ in .granted }),
            installedAppProvider: {
                [
                    InstalledApp(
                        bundleIdentifier: "com.example.ActiveApp",
                        displayName: "ActiveApp",
                        bundleURL: URL(fileURLWithPath: "/Applications/ActiveApp.app")
                    )
                ]
            },
            auditStore: auditStore
        )

        let report = try coordinator.scan(
            scope: .standard,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(report.candidates.count == 1)
        #expect(report.blockedArtifacts.count == 1)
        #expect(report.candidates.first?.artifact.url.lastPathComponent == "com.example.OldApp.plist")
        #expect(try auditStore.loadScanSnapshots().count == 1)
    }

    @Test
    func auditWriteFailureDoesNotDiscardValidScanResults() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let launchAgents = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        let auditRoot = sandbox.url.appendingPathComponent("Audit", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Program": sandbox.url.appendingPathComponent("missing-target").path],
            format: .xml,
            options: 0
        )
        try plist.write(to: launchAgents.appendingPathComponent("com.example.dead.plist"))

        let auditStore = try AuditStore(baseURL: auditRoot)
        try Data("not-json".utf8).write(
            to: auditRoot.appendingPathComponent("scan-snapshots.json")
        )
        let coordinator = ScanCoordinator(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: launchAgents,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            inventoryService: InventoryService(
                permissionCoordinator: PermissionCoordinator { _ in .granted }
            ),
            installedAppProvider: { [] },
            auditStore: auditStore
        )

        let report = try coordinator.scan(scope: .standard)

        #expect(report.candidates.count == 1)
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].contains("audit snapshot"))
    }
}
