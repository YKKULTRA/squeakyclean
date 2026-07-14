import Foundation

public struct ActiveDependencyInspector: Sendable {
    private let pathMarkers = [
        "/node_modules/",
        "/.venv/",
        "/venv/",
        "/.virtualenvs/",
        "/.pyenv/",
        "/.npm/",
        "/.pnpm-store/",
        "/.yarn/",
        "/opt/homebrew/",
        "/usr/local/Cellar/",
        "/.nvm/"
    ]

    public init() {}

    public func isActivelyManaged(url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return pathMarkers.contains { path.contains($0.lowercased()) }
    }
}
