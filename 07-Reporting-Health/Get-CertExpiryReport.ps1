<#
.SYNOPSIS
    Scan certificate stores for anything expired or expiring soon — the RDP
    listener cert, an internal web/app cert, an LDAPS cert — before it surprises
    you.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Checks the
    local machine's certificate stores by default; pass -ComputerName to check
    one or more remote machines instead (uses PowerShell remoting).

    This is a certificate-STORE scan, not a full PKI/CA audit: it tells you
    what's installed and when it expires, which covers the vast majority of
    "why did RDP/IIS/a service suddenly break" incidents. It does not walk
    your internal CA's issued-certificate database — if you run AD CS, that's
    a separate, CA-side report.

.PARAMETER WarningDays
    Flag anything expiring within this many days (default 30).
.PARAMETER Stores
    Certificate store paths to check (default: the ones that actually matter
    day to day — My, WebHosting, Remote Desktop).
.PARAMETER ComputerName
    One or more remote machines to check instead of (or in addition to) local.
    Uses Invoke-Command — needs PowerShell remoting enabled on the target.
.PARAMETER IncludeExpired
    Also list certs that have already expired (on by default — this switch
    exists only for symmetry/clarity; expired certs are always the most
    important thing this script finds).

.EXAMPLE
    .\Get-CertExpiryReport.ps1
.EXAMPLE
    .\Get-CertExpiryReport.ps1 -WarningDays 60 -ComputerName SRV-RDS01,SRV-APP02

.NOTES
    Read-only. Remote checks need WinRM enabled on the target and rights to
    query its cert store. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [int]$WarningDays = 30,
    [string[]]$Stores = @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\WebHosting', 'Cert:\LocalMachine\Remote Desktop'),
    [string[]]$ComputerName,
    [switch]$IncludeExpired
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
if (-not $PSBoundParameters.ContainsKey('WarningDays')) { $__v = Get-ToolkitSetting 'Reports.CertWarningDays'; if ($null -ne $__v) { $WarningDays = $__v; $__cfgUsed += 'Reports.CertWarningDays' } }
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
Write-Host "  Sysadmin-Toolkit :: Certificate Expiry Report" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor DarkGray

$scanBlock = {
    param($Stores, $WarningDays)
    $now = Get-Date
    $found = @()
    foreach ($storePath in $Stores) {
        if (-not (Test-Path $storePath)) { continue }
        Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue | ForEach-Object {
            $daysLeft = [int]($_.NotAfter - $now).TotalDays
            if ($daysLeft -le $WarningDays) {
                $found += [pscustomobject]@{
                    Store      = $storePath
                    Subject    = $_.Subject
                    Thumbprint = $_.Thumbprint
                    NotAfter   = $_.NotAfter
                    DaysLeft   = $daysLeft
                    Status     = if ($daysLeft -lt 0) { 'EXPIRED' } elseif ($daysLeft -le 7) { 'CRITICAL' } else { 'WARNING' }
                }
            }
        }
    }
    return $found
}

$allResults = New-Object System.Collections.Generic.List[pscustomobject]

if ($ComputerName) {
    foreach ($cn in $ComputerName) {
        Write-Log "Scanning $cn..." 'STEP'
        try {
            $r = Invoke-Command -ComputerName $cn -ScriptBlock $scanBlock -ArgumentList (,$Stores), $WarningDays -ErrorAction Stop
            $r | ForEach-Object { $_ | Add-Member -NotePropertyName ComputerName -NotePropertyValue $cn -PassThru } | ForEach-Object { $allResults.Add($_) }
        } catch {
            Write-Log "Could not reach ${cn}: $($_.Exception.Message)" 'WARN'
        }
    }
} else {
    Write-Log "Scanning local machine ($env:COMPUTERNAME)..." 'STEP'
    & $scanBlock -Stores $Stores -WarningDays $WarningDays | ForEach-Object {
        $_ | Add-Member -NotePropertyName ComputerName -NotePropertyValue $env:COMPUTERNAME -PassThru
    } | ForEach-Object { $allResults.Add($_) }
}

if (-not $allResults.Count) {
    Write-Log "Nothing expiring within $WarningDays day(s). All clear." 'OK'
    return
}

$expired = @($allResults | Where-Object { $_.Status -eq 'EXPIRED' })
$critical = @($allResults | Where-Object { $_.Status -eq 'CRITICAL' })
$warning = @($allResults | Where-Object { $_.Status -eq 'WARNING' })

Write-Host ''
foreach ($r in $allResults | Sort-Object DaysLeft) {
    $color = @{ EXPIRED = 'Red'; CRITICAL = 'Red'; WARNING = 'Yellow' }[$r.Status]
    Write-Host ("  [{0,-8}] {1,-15} {2,5} day(s)  {3}  ({4})" -f $r.Status, $r.ComputerName, $r.DaysLeft, $r.Subject, $r.Store) -ForegroundColor $color
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\CertExpiry_{0}.html" -f $stamp)
$rows = ($allResults | Sort-Object DaysLeft | ForEach-Object {
    "<tr class='$($_.Status.ToLower())'><td>$($_.ComputerName)</td><td>$([System.Net.WebUtility]::HtmlEncode($_.Subject))</td><td>$($_.Store)</td><td>$($_.NotAfter)</td><td>$($_.DaysLeft)</td><td>$($_.Status)</td><td>$($_.Thumbprint)</td></tr>"
}) -join "`n"

$html = @"
<html><head><title>Certificate Expiry Report — $stamp</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left;font-size:.9em}
th{background:#f0f0f0}
.expired td, .critical td{background:#fdecea;color:#c62828} .warning td{background:#fff8e1;color:#8a6d00}
</style></head><body>
<h1>Certificate Expiry Report</h1>
<p>$stamp &nbsp; Warning threshold: $WarningDays day(s) &nbsp; Expired: $($expired.Count) &nbsp; Critical (&le;7d): $($critical.Count) &nbsp; Warning: $($warning.Count)</p>
<table><tr><th>Computer</th><th>Subject</th><th>Store</th><th>Expires</th><th>Days left</th><th>Status</th><th>Thumbprint</th></tr>
$rows
</table>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
if ($expired.Count -or $critical.Count) { Write-Log "$($expired.Count) expired, $($critical.Count) critical (<=7 days)." 'ERROR' }
else { Write-Log "$($warning.Count) certificate(s) approaching expiry." 'WARN' }
