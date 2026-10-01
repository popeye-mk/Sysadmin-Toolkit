# Running the fleet runner

Run one toolkit script across many machines from a single console, get one
report. This is the exact procedure validated live (a Windows DC running the
script against a workgroup Windows 11 host over WinRM).

The runner (`Invoke-ToolkitFleet.ps1`) executes the kit script **on each
target**, so two things must be true on every target: PowerShell remoting
(WinRM) is on, and the kit is installed at `C:\Sysadmin-Toolkit`.

---

## The short version

- **Domain-joined targets** — turn WinRM on, run the fleet runner from a DC (or
  any domain box) with your domain admin session. Kerberos handles auth; no
  credential juggling, no TrustedHosts.
- **Workgroup / standalone targets** — turn WinRM on, add each target to
  `TrustedHosts` on the machine you run *from*, and pass `-Credential`.

---

## A. On each target (once)

Elevated PowerShell **on the target**:

```powershell
Enable-PSRemoting -Force -SkipNetworkProfileCheck
```

`-SkipNetworkProfileCheck` lets this succeed even when a network adapter is set
to **Public** — it scopes the WinRM firewall rule to the local subnet. Without
it you get *"WinRM firewall exception will not work since one of the network
connection types … is set to Public."*

Get the target's IP and the local admin account you'll authenticate as:

```powershell
ipconfig | findstr /i IPv4
whoami
```

> The kit is normally already on the target via the installer / ISO / GPO /
> Intune. If it isn't, see **C** — you can push it over the same remoting.

---

## B. On the machine you run FROM

**Domain-joined targets:** nothing to do here — skip to **D**.

**Workgroup targets:** trust each target and confirm it's reachable:

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.122.58" -Concatenate -Force
Test-WSMan -ComputerName 192.168.122.58
```

`-Concatenate` adds to the list instead of replacing it — re-run it (or
comma-separate) for more targets. `Test-WSMan` returning `wsmid … Microsoft
Corporation` lines means the target's WinRM is reachable from here.

Make a credential for the target's local admin:

```powershell
$cred = Get-Credential      # User name: 192.168.122.58\stojan
```

> Use `<ip-or-name>\<localuser>` for a workgroup box (e.g.
> `192.168.122.58\stojan`), not just the bare user name.

---

## C. Put the kit on the target (only if it's missing)

If a target doesn't have `C:\Sysadmin-Toolkit` yet, push it over the remoting
you just set up (workgroup shown; domain-joined omits `-Credential`):

```powershell
$s = New-PSSession -ComputerName 192.168.122.58 -Credential $cred
Copy-Item -Path C:\Sysadmin-Toolkit -Destination C:\ -ToSession $s -Recurse -Force
Invoke-Command -Session $s { Test-Path C:\Sysadmin-Toolkit\17-Security-Audit\Get-LocalAdminAudit.ps1 }
Remove-PSSession $s
```

The `Test-Path` line printing **True** confirms the kit landed.

---

## D. Run it

Dry run first — lists the targets and stops, changes nothing:

```powershell
.\Invoke-ToolkitFleet.ps1 -Computers 192.168.122.58 -Script "17-Security-Audit\Get-LocalAdminAudit.ps1" -Credential $cred -WhatIf
```

Then for real — drop `-WhatIf`:

```powershell
.\Invoke-ToolkitFleet.ps1 -Computers 192.168.122.58 -Script "17-Security-Audit\Get-LocalAdminAudit.ps1" -Credential $cred
```

- **Domain-joined:** omit `-Credential` entirely.
- **A whole company instead of one host:** `-Company Contoso` in place of
  `-Computers …` — it resolves the device list from Zabbix host groups (or AD),
  see `Get-ManagedFleet.ps1`.
- **Filter by OS:** add `-OS 'Windows 11*'`. **More hosts at once:**
  `-ThrottleLimit 32`. **Skip some:** `-Exclude PC05,PC06`.

You get one **done / offline / failed** report and a CSV in the kit's `Reports`
folder.

---

## Which scripts belong here

Fast, **read-only, machine-scope** scripts — audits, reports, health checks.
The runner forces non-interactive mode (`SYSADMIN_TOOLKIT_FORCE=1`) in the
remote session, so a script that would normally prompt won't hang.

**Per-user** scripts (theme, per-user context menu) must run in the user's own
logged-on session — the fleet runner runs as the remoting account, not the
logged-on user, so push those through **GPO / Intune** instead.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `ServerNotTrusted` / "must be added to the TrustedHosts configuration" | You're running from a machine that doesn't trust the target. Set `TrustedHosts` (**B**) on the machine you run *FROM* — and check `hostname` to be sure you're on it, not on the target. |
| "WinRM firewall exception will not work since one of the network connection types … is set to Public" | On the target: `Enable-PSRemoting -Force -SkipNetworkProfileCheck`. |
| "Access is denied. … Run as administrator" | Open PowerShell **elevated** (Task Manager → Run new task → tick "administrative privileges"). |
| `kit/script not found on host` in the report | The kit isn't at `C:\Sysadmin-Toolkit` on that target — deploy it (**C**, or the installer/ISO/GPO). |
| Host shows **offline** in the report | `Test-WSMan -ComputerName <ip>` from the runner. If it fails: WinRM off, firewall, or the target is down. |
| Access denied opening the session, credentials correct | Workgroup remote admin needs `LocalAccountTokenFilterPolicy=1` — `Enable-PSRemoting` sets it; a hardened image may not. |

---

Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
