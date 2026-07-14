import Foundation
import Testing
@testable import SqueakyCleanCore

struct InventoryServiceTests {
    @Test
    func blockedRootIsSkippedBeforeEnumeration() throws {
        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let blockedRoot = InventoryRoot(
            name: "System Cache",
            url: URL(fileURLWithPath: "/System/Library/Caches"),
            artifactKind: .cache,
            minimumScope: .standard
        )

        let snapshot = try service.scan(
            roots: [blockedRoot],
            scope: .standard
        )

        #expect(snapshot.artifacts.isEmpty)
        #expect(snapshot.skippedRoots.count == 1)
        #expect(snapshot.skippedRoots.first?.reason.contains("blocked") == true)
    }

    @Test
    func limitedPermissionsReduceCoverageAndExplainWhy() throws {
        let rootA = InventoryRoot(
            name: "User Cache",
            url: URL(fileURLWithPath: "/Users/test/Library/Caches"),
            artifactKind: .cache,
            minimumScope: .standard
        )
        let rootB = InventoryRoot(
            name: "Shared Support",
            url: URL(fileURLWithPath: "/Library/Application Support"),
            artifactKind: .applicationSupport,
            minimumScope: .deep
        )
        let coordinator = PermissionCoordinator { url in
            url.path == rootA.url.path ? .granted : .restricted("Full Disk Access not granted")
        }

        let state = coordinator.evaluate(for: [rootA, rootB], scope: .deep)

        #expect(state.deepScanAvailable == false)
        #expect(state.inaccessibleRoots.count == 1)
        #expect(state.inaccessibleRoots.first?.reason.contains("Full Disk Access") == true)
    }

    @Test
    func malformedLaunchAgentPlistDoesNotAbortScan() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let agentRoot = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)

        let badPlist = agentRoot.appendingPathComponent("com.example.broken.plist")
        try Data("{ this is not a plist }".utf8).write(to: badPlist)

        let validPlist = agentRoot.appendingPathComponent("com.example.valid.plist")
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: ["Program": "/bin/ls"],
            format: .xml,
            options: 0
        )
        try serialized.write(to: validPlist)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: agentRoot,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        #expect(snapshot.artifacts.count == 2)
        let valid = snapshot.artifacts.first(where: { $0.url.lastPathComponent == "com.example.valid.plist" })
        let broken = snapshot.artifacts.first(where: { $0.url.lastPathComponent == "com.example.broken.plist" })
        #expect(valid?.metadata.launchTargetPath == "/bin/ls")
        #expect(valid?.metadata.launchTargetExists == true)
        #expect(broken != nil)
        #expect(broken?.metadata.launchTargetPath == nil)
        #expect(broken?.metadata.launchTargetExists == nil)
    }

    @Test
    func launchAgentTildePathResolvesAgainstInjectedHome() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let homeDir = sandbox.url.appendingPathComponent("home", isDirectory: true)
        let target = homeDir.appendingPathComponent("bin/agent")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: target)

        let agentRoot = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)

        let plistURL = agentRoot.appendingPathComponent("com.example.tilde.plist")
        let payload: [String: Any] = ["ProgramArguments": ["~/bin/agent", "--foreground"]]
        try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            .write(to: plistURL)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted },
            launchTargetResolver: LaunchTargetPathResolver(homeDirectory: homeDir, environment: [:])
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: agentRoot,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        let item = try #require(snapshot.artifacts.first)
        #expect(item.metadata.launchTargetPath == target.path)
        #expect(item.metadata.launchTargetExists == true)
    }

    @Test
    func launchAgentEnvVarPathResolvesAndDetectsMissingTarget() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let homeDir = sandbox.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)

        let agentRoot = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)

        let plistURL = agentRoot.appendingPathComponent("com.example.env.plist")
        let payload: [String: Any] = ["Program": "${HOME}/Library/services/agent"]
        try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            .write(to: plistURL)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted },
            launchTargetResolver: LaunchTargetPathResolver(
                homeDirectory: homeDir,
                environment: ["HOME": homeDir.path]
            )
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: agentRoot,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        let item = try #require(snapshot.artifacts.first)
        #expect(item.metadata.launchTargetPath == homeDir.appendingPathComponent("Library/services/agent").path)
        // The target file does not exist on disk — this used to be treated as a
        // healthy launch agent because the raw "${HOME}" path could not be stat'd.
        #expect(item.metadata.launchTargetExists == false)
    }

    @Test
    func relativeLaunchCommandDoesNotBecomeFalseMissingTargetEvidence() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let agentRoot = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)

        let plistURL = agentRoot.appendingPathComponent("com.example.path-search.plist")
        let payload: [String: Any] = ["ProgramArguments": ["example-agent", "--foreground"]]
        try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
            .write(to: plistURL)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: agentRoot,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        let item = try #require(snapshot.artifacts.first)
        #expect(item.metadata.launchTargetPath == "example-agent")
        #expect(item.metadata.launchTargetExists == nil)
    }

    @Test
    func inaccessibleLaunchTargetIsNotReportedAsMissing() throws {
        let sandbox = try TemporaryDirectory()
        let lockedParent = sandbox.url.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: lockedParent.path
            )
            sandbox.remove()
        }

        try FileManager.default.createDirectory(at: lockedParent, withIntermediateDirectories: true)
        let target = lockedParent.appendingPathComponent("agent")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: lockedParent.path
        )

        let agentRoot = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
        let plistURL = agentRoot.appendingPathComponent("com.example.inaccessible.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Program": target.path],
            format: .xml,
            options: 0
        ).write(to: plistURL)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "LaunchAgents",
                    url: agentRoot,
                    artifactKind: .launchAgent,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        let item = try #require(snapshot.artifacts.first)
        #expect(item.metadata.launchTargetPath == target.path)
        #expect(item.metadata.launchTargetExists == nil)
    }

    @Test
    func cancellingTheTaskAbortsTheScanWithCancellationError() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let cacheRoot = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        for i in 0..<200 {
            try Data("x".utf8).write(to: cacheRoot.appendingPathComponent("entry_\(i)"))
        }

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let task = Task {
            try service.scan(
                roots: [
                    InventoryRoot(
                        name: "Caches",
                        url: cacheRoot,
                        artifactKind: .cache,
                        minimumScope: .standard
                    )
                ],
                scope: .standard
            )
        }
        // Cancel before awaiting: the first checkCancellation call inside scan
        // should fire and surface a CancellationError instead of returning a snapshot.
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled scan to throw CancellationError.")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func directoryArtifactsAreNotRecursivelySizedDuringScan() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let rootURL = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        let childDirectory = rootURL.appendingPathComponent("com.example.ActiveApp", isDirectory: true)
        let nestedFile = childDirectory.appendingPathComponent("library.db")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4_096).write(to: nestedFile)

        let service = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try service.scan(
            roots: [
                InventoryRoot(
                    name: "Caches",
                    url: rootURL,
                    artifactKind: .cache,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )

        #expect(snapshot.artifacts.count == 1)
        #expect(snapshot.artifacts.first?.sizeInBytes == 0)
    }
}
