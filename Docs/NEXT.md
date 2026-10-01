# Sysadmin-Toolkit — What's Next

`ROADMAP.md` is the history: what was planned and built. This file is the
other direction — where the kit is still thin, what could be better in what
already exists, and which new areas are worth covering. Written honestly,
so some of it is criticism of the kit itself. That's the point.

Three lists: **improve what's there**, **cover what's missing**, **raise the
quality bar**. Then a suggested order. Nothing here is urgent before the
first real test on the server — that test will reorder this list.

---

## 0. Top of the list (added 2026-09-20, from the first look at how the IBO employer works)

### 0.1 Multi-company fleet — BUILT in 1.5.0 (pick a company, pick a script, run it on that company's devices)

**Why first:** the employer manages several companies. Their monitoring
already knows every managed device *and which company it belongs to*
(Zabbix host groups, one per customer). That inventory is the natural source
of truth — the kit should not keep its own list of machines.

**Status: done in 1.5.0** — `21-Fleet\Get-ManagedFleet.ps1` (Zabbix host groups + AD/Intune fallback) and root `Invoke-ToolkitFleet.ps1` (resolve targets, WinRM check, Invoke-Command with SYSADMIN_TOOLKIT_FORCE, one report, -WhatIf lists targets). Per-company map in `Config\companies.json`, per-company Config under `Config\Companies\`. Still to do: live test against the lab Zabbix; Intune device source (currently points at 09); ship the scripts to hosts that do not have the kit installed.

**What was built**

1. `Get-ManagedFleet.ps1` (new section `21-Fleet`): read companies and devices
   from the Zabbix API (`hostgroup.get` + `host.get`, with interfaces, OS
   inventory field, last-seen). Fallbacks when Zabbix isn't reachable: AD
   (one domain per company, or an OU per company) and Intune (one tenant per
   company via `09`). Output: a table *company → device → OS → online → source*,
   cached to `Reports\Fleet_<stamp>.json`.
2. `Invoke-ToolkitFleet.ps1` (root): `-Company "Contoso" -Script 20\Set-Branding.ps1
   -ScriptArgs @{…}`. Resolves the company's devices from step 1, filters
   (`-OS 'Windows 11*'`, `-Online`, `-Exclude`), checks WinRM, then copies the
   script **plus that company's Config** to each device and runs it with
   `Invoke-Command` (throttled), collecting one report: done / offline / failed
   and why. `-WhatIf` = show the target list and stop.
3. **Per-company Config**: `Config\Companies\<Name>	oolkit-settings.json` +
   `Branding\` + `desktop-shortcuts.json`, same format as the root Config; the
   root Config becomes the defaults. Scripts don't change — the fleet runner
   just ships the right Config folder next to the script, and the existing
   lookup (`..\Config`) finds it.
4. **Scope flag** in every script's help (`Scope: machine` / `Scope: user`):
   machine-scope scripts (branding, power/lock, `-AllUsers` variants, all
   reports, agent installs) run remotely as-is; user-scope ones (theme,
   HKCU context menu, per-user regional) are refused by the runner with the
   hint to deploy via GPO/Intune (`11` / `09`) — no pretending.
5. Menu integration: in a section, `F 3 -Company Contoso` runs script 3 on
   that company's fleet; the help card shows the scope flag.

**Credentials:** Zabbix API token and per-company admin credentials in
`19-Secrets` (DPAPI), never in Config. **Safety:** default `-WhatIf` listing
first; no script runs on more than N devices without `-Confirm:$false`.

### 0.2 Start it FROM the monitoring — the boss picks the device in Zabbix, not in our menu

The requirement as stated: whoever manages the customers wants to choose
**in Zabbix** which company / which device gets which script, and press go
there. So the kit must be callable from Zabbix, not only read from it.

**How Zabbix can launch our scripts**

1. **Global scripts** (Administration → Scripts, execute on *Zabbix agent*):
   one entry per toolkit script, e.g. "Toolkit: Brand this PC" =
   `powershell.exe -ExecutionPolicy Bypass -File C:\Sysadmin-Toolkit\20-Desktop-Experience\Set-Branding.ps1`.
   Shows up in the host's context menu in the Zabbix web UI → pick host,
   click, runs on that device as the agent account (SYSTEM). Scope
   restriction (host group) and user-group permissions are Zabbix features,
   so "this script only for customer X" is a checkbox, not code.
2. **Mass run:** Zabbix global scripts run per host; for "all Win11 of
   customer X" use `Invoke-ToolkitFleet` (0.1) with the host group as
   target — or a Zabbix script that calls the fleet runner on the admin
   server with `{HOST.GROUP}` / `{HOST.NAME}` macros.
3. **Automatic remediation** (Actions → remote commands): trigger fires
   (disk full, service down, stale patch) → Zabbix runs the matching kit
   script on that host and the alert carries the result.

**What the kit needs for this**

- The kit installed on every managed device (fleet runner or the exe via
  Intune/GPO) with the agent's `AllowKey=system.run[*]` — or better, one
  **UserParameter per toolkit action** in `10-Monitoring-Zabbix\UserParameters`
  so `system.run` stays closed: `sysadmintoolkit.run[Set-Branding]`,
  `sysadmintoolkit.run[Invoke-HealthCheck]`, with an allow-list of script
  names inside the kit.
- A **Zabbix script-definition export** shipped in section 10
  (`zbx_global_scripts_sysadmintoolkit.json`, importable), one entry per
  machine-scope script, with a description the boss can read in the UI.
- Scripts must run **non-interactive** when launched by the agent: no
  Read-Host, no "apply default set? [y/N]" prompt (Set-DesktopExperience has
  one — needs a `-NonInteractive` / detect `[Environment]::UserInteractive`
  path), exit code ≠ 0 on failure so Zabbix shows red, output short enough
  for the Zabbix result window.
- Per-company Config on the device (0.1 §3) so the same Zabbix button does
  the right branding on every customer.

**Open questions to settle at the employer:** does each customer have its own
AD/tenant or one shared? Is WinRM open from the admin workstation to customer
LANs (VPN/jump host)? Which Zabbix host-group naming convention do they use?

---

## 1. Improve what's already there

Known rough edges, found by reading the kit critically. Each is small; none
is dangerous. Ordered by how much they'd matter day to day.

| # | Where | What's wrong / weak | Fix |
| --- | --- | --- | --- |
| 1.1 | Whole kit | **Never run on a real Windows machine yet.** Parse/compat checks are done; behaviour isn't. | Mount the ISO on the test server, run each read-only report, then each `-WhatIf`, then one real change + `-Rollback` per section. Log what breaks in `CHANGELOG.md`. |
| 1.2 | `04\Harden-Baseline.ps1`, `07\Get-PCInventory.ps1` | Still default to `C:\TechToolkit\...` (TechToolkit heritage) while everything else uses `C:\Sysadmin-Toolkit\...`. Reports end up in two places. | Change the defaults to the toolkit root; keep the parameter so old habits still work. |
| 1.3 | 29 newer scripts | Their inline `Write-Log` prints to the console only — no line in `Logs\Toolkit_<date>.log`, unlike sections 01–07. Scheduled runs leave no trace. | Add the one-line `Add-Content` to the inline helper (same as the 01–07 fallback), or a shared snippet you paste. |
| 1.4 | `13-Alerting` | Nothing calls it yet. The health check, AD health, cert expiry and patch reports each have their own e-mail plumbing or none. | Add `-TeamsWebhookUrl` / `-AlertOnFail` to the scheduled reports that call `Send-ToolkitAlert.ps1` by path (still optional, still standalone). |
| 1.5 | ~~4 scripts~~ | **Done in 1.2.0** — `Config\toolkit-settings.json`, read by 42 scripts, parameters override, absence is fine. | Remaining: move secret values to `19-Secrets` automatically when present. |
| 1.6 | `09\Get-LAPSComplianceReport.ps1`, `07\Confirm-BitLockerEscrow.ps1` | Use newer Graph endpoints (`deviceLocalCredentials`, `bitlocker/recoveryKeys`) that I couldn't test against a tenant; they try v1.0 then beta and fail loud. | Verify once against the real tenant; pin the working version; remove the fallback if v1.0 is confirmed. |
| 1.7 | `09\New-IntuneConfigProfile-Win11Baseline.ps1` | Covers 3 CSP settings; Recall left out on purpose (CSP name churn). | Check the current CSP name for Recall/`DisableAIDataAnalysis` on the tenant's Windows build and add it if stable. Consider a Settings Catalog version. |
| 1.8 | `18-Environment-Discovery` | Lists classic Intune configuration profiles only; Settings Catalog profiles (the modern kind) need `deviceManagement/configurationPolicies`. | Add that call (beta today) with the same honest fallback. |
| 1.9 | `Tests\` | Pester suite is static (parse, syntax, contracts). It proves nothing about behaviour. | Add behaviour tests with mocks for the riskiest paths: offboard order (cloud block before AD), onboard re-run detection, DNS `-RecordsToRemove` gate, backup-set rollback selecting all files of one stamp. |
| 1.10 | HTML reports | Two visual styles (sections 01–07 vs the later ones), no dark mode, no print stylesheet. | One shared CSS block pasted into each (keeps standalone), or a tiny `Reports\style.css` that reports link to *if present*. |
| 1.11 | `Set-StartTaskbarLayout.ps1` (Win10 branch) | If you set both `-StartPins -ApplyToExistingUsers` and `-TaskbarPins`, the last `StartLayoutFile` written wins (the script warns). | Merge both into one XML when both are given. |
| 1.12 | `08-TechToolkit` | Bundled as-is (5.1). Its own reports/backups go to `C:\TechToolkit`. Its departments share nothing with the rest of the kit. | Leave it — it's a working, published tool. Optionally add a tiny bridge: a department entry that launches `Start-SysadminToolkit.ps1`. |
| 1.13 | `Docs\Communication-Templates.md` | Dutch/English only. | Add French versions if the company has a Wallonia/Brussels site. |
| 1.14 | `Install-AllScheduledTasks.ps1` | Times now come from Config; the e-mail/webhook values are read by the tasks' own scripts at run time. | Nothing left here. |

---

## 2. Cover what's missing

Grouped by how likely a one-person IT / IBO sysadmin actually meets it.
"Depends on" says what has to exist in the environment for the item to
make sense — run `18-Environment-Discovery` first and cross out what
doesn't apply.

### Very likely (build after the server test)

| Area | What | Depends on |
| --- | --- | --- |
| **Fleet runner** | `Invoke-ToolkitFleet.ps1`: run any kit script on N machines via `Invoke-Command`, collect the reports centrally, one summary. The missing glue between "per-PC script" and "the whole floor". | WinRM enabled (GPO) |
| **Backup verification** | Read the backup product's job status (Windows Server Backup `wbadmin get status`, Veeam PowerShell, or a log folder) and alert on failed/old jobs. The single most important "am I safe" report there is. | Whatever backup product exists |
| **Windows Update for Business / WSUS report** | Update-ring assignment and pending/failed update counts per device (Graph `windowsUpdateForBusiness` reports), or WSUS computer status if WSUS exists. Complements the relative patch-level check in 09. | Intune update rings or WSUS |
| **MFA registration report** | Who has MFA registered, which methods, who doesn't (Graph `reports/authenticationMethods/userRegistrationDetails`). Pairs with `Get-EntraSecurityPosture`. | Entra P1 for some fields |
| **Mailbox/M365 reports** | Mailbox sizes, shared mailboxes without owners, forwarding rules (a phishing indicator), licence usage vs assigned. Via Exchange Online PowerShell + Graph. | Exchange Online module |
| **Printer server tooling** | Queue health, stuck jobs, driver inventory, per-printer page counts (SNMP). Printing is a top-3 ticket source. | A print server / SNMP on printers |
| **Autopilot / device enrolment** | Hardware-hash export (`Get-WindowsAutopilotInfo`), Autopilot profile assignment, enrolment status. | Autopilot in use |

### Likely, depending on the environment

| Area | What | Depends on |
| --- | --- | --- |
| **Hyper-V / VM health** | VM state, checkpoints older than N days (silent disk-eaters), replication health, host resource usage. | Hyper-V hosts |
| **File server quotas / FSRM** | Quota usage per share, file screening (block .exe uploads), large/old file reports. | FSRM role |
| **AD CS (internal PKI)** | Issued/expiring certificates from the CA database (`certutil -view`), template audit. Completes `Get-CertExpiryReport`. | AD CS |
| **Defender for Endpoint** | Device risk score, active alerts, onboarding status (Graph security API). | MDE licence |
| **Switch/firewall config backups** | Nightly config pull over SSH (Posh-SSH) to a versioned folder. | Network gear with SSH |
| **Linux hosts in Zabbix** | Template + a Bash metrics script mirroring section 10 for Linux servers. | Linux servers |
| **Asset & warranty** | Serial → warranty end via vendor APIs (Dell, HP, Lenovo), asset list from Intune + AD. | Vendor API keys |
| **Intune Win32 packaging helper** | Wrap an MSI/EXE with `IntuneWinAppUtil.exe`, upload via Graph, assign — for the Zabbix agent and any LOB app. | Intune |
| **RDS / session hosts** | Session counts, user profile disk sizes, logoff idle sessions. | RDS |

### Nice to have

| Area | What |
| --- | --- |
| **Documentation generator** | Turn the discovery Markdown into a wiki page (SharePoint/Confluence/DokuWiki via API) and keep it updated on a schedule. |
| **Ticketing hooks** | Create/annotate tickets from scripts (whatever the helpdesk tool is — most have a REST API). |
| **Self-service password reset guide** | User-facing NL/EN one-pager for SSPR + MFA enrolment, to go with the welcome template. |
| **Change log for the environment** | Diff two discovery reports and produce "what changed since last month". |
| **Purview / DLP basics** | Sensitivity labels present? DLP policies? Read-only report. |

---

## 3. Raise the quality bar

| What | Why | How |
| --- | --- | --- |
| **Code signing** | Lets the company run with `AllSigned` execution policy instead of `Bypass`. Looks professional in an audit. | An internal CA code-signing cert (AD CS) or a cheap public one; `Set-AuthenticodeSignature` over every `.ps1`/`.psm1`; a `Sign-Toolkit.ps1` at the root. |
| **CI on GitHub** | The static tests run on every push; you never ship a parse error again. | GitHub Actions with `pwsh` running `Tests\Run-Tests.ps1`. Keep the repo private or scrub anything environment-specific first. |
| **Semantic versioning** | 1.1 today. Bump minor for new sections, patch for fixes; tag releases; the ISO name carries the version. | `VERSION` + `CHANGELOG.md` already exist; add a `Build-Iso.ps1` that reads them. |
| **Config over parameters** | Done (1.2.0): `Config\toolkit-settings.json`. | — |
| **Consistent logging** | See 1.3. Every run leaves a line in `Logs\`. | One helper snippet, pasted. |
| **Report style** | See 1.10. | One CSS block. |
| **Behaviour tests** | See 1.9. | Pester + mocks. |
| **A `-Verbose` story** | Some scripts print a lot, some little. | Route detail lines through `Write-Verbose` where the console gets noisy. |
| **NL user-facing output** | Anything a *user* sees (welcome e-mail, lock-screen text, shortcut names) should be available in Dutch. Admin-facing output stays English. | Templates already NL/EN; extend to shortcut manifest names and OEM support text. |

---

## 4. Suggested order

1. ~~Test on the server~~ — done for half the kit (1.1.x); finish the other half section by section (see project notes).
2. **0.1 + 0.2 Multi-company fleet, launched from Zabbix** — companies + devices from Zabbix, per-company Config, `Invoke-ToolkitFleet`, scope flags, Zabbix global scripts / UserParameters so the boss picks the device in the monitoring UI. The one thing that turns the kit from "my PC" into "the customers' PCs".
3. ~~1.5 Config file~~ — done (1.2.0). **1.2, 1.3** still open.
4. **Backup verification** — the other "very likely" item with a big payoff.
5. **1.4 alerting wiring** — once there's a Teams channel to send to.
6. Everything else as the job actually asks for it. Don't build for a printer server that doesn't exist.

---

## How to add a section (so it stays "apart")

- New folder `NN-Name\`, one `README.md`, scripts that carry their own
  helpers (copy the inline block from any section-20 script).
- No `Import-Module` of another section. If two scripts need the same
  logic, paste it — duplication is the price of standalone, and it's cheap.
- Registry changes: `Backup-RegistryKey` per key, `-Rollback` restores the
  newest *set*. Anything destructive: `SupportsShouldProcess`, `ConfirmImpact = 'High'`.
- Never delete accounts, records or files by default. Report first, remove
  as a separate explicit step.
- Add rows to `INVENTORY.md` and `README.md`, a line to `CHANGELOG.md`,
  bump `VERSION`, run `Tests\Run-Tests.ps1`, rebuild the ISO.
