# 03 — Windows 10

Check whether a Windows 10 PC can move to Windows 11, and set a sensible
Windows 10 baseline.

| Script | What it does | Admin? |
| --- | --- | --- |
| `Test-Win11Readiness.ps1` | Checks TPM / Secure Boot / UEFI / CPU / RAM / disk against the Win 11 requirements, plus a Windows 10 end-of-support countdown. **Read-only.** | no |
| `Set-Win10Baseline.ps1` | Per-user baseline: Explorer defaults, Cortana/Bing search off, advertising ID off. Has `-Rollback`. | user (+admin for machine bits) |

```powershell
# Is this PC Windows 11 ready? (safe, changes nothing)
.\03-Windows10\Test-Win11Readiness.ps1

# Apply the Windows 10 baseline (preview first):
.\03-Windows10\Set-Win10Baseline.ps1 -WhatIf
.\03-Windows10\Set-Win10Baseline.ps1
```

`Test-Win11Readiness` tells you exactly which check passed or failed (e.g. "TPM
2.0: OK, Secure Boot: not enabled") so you know what to fix — great for planning
which machines need replacing before Windows 10 goes end-of-support.
