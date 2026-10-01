# 02 — Windows 11

Two scripts that set a sensible Windows 11 baseline — one for the **logged-in
user's** experience, one for **machine-wide** privacy/AI policy.

Try **`-WhatIf`** first; both have **`-Rollback`** to undo.

| Script | What it does | Admin? |
| --- | --- | --- |
| `Set-Win11Baseline.ps1` | Per-user: classic right-click menu back, tidy taskbar/Explorer defaults, web search & Spotlight off. | no |
| `Disable-Win11AITelemetry.ps1` | Machine policy: Copilot/Recall off, telemetry to minimum, advertising ID off. | yes |

```powershell
# See what it would change, then apply, then (if needed) undo:
.\02-Windows11\Set-Win11Baseline.ps1 -WhatIf
.\02-Windows11\Set-Win11Baseline.ps1
.\02-Windows11\Set-Win11Baseline.ps1 -Rollback
```

The `-Skip...` switches (e.g. `-SkipTaskbar`) leave one part alone if you don't
want it changed. `Set-Win11Baseline` changes *your* profile — to apply it to
every user, push it via a GPO/Intune logon script (it must run in each user's own
session). `Disable-Win11AITelemetry` is machine-wide, so it applies to everyone.
