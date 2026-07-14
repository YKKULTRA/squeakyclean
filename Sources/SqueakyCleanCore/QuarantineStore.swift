import Darwin
import Foundation

private let systemFlock: @Sendable (Int32, Int32) -> Int32 = flock

public enum QuarantineStoreError: Error, LocalizedError {
    case missingRecord(UUID)
    case invalidPayloadRoot
    case invalidPayloadPath(UUID)
    case invalidPayloadName(String)
    case inconsistentRecord(UUID, String)

    public var errorDescription: String? {
        switch self {
        case .missingRecord(let id):
            return "Quarantine record \(id) does not exist."
        case .invalidPayloadRoot:
            return "The managed quarantine payload root has no stable filesystem identity."
        case .invalidPayloadPath(let id):
            return "Quarantine record \(id) points outside its managed payload directory."
        case .invalidPayloadName(let name):
            return "The payload name is not safe: \(name)"
        case .inconsistentRecord(let id, let detail):
            return "Quarantine record \(id) is inconsistent: \(detail)"
        }
    }
}

/// A serialized manifest store with an advisory filesystem lock shared by app
/// processes. Every payload path is derived from the store root and record UUID;
/// persisted URLs are validated before use.
public final class QuarantineStore: @unchecked Sendable {
    public let baseURL: URL
    public let payloadsURL: URL
    private let manifestURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()
    private let transactionLockURL: URL
    private let transactionLockDescriptor: Int32
    private let canonicalPayloadsURL: URL
    private let payloadsFileSystemNumber: UInt64
    private let payloadsFileSystemFileNumber: UInt64
    private var lockDepth = 0

    public init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL.standardizedFileURL
        self.payloadsURL = baseURL
            .appending(path: "Payloads", directoryHint: .isDirectory)
            .standardizedFileURL
        self.manifestURL = baseURL
            .appending(path: "quarantine-manifest.json")
            .standardizedFileURL
        self.transactionLockURL = baseURL
            .appending(path: "quarantine-transaction.lock")
            .standardizedFileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(at: self.baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: self.payloadsURL, withIntermediateDirectories: true)

        let payloadAttributes = try fileManager.attributesOfItem(atPath: self.payloadsURL.path)
        guard
            let payloadSystem = (payloadAttributes[.systemNumber] as? NSNumber)?.uint64Value,
            let payloadFile = (payloadAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw QuarantineStoreError.invalidPayloadRoot
        }
        self.canonicalPayloadsURL = self.payloadsURL.resolvingSymlinksInPath().standardizedFileURL
        self.payloadsFileSystemNumber = payloadSystem
        self.payloadsFileSystemFileNumber = payloadFile

        let descriptor = Darwin.open(
            self.transactionLockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.transactionLockDescriptor = descriptor

        do {
            try withLock {
                if !fileManager.fileExists(atPath: self.manifestURL.path) {
                    try saveRecords([])
                }
            }
            try reconcileInterruptedOperations()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(transactionLockDescriptor)
    }

    /// Serializes the complete intent/filesystem/finalization sequence across
    /// threads, store instances, and cooperating app processes.
    public func withExclusiveTransaction<T>(_ body: () throws -> T) throws -> T {
        try withLock(body)
    }

    public func payloadURL(recordID: UUID, originalURL: URL) throws -> URL {
        let name = originalURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw QuarantineStoreError.invalidPayloadName(name)
        }
        return payloadsURL
            .appendingPathComponent(recordID.uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
    }

    public func validateManagedPayload(for record: QuarantineRecord) throws {
        try withLock {
            try validatePayloadPath(record)
        }
    }

    public func allRecords() throws -> [QuarantineRecord] {
        try withLock {
            var records = try readRecords()
            if try reconcile(&records) {
                try saveRecords(records)
            }
            return records
        }
    }

    public func record(id: UUID) throws -> QuarantineRecord {
        guard let record = try allRecords().first(where: { $0.id == id }) else {
            throw QuarantineStoreError.missingRecord(id)
        }
        return record
    }

    public func save(record: QuarantineRecord) throws {
        try withLock {
            try validatePayloadPath(record)
            var records = try readRecords()
            records.removeAll { $0.id == record.id }
            records.append(record)
            try saveRecords(records.sorted { $0.createdAt < $1.createdAt })
        }
    }

    public func delete(recordID: UUID) throws {
        try withLock {
            var records = try readRecords()
            records.removeAll { $0.id == recordID }
            try saveRecords(records)
        }
    }

    public func reconcileInterruptedOperations() throws {
        try withLock {
            var records = try readRecords()
            if try reconcile(&records) {
                try saveRecords(records)
            }
        }
    }

    private func readRecords() throws -> [QuarantineRecord] {
        let data = try Data(contentsOf: manifestURL)
        let records = try decoder.decode([QuarantineRecord].self, from: data)
        try records.forEach(validatePayloadPath)
        return records
    }

    private func saveRecords(_ records: [QuarantineRecord]) throws {
        let data = try encoder.encode(records)
        try data.write(to: manifestURL, options: .atomic)
    }

    @discardableResult
    private func reconcile(_ records: inout [QuarantineRecord]) throws -> Bool {
        var changed = false
        var reconciled: [QuarantineRecord] = []

        for record in records {
            try validatePayloadPath(record)
            let payloadExists = itemExists(at: record.quarantinedURL)
            let originalExists = itemExists(at: record.originalURL)

            switch record.status {
            case .pending:
                if payloadExists, !originalExists {
                    let status: QuarantineRecordStatus = fingerprintMatches(record, at: record.quarantinedURL)
                        ? .quarantined
                        : .interrupted
                    reconciled.append(record.updating(status: status))
                    changed = true
                } else if !payloadExists, originalExists {
                    try? removePayloadContainer(for: record)
                    changed = true
                } else {
                    // Ambiguous states must never make the whole store unusable
                    // or trigger speculative deletion. Preserve the record for
                    // explicit user recovery and leave every surviving path alone.
                    reconciled.append(record.updating(status: .interrupted))
                    changed = true
                }

            case .restoring:
                guard let restoredURL = record.restoredURL else {
                    throw QuarantineStoreError.inconsistentRecord(record.id, "restore destination is missing")
                }
                let restoredExists = itemExists(at: restoredURL)
                if restoredExists, !payloadExists {
                    if fingerprintMatches(record, at: restoredURL) {
                        reconciled.append(record.restored(to: restoredURL, at: record.restoredAt ?? .now))
                    } else {
                        reconciled.append(record.updating(status: .interrupted))
                    }
                    changed = true
                } else if payloadExists {
                    // If the payload still exists, the move did not consume the
                    // recoverable copy. A destination collision is rolled back
                    // without touching the colliding destination.
                    reconciled.append(record.quarantined())
                    changed = true
                } else {
                    reconciled.append(record.updating(status: .interrupted))
                    changed = true
                }

            case .purging:
                if payloadExists {
                    reconciled.append(record.quarantined())
                } else {
                    try? removePayloadContainer(for: record)
                }
                changed = true

            case .quarantined:
                // A payload can be removed outside the app. Keep the record in
                // its known state so purge remains idempotent; restore will fail
                // closed when it cannot verify the missing payload.
                reconciled.append(record)

            case .restored, .interrupted:
                reconciled.append(record)
            }
        }

        if changed {
            records = reconciled.sorted { $0.createdAt < $1.createdAt }
        }
        return changed
    }

    private func validatePayloadPath(_ record: QuarantineRecord) throws {
        let rootValues = try payloadsURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        let rootAttributes = try fileManager.attributesOfItem(atPath: payloadsURL.path)
        let currentSystem = (rootAttributes[.systemNumber] as? NSNumber)?.uint64Value
        let currentFile = (rootAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard
            rootValues.isSymbolicLink != true,
            currentSystem == payloadsFileSystemNumber,
            currentFile == payloadsFileSystemFileNumber,
            payloadsURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalPayloadsURL.path
        else {
            throw QuarantineStoreError.invalidPayloadPath(record.id)
        }

        let expected = try payloadURL(recordID: record.id, originalURL: record.originalURL)
        guard expected.path == record.quarantinedURL.standardizedFileURL.path else {
            throw QuarantineStoreError.invalidPayloadPath(record.id)
        }

        let expectedContainer = payloadsURL
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .standardizedFileURL
        let actualContainer = record.quarantinedURL
            .deletingLastPathComponent()
            .standardizedFileURL
        guard expectedContainer.path == actualContainer.path else {
            throw QuarantineStoreError.invalidPayloadPath(record.id)
        }

        // When the container exists, also ensure an attacker has not replaced
        // it with a symlink that escapes the managed payload root.
        if itemExists(at: actualContainer) {
            let realPayloadRoot = payloadsURL.resolvingSymlinksInPath().standardizedFileURL
            let realContainer = actualContainer.resolvingSymlinksInPath().standardizedFileURL
            let expectedRealContainer = realPayloadRoot
                .appendingPathComponent(record.id.uuidString, isDirectory: true)
                .standardizedFileURL
            guard realContainer.path == expectedRealContainer.path else {
                throw QuarantineStoreError.invalidPayloadPath(record.id)
            }
        }
    }

    private func removePayloadContainer(for record: QuarantineRecord) throws {
        let container = record.quarantinedURL.deletingLastPathComponent()
        guard container.lastPathComponent == record.id.uuidString else {
            throw QuarantineStoreError.invalidPayloadPath(record.id)
        }
        if itemExists(at: container) {
            try fileManager.removeItem(at: container)
        }
    }

    private func itemExists(at url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func fingerprintMatches(_ record: QuarantineRecord, at url: URL) -> Bool {
        guard record.fingerprintVersion == 2 else { return false }
        return (try? PayloadInspector(fileManager: fileManager).contentHash(for: url)) == record.contentHash
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let isOutermostLock = lockDepth == 0
        if isOutermostLock {
            while systemFlock(transactionLockDescriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
        lockDepth += 1
        defer {
            lockDepth -= 1
            if isOutermostLock {
                _ = systemFlock(transactionLockDescriptor, LOCK_UN)
            }
        }
        return try body()
    }
}
