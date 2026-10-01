# 12 — AD Health

The "does AD feel fine?" check — run it first when something's off, or on a
daily schedule so you find out before someone reports it. Self-contained —
copy just this one file anywhere.

## What's here

| File | What it is |
| --- | --- |
| `Test-ADHealth.ps1` | dcdiag + repadmin replication summary + FSMO role holders + SYSVOL/NETLOGON reachability, scored Healthy / Attention / Action needed, HTML report. Read-only. |

## Usage

```powershell
.\Test-ADHealth.ps1                      # every DC in the domain
.\Test-ADHealth.ps1 -DomainController DC01
.\Test-ADHealth.ps1 -SkipDcdiag          # replication + FSMO + shares only, faster
```

## Requirements

RSAT: Active Directory module, plus `dcdiag.exe` and `repadmin.exe` (both
ship with RSAT-AD-Tools, or are already present on any domain controller).
If either is missing, that specific check is skipped with a warning — the
rest of the report still runs.

## Scheduling it

Use `..\Install-AllScheduledTasks.ps1` at the kit root to register this
alongside the other recurring reports, or set up a Scheduled Task for just
this one by hand if you'd rather.
