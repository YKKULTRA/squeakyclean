import Foundation

public enum CleanupCoordinatorError: Error, LocalizedError {
    case sourceMissing(URL)
    case ownerNowInstalled(URL, String)
    case operationCompletedButFinalizationFailed(QuarantineRecord, String)
    case operationNeedsRecovery(QuarantineRecord, String)
    case partialPurge([QuarantineRecord], String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "The scanned item no longer exists: \(url.path)"
        case .ownerNowInstalled(let url, let appName):
            return "The item now matches installed app \(appName). Cleanup was stopped: \(url.path)"
        case .operationCompletedButFinalizationFailed(_, let detail):
            return "The filesystem action completed, but its manifest could not be finalized: \(detail)"
        case .operationNeedsRecovery(_, let detail):
            return "The filesystem action had an uncertain result. The recovery record and any surviving files were preserved: \(detail)"
        case .partialPurge(let records, let detail):
            return "Permanently deleted \(records.count) item(s) before a later item failed: \(detail)"
        }
    }
}

public final class CleanupCoordinator: @unchecked Sendable {
    private let quarantineStore: QuarantineStore
    private let pathPolicy: CleanupPathPolicy
    private let fileManager: FileManager
    private let payloadInspector: PayloadInspector
    private let installedAppProvider: @Sendable () -> [InstalledApp]

    public init(
        quarantineStore: QuarantineStore,
        pathPolicy: CleanupPathPolicy,
        fileManager: FileManager = .default,
        installedAppProvider: @escaping @Sendable () -> [InstalledApp] = {
            InstalledAppCatalog().snapshot()
        }
    ) {
        self.quarantineStore = quarantineStore
        self.pathPolicy = pathPolicy
        self.fileManager = fileManager
        self.payloadInspector = PayloadInspector(fileManager: fileManager)
        self.installedAppProvider = installedAppProvider
    }

    /// Permanently removes a quarantined payload. For an already-restored
    /// record, this removes only the manifest/history record, never the restored
    /// file at its destination.
    public func purge(recordID: UUID) throws {
        try quarantineStore.withExclusiveTransaction {
            try purgeWithinTransaction(recordID: recordID)
        }
    }

    private func purgeWithinTransaction(recordID: UUID) throws {
        let record = try quarantineStore.record(id: recordID)

        if record.status == .restored {
            try quarantineStore.delete(recordID: record.id)
            return
        }

        guard record.status == .quarantined else {
            throw QuarantineStoreError.inconsistentRecord(
                record.id,
                "record is not ready to purge (status: \(record.status.rawValue))"
            )
        }

        try quarantineStore.save(record: record.updating(status: .purging))
        do {
            try quarantineStore.validateManagedPayload(for: record)
            if itemExists(at: record.quarantinedURL) {
                try fileManager.removeItem(at: record.quarantinedURL)
            }
            try removePayloadContainerIfPresent(for: record)
            try quarantineStore.delete(recordID: record.id)
        } catch {
            let purgeError = error
            do {
                try quarantineStore.reconcileInterruptedOperations()
                let recordStillExists = try quarantineStore.allRecords().contains {
                    $0.id == record.id
                }
                if !recordStillExists {
                    // The payload disappeared and reconciliation finalized the
                    // journal, so the requested purge did complete.
                    return
                }
            } catch {
                throw CleanupCoordinatorError.operationNeedsRecovery(
                    record,
                    "\(purgeError.localizedDescription) Recovery also failed: \(error.localizedDescription)"
                )
            }
            throw purgeError
        }
    }

    /// Attempts every quarantined record and reports records that were already
    /// deleted if a later record fails, so callers can audit partial success.
    @discardableResult
    public func purgeAll() throws -> [QuarantineRecord] {
        try quarantineStore.withExclusiveTransaction {
            let records = try quarantineStore.allRecords().filter { $0.status == .quarantined }
            var purged: [QuarantineRecord] = []
            for record in records {
                do {
                    try purgeWithinTransaction(recordID: record.id)
                    purged.append(record)
                } catch {
                    throw CleanupCoordinatorError.partialPurge(purged, error.localizedDescription)
                }
            }
            return purged
        }
    }

    public func quarantine(candidate: CleanupCandidate, at date: Date = .now) throws -> QuarantineRecord {
        try quarantineStore.withExclusiveTransaction {
            try quarantineWithinTransaction(candidate: candidate, at: date)
        }
    }

    private func quarantineWithinTransaction(
        candidate: CleanupCandidate,
        at date: Date
    ) throws -> QuarantineRecord {
        let sourceURL = try pathPolicy.validate(candidate: candidate, fileManager: fileManager)
        guard itemExists(at: sourceURL) else {
            throw CleanupCoordinatorError.sourceMissing(sourceURL)
        }

        let recordedSize = try payloadInspector.allocatedSize(at: sourceURL)
        let contentHash = try payloadInspector.contentHash(for: sourceURL)

        // Revalidate after the potentially long hash pass. Active data may have
        // changed while it was being read and must not be moved under a stale approval.
        _ = try pathPolicy.validate(candidate: candidate, fileManager: fileManager)
        if case .installed(let app) = OwnershipResolver().resolve(
            artifact: candidate.artifact,
            installedApps: installedAppProvider()
        ) {
            throw CleanupCoordinatorError.ownerNowInstalled(sourceURL, app.displayName)
        }

        let recordID = UUID()
        let quarantinedURL = try quarantineStore.payloadURL(
            recordID: recordID,
            originalURL: sourceURL
        )
        let payloadContainer = quarantinedURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: payloadContainer, withIntermediateDirectories: true)

        let pendingRecord = QuarantineRecord(
            id: recordID,
            artifactKind: candidate.artifact.kind,
            originalURL: sourceURL,
            quarantinedURL: quarantinedURL,
            recordedSizeBytes: recordedSize,
            contentHash: contentHash,
            reason: candidate.reason,
            evidenceSummary: candidate.evidence.summary,
            createdAt: date,
            status: .pending
        )

        // Persist recoverability before the original path is changed.
        try quarantineStore.save(record: pendingRecord)
        do {
            // Close the manifest-write window as well as the hash window.
            _ = try pathPolicy.validate(candidate: candidate, fileManager: fileManager)
            try quarantineStore.validateManagedPayload(for: pendingRecord)
            try fileManager.moveItem(at: sourceURL, to: quarantinedURL)
        } catch {
            let moveError = error

            // A move can report failure after changing the filesystem. Never
            // delete either location based only on the thrown error. Reconcile
            // the journal from the observable source/payload state instead.
            do {
                try quarantineStore.reconcileInterruptedOperations()
                if let recovered = try quarantineStore.allRecords().first(where: { $0.id == recordID }) {
                    if recovered.status == .quarantined {
                        return recovered
                    }
                    throw CleanupCoordinatorError.operationNeedsRecovery(
                        recovered,
                        moveError.localizedDescription
                    )
                }
            } catch let recoveryError as CleanupCoordinatorError {
                throw recoveryError
            } catch {
                throw CleanupCoordinatorError.operationNeedsRecovery(
                    pendingRecord,
                    "\(moveError.localizedDescription) Recovery also failed: \(error.localizedDescription)"
                )
            }
            throw moveError
        }

        let completedRecord = pendingRecord.updating(status: .quarantined)
        do {
            try quarantineStore.save(record: completedRecord)
            return completedRecord
        } catch {
            // The pending record still points to the moved payload and can be
            // reconciled on the next read or app launch.
            throw CleanupCoordinatorError.operationCompletedButFinalizationFailed(
                completedRecord,
                error.localizedDescription
            )
        }
    }

    private func removePayloadContainerIfPresent(for record: QuarantineRecord) throws {
        let payloadContainer = record.quarantinedURL.deletingLastPathComponent()
        guard payloadContainer.lastPathComponent == record.id.uuidString else {
            throw QuarantineStoreError.invalidPayloadPath(record.id)
        }
        if itemExists(at: payloadContainer) {
            try fileManager.removeItem(at: payloadContainer)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

}
