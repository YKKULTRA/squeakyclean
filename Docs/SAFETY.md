# Safety model

SqueakyClean is designed around one default: incomplete evidence must stop cleanup. This document describes the guarantees implemented in the current release and the limits around them.

## Current trust boundary

The production cleanup profile is deliberately narrow. A file can become actionable only when all of the following are true:

1. It is a user LaunchAgent plist discovered under the allowlisted user LaunchAgents root.
2. Its configured `Program`, or first `ProgramArguments` value, resolves to an absolute target path.
3. That target is definitively missing, not merely inaccessible or unresolved.
4. The plist is not matched to an installed application and does not fall under an Apple-managed or protected path.
5. The scan captured a usable filesystem identity and the action-time checks still match it.

An unmatched cache, log, preference, Application Support folder, temporary item, installer receipt, script, or package is not evidence of abandonment. Those categories remain non-actionable in the current production rules.

## Scan boundaries

Standard scans inventory selected locations in the current user's Library plus the process temporary directory. Deep scans add selected `/Library` locations, shared launch items, and installer receipts.

Every `/Library` finding is analysis-only. Deep mode does not enable system-wide cleanup.

The scanner skips malformed plists and per-item metadata failures without aborting the entire scan. Unreadable roots are reported as skipped. A partial traversal is never treated as complete evidence.

The inventory pass examines the immediate children of configured roots. Candidate sizing and fingerprinting are recursive and include hidden descendants and package contents.

## Fail-closed classification

- Installed-app data is blocked.
- Unknown ownership is ignored, not treated as orphaned.
- Apple-managed paths such as CloudKit, Mobile Documents, iCloud, Containers, and Group Containers are blocked.
- SqueakyClean's own application data is blocked.
- Symbolic-link candidates are rejected by the action-time path policy.
- Relative, malformed, unresolved, inaccessible, or still-valid launch targets are left untouched.
- Launch target checks expand `~`, `$HOME`, and `${HOME}` forms before evaluating the target.

## Approval-time gate

Scan results can become stale, so approval is not enough by itself. Immediately before quarantine, SqueakyClean:

1. Resolves and validates the canonical source path.
2. Confirms the path remains inside an allowed user root and outside every protected root.
3. Rejects symbolic links.
4. Verifies the filesystem number, file number, and modification state captured by the scan.
5. Refreshes the installed-app catalog and blocks newly matched ownership.
6. Rechecks that the launch target is still definitively missing.
7. Fingerprints the payload.
8. Rechecks the source identity and evidence once more before moving it.

If any check is unavailable, unsupported, or different from the scan evidence, the move is refused.

## Quarantine transactions

Quarantine, restore, and purge use a serialized manifest that is written atomically. Each mutation first records a pending operation, then performs the filesystem change, and finally records the completed state.

A filesystem lock serializes complete transactions across SqueakyClean processes. Managed payload paths, restore destinations, and the quarantine root identity are revalidated immediately around moves and deletion.

At startup, pending operations are reconciled against the filesystem. Clear outcomes are finalized. Ambiguous outcomes are preserved as explicit interrupted records so the app never guesses that a payload was deleted, moved, or restored.

## Payload integrity

Fingerprint version 2 separates file, directory, and symbolic-link domains. It hashes full file contents and deterministic directory entries, including hidden files and package contents. Large files are streamed in 1 MiB chunks rather than loaded into memory.

Restore accepts only a supported fingerprint version. It verifies the quarantined payload before moving it, verifies it again at the destination, and finalizes the record only after both checks succeed.

Directory sizing and fingerprinting fail closed when any descendant cannot be enumerated. Partial results are never accepted as complete.

## Space semantics

Candidate sizes are allocated-byte estimates. Compression, clones, filesystem metadata, and changes after the scan can change the amount eventually reclaimed.

Quarantine normally moves a payload on the same disk, so it does not free the payload's space. Only explicit permanent purge reclaims that space. Restored records can remain as audit history without retaining a quarantined payload.

## Local records

Scan snapshots, approval history, transaction state, and quarantined payloads are stored under:

```text
~/Library/Application Support/SqueakyClean
```

Read-only scanning is decoupled from audit and quarantine initialization, so a damaged local store does not disable the scanner itself.

## Permission and distribution limits

Full Disk Access is optional. The in-app access check probes selected protected locations, but it is not an authoritative verdict about the macOS privacy entitlement state.

Local bundles are ad hoc signed and verified for development. A public release still needs a Developer ID identity, Apple notarization, and a finalized permissions story. These safety controls reduce risk, but they do not turn an early preview into a substitute for backups or careful review.
