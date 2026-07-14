import Foundation

public struct ScanCoordinator: Sendable {
    private let roots: [InventoryRoot]
    private let inventoryService: InventoryService
    private let ownershipResolver: OwnershipResolver
    private let ruleEngine: RuleEngine
    private let candidateSizer: CandidateSizer
    private let installedAppProvider: @Sendable () -> [InstalledApp]
    private let auditStore: AuditStore?

    public init(
        roots: [InventoryRoot],
        inventoryService: InventoryService,
        ownershipResolver: OwnershipResolver = OwnershipResolver(),
        ruleEngine: RuleEngine = RuleEngine(),
        candidateSizer: CandidateSizer = CandidateSizer(),
        installedAppProvider: @escaping @Sendable () -> [InstalledApp],
        auditStore: AuditStore? = nil
    ) {
        self.roots = roots
        self.inventoryService = inventoryService
        self.ownershipResolver = ownershipResolver
        self.ruleEngine = ruleEngine
        self.candidateSizer = candidateSizer
        self.installedAppProvider = installedAppProvider
        self.auditStore = auditStore
    }

    public func scan(scope: ScanScope, now: Date = .now) throws -> ScanReport {
        let installedApps = installedAppProvider()
        let inventorySnapshot = try inventoryService.scan(roots: roots, scope: scope)

        var candidates: [CleanupCandidate] = []
        var blockedArtifacts: [BlockedArtifact] = []
        var ignoredArtifactCount = 0

        for artifact in inventorySnapshot.artifacts {
            let ownerState = ownershipResolver.resolve(artifact: artifact, installedApps: installedApps)
            switch ruleEngine.classify(artifact: artifact, ownerState: ownerState, now: now) {
            case .candidate(let candidate):
                candidates.append(candidate)
            case .blocked(let blocked):
                blockedArtifacts.append(blocked)
            case .ignored:
                ignoredArtifactCount += 1
            }
        }

        // Real sizes for candidates that the user might approve. The cost is
        // bounded to candidates only — blocked items never get sized.
        candidates = try candidateSizer.sized(candidates)

        candidates.sort {
            if $0.riskTier != $1.riskTier {
                return $0.riskTier.sortOrder < $1.riskTier.sortOrder
            }
            return $0.artifact.sizeInBytes > $1.artifact.sizeInBytes
        }
        blockedArtifacts.sort { $0.artifact.sizeInBytes > $1.artifact.sizeInBytes }

        var warnings: [String] = []
        do {
            try auditStore?.append(
                snapshot: ScanSnapshotRecord(
                    scannedAt: now,
                    scope: scope,
                    scannedArtifactCount: inventorySnapshot.artifacts.count,
                    candidateCount: candidates.count,
                    blockedCount: blockedArtifacts.count,
                    inaccessibleRootCount: inventorySnapshot.permissionState.inaccessibleRoots.count
                )
            )
        } catch {
            // Audit persistence is important, but a logging failure must not
            // discard a valid read-only scan. Surface it as a non-fatal warning.
            warnings.append("Scan completed, but its audit snapshot could not be saved: \(error.localizedDescription)")
        }

        return ScanReport(
            scannedAt: now,
            scope: scope,
            permissionState: inventorySnapshot.permissionState,
            scannedArtifactCount: inventorySnapshot.artifacts.count,
            installedAppCount: installedApps.count,
            candidates: candidates,
            blockedArtifacts: blockedArtifacts,
            ignoredArtifactCount: ignoredArtifactCount,
            skippedRoots: inventorySnapshot.skippedRoots,
            warnings: warnings
        )
    }
}

private extension RiskTier {
    var sortOrder: Int {
        switch self {
        case .safe:
            return 0
        case .review:
            return 1
        case .blocked:
            return 2
        }
    }
}
