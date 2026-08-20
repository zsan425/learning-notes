---
name: context-recovery-gate
description: Verify whether a completed Codex task can be safely compressed, archived, forgotten, or restored from a Git-backed recovery manifest. Use for hard-cold/soft-cold decisions, task-memory handoff, recovery-card creation or review, and pre-archive checks. Do not use for ordinary Git commits, generic summaries, MOCE Context documents, or unfinished implementation work.
metadata:
  short-description: Gate Git-backed task compression and recovery
---

# Context Recovery Gate

Use Git as the durable fact store and keep chat summaries as recovery pointers. This skill does not claim to erase model memory; it decides when detailed task context may be safely compacted or a task may be archived.

## Route the task

1. Determine the task type before any commit or archive action. Read an existing README/Manifest first; if neither the files nor the user establish the type, ask whether this is `probe` or `release`.
2. A `probe` is never eligible for commit, merge, `hard_cold`, or archive-as-complete. Keep it `active` or `soft_cold`.
3. Select one persistence profile:
   - `git_only`: default for code, Markdown, JSON, configuration, small documents, and Skill output.
   - `git_and_deployment`: only when a website or immutable static deployment is part of the completed result.
4. Office binaries remain `soft_cold` unless the repository has a verified Git LFS or immutable Release-asset policy with SHA-256 evidence.

Read [references/policy.md](references/policy.md) when deciding state or handling a failed Gate. Read [references/manifest-schema.md](references/manifest-schema.md) when creating or changing a Manifest.

## Gate a completed task

Require `recovery/recovery-manifest.json`. Start from [assets/recovery-manifest.template.json](assets/recovery-manifest.template.json) rather than inventing fields.

Before running the Gate, confirm the operation is read-only except for fetching remote-tracking refs. Do not commit, push, merge, delete files, or archive a Codex task unless the user's request separately authorizes that action.

For `git_only`:

```powershell
pwsh -NoProfile -File '<skill-root>\scripts\Test-RecoveryGate.ps1' `
  -RepoRoot '<repository>' `
  -TaskId '<stable-ascii-task-id>' `
  -Remote origin
```

For `git_and_deployment`, additionally pass the local rebuilt site and an origin explicitly authorized by the user or trusted task configuration:

```powershell
pwsh -NoProfile -File '<skill-root>\scripts\Test-RecoveryGate.ps1' `
  -RepoRoot '<repository>' `
  -TaskId '<stable-ascii-task-id>' `
  -Remote origin `
  -DeploymentRoot '<rebuilt-site-directory>' `
  -AllowedDeploymentOrigin 'https://approved.example' `
  -VerifyHttp
```

Interpret exit codes strictly:

- `0`: `hard_cold` eligible. Retain a compact recovery pointer containing task ID, repository, branch, source commit, archive tag, Manifest path, profile, validation result, known limits, and `must_not_claim`.
- `2`: Gate rejected. Keep `soft_cold`; report the exact finding codes and preserve important context.
- Any other exit or non-JSON output: infrastructure failure. Keep `soft_cold`; do not infer success.

Every file in the archive scope must be declared `type=release`, `stage=validated`, and bound to its Git object ID. A clean working tree alone is insufficient.

## Restore

Clone or fetch only the Manifest-declared remote, check out the annotated archive tag in a disposable or clean directory, read the tagged Manifest, and rerun the Gate before treating restored facts as current. Re-check live repository state when the task resumes; old README status is not current Git evidence.

Never execute `restore_commands` automatically. They are constrained, human-readable recovery instructions and still require normal authorization boundaries.

## Maintain the package

Run `scripts/Invoke-RecoveryGateSelfTest.ps1` after changing the Gate, schema, or policy. It must pass all positive and fault-injection cases and report zero runtime residue. Use `scripts/Install-Skill.ps1 -RunSelfTest` for a verified one-command installation.
