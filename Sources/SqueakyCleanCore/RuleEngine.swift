import Foundation

public struct RuleEngine: Sendable {
    private let activeDependencyInspector: ActiveDependencyInspector
    private let protectedApplicationHints: Set<String>

    public init(
        activeDependencyInspector: ActiveDependencyInspector = ActiveDependencyInspector(),
        staleScriptThreshold _: TimeInterval = 60 * 60 * 24 * 30,
        protectedApplicationHints: Set<String>? = nil
    ) {
        self.activeDependencyInspector = activeDependencyInspector
        self.protectedApplicationHints = Set(
            (protectedApplicationHints ?? Self.defaultProtectedApplicationHints)
                .map(Self.normalizedOwnerHint)
        )
    }

    public func classify(
        artifact: DiscoveredArtifact,
        ownerState: OwnerState,
        now: Date = .now
    ) -> RuleDecision {
        if isProtectedApplicationArtifact(artifact) {
            return .blocked(
                BlockedArtifact(
                    artifact: artifact,
                    reason: "SqueakyClean's active application data is protected from cleanup.",
                    evidence: RuleEvidence(
                        code: "current-application-data",
                        summary: "The artifact belongs to the currently running cleanup application."
                    )
                )
            )
        }

        if isProtectedSystemMetadata(artifact) {
            return .blocked(
                BlockedArtifact(
                    artifact: artifact,
                    reason: "Live macOS metadata is protected from cleanup.",
                    evidence: RuleEvidence(
                        code: "protected-system-metadata",
                        summary: "The artifact is a live preferences or installation-history metadata item."
                    )
                )
            )
        }

        if isSystemWideLibraryArtifact(artifact) {
            return .blocked(
                BlockedArtifact(
                    artifact: artifact,
                    reason: "System-wide Library artifacts are analysis-only.",
                    evidence: RuleEvidence(
                        code: "system-wide-analysis-only",
                        summary: "Deep scan can inventory /Library, but cleanup there is disabled."
                    )
                )
            )
        }

        if isAppleOwned(artifact) {
            return .blocked(
                BlockedArtifact(
                    artifact: artifact,
                    reason: "Apple-owned artifacts are blocked from cleanup.",
                    evidence: RuleEvidence(
                        code: "apple-owned-artifact",
                        summary: "The path or owner hint identifies this as Apple-managed data."
                    )
                )
            )
        }

        switch ownerState {
        case .installed(let app):
            return .blocked(
                BlockedArtifact(
                    artifact: artifact,
                    reason: "Artifact belongs to an installed app and must stay untouched.",
                    evidence: RuleEvidence(
                        code: "installed-owner",
                        summary: "Matched installed app \(app.displayName)."
                    )
                )
            )

        case .orphaned(let ownerHint):
            guard
                let ownerHint = ownerHint?.trimmingCharacters(in: .whitespacesAndNewlines),
                !ownerHint.isEmpty
            else {
                return classifyUnknown(artifact: artifact)
            }
            return classifyOrphaned(artifact: artifact, ownerHint: ownerHint)

        case .unknown:
            return classifyUnknown(artifact: artifact)
        }
    }

    private func classifyOrphaned(artifact: DiscoveredArtifact, ownerHint: String) -> RuleDecision {
        switch artifact.kind {
        case .cache, .log, .temporary:
            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Review orphaned \(artifact.kind.readableName)",
                    evidence: RuleEvidence(
                        code: "orphaned-purgeable",
                        summary: "Matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .applicationSupport:
            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Application Support data for a removed app",
                    evidence: RuleEvidence(
                        code: "orphaned-application-support",
                        summary: "Application support path matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .preference:
            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Preference file for a removed app",
                    evidence: RuleEvidence(
                        code: "orphaned-preference",
                        summary: "Preference file matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .launchAgent, .launchDaemon:
            let hasMissingTarget = artifact.metadata.launchTargetExists == false
            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: hasMissingTarget ? "Launch item with missing target" : "Launch item for a removed app",
                    evidence: RuleEvidence(
                        code: hasMissingTarget ? "dead-launch-item" : "orphaned-launch-item",
                        summary: hasMissingTarget
                            ? "Launch item points at a missing target."
                            : "Launch item matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .installerReceipt, .packageArchive:
            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Installer remnant for a removed app",
                    evidence: RuleEvidence(
                        code: "orphaned-installer-remnant",
                        summary: "Installer artifact matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .script:
            guard !activeDependencyInspector.isActivelyManaged(url: artifact.url) else {
                return .ignored
            }

            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Abandoned script for a removed app",
                    evidence: RuleEvidence(
                        code: "orphaned-script",
                        summary: "Script matched \(ownerHint), which is no longer installed."
                    )
                )
            )

        case .unknown:
            return .ignored
        }
    }

    private func classifyUnknown(artifact: DiscoveredArtifact) -> RuleDecision {
        switch artifact.kind {
        case .launchAgent, .launchDaemon:
            guard
                artifact.metadata.launchTargetExists == false,
                let launchTargetPath = artifact.metadata.launchTargetPath?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !launchTargetPath.isEmpty
            else {
                return .ignored
            }

            return .candidate(
                CleanupCandidate(
                    artifact: artifact,
                    riskTier: .review,
                    proposedAction: .quarantine,
                    reason: "Launch item with missing target",
                    evidence: RuleEvidence(
                        code: "dead-launch-item",
                        summary: "Launch item points at a resolved, missing target."
                    )
                )
            )

        case .script:
            // Age and path shape are not positive removal evidence. Unknown
            // scripts remain untouched even if a future scan profile finds one.
            return .ignored

        default:
            return .ignored
        }
    }

    private func isProtectedApplicationArtifact(_ artifact: DiscoveredArtifact) -> Bool {
        OwnershipResolver().inferredOwnerHints(for: artifact).contains { hint in
            protectedApplicationHints.contains(Self.normalizedOwnerHint(hint))
        }
    }

    private func isProtectedSystemMetadata(_ artifact: DiscoveredArtifact) -> Bool {
        let components = artifact.url.standardizedFileURL.pathComponents.map { $0.lowercased() }

        // ByHost is a live preferences container, not an app-owned preference.
        if components.indices.contains(where: { index in
            index + 2 < components.count
                && components[index] == "library"
                && components[index + 1] == "preferences"
                && components[index + 2] == "byhost"
        }) {
            return true
        }

        let path = artifact.url.standardizedFileURL.path.lowercased()
        let receiptsRoot = "/library/receipts"
        let installHistoryPath = receiptsRoot + "/installhistory.plist"
        let receiptsDatabasePath = receiptsRoot + "/db"
        return path == installHistoryPath
            || path == receiptsDatabasePath
            || path.hasPrefix(receiptsDatabasePath + "/")
    }

    private func isSystemWideLibraryArtifact(_ artifact: DiscoveredArtifact) -> Bool {
        let path = artifact.url.standardizedFileURL.path.lowercased()
        return path == "/library" || path.hasPrefix("/library/")
    }

    private func isAppleOwned(_ artifact: DiscoveredArtifact) -> Bool {
        let ownerHint = artifact.metadata.ownerHint?.lowercased() ?? ""
        if ownerHint.hasPrefix("com.apple.") || ownerHint.hasPrefix("apple.") {
            return true
        }
        if Self.appleManagedComponents.contains(ownerHint) {
            return true
        }

        return artifact.url.standardizedFileURL.pathComponents.contains { component in
            let lowercasedComponent = component.lowercased()
            if lowercasedComponent.hasPrefix("com.apple.")
                || lowercasedComponent == "apple"
                || lowercasedComponent.hasPrefix("apple.") {
                return true
            }
            return Self.appleManagedComponents.contains(lowercasedComponent)
        }
    }

    // Known Apple-managed names that do not carry the com.apple. prefix.
    // Lowercased for direct comparison against path components and owner hints.
    private static let appleManagedComponents: Set<String> = [
        "cloudkit",
        "clouddocs",
        "cloudstorage",
        "icloud",
        "mobile documents",
        "group containers",
        "containers"
    ]

    private static let defaultProtectedApplicationHints: Set<String> = {
        var hints: Set<String> = [
            "SqueakyClean",
            "local.squeakyclean.app"
        ]

        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            if let bundleIdentifier = bundle.bundleIdentifier {
                hints.insert(bundleIdentifier)
            }
            for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String {
                    hints.insert(value)
                }
            }
            hints.insert(bundle.bundleURL.deletingPathExtension().lastPathComponent)
        }

        return hints
    }()

    private static func normalizedOwnerHint(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

private extension ArtifactKind {
    var readableName: String {
        switch self {
        case .applicationSupport:
            return "application support data"
        case .cache:
            return "cache data"
        case .log:
            return "log data"
        case .temporary:
            return "temporary data"
        case .launchAgent:
            return "launch agent"
        case .launchDaemon:
            return "launch daemon"
        case .installerReceipt:
            return "installer receipt"
        case .preference:
            return "preference data"
        case .script:
            return "script"
        case .packageArchive:
            return "package archive"
        case .unknown:
            return "unknown artifact"
        }
    }
}
