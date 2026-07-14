# Changelog

## Unreleased

### Correctness

- Moved scans off the main actor so the UI remains responsive and the spinner renders during slow scans.
- Added scan cancellation without clearing the previous report or showing an error alert.
- Made inventory scans resilient to malformed plists, unreadable roots, and per-file metadata failures.
- Added launch target expansion for `~`, `$HOME`, and `${HOME}` before checking whether launch agents point at missing targets.
- Changed ownership resolution to fail closed: an unmatched owner hint is unknown and ignored instead of being treated as proof of an orphan.
- Limited production cleanup candidates to positive evidence, currently user launch items with resolved targets that are confirmed missing.
- Removed the dormant age-only unknown-script candidate rule so future scan-profile expansion remains fail closed.
- Made relative launch commands fail closed instead of checking them against SqueakyClean's working directory and falsely calling them missing.
- Distinguished a definitively missing launch target from an inaccessible one and revalidated missing-target evidence immediately before quarantine.
- Refreshed installed-app ownership at approval time so a reinstalled owner blocks a stale cleanup candidate.
- Made every `/Library` finding analysis-only, including shared launch items and installer receipts found by Deep scans.
- Hardened Apple-managed path blocking for CloudKit, Mobile Documents, iCloud, Containers, and Group Containers.
- Added an action-time path and identity gate that rejects paths outside allowed user roots, protected paths, symbolic links, missing or stale filesystem identities, changed modification state, and non-quarantine actions.

### Cleanup Semantics

- Added candidate-only allocated-size estimates, including hidden files and package contents, without spending I/O on blocked findings.
- Added version 2 type-separated, full-content fingerprints for files and directories and fingerprint verification before restore.
- Journaled quarantine, restore, and purge operations in a serialized, atomically written manifest with startup reconciliation for interrupted operations.
- Preserved ambiguous move outcomes as explicit interrupted records, fixed restore-destination collision rollback, and stopped move errors from deleting potentially completed payloads.
- Added a filesystem transaction lock across app instances and repeated managed-path validation immediately around moves and deletion.
- Made restore reject legacy or unknown fingerprint versions and reverify content at the destination before finalizing.
- Clarified that quarantine itself normally reclaims no space and that displayed byte totals are estimates. Only purge removes the quarantined payload.
- Added per-record purge and Empty Quarantine flows for reclaiming disk space through a separately confirmed destructive action.
- Preserved restored records as audit history when purging the remaining quarantine.

### Usability

- Added search, kind filtering, multi-select, and batch quarantine for candidate lists.
- Added destructive confirmation dialogs for per-record purge and Empty Quarantine.
- Added distinct empty states for no candidates and no filter matches.
- Added completed-scan scope and timestamp, stale-report protection, and an explicit Deep Read Only label.
- Reframed space totals as purge-time estimates and clarified that Full Disk Access is optional.
- Made the protected-location access check test every available sample before reporting success and avoided presenting the probe as an operating-system entitlement verdict.
- Decoupled read-only scanning from audit and quarantine initialization so one damaged local store cannot disable the scanner.
- Added restored destination locations and accurate history-removal wording for restored records.

### Infrastructure

- Replaced generated `PlistBuddy` bundle metadata with a static `Resources/Info.plist` template.
- Hardened the local app build script with plist validation, native or universal architecture builds, completed-bundle signing, hardened runtime and timestamp support for real identities, and strict signature verification.
- Added macOS CI that builds and tests with warnings treated as errors, packages a universal app, verifies it, and uploads the app archive.
- Kept CI on the current official macOS 26 runner, checkout v6, and upload-artifact v7 action majors.
- Changed large-file hashing to stream SHA256 in 1 MiB chunks.
- Made directory sizing and fingerprinting propagate descendant-enumeration failures instead of silently accepting partial results.
- Made directory fingerprints deterministic when parent directory names reappear deeper in a tree.

### Tests

- Expanded the suite across fail-closed ownership, scan profiles, launch target resolution, Apple-managed path blocking, action-time path policy, allocated sizing, transaction recovery, purge behavior, cancellation, streaming hashing, and full-content directory fingerprints.
