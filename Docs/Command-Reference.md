# Sysadmin-Toolkit — command reference

Every command you actually need, in one place, grouped by task. Copy, adjust the
values in `<angle brackets>`, run. Lab values (e.g. `192.168.122.152`) are shown
as examples — swap in your own.

All script runs assume you're in `C:\Sysadmin-Toolkit` (`cd C:\Sysadmin-Toolkit`)
and using an **elevated** PowerShell.

---

## 1. Install / update the kit

```powershell
# From the release: run the installer (over an old copy is fine)
.\Setup.exe

# Confirm the installed version
Get-Content C:\Sysadmin-Toolkit\VERSION

# If a Config file ever shows "read-only", clear it:
attrib -R "C:\Sysadmin-Toolkit\*" /S /D
```

---

## 2. Configure the environment (once)

Edit `C:\Sysadmin-Toolkit\Config\toolkit-settings.json` — every script reads it.
Company name, AD, shares, branding, Zabbix URL, etc. Put per-customer branding
files in `Config\Branding\`.

```powershell
notepad C:\Sysadmin-Toolkit\Config\toolkit-settings.json
```

---

## 3. Run any script directly

```powershell
# The menu (browse everything, with a help card)
.\Start-SysadminToolkit.ps1

# A specific script
.\17-Security-Audit\Get-LocalAdminAudit.ps1

# Safe preview of a changing script — shows what it WOULD do
.\20-Desktop-Experience\Set-PowerAndLock.ps1 -Workstation -WhatIf
```

---

## 4. Onboarding / offboarding

```powershell
# Preview onboarding (no changes)
.\01-Users\New-ADUserOnboard.ps1 -FirstName Jan -LastName Jansen -WhatIf

# Offboard, non-interactive (no "Are you sure?" prompt) — for automation/scripts
.\01-Users\Disable-ADUserOffboard.ps1 -SamAccountName <user> -Force
```

`-Force` (or the env var `SYSADMIN_TOOLKIT_FORCE=1`) skips confirmation on any
changing script — that's what makes them safe to run from Zabbix or the fleet
runner.

---

## 5. Zabbix buttons

### Get an API token
Zabbix UI → **Users → API tokens → Create**, copy the string (shown once).

### Create the standard 10 buttons over the API
```powershell
# Dry run (creates nothing)
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix -ApiToken <token> -WhatIf

# For real
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix -ApiToken <token>

# Only for one customer's hosts
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -HostGroup 'Contoso'

# Remove all the Toolkit buttons again
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Remove
```
Idempotent — re-run any time; existing buttons update, missing ones get created.
The URL can also come from `Config` (`Monitoring.ZabbixUrl`), and the token from
a stored secret (`19-Secrets\Manage-ToolkitSecret.ps1 -Set ZabbixApiToken`).

### Expose a whole section at once (folder mode)
```powershell
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Folder "07-Reporting-Health"
```
Scans the folder, makes a button for every **read-only** script
(`Get-`/`Test-`/`Find-`/`Measure-`/`Show-`/`Read-`/`Confirm-`), and **skips**
anything that changes the machine (`Set-`/`New-`/`Disable-`/`Remove-`/`Enable-`/
`Invoke-`/...).

### Add one custom button by hand
Add a line to `10-Monitoring-Zabbix\toolkit-zabbix-scripts.json` then re-run the
creator:
```json
{ "name": "Reboot pending", "script": "07-Reporting-Health\\Test-RebootPending.ps1", "description": "Is a reboot pending on this host." }
```
(Button name in Zabbix = `Toolkit:` + the JSON `name`.)

### Let a host run the buttons — one-time agent config
On each **Windows target**, elevated PowerShell:
```powershell
# Lab (wide open — fine for a lab, NOT production)
Add-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' "`nAllowKey=system.run[*]"
# Give slow read-only checks room (max 30s)
Add-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' "`nTimeout=30"
Restart-Service 'Zabbix Agent 2'
```
Production: replace the wide `AllowKey` with the toolkit-only allow-list — see
`10-Monitoring-Zabbix\Zabbix-Run-Toolkit-Scripts.md`.

### Fix "context deadline exceeded"
Raise the timeout in **both** places, to the same value:
```powershell
# On the Windows host (agent)  — see above: Timeout=30 + restart agent

# On the Zabbix server (Ubuntu)
sudo sed -i -E 's/^#?\s*Timeout=.*/Timeout=30/' /etc/zabbix/zabbix_server.conf
sudo systemctl restart zabbix-server
```
A script that still can't finish in 30s doesn't belong on a run-and-wait button.

---

## 6. Fleet runner — one script across many machines

Full detail and troubleshooting: `21-Fleet\Run-The-Fleet.md`.

### On each target (once)
```powershell
Enable-PSRemoting -Force -SkipNetworkProfileCheck   # -Skip... handles a Public NIC
ipconfig | findstr /i IPv4                           # note the IP
whoami                                               # note the local admin account
```

### On the machine you run FROM (workgroup targets only)
```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.122.58" -Concatenate -Force
Test-WSMan -ComputerName 192.168.122.58              # should return Microsoft wsmid lines
$cred = Get-Credential                               # user: 192.168.122.58\<localadmin>
```

### Push the kit to a target that doesn't have it
```powershell
$s = New-PSSession -ComputerName 192.168.122.58 -Credential $cred
Copy-Item -Path C:\Sysadmin-Toolkit -Destination C:\ -ToSession $s -Recurse -Force
Remove-PSSession $s
```

### Run it
```powershell
# Dry run — lists targets, changes nothing
.\Invoke-ToolkitFleet.ps1 -Computers 192.168.122.58 -Script "17-Security-Audit\Get-LocalAdminAudit.ps1" -Credential $cred -WhatIf

# For real (workgroup: keep -Credential; domain-joined: drop it)
.\Invoke-ToolkitFleet.ps1 -Computers 192.168.122.58 -Script "17-Security-Audit\Get-LocalAdminAudit.ps1" -Credential $cred

# A whole company from Zabbix/AD instead of one host
.\Invoke-ToolkitFleet.ps1 -Company Contoso -OS 'Windows 11*' -Script "07-Reporting-Health\Get-PCInventory.ps1"
```

### See a company's devices (no run)
```powershell
.\21-Fleet\Get-ManagedFleet.ps1 -Company Contoso -OnlineOnly
```

---

## 7. Quick checks

```powershell
hostname                                             # which machine am I on?
Get-Content C:\Sysadmin-Toolkit\VERSION              # kit version
Get-ChildItem C:\Sysadmin-Toolkit\Reports | Sort-Object LastWriteTime -Descending | Select-Object -First 5
```

---

Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
