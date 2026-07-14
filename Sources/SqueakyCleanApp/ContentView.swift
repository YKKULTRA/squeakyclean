import SwiftUI
import SqueakyCleanCore

private extension AppModel {
    var isBusy: Bool {
        isScanning || isMutating
    }

    var scanResultsAreStale: Bool {
        guard let report else { return false }
        return report.scope != scope
    }

    var candidateMutationsAreDisabled: Bool {
        isBusy || scanResultsAreStale
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ScanWorkspaceView()
                .tabItem {
                    Label("Scan", systemImage: "magnifyingglass")
                }

            QuarantineHistoryView()
                .tabItem {
                    Label("Quarantine", systemImage: "archivebox")
                }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("SqueakyClean", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    model.dismissError()
                }
            }
        )) {
            Button("OK", role: .cancel) {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct ScanWorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ScanHeaderView()
            PermissionStatusCard()

            HSplitView {
                CandidateListView()
                    .frame(minWidth: 420)

                CandidateDetailView()
                    .frame(minWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct ScanHeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text("SqueakyClean")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))

                Spacer()

                Picker("Scan depth", selection: $model.scope) {
                    Text("Standard").tag(ScanScope.standard)
                    Text("Deep (Read Only)").tag(ScanScope.deep)
                }
                .pickerStyle(.segmented)
                .frame(width: 290)
                .disabled(model.isBusy)

                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Button {
                        model.cancelScan()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if model.isMutating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying Changes…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.runScan()
                    } label: {
                        Label("Run Scan", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 14) {
                if let report = model.report {
                    Label("\(report.scope.rawValue.capitalized) scope", systemImage: "scope")
                    Label(
                        "Completed \(report.scannedAt.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "clock"
                    )
                    if model.scanResultsAreStale {
                        AccessBadge(title: "Results Stale", color: .orange)
                    }
                } else {
                    Label("No completed scan", systemImage: "clock.badge.questionmark")
                }
                Spacer()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if model.scope == .deep {
                Label(
                    "Deep scope inspects system-wide locations for analysis only. Findings there are never offered as cleanup candidates in this release.",
                    systemImage: "eye"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.scanResultsAreStale, let report = model.report {
                Label(
                    "These results came from a \(report.scope.rawValue.capitalized) scan, but \(model.scope.rawValue.capitalized) is selected. Run a new scan before quarantining any result.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 160)),
                GridItem(.flexible(minimum: 160)),
                GridItem(.flexible(minimum: 160)),
                GridItem(.flexible(minimum: 160))
            ], alignment: .leading, spacing: 12) {
                MetricCard(
                    title: "Estimated After Purge",
                    value: model.report.map {
                        ByteCountFormatter.string(fromByteCount: $0.totalRecoverableBytes, countStyle: .file)
                    } ?? "Not scanned",
                    caption: model.report == nil
                        ? "Run a scan to estimate reclaimable space"
                        : "Quarantine stays on disk; purging reclaims space"
                )
                MetricCard(
                    title: "Candidates",
                    value: model.report.map { "\($0.candidates.count)" } ?? "Not scanned",
                    caption: model.report == nil ? "Run a scan to review findings" : "Ready for guided review"
                )
                MetricCard(
                    title: "Blocked",
                    value: model.report.map { "\($0.blockedArtifacts.count)" } ?? "Not scanned",
                    caption: model.report == nil ? "Run a scan to apply safety rules" : "Protected by safety rules"
                )
                MetricCard(
                    title: "Scanned",
                    value: model.report.map { "\($0.scannedArtifactCount)" } ?? "Not scanned",
                    caption: model.report.map {
                        "\($0.ignoredArtifactCount) unmatched items left untouched"
                    } ?? "No scan report yet"
                )
            }
        }
    }
}

private struct PermissionStatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Disk Access", systemImage: "externaldrive.badge.checkmark")
                    .font(.headline)
                Spacer()
                AccessBadge(title: fullDiskAccessBadge.title, color: fullDiskAccessBadge.color)
                if let report = model.report {
                    let scanIsComplete = report.permissionState.scanRootsReadable
                        && report.skippedRoots.isEmpty
                    AccessBadge(
                        title: scanIsComplete ? "Scan Complete" : "Scan Limited",
                        color: scanIsComplete ? .green : .orange
                    )
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Full Disk Access is optional. Start without it and grant it only if a scan lists protected locations you deliberately want SqueakyClean to inspect.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Granting access expands what the app can read. Keep the narrower access unless those additional locations are necessary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fullDiskAccessDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            model.openFullDiskAccessSettings()
                        } label: {
                            Label("Open Optional Access Settings", systemImage: "gearshape")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            model.checkFullDiskAccess()
                        } label: {
                            Label("Check Access", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            model.revealAppBundleForFullDiskAccess()
                        } label: {
                            Label("Show App in Finder", systemImage: "finder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let report = model.report, !report.skippedRoots.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Skipped \(report.skippedRoots.count) location\(report.skippedRoots.count == 1 ? "" : "s")",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                        ForEach(report.skippedRoots.prefix(3), id: \.root.id) { skipped in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skipped.root.name)
                                    .font(.subheadline.weight(.medium))
                                Text(skipped.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        if report.skippedRoots.count > 3 {
                            Text("And \(report.skippedRoots.count - 3) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fullDiskAccessBadge: (title: String, color: Color) {
        switch model.fullDiskAccessStatus {
        case .granted:
            return ("Protected Access Check Passed", .green)
        case .notGranted:
            return ("Full Disk Access Off (Optional)", .secondary)
        case .unknown:
            return ("Full Disk Access Not Checked", .secondary)
        }
    }

    private var fullDiskAccessDetail: String {
        switch model.fullDiskAccessStatus {
        case .granted:
            return "Every protected sample location present on this Mac was readable."
        case .notGranted(let reason):
            return reason
        case .unknown(let reason):
            return reason
        }
    }
}

private struct CandidateListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Candidates")
                    .font(.headline)
                Spacer()
                if model.report != nil {
                    Text("\(model.filteredCandidates.count) shown")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if model.report != nil {
                HStack(spacing: 8) {
                    TextField("Search name, path, or owner", text: $model.candidateSearchText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Kind", selection: $model.candidateKindFilter) {
                        Text("All Kinds").tag(ArtifactKind?.none)
                        ForEach(model.availableKinds, id: \.self) { kind in
                            Text(kind.rawValue).tag(ArtifactKind?.some(kind))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if let report = model.report, !report.candidates.isEmpty {
                let filtered = model.filteredCandidates
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the search text or kind filter to see more candidates.")
                    )
                } else {
                    List(filtered, selection: $model.selectedCandidateIDs) { candidate in
                        CandidateRow(candidate: candidate)
                            .tag(candidate.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else {
                ContentUnavailableView(
                    "No candidates yet",
                    systemImage: "checkmark.shield",
                    description: Text("Run a scan to review only findings backed by cleanup evidence.")
                )
            }

            if let report = model.report, !report.blockedArtifacts.isEmpty {
                DisclosureGroup("Blocked Findings (\(report.blockedArtifacts.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.blockedArtifacts.prefix(8)) { blocked in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blocked.artifact.url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(blocked.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CandidateRow: View {
    let candidate: CleanupCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.artifact.url.lastPathComponent)
                    .font(.body.weight(.medium))
                Spacer()
                RiskBadge(riskTier: candidate.riskTier)
            }
            Text(candidate.artifact.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Text(ByteCountFormatter.string(fromByteCount: candidate.artifact.sizeInBytes, countStyle: .file))
                Text(candidate.artifact.kind.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct CandidateDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            if model.selectedCandidates.count > 1 {
                BatchCandidateDetailView()
            } else if let candidate = model.selectedCandidate {
                SingleCandidateDetailView(candidate: candidate)
            } else {
                ContentUnavailableView(
                    "Select a candidate",
                    systemImage: "sidebar.right",
                    description: Text("Pick one or more cleanup candidates. Cmd-click or shift-click to select multiple and act on them as a batch.")
                )
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SingleCandidateDetailView: View {
    let candidate: CleanupCandidate
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.artifact.url.lastPathComponent)
                        .font(.title2.weight(.semibold))
                    Text(candidate.artifact.url.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                DetailSection(title: "Recommended Action") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            RiskBadge(riskTier: candidate.riskTier)
                            Text(candidate.reason)
                                .font(.headline)
                        }
                        Text(candidate.evidence.summary)
                            .foregroundStyle(.secondary)
                    }
                }

                DetailSection(title: "Artifact Details") {
                    DetailRow(label: "Kind", value: candidate.artifact.kind.rawValue)
                    DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: candidate.artifact.sizeInBytes, countStyle: .file))
                    DetailRow(label: "Modified", value: candidate.artifact.lastModifiedAt.formatted(date: .abbreviated, time: .shortened))
                    DetailRow(label: "Action", value: candidate.proposedAction.rawValue.capitalized)
                }

                if let ownerHint = candidate.artifact.metadata.ownerHint {
                    DetailSection(title: "Ownership Evidence") {
                        DetailRow(label: "Owner hint", value: ownerHint)
                        if let launchTargetPath = candidate.artifact.metadata.launchTargetPath {
                            DetailRow(label: "Launch target", value: launchTargetPath)
                        }
                    }
                }

                Button("Quarantine This Item") {
                    model.quarantine(candidate: candidate)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.candidateMutationsAreDisabled)
                .help(quarantineDisabledHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var quarantineDisabledHelp: String {
        if model.isScanning {
            return "Wait for the active scan to finish before quarantining items."
        }
        if model.isMutating {
            return "Wait for the active disk operation to finish before quarantining items."
        }
        if model.scanResultsAreStale {
            return "Run a scan with the selected scope before quarantining this result."
        }
        return "Move this item into quarantine with restore support."
    }
}

private struct BatchCandidateDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let candidates = model.selectedCandidates
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(candidates.count) candidates selected")
                        .font(.title2.weight(.semibold))
                    Text(
                        "This moves \(ByteCountFormatter.string(fromByteCount: model.selectedRecoverableBytes, countStyle: .file)) into quarantine. Disk space is reclaimed only if those payloads are later purged."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                DetailSection(title: "What will happen") {
                    Text("Each item is moved into the app's quarantine area with restore support. The app then attempts to record every move in its audit history and reports any logging failure.")
                        .foregroundStyle(.secondary)
                }

                DetailSection(title: "Selection preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates.prefix(8)) { candidate in
                            HStack {
                                Text(candidate.artifact.url.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: candidate.artifact.sizeInBytes, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if candidates.count > 8 {
                            Text("…and \(candidates.count - 8) more")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Button("Quarantine \(candidates.count) Items") {
                    model.quarantineSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.candidateMutationsAreDisabled)
                .help(quarantineDisabledHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var quarantineDisabledHelp: String {
        if model.isScanning {
            return "Wait for the active scan to finish before quarantining items."
        }
        if model.isMutating {
            return "Wait for the active disk operation to finish before quarantining items."
        }
        if model.scanResultsAreStale {
            return "Run a scan with the selected scope before quarantining these results."
        }
        return "Move the selected items into quarantine with restore support."
    }
}

private struct QuarantineHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isConfirmingEmpty = false
    @State private var pendingRemovalRecord: QuarantineRecord?

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quarantine & audit history")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Quarantined items stay recoverable until purged; restored records remain here as history.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isMutating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh History") {
                    model.refreshHistory()
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
                Button("Empty Quarantine") {
                    isConfirmingEmpty = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!model.hasQuarantinedItems || model.isBusy)
            }
            .confirmationDialog(
                "Permanently delete every quarantined item?",
                isPresented: $isConfirmingEmpty,
                titleVisibility: .visible
            ) {
                Button("Empty Quarantine", role: .destructive) {
                    model.emptyQuarantine()
                }
                .disabled(model.isBusy)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the quarantined payloads from disk for good. Restored items keep their audit history.")
            }

            HSplitView {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quarantine Records")
                            .font(.headline)
                        if model.quarantineRecords.isEmpty {
                            ContentUnavailableView(
                                "Nothing quarantined yet",
                                systemImage: "archivebox",
                                description: Text("Approved cleanup items will show up here with restore support.")
                            )
                        } else {
                            List(model.quarantineRecords, selection: $model.selectedRecordID) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(record.originalURL.lastPathComponent)
                                            .font(.body.weight(.medium))
                                        Spacer()
                                        Text(record.status.rawValue.capitalized)
                                            .foregroundStyle(statusColor(for: record.status))
                                    }
                                    Text(record.originalURL.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 4)
                                .tag(record.id)
                            }
                            .listStyle(.inset(alternatesRowBackgrounds: true))
                        }
                    }
                }
                .frame(minWidth: 380)

                GroupBox {
                    if let record = model.selectedRecord {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text(record.originalURL.lastPathComponent)
                                    .font(.title2.weight(.semibold))
                                DetailSection(title: "Record") {
                                    DetailRow(label: "Status", value: record.status.rawValue.capitalized)
                                    DetailRow(label: "Original", value: record.originalURL.path)
                                    DetailRow(label: "Quarantined", value: record.quarantinedURL.path)
                                    DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: record.recordedSizeBytes, countStyle: .file))
                                    DetailRow(label: "Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    if let restoredURL = record.restoredURL {
                                        DetailRow(label: "Restored location", value: restoredURL.path)
                                    }
                                    if let restoredAt = record.restoredAt {
                                        DetailRow(label: "Restored", value: restoredAt.formatted(date: .abbreviated, time: .shortened))
                                    }
                                }
                                DetailSection(title: "Why it was moved") {
                                    Text(record.reason)
                                        .font(.headline)
                                    Text(record.evidenceSummary)
                                        .foregroundStyle(.secondary)
                                    Text("Fingerprint: \(record.contentHash)")
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    DetailRow(
                                        label: "Fingerprint version",
                                        value: record.fingerprintVersion.map(String.init) ?? "Legacy"
                                    )
                                }
                                HStack(spacing: 10) {
                                    if record.status == .quarantined,
                                       record.fingerprintVersion == 2 {
                                        Button("Restore This Item") {
                                            model.restore(record: record)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(model.isBusy)
                                    }
                                    if record.status == .quarantined || record.status == .restored {
                                        Button(removalButtonTitle(for: record)) {
                                            pendingRemovalRecord = record
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.red)
                                        .disabled(model.isBusy)
                                    }
                                }
                                if record.status == .quarantined,
                                   record.fingerprintVersion != 2 {
                                    Label(
                                        "Automatic restore is disabled because this record has no supported integrity fingerprint. The quarantined payload remains untouched at the path shown above.",
                                        systemImage: "lock.trianglebadge.exclamationmark"
                                    )
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                }
                                if record.status == .interrupted {
                                    Label(
                                        "This operation ended in an ambiguous state. SqueakyClean preserved every surviving path and disabled automatic actions for this record.",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .confirmationDialog(
                            removalDialogTitle,
                            isPresented: Binding(
                                get: { pendingRemovalRecord != nil },
                                set: { if !$0 { pendingRemovalRecord = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button(removalConfirmationTitle, role: .destructive) {
                                if let target = pendingRemovalRecord {
                                    model.purge(record: target)
                                }
                                pendingRemovalRecord = nil
                            }
                            .disabled(model.isBusy)
                            Button("Cancel", role: .cancel) {
                                pendingRemovalRecord = nil
                            }
                        } message: {
                            Text(removalDialogMessage)
                        }
                    } else {
                        ContentUnavailableView(
                            "Select a record",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Choose a quarantined item to inspect its audit trail or restore it.")
                        )
                    }
                }
                .frame(minWidth: 420)
            }

            HStack(alignment: .top, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Scan Snapshots")
                            .font(.headline)
                        if model.scanSnapshots.isEmpty {
                            Text("No scans recorded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.scanSnapshots.prefix(5).enumerated()), id: \.offset) { _, snapshot in
                                HStack {
                                    Text(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened))
                                    Spacer()
                                    Text("\(snapshot.candidateCount) candidates")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent Approval Events")
                            .font(.headline)
                        if model.approvalHistory.isEmpty {
                            Text("No cleanup actions recorded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(model.approvalHistory.prefix(5).enumerated()), id: \.offset) { _, approval in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(approval.action.rawValue.capitalized): \(approval.artifactURL.lastPathComponent)")
                                        .font(.footnote.weight(.medium))
                                    Text(approval.executedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
    }

    private func removalButtonTitle(for record: QuarantineRecord) -> String {
        record.status == .quarantined ? "Permanently Delete Payload" : "Remove History Record"
    }

    private func statusColor(for status: QuarantineRecordStatus) -> Color {
        switch status {
        case .restored:
            return .green
        case .interrupted:
            return .red
        case .pending, .quarantined, .restoring, .purging:
            return .orange
        }
    }

    private var removalDialogTitle: String {
        guard let record = pendingRemovalRecord else { return "Remove record?" }
        if record.status == .quarantined {
            return "Permanently delete \(record.originalURL.lastPathComponent)?"
        }
        return "Remove restored record for \(record.originalURL.lastPathComponent)?"
    }

    private var removalConfirmationTitle: String {
        guard let record = pendingRemovalRecord else { return "Remove" }
        return record.status == .quarantined ? "Permanently Delete" : "Remove History Record"
    }

    private var removalDialogMessage: String {
        guard let record = pendingRemovalRecord else { return "" }
        if record.status == .quarantined {
            return "This permanently removes the quarantined payload and its recovery option. The app will attempt to record the action and report any logging failure."
        }
        if let restoredURL = record.restoredURL {
            return "This removes only the quarantine history record. The restored item at \(restoredURL.path) is not deleted. The app will attempt to record the action and report any logging failure."
        }
        return "This removes only the quarantine history record. The restored item is not deleted. The app will attempt to record the action and report any logging failure."
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AccessBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct RiskBadge: View {
    let riskTier: RiskTier

    var body: some View {
        Text(riskTier.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.18), in: Capsule())
            .foregroundStyle(backgroundColor)
    }

    private var backgroundColor: Color {
        switch riskTier {
        case .safe:
            return .green
        case .review:
            return .orange
        case .blocked:
            return .red
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}
