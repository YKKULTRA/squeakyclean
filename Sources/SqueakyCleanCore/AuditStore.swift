import Foundation

public final class AuditStore: @unchecked Sendable {
    private let baseURL: URL
    private let snapshotsURL: URL
    private let approvalsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()

    public init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL
        self.snapshotsURL = baseURL.appendingPathComponent("scan-snapshots.json")
        self.approvalsURL = baseURL.appendingPathComponent("approval-history.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: snapshotsURL.path) {
            try write([ScanSnapshotRecord](), to: snapshotsURL)
        }

        if !fileManager.fileExists(atPath: approvalsURL.path) {
            try write([ApprovalRecord](), to: approvalsURL)
        }
    }

    public func append(snapshot: ScanSnapshotRecord) throws {
        try withLock {
            var snapshots = try loadScanSnapshots()
            snapshots.append(snapshot)
            try write(snapshots, to: snapshotsURL)
        }
    }

    public func append(approval: ApprovalRecord) throws {
        try append(approvals: [approval])
    }

    public func append(approvals newApprovals: [ApprovalRecord]) throws {
        guard !newApprovals.isEmpty else { return }
        try withLock {
            var approvals = try loadApprovals()
            approvals.append(contentsOf: newApprovals)
            try write(approvals, to: approvalsURL)
        }
    }

    public func loadScanSnapshots() throws -> [ScanSnapshotRecord] {
        try withLock {
            try read([ScanSnapshotRecord].self, from: snapshotsURL)
        }
    }

    public func loadApprovals() throws -> [ApprovalRecord] {
        try withLock {
            try read([ApprovalRecord].self, from: approvalsURL)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
