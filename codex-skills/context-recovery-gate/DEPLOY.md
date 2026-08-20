# Deploy context-recovery-gate

From a clone of the personal knowledge repository:

```powershell
Set-Location '.\codex-skills\context-recovery-gate'
pwsh -NoProfile -File '.\scripts\Install-Skill.ps1' -RunSelfTest
```

To upgrade an existing installation, keep a recoverable backup and replace it:

```powershell
pwsh -NoProfile -File '.\scripts\Install-Skill.ps1' -Force -RunSelfTest
```

Restart Codex after installation or upgrade so the Skill catalog reloads.

To uninstall, move the installed Skill to the backup directory:

```powershell
pwsh -NoProfile -File '.\scripts\Uninstall-Skill.ps1' -ConfirmRemoval
```

`-CodexHome '<isolated-directory>'` is available on all deployment commands for testing without touching the real Codex installation.
