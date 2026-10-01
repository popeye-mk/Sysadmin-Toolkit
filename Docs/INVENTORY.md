# Sysadmin-Toolkit — Complete Inventory

> For the full handbook (install, setup, how to run, Zabbix, troubleshooting) see **`MANUAL.md`**. This file is just the flat script list.

Everything in the kit, one flat list. **Every script runs on its own when
copied out** — "Standalone" says how: *self* = carries its own helpers
inside the file; *folder* = needs only the files in its own section folder
(e.g. a `.conf` or `.json` next to it). Nothing needs another section.

Reports go to `C:\Sysadmin-Toolkit\Reports`, backups to `...\Backups`, logs
to `...\Logs` — regardless of where the script itself lives (USB, ISO,
network share). `-WhatIf` = previews without changing anything.


## Config\ — your environment (created on first install, never overwritten)

| File | Contents | Read by |
|---|---|---|
| `toolkit-settings.json` | Company/helpdesk info, AD OUs + UPN suffix, Entra licences/groups, shares, desktop/regional/power defaults, Teams webhook + SMTP, Zabbix, expected local admins, report folder, schedules | 42 scripts (explicit parameter → Config → default) |
| `desktop-shortcuts.json` | Shortcuts for every desktop | `20\New-DesktopShortcuts.ps1` |
| `Branding\wallpaper.jpg`, `lockscreen.jpg`, `logo.bmp` | Company images | `20\Set-Branding.ps1` |
| `README.md` | How the lookup works, where scripts look, secrets note | — |

## Root

| File | Purpose | Standalone |
| --- | --- | --- |
| `Start-SysadminToolkit.ps1` | The "God file": one menu over every section and script. Optional convenience — nothing needs it. | self |
| `Sysadmin-Toolkit.bat` | Double-click launcher for the menu (bypasses execution policy for that window). | self |
| `Install-Toolkit.ps1` | Copy the kit from ISO/USB/share to `C:\Sysadmin-Toolkit`, unblock files, desktop shortcut. Never overwrites Reports/Backups/Logs/secrets. | self |
| `Install-AllScheduledTasks.ps1` | Register a Scheduled Task (as SYSTEM) for every recurring report it finds; skips missing ones. `-Remove` to undo. | self |
| `Invoke-ToolkitFleet.ps1` | Run one kit script across a company's devices (resolve via Zabbix/AD, WinRM check, Invoke-Command, one report). `-WhatIf` lists targets. | self |
| `README.md` | Master guide, per section. | — |
| `INVENTORY.md` | This file. | — |
| `ROADMAP.md` | What was planned, what's built, what's left. | — |
| `CHANGELOG.md` | Dated log of additions. | — |
| `VERSION` | Kit version (bumped with the changelog). | — |
| `_Common\SysadminToolkit.Common.psm1` | Shared helpers used *inside* the kit by sections 01–07; every script has an inline fallback if it's absent. | — |

## 01 — Users (on-prem AD + local)

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `New-ADUserOnboard.ps1` | Create AD user: temp password, groups (copy from colleague), title/dept/manager, home drive. | AD module, admin | yes | self |
| `Disable-ADUserOffboard.ps1` | Disable (never delete), randomise password, save then strip groups, move to Disabled OU, hide from GAL. | AD module, admin | yes | self |
| `New-BulkADUsers.ps1` | Many users from a CSV (`sample-newhires.csv`), results CSV with temp passwords. | AD module, admin | yes | self |
| `Get-ADPasswordExpiry.ps1` | Accounts with passwords expiring soon. Read-only. | AD module | — | self |
| `Manage-LocalUser.ps1` | Local (non-domain) account onboard/offboard. | admin | yes | self |

## 02 — Windows 11

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Set-Win11Baseline.ps1` | Per-user baseline: classic context menu, taskbar/Explorer defaults, web search & Spotlight off. Registry backup, `-Rollback`. | user | yes | self |
| `Disable-Win11AITelemetry.ps1` | Machine policy: Copilot/Recall off, telemetry minimum, advertising ID off. Backup, `-Rollback`. | admin | yes | self |

## 03 — Windows 10

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Test-Win11Readiness.ps1` | TPM/Secure Boot/UEFI/CPU/RAM/disk check + Win10 end-of-support countdown. Read-only. | — | — | self |
| `Set-Win10Baseline.ps1` | Per-user baseline: Explorer defaults, Cortana/Bing off, ad ID off. Backup, `-Rollback`. | user (+admin for machine bits) | yes | self |

## 04 — PC Provisioning

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Initialize-NewPC.ps1` | Rename, power plan, RDP, winget software set, time zone, update scan. | admin, winget | yes | self |
| `Join-Domain.ps1` | Domain join with optional rename + target OU, sanity checks. | admin | yes | self |
| `Setup-PrintersAndDrives.ps1` | Map drives + install printers from a manifest, idempotent. | user | yes | self |
| `Harden-Baseline.ps1` | Conservative security hardening for a standalone PC. Backup, `-Rollback`. | admin | yes | self |

## 05 — Network

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Get-NetworkDiagnostics.ps1` | Adapters, gateway, DNS, internet, public IP, named hosts → HTML. Read-only. | — | — | self |
| `Invoke-SubnetScan.ps1` | Sweep a subnet: live hosts, names, MACs, optional ports → CSV/HTML. Read-only. | — | — | self |

## 06 — Debloat & Privacy

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Remove-Bloatware.ps1` | Remove junk from a curated safe list. Dry-run by default, `-Execute` to act. | admin | dry-run | self |
| `Get-StartupItems.ps1` | Every startup entry; `-Disable` one reversibly. | admin for HKLM | yes | self |

## 07 — Reporting & Health

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Invoke-HealthCheck.ps1` | Scored health: disk, memory, services, pending reboot, uptime, updates, event errors, Defender → HTML + trend CSV + optional e-mail. | — | — | self |
| `Install-HealthCheckTask.ps1` | Daily Scheduled Task for the health check with e-mail baked in. `-Remove`. | admin | yes | self |
| `Get-PCInventory.ps1` | Full per-PC inventory → HTML + CSV. | — (BitLocker needs admin) | — | self |
| `Get-CertExpiryReport.ps1` | Cert stores (local/remote) for expired/expiring certs → HTML. | — | — | self |
| `Get-SoftwareInventoryReport.ps1` | Fleet software rollup + EOL flags from `EOLSoftwareList.json`. | WinRM for remote | — | folder |
| `Confirm-BitLockerEscrow.ps1` | Recovery keys escrowed to AD / Entra? Flags at-risk volumes. | AD and/or Graph optional | — | self |
| `Get-FirewallAuditReport.ps1` | Firewall profiles, inbound allow rules, listening ports; flags risky ports. | WinRM for remote | — | self |
| `EOLSoftwareList.json` | Editable seed list of long-EOL software (not a live feed). | — | — | — |

## 08 — TechToolkit (bundled 5.1, 22 departments)

| File | Purpose | Standalone |
| --- | --- | --- |
| `TechToolkit.ps1` / `TechToolkit.bat` | Full menu app; `-QuickRun <cmd>` for one tool; `-Help` lists commands. | folder |
| `Run-Department.ps1` | Open one department directly by name or number. | folder |
| `Launchers\*.bat` (22) | Double-click one department. | folder |
| `Departments\*.ps1` (23, incl. `00-Core`) | The department modules. | folder |
| `QuickScan.ps1` / `.bat` | Fast system scan. | folder |
| `Optimize-Workstation.ps1`, `Optimize-Taskbar.ps1` (+ `.vbs`), `Get-SysadminTools.ps1`, `create_shortcut.ps1` | The "additions" — run on their own. | self |

## 09 — Entra ID + Intune (Microsoft Graph)

| Script | Purpose | Needs (Graph role) | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `New-EntraUserOnboard.ps1` | Cloud-native onboard, or `-ExistingUser` for post-sync licence/groups/manager. | User Administrator | yes | self |
| `Disable-EntraUserOffboard.ps1` | Block sign-in, revoke sessions, strip groups/licences, optional Intune retire. | User Administrator (+Intune for retire) | yes | self |
| `Get-IntuneDeviceCompliance.ps1` | Fleet compliance state, staleness, encryption → HTML + CSV. | Intune (read) | — | self |
| `Get-IntunePatchCompliance.ps1` | Build level vs your own fleet's newest, per Windows version. | Intune (read) | — | self |
| `Get-LAPSComplianceReport.ps1` | Windows LAPS escrow present + fresh, per device. | `DeviceLocalCredential.Read.All` | — | self |
| `Get-EntraSecurityPosture.ps1` | Conditional Access states + privileged role holders (standing). | `Policy.Read.All`, `RoleManagement.Read.Directory` | — | self |
| `Deploy-ScriptViaIntune.ps1` | Push any `.ps1` as an Intune device script to a group. | Intune Administrator | yes | self |
| `New-IntuneConfigProfile-Win11Baseline.ps1` | CSP-backed Win11 baseline (Copilot/telemetry/tailored experiences) as a policy. | Intune Administrator | yes | self |
| `_GraphCommon.psm1` | Shared Graph helpers used inside the kit; every script falls back inline. | — | — | — |

## 10 — Monitoring: Zabbix + Grafana

| File | Purpose | Standalone |
| --- | --- | --- |
| `Install-ZabbixAgent.ps1` | Silent Zabbix Agent 2 install + config + deploys the UserParameter. `-WhatIf`. | folder |
| `New-ZabbixToolkitScripts.ps1` | Create the "Toolkit: …" Zabbix buttons over the API from the definitions JSON. Idempotent, `-WhatIf`, `-HostGroup`, `-Remove`. | folder |
| `toolkit-zabbix-scripts.json` | Which read-only scripts become Zabbix buttons (editable). | — |
| `Zabbix-Run-Toolkit-Scripts.md` | How to run kit scripts from Zabbix (buttons, hardening, remediation). | — |
| `UserParameters\Get-ToolkitZabbixMetrics.ps1` | Emits one JSON line: health score, reboot pending, disk, Defender, uptime… | self |
| `UserParameters\SysadminToolkit.conf` | The `toolkit.metrics` UserParameter. | folder |
| `zbx_template_windows_sysadmintoolkit.xml` | Zabbix 6.0+ template: 1 master + 11 dependent items, 8 triggers. | — |
| `grafana_dashboard_sysadmintoolkit.json` | Grafana dashboard for the grafana-zabbix plugin. | — |

## 11 — GPO / ADMX

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Deploy-GPOCentralStore.ps1` | Extract the ADMX MSI, back up the existing Central Store, deploy to SYSVOL. | Domain Admin (SYSVOL write) | yes | self |
| `Backup-GPOs.ps1` | Backup every GPO + HTML report per GPO + "changed since last run". | GroupPolicy module | yes | self |

## 12 — AD Health

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Test-ADHealth.ps1` | dcdiag + repadmin + FSMO + SYSVOL, scored → HTML. Read-only. | RSAT AD tools | self |

## 13 — Alerting

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Send-ToolkitAlert.ps1` | Teams webhook and/or e-mail alert; prints if nothing configured. Call by path from anywhere. | webhook URL / SMTP | self |

## 14 — Employee Lifecycle (hybrid AD + Entra/Intune)

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `New-EmployeeOnboard.ps1` | AD account → wait for Entra sync → licence/cloud groups. Cloud-only mode with `-SkipAD`. Re-runnable. | AD and/or Graph | yes | self |
| `Disable-EmployeeOffboard.ps1` | Cloud cutoff first (block + revoke), then AD disable. Either half alone. | AD and/or Graph | yes | self |

## 15 — DNS / DHCP

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Get-DHCPScopeReport.ps1` | Scope utilisation %, warning/critical thresholds → HTML. Read-only. | DhcpServer module | — | self |
| `Get-StaleDNSRecords.ps1` | A records with no ping reply (+ AD cross-check). Report only; removal is a separate `-RecordsToRemove` step. | DnsServer module | yes (removal) | self |

## 16 — File Shares

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Get-SharePermissionReport.ps1` | Share + NTFS permissions, orphaned SIDs flagged → HTML. Read-only. | read rights; WinRM remote | self |

## 17 — Security Audit

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Get-LocalAdminAudit.ps1` | Local Administrators membership across machines, flagged against your allow list. | WinRM remote | self |

## 18 — Environment Discovery

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Get-EnvironmentDiscovery.ps1` | Day-1 map: AD, DCs, FSMO, OUs, GPOs, DHCP, DNS, servers, shares, (Intune) → Markdown + HTML. Read-only. | RSAT (each section optional) | self |

## 21 — Fleet

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Get-ManagedFleet.ps1` | List a company's devices from Zabbix host groups (AD/Intune fallback) → Name/IPv4/OS/Online/Source. Read-only. | Zabbix API token or RSAT AD | self |

(The runner `Invoke-ToolkitFleet.ps1` lives at the root — see the Root table.)

## 19 — Secrets

| Script | Purpose | Needs | Standalone |
| --- | --- | --- | --- |
| `Manage-ToolkitSecret.ps1` | DPAPI-encrypted `-Set/-Get/-List/-Remove` of webhook URLs, client secrets, SMTP passwords. | Windows | self |

## 20 — Desktop Experience

| Script | Purpose | Needs | WhatIf | Standalone |
| --- | --- | --- | --- | --- |
| `Set-DesktopExperience.ps1` | Theme, desktop icons, icon size, Explorer view, Quick Access pins, tips off. Backup + `-Rollback`. | user | yes | self |
| `New-DesktopShortcuts.ps1` | Shortcuts from `Config\desktop-shortcuts.json` (or `-ManifestPath`) (apps/shares/URLs/toolkit) with icons; per-user or Public desktop; `-Remove`. | user (admin for AllUsers) | yes | folder |
| `Set-Branding.ps1` | Enforced wallpaper + lock screen (PersonalizationCSP, Pro-compatible), OEM support info. Backup + `-Rollback`. | admin | yes | self |
| `Set-StartTaskbarLayout.ps1` | Start/taskbar pins per OS rules; `-ExportCurrent`; drops files it can remove again. Backup + `-Rollback`. | admin | yes | self |
| `Add-ContextMenuEntries.ps1` | PowerShell here (+Admin), Copy path, Open with Notepad, Take ownership (opt-in). Own keys; `-Remove`. | user (admin for AllUsers) | yes | self |
| `Set-RegionalSettings.ps1` | nl-BE format, Belgian keyboard, Brussels TZ, home location, date format; `-CopyToSystem`. JSON snapshot + `-Rollback`. | user (admin for CopyToSystem) | yes | self |
| `Set-PowerAndLock.ps1` | Timers, idle lock, lid/power button, Fast Startup, hibernate; `-Workstation`/`-Laptop`. Scheme export + `-Rollback`. | admin | yes | self |
| `shortcuts-EXAMPLE.json` | Example manifest (format reference; `-UseExample` runs it). | — | — | — |

## Support folders

| Folder | Contents |
| --- | --- |
| `Runbooks\` | RB-01…RB-09 incident guides + ticket-note template, each pointing at the kit script to run. |
| `Docs\` | `First-Week-Plan.md` (what to find out, what to ask, baselines to take), `Communication-Templates.md` (NL/EN: maintenance, outage, resolved, password reset, welcome, phishing, ticket reply). |
| `Tests\` | `Run-Tests.ps1` + `Toolkit.Tests.ps1` (Pester): every script parses, PS5.1-safe, risky scripts keep `-WhatIf` + never delete accounts, no hard module dependencies. |
| `Reports\` `Backups\` `Logs\` | Generated output — git-ignored, never overwritten by an install. |
