import Foundation

public enum ScanScope: String, Codable, CaseIterable, Sendable {
    case standard
    case deep

    public func includes(_ rootScope: ScanScope) -> Bool {
        switch (self, rootScope) {
        case (.deep, _), (.standard, .standard):
            return true
        case (.standard, .deep):
            return false
        }
    }
}

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case applicationSupport
    case cache
    case log
    case temporary
    case launchAgent
    case launchDaemon
    case installerReceipt
    case preference
    case script
    case packageArchive
    case unknown
}

public enum RiskTier: String, Codable, Equatable, Sendable {
    case safe
    case review
    case blocked
}

public enum CleanupAction: String, Codable, Equatable, Sendable {
    case quarantine
    case restore
    case purge
    case removeRecord
}

public struct RuleEvidence: Codable, Equatable, Sendable {
    public let code: String
    public let summary: String

    public init(code: String, summary: String) {
        self.code = code
        self.summary = summary
    }
}

public struct ArtifactMetadata: Codable, Equatable, Sendable {
    public let ownerHint: String?
    public let launchTargetPath: String?
    public let launchTargetExists: Bool?
    public let fileSystemNumber: UInt64?
    public let fileSystemFileNumber: UInt64?
    public let isSymbolicLink: Bool?

    public init(
        ownerHint: String? = nil,
        launchTargetPath: String? = nil,
        launchTargetExists: Bool? = nil,
        fileSystemNumber: UInt64? = nil,
        fileSystemFileNumber: UInt64? = nil,
        isSymbolicLink: Bool? = nil
    ) {
        self.ownerHint = ownerHint
        self.launchTargetPath = launchTargetPath
        self.launchTargetExists = launchTargetExists
        self.fileSystemNumber = fileSystemNumber
        self.fileSystemFileNumber = fileSystemFileNumber
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct DiscoveredArtifact: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let kind: ArtifactKind
    public let sizeInBytes: Int64
    public let lastModifiedAt: Date
    public let metadata: ArtifactMetadata

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: ArtifactKind,
        sizeInBytes: Int64,
        lastModifiedAt: Date,
        metadata: ArtifactMetadata
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.sizeInBytes = sizeInBytes
        self.lastModifiedAt = lastModifiedAt
        self.metadata = metadata
    }
}

public struct InstalledApp: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String
    public let bundleURL: URL

    public init(bundleIdentifier: String, displayName: String, bundleURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.bundleURL = bundleURL
    }

    public func matches(ownerHint: String) -> Bool {
        let normalizedHint = ownerHint.normalizedOwnershipToken()
        let bundleName = bundleURL.deletingPathExtension().lastPathComponent
        let candidateNames = [bundleIdentifier, displayName, bundleName]
        let normalizedCandidates = candidateNames.map { $0.normalizedOwnershipToken() }

        if normalizedCandidates.contains(normalizedHint) {
            return true
        }

        let dottedHint = ownerHint.lowercased()
        let dottedBundleIdentifier = bundleIdentifier.lowercased()
        if dottedHint.hasPrefix(dottedBundleIdentifier + ".") || dottedBundleIdentifier.hasPrefix(dottedHint + ".") {
            return true
        }

        let hintTokens = ownerHint.ownershipTokens()
        let appSpecificNames = [
            displayName,
            bundleName,
            bundleIdentifier.components(separatedBy: ".").last ?? bundleIdentifier
        ]
        let appTokens = appSpecificNames.flatMap { $0.ownershipTokens() }
        return hintTokens.contains { hintToken in
            hintToken.count >= 4
                && !Self.genericBundleTokens.contains(hintToken)
                && appTokens.contains(hintToken)
        }
    }

    private static let genericBundleTokens: Set<String> = [
        "app",
        "apps",
        "com",
        "corp",
        "group",
        "inc",
        "io",
        "llc",
        "net",
        "org"
    ]
}

public enum OwnerState: Equatable, Sendable {
    case installed(InstalledApp)
    case orphaned(ownerHint: String?)
    case unknown
}

public struct CleanupCandidate: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let artifact: DiscoveredArtifact
    public let riskTier: RiskTier
    public let proposedAction: CleanupAction
    public let reason: String
    public let evidence: RuleEvidence

    public init(
        id: UUID = UUID(),
        artifact: DiscoveredArtifact,
        riskTier: RiskTier,
        proposedAction: CleanupAction,
        reason: String,
        evidence: RuleEvidence
    ) {
        self.id = id
        self.artifact = artifact
        self.riskTier = riskTier
        self.proposedAction = proposedAction
        self.reason = reason
        self.evidence = evidence
    }
}

public struct BlockedArtifact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let artifact: DiscoveredArtifact
    public let reason: String
    public let evidence: RuleEvidence

    public init(
        id: UUID = UUID(),
        artifact: DiscoveredArtifact,
        reason: String,
        evidence: RuleEvidence
    ) {
        self.id = id
        self.artifact = artifact
        self.reason = reason
        self.evidence = evidence
    }
}

public enum RuleDecision: Equatable, Sendable {
    case candidate(CleanupCandidate)
    case blocked(BlockedArtifact)
    case ignored
}

public struct InventoryRoot: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let url: URL
    public let artifactKind: ArtifactKind
    public let minimumScope: ScanScope

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        artifactKind: ArtifactKind,
        minimumScope: ScanScope
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.artifactKind = artifactKind
        self.minimumScope = minimumScope
    }
}

public enum RootAccess: Equatable, Sendable {
    case granted
    case restricted(String)
}

public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted
    case notGranted(String)
    case unknown(String)
}

public struct InaccessibleRoot: Equatable, Sendable {
    public let root: InventoryRoot
    public let reason: String

    public init(root: InventoryRoot, reason: String) {
        self.root = root
        self.reason = reason
    }
}

public struct PermissionState: Equatable, Sendable {
    public let scope: ScanScope
    public let inaccessibleRoots: [InaccessibleRoot]
    public let fullDiskAccessStatus: FullDiskAccessStatus

    public init(
        scope: ScanScope,
        inaccessibleRoots: [InaccessibleRoot],
        fullDiskAccessStatus: FullDiskAccessStatus = .unknown("Full Disk Access has not been checked.")
    ) {
        self.scope = scope
        self.inaccessibleRoots = inaccessibleRoots
        self.fullDiskAccessStatus = fullDiskAccessStatus
    }

    public var scanRootsReadable: Bool {
        inaccessibleRoots.isEmpty
    }

    public var deepScanAvailable: Bool {
        scanRootsReadable
    }
}

public struct SkippedRoot: Equatable, Sendable {
    public let root: InventoryRoot
    public let reason: String

    public init(root: InventoryRoot, reason: String) {
        self.root = root
        self.reason = reason
    }
}

public struct InventorySnapshot: Sendable {
    public let artifacts: [DiscoveredArtifact]
    public let skippedRoots: [SkippedRoot]
    public let permissionState: PermissionState

    public init(
        artifacts: [DiscoveredArtifact],
        skippedRoots: [SkippedRoot],
        permissionState: PermissionState
    ) {
        self.artifacts = artifacts
        self.skippedRoots = skippedRoots
        self.permissionState = permissionState
    }
}

public struct ScanReport: Sendable {
    public let scannedAt: Date
    public let scope: ScanScope
    public let permissionState: PermissionState
    public let scannedArtifactCount: Int
    public let installedAppCount: Int
    public let candidates: [CleanupCandidate]
    public let blockedArtifacts: [BlockedArtifact]
    public let ignoredArtifactCount: Int
    public let skippedRoots: [SkippedRoot]
    public let warnings: [String]

    public init(
        scannedAt: Date,
        scope: ScanScope,
        permissionState: PermissionState,
        scannedArtifactCount: Int,
        installedAppCount: Int,
        candidates: [CleanupCandidate],
        blockedArtifacts: [BlockedArtifact],
        ignoredArtifactCount: Int = 0,
        skippedRoots: [SkippedRoot] = [],
        warnings: [String] = []
    ) {
        self.scannedAt = scannedAt
        self.scope = scope
        self.permissionState = permissionState
        self.scannedArtifactCount = scannedArtifactCount
        self.installedAppCount = installedAppCount
        self.candidates = candidates
        self.blockedArtifacts = blockedArtifacts
        self.ignoredArtifactCount = ignoredArtifactCount
        self.skippedRoots = skippedRoots
        self.warnings = warnings
    }

    public var totalRecoverableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.artifact.sizeInBytes }
    }
}

public struct ScanSnapshotRecord: Codable, Equatable, Sendable {
    public let scannedAt: Date
    public let scope: ScanScope
    public let scannedArtifactCount: Int
    public let candidateCount: Int
    public let blockedCount: Int
    public let inaccessibleRootCount: Int

    public init(
        scannedAt: Date,
        scope: ScanScope,
        scannedArtifactCount: Int,
        candidateCount: Int,
        blockedCount: Int,
        inaccessibleRootCount: Int
    ) {
        self.scannedAt = scannedAt
        self.scope = scope
        self.scannedArtifactCount = scannedArtifactCount
        self.candidateCount = candidateCount
        self.blockedCount = blockedCount
        self.inaccessibleRootCount = inaccessibleRootCount
    }
}

public struct ApprovalRecord: Codable, Equatable, Sendable {
    public let executedAt: Date
    public let artifactURL: URL
    public let action: CleanupAction
    public let reason: String
    public let evidenceSummary: String

    public init(
        executedAt: Date,
        artifactURL: URL,
        action: CleanupAction,
        reason: String,
        evidenceSummary: String
    ) {
        self.executedAt = executedAt
        self.artifactURL = artifactURL
        self.action = action
        self.reason = reason
        self.evidenceSummary = evidenceSummary
    }
}

public enum QuarantineRecordStatus: String, Codable, Equatable, Sendable {
    case pending
    case quarantined
    case restoring
    case restored
    case purging
    case interrupted
}

public struct QuarantineRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let artifactKind: ArtifactKind
    public let originalURL: URL
    public let quarantinedURL: URL
    public let recordedSizeBytes: Int64
    public let contentHash: String
    public let fingerprintVersion: Int?
    public let reason: String
    public let evidenceSummary: String
    public let createdAt: Date
    public let status: QuarantineRecordStatus
    public let restoredURL: URL?
    public let restoredAt: Date?

    public init(
        id: UUID,
        artifactKind: ArtifactKind,
        originalURL: URL,
        quarantinedURL: URL,
        recordedSizeBytes: Int64,
        contentHash: String,
        fingerprintVersion: Int? = 2,
        reason: String,
        evidenceSummary: String,
        createdAt: Date,
        status: QuarantineRecordStatus = .quarantined,
        restoredURL: URL? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.artifactKind = artifactKind
        self.originalURL = originalURL
        self.quarantinedURL = quarantinedURL
        self.recordedSizeBytes = recordedSizeBytes
        self.contentHash = contentHash
        self.fingerprintVersion = fingerprintVersion
        self.reason = reason
        self.evidenceSummary = evidenceSummary
        self.createdAt = createdAt
        self.status = status
        self.restoredURL = restoredURL
        self.restoredAt = restoredAt
    }

    public func restored(to url: URL, at date: Date) -> QuarantineRecord {
        updating(status: .restored, restoredURL: url, restoredAt: date)
    }

    public func restoring(to url: URL, at date: Date) -> QuarantineRecord {
        updating(status: .restoring, restoredURL: url, restoredAt: date)
    }

    public func quarantined() -> QuarantineRecord {
        updating(status: .quarantined, restoredURL: nil, restoredAt: nil)
    }

    public func updating(status: QuarantineRecordStatus) -> QuarantineRecord {
        updating(status: status, restoredURL: restoredURL, restoredAt: restoredAt)
    }

    private func updating(
        status: QuarantineRecordStatus,
        restoredURL: URL?,
        restoredAt: Date?
    ) -> QuarantineRecord {
        QuarantineRecord(
            id: id,
            artifactKind: artifactKind,
            originalURL: originalURL,
            quarantinedURL: quarantinedURL,
            recordedSizeBytes: recordedSizeBytes,
            contentHash: contentHash,
            fingerprintVersion: fingerprintVersion,
            reason: reason,
            evidenceSummary: evidenceSummary,
            createdAt: createdAt,
            status: status,
            restoredURL: restoredURL,
            restoredAt: restoredAt
        )
    }
}

extension String {
    fileprivate func normalizedOwnershipToken() -> String {
        lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    fileprivate func ownershipTokens() -> [String] {
        lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
