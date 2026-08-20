# Recovery Manifest schema

The current schema version is `1.0`. Use `recovery/recovery-manifest.json` and UTF-8 without BOM.

## Required top-level fields

| Field | Requirement |
|---|---|
| `schema_version` | Exactly `1.0`. |
| `task_id` | Stable ASCII identifier matching `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. |
| `type` | Must be `release` for hard-cold. |
| `state` | Must be `ready_for_hard_cold`. |
| `persistence_profile` | `git_only` or `git_and_deployment`. |
| `repository_url` | Must exactly match the selected safe Git remote URL and contain no credentials. |
| `branch` | Valid Git branch containing the Manifest commit. |
| `source_commit` | Full SHA-1 or SHA-256 object ID for completed source/output. |
| `manifest_ref` | Exactly `archive/<task_id>`. |
| `archive_scope_paths` | Safe repository-relative files/directories, including the Manifest path. |
| `tracked_outputs` | One declaration for every file in the source archive scope. |
| `validation` | Passed status and evidence paths present in the source commit. |
| `known_limits` | Non-empty truthful limitations. |
| `must_not_claim` | Non-empty statements that prevent validation overclaiming. |
| `restore_commands` | Restricted clone, fetch-tags, and archive-checkout instructions. They are never auto-executed. |

Each `tracked_outputs` item contains `path`, `git_object`, `type=release`, and `stage=validated`.

## Deployment profile

`git_only` must omit `deployment` so stale website claims cannot survive.

`git_and_deployment` requires:

- `url` and `version_url`: credential-free HTTP(S), same origin, without query or fragment;
- `deployment_id`: immutable release/deployment identifier;
- `source_commit`: equal to the top-level source commit;
- `artifacts`: unique safe relative paths and 64-hex SHA-256 values.

HTTP verification runs only when the caller separately supplies a matching `AllowedDeploymentOrigin`.

## Commit sequence

1. Commit completed source and declared outputs as source commit A.
2. Build and validate from A; calculate Git object IDs and deployment hashes.
3. Add the Manifest in a later commit B.
4. Create annotated tag `archive/<task_id>` at B.
5. Push the declared branch and the exact tag.
6. Verify from a clean clone before compacting the task.
