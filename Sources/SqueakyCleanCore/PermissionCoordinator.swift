import Foundation

public struct PermissionCoordinator {
    private let accessProbe: @Sendable (URL) -> RootAccess
    private let fullDiskAccessProbe: @Sendable () -> FullDiskAccessStatus

    public init(
        accessProbe: @escaping @Sendable (URL) -> RootAccess = PermissionCoordinator.liveAccessProbe,
        fullDiskAccessProbe: @escaping @Sendable () -> FullDiskAccessStatus = PermissionCoordinator.liveFullDiskAccessProbe
    ) {
        self.accessProbe = accessProbe
        self.fullDiskAccessProbe = fullDiskAccessProbe
    }

    public func evaluate(for roots: [InventoryRoot], scope: ScanScope) -> PermissionState {
        let inaccessibleRoots = roots
            .filter { scope.includes($0.minimumScope) }
            .compactMap { root -> InaccessibleRoot? in
                switch accessProbe(root.url) {
                case .granted:
                    return nil
                case .restricted(let reason):
                    return InaccessibleRoot(root: root, reason: reason)
                }
            }

        return PermissionState(
            scope: scope,
            inaccessibleRoots: inaccessibleRoots,
            fullDiskAccessStatus: fullDiskAccessProbe()
        )
    }

    public static func liveAccessProbe(url: URL) -> RootAccess {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            return .granted
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            return .restricted("The app cannot read this location with current permissions.")
        }

        do {
            _ = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return .granted
        } catch {
            return .restricted(error.localizedDescription)
        }
    }

    public static func liveFullDiskAccessProbe() -> FullDiskAccessStatus {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let protectedProbeURLs = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true)
        ]

        let existingProbeURLs = protectedProbeURLs.filter {
            fileManager.fileExists(atPath: $0.path)
        }
        guard !existingProbeURLs.isEmpty else {
            return .unknown("No protected probe location was found on this Mac.")
        }

        for url in existingProbeURLs {
            do {
                _ = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            } catch {
                return .notGranted("Protected location denied: \(url.lastPathComponent)")
            }
        }

        return .granted
    }
}
