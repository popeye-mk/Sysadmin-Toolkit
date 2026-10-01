# Sysadmin-Toolkit — Roadmap to "God Tier"

Honest gap list: what's already covered, what genuinely moves this from "a
solid toolkit" to "the one file that runs the whole environment." Nothing
here is required — the 11 sections you have today already cover onboarding,
baselines, provisioning, network, debloat, health, TechToolkit's 22
departments, Entra/Intune, Zabbix/Grafana, and GPO Central Store. This is
the list for when you want to keep building.

Each item says what it does, why it's worth having, and where it fits —
either a new numbered section or an addition to one that exists. Build in
whatever order actually matches what your day-to-day throws at you; the
tiers below are a suggestion, not a rule.

---

## The single highest-value next build ✅ built

**`Start-SysadminToolkit.ps1`** — a master menu at the kit root that lists
every section and launches whatever you pick (plus `Sysadmin-Toolkit.bat`
to double-click it, and `Install-Toolkit.ps1` to install from ISO/USB).
Optional: nothing in the kit needs it, every piece still runs alone.

## Beyond the tiers ✅ built

- `18-Environment-Discovery` — the day-1 environment map.
- `Runbooks\` — RB-01…RB-09 incident guides.
- `Docs\First-Week-Plan.md`, `Docs\Communication-Templates.md` (NL/EN).
- `INVENTORY.md` — flat list of everything.
- The five original `09-Entra-Intune` scripts converted to the same
  standalone-safe pattern as everything else.

```
Sysadmin-Toolkit\Start-SysadminToolkit.ps1
  1) Users (AD + local)          7) Reporting & Health
  2) Windows 11 baseline         8) TechToolkit (22 departments)
  3) Windows 10 baseline         9) Entra ID + Intune
  4) PC Provisioning            10) Monitoring (Zabbix/Grafana)
  5) Network                    11) GPO ADMX Central Store
  6) Debloat & Privacy
```

---

## Tier 1 — reach for weekly ✅ built

Every item below is built, and deliberately **independent of each other** —
same rule as the rest of the kit, just applied one level up: no Tier-1 script
imports or calls another one. `New-EmployeeOnboard.ps1` doesn't call
`01-Users` or `09-Entra-Intune`'s scripts, `Backup-GPOs.ps1` doesn't need
`Deploy-GPOCentralStore.ps1`, `Install-AllScheduledTasks.ps1` only checks
whether a target script's *file* exists (never imports it), and
`Send-ToolkitAlert.ps1` is called by path when wanted, never required by
anything. Copy any one file out on its own and it still runs.

| Item | What it does | Fits in |
| --- | --- | --- |
| **AD health check** | Wraps `dcdiag` + `repadmin /replsummary` into one readable report — replication failures, SYSVOL health, FSMO role holders. The thing you run first when "something feels off" with AD. | `12-AD-Health\Test-ADHealth.ps1` |
| **GPO backup + report** | `Backup-GPO` of every GPO to a dated folder, plus an HTML report of every GPO's settings. Also flags which GPOs changed version since the last run — lightweight change tracking without diffing full backups by hand. | `11-GPO-ADMX\Backup-GPOs.ps1` |
| **Certificate expiry watch** | Scans local (or remote, via `-ComputerName`) cert stores for anything expiring soon — RDP listener, IIS, LDAPS certs. HTML report. | `07-Reporting-Health\Get-CertExpiryReport.ps1` |
| **Central alert helper** | `Send-ToolkitAlert.ps1` — Teams webhook and/or e-mail, callable standalone or by path from anywhere. Nothing in the kit calls it automatically yet (would create a dependency); wiring it into other scripts is a future, opt-in step. | `13-Alerting\Send-ToolkitAlert.ps1` |
| **Onboarding/offboarding orchestrator** | One command each for the full hybrid AD+Entra/Intune joiner or leaver flow. Does its own AD and Graph work inline rather than calling `01`/`09` scripts — genuinely standalone, not just organized to look that way. Offboard hits cloud access first (fastest real cutoff), AD second. | `14-Employee-Lifecycle\` |
| **Scheduled-task installer for the whole kit** | Registers a Scheduled Task per recurring report script it finds present — skips (warns, doesn't fail) whatever isn't deployed yet. Checks file *existence* only, never imports anything. | `Install-AllScheduledTasks.ps1` at kit root |

## Tier 2 — infrastructure depth ✅ built

Same independence rule as Tier 1: nothing below imports or calls anything
else in the kit. `Get-DHCPScopeReport.ps1` and `Get-StaleDNSRecords.ps1`
don't need each other; the patch-compliance and software-inventory scripts
connect to Graph / scan the registry themselves rather than reusing another
script's logic by reference.

| Item | What it does | Fits in |
| --- | --- | --- |
| **DHCP scope report** | Utilization % per scope, warns before a scope runs out of leases — the classic "why can't anyone get an IP" root cause, caught before it happens. | `15-DNS-DHCP\Get-DHCPScopeReport.ps1` |
| **Stale DNS record cleanup** | Finds A records that don't answer a ping (cross-checked against AD when available) and reports them for review. **Never deletes automatically** — removal is a separate, explicit, opt-in step (`-RecordsToRemove`). | `15-DNS-DHCP\Get-StaleDNSRecords.ps1` |
| **Share/NTFS permission audit** | Who has access to what on your file shares, plus orphaned SIDs (permissions for deleted accounts nobody cleaned up). | `16-FileShares\Get-SharePermissionReport.ps1` |
| **Patch compliance report** | Fleet-wide Windows build/patch level via Intune — flags devices behind the newest build already seen elsewhere in your own fleet. Honest about scope: relative to your fleet, not an absolute check against Microsoft's release schedule (see the script's `.NOTES` for why). | `09-Entra-Intune\Get-IntunePatchCompliance.ps1` |
| **Software/license inventory** | Fleet-wide installed-software rollup (title/version/publisher/machine count), flags anything matching a small, manually-maintained EOL reference list next to the script. | `07-Reporting-Health\Get-SoftwareInventoryReport.ps1` |

## Tier 3 — security & compliance ✅ built

Same independence rule as Tiers 1–2. The two newer, less-documented Graph
APIs used here (Windows LAPS escrow, Entra BitLocker recovery keys) get
extra honest handling: each script tries `/v1.0` then falls back to `/beta`,
says plainly which one worked, and fails loud rather than silently showing
an empty "all clear" if both fail — same discipline this kit already
applied to the Zabbix agent URL and the Recall CSP naming uncertainty.

| Item | What it does | Fits in |
| --- | --- | --- |
| **Local admin audit** | Who's actually in the local Administrators group across every machine — almost always turns up at least one surprise. Flags anything not on your own expected/allow list. | `17-Security-Audit\Get-LocalAdminAudit.ps1` |
| **LAPS check/deploy** | Confirms Windows LAPS is actually escrowing + rotating local admin passwords fleet-wide — flags devices with no escrow record or a stale one, not just "policy assigned." | `09-Entra-Intune\Get-LAPSComplianceReport.ps1` |
| **BitLocker key-escrow check** | Confirms recovery keys are actually escrowed — to AD, to Entra, or both — per encrypted volume. Runs with just AD, just Entra, or neither available. | `07-Reporting-Health\Confirm-BitLockerEscrow.ps1` |
| **Conditional Access + privileged role report** | CA policy states (flags disabled/report-only) + current standing holders of 8 high-privilege Entra roles. Explicit about not covering PIM eligible/time-bound assignments — see the script's `.NOTES`. | `09-Entra-Intune\Get-EntraSecurityPosture.ps1` |
| **Firewall/open-port audit** | Firewall profile status + enabled inbound allow rules + what's actually listening, per machine. Flags RDP/SMB/WinRM/Telnet by default, configurable. | `07-Reporting-Health\Get-FirewallAuditReport.ps1` |

## Tier 4 — polish that makes it feel finished ✅ built

| Item | What it does | Fits in |
| --- | --- | --- |
| **CHANGELOG.md** | One line per addition, dated. | `CHANGELOG.md` |
| **Pester tests** | Every script parses and is PS5.1-safe; risky scripts must support `-WhatIf` and never delete accounts; no script hard-requires a module by relative path. Runs anywhere, no AD/Graph needed. | `Tests\Run-Tests.ps1` |
| **Encrypted secret store helper** | DPAPI-backed `-Set/-Get/-List/-Remove`, user+machine bound, no infrastructure. Standalone (not in `_Common`, so it's copy-out-able like everything else). | `19-Secrets\Manage-ToolkitSecret.ps1` |

## Added after the tiers ✅ built

- `20-Desktop-Experience` — theme/icons/shortcuts/branding/pins/context menu/regional/power-lock, seven standalone scripts.
- Kit-wide fix of the registry-backup filename collision (see CHANGELOG 1.1).

## What's genuinely left

Nothing on the original list. From here it's your environment that decides:
run `18-Environment-Discovery`, work through `Docs\First-Week-Plan.md`, and
whatever turns up red or missing becomes the next item. Ideas that only
make sense once you know the place: an Intune Win32 packaging helper for
the Zabbix agent, Settings Catalog (not classic) profile export, WSUS
reporting if WSUS exists, a print-server queue monitor if printing is a
daily pain, and wiring `13-Alerting` into the scheduled reports once
there's a Teams channel to send to.

---

## Scope note

This is deliberately long — you said extra is no problem, so it's here to
pick from rather than something to power through top to bottom. Tier 1 is
where the real day-to-day payoff is; Tiers 2–4 are depth you'll want
progressively as you take on more of the environment. Say which one you
want built next and I'll build it the same way as everything else here:
standalone-safe, `-WhatIf` where it changes anything, backed up before it
touches the system, and indexed in the master README.
