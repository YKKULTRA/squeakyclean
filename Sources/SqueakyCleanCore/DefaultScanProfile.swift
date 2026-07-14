import Foundation

public enum DefaultScanProfile {
    public static func roots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [InventoryRoot] {
        // Deep roots are inventory-only for now. RuleEngine structurally blocks
        // every /Library artifact, so these roots can inform the user without
        // offering operations that require privileged filesystem writes.
        [
            InventoryRoot(
                name: "User Application Support",
                url: homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true),
                artifactKind: .applicationSupport,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "User Caches",
                url: homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true),
                artifactKind: .cache,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "User Logs",
                url: homeDirectory.appendingPathComponent("Library/Logs", isDirectory: true),
                artifactKind: .log,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "User Preferences",
                url: homeDirectory.appendingPathComponent("Library/Preferences", isDirectory: true),
                artifactKind: .preference,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "User LaunchAgents",
                url: homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                artifactKind: .launchAgent,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "Temporary Files",
                url: temporaryDirectory,
                artifactKind: .temporary,
                minimumScope: .standard
            ),
            InventoryRoot(
                name: "Shared Application Support",
                url: URL(fileURLWithPath: "/Library/Application Support", isDirectory: true),
                artifactKind: .applicationSupport,
                minimumScope: .deep
            ),
            InventoryRoot(
                name: "Shared Caches",
                url: URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
                artifactKind: .cache,
                minimumScope: .deep
            ),
            InventoryRoot(
                name: "Shared Logs",
                url: URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
                artifactKind: .log,
                minimumScope: .deep
            ),
            InventoryRoot(
                name: "Shared LaunchAgents",
                url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                artifactKind: .launchAgent,
                minimumScope: .deep
            ),
            InventoryRoot(
                name: "Shared LaunchDaemons",
                url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
                artifactKind: .launchDaemon,
                minimumScope: .deep
            ),
            InventoryRoot(
                name: "Installer Receipts",
                url: URL(fileURLWithPath: "/Library/Receipts", isDirectory: true),
                artifactKind: .installerReceipt,
                minimumScope: .deep
            )
        ]
    }
}
