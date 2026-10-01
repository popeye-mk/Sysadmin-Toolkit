# 10 — Monitoring: Zabbix + Grafana

Wires this toolkit's health data into Zabbix so it shows up in Grafana, instead
of `07-Reporting-Health\Invoke-HealthCheck.ps1` only emailing an HTML report.

This folder is self-contained — copy just `10-Monitoring-Zabbix\` to an
endpoint, or push it via `..\09-Entra-Intune\Deploy-ScriptViaIntune.ps1` /
as an Intune Win32 app. It does not depend on the rest of the kit.

## How it fits together

```
Windows PC ──(Zabbix Agent 2, active check)──▶ Zabbix Server ──▶ Grafana
     │
     └─ UserParameter "toolkit.metrics" runs
        Get-ToolkitZabbixMetrics.ps1 every 5 min,
        which emits ONE line of JSON:
        {"healthScore":85,"pendingReboot":0,"diskFreePctMin":42,...}
                │
                ▼
     Zabbix template splits that JSON into ~11 separate items
     (dependent items + JSONPath preprocessing) — one PowerShell
     launch feeds every metric, not one launch per item.
```

## Files

| File | What it is |
| --- | --- |
| `Install-ZabbixAgent.ps1` | Silent Zabbix Agent 2 install + config, deploys the UserParameter in the same run. |
| `UserParameters\SysadminToolkit.conf` | The one-line UserParameter definition (`toolkit.metrics`). |
| `UserParameters\Get-ToolkitZabbixMetrics.ps1` | Self-contained script that emits the JSON snapshot. Safe to run by hand to see what Zabbix would capture. |
| `zbx_template_windows_sysadmintoolkit.xml` | Zabbix 6.0+ template: 1 master item, 11 dependent items, 8 triggers, 1 value map. Import as-is. |
| `grafana_dashboard_sysadmintoolkit.json` | Grafana dashboard (grafana-zabbix plugin): fleet health score, pending-reboot count, Defender-off count, low-disk count, a trend chart, and a sortable table. |

## Setup, in order

**1. Get the agent onto a machine**

Download the Zabbix Agent 2 MSI matching your Zabbix server version from
<https://www.zabbix.com/download_agents> (not hardcoded here — versions and
URLs change), then:

```powershell
.\Install-ZabbixAgent.ps1 -InstallerPath C:\Temp\zabbix_agent2-7.0.msi -ServerActiveIP zabbix.yourdomain.local
```

This installs the agent, points it at your server for **active** checks (the
agent calls out — no inbound firewall hole needed), and deploys
`SysadminToolkit.conf` + the metrics script into the agent's config folder in
the same run. Pass `-AllowPassiveChecks -ServerIP ...` too if your Zabbix setup
also needs passive (server-initiated) checks.

To roll this out fleet-wide instead of machine-by-machine, package it as an
Intune Win32 app, or push it with
`..\09-Entra-Intune\Deploy-ScriptViaIntune.ps1` (note: that script deploys a
single .ps1; for this one you'd want the MSI staged somewhere reachable, or
use Intune's native Win32 app packaging with `IntuneWinAppUtil.exe`, which
isn't scriptable from here).

**2. Confirm the item works**

On the endpoint:

```powershell
& "C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe" -t toolkit.metrics
```

You should see one line of JSON back.

**3. Import the template into Zabbix**

Zabbix web UI → **Data collection → Templates → Import** →
`zbx_template_windows_sysadmintoolkit.xml`. It creates its own template group
(`Templates/Sysadmin-Toolkit`) so it won't collide with anything you already have.

**4. Link it to your hosts**

Either link the template to your existing Windows host objects (**Data
collection → Hosts → [host] → Templates → Add**), or let Zabbix
auto-register/discover them if you already have that set up — this template
doesn't assume either way.

**5. Import the Grafana dashboard**

Grafana → **Dashboards → Import** → upload
`grafana_dashboard_sysadmintoolkit.json`. On import, Grafana asks you to map
the `DS_ZABBIX` variable to your actual Zabbix data source (the
grafana-zabbix / `alexanderzobnin-zabbix-datasource` plugin must already be
installed and configured against your Zabbix server). Then set the **Host
group** text variable at the top of the dashboard to whatever Zabbix host
group you linked the template to.

## What's in the JSON / what each item means

| JSON field | Zabbix item key | Meaning |
| --- | --- | --- |
| `healthScore` | `toolkit.health.score` | 0-100, same scoring model as `Invoke-HealthCheck.ps1` at a lighter scope (fast enough to poll every 5 min). |
| `healthGrade` | `toolkit.health.grade` | Healthy / Attention / ActionNeeded |
| `failCount` / `warnCount` | `toolkit.health.failcount` / `.warncount` | Counts behind the score |
| `pendingReboot` | `toolkit.pendingreboot` | 0/1 — Component Based Servicing / WU reboot flags |
| `diskFreePctMin` | `toolkit.disk.freepctmin` | Lowest free-% across fixed drives |
| `uptimeDays` | `toolkit.uptime.days` | Days since last boot |
| `defenderRealTime` / `defenderSigAgeDays` | `toolkit.defender.*` | Real-time protection on/off, signature age |
| `bloatwareCount` | `toolkit.bloatware.count` | Quick subset of the curated debloat list — not the full list (kept fast for a 5-min poll) |
| `passwordExpiryCount` | `toolkit.ad.passwordexpirycount` | AD accounts expiring within 14 days — only populated on a host with RSAT + a reachable DC (a DC or admin/management box); empty elsewhere, by design |

## Notes

- The 5-minute poll interval is set on the master item in the template — change
  `<delay>5m</delay>` before import if you want it tighter or looser. Dependent
  items always follow the master's schedule (their own `delay` is `0`).
- Triggers ship with sensible defaults (score < 70 warning, < 50 high; disk <
  15%/8%; Defender off; reboot pending 3+ polls running). Tune severities/
  thresholds in Zabbix after import to match your environment — don't treat
  these as gospel on day one.
- CSP/policy names inside `09-Entra-Intune` and the Windows-side registry
  checks here can shift across Windows builds. If an item stops reporting,
  check that first before assuming the wiring broke.

## Running toolkit scripts from Zabbix

See **Zabbix-Run-Toolkit-Scripts.md** in this folder: how to make a Zabbix button that runs a kit script on a host (validated live on the lab), the read-vs-change split, command patterns, and the production hardening with a UserParameter allow-list.
