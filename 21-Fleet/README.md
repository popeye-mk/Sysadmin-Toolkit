# 21 — Fleet

Run one toolkit script across many machines — a company's whole fleet — from one
place, and read the device list from the monitoring instead of keeping your own.

> **New to this? Read [`Run-The-Fleet.md`](Run-The-Fleet.md) first** — it's the
> full step-by-step: how to set up remoting (domain *and* workgroup machines),
> how to push the kit to a target, the safe first run, and a troubleshooting
> table for every error. This README is the quick reference; that file is the
> walkthrough. **Always run with `-WhatIf` the first time** — it lists the target
> machines and stops, so you see exactly what you'd hit before anything runs.

| Script | Purpose |
|---|---|
| `Get-ManagedFleet.ps1` | List a company's devices (Company → Zabbix host group), with AD (OU per company) and Intune as fallbacks. Read-only. Returns Name / IPv4 / OS / Online / Source. |
| `..\Invoke-ToolkitFleet.ps1` | (at the root) Resolve targets, check WinRM, run a kit script on each with `Invoke-Command`, one done/offline/failed report. `-WhatIf` lists targets first. Sets `SYSADMIN_TOOLKIT_FORCE=1` remotely so nothing hangs on a prompt. |

Company mapping is optional: `Config\companies.json` maps a friendly name to its
Zabbix group / AD OU / per-company Config folder (`Config\Companies\<name>\`).
Without it, `-Company` is the Zabbix host-group name.

**Scope matters.** Machine-scope scripts (reports, branding, power, `-AllUsers`
variants) run fine remotely. Per-user scripts (theme, per-user context menu,
regional) must run in the user's own session — push those via GPO/Intune, not the
fleet runner.

Needs PowerShell remoting (WinRM) open from your admin machine to the targets,
and the kit installed at `C:\Sysadmin-Toolkit` on them (installer / GPO / Intune).

Examples:

```powershell
.\Get-ManagedFleet.ps1 -Company Contoso -OS 'Windows 11*'
..\Invoke-ToolkitFleet.ps1 -Company Contoso -Script '17-Security-Audit\Get-LocalAdminAudit.ps1' -WhatIf
..\Invoke-ToolkitFleet.ps1 -Company Contoso -OS 'Windows 11*' -Script '20-Desktop-Experience\Set-Branding.ps1'
```
