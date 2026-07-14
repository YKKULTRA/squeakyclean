# SqueakyClean

`SqueakyClean` is a native macOS cleanup app built with `SwiftUI` and a safety-first scanning engine.

## What It Does

- Scans only allowlisted locations that commonly accumulate technical leftovers.
- Treats installed-app data as blocked and unmatched app-like data as unknown, not orphaned.
- Offers cleanup only when the scan has positive evidence, currently a user launch item whose resolved target is missing.
- Inventories `/Library` in Deep mode for analysis, but never offers cleanup there.
- Requires explicit user approval before cleanup.
- Supports async scans, cancellation, search, kind filters, multi-select, and batch quarantine.
- Shows an allocated-size estimate for candidates, including hidden files and package contents.
- Moves approved items into an app-managed quarantine area with restore support. Quarantine itself does not free disk space.
- Can permanently purge quarantined items through explicit destructive confirmation.
- Records scan snapshots and approval history in the app's own storage.

## Current Scope

Milestone 1 deliberately keeps its actionable scope narrow. In the production scan profile, a user LaunchAgent becomes reviewable only when its configured target resolves to an absolute path and that path is confirmed missing. A relative command, unresolved path, malformed plist, or still-valid launch item is not offered for cleanup.

An app-like folder or preference that fails to match the installed-app catalog is treated as unknown and ignored. A missing catalog match is not proof that an app was removed. Orphaned caches, logs, Application Support folders, preferences, stale scripts, and installer remnants are therefore not production cleanup categories today.

Deep mode inventories selected `/Library` locations, including shared launch items and installer receipts, but every system-wide finding is analysis-only. The app deliberately does **not** propose cleanup for installed-app data, Apple-managed paths such as CloudKit, Mobile Documents, iCloud, Containers, or Group Containers, its own data, or any `/Library` item.

## Safety Model

- Scans are read-only until the user explicitly approves a candidate.
- Classification fails closed: unknown ownership is ignored, while installed, Apple-managed, protected, and system-wide data is blocked.
- Immediately before quarantine, an action-time gate requires a recorded filesystem identity, verifies the canonical path is inside an allowed user root, outside protected roots, is not a symbolic link, and still has the identity and modification state recorded by the scan. It also refreshes the installed-app catalog and, for dead launch items, confirms that the target is still definitively missing. It rechecks the candidate after fingerprinting and before moving it.
- Quarantine writes a pending operation to a serialized, atomically saved manifest before moving the source. Pending quarantine, restore, and purge states are reconciled after interrupted operations; ambiguous states are preserved as interrupted instead of guessed or deleted.
- A filesystem lock serializes complete quarantine, restore, and purge transactions across app processes. Managed payload and restore paths are revalidated immediately around mutations.
- Version 2 fingerprints domain-separate files, directories, and symbolic links, then hash full file contents and deterministic directory entries, including hidden files and package contents. Restore requires a supported fingerprint and verifies it both before moving and at the destination before finalizing.
- Candidate sizes are allocated-byte estimates, not guarantees of space that will be reclaimed. Filesystem compression, clones, metadata, and later changes can affect the result.
- Quarantine preserves restore support but normally moves data on the same disk, so it frees no space. Only permanent purge reclaims the payload's space, and purge requires separate confirmation.
- Malformed launch agent plists, unreadable files, and unreadable roots are skipped or surfaced as skipped roots instead of aborting the whole scan.
- Launch agent target checks expand `~`, `$HOME`, and `${HOME}`-style paths before deciding whether a target is missing.
- Large files are hashed with streaming SHA256 to avoid loading the whole payload into memory.
- Directory sizing and fingerprinting fail closed if any descendant cannot be enumerated; partial traversals are never treated as complete evidence.

## Project Layout

- `Sources/SqueakyCleanCore`: scanning, ownership resolution, rule engine, quarantine, restore, audit persistence
- `Sources/SqueakyCleanApp`: `SwiftUI` app shell and user flows
- `Resources/Info.plist`: bundle metadata used by the local app build script
- `Scripts/build-app.sh`: builds, signs, and verifies `build/SqueakyClean.app`
- `Tests/SqueakyCleanCoreTests`: unit tests for the core safety and cleanup behavior

## Run It

```bash
Scripts/build-app.sh
open build/SqueakyClean.app
```

The default build targets the current Mac architecture and uses an ad hoc signature, which is suitable for local development. To create a universal app containing both Apple silicon and Intel executables:

```bash
ARCHS="arm64 x86_64" Scripts/build-app.sh
```

For a distribution build, select an installed signing identity. Non-ad-hoc identities automatically enable the hardened runtime and request a secure timestamp:

```bash
ARCHS="arm64 x86_64" \
CODE_SIGN_IDENTITY="Developer ID Application: Example, Inc. (TEAMID)" \
Scripts/build-app.sh
```

`BUILD_DIR` can select another output directory, `MACOSX_DEPLOYMENT_TARGET` can raise the plist default, and `WARNINGS_AS_ERRORS=1` enables strict compiler warnings during packaging. Running the raw SwiftPM executable can make Finder open a Terminal window. Use the `.app` bundle above for normal macOS launching.

## Verify It

```bash
swift build
swift test
WARNINGS_AS_ERRORS=1 Scripts/build-app.sh
plutil -lint build/SqueakyClean.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/SqueakyClean.app
```

GitHub Actions runs release builds and tests with warnings treated as errors, then packages and verifies a universal app bundle.

## Local App Data

The app stores its own audit and quarantine data under:

`~/Library/Application Support/SqueakyClean`

## Distribution Status

The local app bundle is ad-hoc signed and strictly verified. That is appropriate for development and personal testing. Public distribution still needs a Developer ID identity, Apple notarization, and a clearer permissions story. The build script supports Developer ID signing and the hardened runtime, but it deliberately does not submit credentials or notarize automatically.
