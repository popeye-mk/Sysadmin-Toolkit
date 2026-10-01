# Changelog

One line per addition, newest first. Dates are when the change landed in
the kit folder. Version in `VERSION`.

## 1.5.9 — 2026-09-23

- **Set-UpdatePolicy.ps1 -Mode Hold locks Settings > Windows Update** (policy *Remove access to use all Windows Update features*) — found in the field test: on a held PC anyone could still click *Install* in Settings. Approved updates are still installed through the update engine (OpsBoard / Install-ApprovedUpdates.ps1). Pilot and Default remove the lock, only when the toolkit set it.
- **Get-UpdateStatus.ps1** reports `settingsLocked`.
- **Set-UpdatePolicy.ps1** shows "Windows 11" on Windows 11 (the registry still says "Windows 10"; the build number decides).

## 1.5.8 — 2026-09-23

- **Install-ApprovedUpdates.ps1 always installs in the background** (SYSTEM task), also when run on the PC itself — found in the field test: on the OpsBoard server an update action runs locally with a time limit, and a long install must never be cut off half-way. `-NoTask` installs in the current window as before.

## 1.5.7 — 2026-09-23

- **New section 22-Windows-Update** — patch status and a *pilot ring + hold* routine, so a bad Microsoft update hits one test PC instead of every PC:
  - `Get-UpdateStatus.ps1` — updates waiting (security flagged, Defender signatures separate), last real patch date, hold state; saves `Reports\update-status.json` for the Zabbix metrics. Read-only.
  - `Set-UpdatePolicy.ps1 -Mode Hold|Pilot|Default` — *Hold*: Windows downloads but installs nothing on its own; *Pilot*: installs automatically; both keep the PC on its current Windows version, never restart with a user logged on, let Defender fetch its own signatures every 4 h, and schedule a daily status scan. *Default* removes only what the toolkit set. `-WhatIf` supported.
  - `Install-ApprovedUpdates.ps1` — installs exactly the approved update IDs (plus Defender signatures), hides declined ones, never restarts; runs as a SYSTEM task when called remotely (Windows refuses remote installs) and writes `Reports\update-install-last.json`.
- **Get-ToolkitZabbixMetrics.ps1** adds `updatesPending`, `updatesSecurity`, `updateScanAgeHours`, `lastPatchDays`, `updatePolicy` (read from the cache - no slow scan on every poll).

## 1.5.6 — 2026-09-23

- **Install-Toolkit.ps1 `-Prune`**: after copying, files that are in the install folder but no longer in this kit (left over from an older version) are **moved** to `Backups\Pruned-<date>\` — nothing is deleted, move a file back if you still need it. Config, Reports, Logs, Backups, secrets and the onboarding marker are never touched; `-WhatIf` shows what would move. The onboarding bootstrap and OpsBoard's *Update toolkit* use it, so every PC ends up with exactly the kit it was given.
- **Honest Config message on pushed updates**: a package without `Config\` (OpsBoard's *Update toolkit* never sends the server's settings) now says *"No Config\ in this package - kept this PC's own Config\ as it is"* instead of the first-install hint.

## 1.5.5 — 2026-09-22

- **Get-ToolkitZabbixMetrics.ps1 reports the installed kit version** (`toolkitVersion`, read from `VERSION` at the kit root). OpsBoard uses it to show which PCs run an outdated toolkit and to update them from the server. New field only — nothing that reads the JSON breaks, and `null` when `VERSION` can't be found.

## 1.5.4 — 2026-09-22

- **Remove-Bloatware.ps1 now tells the truth when it can't remove.** In a non-interactive session (OpsBoard, a scheduled task, remoting) the per-app "Remove?" confirmation can't be answered, so every app failed on its own while the script still printed "Debloat complete". It now stops once with a clear message unless the caller has confirmed (`-Force`, `-Confirm:$false` or `SYSADMIN_TOOLKIT_FORCE=1`), and ends with an honest count — *X removed, Y failed, Z skipped* — also appended to the record in `Backups\`. It also finds each app before removing it, so an app is only counted as *removed* when it was really there (already-gone apps count as *already gone*). When removing an app's provisioned template errors, it re-checks: Windows 11 usually removes the template together with the installed app, so that's reported as *already gone*, not *failed*. Interactive use by hand is unchanged.

## 1.5.3 — 2026-09-21

- **Section READMEs brought to learner level (every section now has one).** Sections 01–07 had no section README at all (only the root table) — created beginner READMEs with worked examples for **01 Users**, **04 PC-Provisioning**, **07 Reporting-Health** (high-use), plus **02 Windows 11**, **03 Windows 10**, **05 Network**, **06 Debloat-Privacy**. Rewrote **09 Entra-Intune** with the jargon in plain words (Graph, scopes/consent, usage location, licence SKU, CSP), a worked onboard example, and how to find a licence SKU id. **11 GPO-ADMX**: added where to download the ADMX package and a "how to confirm it worked" step (the GPMC central-store line). **21 Fleet**: now points to the step-by-step `Run-The-Fleet.md` and stresses `-WhatIf` first. No script/logic changes — documentation only.

## 1.5.2 — 2026-09-21

- **Docs rewritten for a learner (junior/IBO level), not a senior**: the guides now teach — plain-language intros to each concept, a glossary where jargon first appears, exact click paths and what each command flag does and why, what you should see after each step, and "you see *this* error → it means *this* → do *this*" troubleshooting tables.
  - `10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md` — full beginner rewrite (what a Zabbix button is and how server→agent→PowerShell connect; one-time agent + server setup; the automatic creator and `-Folder` mode; run-and-read; error table).
  - `Docs\MANUAL.md` — new "Start here" orientation (what it is, what you need, the four-move mental model, the safety promise), plain intros and explained jargon across the how-to sections, a mapped troubleshooting table. Section-by-section reference tables kept.
  - `Docs\First-Week-Plan.md` — cross-links to the manual and command reference.
- No script/logic changes from 1.5.1 — this is a documentation release.

## 1.5.1 — 2026-09-21

- **Fixes found in live testing** (v1.4.0/v1.5.0 features, proven on the lab — DC + a workgroup Windows 11 VM over WinRM + Zabbix 7.0.29):
  - **Zabbix button creator** — the pre-flight `apiinfo.version` call sent the API auth header, which Zabbix 7.0 rejects (`"apiinfo.version" method must be called without authorization header`). It now runs header-free, so `New-ZabbixToolkitScripts.ps1` connects and created/updated all 10 buttons over the API.
  - **Fleet runner** — the remote block didn't bypass the target's execution policy, so an unsigned kit script failed with "cannot be loaded" on a default Windows 11. It now runs `Set-ExecutionPolicy -Scope Process Bypass` in the remote session before invoking the script. Full fan-out proven: DC → Win 11 VM, Local Admin Audit, `1 done, 0 failed, 0 offline`.
- **Zabbix creator — `-Folder` mode**: `New-ZabbixToolkitScripts.ps1 -Folder "07-Reporting-Health"` scans a section and exposes every **read-only** script (`Get-`/`Test-`/`Find-`/`Measure-`/`Show-`/`Read-`/`Confirm-`) as a button in one pass; machine-changing scripts (`Set-`/`New-`/`Disable-`/`Remove-`/`Enable-`/`Invoke-`/…) are skipped so they can't become one-click buttons. Button names are humanised from the file name; descriptions come from each script's `.SYNOPSIS`.
- **Docs**: `10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md` now covers raising the **Zabbix server** `Timeout` as well as the agent — the real fix for `Execute failed: … context deadline exceeded`. New `21-Fleet\Run-The-Fleet.md` (the full fleet-runner procedure — domain and workgroup paths, kit-push over remoting, troubleshooting table with every live error) and `Docs\Command-Reference.md` (every command from onboarding to Zabbix to fleet, grouped by task).

## 1.5.0 — 2026-09-21

- **Fleet runner — item 3 / NEXT.md 0.1**: run one toolkit script across a whole company's devices from one place.
  - `21-Fleet\Get-ManagedFleet.ps1` — lists a company's devices from **Zabbix host groups** (one per customer) via the API, with **Active Directory** (OU per company) and Intune as fallbacks. Read-only; returns Name / IPv4 / OS / Online / Source.
  - `Invoke-ToolkitFleet.ps1` (root) — `-Company X -Script '17-Security-Audit\Get-LocalAdminAudit.ps1'`: resolves the targets, checks WinRM, runs the script on each with `Invoke-Command` (throttled), and prints one **done / offline / failed** report + CSV. `-WhatIf` lists the targets and stops. Runs non-interactively (sets `SYSADMIN_TOOLKIT_FORCE=1` on the remote) so nothing hangs on a prompt. Filters: `-OS`, `-OnlineOnly`, `-Exclude`; `-Computers` for an explicit list.
  - Per-company mapping in `Config\companies.json` (friendly name → Zabbix group / AD OU / Config folder) and per-company Config under `Config\Companies\<name>\`.
  - Menu and MANUAL updated; the runner is listed at the root. Machine-scope scripts run remotely; per-user ones still go via GPO/Intune (documented).

## 1.4.0 — 2026-09-20

- **`-Force` / non-interactive mode (item 1)**: scripts that change things stop to confirm ("Are you sure? [Y/N]") — right for a person, but it would hang a scheduled task or a Zabbix launch. Every changing script now takes **`-Force`** (and honours the `SYSADMIN_TOOLKIT_FORCE=1` environment variable): it sets `$ConfirmPreference='None'` and makes the inline `Confirm-Action` proceed, so the script runs unattended without prompts. Interactively, without `-Force`, they still ask. Added to 20 scripts; `Confirm-Action` updated in 16.
- **Zabbix button set (item 2)**: `10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1` creates the "Toolkit: …" Zabbix buttons in one pass over the Zabbix API, from `toolkit-zabbix-scripts.json` (10 fast read-only scripts). Idempotent, `-WhatIf`, `-HostGroup` (scope to a customer), `-Remove`. API token via `-ApiToken`, a `ZabbixApiToken` secret in 19-Secrets, or `-Credential`; URL from `-ZabbixUrl` or Config `Monitoring.ZabbixUrl`. The Zabbix guide adds the button-safe agent config (`AllowKey=system.run[powershell*C:\Sysadmin-Toolkit\*]` + `DenyKey=system.run[*]`) instead of opening `system.run` wide.

## 1.3.1 — 2026-09-20

- **Tidied the docs into one place**: `MANUAL.md`, `INVENTORY.md`, `ROADMAP.md` and `NEXT.md` moved into `Docs\` (with a `Docs\README.md` index); the root now holds only `README.md`, `CHANGELOG.md` and `VERSION`. README points at `Docs\MANUAL.md` as the handbook. Per-section READMEs and `Runbooks\` stay where they belong, next to what they document.
- LinkedIn overview PDF: added an "In gebruik — echte commando's en output" page (real command + output from the lab: local-admin audit, GPO backup, onboard→offboard).

## 1.3.0 — 2026-09-20

- **One manual**: new `MANUAL.md` at the root — a single handbook that folds together install, the one-time Config setup, using the menu, running a script directly, safety (WhatIf/backup/rollback), running the kit from Zabbix, rolling out to many PCs, scheduled tasks, the day-one routine, where files land, troubleshooting, and a section-by-section reference of every script. README and INVENTORY now point to it as the one place to start, instead of the how-to being spread across several files.

## 1.2.6 — 2026-09-20

- **Docs aligned with the live testing**: README gets a "Status — tested on a real domain" section (what was validated on the lab DC + the Zabbix run, pointing at the monitoring guide); `Docs/First-Week-Plan.md` now starts with the exe install and the one-time `Config\toolkit-settings.json` fill; the LinkedIn overview PDF gets a "what ran live" section.

## 1.2.5 — 2026-09-20

- **Fix (found live, cosmetic but visible)**: under `-WhatIf`, every log line was echoed as `What if: Performing the operation "Add Content" on target "…Toolkit_<date>.log"` — the file logger inherited the WhatIf preference. The log write now uses `-WhatIf:$false`, so logging always happens quietly and never appears in WhatIf output. Applied to `Write-Log` in `_Common` and all 23 inline copies. Confirmed live: `01-Users/New-ADUserOnboard.ps1 -WhatIf` validated on the lab (username/UPN/OU preview + correct duplicate-name detection).
- Live-confirmed this session on the lab DC (lab.local): 18 Environment Discovery, 07 Cert Expiry, 16 Share Permissions, 11 GPO Backup, 01 New-ADUserOnboard (-WhatIf), 20 Add-ContextMenuEntries (the .NET registry rewrite — the literal `*` path wrote cleanly). Plus Zabbix running a kit script on the host on demand (17 local-admin audit via a Zabbix global script).

## 1.2.4 — 2026-09-20

- **Docs**: `10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md` — step-by-step guide to running any toolkit script from a Zabbix button (agent `AllowKey`, global script creation, run on host), validated live on the lab (Zabbix 7.0 + Agent 2, "Toolkit test" returned host/SYSTEM/time). Covers the read-only-show vs change-launch split, command patterns (file, detached, with args/`-WhatIf`), how Config travels with each host, trigger-action remediation, and the production hardening that replaces `system.run[*]` with a `sysadmintoolkit.run[*]` UserParameter allow-list.

## 1.2.3 — 2026-09-20

- **Fix (found live, ISO/CD install)**: files copied from the ISO kept the Windows read-only attribute, so editing `Config\toolkit-settings.json` afterwards failed with "This file is set to read-only". `Install-Toolkit.ps1` now clears the read-only attribute across the installed tree (right after unblocking). Existing installs: run `attrib -R "C:\Sysadmin-Toolkit\*" /S /D` once, or reinstall.

## 1.2.2 — 2026-09-20

- **Fix (installer exe, found live)**: the two-click `Sysadmin-Toolkit-Setup.exe` failed on launch with "Install-Toolkit.ps1 is not recognized" — the embedded archive was zipped from *inside* the kit folder, so it unpacked without the top-level `Sysadmin-Toolkit\` folder the stub expects. Archive now built from the parent so the layout matches. The ISO and the direct kit copy were never affected. (No script changed; exe rebuilt.)

## 1.2.1 — 2026-09-20

- **Fix (1.2.0 regression)**: seven scripts still had `[Parameter(Mandatory)]` on values that can now come from Config (`Install-ZabbixAgent -InstallerPath/-ServerActiveIP`, `Join-Domain -Domain`, `New-ADUserOnboard -OU`, `Invoke-SubnetScan -Subnet`, `Deploy-GPOCentralStore -SourceMsi`, `Deploy-ScriptViaIntune`/`New-IntuneConfigProfile -GroupName`). PowerShell prompts for a mandatory parameter *before* the script runs, so Config was never consulted. Now optional, checked right after the Config lookup with a clear "Missing: -X (or Key in Config)" error. New test guards it.
- NEXT.md: item 0 added — multi-company fleet (0.1) and launching kit scripts from Zabbix (0.2), Stojan's top priority after the VM tests.

## 1.2.0 — 2026-09-20

- **Config folder — fill in your environment once.** New `Config\` at the kit root: `toolkit-settings.json` (company/helpdesk info, AD OUs and UPN suffix, Entra licences/groups, file server and shares, desktop/regional/power defaults, Teams webhook and SMTP, Zabbix server, expected local admins, report folder, schedule times), `desktop-shortcuts.json` (the real shortcuts), `Branding\` (wallpaper / lock screen / logo). 42 scripts read the values they need from it when you don't pass them: **explicit parameter wins → Config → the script's own default**. Each script prints one grey `[Config] using: …` line so nothing is silent. A script copied out of the kit finds no Config and runs exactly as before (the lookup is inline, no dependency). Config is found via `SYSADMIN_TOOLKIT_CONFIG`, `..\Config`, `.\Config`, or `C:\Sysadmin-Toolkit\Config`.
- `Install-Toolkit.ps1` creates `Config\` on first install and **never overwrites it** afterwards — your settings survive every update.
- `New-DesktopShortcuts.ps1` no longer puts example shortcuts on a desktop by accident: it uses `Config\desktop-shortcuts.json`, or `-ManifestPath`, or stops with a hint. `-UseExample` runs the renamed `shortcuts-EXAMPLE.json` on purpose.
- Menu shows whether a Config folder was found.
- Tests: Config JSON validity, every Config key a script asks for exists in the template, and every lookup is guarded so explicit parameters win.

## 1.1.4 — 2026-09-20

- **Menu shows what a script does before running it.** Typing a number alone now prints a card built from the script's own help — one-line summary, description, every switch with its meaning, the examples — and then asks: Enter = run as is, or type switches (e.g. `-All -WhatIf`), or B = back. `H 3` shows the full help for script 3 without running it. Number + switches on one line still runs directly, as before. The tip line says whether the script is read-only, supports `-WhatIf`, and has `-Rollback`.
- Help blocks: combined `.PARAMETER A / B` entries (12 scripts) split into one entry per switch so every switch shows a description on the card; missing descriptions added (`Set-PowerAndLock` Fast Startup/hibernate switches, `Set-DesktopExperience -IncludeControlPanel`).

## 1.1.3 — 2026-09-20

- **Fix (found live)**: `-Rollback` aborted after the first key with "The operation completed successfully" reported as an error. Cause: `reg.exe import` prints its success message to *stderr*, and Windows PowerShell 5.1 promotes captured native stderr (`2>&1`) inside a try/catch (which the menu uses) to a terminating error. Every `reg.exe import`/`export` in the kit (26 files, incl. three TechToolkit scripts) now goes through `Start-Process`, which never touches the error stream. New test in `Tests\Toolkit.Tests.ps1` guards the pattern.
- Confirmed live: `Set-DesktopExperience.ps1 -All -WhatIf` and `-All` (theme + desktop icons applied on Server 2025).
- **Fix**: `Add-ContextMenuEntries` failed with "unable to find the specified registry key" — the path `Software\Classes\*\shell` contains a literal `*` which PowerShell's registry provider treats as a wildcard. Script now writes through the .NET `[Microsoft.Win32.Registry]` API; registry `Test-Path` calls across the kit switched to `-LiteralPath` (22 files).

## 1.1.2 — 2026-09-20 (after the first live run on a Server 2025 DC)

- `Get-LocalAdminAudit.ps1`: machine count was wrong when only one machine was checked (`Group-Object` single-group `.Count` quirk); `Enterprise Admins` added to the default expected list (normal on a DC).
- `Set-DesktopExperience.ps1`: run with no switches (e.g. from the menu) it now offers to apply the default set interactively instead of just warning.
- `Get-EnvironmentDiscovery.ps1`: tables had the `---` separator glued onto the header row (PowerShell comma-vs-plus precedence in the table builder) — both the `.md` and `.html` are proper tables now.
- Confirmed working live on a Server 2025 DC: `Sysadmin-Toolkit-Setup.exe`, the menu, `Test-ADHealth.ps1` (Healthy on lab.local), `Get-LocalAdminAudit.ps1`, `Get-StaleDNSRecords.ps1`, `Get-EnvironmentDiscovery.ps1`.

## 1.1.1 — 2026-09-20

- **Fix (found on the first real Windows test)**: every `.ps1`/`.psm1` was saved as UTF-8 *without* BOM. Windows PowerShell 5.1 reads such files as ANSI (Windows-1252), turning em-dashes in messages into `â€”` — and that last character is a curly quote PowerShell treats as a string delimiter, so scripts failed to parse ("missing string terminator"). PowerShell 7 never showed it. All 90 files now carry a UTF-8 BOM; `Tests\Toolkit.Tests.ps1` has a new test that fails if a file ever loses it.
- **`Sysadmin-Toolkit-Setup.exe`** (ISO root / next to the kit): two-click install — double-click, Yes to UAC; unpacks, runs `Install-Toolkit.ps1`, opens the menu. Unsigned, so a *downloaded* copy may show SmartScreen's "More info → Run anyway"; from the ISO/USB it doesn't.
- `Install-Toolkit.ps1`: running it from inside the install folder no longer floods the screen with "cannot overwrite with itself" — it detects source = destination and only unblocks + refreshes the shortcut.

## 1.1 — 2026-09-19 (evening)

- **20-Desktop-Experience** (7 scripts): `Set-DesktopExperience`, `New-DesktopShortcuts` (+ `shortcuts-sample.json`), `Set-Branding`, `Set-StartTaskbarLayout`, `Add-ContextMenuEntries`, `Set-RegionalSettings`, `Set-PowerAndLock`. All standalone, backup + `-Rollback` + `-WhatIf`.
- **Fix (real bug, present since day 1)**: `Backup-RegistryKey` named files `<Label>_<stamp>.reg`, so several keys backed up under one label in the same second overwrote each other and `-Rollback` restored only the last key. Now `<Label>_<key>_<stamp>.reg`, and the rollback in `Set-Win11Baseline`, `Disable-Win11AITelemetry` and `Set-Win10Baseline` re-imports the whole set. Patched in `_Common` and every inline fallback copy (17 files). Backups made before this fix contain only one key per run — re-run the baseline once to get a complete backup set.
- Launcher: section 08's 22 departments are no longer listed as runnable (they're loaded by `TechToolkit.ps1` / `Run-Department.ps1` and stay together).
- `VERSION` file added.

## 1.0 — 2026-09-19

- **God file + distribution**: `Start-SysadminToolkit.ps1` menu over every section, `Sysadmin-Toolkit.bat` double-click launcher, `Install-Toolkit.ps1` (ISO/USB → `C:\Sysadmin-Toolkit`, desktop shortcut). Kit packaged as a data ISO for VM testing.
- **18-Environment-Discovery**: `Get-EnvironmentDiscovery.ps1` — day-1 map of AD, GPO, DHCP, DNS, servers, shares, Intune → Markdown + HTML.
- **19-Secrets**: `Manage-ToolkitSecret.ps1` — DPAPI-encrypted secret store.
- **Runbooks\**: RB-01…RB-09 incident guides + ticket-note template.
- **Docs\**: `First-Week-Plan.md`, `Communication-Templates.md` (NL/EN).
- **Tests\**: Pester suite (`Run-Tests.ps1`) — parse, PS5.1 compat, safety contracts, standalone-safety.
- **INVENTORY.md**, **CHANGELOG.md** added.
- **09-Entra-Intune**: the five original scripts converted to the standalone-safe fallback pattern (no longer hard-require `_GraphCommon.psm1`).
- **Tier 3 built**: `17-Security-Audit\Get-LocalAdminAudit.ps1`, `09\Get-LAPSComplianceReport.ps1`, `09\Get-EntraSecurityPosture.ps1`, `07\Confirm-BitLockerEscrow.ps1`, `07\Get-FirewallAuditReport.ps1`.
- **Tier 2 built**: `15-DNS-DHCP` (DHCP scope report, stale DNS report), `16-FileShares\Get-SharePermissionReport.ps1`, `09\Get-IntunePatchCompliance.ps1`, `07\Get-SoftwareInventoryReport.ps1` + `EOLSoftwareList.json`. Fixed a local-vs-remote detection edge case in the share report.
- **Tier 1 built**: `12-AD-Health\Test-ADHealth.ps1`, `11\Backup-GPOs.ps1`, `07\Get-CertExpiryReport.ps1`, `13-Alerting\Send-ToolkitAlert.ps1`, `14-Employee-Lifecycle` (hybrid onboard/offboard), `Install-AllScheduledTasks.ps1`.
- **11-GPO-ADMX**: `Deploy-GPOCentralStore.ps1` for the downloaded Windows Server 2025 ADMX package.
- **ROADMAP.md** added.

## 2026-09-18

- **09-Entra-Intune** and **10-Monitoring-Zabbix** sections added (Graph onboarding/offboarding, Intune compliance, script + config-profile deployment; Zabbix agent, template, Grafana dashboard).
- **08-TechToolkit**: TechToolkit 5.1 + additions merged in; `Run-Department.ps1` and per-department `Launchers\*.bat` added.
- Sections **01–07** built; `_Common` module; standalone-safe fallback added to every section script; `Write-Log` positional-parameter bug fixed; non-admin folder-creation errors silenced.
- Duplicate/loose material at the folder root folded into the kit and removed.
