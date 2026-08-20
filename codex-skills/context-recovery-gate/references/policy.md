# Recovery policy

## States

- `active`: work is unfinished; keep working context.
- `soft_cold`: work paused or apparently complete, but durable recovery is not proven. Retain a factual summary and do not forget unique information.
- `hard_cold`: Gate exit code 0. Detailed process context may be compacted to a recovery pointer.
- `restored`: an archived task was recovered from the remote annotated tag and the Gate was rerun.

## Hard-cold invariants

- The task has an authorized Git repository and reachable remote.
- Source commit A and Manifest commit B are distinct; B is reachable from the declared remote branch.
- `archive/<task_id>` is an annotated tag and its exact tag object exists remotely.
- The Manifest is a tracked regular file no larger than 64 KiB.
- The archive scope contains no modified, untracked, ignored-only, undeclared, probe, draft, or unvalidated file.
- Every scoped source file has a declared Git object ID, `type=release`, and `stage=validated`.
- Validation evidence exists in source commit A. Limits and prohibited claims are non-empty.
- No token, password, private key, embedded credential, path escape, NTFS ADS, Windows device name, unsafe Git helper, command injection, or reparse-point escape is accepted.
- A deployment profile also binds rebuilt SHA-256 values, version metadata, source commit, deployment ID, and a caller-authorized HTTP(S) origin.

## Failure handling

Gate failure never authorizes deletion, reset, checkout over user work, commit, push, merge, or task archival. Report findings, keep `soft_cold`, and repair only within the user's existing scope.

If the repository is absent, the remote is unreachable, unique evidence exists only locally, or the task is a probe, preserve the task summary. The absence of collaboration does not make local-only state recoverable.

## Context budget

Keep the Manifest small. Store stable identifiers, paths, hashes, validation conclusions, limits, and recovery steps. Keep raw logs, firmware binaries, media, and large Office files outside the Manifest; reference immutable tracked/LFS/Release assets by path and SHA-256.

The compact recovery pointer is an index, not a second copy of the task. On restoration, prefer tagged repository evidence over remembered prose.
