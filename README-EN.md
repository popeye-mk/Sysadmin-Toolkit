# Sysadmin-Toolkit

A modular PowerShell toolkit for day-to-day Windows system administration —
built for an all-Microsoft, hybrid environment (Windows endpoints, Entra ID +
Intune, monitoring via Zabbix → Grafana).

Everything lives in **one folder**, but nothing forces you to carry the whole
thing. Grab the whole kit, one area, or a single tool — whatever the job needs.

> **New here? Read `Docs\MANUAL.md`** — the single handbook: install, setup, the menu, Zabbix, day-one, troubleshooting, and every script. This README is the short intro; `MANUAL.md` is the one place with everything.

---

## Status — tested on a real domain

Not just "it parses". Validated live on a Windows Server 2025 domain controller
(`lab.local`) and a Zabbix box: install, the menu, environment discovery, AD
health, GPO backup, share and firewall audits, local-admin audit, certificate
expiry, the full user onboard → offboard lifecycle, the section-20 desktop
scripts (branding, regional, context menu) with preview and rollback — and the
kit **run from Zabbix**: click a host in the monitoring console, run a script,
get the answer back. See `CHANGELOG.md` for what each real-Windows run turned up
and fixed, and `10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md` for the
monitoring integration.

---

## Three ways to use it

**1. Need everything in one place** → copy the whole `Sysadmin-Toolkit` folder
(or mount the ISO and run `Install-Toolkit.ps1`). Double-click
`Sysadmin-Toolkit.bat` for one menu over every section — that's the "God
file". Full flat list of everything: `Docs\INVENTORY.md`.

**2. Need one area** → take a single section folder (e.g. `05-Network`), or open
one TechToolkit department at a time (see section 08 below). Every section
is self-sufficient.

**3. Need one tool** → copy a single `.ps1` and run it. The section scripts are
**self-standing**: inside the kit they share one helper module, but if you copy a
script out on its own it carries its own helpers and still runs. For TechToolkit,
fire a single tool from the command line with `-QuickRun` (no menu).

> That's the whole design: one organised kit, every piece able to work alone.

**Using the menu.** Pick a section by number, then a script by number. Typing
the number alone shows what the script does first (summary, every switch,
examples), then asks — Enter runs it as is, or type switches such as
`-All -WhatIf`, or B to go back. `H 3` shows the full help for script 3.
Number + switches on one line (`4 -Rollback`) runs directly. The card's last
line tells you whether the script is read-only, supports `-WhatIf` (preview,
change nothing) and `-Rollback` (restore the backup it made).

---

## First-run setup

Execution policy may block scripts on a fresh machine. For a single session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

Run anything as **Administrator** if it changes the system; read-only tools
(inventory, diagnostics, health, readiness) run fine without.

Reports go to `C:\Sysadmin-Toolkit\Reports`, logs to `...\Logs`, and safety
backups to `...\Backups` (all created automatically, and it fails quietly if a
non-admin can't create them).

**Fill in `Config\` once.** The installer creates `Config\toolkit-settings.json`
(company and helpdesk info, AD OUs and UPN suffix, Entra licences and groups, file
server and shares, desktop/regional/power defaults, Teams webhook and SMTP, Zabbix
server, expected local admins, report folder, schedule times),
`Config\desktop-shortcuts.json` (the shortcuts every desktop gets) and
`Config\Branding\` (wallpaper, lock screen, logo). Scripts read from there
whatever you don't pass on the command line — **explicit parameter → Config →
built-in default** — and print one grey `[Config] using: …` line so you always see
where a value came from. Updates never overwrite `Config\`. A script copied out of
the kit finds no Config and simply runs as documented. Details: `Config\README.md`.

---

## Layout

```
Sysadmin-Toolkit\
├─ _Common\              Shared helper module (used inside the kit; scripts also self-provide it)
├─ 01-Users\             AD + local user lifecycle
├─ 02-Windows11\         Windows 11 baselines & privacy
├─ 03-Windows10\         Windows 10 baselines & upgrade readiness
├─ 04-PC-Provisioning\   New-machine setup & domain join
├─ 05-Network\           Diagnostics & discovery
├─ 06-Debloat-Privacy\   Bloatware removal & startup control
├─ 07-Reporting-Health\  Health checks & scheduled reporting
├─ 08-TechToolkit\       Full TechToolkit 5.1 (22 departments) + additions
│   ├─ TechToolkit.ps1       Menu app  /  -QuickRun <cmd>  for one tool
│   ├─ Run-Department.ps1    Open ONE department directly
│   ├─ Launchers\            Double-click .bat per department (Network.bat, …)
│   └─ Departments\          The 22 department modules
├─ 09-Entra-Intune\      Cloud identity (Graph) + Intune device/policy management
├─ 10-Monitoring-Zabbix\ Zabbix agent + template + Grafana dashboard
├─ 11-GPO-ADMX\          GPO Central Store deploy + GPO backup/report
├─ 12-AD-Health\         dcdiag + replication + FSMO health check
├─ 13-Alerting\          Shared Teams/e-mail alert helper
├─ 14-Employee-Lifecycle\ Combined AD + Entra/Intune onboard/offboard
├─ 15-DNS-DHCP\          DHCP scope utilization + stale DNS record report
├─ 16-FileShares\        Share + NTFS permission audit, orphaned SIDs
├─ 17-Security-Audit\    Local admin membership across the fleet
├─ 18-Environment-Discovery\  Day-1 map of the whole environment → Markdown + HTML
├─ 19-Secrets\           DPAPI-encrypted store for webhooks / client secrets / SMTP passwords
├─ 20-Desktop-Experience\ Theme, icons, shortcuts, branding, pins, right-click menu, regional, power/lock
├─ 22-Windows-Update\    Pilot ring + hold: install only the Windows updates you approved; patch status
├─ Config\               YOUR environment: toolkit-settings.json, desktop-shortcuts.json, Branding\ (never overwritten)
├─ Runbooks\             RB-01…RB-09 "what to do when" incident guides
├─ Docs\                 First-week plan, NL/EN communication templates
├─ Tests\                Pester suite: parse, PS5.1 compat, safety contracts
├─ Reports\  Backups\  Logs\   (generated output — git-ignored)
├─ Start-SysadminToolkit.ps1       The menu over everything ("God file") — optional
├─ Sysadmin-Toolkit.bat            Double-click launcher for that menu
├─ Install-Toolkit.ps1             ISO/USB/share → C:\Sysadmin-Toolkit + desktop shortcut
├─ Install-AllScheduledTasks.ps1   Register every recurring report's Scheduled Task in one pass
├─ Docs\                 All the documentation: MANUAL.md (the handbook), INVENTORY, ROADMAP,
│                        NEXT, First-Week-Plan, Communication-Templates
├─ CHANGELOG.md   VERSION
├─ README.md
└─ .gitignore
```

---

## 01 — Users

| Script | What it does | Needs |
| --- | --- | --- |
| `New-ADUserOnboard.ps1` | Full joiner flow: create AD user, temp password + change-at-logon, groups, copy a colleague's groups, title/dept/manager, home drive. | AD module, admin |
| `Disable-ADUserOffboard.ps1` | Leaver flow, safe: **disable** (not delete), randomise password, save then strip groups, move to a Disabled OU, hide from GAL. | AD module, admin |
| `New-BulkADUsers.ps1` | Create many users from a CSV, temp password each, results CSV. See `sample-newhires.csv`. | AD module, admin |
| `Get-ADPasswordExpiry.ps1` | Report accounts with passwords expiring soon (good weekly task). Read-only. | AD module |
| `Manage-LocalUser.ps1` | Onboard/offboard a **local** account (no domain): create + temp password + change-at-logon, or disable on leave. | admin |

## 02 — Windows 11

| Script | What it does | Needs |
| --- | --- | --- |
| `Set-Win11Baseline.ps1` | Per-user baseline: classic right-click menu, taskbar/Explorer defaults, web-search & Spotlight ads off. Backup + `-WhatIf` + `-Rollback`. | user (mostly) |
| `Disable-Win11AITelemetry.ps1` | Machine policy: Copilot & Recall off, telemetry down, advertising ID / tailored experiences off. Backup + `-WhatIf` + `-Rollback`. | admin |

## 03 — Windows 10

| Script | What it does | Needs |
| --- | --- | --- |
| `Test-Win11Readiness.ps1` | Win11 upgrade check (TPM/Secure Boot/UEFI/CPU/RAM/disk) + Windows 10 end-of-support countdown. Read-only, per-machine CSV. | read-only |
| `Set-Win10Baseline.ps1` | Per-user baseline: Explorer defaults, Cortana + Bing off, ad ID / suggestions off, Timeline upload off. Backup + `-WhatIf` + `-Rollback`. | user (+admin for machine bits) |

## 04 — PC Provisioning

| Script | What it does | Needs |
| --- | --- | --- |
| `Initialize-NewPC.ps1` | First-touch: rename, power plan, enable RDP (NLA), winget software set, time zone, update scan. | admin, winget |
| `Join-Domain.ps1` | Join AD (optionally rename + target OU), secure prompt, sanity checks, optional reboot. | admin, DNS→DC |
| `Setup-PrintersAndDrives.ps1` | Map network drives + install network printers from a simple manifest — the without-GPO way. Idempotent, `-WhatIf`. | user |
| `Harden-Baseline.ps1` | Conservative security hardening baseline for a standalone Win10/11 PC (no GPO). Backup + `-WhatIf` + `-Rollback`. | admin |

## 05 — Network

| Script | What it does | Needs |
| --- | --- | --- |
| `Get-NetworkDiagnostics.ps1` | The "can't reach the server" one-shot: adapters, gateway, DNS, internet, public IP, named hosts. HTML report. Read-only. | read-only |
| `Invoke-SubnetScan.ps1` | Sweep a /24, resolve names, read MACs, optional port probe. CSV + HTML. Read-only. | read-only |

## 06 — Debloat & Privacy

| Script | What it does | Needs |
| --- | --- | --- |
| `Remove-Bloatware.ps1` | Remove junk from a **curated safe list** (installed + provisioned). **Dry-run by default**; `-Execute` to act; `-List` shows the list; never touches OS-critical apps. | admin |
| `Get-StartupItems.ps1` | List all startup entries (Run keys, Startup folders, logon tasks); `-Disable` one reversibly. | admin for HKLM/disable |

## 07 — Reporting & Health

| Script | What it does | Needs |
| --- | --- | --- |
| `Invoke-HealthCheck.ps1` | Scored health check: disk, memory, services, pending reboot, uptime, updates, event errors, Defender. HTML + trend CSV + optional e-mail. Read-only. | read-only |
| `Install-HealthCheckTask.ps1` | Register a daily Scheduled Task (runs as SYSTEM, e-mail baked in). `-Remove` to uninstall. | admin |
| `Get-PCInventory.ps1` | Full per-PC inventory (hardware/OS/network/storage, activation, BitLocker, installed software) → HTML + CSV. Read-only. | read-only (BitLocker needs admin) |
| `Get-CertExpiryReport.ps1` | Scans certificate stores (local or remote via `-ComputerName`) for anything expired or expiring soon — RDP listener, IIS, LDAPS certs. HTML report. Read-only. | read-only |
| `Get-SoftwareInventoryReport.ps1` | Installed-software rollup across one or more machines — title/version/publisher, machine count, flags anything matching `EOLSoftwareList.json` (a small, manually-maintained seed list, not a live feed). HTML + CSV. | read-only |
| `Confirm-BitLockerEscrow.ps1` | Confirms BitLocker recovery keys are actually escrowed — to AD, to Entra, or both — before someone's locked out and the key turns out to have never been saved anywhere. Runs fine with just AD, just Entra, or neither (local-only check then). | read-only; AD and/or Graph optional |
| `Get-FirewallAuditReport.ps1` | Firewall profile status + enabled inbound allow rules + what's actually listening, per machine. Flags a short list of commonly-risky ports (RDP, SMB, WinRM, Telnet) by default. | read-only |

> The health check still e-mails HTML on its own. For the same data to land in
> Zabbix/Grafana instead of (or alongside) an inbox, see section 10 below.

---

## 08 — TechToolkit (bundled, 22 departments)

The full TechToolkit 5.1 menu app, with the additions applied. It's a
self-contained unit — copy the `08-TechToolkit` folder anywhere and it runs.
Three ways in, from most to least:

**Full menu**

```powershell
cd 08-TechToolkit
.\TechToolkit.ps1
```

**One department** (no clicking through the top menu):

```powershell
.\Run-Department.ps1 -Department network
.\Run-Department.ps1 -Department 5 -Client "Acme Corp"
```

…or just double-click a shortcut in `08-TechToolkit\Launchers\` —
`Network.bat`, `Security.bat`, `ActiveDirectory.bat`, and so on.

**One tool** (straight to a single action, scriptable):

```powershell
.\TechToolkit.ps1 -QuickRun flushdns
.\TechToolkit.ps1 -QuickRun secaudit -Client "SecureBank"
```

Run `.\TechToolkit.ps1 -Help` for the full `-QuickRun` command list. The
additions (`Optimize-Workstation.ps1`, `Optimize-Taskbar.ps1`,
`Get-SysadminTools.ps1`) sit at the `08-TechToolkit` root and run on their own too.

---

## 09 — Entra ID + Intune

Cloud-native identity and device management via Microsoft Graph — the
counterpart to `01-Users` for a tenant with no on-prem AD, or for the cloud
steps (licensing, Intune groups) in a hybrid tenant. Full detail in
`09-Entra-Intune\README.md`; summary:

| Script | What it does | Needs |
| --- | --- | --- |
| `New-EntraUserOnboard.ps1` | Cloud-native onboard: temp password, usage location, licenses, groups, manager. `-ExistingUser` to just configure an account already synced from on-prem. | Graph, User Administrator |
| `Disable-EntraUserOffboard.ps1` | Block sign-in, revoke sessions, save-then-strip groups, remove licenses, optionally retire the user's Intune devices. Disables, never deletes. | Graph, User Administrator |
| `Get-IntuneDeviceCompliance.ps1` | Fleet-wide Intune compliance report — every managed device, state, staleness, encryption. HTML + CSV. Read-only. | Graph, Intune Administrator (read) |
| `Deploy-ScriptViaIntune.ps1` | Push ANY `.ps1` from this whole kit to a fleet as an Intune device management script, assigned to a group. | Graph, Intune Administrator |
| `New-IntuneConfigProfile-Win11Baseline.ps1` | The CSP-backed subset of the Win11 baseline (Copilot/telemetry/tailored experiences) as a real Intune policy. | Graph, Intune Administrator |
| `Get-IntunePatchCompliance.ps1` | Fleet-wide Windows build/patch level — flags devices whose build is behind the newest build already seen elsewhere in *your* fleet (not an absolute check against Microsoft's release schedule — see the script's `.NOTES`). Read-only. | Graph, Intune Administrator (read) |
| `Get-LAPSComplianceReport.ps1` | Confirms Windows LAPS is actually escrowing + rotating local admin passwords fleet-wide, not just configured once. Flags devices with no escrow record or a stale one. Read-only. | Graph, `DeviceLocalCredential.Read.All` |
| `Get-EntraSecurityPosture.ps1` | Conditional Access policy states + current holders of high-privilege Entra roles (standing assignments — not PIM eligible/time-bound; see `.NOTES`). Read-only. | Graph, `Policy.Read.All` + `RoleManagement.Read.Directory` |

Requires `Install-Module Microsoft.Graph -Scope CurrentUser` once; each script
prompts for sign-in + consent to just the scopes it needs on first use.

---

## 10 — Monitoring: Zabbix + Grafana

Wires this toolkit's health data into Zabbix/Grafana instead of (or alongside)
the e-mailed report from section 07. Self-contained — copy just this one
folder to an endpoint. Full setup walkthrough in
`10-Monitoring-Zabbix\README.md`; summary:

| File | What it is |
| --- | --- |
| `Install-ZabbixAgent.ps1` | Silent Zabbix Agent 2 install + config, deploys the toolkit's UserParameter in the same run. |
| `UserParameters\Get-ToolkitZabbixMetrics.ps1` | Self-contained script emitting one line of JSON (health score, pending reboot, disk, Defender, uptime, AD password-expiry count where applicable). |
| `UserParameters\SysadminToolkit.conf` | The one-line Zabbix UserParameter wiring that script in as item `toolkit.metrics`. |
| `zbx_template_windows_sysadmintoolkit.xml` | Import-ready Zabbix 6.0+ template: 1 master item + 11 dependent items (JSONPath preprocessing — one PowerShell launch feeds every item) + 8 triggers. |
| `grafana_dashboard_sysadmintoolkit.json` | Grafana dashboard (grafana-zabbix plugin): fleet health score, pending-reboot/Defender-off/low-disk counts, a trend chart, a sortable table. |

One PowerShell launch every 5 minutes feeds the whole template — dependent
items split the JSON back into separate Zabbix items instead of spawning
PowerShell once per metric.

---

## 11 — Group Policy: ADMX Central Store

Deploys a Microsoft "Administrative Templates (.admx)" package into your
domain's GPO Central Store, so every admin editing Group Policy sees the same
up-to-date policy set instead of whatever ships with their own Windows build.
Self-contained — copy just this one folder. Full walkthrough in
`11-GPO-ADMX\README.md`; summary:

| File | What it is |
| --- | --- |
| `Deploy-GPOCentralStore.ps1` | Extracts the ADMX MSI (or uses an already-extracted folder), backs up the existing Central Store, then deploys into `\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions`. `-WhatIf` supported throughout. |

```powershell
.\Deploy-GPOCentralStore.ps1 -SourceMsi 'C:\Downloads\Administrative Templates (.admx) for Windows Server2025 Oct 2025 Update-V3.msi' -WhatIf
```

`Backup-GPOs.ps1` in the same folder backs up the GPO *objects* themselves
(separate from the ADMX templates above) — full detail in
`11-GPO-ADMX\README.md`.

---

## 12 — AD Health

The "does AD feel fine?" check: dcdiag, replication summary, FSMO role
holders, SYSVOL/NETLOGON reachability — scored and reported like the PC
health check, but for the domain. Self-contained — copy just this folder.
Full detail in `12-AD-Health\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Test-ADHealth.ps1` | dcdiag + repadmin + FSMO + SYSVOL checks, scored Healthy/Attention/Action needed, HTML report. Read-only. | RSAT (AD module, dcdiag, repadmin) |

---

## 13 — Alerting

One place alert-sending lives — Teams webhook, e-mail, or both — instead of
every script rolling its own. Self-contained, single file. Nothing in the
kit calls it automatically yet (that's on the roadmap); use it standalone or
call it by path from your own scripts. Full detail in
`13-Alerting\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Send-ToolkitAlert.ps1` | Sends one alert via Teams Incoming Webhook and/or e-mail. Prints and warns (never fails) if no channel is configured. | Teams webhook URL and/or SMTP server |

---

## 14 — Employee Lifecycle (combined AD + Entra/Intune)

The full hybrid joiner/leaver flow in one command each, instead of running
`01-Users` and `09-Entra-Intune` scripts separately. Self-contained — does
its own AD and Graph work inline, doesn't need either of those sections
present. Full detail in `14-Employee-Lifecycle\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `New-EmployeeOnboard.ps1` | Creates the AD account, waits for Entra Connect sync, then applies usage location/license/cloud groups. Cloud-only tenant: creates the Entra account directly instead. Re-runnable. | AD module and/or Microsoft.Graph |
| `Disable-EmployeeOffboard.ps1` | Blocks Entra sign-in + revokes sessions + strips cloud access **first** (fastest real cutoff), then disables the AD account. Either half works alone. | AD module and/or Microsoft.Graph |

---

## 15 — DNS / DHCP

Two independent reports, neither needing the other. Self-contained — copy
just this folder. Full detail in `15-DNS-DHCP\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Get-DHCPScopeReport.ps1` | Utilization % per DHCP scope, flags anything approaching exhaustion. HTML report. Read-only. | DhcpServer module |
| `Get-StaleDNSRecords.ps1` | Finds A records that don't answer a ping, cross-checked against AD when available. **Reports only — never deletes automatically.** Removal is a separate, explicit, opt-in step. | DnsServer module |

---

## 16 — File Shares

Who has access to what — share-level + NTFS permissions in one report, with
orphaned SIDs flagged automatically. Self-contained, single file, read-only.
Full detail in `16-FileShares\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Get-SharePermissionReport.ps1` | SMB share + NTFS ACL audit (local or remote), flags orphaned SIDs (grants for deleted accounts). HTML report. | Read rights on shares/ACLs; WinRM for remote |

---

## 17 — Security Audit

Local admin membership across the fleet — almost always turns up a surprise.
Self-contained, single file, read-only. The other Tier 3 security additions
(LAPS, BitLocker escrow, Conditional Access/privileged roles, firewall) live
inside sections 09 and 07 above rather than here. Full detail in
`17-Security-Audit\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Get-LocalAdminAudit.ps1` | Who's in the local Administrators group, local or fleet-wide. Flags anyone not on your expected/allow list. HTML report. | Local; WinRM for remote |

---

## 18 — Environment Discovery

The day-1 script. One read-only run from an admin workstation or DC writes
a Markdown + HTML document of the environment you just walked into.
Self-contained. Full detail in `18-Environment-Discovery\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Get-EnvironmentDiscovery.ps1` | Domain/forest, DCs, FSMO, OU tree, GPOs, DHCP scopes, DNS zones, servers, shares, and with `-IncludeCloud` the Entra/Intune overview. Every section optional by module. | RSAT; Graph for cloud |

---

## 19 — Secrets

Keep webhook URLs, app-registration secrets and SMTP passwords out of
plaintext. Self-contained, Windows DPAPI, no infrastructure. Full detail in
`19-Secrets\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Manage-ToolkitSecret.ps1` | `-Set` / `-Get` / `-List` / `-Remove` named secrets in one encrypted file, bound to the user + machine that saved them. | Windows |

---

## 20 — Desktop Experience

The "make it look and behave like a proper work PC" layer. Seven
independent scripts, each with backup + `-Rollback` + `-WhatIf`. Full
detail and a start-to-finish new-PC recipe in `20-Desktop-Experience\README.md`.

| Script | What it does | Needs |
| --- | --- | --- |
| `Set-DesktopExperience.ps1` | Theme, classic desktop icons, icon size, Explorer view, Quick Access pins, tips off. `-All` for the sensible default. | user |
| `New-DesktopShortcuts.ps1` | Standard shortcuts from a JSON manifest — apps, shares, portals, the toolkit — with `.ico` icons, run-as-admin flag, per-user or Public desktop. | user / admin |
| `Set-Branding.ps1` | Company wallpaper + lock screen for all users (works on Pro), support phone/hours/URL in Settings > About. | admin |
| `Set-StartTaskbarLayout.ps1` | Pinned Start + taskbar apps, honest per OS about what Windows allows; `-ExportCurrent` to capture a reference. | admin |
| `Add-ContextMenuEntries.ps1` | "Open PowerShell here (Admin)", "Copy path", "Open with Notepad", opt-in "Take ownership" — cleanly removable. | user / admin |
| `Set-RegionalSettings.ps1` | Belgium-ready: nl-BE, Belgian (Period) keyboard, Brussels time, dd/MM/yyyy; `-CopyToSystem` for new users. | user / admin |
| `Set-PowerAndLock.ps1` | Screen/sleep timers, lock after idle, lid/power button, Fast Startup, hibernate. `-Workstation` / `-Laptop` presets. | admin |

---

## Runbooks, Docs, Tests

- **`Runbooks\`** — RB-01 user can't log in · RB-02 PC slow/won't boot ·
  RB-03 network unreachable · RB-04 disk full on a server · RB-05 printers ·
  RB-06 malware/phishing · RB-07 joiner/leaver · RB-08 service down ·
  RB-09 AD/GPO issues. Each points at the exact kit script for each step.
  Start with `Runbooks\README.md` (ticket-note template + escalation rule).
- **`Docs\First-Week-Plan.md`** — what to find out, whom to ask, which
  baselines to take in week one, and what *not* to touch yet.
- **`Docs\Communication-Templates.md`** — Dutch + English: planned
  maintenance, outage first notice, outage resolved, password reset, new
  user welcome, phishing warning, ticket reply.
- **`Tests\Run-Tests.ps1`** — Pester: every script parses, is PS5.1-safe,
  risky scripts keep `-WhatIf` and never delete accounts, nothing
  hard-requires a module by relative path.

---

## Installing from the ISO / a USB stick

Fastest: double-click **`Sysadmin-Toolkit-Setup.exe`** on the disc, answer Yes
to the admin prompt — it installs, adds the shortcut and opens the menu. Or
by hand:

```powershell
# mount the ISO (or plug in the stick), then from that drive:
D:\Install-Toolkit.ps1 -WhatIf
D:\Install-Toolkit.ps1
```

That copies the kit to `C:\Sysadmin-Toolkit`, unblocks the files, and puts
a **Sysadmin-Toolkit** shortcut on the desktop. Re-running updates the
scripts and leaves your Reports/Backups/Logs/secrets alone. The kit also
runs directly from the ISO for read-only tools — reports still land in
`C:\Sysadmin-Toolkit\Reports`.

---

## Keeping it all running on a schedule

`Install-AllScheduledTasks.ps1` at the kit root registers Scheduled Tasks
(as SYSTEM, sane default times) for every recurring report script it finds:
the health check, password-expiry report, cert-expiry report, and AD health
check. Missing ones are skipped with a warning, not an error — run it
whenever you've added one of these scripts, and it picks up whatever's
there.

```powershell
.\Install-AllScheduledTasks.ps1 -WhatIf
.\Install-AllScheduledTasks.ps1
.\Install-AllScheduledTasks.ps1 -Remove
```

---

## Safety notes

- **Test on a VM or one spare PC first.** Changes are backed up and most are
  reversible, but a lab run beats a surprise on someone's machine.
- **`-WhatIf` first** on anything that changes the system.
- **Reports, backups and logs hold machine/account details** — they're
  `.gitignore`d. Delete bulk-create CSVs (initial passwords) after use.
- Nothing phones home or installs agents; e-mail goes only to an SMTP server
  you configure.

---

*Part of the TechToolkit family. Author: Stojan Tomeski — stojantomeski.be*
