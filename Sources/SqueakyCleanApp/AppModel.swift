import AppKit
import Foundation
import SqueakyCleanCore

private enum ScanOutcome: Sendable {
    case success(ScanReport)
    case cancelled
    case failure(String)
}

private struct HistoryState: Sendable {
    let quarantineRecords: [QuarantineRecord]
    let approvalHistory: [ApprovalRecord]
    let scanSnapshots: [ScanSnapshotRecord]
}

private enum HistoryOutcome: Sendable {
    case success(HistoryState)
    case failure(String)
}

private struct QuarantineMutationOutcome: Sendable {
    let quarantinedIDs: Set<CleanupCandidate.ID>
    let history: HistoryOutcome
    let message: String?
}

private struct PurgeMutationOutcome: Sendable {
    let recordID: QuarantineRecord.ID
    let actionSucceeded: Bool
    let history: HistoryOutcome
    let message: String?
}

private struct EmptyQuarantineMutationOutcome: Sendable {
    let history: HistoryOutcome
    let message: String?
}

private struct RestoreMutationOutcome: Sendable {
    let history: HistoryOutcome
    let message: String?
}

private func loadHistory(
    quarantineStore: QuarantineStore?,
    auditStore: AuditStore?
) -> HistoryOutcome {
    do {
        let quarantineRecords = try quarantineStore?.allRecords()
            .sorted(by: { $0.createdAt > $1.createdAt }) ?? []
        let approvalHistory = try auditStore?.loadApprovals()
            .sorted(by: { $0.executedAt > $1.executedAt }) ?? []
        let scanSnapshots = try auditStore?.loadScanSnapshots()
            .sorted(by: { $0.scannedAt > $1.scannedAt }) ?? []
        return .success(
            HistoryState(
                quarantineRecords: quarantineRecords,
                approvalHistory: approvalHistory,
                scanSnapshots: scanSnapshots
            )
        )
    } catch {
        return .failure("Failed to load local history: \(error.localizedDescription)")
    }
}

private func performQuarantineMutation(
    candidates: [CleanupCandidate],
    cleanupCoordinator: CleanupCoordinator,
    quarantineStore: QuarantineStore?,
    auditStore: AuditStore?
) -> QuarantineMutationOutcome {
    var quarantinedIDs = Set<CleanupCandidate.ID>()
    var approvals: [ApprovalRecord] = []
    var firstError: String?
    var firstWarning: String?

    for candidate in candidates {
        do {
            _ = try cleanupCoordinator.quarantine(candidate: candidate, at: Date())
            quarantinedIDs.insert(candidate.id)
            approvals.append(
                ApprovalRecord(
                    executedAt: Date(),
                    artifactURL: candidate.artifact.url,
                    action: .quarantine,
                    reason: candidate.reason,
                    evidenceSummary: candidate.evidence.summary
                )
            )
        } catch CleanupCoordinatorError.operationCompletedButFinalizationFailed {
            // The pending journal was written before the move. Treat the
            // filesystem action as successful and let the history read reconcile it.
            quarantinedIDs.insert(candidate.id)
            approvals.append(
                ApprovalRecord(
                    executedAt: Date(),
                    artifactURL: candidate.artifact.url,
                    action: .quarantine,
                    reason: candidate.reason,
                    evidenceSummary: candidate.evidence.summary
                )
            )
            if firstWarning == nil {
                firstWarning = "An item was moved safely, but its manifest needed recovery."
            }
        } catch {
            if firstError == nil {
                firstError = "\(candidate.artifact.url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    if !approvals.isEmpty {
        do {
            try auditStore?.append(approvals: approvals)
        } catch {
            firstWarning = "Cleanup succeeded, but its audit history could not be saved: \(error.localizedDescription)"
        }
    }

    let message: String?
    if let firstError {
        if quarantinedIDs.isEmpty {
            message = "Failed to quarantine: \(firstError)"
        } else {
            message = "Quarantined \(quarantinedIDs.count) of \(candidates.count). First error: \(firstError)"
        }
    } else {
        message = firstWarning
    }

    return QuarantineMutationOutcome(
        quarantinedIDs: quarantinedIDs,
        history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
        message: message
    )
}

private func performPurgeMutation(
    record: QuarantineRecord,
    cleanupCoordinator: CleanupCoordinator,
    quarantineStore: QuarantineStore?,
    auditStore: AuditStore?
) -> PurgeMutationOutcome {
    do {
        try cleanupCoordinator.purge(recordID: record.id)
    } catch {
        let verb = record.status == .restored ? "remove history record" : "permanently delete item"
        return PurgeMutationOutcome(
            recordID: record.id,
            actionSucceeded: false,
            history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
            message: "Failed to \(verb): \(error.localizedDescription)"
        )
    }

    var warning: String?
    do {
        try auditStore?.append(
            approval: ApprovalRecord(
                executedAt: Date(),
                artifactURL: record.originalURL,
                action: record.status == .restored ? .removeRecord : .purge,
                reason: record.reason,
                evidenceSummary: record.evidenceSummary
            )
        )
    } catch {
        warning = "The action succeeded, but its audit history could not be saved: \(error.localizedDescription)"
    }

    return PurgeMutationOutcome(
        recordID: record.id,
        actionSucceeded: true,
        history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
        message: warning
    )
}

private func performEmptyQuarantineMutation(
    cleanupCoordinator: CleanupCoordinator,
    quarantineStore: QuarantineStore?,
    auditStore: AuditStore?
) -> EmptyQuarantineMutationOutcome {
    var purged: [QuarantineRecord] = []
    var operationError: String?
    do {
        purged = try cleanupCoordinator.purgeAll()
    } catch CleanupCoordinatorError.partialPurge(let completed, let detail) {
        purged = completed
        operationError = detail
    } catch {
        operationError = error.localizedDescription
    }

    let approvals = purged.map { record in
        ApprovalRecord(
            executedAt: Date(),
            artifactURL: record.originalURL,
            action: .purge,
            reason: record.reason,
            evidenceSummary: record.evidenceSummary
        )
    }
    var auditError: String?
    do {
        try auditStore?.append(approvals: approvals)
    } catch {
        auditError = error.localizedDescription
    }

    let message: String?
    if let operationError {
        message = "Permanently deleted \(purged.count) item(s), then stopped: \(operationError)"
    } else if let auditError {
        message = "Quarantine was emptied, but its audit history could not be saved: \(auditError)"
    } else {
        message = nil
    }

    return EmptyQuarantineMutationOutcome(
        history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
        message: message
    )
}

private func performRestoreMutation(
    record: QuarantineRecord,
    restoreCoordinator: RestoreCoordinator,
    quarantineStore: QuarantineStore?,
    auditStore: AuditStore?
) -> RestoreMutationOutcome {
    let restoredURL: URL
    var finalizationWarning: String?
    do {
        restoredURL = try restoreCoordinator.restore(recordID: record.id, at: Date())
    } catch RestoreCoordinatorError.operationCompletedButFinalizationFailed(let url, let detail) {
        restoredURL = url
        finalizationWarning = detail
    } catch {
        return RestoreMutationOutcome(
            history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
            message: "Failed to restore item: \(error.localizedDescription)"
        )
    }

    var auditWarning: String?
    do {
        try auditStore?.append(
            approval: ApprovalRecord(
                executedAt: Date(),
                artifactURL: restoredURL,
                action: .restore,
                reason: record.reason,
                evidenceSummary: record.evidenceSummary
            )
        )
    } catch {
        auditWarning = error.localizedDescription
    }

    let message: String?
    if let finalizationWarning {
        message = "The item was restored, but its manifest needed recovery: \(finalizationWarning)"
    } else if let auditWarning {
        message = "The item was restored, but its audit history could not be saved: \(auditWarning)"
    } else {
        message = nil
    }

    return RestoreMutationOutcome(
        history: loadHistory(quarantineStore: quarantineStore, auditStore: auditStore),
        message: message
    )
}

@MainActor
final class AppModel: ObservableObject {
    @Published var scope: ScanScope = .standard
    @Published var report: ScanReport?
    @Published var quarantineRecords: [QuarantineRecord] = []
    @Published var approvalHistory: [ApprovalRecord] = []
    @Published var scanSnapshots: [ScanSnapshotRecord] = []
    @Published var selectedCandidateIDs: Set<CleanupCandidate.ID> = []
    @Published var selectedRecordID: QuarantineRecord.ID?
    @Published var isScanning = false
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?
    @Published var candidateSearchText: String = ""
    @Published var candidateKindFilter: ArtifactKind?
    @Published var fullDiskAccessStatus: FullDiskAccessStatus = .unknown("Full Disk Access has not been checked.")

    private var scanTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    private let auditStore: AuditStore?
    private let quarantineStore: QuarantineStore?
    private let cleanupCoordinator: CleanupCoordinator?
    private let restoreCoordinator: RestoreCoordinator?
    private let scanCoordinator: ScanCoordinator?

    init() {
        let roots = DefaultScanProfile.roots()
        let inventoryService = InventoryService()
        var initializedAuditStore: AuditStore?
        var initializedQuarantineStore: QuarantineStore?
        var initializedCleanupCoordinator: CleanupCoordinator?
        var initializedRestoreCoordinator: RestoreCoordinator?
        var initializationWarnings: [String] = []

        do {
            let directories = try AppDirectories.live()

            do {
                initializedAuditStore = try AuditStore(baseURL: directories.auditRoot)
            } catch {
                initializationWarnings.append(
                    "Audit history is unavailable: \(error.localizedDescription)"
                )
            }

            do {
                let quarantineStore = try QuarantineStore(baseURL: directories.quarantineRoot)
                let cleanupRoots = roots
                    .filter { $0.minimumScope == .standard }
                    .map(\.url)
                let pathPolicy = CleanupPathPolicy(
                    allowedRoots: cleanupRoots,
                    protectedRoots: [directories.baseRoot]
                )
                initializedQuarantineStore = quarantineStore
                initializedCleanupCoordinator = CleanupCoordinator(
                    quarantineStore: quarantineStore,
                    pathPolicy: pathPolicy
                )
                initializedRestoreCoordinator = RestoreCoordinator(
                    quarantineStore: quarantineStore,
                    pathPolicy: pathPolicy
                )
            } catch {
                initializationWarnings.append(
                    "Quarantine and restore are unavailable: \(error.localizedDescription)"
                )
            }
        } catch {
            initializationWarnings.append(
                "Local app storage is unavailable: \(error.localizedDescription)"
            )
        }

        self.auditStore = initializedAuditStore
        self.quarantineStore = initializedQuarantineStore
        self.cleanupCoordinator = initializedCleanupCoordinator
        self.restoreCoordinator = initializedRestoreCoordinator
        self.scanCoordinator = ScanCoordinator(
            roots: roots,
            inventoryService: inventoryService,
            installedAppProvider: { InstalledAppCatalog().snapshot() },
            auditStore: initializedAuditStore
        )
        if !initializationWarnings.isEmpty {
            self.errorMessage = initializationWarnings.joined(separator: "\n")
        }

        refreshHistory()
    }

    var filteredCandidates: [CleanupCandidate] {
        guard let report else { return [] }
        let needle = candidateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return report.candidates.filter { candidate in
            if let kind = candidateKindFilter, candidate.artifact.kind != kind {
                return false
            }
            guard !needle.isEmpty else { return true }
            if candidate.artifact.url.lastPathComponent.lowercased().contains(needle) {
                return true
            }
            if candidate.artifact.url.path.lowercased().contains(needle) {
                return true
            }
            if candidate.artifact.metadata.ownerHint?.lowercased().contains(needle) == true {
                return true
            }
            return false
        }
    }

    var selectedCandidates: [CleanupCandidate] {
        filteredCandidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    var selectedCandidate: CleanupCandidate? {
        selectedCandidates.count == 1 ? selectedCandidates.first : nil
    }

    var selectedRecord: QuarantineRecord? {
        quarantineRecords.first(where: { $0.id == selectedRecordID })
    }

    var availableKinds: [ArtifactKind] {
        guard let report else { return [] }
        let kinds = Set(report.candidates.map { $0.artifact.kind })
        return ArtifactKind.allCases.filter { kinds.contains($0) }
    }

    var selectedRecoverableBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.artifact.sizeInBytes }
    }

    func runScan() {
        guard let scanCoordinator else {
            errorMessage = "Scanning is unavailable because the core services could not be initialized."
            return
        }

        guard !isScanning, !isMutating else { return }
        isScanning = true
        let scope = self.scope

        scanTask = Task.detached(priority: .userInitiated) { [weak self, scanCoordinator, scope] in
            let outcome: ScanOutcome
            do {
                let report = try scanCoordinator.scan(scope: scope, now: Date())
                outcome = .success(report)
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            await self?.applyScanOutcome(outcome)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func applyScanOutcome(_ outcome: ScanOutcome) {
        switch outcome {
        case .success(let report):
            self.report = report
            self.fullDiskAccessStatus = report.permissionState.fullDiskAccessStatus
            self.selectedCandidateIDs = []
            refreshHistory()
            if errorMessage == nil, !report.warnings.isEmpty {
                errorMessage = report.warnings.joined(separator: "\n")
            }
        case .cancelled:
            // Keep the existing report (if any) and stay quiet — the user
            // initiated this and doesn't need an error popup.
            break
        case .failure(let message):
            errorMessage = "Scan failed: \(message)"
        }
        isScanning = false
        scanTask = nil
    }

    func quarantineSelected() {
        let targets = selectedCandidates
        guard !targets.isEmpty else { return }
        quarantine(candidates: targets)
    }

    func quarantine(candidate: CleanupCandidate) {
        quarantine(candidates: [candidate])
    }

    private func quarantine(candidates: [CleanupCandidate]) {
        guard let cleanupCoordinator else {
            errorMessage = "Cleanup is unavailable because the quarantine store could not be initialized."
            return
        }

        guard !isScanning, !isMutating else { return }
        guard report?.scope == scope else {
            errorMessage = "Run a current scan before approving cleanup."
            return
        }

        isMutating = true
        let quarantineStore = self.quarantineStore
        let auditStore = self.auditStore
        mutationTask = Task.detached(priority: .userInitiated) { [
            weak self,
            candidates,
            cleanupCoordinator,
            quarantineStore,
            auditStore
        ] in
            let outcome = performQuarantineMutation(
                candidates: candidates,
                cleanupCoordinator: cleanupCoordinator,
                quarantineStore: quarantineStore,
                auditStore: auditStore
            )
            await self?.applyQuarantineMutationOutcome(outcome)
        }
    }

    private func applyQuarantineMutationOutcome(_ outcome: QuarantineMutationOutcome) {
        if !outcome.quarantinedIDs.isEmpty, let report {
            self.report = ScanReport(
                scannedAt: report.scannedAt,
                scope: report.scope,
                permissionState: report.permissionState,
                scannedArtifactCount: report.scannedArtifactCount,
                installedAppCount: report.installedAppCount,
                candidates: report.candidates.filter { !outcome.quarantinedIDs.contains($0.id) },
                blockedArtifacts: report.blockedArtifacts,
                ignoredArtifactCount: report.ignoredArtifactCount,
                skippedRoots: report.skippedRoots,
                warnings: report.warnings
            )
        }
        selectedCandidateIDs.subtract(outcome.quarantinedIDs)
        let historyError = applyHistoryOutcome(outcome.history)
        if let message = outcome.message ?? historyError {
            errorMessage = message
        }
        finishMutation()
    }

    func purge(record: QuarantineRecord) {
        guard let cleanupCoordinator else {
            errorMessage = "Cleanup is unavailable because the quarantine store could not be initialized."
            return
        }

        guard !isScanning, !isMutating else { return }

        isMutating = true
        let quarantineStore = self.quarantineStore
        let auditStore = self.auditStore
        mutationTask = Task.detached(priority: .userInitiated) { [
            weak self,
            record,
            cleanupCoordinator,
            quarantineStore,
            auditStore
        ] in
            let outcome = performPurgeMutation(
                record: record,
                cleanupCoordinator: cleanupCoordinator,
                quarantineStore: quarantineStore,
                auditStore: auditStore
            )
            await self?.applyPurgeMutationOutcome(outcome)
        }
    }

    private func applyPurgeMutationOutcome(_ outcome: PurgeMutationOutcome) {
        if outcome.actionSucceeded, selectedRecordID == outcome.recordID {
            selectedRecordID = nil
        }
        let historyError = applyHistoryOutcome(outcome.history)
        if let message = outcome.message ?? historyError {
            errorMessage = message
        }
        finishMutation()
    }

    func emptyQuarantine() {
        guard let cleanupCoordinator else {
            errorMessage = "Cleanup is unavailable because the quarantine store could not be initialized."
            return
        }

        guard !isScanning, !isMutating else { return }

        isMutating = true
        let quarantineStore = self.quarantineStore
        let auditStore = self.auditStore
        mutationTask = Task.detached(priority: .userInitiated) { [
            weak self,
            cleanupCoordinator,
            quarantineStore,
            auditStore
        ] in
            let outcome = performEmptyQuarantineMutation(
                cleanupCoordinator: cleanupCoordinator,
                quarantineStore: quarantineStore,
                auditStore: auditStore
            )
            await self?.applyEmptyQuarantineMutationOutcome(outcome)
        }
    }

    private func applyEmptyQuarantineMutationOutcome(_ outcome: EmptyQuarantineMutationOutcome) {
        selectedRecordID = nil
        let historyError = applyHistoryOutcome(outcome.history)
        if let message = outcome.message ?? historyError {
            errorMessage = message
        }
        finishMutation()
    }

    var hasQuarantinedItems: Bool {
        quarantineRecords.contains { $0.status == .quarantined }
    }

    func restoreSelectedRecord() {
        guard let record = selectedRecord else { return }
        restore(record: record)
    }

    func restore(record: QuarantineRecord) {
        guard let restoreCoordinator else {
            errorMessage = "Restore is unavailable because the quarantine store could not be initialized."
            return
        }

        guard !isScanning, !isMutating else { return }

        isMutating = true
        let quarantineStore = self.quarantineStore
        let auditStore = self.auditStore
        mutationTask = Task.detached(priority: .userInitiated) { [
            weak self,
            record,
            restoreCoordinator,
            quarantineStore,
            auditStore
        ] in
            let outcome = performRestoreMutation(
                record: record,
                restoreCoordinator: restoreCoordinator,
                quarantineStore: quarantineStore,
                auditStore: auditStore
            )
            await self?.applyRestoreMutationOutcome(outcome)
        }
    }

    private func applyRestoreMutationOutcome(_ outcome: RestoreMutationOutcome) {
        let historyError = applyHistoryOutcome(outcome.history)
        if let message = outcome.message ?? historyError {
            errorMessage = message
        }
        finishMutation()
    }

    private func applyHistoryOutcome(_ outcome: HistoryOutcome) -> String? {
        switch outcome {
        case .success(let history):
            quarantineRecords = history.quarantineRecords
            approvalHistory = history.approvalHistory
            scanSnapshots = history.scanSnapshots
            if selectedRecordID == nil {
                selectedRecordID = quarantineRecords.first?.id
            }
            return nil
        case .failure(let message):
            return message
        }
    }

    private func finishMutation() {
        isMutating = false
        mutationTask = nil
    }

    func refreshHistory() {
        do {
            quarantineRecords = try quarantineStore?.allRecords().sorted(by: { $0.createdAt > $1.createdAt }) ?? []
            approvalHistory = try auditStore?.loadApprovals().sorted(by: { $0.executedAt > $1.executedAt }) ?? []
            scanSnapshots = try auditStore?.loadScanSnapshots().sorted(by: { $0.scannedAt > $1.scannedAt }) ?? []
            if selectedRecordID == nil {
                selectedRecordID = quarantineRecords.first?.id
            }
        } catch {
            errorMessage = "Failed to load local history: \(error.localizedDescription)"
        }
    }

    func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for value in urls {
            guard let url = URL(string: value) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        errorMessage = "Could not open Privacy & Security settings."
    }

    func checkFullDiskAccess() {
        fullDiskAccessStatus = PermissionCoordinator.liveFullDiskAccessProbe()
    }

    func revealAppBundleForFullDiskAccess() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            errorMessage = "Could not find the running app on disk."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([executableURL])
    }

    func dismissError() {
        errorMessage = nil
    }
}

private struct AppDirectories {
    let baseRoot: URL
    let auditRoot: URL
    let quarantineRoot: URL

    static func live(fileManager: FileManager = .default) throws -> AppDirectories {
        let baseRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SqueakyClean", isDirectory: true)
        let auditRoot = baseRoot.appendingPathComponent("Audit", isDirectory: true)
        let quarantineRoot = baseRoot.appendingPathComponent("Quarantine", isDirectory: true)

        try fileManager.createDirectory(at: baseRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: auditRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        return AppDirectories(baseRoot: baseRoot, auditRoot: auditRoot, quarantineRoot: quarantineRoot)
    }
}
