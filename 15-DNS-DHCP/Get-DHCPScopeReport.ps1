<#
.SYNOPSIS
    DHCP scope utilization report — catches "why can't anyone get an IP"
    before it happens, not during.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Queries
    one or more DHCP servers for their IPv4 scopes and per-scope statistics
    (addresses in use / free / % utilization), flags anything over a warning
    threshold, and writes an HTML report.

.PARAMETER ComputerName
    DHCP server(s) to query. Default: every authorized DHCP server found in
    AD (via Get-DhcpServerInDC) if the DHCP module supports it, else localhost.
.PARAMETER WarningPercent
    Flag a scope at or above this utilization (default 80).
.PARAMETER CriticalPercent
    Flag a scope at or above this utilization as critical (default 90).

.EXAMPLE
    .\Get-DHCPScopeReport.ps1
.EXAMPLE
    .\Get-DHCPScopeReport.ps1 -ComputerName dhcp01.contoso.local -WarningPercent 75

.NOTES
    Needs the DhcpServer module (RSAT: DHCP Server Tools) and read rights on
    the target DHCP server(s). Read-only. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [int]$WarningPercent = 80,
    [int]$CriticalPercent = 90
)

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
if (-not $PSBoundParameters.ContainsKey('ComputerName')) { $__v = Get-ToolkitSetting 'Network.DhcpServers'; if ($null -ne $__v) { $ComputerName = $__v; $__cfgUsed += 'Network.DhcpServers' } }
if (-not $PSBoundParameters.ContainsKey('WarningPercent')) { $__v = Get-ToolkitSetting 'Network.DhcpWarnPercent'; if ($null -ne $__v) { $WarningPercent = $__v; $__cfgUsed += 'Network.DhcpWarnPercent' } }
if (-not $PSBoundParameters.ContainsKey('CriticalPercent')) { $__v = Get-ToolkitSetting 'Network.DhcpCritPercent'; if ($null -ne $__v) { $CriticalPercent = $__v; $__cfgUsed += 'Network.DhcpCritPercent' } }
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

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: DHCP Scope Report" -ForegroundColor White
Write-Host "  ======================================" -ForegroundColor DarkGray

if (-not (Get-Module -ListAvailable DhcpServer)) {
    Write-Log "DhcpServer module not found (install RSAT: DHCP Server Tools)." 'ERROR'; return
}
Import-Module DhcpServer -ErrorAction Stop

if (-not $ComputerName) {
    try { $ComputerName = (Get-DhcpServerInDC -ErrorAction Stop).DnsName }
    catch { $ComputerName = @($env:COMPUTERNAME); Write-Log "Could not query AD for authorized DHCP servers — falling back to local machine. Pass -ComputerName to target specific server(s)." 'WARN' }
}
if (-not $ComputerName -or $ComputerName.Count -eq 0) { $ComputerName = @($env:COMPUTERNAME) }

Write-Log "DHCP server(s): $($ComputerName -join ', ')" 'INFO'

$rows = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($server in $ComputerName) {
    try {
        $scopes = @(Get-DhcpServerv4Scope -ComputerName $server -ErrorAction Stop)
    } catch {
        Write-Log "Could not query ${server}: $($_.Exception.Message)" 'WARN'
        continue
    }
    foreach ($scope in $scopes) {
        try {
            $stats = Get-DhcpServerv4ScopeStatistics -ComputerName $server -ScopeId $scope.ScopeId -ErrorAction Stop
        } catch {
            Write-Log "Could not get statistics for scope $($scope.ScopeId) on ${server}: $($_.Exception.Message)" 'WARN'
            continue
        }
        $pct = [math]::Round($stats.PercentageInUse, 1)
        $status = if ($pct -ge $CriticalPercent) { 'CRITICAL' } elseif ($pct -ge $WarningPercent) { 'WARNING' } else { 'OK' }
        $rows.Add([pscustomobject]@{
            Server     = $server
            ScopeId    = $scope.ScopeId
            Name       = $scope.Name
            State      = $scope.State
            InUse      = $stats.AddressesInUse
            Free       = $stats.AddressesFree
            PercentUse = $pct
            Status     = $status
        })
    }
}

if (-not $rows.Count) { Write-Log "No scopes found across the target server(s)." 'WARN'; return }

Write-Host ''
foreach ($r in $rows | Sort-Object PercentUse -Descending) {
    $color = @{ CRITICAL = 'Red'; WARNING = 'Yellow'; OK = 'Green' }[$r.Status]
    Write-Host ("  [{0,-8}] {1,-15} {2,-25} {3,5}% used  ({4} in use / {5} free)" -f $r.Status, $r.Server, $r.Name, $r.PercentUse, $r.InUse, $r.Free) -ForegroundColor $color
}

$critical = @($rows | Where-Object Status -eq 'CRITICAL')
$warning  = @($rows | Where-Object Status -eq 'WARNING')

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\DHCPScopes_{0}.html" -f $stamp)
$tableRows = ($rows | Sort-Object PercentUse -Descending | ForEach-Object {
    "<tr class='$($_.Status.ToLower())'><td>$($_.Server)</td><td>$($_.ScopeId)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Name))</td><td>$($_.State)</td><td>$($_.InUse)</td><td>$($_.Free)</td><td>$($_.PercentUse)%</td><td>$($_.Status)</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>DHCP Scope Report — $stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left}
th{background:#f0f0f0} .critical td{background:#fdecea;color:#c62828} .warning td{background:#fff8e1;color:#8a6d00}
</style></head><body>
<h1>DHCP Scope Report</h1>
<p>$stamp &nbsp; Warning: $WarningPercent% &nbsp; Critical: $CriticalPercent% &nbsp; Critical scopes: $($critical.Count) &nbsp; Warning scopes: $($warning.Count)</p>
<table><tr><th>Server</th><th>Scope</th><th>Name</th><th>State</th><th>In use</th><th>Free</th><th>% used</th><th>Status</th></tr>
$tableRows
</table>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
if ($critical.Count) { Write-Log "$($critical.Count) scope(s) critical (>=$CriticalPercent%)." 'ERROR' }
elseif ($warning.Count) { Write-Log "$($warning.Count) scope(s) at warning level (>=$WarningPercent%)." 'WARN' }
else { Write-Log "All scopes healthy." 'OK' }
