# 07 — Reporting & Health (the daily-driver reports)

The "how are things?" section. These are mostly **read-only** — they look at a
machine (or several) and write a report. Safe to run any time, as a normal user
for most, admin for a few (noted below).

Every report lands under **`C:\Sysadmin-Toolkit\Reports\`** as an HTML file (open
it in a browser) and often a CSV too.

| Script | What it does | Admin? |
| --- | --- | --- |
| `Invoke-HealthCheck.ps1` | Scored health of a PC: disk, memory, services, reboot pending, uptime, updates, Defender → HTML + trend CSV, optional email. | no |
| `Get-PCInventory.ps1` | Full inventory of a PC (hardware, OS, disks, network, installed software). | for BitLocker info |
| `Get-CertExpiryReport.ps1` | Certificates that are expiring soon. | no |
| `Get-FirewallAuditReport.ps1` | Firewall profiles, inbound rules, listening ports; flags risky ones. | no |
| `Get-SoftwareInventoryReport.ps1` | Software across machines + end-of-life flags. | no |
| `Confirm-BitLockerEscrow.ps1` | Are BitLocker recovery keys backed up to AD/Entra? | yes |
| `Install-HealthCheckTask.ps1` | Schedule the health check to run daily. | yes |

---

## The health check (worked example)

```powershell
.\07-Reporting-Health\Invoke-HealthCheck.ps1
```

**What you'll see:** a scored summary in the console (green/amber/red per area),
and the line telling you where the HTML report was written. Open that HTML file
to see the detail. Run it again another day and it appends to a **trend CSV**, so
you can see whether things are getting better or worse.

Email it to yourself automatically:

```powershell
.\07-Reporting-Health\Invoke-HealthCheck.ps1 -EmailTo you@company.com `
    -EmailFrom kit@company.com -SmtpServer smtp.company.com
```

---

## Certificates about to expire

```powershell
.\07-Reporting-Health\Get-CertExpiryReport.ps1 -WarningDays 30
```

Lists machine certificates expiring within 30 days — a classic "avoid the 2 a.m.
outage" check. Add `-ComputerName SERVER1,SERVER2` to check remote machines
(needs WinRM).

---

## Run the health check every day, by itself

```powershell
.\07-Reporting-Health\Install-HealthCheckTask.ps1 -WhatIf
.\07-Reporting-Health\Install-HealthCheckTask.ps1
```

Registers a Windows Scheduled Task (as SYSTEM) that runs the health check daily.
`-Remove` takes it away again.

---

## Reading the score

Green = fine, amber = worth a look, red = needs attention. A red on "reboot
pending" just means the machine wants a restart; a red on disk means it's nearly
full. The report explains each line — you don't have to memorise anything.
