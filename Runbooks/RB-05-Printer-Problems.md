# RB-05 — Printer problems

## 1. Scope

- One user can't print, others can → the user's PC / their driver / their
  connection to the queue.
- Nobody can print to this printer → the printer, or the print server
  queue for it.
- Nobody can print to anything → print server spooler (go to 4).

## 2. The printer itself (physical)

Walk there or ask someone to. Display says what's wrong 90% of the time:
paper jam, toner, "offline", tray open, needs a code. Power-cycle the
printer. Can you ping it? `Test-Connection <printer-ip>` — no reply means
network/cable/printer, not Windows.

## 3. One user

On their PC:

```powershell
Get-Printer | Select-Object Name, PrinterStatus, PortName, DriverName
Get-PrintJob -PrinterName "<name>"          # stuck jobs?
```

- Stuck job: `Remove-PrintJob` on it, or clear the queue (below).
- "Offline" while the printer is fine: remove the printer and add it
  again from the server (`\\printserver\<queue>`), or push the standard
  set again: `04-PC-Provisioning\Setup-PrintersAndDrives.ps1`.
- Driver error / prints garbage: remove printer, delete the driver
  (Print Management → Drivers), re-add from the server so it pulls a
  fresh driver.
- Wrong default printer: `Set-Printer`? No — that's per-user:
  Settings → Printers, or `(New-Object -ComObject WScript.Network).SetDefaultPrinter("<name>")`.

## 4. Print server / spooler

Clear a stuck spooler safely:

```powershell
Stop-Service Spooler
Remove-Item "$env:SystemRoot\System32\spool\PRINTERS\*" -Force
Start-Service Spooler
```

(Everyone's queued jobs are gone — tell them to print again.)

Spooler keeps crashing → almost always a bad driver. Event Viewer →
Applications → look for the driver name in the crash, remove that driver
from Print Management, re-add with the current vendor package.

Check the server generally while you're on it: RB-08 and
`07-Reporting-Health\Invoke-HealthCheck.ps1`.

## 5. Scan-to-email / scan-to-folder stopped

- Scan-to-email: printer's SMTP settings — password changed? TLS now
  required? Ask whoever manages email whether SMTP auth/relay changed.
- Scan-to-folder: the service account's password expired, or the share
  permission changed. `16-FileShares\Get-SharePermissionReport.ps1` on
  that share.

## Close

If a printer is a repeat offender, note the model and the fix — the next
person will hit the same thing.
