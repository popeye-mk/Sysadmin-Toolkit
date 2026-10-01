# 17 — Security Audit

Local admin membership across the fleet. Self-contained, single file,
read-only. The other Tier 3 security items (LAPS, BitLocker escrow,
Conditional Access/privileged roles, firewall) live as additions inside
`09-Entra-Intune` and `07-Reporting-Health` rather than here — see the
master `README.md`'s section 09/07 tables for those.

## What's here

| Script | What it does |
| --- | --- |
| `Get-LocalAdminAudit.ps1` | Who's in the local Administrators group, local or across a fleet. Flags anyone not on your expected/allow list. HTML report. |

## Usage

```powershell
.\Get-LocalAdminAudit.ps1
.\Get-LocalAdminAudit.ps1 -ComputerName PC01,PC02,SRV01 `
    -ExpectedMembers 'Administrator','Domain Admins','Workstation-Admins' -FlaggedOnly
```

Set `-ExpectedMembers` to match your own delegation model — the default
(`Administrator`, `Domain Admins`) is a minimal, generic baseline. If you
grant local admin to IT via a dedicated AD group, add it here so the report
only flags genuine surprises instead of your own normal setup.

## Requirements

Local checks need nothing extra. Remote checks (`-ComputerName`) use
PowerShell remoting — WinRM enabled on the target, and rights there to read
the local Administrators group.
