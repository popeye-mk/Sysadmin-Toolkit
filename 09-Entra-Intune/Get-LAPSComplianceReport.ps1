<#
.SYNOPSIS
    Confirms Windows LAPS is actually rotating and escrowing local admin
    passwords fleet-wide — not just configured once and forgotten.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    _GraphCommon.psm1 next to it. Cross-references every Intune-managed
    Windows device against Graph's Windows LAPS escrow records and flags:
      - devices with NO escrowed credential at all (LAPS policy may not be
        applying, or the device has never checked in since it was assigned)
      - devices whose last backup is older than -StaleDays (rotation may
        have stopped working on that machine specifically)

    A note on this script's honesty: the Graph endpoint for Windows LAPS
    escrow records (deviceManagement/deviceLocalCredentials) is newer than
    most of the Graph surface this kit uses elsewhere, and Microsoft has
    moved things between /beta and /v1.0 before. This script calls /v1.0
    first and automatically retries against /beta if that 404s, and prints
    plainly which one actually worked. If BOTH fail, that's telling you
    something real (wrong permission, or the API shape has changed again) —
    it will say so rather than silently showing an empty, misleadingly-clean
    report. Verify against current Microsoft Learn docs for your tenant if
    this ever looks wrong.

.PARAMETER StaleDays
    Flag an escrowed credential whose last backup is older than this many
    days (default 30 — Windows LAPS' default rotation is more frequent than
    that, so anything past 30 days usually means rotation stopped working).
.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Get-LAPSComplianceReport.ps1
.EXAMPLE
    .\Get-LAPSComplianceReport.ps1 -StaleDays 45

.NOTES
    Requires Microsoft.Graph.Authentication and
    DeviceLocalCredential.Read.All (or ReadBasic.All) +
    DeviceManagementManagedDevices.Read.All. Read-only — this script never
    reads the actual escrowed passwords, only backup timestamps/metadata.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [int]$StaleDays = 30,
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
Write-Host "  Sysadmin-Toolkit :: Windows LAPS Compliance" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor DarkGray

$scopes = @('DeviceLocalCredential.Read.All', 'DeviceManagementManagedDevices.Read.All')
if (-not (Connect-ToolkitGraphStandalone -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

Write-Log "Fetching managed Windows devices..." 'STEP'
$devices = @(Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All -ErrorAction Stop)
Write-Log "$($devices.Count) Windows device(s) returned." 'INFO'
if (-not $devices.Count) { Write-Log "No Windows devices found." 'WARN'; return }

Write-Log "Fetching Windows LAPS escrow records..." 'STEP'
$lapsRecords = $null
$apiUsed = $null
foreach ($ver in @('v1.0', 'beta')) {
    try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/$ver/deviceManagement/deviceLocalCredentials?`$top=999" -ErrorAction Stop
        $lapsRecords = @($resp.value)
        $apiUsed = $ver
        break
    } catch {
        Write-Log "  /$ver/deviceManagement/deviceLocalCredentials failed: $($_.Exception.Message)" 'INFO'
    }
}

if (-not $apiUsed) {
    Write-Log "Could not reach the Windows LAPS escrow endpoint on either /v1.0 or /beta. This could mean: the permission wasn't granted, Windows LAPS isn't set up in this tenant, or Microsoft has changed the API shape again — check current Microsoft Learn docs for 'deviceLocalCredentials'." 'ERROR'
    return
}
Write-Log "Using /$apiUsed — $($lapsRecords.Count) escrow record(s) found." 'OK'

# index escrow records by device id (property name has varied historically — cover both seen forms)
$byDeviceId = @{}
foreach ($r in $lapsRecords) {
    $id = if ($r.deviceId) { $r.deviceId } elseif ($r.id) { $r.id } else { $null }
    if ($id) { $byDeviceId[$id] = $r }
}

$now = Get-Date
$rows = foreach ($d in $devices) {
    $rec = $byDeviceId[$d.AzureAdDeviceId]
    $lastBackup = $null
    if ($rec) {
        $lastBackup = if ($rec.lastBackupDateTime) { [datetime]$rec.lastBackupDateTime } elseif ($rec.backupDateTime) { [datetime]$rec.backupDateTime } else { $null }
    }
    $daysSince = if ($lastBackup) { [math]::Round(($now - $lastBackup).TotalDays, 1) } else { $null }
    [pscustomobject]@{
        DeviceName  = $d.DeviceName
        HasEscrow   = [bool]$rec
        LastBackup  = if ($lastBackup) { $lastBackup.ToString('yyyy-MM-dd HH:mm') } else { 'never' }
        DaysSince   = $daysSince
        Stale       = ($rec -and (($null -eq $daysSince) -or ($daysSince -gt $StaleDays)))
        NoEscrow    = -not $rec
    }
}

$noEscrow = @($rows | Where-Object NoEscrow)
$stale    = @($rows | Where-Object Stale)

$rows | Sort-Object @{e={-not $_.NoEscrow}}, @{e={-not $_.Stale}}, DeviceName | Format-Table DeviceName, HasEscrow, LastBackup, DaysSince, Stale -AutoSize | Out-Host
Write-Host ''
Write-Host "  No escrow record: $($noEscrow.Count)   Stale (>$StaleDays d): $($stale.Count)   Total: $($rows.Count)" -ForegroundColor $(if (-not $noEscrow.Count -and -not $stale.Count) { 'Green' } else { 'Yellow' })

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$htmlOut = Join-Path $OutputPath "LAPSCompliance_$stamp.html"
$csvOut  = Join-Path $OutputPath "LAPSCompliance_$stamp.csv"
$rowsHtml = ($rows | Sort-Object @{e={-not $_.NoEscrow}}, @{e={-not $_.Stale}}, DeviceName | ForEach-Object {
    $cls = if ($_.NoEscrow) { 'noescrow' } elseif ($_.Stale) { 'stale' } else { '' }
    "<tr class='$cls'><td>$($_.DeviceName)</td><td>$($_.HasEscrow)</td><td>$($_.LastBackup)</td><td>$($_.DaysSince)</td></tr>"
}) -join "`n"
$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Windows LAPS compliance</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1e2327}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e2e8f0;padding:6px 9px;text-align:left}
th{background:#f5f8fc}.noescrow td{background:#fdecea;color:#b91c1c}.stale td{background:#fff8e1;color:#8a6d00}</style>
</head><body>
<h1>Windows LAPS compliance</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') via Graph /$apiUsed · no escrow: $($noEscrow.Count) · stale (&gt;$StaleDays d): $($stale.Count) · total $($rows.Count)</p>
<table><tr><th>Device</th><th>Has escrow</th><th>Last backup</th><th>Days since</th></tr>$rowsHtml</table>
<p style="color:#6b7280;font-size:12px">Read-only — actual escrowed passwords are never fetched by this script. "No escrow" can also mean the device hasn't checked in since LAPS policy was assigned; cross-check with Get-IntuneDeviceCompliance.ps1's staleness column if unsure.</p>
</body></html>
"@
$html | Set-Content -Path $htmlOut -Encoding UTF8
$rows | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
Write-Log "HTML: $htmlOut" 'OK'
Write-Log "CSV : $csvOut" 'OK'
