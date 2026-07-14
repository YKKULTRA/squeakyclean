import Foundation
import Testing
@testable import SqueakyCleanCore

struct RuleEngineTests {
    @Test
    func installedApplicationSupportIsBlocked() {
        let app = InstalledApp(
            bundleIdentifier: "com.example.ActiveApp",
            displayName: "ActiveApp",
            bundleURL: URL(fileURLWithPath: "/Applications/ActiveApp.app")
        )
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Application Support/com.example.ActiveApp/state.db"),
            kind: .applicationSupport,
            sizeInBytes: 2_048,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.ActiveApp")
        )
        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [app])

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: ownerState,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.reason.contains("installed"))
            #expect(blocked.evidence.summary.contains("ActiveApp"))
        default:
            Issue.record("Expected installed app support data to be blocked.")
        }
    }

    @Test
    func appleOwnedArtifactsAreBlockedEvenWhenCatalogMissesSystemApp() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.apple.Music"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.apple.Music")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "com.apple.Music"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.reason.contains("Apple"))
            #expect(blocked.evidence.code == "apple-owned-artifact")
        default:
            Issue.record("Expected Apple-owned artifacts to be blocked, not proposed as safe cleanup.")
        }
    }

    @Test
    func cloudKitArtifactsWithoutComApplePrefixAreBlocked() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/CloudKit/db.sqlite"),
            kind: .cache,
            sizeInBytes: 4_096,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "CloudKit")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "CloudKit"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "apple-owned-artifact")
        default:
            Issue.record("Expected CloudKit cache to be recognized as Apple-managed and blocked.")
        }
    }

    @Test
    func mobileDocumentsArtifactsAreBlocked() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Mobile Documents/iCloud~example/file"),
            kind: .applicationSupport,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "Mobile Documents")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "Mobile Documents"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "apple-owned-artifact")
        default:
            Issue.record("Expected Mobile Documents to be recognized as Apple-managed and blocked.")
        }
    }

    @Test
    func appleSubstringInOrdinaryNameIsNotBlocked() {
        // Guard against false positives like "pineapple" matching the apple. prefix.
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.pineapple/blob.cache"),
            kind: .cache,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.pineapple")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "com.example.pineapple"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .candidate:
            break  // expected: orphan cleanup candidate, not falsely blocked as Apple
        default:
            Issue.record("Expected an ordinary 'pineapple' artifact to surface as a candidate, not be blocked as Apple-owned.")
        }
    }

    @Test
    func positivelyConfirmedOrphanedCacheRequiresReview() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.OldApp/blob.cache"),
            kind: .cache,
            sizeInBytes: 4_096,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.OldApp")
        )
        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "com.example.OldApp"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .candidate(let candidate):
            #expect(candidate.riskTier == .review)
            #expect(candidate.proposedAction == .quarantine)
            #expect(candidate.evidence.summary.contains("no longer installed"))
        default:
            Issue.record("Expected orphaned cache data to require review.")
        }
    }

    @Test
    func positivelyConfirmedOrphanedPreferenceRequiresReview() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Preferences/com.example.OldApp.plist"),
            kind: .preference,
            sizeInBytes: 512,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.OldApp")
        )
        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "com.example.OldApp"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .candidate(let candidate):
            #expect(candidate.riskTier == .review)
            #expect(candidate.reason.contains("Preference"))
        default:
            Issue.record("Expected orphaned preference data to require review.")
        }
    }

    @Test
    func unknownUserLaunchAgentWithResolvedMissingTargetRequiresReview() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/com.example.OldApp.agent.plist"),
            kind: .launchAgent,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(
                ownerHint: "com.example.OldApp",
                launchTargetPath: "/Users/test/.oldapp/agent",
                launchTargetExists: false
            )
        )
        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [])

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: ownerState,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .candidate(let candidate):
            #expect(candidate.riskTier == .review)
            #expect(candidate.evidence.summary.contains("missing target"))
        default:
            Issue.record("Expected a dead launch agent to be reviewable.")
        }
    }

    @Test
    func unmatchedCacheOwnerIsIgnoredWithoutPositiveRemovalEvidence() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.NotCatalogued"),
            kind: .cache,
            sizeInBytes: 4_096,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.NotCatalogued")
        )
        let ownerState = OwnershipResolver().resolve(artifact: artifact, installedApps: [])

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: ownerState,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(ownerState == .unknown)
        #expect(decision == .ignored)
    }

    @Test
    func orphanStateWithoutAnOwnerIdentityFailsClosed() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/unidentified"),
            kind: .cache,
            sizeInBytes: 4_096,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: nil)
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: nil),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(decision == .ignored)
    }

    @Test
    func unknownLaunchItemWithExistingTargetIsIgnored() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/com.example.Active.agent.plist"),
            kind: .launchAgent,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(
                ownerHint: "com.example.Active",
                launchTargetPath: "/Applications/Active.app/Contents/MacOS/Active",
                launchTargetExists: true
            )
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .unknown,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(decision == .ignored)
    }

    @Test
    func unknownLaunchItemWithoutResolvedTargetIsIgnored() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/com.example.Malformed.agent.plist"),
            kind: .launchAgent,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(
                ownerHint: "com.example.Malformed",
                launchTargetPath: nil,
                launchTargetExists: false
            )
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .unknown,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(decision == .ignored)
    }

    @Test
    func userPreferencesByHostContainerIsAlwaysBlocked() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Preferences/ByHost"),
            kind: .preference,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "ByHost")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "ByHost"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "protected-system-metadata")
        default:
            Issue.record("Expected the live ByHost preferences container to be blocked.")
        }
    }

    @Test
    func byHostNameOutsidePreferencesStructureIsNotSpecialCased() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/ByHost"),
            kind: .cache,
            sizeInBytes: 0,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "ByHost")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "ByHost"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        if case .candidate = decision {
            // Expected: the protection is based on the preferences path structure.
        } else {
            Issue.record("Expected an unrelated ByHost name to follow normal orphan rules.")
        }
    }

    @Test
    func installHistoryAndReceiptDatabaseAreAlwaysBlocked() {
        let urls = [
            URL(fileURLWithPath: "/Library/Receipts/InstallHistory.plist"),
            URL(fileURLWithPath: "/Library/Receipts/db", isDirectory: true),
            URL(fileURLWithPath: "/Library/Receipts/db/a.receiptdb")
        ]

        for url in urls {
            let artifact = DiscoveredArtifact(
                url: url,
                kind: .installerReceipt,
                sizeInBytes: 0,
                lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: ArtifactMetadata(ownerHint: url.deletingPathExtension().lastPathComponent)
            )

            let decision = RuleEngine().classify(
                artifact: artifact,
                ownerState: .orphaned(ownerHint: artifact.metadata.ownerHint),
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )

            switch decision {
            case .blocked(let blocked):
                #expect(blocked.evidence.code == "protected-system-metadata")
            default:
                Issue.record("Expected \(url.path) to be blocked as live receipt metadata.")
            }
        }
    }

    @Test
    func allSystemWideLibraryArtifactsAreAnalysisOnly() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Library/Caches/com.example.ConfirmedRemoved"),
            kind: .cache,
            sizeInBytes: 4_096,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "com.example.ConfirmedRemoved")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "com.example.ConfirmedRemoved"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "system-wide-analysis-only")
        default:
            Issue.record("Expected all /Library artifacts to be analysis-only.")
        }
    }

    @Test
    func systemWideDeadLaunchItemRemainsAnalysisOnly() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.dead.plist"),
            kind: .launchDaemon,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(
                ownerHint: "com.example.dead",
                launchTargetPath: "/missing/daemon",
                launchTargetExists: false
            )
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .unknown,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "system-wide-analysis-only")
        default:
            Issue.record("Expected a system launch item to remain analysis-only even with a missing target.")
        }
    }

    @Test
    func squeakyCleanApplicationSupportIsAlwaysBlocked() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Application Support/SqueakyClean"),
            kind: .applicationSupport,
            sizeInBytes: 1_024,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: "SqueakyClean")
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .orphaned(ownerHint: "SqueakyClean"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        switch decision {
        case .blocked(let blocked):
            #expect(blocked.evidence.code == "current-application-data")
        default:
            Issue.record("Expected SqueakyClean's own data to be blocked.")
        }
    }

    @Test
    func unknownScriptInActiveToolingPathIsIgnored() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/project/node_modules/.bin/eslint"),
            kind: .script,
            sizeInBytes: 2_048,
            lastModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ArtifactMetadata(ownerHint: nil)
        )

        let decision = RuleEngine(
            activeDependencyInspector: ActiveDependencyInspector()
        ).classify(
            artifact: artifact,
            ownerState: .unknown,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(decision == .ignored)
    }

    @Test
    func staleUnknownScriptOutsideActiveToolingStillFailsClosed() {
        let artifact = DiscoveredArtifact(
            url: URL(fileURLWithPath: "/Users/test/Library/Caches/abandoned/tool.py"),
            kind: .script,
            sizeInBytes: 2_048,
            lastModifiedAt: Date(timeIntervalSince1970: 1_600_000_000),
            metadata: ArtifactMetadata(ownerHint: nil)
        )

        let decision = RuleEngine().classify(
            artifact: artifact,
            ownerState: .unknown,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(decision == .ignored)
    }
}
