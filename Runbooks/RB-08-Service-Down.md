# RB-08 — Service down / server unresponsive

"Nobody can open the application" — application server, file server, print
server, intranet, whatever it is.

## 1. Is the server alive?

```powershell
Test-Connection SRV-APP01 -Count 2
Test-NetConnection SRV-APP01 -Port 443      # or 445 for a file server, 3389 for RDP, the app's port
```

- No ping, no ports → host down or network to it (RB-03 for the network
  half). Hypervisor console: is the VM running? Is the host up?
- Ping ok, port closed → the service is down (go to 2).
- Port open but the app misbehaves → application-level (go to 3).

## 2. The service

```powershell
Get-Service -ComputerName SRV-APP01 | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' }
```

Auto-start services that aren't running are your shortlist. Start the one
that matters:

```powershell
Start-Service -Name <service> ; Get-Service <service>
```

If it stops again within a minute: Event Viewer → System + Application,
filter by the last 30 minutes. The error before the stop is the cause —
usually disk full (RB-04), a expired certificate
(`07-Reporting-Health\Get-CertExpiryReport.ps1`), a service-account
password that expired/changed, or a dependency service that's down.

## 3. Health look, without rebooting

`07-Reporting-Health\Invoke-HealthCheck.ps1` remotely or on the box: disk,
memory, pending reboot, uptime, event-log error rate, Defender. A server at
99% memory or 100% disk explains most "it's up but nothing works" cases.

Also quick:

- **Time**: `w32tm /query /status` — clock off by > 5 min breaks Kerberos
  and therefore everything.
- **Certificates**: expired LDAPS/IIS/RDP cert = silent failures.
- **Recent changes**: Windows updates last night? `Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5`
- **Firewall**: did a rule change? `07-Reporting-Health\Get-FirewallAuditReport.ps1`

## 4. When to reboot a server

After you've noted what you saw (services, events, resource usage). Then:
tell users first (template in `Docs\Communication-Templates.md`), then
`Restart-Computer SRV-APP01 -Force` — and stay there until it's back and
the service is running. If it's a **domain controller**: check
`12-AD-Health\Test-ADHealth.ps1` afterwards to be sure replication is
healthy.

## 5. It's back — now the real work

- Cause found? If not, write down what you observed so the pattern shows
  next time.
- Would monitoring have told you before users did? Add the check (Zabbix
  section 10, or the scheduled health check).
