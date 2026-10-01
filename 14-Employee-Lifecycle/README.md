# 14 — Employee Lifecycle (AD + Entra/Intune, combined)

The hybrid joiner/leaver flow in one command each, instead of running the
on-prem script (`01-Users`) and the cloud script (`09-Entra-Intune`)
separately and hoping you did both in the right order. Self-contained — copy
just this one folder anywhere; it doesn't need `01-Users` or `09-Entra-Intune`
to exist alongside it (it does its own AD and Graph work inline).

## What's here

| Script | What it does |
| --- | --- |
| `New-EmployeeOnboard.ps1` | Creates the AD account (if the AD module is available), waits for it to sync to Entra, then applies usage location/license/cloud groups. Cloud-only tenant (or `-SkipAD`): creates the Entra account directly instead. Re-runnable — if the AD account already exists it skips straight to the cloud half. |
| `Disable-EmployeeOffboard.ps1` | Blocks Entra sign-in, revokes sessions, strips cloud groups/licenses, optionally retires Intune devices — **first**, because that's the fastest real cutoff. Then disables the AD account, randomizes its password, strips AD groups. Either half works alone. |

## Why cloud-first on offboarding

Waiting for Entra Connect sync before cutting off cloud access defeats the
point of an urgent offboard — someone disabled on-prem can still have live
sessions in Outlook, Teams, SharePoint for however long the sync interval is.
`Disable-EmployeeOffboard.ps1` hits Entra directly first (block sign-in +
revoke tokens), independent of AD, then handles the on-prem side.

## Usage

```powershell
# Full hybrid onboard
.\New-EmployeeOnboard.ps1 -GivenName Jan -Surname Peeters -OU 'OU=Staff,DC=contoso,DC=local' `
    -CopyGroupsFrom mvanden -CopyCloudGroupsFrom mvanden@contoso.com `
    -UsageLocation BE -LicenseSkuIds "c7df2760-2c81-4ef7-b578-5b5392b571df" -WhatIf

# Full hybrid offboard
.\Disable-EmployeeOffboard.ps1 -SamAccountName jpeeters -UpnSuffix contoso.com -WipeDevices -WhatIf

# Either script also runs fine with just -SamAccountName (AD only) or just
# -UserPrincipalName (cloud only) — pass what applies to your situation.
```

## Requirements

Either half runs independently based on what's installed — no error if one
module is missing, just a log line saying that half was skipped:

- **AD half**: `ActiveDirectory` module (RSAT), rights in the target OU.
- **Cloud half**: `Microsoft.Graph` module, User Administrator role (+ Intune
  Administrator for device retire on offboard). First use prompts for
  consent — see each script's `.NOTES` for the exact scopes.

## A note on sync timing

`New-EmployeeOnboard.ps1` polls for the Entra Connect sync by default (up to
30 minutes, `-SyncTimeoutMinutes` to change it). If your sync interval is
longer than that, it times out with a clear message — just run the exact
same command again later; it detects the AD account already exists and picks
up at the cloud half without recreating anything.
