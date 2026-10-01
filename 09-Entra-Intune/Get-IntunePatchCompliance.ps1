<#
.SYNOPSIS
    Fleet-wide Windows build/patch level report — which machines are behind,
    relative to the rest of your own fleet.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    _GraphCommon.psm1 next to it or Get-IntuneDeviceCompliance.ps1's Intune
    "compliance policy" pass/fail state (a different thing — that's whether a
    device meets your configured compliance rules; this is about actual OS
    build/patch level).

    Honest about its own limits: this does NOT compare against Microsoft's
    release schedule (there's no reliable way to hardcode "the current build"
    here — that goes stale the moment a new cumulative update ships, the
    exact mistake this kit's Zabbix section deliberately avoided for the
    agent installer URL). Instead it compares every device's OS build number
    against the NEWEST build already seen elsewhere in YOUR fleet, per
    Windows major version (10 vs 11) — so it flags real outliers: the
    machines behind everyone else, which is almost always the thing you
    actually want to act on first.

.PARAMETER ThresholdBuilds
    Flag a device whose build number is behind its version's fleet-newest by
    at least this many builds (default 100 — Windows builds increment by
    roughly that much between monthly cumulative updates, so this catches
    "hasn't updated in ~1+ months relative to the rest of the fleet").
.PARAMETER StaleDays
    Also flag devices that haven't checked in within this many days (default
    14) — a device that's simply not reporting looks the same as one that's
    behind, worth telling apart in the report.
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Get-IntunePatchCompliance.ps1
.EXAMPLE
    .\Get-IntunePatchCompliance.ps1 -ThresholdBuilds 50

.NOTES
    Requires Microsoft.Graph.DeviceManagement and DeviceManagementManagedDevices.Read.All.
    Read-only. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [int]$ThresholdBuilds = 100,
    [int]$StaleDays = 14,
    [string]$OutputPath
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
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
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
function Connect-ToolkitGraphStandalone {
    param([string[]]$Scopes)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'
        return $false
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru -ErrorAction SilentlyContinue | Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) { return $true }
    try { Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null; return $true }
    catch { Write-Log "Graph connect failed: $($_.Exception.Message)" 'ERROR'; return $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Intune Patch Compliance" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor DarkGray

if (-not (Connect-ToolkitGraphStandalone -Scopes @('DeviceManagementManagedDevices.Read.All'))) { return }
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

Write-Log "Fetching managed Windows devices..." 'STEP'
$devices = @(Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All -ErrorAction Stop)
Write-Log "$($devices.Count) Windows device(s) returned." 'INFO'
if (-not $devices.Count) { Write-Log "No Windows devices found." 'WARN'; return }

# --- parse OS version -> major (10/11) + build number, and find each version's fleet-newest build ---
function Get-BuildInfo {
    param([string]$OsVersion)
    # osVersion typically looks like "10.0.22631.4602"
    if ($OsVersion -match '^10\.0\.(\d+)(?:\.(\d+))?') {
        $build = [int]$Matches[1]
        $major = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        return [pscustomobject]@{ Major = $major; Build = $build }
    }
    return [pscustomobject]@{ Major = 'Unknown'; Build = 0 }
}

$now = Get-Date
$parsed = foreach ($d in $devices) {
    $info = Get-BuildInfo -OsVersion $d.OsVersion
    $lastSync = $d.LastSyncDateTime
    $daysSinceSync = if ($lastSync) { [math]::Round(($now - $lastSync).TotalDays, 1) } else { $null }
    [pscustomobject]@{
        DeviceName    = $d.DeviceName
        Owner         = $d.UserPrincipalName
        OsVersion     = $d.OsVersion
        Major         = $info.Major
        Build         = $info.Build
        LastSync      = if ($lastSync) { $lastSync.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        DaysSinceSync = $daysSinceSync
        Stale         = ($null -eq $daysSinceSync) -or ($daysSinceSync -gt $StaleDays)
    }
}

$fleetNewest = @{}
$parsed | Where-Object { $_.Major -ne 'Unknown' } | Group-Object Major | ForEach-Object {
    $fleetNewest[$_.Name] = ($_.Group | Measure-Object -Property Build -Maximum).Maximum
}
Write-Log "Fleet-newest build seen — $((@($fleetNewest.GetEnumerator()) | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', ')" 'INFO'

$rows = $parsed | ForEach-Object {
    $newest = if ($fleetNewest.ContainsKey($_.Major)) { $fleetNewest[$_.Major] } else { $_.Build }
    $behindBy = $newest - $_.Build
    $_ | Add-Member -NotePropertyName BehindBy -NotePropertyValue $behindBy -PassThru |
         Add-Member -NotePropertyName BehindFlag -NotePropertyValue ($behindBy -ge $ThresholdBuilds) -PassThru
}

$behindCount = @($rows | Where-Object BehindFlag).Count
$staleCount  = @($rows | Where-Object Stale).Count

$rows | Sort-Object BehindBy -Descending | Format-Table DeviceName, Owner, Major, Build, BehindBy, LastSync, Stale -AutoSize | Out-Host
Write-Host ''
Write-Host "  Behind fleet (>=$ThresholdBuilds builds): $behindCount   Stale (>$StaleDays d): $staleCount   Total: $($rows.Count)" -ForegroundColor $(if ($behindCount -eq 0) { 'Green' } else { 'Yellow' })

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "IntunePatchCompliance_$stamp.html"
$csvOut  = Join-Path $OutputPath "IntunePatchCompliance_$stamp.csv"
$rowsHtml = ($rows | Sort-Object BehindBy -Descending | ForEach-Object {
    $cls = if ($_.BehindFlag) { 'behind' } elseif ($_.Stale) { 'stale' } else { '' }
    "<tr class='$cls'><td>$($_.DeviceName)</td><td>$($_.Owner)</td><td>$($_.Major)</td><td>$($_.Build)</td><td>$($_.BehindBy)</td><td>$($_.LastSync)</td></tr>"
}) -join "`n"
$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Intune patch compliance</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}
th{background:#f5f8fc}.behind td{background:#fdecea;color:#b91c1c}.stale td{background:#fff8e1;color:#8a6d00}</style>
</head><body>
<h1>Intune patch compliance (relative to your own fleet)</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') · behind &ge;$ThresholdBuilds builds: $behindCount · stale (&gt;$StaleDays d): $staleCount · total $($rows.Count)</p>
<table><tr><th>Device</th><th>Owner</th><th>Version</th><th>Build</th><th>Behind by</th><th>Last sync</th></tr>$rowsHtml</table>
<p style="color:#6b7280;font-size:12px">"Behind by" is relative to the newest build already seen elsewhere in this fleet for the same Windows version — not an absolute check against Microsoft's release schedule.</p>
</body></html>
"@
$html | Set-Content -Path $htmlOut -Encoding UTF8
$rows | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Log "HTML: $htmlOut" 'OK'
Write-Log "CSV : $csvOut" 'OK'
