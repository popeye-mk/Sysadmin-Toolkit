<#
.SYNOPSIS
    Find DNS A records that don't answer a ping and (optionally) don't match
    a live AD computer object — a report to review, never an auto-delete.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    Get-DHCPScopeReport.ps1 next to it (the two don't need each other).

    Common after years of PC replacements: DNS keeps A records for machines
    that were reimaged, replaced, or retired without anyone cleaning up after
    them. This script flags candidates — it does NOT delete anything on its
    own, ever. Deleting a DNS record you shouldn't have breaks something for
    someone, so removal is a separate, explicit, opt-in step (-RecordsToRemove
    + -WhatIf) you run only after you've reviewed the report yourself.

    For each A record in the target zone(s):
      - Pings the IP (quick, short timeout) — no answer is the main signal.
      - If the AD module is available, cross-checks whether a matching,
        enabled AD computer account exists (extra signal, not a
        requirement — plenty of legitimate records aren't computer objects:
        printers, IoT, appliances, DHCP reservations for non-domain devices).

.PARAMETER ZoneName
    DNS zone(s) to check. Default: every primary zone on the target server.
.PARAMETER ComputerName
    DNS server to query (default: local machine / current domain's DNS).
.PARAMETER PingTimeoutMs
    Ping timeout per record (default 500ms — keep this low, you may be
    checking hundreds of records).
.PARAMETER SkipADCheck
    Skip the AD computer-object cross-check even if the AD module is present.
.PARAMETER RecordsToRemove
    Opt-in removal: exact record name(s) to delete, after you've reviewed the
    report. Nothing is ever removed just from running the report itself.

.EXAMPLE
    .\Get-StaleDNSRecords.ps1
.EXAMPLE
    .\Get-StaleDNSRecords.ps1 -ZoneName contoso.local -PingTimeoutMs 1000
.EXAMPLE
    # after reviewing the report:
    .\Get-StaleDNSRecords.ps1 -ZoneName contoso.local -RecordsToRemove OLD-PC01,OLD-PC02 -WhatIf

.NOTES
    Needs the DnsServer module (RSAT: DNS Server Tools). AD cross-check needs
    the ActiveDirectory module too, but runs fine without it (just skips that
    column). Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$ZoneName,
    [string]$ComputerName = $env:COMPUTERNAME,
    [int]$PingTimeoutMs = 500,
    [switch]$SkipADCheck,
    [string[]]$RecordsToRemove,
    [switch]$Force
)

$script:__ntForce = $false
if ($Force -or $env:SYSADMIN_TOOLKIT_FORCE -eq '1') { $ConfirmPreference = 'None'; $script:__ntForce = $true }

# --- Config folder (optional) -------------------------------------------------------
# Values you don't pass on the command line are taken from Config\toolkit-settings.json
# when the kit's Config folder is present. Explicit parameters always win; without a
# Config folder this script behaves exactly as its help describes. (Inline on purpose:
# the script must keep working when copied out of the kit on its own.)
function Get-ToolkitSetting {
    param([string]$Key, [switch]$File)
    if (-not $script:__cfg) {
        $script:__cfg = @{ Loaded = $true; Data = $null; Dir = $null }
        $cands = @()
        if ($env:SYSADMIN_TOOLKIT_CONFIG) { $cands += $env:SYSADMIN_TOOLKIT_CONFIG }
        if ($PSScriptRoot) {
            $parent = Split-Path $PSScriptRoot -Parent
            if ($parent) { $cands += (Join-Path $parent 'Config') }
            $cands += (Join-Path $PSScriptRoot 'Config')
        }
        $cands += 'C:\Sysadmin-Toolkit\Config'
        foreach ($d in $cands) {
            $f = $null
            try { $f = Join-Path $d 'toolkit-settings.json' -ErrorAction Stop } catch { continue }
            if ($f -and (Test-Path -LiteralPath $f -ErrorAction SilentlyContinue)) {
                try { $script:__cfg.Data = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; $script:__cfg.Dir = $d; break }
                catch { Write-Host "  [Config] $f is not valid JSON - ignored ($($_.Exception.Message))" -ForegroundColor Yellow }
            }
        }
    }
    if (-not $script:__cfg.Data) { return $null }
    $node = $script:__cfg.Data
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $part)) { return $null }
        $node = $node.$part
    }
    if ($null -eq $node) { return $null }
    if ($node -is [string]) {
        $node = [Environment]::ExpandEnvironmentVariables($node.Trim())
        if ($node -eq '') { return $null }
        if ($File) {
            if ($node -notmatch '^([A-Za-z]:|\\\\|https?:)') { $node = Join-Path $script:__cfg.Dir $node }
            if (-not (Test-Path -LiteralPath $node)) { return $null }
        }
        return $node
    }
    if ($node -is [System.Array]) { if ($node.Count -eq 0) { return $null }; return @($node) }
    return $node
}
$__cfgUsed = @()
if (-not $PSBoundParameters.ContainsKey('ZoneName')) { $__v = Get-ToolkitSetting 'Network.DnsZones'; if ($null -ne $__v) { $ZoneName = $__v; $__cfgUsed += 'Network.DnsZones' } }
if (-not $PSBoundParameters.ContainsKey('ComputerName')) { $__v = Get-ToolkitSetting 'Network.DnsServer'; if ($null -ne $__v) { $ComputerName = $__v; $__cfgUsed += 'Network.DnsServer' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Reports')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}
function Test-QuickPing {
    param([string]$IPAddress, [int]$TimeoutMs)
    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send($IPAddress, $TimeoutMs)
        return $reply.Status -eq 'Success'
    } catch { return $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Stale DNS Records" -ForegroundColor White
Write-Host "  ======================================" -ForegroundColor DarkGray

if (-not (Get-Module -ListAvailable DnsServer)) {
    Write-Log "DnsServer module not found (install RSAT: DNS Server Tools)." 'ERROR'; return
}
Import-Module DnsServer -ErrorAction Stop

$adAvailable = (-not $SkipADCheck) -and (Get-Module -ListAvailable ActiveDirectory)
if ($adAvailable) { Import-Module ActiveDirectory -ErrorAction Stop }
elseif (-not $SkipADCheck) { Write-Log "ActiveDirectory module not found — AD cross-check column will show 'Unknown'." 'INFO' }

if (-not $ZoneName) {
    try { $ZoneName = (Get-DnsServerZone -ComputerName $ComputerName -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -eq 'Primary' }).ZoneName }
    catch { Write-Log "Could not enumerate zones on ${ComputerName}: $($_.Exception.Message)" 'ERROR'; return }
}
if (-not $ZoneName -or $ZoneName.Count -eq 0) { Write-Log "No primary zones found." 'WARN'; return }

# --- opt-in removal path (skips the scan entirely — this is a separate, deliberate action) ---
if ($RecordsToRemove) {
    foreach ($zone in $ZoneName) {
        foreach ($name in $RecordsToRemove) {
            if ($PSCmdlet.ShouldProcess("$name.$zone", "Remove DNS A record")) {
                try {
                    Remove-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $zone -Name $name -RRType A -Force -ErrorAction Stop
                    Write-Log "Removed $name.$zone" 'OK'
                } catch { Write-Log "Could not remove ${name}.${zone}: $($_.Exception.Message)" 'WARN' }
            }
        }
    }
    return
}

Write-Log "Zone(s): $($ZoneName -join ', ')  |  DNS server: $ComputerName" 'INFO'

$results = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($zone in $ZoneName) {
    try { $records = @(Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $zone -RRType A -ErrorAction Stop | Where-Object { $_.HostName -ne '@' }) }
    catch { Write-Log "Could not read records for zone ${zone}: $($_.Exception.Message)" 'WARN'; continue }

    Write-Log "Checking $($records.Count) A record(s) in $zone..." 'STEP'
    foreach ($rec in $records) {
        $ip = $rec.RecordData.IPv4Address.ToString()
        $pingOk = Test-QuickPing -IPAddress $ip -TimeoutMs $PingTimeoutMs
        if ($pingOk) { continue }  # answered — not stale, skip it from the report entirely

        $adStatus = 'Unknown'
        if ($adAvailable) {
            $adObj = Get-ADComputer -Filter "Name -eq '$($rec.HostName)'" -ErrorAction SilentlyContinue
            $adStatus = if (-not $adObj) { 'Not in AD' } elseif ($adObj.Enabled) { 'In AD (enabled)' } else { 'In AD (disabled)' }
        }
        $results.Add([pscustomobject]@{
            Zone      = $zone
            HostName  = $rec.HostName
            IPAddress = $ip
            PingedOK  = $pingOk
            ADStatus  = $adStatus
            Timestamp = $rec.Timestamp
        })
    }
}

if (-not $results.Count) { Write-Log "No unresponsive A records found — nothing flagged." 'OK'; return }

Write-Host ''
foreach ($r in $results | Sort-Object Zone, HostName) {
    Write-Host ("  {0,-30} {1,-16} AD: {2}" -f "$($r.HostName).$($r.Zone)", $r.IPAddress, $r.ADStatus) -ForegroundColor Yellow
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\StaleDNS_{0}.html" -f $stamp)
$rows = ($results | Sort-Object Zone, HostName | ForEach-Object {
    "<tr><td>$($_.HostName)</td><td>$($_.Zone)</td><td>$($_.IPAddress)</td><td>$($_.ADStatus)</td><td>$($_.Timestamp)</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>Stale DNS Records — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left} th{background:#f0f0f0}</style>
</head><body>
<h1>Stale DNS Records (no ping response)</h1>
<p>$stamp &nbsp; $($results.Count) record(s) flagged for review — nothing has been removed.</p>
<table><tr><th>Host</th><th>Zone</th><th>IP</th><th>AD status</th><th>Record timestamp</th></tr>
$rows
</table>
<p>To remove specific records after review: <code>.\Get-StaleDNSRecords.ps1 -ZoneName &lt;zone&gt; -RecordsToRemove name1,name2 -WhatIf</code></p>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
Write-Log "$($results.Count) record(s) flagged for review. Nothing was removed." 'WARN'
