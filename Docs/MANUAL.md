# Sysadmin-Toolkit — Manual

This is the one handbook for the whole kit. If you read one file, read this one.
It's written to be followed from a standing start: what the kit is, what you need,
how to install and set it up, and then how to actually use it — from the menu, the
command line, Zabbix, or across many machines at once. The last part is a
reference table for every script.

---

## 0. Start here — what this is and how it fits together

**What it is.** A collection of ready-made **PowerShell scripts** for everyday
Windows system administration — creating and disabling user accounts, checking a
machine's health, auditing who's a local admin, branding desktops, reporting on
certificates and shares, and so on. It's built for a typical **all-Microsoft**
setup: Windows 10/11 computers, an on-prem **Active Directory** (AD), **Entra ID
+ Intune** in the cloud, and **Zabbix** for monitoring.

**What you need.**

- A Windows machine to work from (your "admin machine"). For AD/DNS/GPO tasks
  that's usually a **domain controller** or a machine with **RSAT** (the Remote
  Server Administration Tools) installed.
- **Administrator rights** for anything that *changes* a machine. Read-only
  reports run fine as a normal user.
- PowerShell **5.1** (built into Windows) — you don't install anything; the kit
  is written for the PowerShell that's already there.

**The mental model** — the kit works in four moves, and the rest of this manual
is just those four in detail:

1. **Install** it once on a machine (§1).
2. **Configure** it once — fill in one settings file with your company's details
   (§2). After this, scripts "just know" your AD, your shares, your branding.
3. **Run** what you need — from a menu (§3), or a single script by name (§4).
4. **Scale** it — run from Zabbix (§6), or across many machines at once (§7).

**A safety promise first (read §5 too):** almost every script that changes
anything has a **`-WhatIf`** switch that shows what it *would* do and changes
nothing. When you're unsure, add `-WhatIf` and look first. Accounts are always
**disabled, never deleted.**

---

## Contents

1. [Install](#1-install)
2. [Set it up once — the Config folder](#2-set-it-up-once--the-config-folder)
3. [Run it — the menu](#3-run-it--the-menu)
4. [Run it — one script directly](#4-run-it--one-script-directly)
5. [Safety: preview, backup, rollback](#5-safety-preview-backup-rollback)
6. [Run it from Zabbix](#6-run-it-from-zabbix)
7. [Roll out to many PCs](#7-roll-out-to-many-pcs)
8. [Scheduled tasks](#8-scheduled-tasks)
9. [Day-one routine](#9-day-one-routine)
10. [Where things go](#10-where-things-go)
11. [Troubleshooting](#11-troubleshooting)
12. [Section-by-section reference](#12-section-by-section-reference)
13. [Also in the kit](#13-also-in-the-kit)

---

## 1. Install

Pick **one** of these three ways — they all end with the kit in
`C:\Sysadmin-Toolkit`.

- **The installer (easiest)** — double-click **`Sysadmin-Toolkit-Setup.exe`**. It
  unpacks the kit to `C:\Sysadmin-Toolkit`, unblocks the files, makes a desktop
  shortcut, and opens the menu. It's not code-signed, so Windows SmartScreen may
  warn once — click **"More info → Run anyway"**. (This is normal for in-house
  tools; the warning is about the signature, not the content.)
- **The ISO (for deployment)** — mount **`Sysadmin-Toolkit.iso`** (double-click it
  in Windows, or attach it to a VM), open the drive, and run
  `.\Install-Toolkit.ps1`. Same result. Use this when you're installing onto VMs
  or many machines.
- **Just the folder** — copy the `Sysadmin-Toolkit\` folder anywhere (USB, a
  share) and run scripts straight from it. Every script is self-contained, so it
  works even outside `C:\`.

If Windows blocks scripts on a fresh machine ("running scripts is disabled"), you
can allow them **for that one window** with:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

`-Scope Process` means "just this window" — it's the safe, temporary way and
resets when you close the window.

**Rule:** run anything that **changes** the system as **Administrator**;
read-only reports are fine as a normal user.

---

## 2. Set it up once — the Config folder

This is the most important idea in the kit, so it's worth a minute.

`C:\Sysadmin-Toolkit\Config\` holds **your environment's details in one place**.
You fill it in once, and from then on scripts read their settings from it — you
don't retype your domain, your shares, or your support phone number every time.
It's created on first install and is **never overwritten** by a later update, so
your settings survive every new version.

What's in it:

| File | What it holds |
|---|---|
| `toolkit-settings.json` | Everything fixed for an environment: company + helpdesk info, AD OUs and UPN suffix, Entra licences/groups, file server + shares, desktop/regional/power defaults, Teams webhook + SMTP, the Zabbix server URL, expected local admins, report folder, schedule times |
| `desktop-shortcuts.json` | The shortcuts every desktop should get |
| `Branding\wallpaper.jpg`, `lockscreen.jpg`, `logo.bmp` | Your company images |

**How a script decides what value to use** (this is the same everywhere, so learn
it once):

1. A value you **type on the command line** always wins.
2. If you didn't type one, the script reads it from `Config\toolkit-settings.json`.
3. If that's empty too, the script uses a sensible built-in default, asks you, or
   skips that bit.

And it's never a mystery — each script prints one grey line,
`[Config] using: …`, telling you exactly where each value came from.

**So: fill it in once per company.** After that, `Set-Branding` uses your
wallpaper and support info with no arguments, `New-DesktopShortcuts` creates your
shortcuts, `Get-LocalAdminAudit` checks against your list of allowed admins — on
1 PC or 500, without retyping. Managing more than one company? Keep a separate
Config per company (there's a per-company layout under `Config\Companies\<name>\`,
used by the fleet runner in §7).

**How to edit it.** It's a **JSON** file — plain text with a simple shape
(text in `"quotes"`, lists in `[brackets]`, no comma after the last item). Open it
in Notepad:

```powershell
notepad C:\Sysadmin-Toolkit\Config\toolkit-settings.json
```

…or change one value from PowerShell:

```powershell
$f='C:\Sysadmin-Toolkit\Config\toolkit-settings.json'
$j=Get-Content $f -Raw | ConvertFrom-Json
$j.Company.Name='Contoso'; $j.Company.SupportPhone='03 123 45 67'
($j|ConvertTo-Json -Depth 10) | Set-Content $f -Encoding UTF8
```

**One caution about secrets.** Anyone who can read the Config folder can read a
password or webhook you put in it. On a shared machine, keep those in **section
19 (Secrets)** instead — it encrypts them with Windows DPAPI — and leave those
fields empty in the Config file.

---

## 3. Run it — the menu

The menu is the friendly front door: it lists everything and explains each script
before you run it. Start it with `Start-SysadminToolkit.ps1`, or double-click
`Sysadmin-Toolkit.bat`, or use the desktop shortcut.

How to drive it:

- Pick a **section** by its number (or type part of its name).
- Pick a **script** by its number. Type the number **on its own** first and the
  menu shows you a **card**: what the script does, every switch and what it means,
  and examples — *then* it asks whether to run. So you never run something blind.
- At that "run?" prompt: press **Enter** to run with no arguments · type switches
  (e.g. `-All -WhatIf`) then Enter · press **B** to go back.
- **`H 3`** shows the full help for script 3 without running it.
- **Number + switches on one line** (e.g. `4 -Rollback`) runs it straight away.
- The card's last line tells you at a glance whether the script is read-only,
  whether it supports `-WhatIf`, and whether it has `-Rollback`.

The top of the menu also tells you whether it found your `Config\` folder.

*(One oddity: section 08, "TechToolkit", is a whole helpdesk app of its own with
22 departments. It loads as a set, so the menu points you to its own launcher
rather than listing its tools individually.)*

---

## 4. Run it — one script directly

Once you know which script you want, you can skip the menu and run it directly.
The safe form is: full path, don't load your profile, bypass the policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Sysadmin-Toolkit\17-Security-Audit\Get-LocalAdminAudit.ps1"
```

Add switches after it — for example `-WhatIf` (preview), `-Rollback` (undo), or
`-ComputerName PC01,PC02` (target remote machines). To see a script's switches,
look it up in the [reference](#12-section-by-section-reference) or ask PowerShell:

```powershell
Get-Help "C:\Sysadmin-Toolkit\17-Security-Audit\Get-LocalAdminAudit.ps1" -Detailed
```

A script copied out of the kit onto another machine still runs — each one carries
its own helper code inside. It just won't find a `Config\` folder over there, so
it falls back to defaults or whatever you pass on the command line.

---

## 5. Safety: preview, backup, rollback

The kit is designed so you can try things without fear. Five safety nets:

- **`-WhatIf` — look before you leap.** Every changing script takes it. It prints
  exactly what it *would* change and does nothing. Make this your reflex first
  click on anything new.
- **Automatic backup before a change.** Before writing anything, scripts export
  what they're about to touch — registry keys to `.reg` files, power schemes to
  `.pow`, regional settings to a JSON snapshot, GPOs to a folder — all under
  `Backups\`.
- **`-Rollback` — undo.** Re-imports the newest backup set and reverses the
  change.
- **A confirmation prompt on destructive actions.** Disabling an account or
  resetting a password stops to ask "Are you sure?" first.
- **`-Force` — for automation only.** That "Are you sure?" prompt is right for a
  person, but it would **hang** a scheduled task or a Zabbix/fleet run (nobody's
  there to answer). Adding **`-Force`** (or setting the environment variable
  `SYSADMIN_TOOLKIT_FORCE=1`) makes the script run straight through without
  prompting. Run by hand without `-Force`, it still asks. This is what lets the
  Zabbix buttons and the fleet runner work unattended.
- **Report, don't destroy.** The "risky" scripts default to *reporting*. Stale-DNS
  and offboarding scripts flag or **disable**; actually removing anything is
  always a separate, deliberate step. **Accounts are disabled, never deleted.**

---

## 6. Run it from Zabbix

You can run kit scripts straight from your Zabbix monitoring console — click a
computer, pick an action like "Local admin audit", and the answer comes back in
the browser. This turns monitoring into a place you can *act* from.

The short version:

- **Fast, read-only** scripts (audits, "who's local admin", "reboot pending") →
  make them **buttons that show the answer**.
- **Slow / changing** scripts (branding, baselines) → don't wait on them; launch
  them detached or push via GPO/Intune.

The one-time setup (allow the Zabbix agent to run commands, raise the timeouts),
how to create the buttons — including the automatic creator
`New-ZabbixToolkitScripts.ps1` and its `-Folder` mode that exposes a whole
section at once — and a full troubleshooting table are all in the dedicated,
step-by-step guide:

> **`10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md`** — read that for
> Zabbix. It's written at the same beginner level as this manual.

This was validated live on the lab (Zabbix 7.0 + Agent 2, on both a domain
controller and a Windows 11 machine).

---

## 7. Roll out to many PCs

Because you configured everything once (§2), the *same* script does the right
thing on every machine. Here are four ways to reach many machines, smallest to
biggest — pick the one that matches how many machines and how hands-on you want
to be:

1. **One PC at a time.** Install the kit there (it carries its Config) and run
   what you need. Fine for a handful.
2. **From a network share.** Put the kit on `\\fileserver\IT\Sysadmin-Toolkit`,
   and run `\\fileserver\IT\Sysadmin-Toolkit\Sysadmin-Toolkit.bat` from any PC —
   one shared Config for everyone. (Point `SYSADMIN_TOOLKIT_CONFIG` at a different
   Config folder if you need to.)
3. **Push it automatically.** Deploy via a **GPO** logon/startup script, via
   **Intune** (`09\Deploy-ScriptViaIntune.ps1` does exactly this), or a scheduled
   task. This is the real "every PC in the domain" answer.
4. **The fleet runner** — run one script across a whole company's machines from
   your desk, with one report. `Invoke-ToolkitFleet.ps1` (at the kit root) figures
   out which machines belong to a company (from your Zabbix host groups, via
   `21-Fleet\Get-ManagedFleet.ps1`, with AD/Intune as fallback), checks each is
   reachable, runs the script on all of them, and gives you one
   **done / offline / failed** summary. Example:

   ```powershell
   .\Invoke-ToolkitFleet.ps1 -Company Contoso -OS 'Windows 11*' -Script "20-Desktop-Experience\Set-Branding.ps1"
   ```

   Always add `-WhatIf` first to see the target list. It runs non-interactively
   (sets `SYSADMIN_TOOLKIT_FORCE=1` on each machine) so nothing hangs. Full
   setup — including the workgroup/remoting steps and troubleshooting — is in
   **`21-Fleet\Run-The-Fleet.md`**.

**One thing to know about "machine" vs "user" scripts:** machine-wide scripts
(branding, power settings, `-AllUsers` variants, all the reports) run remotely
just fine. Scripts that change **a logged-in user's own settings** (their theme,
their personal context menu, their regional format) have to run *in that user's
session* — so push those through a GPO/Intune **logon** script instead of the
fleet runner.

---

## 8. Scheduled tasks

To make the recurring reports run on their own, `Install-AllScheduledTasks.ps1`
registers a Windows **Scheduled Task** (running as SYSTEM) for each one — the
health check, AD health, password-expiry, cert-expiry — using the times from your
Config (`Schedules.*`). Run it with `-Remove` to undo them all. Individual
scripts have their own installers too, e.g. `07\Install-HealthCheckTask.ps1`.

---

## 9. Day-one routine

When you start somewhere new, the safe order is: **look before you touch.** Every
step below is read-only — you're building a picture, not changing anything.

1. Install the kit on your admin machine and fill in
   `Config\toolkit-settings.json` (§2).
2. **`18\Get-EnvironmentDiscovery.ps1`** — a read-only map of the whole
   environment: AD, domain controllers, FSMO roles, OUs, GPOs, DNS, servers,
   shares. Read it, and write down your questions.
3. **`12\Test-ADHealth.ps1`** — is Active Directory healthy? (replication,
   SYSVOL, FSMO roles).
4. **`17\Get-LocalAdminAudit.ps1`** — who has local admin rights, checked against
   your allowed list.
5. **`07\Get-CertExpiryReport.ps1`** and **`15\Get-StaleDNSRecords.ps1`** — quick
   wins that surface problems and make you look sharp early.
6. Then everything else as the work calls for it. **Don't change anything on day
   one** — get the lay of the land first.

The fuller version of this is in `Docs\First-Week-Plan.md`.

---

## 10. Where things go

Wherever a script is run from (USB, ISO, a share), its output always lands under
`C:\Sysadmin-Toolkit\`:

- `Reports\` — the HTML and CSV reports.
- `Backups\` — the `.reg` / `.pow` / JSON safety backups, and GPO backups.
- `Logs\` — one dated log line per action, so there's always a record.
- `Config\` — your settings (**never** overwritten by an update).

These folders are created automatically and are left alone by installs.

---

## 11. Troubleshooting

| You see… | It means | Do this |
| --- | --- | --- |
| `"…is not recognized"` / red text all over the menu | The files lost their UTF-8 "BOM" marker (only happens on very old builds). | Reinstall from the current exe/ISO. |
| `"This file is set to read-only"` when editing Config after an ISO install | Files copied off a CD keep a read-only flag. | The current installer clears it; on an older install run once: `attrib -R "C:\Sysadmin-Toolkit\*" /S /D`. |
| Scripts are blocked / "running scripts is disabled" | Windows execution policy. | `Set-ExecutionPolicy -Scope Process Bypass -Force`, or launch via `Sysadmin-Toolkit.bat` (it does this for its window). |
| `"Missing: -X (or Key in Config)"` | That value is required and you didn't supply it. | Pass it on the command line, or fill it into `Config\toolkit-settings.json`. |
| A changing script **hangs** when run from Zabbix or a scheduled task | It's stuck waiting at an "Are you sure?" prompt. | Add `-Force` (or `SYSADMIN_TOOLKIT_FORCE=1`), or run it by hand. |
| A section says `"module not installed"` | That AD/DNS/GPO module (RSAT) isn't on this machine. | Run from a domain controller or a machine with RSAT. The script says so and carries on with what it can. |

---

## 12. Section-by-section reference

Every script runs standalone. **WhatIf** = has a preview mode. **Needs** = the
rights or modules required. Reports, backups, and logs always land under
`C:\Sysadmin-Toolkit\`.

### 01 — Users (on-prem AD + local)
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `New-ADUserOnboard.ps1` | Create AD user: temp password, groups (copy from a colleague), title/dept/manager, home drive. | AD module, admin | yes |
| `Disable-ADUserOffboard.ps1` | Disable (never delete), randomise password, save then strip groups, move to Disabled OU, hide from GAL. | AD module, admin | yes |
| `New-BulkADUsers.ps1` | Many users from a CSV (`sample-newhires.csv`); results CSV with temp passwords. | AD module, admin | yes |
| `Get-ADPasswordExpiry.ps1` | Accounts with passwords expiring soon. Read-only. | AD module | — |
| `Manage-LocalUser.ps1` | Local (non-domain) account onboard/offboard. | admin | yes |

### 02 — Windows 11
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Set-Win11Baseline.ps1` | Per-user baseline: classic context menu, taskbar/Explorer defaults, web search & Spotlight off. `-Rollback`. | user | yes |
| `Disable-Win11AITelemetry.ps1` | Machine policy: Copilot/Recall off, telemetry minimum, ad ID off. `-Rollback`. | admin | yes |

### 03 — Windows 10
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Test-Win11Readiness.ps1` | TPM/Secure Boot/UEFI/CPU/RAM/disk + Win10 end-of-support countdown. Read-only. | — | — |
| `Set-Win10Baseline.ps1` | Per-user baseline: Explorer defaults, Cortana/Bing off, ad ID off. `-Rollback`. | user (+admin for machine bits) | yes |

### 04 — PC Provisioning
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Initialize-NewPC.ps1` | Rename, power plan, RDP, winget software set, time zone, update scan. | admin, winget | yes |
| `Join-Domain.ps1` | Domain join with optional rename + target OU, sanity checks. | admin | yes |
| `Setup-PrintersAndDrives.ps1` | Map drives + install printers from a manifest, idempotent. | user | yes |
| `Harden-Baseline.ps1` | Conservative security hardening for a standalone PC. `-Rollback`. | admin | yes |

### 05 — Network
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Get-NetworkDiagnostics.ps1` | Adapters, gateway, DNS, internet, public IP, named hosts → HTML. Read-only. | — | — |
| `Invoke-SubnetScan.ps1` | Sweep a subnet: live hosts, names, MACs, optional ports → CSV/HTML. Read-only. | — | — |

### 06 — Debloat & Privacy
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Remove-Bloatware.ps1` | Remove junk from a curated safe list. Dry-run by default; `-Execute` to act. | admin | dry-run |
| `Get-StartupItems.ps1` | Every startup entry; `-Disable` one reversibly. | admin for HKLM | yes |

### 07 — Reporting & Health
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Invoke-HealthCheck.ps1` | Scored health: disk, memory, services, reboot pending, uptime, updates, event errors, Defender → HTML + trend CSV + optional e-mail. | — | — |
| `Install-HealthCheckTask.ps1` | Daily Scheduled Task for the health check with e-mail. `-Remove`. | admin | yes |
| `Get-PCInventory.ps1` | Full per-PC inventory → HTML + CSV. | (BitLocker needs admin) | — |
| `Get-CertExpiryReport.ps1` | Cert stores (local/remote) for expiring certs → HTML. | — | — |
| `Get-SoftwareInventoryReport.ps1` | Fleet software rollup + EOL flags (`EOLSoftwareList.json`). | WinRM for remote | — |
| `Confirm-BitLockerEscrow.ps1` | Recovery keys escrowed to AD/Entra? Flags at-risk volumes. | AD and/or Graph | — |
| `Get-FirewallAuditReport.ps1` | Firewall profiles, inbound allow rules, listening ports; flags risky ports. | WinRM for remote | — |

### 08 — TechToolkit (bundled, 22 departments)
A portable first-line helpdesk menu app with 180+ tools. Launch `TechToolkit.bat`
(or `.ps1`), or one department with `Run-Department.ps1` / a `Launchers\*.bat`.
`TechToolkit.ps1 -QuickRun <cmd>` fires one tool; `-Help` lists them. The 22
department modules stay together as a set.

### 09 — Entra ID + Intune (Microsoft Graph)
| Script | Purpose | Needs (Graph role) | WhatIf |
|---|---|---|---|
| `New-EntraUserOnboard.ps1` | Cloud-native onboard, or `-ExistingUser` for post-sync licence/groups/manager. | User Administrator | yes |
| `Disable-EntraUserOffboard.ps1` | Block sign-in, revoke sessions, strip groups/licences, optional Intune retire. | User Administrator (+Intune) | yes |
| `Get-IntuneDeviceCompliance.ps1` | Fleet compliance, staleness, encryption → HTML + CSV. | Intune (read) | — |
| `Get-IntunePatchCompliance.ps1` | Build level vs your fleet's newest, per Windows version. | Intune (read) | — |
| `Get-LAPSComplianceReport.ps1` | Windows LAPS escrow present + fresh, per device. | `DeviceLocalCredential.Read.All` | — |
| `Get-EntraSecurityPosture.ps1` | Conditional Access states + standing privileged role holders. | `Policy.Read.All`, `RoleManagement.Read.Directory` | — |
| `Deploy-ScriptViaIntune.ps1` | Push any `.ps1` as an Intune device script to a group. | Intune Administrator | yes |
| `New-IntuneConfigProfile-Win11Baseline.ps1` | CSP-backed Win11 baseline as a policy. | Intune Administrator | yes |

### 10 — Monitoring: Zabbix + Grafana
| File | Purpose |
|---|---|
| `Install-ZabbixAgent.ps1` | Silent Zabbix Agent 2 install + config + UserParameter. `-WhatIf`. |
| `New-ZabbixToolkitScripts.ps1` | Create the "Toolkit: …" Zabbix buttons over the API (curated set, `-Folder` for a whole section, `-HostGroup`, `-Remove`). |
| `Zabbix-Run-Toolkit-Scripts.md` | The step-by-step guide to running kit scripts from Zabbix (see §6). |
| `UserParameters\Get-ToolkitZabbixMetrics.ps1` + `.conf` | Emits one JSON line (health, reboot, disk, Defender, uptime…) as `toolkit.metrics`. |
| `zbx_template_windows_sysadmintoolkit.xml` | Zabbix 6.0+ template (1 master + 11 items, 8 triggers). |
| `grafana_dashboard_sysadmintoolkit.json` | Grafana dashboard (grafana-zabbix plugin). |

### 11 — GPO / ADMX
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Deploy-GPOCentralStore.ps1` | Extract the ADMX MSI, back up the existing Central Store, deploy to SYSVOL. | Domain Admin | yes |
| `Backup-GPOs.ps1` | Back up every GPO + HTML report per GPO + "changed since last run". | GroupPolicy module | yes |

### 12 — AD Health
| Script | Purpose | Needs |
|---|---|---|
| `Test-ADHealth.ps1` | dcdiag + repadmin + FSMO + SYSVOL, scored → HTML. Read-only. | RSAT AD tools |

### 13 — Alerting
| Script | Purpose | Needs |
|---|---|---|
| `Send-ToolkitAlert.ps1` | Teams webhook and/or e-mail alert; prints if nothing configured. Call by path from any script. | webhook URL / SMTP (or Config) |

### 14 — Employee Lifecycle (hybrid AD + Entra/Intune)
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `New-EmployeeOnboard.ps1` | AD account → wait for Entra sync → licence/cloud groups. `-SkipAD` for cloud-only. Re-runnable. | AD and/or Graph | yes |
| `Disable-EmployeeOffboard.ps1` | Cloud cutoff first (block + revoke), then AD disable. Either half alone. | AD and/or Graph | yes |

### 15 — DNS / DHCP
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Get-DHCPScopeReport.ps1` | Scope utilisation %, warning/critical thresholds → HTML. Read-only. | DhcpServer module | — |
| `Get-StaleDNSRecords.ps1` | A records with no ping reply (+ AD cross-check). Report only; removal is a separate `-RecordsToRemove` step. | DnsServer module | yes (removal) |

### 16 — File Shares
| Script | Purpose | Needs |
|---|---|---|
| `Get-SharePermissionReport.ps1` | Share + NTFS permissions, orphaned SIDs flagged → HTML. Read-only. | read rights; WinRM remote |

### 17 — Security Audit
| Script | Purpose | Needs |
|---|---|---|
| `Get-LocalAdminAudit.ps1` | Local Administrators membership across machines, flagged against your allow list (`Security.ExpectedLocalAdmins`). | WinRM for remote |

### 18 — Environment Discovery
| Script | Purpose | Needs |
|---|---|---|
| `Get-EnvironmentDiscovery.ps1` | Day-1 map: AD, DCs, FSMO, OUs, GPOs, DHCP, DNS, servers, shares, (Intune with `-IncludeCloud`) → Markdown + HTML. Read-only. | RSAT (each section optional) |

### 19 — Secrets
| Script | Purpose | Needs |
|---|---|---|
| `Manage-ToolkitSecret.ps1` | DPAPI-encrypted `-Set/-Get/-List/-Remove` of webhook URLs, client secrets, SMTP passwords. | Windows |

### 20 — Desktop Experience
| Script | Purpose | Needs | WhatIf |
|---|---|---|---|
| `Set-DesktopExperience.ps1` | Theme, desktop icons, icon size, Explorer view, Quick Access pins, tips off. `-Rollback`. | user | yes |
| `New-DesktopShortcuts.ps1` | Shortcuts from `Config\desktop-shortcuts.json` (or `-ManifestPath`); per-user or Public desktop; `-Remove`. `-UseExample` runs the demo manifest. | user (admin for AllUsers) | yes |
| `Set-Branding.ps1` | Enforced wallpaper + lock screen (PersonalizationCSP, Pro-compatible), OEM support info. `-Rollback`. | admin | yes |
| `Set-StartTaskbarLayout.ps1` | Start/taskbar pins per OS rules; `-ExportCurrent`. `-Rollback`. | admin | yes |
| `Add-ContextMenuEntries.ps1` | "PowerShell here" (+Admin), Copy path, Open with Notepad, Take ownership (opt-in). `-Remove`. | user (admin for AllUsers) | yes |
| `Set-RegionalSettings.ps1` | Culture/format, keyboard, time zone, home location, date format; `-CopyToSystem` for new users + login screen. `-Rollback`. | user (admin for CopyToSystem) | yes |
| `Set-PowerAndLock.ps1` | Screen/sleep timers, idle lock, lid/power button, Fast Startup, hibernate; `-Workstation`/`-Laptop` presets. `-Rollback`. | admin | yes |

### 21 — Fleet
| Script | Purpose | Needs |
|---|---|---|
| `Get-ManagedFleet.ps1` | List a company's devices (Zabbix host group → devices; AD/Intune fallback). Read-only. | Zabbix API token, or RSAT AD |
| `..\Invoke-ToolkitFleet.ps1` (root) | Run one kit script across a company's devices; WinRM + Invoke-Command; one done/offline/failed report; `-WhatIf`. See `21-Fleet\Run-The-Fleet.md`. | WinRM to targets; kit installed on them |

---

## 13. Also in the kit

- **`Runbooks\`** — RB-01…RB-09 incident guides (user can't log in, slow PC,
  network down, disk full, printer, malware, joiner/leaver, service down, AD/GPO)
  plus a ticket-note template, each pointing at the kit script to run.
- **`Docs\First-Week-Plan.md`** — what to find out and ask when you start
  somewhere new. **`Docs\Command-Reference.md`** — every command grouped by task.
  **`Docs\Communication-Templates.md`** — NL/EN messages (maintenance, outage,
  resolved, password reset, welcome, phishing, ticket reply).
- **`Tests\Run-Tests.ps1`** — a Pester test suite: every script parses, is PS
  5.1-safe, risky scripts keep `-WhatIf` and never delete accounts, Config keys
  line up.
- **`Docs\NEXT.md`** — the honest gap list and what's next. **`Docs\ROADMAP.md`**
  / **`CHANGELOG.md`** / **`VERSION`** — history and current version.
  **`Docs\INVENTORY.md`** — the same script list as a quick flat reference.

---

*The kit has 21 sections and 91 scripts. Validated live on a Windows Server 2025
domain controller (`lab.local`), a workgroup Windows 11 machine, and a Zabbix 7.0
box. Made and tested in a private lab — no customer or employer data inside.*
