# 05 — Network

Two **read-only** network tools — safe to run any time, no admin needed.

| Script | What it does |
| --- | --- |
| `Get-NetworkDiagnostics.ps1` | The full picture of this machine's networking: adapters, gateway, DNS, whether the internet is reachable, your public IP → HTML report. |
| `Invoke-SubnetScan.ps1` | Sweep a subnet to find live hosts, their names and MACs, and optionally open ports → CSV/HTML. |

```powershell
# "Why isn't this PC on the internet?" — one report with the answers:
.\05-Network\Get-NetworkDiagnostics.ps1

# What's alive on the 192.168.1.0/24 network?
.\05-Network\Invoke-SubnetScan.ps1 -Subnet 192.168.1.0/24
```

`Get-NetworkDiagnostics` is the fastest first step for a connectivity ticket — it
checks each layer (adapter → gateway → DNS → internet) and shows you where it
breaks. Add `-TargetHosts server1,192.168.1.1` to also test reaching specific
hosts.
