import Foundation

public struct OwnershipResolver: Sendable {
    public init() {}

    public func resolve(artifact: DiscoveredArtifact, installedApps: [InstalledApp]) -> OwnerState {
        let ownerHints = inferredOwnerHints(for: artifact).uniqued()

        for hint in ownerHints {
            if let app = installedApps.first(where: { $0.matches(ownerHint: hint) }) {
                return .installed(app)
            }
        }

        // A catalog miss is not evidence that an app was removed. The catalog
        // can be incomplete (for example, an app may run outside /Applications),
        // and many macOS-owned folders do not map cleanly to an app bundle.
        // Only a source with positive removal evidence may produce `.orphaned`.
        return .unknown
    }

    public func inferredOwnerHints(for artifact: DiscoveredArtifact) -> [String] {
        var hints: [String] = []

        if let ownerHint = artifact.metadata.ownerHint, !ownerHint.isEmpty {
            hints.append(ownerHint)
        }

        let pathComponents = artifact.url.standardizedFileURL.pathComponents
        if let libraryIndex = pathComponents.firstIndex(of: "Library"), libraryIndex + 2 < pathComponents.count {
            let category = pathComponents[libraryIndex + 1]
            let ownerComponent = pathComponents[libraryIndex + 2]
            if ["Application Support", "Caches", "Logs"].contains(category) {
                hints.append(ownerComponent)
            }
        }

        switch artifact.kind {
        case .preference, .launchAgent, .launchDaemon:
            hints.append(artifact.url.deletingPathExtension().lastPathComponent)
        case .installerReceipt:
            hints.append(artifact.url.deletingPathExtension().lastPathComponent)
        default:
            break
        }

        return hints.filter { !$0.isEmpty }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
