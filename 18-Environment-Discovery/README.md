# 18 — Environment Discovery

The day-1 script. Run it once from an admin workstation (or a DC) and you
get a Markdown + HTML document describing the environment you just walked
into — before anyone has had time to explain it to you. Self-contained,
single file, read-only.

## What's here

| Script | What it does |
| --- | --- |
| `Get-EnvironmentDiscovery.ps1` | Domain/forest, DCs, FSMO holders, OU tree, GPO list, DHCP scopes, DNS zones, servers in AD, file shares, and (with `-IncludeCloud`) Entra tenant + Intune device/policy overview. Writes `Environment_<date>.md` + `.html`. |

## Usage

```powershell
.\Get-EnvironmentDiscovery.ps1
.\Get-EnvironmentDiscovery.ps1 -FileServer FS01 -IncludeCloud
.\Get-EnvironmentDiscovery.ps1 -OUDepth 3
```

## What to expect

Every section is optional. If the RSAT module for it isn't installed where
you run it (GroupPolicy, DhcpServer, DnsServer), that section just says
_skipped_ and everything else still runs. Best results: run it on a machine
with the full RSAT set, or on a domain controller — they have everything.

The Markdown file is meant to become the start of your own environment
documentation: open it, add what you learn from colleagues (backup solution,
who owns what, vendor contacts), and keep it. Re-run the script in a month
and diff the two — that's your change log for free.

## Requirements

- `ActiveDirectory` module (RSAT) for the AD, servers and OU sections.
- `GroupPolicy`, `DhcpServer`, `DnsServer` modules for their sections.
- `Microsoft.Graph` + Intune Administrator (read) for `-IncludeCloud`.
