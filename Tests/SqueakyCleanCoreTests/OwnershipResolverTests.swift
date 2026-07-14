import Foundation
import Testing
@testable import SqueakyCleanCore

struct OwnershipResolverTests {
    @Test
    func relatedBundleIdentifierIsInstalled() {
        let app = InstalledApp(
            bundleIdentifier: "com.example.Widget",
            displayName: "Widget",
            bundleURL: URL(fileURLWithPath: "/Applications/Widget.app")
        )
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.Widget.Helper"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.Widget.Helper")
        )

        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [app])

        #expect(ownerState == .installed(app))
    }

    @Test
    func displayNameTokenIsInstalled() {
        let app = InstalledApp(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Google Chrome",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
        )
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/Chrome"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "Chrome")
        )

        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [app])

        #expect(ownerState == .installed(app))
    }

    @Test
    func unmatchedExplicitOwnerHintIsUnknownRatherThanOrphaned() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.NotCatalogued"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.NotCatalogued")
        )

        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [])

        #expect(ownerState == .unknown)
    }

    @Test
    func unmatchedPathInferredOwnerHintIsUnknownRatherThanOrphaned() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Application Support/Uncatalogued Tool/state.db"),
            kind: .applicationSupport,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: nil)
        )

        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [])

        #expect(ownerState == .unknown)
    }

    @Test
    func laterInferredHintCanStillMatchAnInstalledApp() {
        let app = InstalledApp(
            bundleIdentifier: "com.example.Widget",
            displayName: "Widget",
            bundleURL: URL(fileURLWithPath: "/Applications/Widget.app")
        )
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.Widget"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "misleading-unmatched-hint")
        )

        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [app])

        #expect(ownerState == .installed(app))
    }
}
