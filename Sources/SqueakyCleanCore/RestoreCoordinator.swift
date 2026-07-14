import Foundation

public enum RestoreCoordinatorError: Error, LocalizedError {
    case recordNotRestorable(UUID, QuarantineRecordStatus)
    case unsupportedFingerprintVersion(UUID, Int?)
    case fingerprintMismatch(UUID)
    case operationNeedsRecovery(URL, String)
    case operationCompletedButFinalizationFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .recordNotRestorable(let id, let status):
            return "Quarantine record \(id) cannot be restored while its status is \(status.rawValue)."
        case .unsupportedFingerprintVersion(let id, let version):
            let versionDescription = version.map(String.init) ?? "legacy"
            return "Quarantine record \(id) uses an unsupported \(versionDescription) fingerprint and cannot be restored automatically. Its payload was left untouched."
        case .fingerprintMismatch(let id):
            return "Quarantined payload \(id) changed after it was stored. Restore was stopped."
        case .operationNeedsRecovery(let url, let detail):
            return "Restore could not be finalized safely at \(url.path). Every surviving path was preserved for recovery: \(detail)"
        case .operationCompletedButFinalizationFailed(let url, let detail):
            return "The item was restored to \(url.path), but its manifest could not be finalized: \(detail)"
        }
    }
}

public final class RestoreCoordinator: @unchecked Sendable {
    private let quarantineStore: QuarantineStore
    private let pathPolicy: CleanupPathPolicy
    private let fileManager: FileManager
    private let payloadInspector: PayloadInspector

    public init(
        quarantineStore: QuarantineStore,
        pathPolicy: CleanupPathPolicy,
        fileManager: FileManager = .default
    ) {
        self.quarantineStore = quarantineStore
        self.pathPolicy = pathPolicy
        self.fileManager = fileManager
        self.payloadInspector = PayloadInspector(fileManager: fileManager)
    }

    @discardableResult
    public func restore(recordID: UUID, at date: Date = .now) throws -> URL {
        try quarantineStore.withExclusiveTransaction {
            try restoreWithinTransaction(recordID: recordID, at: date)
        }
    }

    private func restoreWithinTransaction(recordID: UUID, at date: Date) throws -> URL {
        let record = try quarantineStore.record(id: recordID)
        guard record.status == .quarantined else {
            throw RestoreCoordinatorError.recordNotRestorable(record.id, record.status)
        }

        guard record.fingerprintVersion == 2 else {
            throw RestoreCoordinatorError.unsupportedFingerprintVersion(
                record.id,
                record.fingerprintVersion
            )
        }
        let currentHash = try payloadInspector.contentHash(for: record.quarantinedURL)
        guard currentHash == record.contentHash else {
            throw RestoreCoordinatorError.fingerprintMismatch(record.id)
        }

        let proposedDestination = try uniqueRestoreURL(for: record.originalURL)
        let destinationURL = try pathPolicy.validateRestoreDestination(proposedDestination)
        let restoringRecord = record.restoring(to: destinationURL, at: date)

        // Persist the intended destination before moving the only payload.
        try quarantineStore.save(record: restoringRecord)
        do {
            let revalidatedDestination = try pathPolicy.validateRestoreDestination(destinationURL)
            guard revalidatedDestination == destinationURL else {
                throw CleanupPathPolicyError.changedSinceScan(destinationURL)
            }
            try quarantineStore.validateManagedPayload(for: restoringRecord)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: record.quarantinedURL, to: destinationURL)
        } catch {
            try? quarantineStore.save(record: record.quarantined())
            throw error
        }

        // Verify the object at its destination before finalizing the journal.
        // This closes the replacement/mutation window between the first hash and
        // the move. On mismatch, move the payload back rather than blessing it.
        do {
            let revalidatedDestination = try pathPolicy.validateRestoreDestination(destinationURL)
            guard revalidatedDestination == destinationURL else {
                throw CleanupPathPolicyError.changedSinceScan(destinationURL)
            }
            let restoredHash = try payloadInspector.contentHash(for: destinationURL)
            guard restoredHash == record.contentHash else {
                throw RestoreCoordinatorError.fingerprintMismatch(record.id)
            }
        } catch {
            let verificationError = error
            do {
                try fileManager.moveItem(at: destinationURL, to: record.quarantinedURL)
                try quarantineStore.save(record: record.quarantined())
            } catch {
                try? quarantineStore.save(record: restoringRecord.updating(status: .interrupted))
                throw RestoreCoordinatorError.operationNeedsRecovery(
                    destinationURL,
                    "\(verificationError.localizedDescription) Rollback also failed: \(error.localizedDescription)"
                )
            }
            throw verificationError
        }

        do {
            try quarantineStore.save(record: record.restored(to: destinationURL, at: date))
            return destinationURL
        } catch {
            // The restoring record contains enough information for startup
            // reconciliation to recognize the completed move.
            throw RestoreCoordinatorError.operationCompletedButFinalizationFailed(
                destinationURL,
                error.localizedDescription
            )
        }
    }

    private func uniqueRestoreURL(for originalURL: URL) throws -> URL {
        guard !fileManager.fileExists(atPath: originalURL.path) else {
            let baseName = originalURL.deletingPathExtension().lastPathComponent
            let fileExtension = originalURL.pathExtension
            let parent = originalURL.deletingLastPathComponent()

            var index = 1
            while true {
                let candidateName = fileExtension.isEmpty
                    ? "\(baseName) restored \(index)"
                    : "\(baseName) restored \(index).\(fileExtension)"
                let candidateURL = parent.appendingPathComponent(candidateName)
                if !fileManager.fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
                index += 1
            }
        }
        return originalURL
    }
}
