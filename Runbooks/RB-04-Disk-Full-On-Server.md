# RB-04 — Disk full on a server

A full system drive on a server stops services, breaks logons on a DC, and
kills backups. Treat as urgent, but don't delete blindly.

## 1. Confirm and size it

```powershell
Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}
```

Or the fleet view: `07-Reporting-Health\Invoke-HealthCheck.ps1` (disk is
part of the score) — and if Zabbix/Grafana is wired (section 10), the
disk-free item will already be red.

## 2. Find what's eating it (don't guess)

Largest folders on the drive, top-level first:

```powershell
Get-ChildItem C:\ -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $s = (Get-ChildItem $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Folder = $_.FullName; GB = [math]::Round($s/1GB,1) }
} | Sort-Object GB -Descending | Select-Object -First 15
```

Repeat into the biggest one. Usual suspects on a server:

| Where | What | Safe action |
| --- | --- | --- |
| `C:\Windows\Temp`, `C:\Users\*\AppData\Local\Temp` | temp files | delete contents |
| `C:\Windows\SoftwareDistribution\Download` | update cache | stop `wuauserv`, delete contents, start it |
| `C:\inetpub\logs\LogFiles`, app log folders | IIS/app logs | archive + delete old ones; set log rotation |
| `C:\Windows\System32\winevt\Logs` | event logs | don't delete — set a max size in Event Viewer |
| `C:\Windows\Installer` | MSI cache | **don't touch** manually |
| `C:\ProgramData\<backup product>` | backup staging | check the backup job, it may be stuck |
| `C:\Windows\WinSxS` | component store | `Dism /Online /Cleanup-Image /StartComponentCleanup` only |
| User profiles on an RDS host | user data | that's a policy problem, not a delete problem |
| SQL/Exchange logs | transaction logs | backups aren't truncating them — fix the backup, don't delete |
| `pagefile.sys`, `hiberfil.sys` | system | leave the pagefile; `powercfg /h off` removes hiberfil on a server safely |

## 3. Free space now, fix the cause after

- Disk Cleanup as admin: `cleanmgr /sageset:1` then `cleanmgr /sagerun:1`
  (tick Windows Update Cleanup).
- Empty the Recycle Bin for all users: `Clear-RecycleBin -Force`.
- Shadow copies on a file server hogging space:
  `vssadmin list shadowstorage` — resize the limit rather than deleting
  all snapshots.

## 4. Make sure it doesn't come back

- Set a max size on whatever log grew.
- If it's a VM: is growing the disk simply the right answer? Often yes.
- Add the server to the health-check schedule if it isn't:
  `Install-AllScheduledTasks.ps1` — or the Zabbix trigger for disk < 15%
  (section 10) so you hear about it at 60% next time, not 99%.

## Never

- Never delete from `C:\Windows\System32`, `Installer`, `WinSxS`, or a
  database's data/log folder to "make space".
- Never shrink a database log by deleting the file.
