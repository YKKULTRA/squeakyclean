import Foundation
import Testing
@testable import SqueakyCleanCore

struct TransactionSafetyTests {
    @Test
    func cleanupRejectsItemsOutsideAllowedRoots() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let allowedRoot = sandbox.url.appendingPathComponent("Allowed", isDirectory: true)
        let outsideRoot = sandbox.url.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let outsideFile = outsideRoot.appendingPathComponent("unrelated.cache")
        try Data("active".utf8).write(to: outsideFile)

        let policy = CleanupPathPolicy(allowedRoots: [allowedRoot])
        expectPathFailure(.outsideAllowedRoots) {
            _ = try policy.validate(
                candidate: candidate(at: outsideFile),
                fileManager: .default
            )
        }
    }

    @Test
    func cleanupRejectsItemsInsideProtectedRoots() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let allowedRoot = sandbox.url.appendingPathComponent("Allowed", isDirectory: true)
        let protectedRoot = allowedRoot.appendingPathComponent("Protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedRoot, withIntermediateDirectories: true)
        let protectedFile = protectedRoot.appendingPathComponent("state.db")
        try Data("needed".utf8).write(to: protectedFile)

        let policy = CleanupPathPolicy(
            allowedRoots: [allowedRoot],
            protectedRoots: [protectedRoot]
        )
        expectPathFailure(.protectedPath) {
            _ = try policy.validate(
                candidate: candidate(at: protectedFile),
                fileManager: .default
            )
        }
    }

    @Test
    func cleanupRejectsAncestorThatWouldDeleteAppManagedData() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let allowedRoot = sandbox.url.appendingPathComponent("Library", isDirectory: true)
        let supportRoot = allowedRoot.appendingPathComponent("Application Support", isDirectory: true)
        let selfRoot = supportRoot.appendingPathComponent("SqueakyClean", isDirectory: true)
        try FileManager.default.createDirectory(at: selfRoot, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: selfRoot.appendingPathComponent("state.json"))

        let policy = CleanupPathPolicy(
            allowedRoots: [allowedRoot],
            protectedRoots: [selfRoot]
        )
        expectPathFailure(.protectedPath) {
            _ = try policy.validate(
                candidate: candidate(at: supportRoot),
                fileManager: .default
            )
        }
    }

    @Test
    func cleanupRejectsArtifactWhoseFileIdentityChangedAfterInventory() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let root = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scannedURL = root.appendingPathComponent("com.example.retired.cache")
        let replacementURL = sandbox.url.appendingPathComponent("replacement.cache")
        try Data("original".utf8).write(to: scannedURL)
        try Data("replacement".utf8).write(to: replacementURL)

        let inventory = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try inventory.scan(
            roots: [
                InventoryRoot(
                    name: "Caches",
                    url: root,
                    artifactKind: .cache,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )
        let scannedArtifact = try #require(snapshot.artifacts.first)
        let scannedFileNumber = try #require(scannedArtifact.metadata.fileSystemFileNumber)

        // The replacement exists concurrently with the scanned file, so it is
        // guaranteed to have a distinct filesystem identity before taking over
        // the same pathname.
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: replacementURL.path)
        let replacementFileNumber = try #require(
            (replacementAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        #expect(replacementFileNumber != scannedFileNumber)
        try FileManager.default.removeItem(at: scannedURL)
        try FileManager.default.moveItem(at: replacementURL, to: scannedURL)

        let policy = CleanupPathPolicy(allowedRoots: [root])
        expectPathFailure(.changedSinceScan) {
            _ = try policy.validate(
                candidate: candidate(for: scannedArtifact),
                fileManager: .default
            )
        }
    }

    @Test
    func cleanupRejectsArtifactWithoutRecordedFilesystemIdentity() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let root = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = root.appendingPathComponent("com.example.unverifiable.cache")
        try Data("active".utf8).write(to: item)
        let artifact = DiscoveredArtifact(
            url: item,
            kind: .cache,
            sizeInBytes: 6,
            lastModifiedAt: testModificationDate(at: item),
            metadata: ArtifactMetadata(ownerHint: "com.example.unverifiable")
        )

        let policy = CleanupPathPolicy(allowedRoots: [root])
        expectPathFailure(.unverifiableIdentity) {
            _ = try policy.validate(candidate: candidate(for: artifact), fileManager: .default)
        }
    }

    @Test
    func cleanupRejectsDeadLaunchItemAfterItsTargetReappears() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let launchAgents = sandbox.url.appendingPathComponent("LaunchAgents", isDirectory: true)
        let target = sandbox.url.appendingPathComponent("bin/reinstalled-agent")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("com.example.reinstalled.plist")
        try Data("plist".utf8).write(to: plist)
        let artifact = DiscoveredArtifact(
            url: plist,
            kind: .launchAgent,
            sizeInBytes: 5,
            lastModifiedAt: testModificationDate(at: plist),
            metadata: ArtifactMetadata(
                ownerHint: "com.example.reinstalled",
                launchTargetPath: target.path,
                launchTargetExists: false,
                fileSystemNumber: testArtifactMetadata(at: plist).fileSystemNumber,
                fileSystemFileNumber: testArtifactMetadata(at: plist).fileSystemFileNumber,
                isSymbolicLink: false
            )
        )
        let cleanupCandidate = CleanupCandidate(
            artifact: artifact,
            riskTier: .review,
            proposedAction: .quarantine,
            reason: "Launch item with missing target",
            evidence: RuleEvidence(code: "dead-launch-item", summary: "Target was missing")
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: target)

        let policy = CleanupPathPolicy(allowedRoots: [launchAgents])
        expectPathFailure(.evidenceChanged) {
            _ = try policy.validate(candidate: cleanupCandidate, fileManager: .default)
        }
    }

    @Test
    func cleanupRejectsCandidateWhoseOwnerIsInstalledAtApprovalTime() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let root = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = root.appendingPathComponent("com.example.reinstalled")
        try Data("active".utf8).write(to: item)
        let store = try QuarantineStore(baseURL: storeRoot)
        let installed = InstalledApp(
            bundleIdentifier: "com.example.retired",
            displayName: "Reinstalled App",
            bundleURL: sandbox.url.appendingPathComponent("Reinstalled App.app")
        )
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: CleanupPathPolicy(allowedRoots: [root], protectedRoots: [storeRoot]),
            installedAppProvider: { [installed] }
        )

        do {
            _ = try cleanup.quarantine(candidate: candidate(at: item))
            Issue.record("Expected action-time installed-owner revalidation to stop cleanup.")
        } catch CleanupCoordinatorError.ownerNowInstalled(let rejectedURL, let appName) {
            #expect(rejectedURL == item)
            #expect(appName == "Reinstalled App")
        } catch {
            Issue.record("Expected ownerNowInstalled, got \(type(of: error)): \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(try store.allRecords().isEmpty)
    }

    @Test
    func cleanupRejectsSymbolicLinkDiscoveredByInventory() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let root = sandbox.url.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = sandbox.url.appendingPathComponent("active.data")
        let link = root.appendingPathComponent("com.example.retired.cache")
        try Data("active".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let inventory = InventoryService(
            permissionCoordinator: PermissionCoordinator { _ in .granted }
        )
        let snapshot = try inventory.scan(
            roots: [
                InventoryRoot(
                    name: "Caches",
                    url: root,
                    artifactKind: .cache,
                    minimumScope: .standard
                )
            ],
            scope: .standard
        )
        let artifact = try #require(snapshot.artifacts.first)
        #expect(artifact.metadata.isSymbolicLink == true)

        let policy = CleanupPathPolicy(allowedRoots: [root])
        expectPathFailure(.symbolicLink) {
            _ = try policy.validate(
                candidate: candidate(for: artifact),
                fileManager: .default
            )
        }
    }

    @Test
    func manifestRejectsPayloadURLOutsideManagedRecordDirectory() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        let source = sandbox.url.appendingPathComponent("original.cache")
        try Data("source".utf8).write(to: source)
        let store = try QuarantineStore(baseURL: storeRoot)
        let id = UUID()
        let record = QuarantineRecord(
            id: id,
            artifactKind: .cache,
            originalURL: source,
            quarantinedURL: sandbox.url.appendingPathComponent("escaped-payload.cache"),
            recordedSizeBytes: 6,
            contentHash: "untrusted",
            reason: "fixture",
            evidenceSummary: "fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .quarantined
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = storeRoot.appendingPathComponent("quarantine-manifest.json")
        try encoder.encode([record]).write(to: manifestURL, options: .atomic)

        do {
            _ = try store.allRecords()
            Issue.record("Expected an escaped manifest payload URL to be rejected.")
        } catch QuarantineStoreError.invalidPayloadPath(let rejectedID) {
            #expect(rejectedID == id)
        } catch {
            Issue.record("Expected invalidPayloadPath, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func manifestRejectsRecordContainerReplacedByEscapingSymlink() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        let escapeRoot = sandbox.url.appendingPathComponent("Escape", isDirectory: true)
        let source = sandbox.url.appendingPathComponent("original.cache")
        try FileManager.default.createDirectory(at: escapeRoot, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        let store = try QuarantineStore(baseURL: storeRoot)
        let id = UUID()
        let payload = try store.payloadURL(recordID: id, originalURL: source)
        let container = payload.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: container, withDestinationURL: escapeRoot)
        try Data("escaped".utf8).write(to: escapeRoot.appendingPathComponent(source.lastPathComponent))

        let record = quarantineRecord(
            id: id,
            originalURL: source,
            quarantinedURL: payload,
            status: .quarantined
        )
        do {
            try store.save(record: record)
            Issue.record("Expected a symlinked payload container to be rejected.")
        } catch QuarantineStoreError.invalidPayloadPath(let rejectedID) {
            #expect(rejectedID == id)
        } catch {
            Issue.record("Expected invalidPayloadPath, got \(type(of: error)): \(error)")
        }
    }

    @Test
    func pendingQuarantineBeforeMoveIsRolledBackAndJournalRemoved() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let store = try QuarantineStore(
            baseURL: sandbox.url.appendingPathComponent("Store", isDirectory: true)
        )
        let source = sandbox.url.appendingPathComponent("source.cache")
        try Data("source".utf8).write(to: source)
        let id = UUID()
        let payload = try store.payloadURL(recordID: id, originalURL: source)
        let container = payload.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try store.save(
            record: quarantineRecord(
                id: id,
                originalURL: source,
                quarantinedURL: payload,
                status: .pending
            )
        )

        try store.reconcileInterruptedOperations()

        #expect(try store.allRecords().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: container.path) == false)
    }

    @Test
    func pendingQuarantineAfterMoveIsCommittedAsQuarantined() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let store = try QuarantineStore(
            baseURL: sandbox.url.appendingPathComponent("Store", isDirectory: true)
        )
        let source = sandbox.url.appendingPathComponent("source.cache")
        try Data("source".utf8).write(to: source)
        let id = UUID()
        let payload = try store.payloadURL(recordID: id, originalURL: source)
        let contentHash = try PayloadInspector(fileManager: .default).contentHash(for: source)
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try store.save(
            record: quarantineRecord(
                id: id,
                originalURL: source,
                quarantinedURL: payload,
                status: .pending,
                contentHash: contentHash
            )
        )
        try FileManager.default.moveItem(at: source, to: payload)

        try store.reconcileInterruptedOperations()

        let reconciled = try #require(store.allRecords().first)
        #expect(reconciled.id == id)
        #expect(reconciled.status == .quarantined)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(FileManager.default.fileExists(atPath: payload.path))
    }

    @Test
    func quarantineMoveThatCompletesThenThrowsIsReconciledAndPreserved() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appendingPathComponent("Source", isDirectory: true)
        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("orphan.cache")
        let originalData = Data("recoverable".utf8)
        try originalData.write(to: source)

        let store = try QuarantineStore(baseURL: storeRoot)
        let fileManager = MoveThenThrowFileManager()
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: CleanupPathPolicy(
                allowedRoots: [sourceRoot],
                protectedRoots: [storeRoot]
            ),
            fileManager: fileManager,
            installedAppProvider: { [] }
        )

        let record = try cleanup.quarantine(candidate: candidate(at: source))

        #expect(fileManager.didInjectFailure)
        #expect(record.status == .quarantined)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try Data(contentsOf: record.quarantinedURL) == originalData)
        let records = try store.allRecords()
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(records.first?.status == .quarantined)
    }

    @Test
    func restoreCollisionInjectedImmediatelyBeforeMovePreservesBothObjects() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appendingPathComponent("Source", isDirectory: true)
        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("orphan.cache")
        let payloadData = Data("quarantined".utf8)
        let collisionData = Data("new active file".utf8)
        try payloadData.write(to: source)

        let store = try QuarantineStore(baseURL: storeRoot)
        let policy = CleanupPathPolicy(
            allowedRoots: [sourceRoot],
            protectedRoots: [storeRoot]
        )
        let cleanup = CleanupCoordinator(
            quarantineStore: store,
            pathPolicy: policy,
            installedAppProvider: { [] }
        )
        let record = try cleanup.quarantine(candidate: candidate(at: source))
        let collisionFileManager = DestinationCollisionFileManager(collisionData: collisionData)
        let restore = RestoreCoordinator(
            quarantineStore: store,
            pathPolicy: policy,
            fileManager: collisionFileManager
        )

        var restoreThrew = false
        do {
            _ = try restore.restore(recordID: record.id)
        } catch {
            restoreThrew = true
        }

        #expect(restoreThrew)
        #expect(collisionFileManager.didInjectCollision)
        #expect(try Data(contentsOf: source) == collisionData)
        #expect(try Data(contentsOf: record.quarantinedURL) == payloadData)
        let persisted = try store.record(id: record.id)
        #expect(persisted.status == .quarantined)
        try store.save(record: persisted)
        #expect(try store.allRecords().map(\.id) == [record.id])
    }

    @Test
    func ambiguousPendingJournalDoesNotBlockOtherRecordReconciliation() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let store = try QuarantineStore(
            baseURL: sandbox.url.appendingPathComponent("Store", isDirectory: true)
        )
        let ambiguousSource = sandbox.url.appendingPathComponent("ambiguous.cache")
        let recoverableSource = sandbox.url.appendingPathComponent("recoverable.cache")
        try Data("source copy".utf8).write(to: ambiguousSource)
        try Data("moved copy".utf8).write(to: recoverableSource)

        let ambiguousID = UUID()
        let ambiguousPayload = try store.payloadURL(
            recordID: ambiguousID,
            originalURL: ambiguousSource
        )
        try FileManager.default.createDirectory(
            at: ambiguousPayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("payload copy".utf8).write(to: ambiguousPayload)
        let ambiguousRecord = quarantineRecord(
            id: ambiguousID,
            originalURL: ambiguousSource,
            quarantinedURL: ambiguousPayload,
            status: .pending,
            contentHash: try PayloadInspector(fileManager: .default).contentHash(for: ambiguousPayload)
        )
        try store.save(record: ambiguousRecord)

        let recoverableID = UUID()
        let recoverablePayload = try store.payloadURL(
            recordID: recoverableID,
            originalURL: recoverableSource
        )
        let recoverableHash = try PayloadInspector(fileManager: .default).contentHash(for: recoverableSource)
        try FileManager.default.createDirectory(
            at: recoverablePayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: recoverableSource, to: recoverablePayload)
        try store.save(
            record: quarantineRecord(
                id: recoverableID,
                originalURL: recoverableSource,
                quarantinedURL: recoverablePayload,
                status: .pending,
                contentHash: recoverableHash
            )
        )

        try store.reconcileInterruptedOperations()

        let records = try store.allRecords()
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        #expect(records.count == 2)
        #expect(recordsByID[ambiguousID]?.status == .interrupted)
        #expect(recordsByID[recoverableID]?.status == .quarantined)
        #expect(FileManager.default.fileExists(atPath: ambiguousSource.path))
        #expect(FileManager.default.fileExists(atPath: ambiguousPayload.path))
        #expect(FileManager.default.fileExists(atPath: recoverablePayload.path))
    }

    @Test
    func restoringBeforeMoveRollsBackToQuarantined() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let fixture = try makeQuarantinedFixture(in: sandbox)
        let restoring = fixture.record.restoring(
            to: fixture.record.originalURL,
            at: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try fixture.store.save(record: restoring)

        try fixture.store.reconcileInterruptedOperations()

        let reconciled = try fixture.store.record(id: fixture.record.id)
        #expect(reconciled.status == .quarantined)
        #expect(reconciled.restoredURL == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.record.quarantinedURL.path))
    }

    @Test
    func restoringAfterMoveCommitsAsRestored() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let fixture = try makeQuarantinedFixture(in: sandbox)
        let restoredAt = Date(timeIntervalSince1970: 1_700_000_100)
        let destination = fixture.record.originalURL
        try fixture.store.save(
            record: fixture.record.restoring(to: destination, at: restoredAt)
        )
        try FileManager.default.moveItem(
            at: fixture.record.quarantinedURL,
            to: destination
        )

        try fixture.store.reconcileInterruptedOperations()

        let reconciled = try fixture.store.record(id: fixture.record.id)
        #expect(reconciled.status == .restored)
        #expect(reconciled.restoredURL == destination)
        #expect(reconciled.restoredAt == restoredAt)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func purgingBeforePayloadRemovalRollsBackToQuarantined() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let fixture = try makeQuarantinedFixture(in: sandbox)
        try fixture.store.save(record: fixture.record.updating(status: .purging))

        try fixture.store.reconcileInterruptedOperations()

        let reconciled = try fixture.store.record(id: fixture.record.id)
        #expect(reconciled.status == .quarantined)
        #expect(FileManager.default.fileExists(atPath: fixture.record.quarantinedURL.path))
    }

    @Test
    func purgingAfterPayloadRemovalDropsRecordAndContainer() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let fixture = try makeQuarantinedFixture(in: sandbox)
        try fixture.store.save(record: fixture.record.updating(status: .purging))
        try FileManager.default.removeItem(at: fixture.record.quarantinedURL)

        try fixture.store.reconcileInterruptedOperations()

        #expect(try fixture.store.allRecords().isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.record.quarantinedURL.deletingLastPathComponent().path
            ) == false
        )
    }

    @Test
    func concurrentStoreInstancesDoNotLoseSavedRecords() async throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        let sourceRoot = sandbox.url.appendingPathComponent("Originals", isDirectory: true)
        let firstStore = try QuarantineStore(baseURL: storeRoot)
        let secondStore = try QuarantineStore(baseURL: storeRoot)
        var records: [QuarantineRecord] = []

        for index in 0..<40 {
            let id = UUID()
            let original = sourceRoot.appendingPathComponent("item-\(index).cache")
            let payload = try firstStore.payloadURL(recordID: id, originalURL: original)
            try FileManager.default.createDirectory(
                at: payload.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("payload \(index)".utf8).write(to: payload)
            records.append(
                quarantineRecord(
                    id: id,
                    originalURL: original,
                    quarantinedURL: payload,
                    status: .quarantined
                )
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, record) in records.enumerated() {
                let store = index.isMultiple(of: 2) ? firstStore : secondStore
                group.addTask {
                    try store.save(record: record)
                }
            }
            try await group.waitForAll()
        }

        let savedRecords = try firstStore.allRecords()
        #expect(savedRecords.count == records.count)
        #expect(Set(savedRecords.map(\.id)) == Set(records.map(\.id)))
        #expect(try secondStore.allRecords().count == records.count)
    }

    @Test
    func unreadableDescendantMakesSizingAndFingerprintInspectionFail() throws {
        let sandbox = try TemporaryDirectory()
        let root = sandbox.url.appendingPathComponent("Cache", isDirectory: true)
        let unreadable = root.appendingPathComponent("private", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadable.path
            )
            sandbox.remove()
        }

        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("must be inspected".utf8).write(to: unreadable.appendingPathComponent("payload"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadable.path
        )

        var permissionDenied = false
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: unreadable.path)
        } catch {
            permissionDenied = true
        }
        #expect(permissionDenied)

        var candidateSizerThrew = false
        do {
            _ = try CandidateSizer().sized([candidate(at: root)])
        } catch {
            candidateSizerThrew = true
        }

        let inspector = PayloadInspector(fileManager: .default)
        var allocatedSizeThrew = false
        do {
            _ = try inspector.allocatedSize(at: root)
        } catch {
            allocatedSizeThrew = true
        }
        var contentHashThrew = false
        do {
            _ = try inspector.contentHash(for: root)
        } catch {
            contentHashThrew = true
        }

        #expect(candidateSizerThrew)
        #expect(allocatedSizeThrew)
        #expect(contentHashThrew)
    }

    @Test
    func hiddenDirectoryContentContributesToSizeAndFingerprint() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let directory = sandbox.url.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hiddenFile = directory.appendingPathComponent(".hidden-payload")
        try Data(repeating: 0x41, count: 8_192).write(to: hiddenFile)

        let sized = try CandidateSizer().sized([candidate(at: directory)])
        let originalHash = try PayloadInspector(fileManager: .default).contentHash(for: directory)
        try Data(repeating: 0x42, count: 8_192).write(to: hiddenFile)
        let changedHash = try PayloadInspector(fileManager: .default).contentHash(for: directory)

        #expect(sized[0].artifact.sizeInBytes > 0)
        #expect(originalHash != changedHash)
    }

    @Test
    func equalLengthDirectoryFilesWithDifferentBytesHaveDifferentFingerprints() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let first = sandbox.url.appendingPathComponent("First", isDirectory: true)
        let second = sandbox.url.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: first.appendingPathComponent("payload.bin"))
        try Data("BBBB".utf8).write(to: second.appendingPathComponent("payload.bin"))

        let inspector = PayloadInspector(fileManager: .default)
        let firstHash = try inspector.contentHash(for: first)
        let secondHash = try inspector.contentHash(for: second)

        #expect(firstHash != secondHash)
    }

    @Test
    func emptyRegularFileAndEmptyDirectoryHaveDifferentFingerprints() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let emptyFile = sandbox.url.appendingPathComponent("empty-file")
        let emptyDirectory = sandbox.url.appendingPathComponent("empty-directory", isDirectory: true)
        try Data().write(to: emptyFile)
        try FileManager.default.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: true
        )

        let inspector = PayloadInspector(fileManager: .default)
        let fileHash = try inspector.contentHash(for: emptyFile)
        let directoryHash = try inspector.contentHash(for: emptyDirectory)

        #expect(fileHash != directoryHash)
    }

    @Test
    func restoreRejectsSameLengthPayloadTampering() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appendingPathComponent("Source", isDirectory: true)
        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let original = sourceRoot.appendingPathComponent("orphan.cache")
        try Data("alpha".utf8).write(to: original)

        let store = try QuarantineStore(baseURL: storeRoot)
        let policy = CleanupPathPolicy(
            allowedRoots: [sourceRoot],
            protectedRoots: [storeRoot]
        )
        let cleanup = CleanupCoordinator(quarantineStore: store, pathPolicy: policy)
        let restore = RestoreCoordinator(quarantineStore: store, pathPolicy: policy)
        let record = try cleanup.quarantine(candidate: candidate(at: original))
        try Data("omega".utf8).write(to: record.quarantinedURL)

        do {
            _ = try restore.restore(recordID: record.id)
            Issue.record("Expected modified quarantined content to fail fingerprint verification.")
        } catch RestoreCoordinatorError.fingerprintMismatch(let rejectedID) {
            #expect(rejectedID == record.id)
        } catch {
            Issue.record("Expected fingerprintMismatch, got \(type(of: error)): \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(FileManager.default.fileExists(atPath: record.quarantinedURL.path))
        #expect(try store.record(id: record.id).status == .quarantined)
    }

    @Test
    func restoreRejectsPayloadReplacedBySameContentSymlink() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let sourceRoot = sandbox.url.appendingPathComponent("Source", isDirectory: true)
        let storeRoot = sandbox.url.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let original = sourceRoot.appendingPathComponent("orphan.cache")
        let externalTarget = sandbox.url.appendingPathComponent("active-external.cache")
        let originalData = Data("identical bytes".utf8)
        try originalData.write(to: original)
        try originalData.write(to: externalTarget)

        let store = try QuarantineStore(baseURL: storeRoot)
        let policy = CleanupPathPolicy(
            allowedRoots: [sourceRoot],
            protectedRoots: [storeRoot]
        )
        let cleanup = CleanupCoordinator(quarantineStore: store, pathPolicy: policy)
        let restore = RestoreCoordinator(quarantineStore: store, pathPolicy: policy)
        let record = try cleanup.quarantine(candidate: candidate(at: original))
        try FileManager.default.removeItem(at: record.quarantinedURL)
        try FileManager.default.createSymbolicLink(
            at: record.quarantinedURL,
            withDestinationURL: externalTarget
        )

        do {
            _ = try restore.restore(recordID: record.id)
            Issue.record("Expected a symlink-swapped payload to fail fingerprint verification.")
        } catch RestoreCoordinatorError.fingerprintMismatch(let rejectedID) {
            #expect(rejectedID == record.id)
        } catch {
            Issue.record("Expected fingerprintMismatch, got \(type(of: error)): \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: original.path) == false)
        #expect(try record.quarantinedURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: externalTarget) == originalData)
        #expect(try store.record(id: record.id).status == .quarantined)
    }

    @Test
    func restoreRejectsMissingAndUnknownFingerprintVersionsWithoutMoving() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let versions: [Int?] = [nil, 99]
        for (index, version) in versions.enumerated() {
            let caseRoot = sandbox.url.appendingPathComponent("Case-\(index)", isDirectory: true)
            let sourceRoot = caseRoot.appendingPathComponent("Source", isDirectory: true)
            let storeRoot = caseRoot.appendingPathComponent("Store", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let source = sourceRoot.appendingPathComponent("orphan.cache")
            let payloadData = Data("legacy payload \(index)".utf8)
            try payloadData.write(to: source)

            let store = try QuarantineStore(baseURL: storeRoot)
            let id = UUID()
            let payload = try store.payloadURL(recordID: id, originalURL: source)
            let contentHash = try PayloadInspector(fileManager: .default).contentHash(for: source)
            try FileManager.default.createDirectory(
                at: payload.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: payload)
            let record = quarantineRecord(
                id: id,
                originalURL: source,
                quarantinedURL: payload,
                status: .quarantined,
                contentHash: contentHash,
                fingerprintVersion: version
            )
            try store.save(record: record)
            let restore = RestoreCoordinator(
                quarantineStore: store,
                pathPolicy: CleanupPathPolicy(
                    allowedRoots: [sourceRoot],
                    protectedRoots: [storeRoot]
                )
            )

            do {
                _ = try restore.restore(recordID: id)
                Issue.record("Expected fingerprint version \(String(describing: version)) to be rejected.")
            } catch RestoreCoordinatorError.unsupportedFingerprintVersion(
                let rejectedID,
                let rejectedVersion
            ) {
                #expect(rejectedID == id)
                #expect(rejectedVersion == version)
            } catch {
                Issue.record("Expected unsupportedFingerprintVersion, got \(type(of: error)): \(error)")
            }

            #expect(FileManager.default.fileExists(atPath: source.path) == false)
            #expect(try Data(contentsOf: payload) == payloadData)
            #expect(try store.record(id: id).status == .quarantined)
        }
    }
}

private enum ExpectedPathFailure {
    case outsideAllowedRoots
    case protectedPath
    case symbolicLink
    case unverifiableIdentity
    case changedSinceScan
    case evidenceChanged
}

private func expectPathFailure(
    _ expected: ExpectedPathFailure,
    performing operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected cleanup path validation to fail with \(expected).")
    } catch let error as CleanupPathPolicyError {
        switch (expected, error) {
        case (.outsideAllowedRoots, .outsideAllowedRoots),
             (.protectedPath, .protectedPath),
             (.symbolicLink, .symbolicLink),
             (.unverifiableIdentity, .unverifiableIdentity),
             (.changedSinceScan, .changedSinceScan),
             (.evidenceChanged, .evidenceChanged):
            break
        default:
            Issue.record("Expected \(expected), got \(error).")
        }
    } catch {
        Issue.record("Expected CleanupPathPolicyError, got \(type(of: error)): \(error)")
    }
}

private func candidate(at url: URL) -> CleanupCandidate {
    candidate(
        for: DiscoveredArtifact(
            url: url,
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast,
            metadata: testArtifactMetadata(at: url, ownerHint: "com.example.retired")
        )
    )
}

private func candidate(for artifact: DiscoveredArtifact) -> CleanupCandidate {
    CleanupCandidate(
        artifact: artifact,
        riskTier: .review,
        proposedAction: .quarantine,
        reason: "Safety test fixture",
        evidence: RuleEvidence(code: "fixture", summary: "Safety test fixture")
    )
}

private func quarantineRecord(
    id: UUID,
    originalURL: URL,
    quarantinedURL: URL,
    status: QuarantineRecordStatus,
    contentHash: String = "fixture-hash",
    fingerprintVersion: Int? = 2
) -> QuarantineRecord {
    QuarantineRecord(
        id: id,
        artifactKind: .cache,
        originalURL: originalURL,
        quarantinedURL: quarantinedURL,
        recordedSizeBytes: 6,
        contentHash: contentHash,
        fingerprintVersion: fingerprintVersion,
        reason: "Safety test fixture",
        evidenceSummary: "Safety test fixture",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        status: status
    )
}

private struct QuarantinedFixture {
    let store: QuarantineStore
    let record: QuarantineRecord
}

private func makeQuarantinedFixture(in sandbox: TemporaryDirectory) throws -> QuarantinedFixture {
    let store = try QuarantineStore(
        baseURL: sandbox.url.appendingPathComponent("Store", isDirectory: true)
    )
    let source = sandbox.url.appendingPathComponent("source.cache")
    try Data("source".utf8).write(to: source)
    let id = UUID()
    let payload = try store.payloadURL(recordID: id, originalURL: source)
    try FileManager.default.createDirectory(
        at: payload.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.moveItem(at: source, to: payload)
    let contentHash = try PayloadInspector(fileManager: .default).contentHash(for: payload)
    let record = quarantineRecord(
        id: id,
        originalURL: source,
        quarantinedURL: payload,
        status: .quarantined,
        contentHash: contentHash
    )
    try store.save(record: record)
    return QuarantinedFixture(store: store, record: record)
}

private enum InjectedFileManagerError: Error {
    case moveReportedFailureAfterCompletion
}

private final class MoveThenThrowFileManager: FileManager, @unchecked Sendable {
    private(set) var didInjectFailure = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try super.moveItem(at: srcURL, to: dstURL)
        guard !didInjectFailure else { return }
        didInjectFailure = true
        throw InjectedFileManagerError.moveReportedFailureAfterCompletion
    }
}

private final class DestinationCollisionFileManager: FileManager, @unchecked Sendable {
    private let collisionData: Data
    private(set) var didInjectCollision = false

    init(collisionData: Data) {
        self.collisionData = collisionData
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if !didInjectCollision {
            try collisionData.write(to: dstURL)
            didInjectCollision = true
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
