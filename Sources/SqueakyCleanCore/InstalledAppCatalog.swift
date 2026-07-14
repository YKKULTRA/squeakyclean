import Foundation

public struct InstalledAppCatalog {
    private let fileManager: FileManager
    private let searchRoots: [URL]
    private let currentApplicationBundle: Bundle?

    public init(
        fileManager: FileManager = .default,
        searchRoots: [URL]? = nil,
        currentApplicationBundle: Bundle? = .main
    ) {
        self.fileManager = fileManager
        self.searchRoots = searchRoots ?? Self.defaultSearchRoots(fileManager: fileManager)
        self.currentApplicationBundle = currentApplicationBundle
    }

    public func snapshot() -> [InstalledApp] {
        var appsByBundleIdentifier: [String: InstalledApp] = [:]

        func add(_ app: InstalledApp) {
            let key = app.bundleIdentifier.lowercased()
            // Prefer the running bundle when the same app also appears under a
            // search root. Its URL is the authoritative location for this run.
            if appsByBundleIdentifier[key] == nil {
                appsByBundleIdentifier[key] = app
            }
        }

        if
            let currentApplicationBundle,
            currentApplicationBundle.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
            let currentApplication = Self.installedApp(from: currentApplicationBundle)
        {
            // The app may be launched directly from a build or download folder,
            // so include it even when it is outside the standard app locations.
            add(currentApplication)
        }

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator
            where url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                guard
                    let bundle = Bundle(url: url),
                    let app = Self.installedApp(from: bundle)
                else {
                    continue
                }
                add(app)
            }
        }

        return appsByBundleIdentifier.values.sorted {
            let displayNameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if displayNameOrder != .orderedSame {
                return displayNameOrder == .orderedAscending
            }
            return $0.bundleIdentifier.localizedCaseInsensitiveCompare($1.bundleIdentifier) == .orderedAscending
        }
    }

    private static func defaultSearchRoots(fileManager: FileManager) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    private static func installedApp(from bundle: Bundle) -> InstalledApp? {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent

        guard !displayName.isEmpty else {
            return nil
        }

        return InstalledApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            bundleURL: bundle.bundleURL
        )
    }
}
