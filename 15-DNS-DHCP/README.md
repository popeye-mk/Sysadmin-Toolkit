# 15 — DNS / DHCP

Two independent, self-contained reports — neither needs the other, and
neither needs anything else in the kit.

## What's here

| Script | What it does |
| --- | --- |
| `Get-DHCPScopeReport.ps1` | Utilization % per DHCP scope across one or more servers. Flags anything approaching exhaustion before it becomes "why can't anyone get an IP." |
| `Get-StaleDNSRecords.ps1` | Finds A records that don't answer a ping, cross-checked against AD computer objects when available. **Report only — never deletes automatically.** Removal is a separate, explicit, opt-in step. |

## Usage

```powershell
.\Get-DHCPScopeReport.ps1
.\Get-DHCPScopeReport.ps1 -ComputerName dhcp01.contoso.local -WarningPercent 75

.\Get-StaleDNSRecords.ps1
.\Get-StaleDNSRecords.ps1 -ZoneName contoso.local

# only after reviewing the report yourself:
.\Get-StaleDNSRecords.ps1 -ZoneName contoso.local -RecordsToRemove OLD-PC01,OLD-PC02 -WhatIf
```

## Requirements

- `Get-DHCPScopeReport.ps1`: `DhcpServer` module (RSAT: DHCP Server Tools).
- `Get-StaleDNSRecords.ps1`: `DnsServer` module (RSAT: DNS Server Tools). The
  AD cross-check is a bonus signal, not a requirement — it runs fine without
  the `ActiveDirectory` module, it just won't show AD status.

## Why the DNS script never auto-deletes

A ping timeout isn't proof a record is safe to remove — a machine could be
off, on a different VLAN the script can't reach, or just slow to respond.
Deleting the wrong DNS record breaks something for someone. So this script's
job stops at "here's what to look at" — you decide, then run it again with
`-RecordsToRemove` for the specific names you've actually reviewed.
