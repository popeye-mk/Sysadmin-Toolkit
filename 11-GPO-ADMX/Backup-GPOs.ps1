<#
.SYNOPSIS
    Back up every GPO in the domain, generate an HTML report of each one's
    settings, and flag any GPO whose version number changed since the last run.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit (including
    Deploy-GPOCentralStore.ps1 next to it; the two don't need each other).

    Three things in one run:
      1. Backup-GPO -All -> a dated folder. This is your restore point if a
         GPO gets broken or deleted — nothing here is a substitute for that.
      2. Get-GPOReport -> one HTML file per GPO, in the same dated folder, so
         you have a readable settings snapshot without opening GPMC.
      3. Lightweight change tracking: saves each GPO's version number to a
         small JSON file after every run, and on the NEXT run compares against
         it — so you get a short "these GPOs changed since last time" list
         without diffing full backups by hand.

.PARAMETER BackupRoot
    Where dated backup folders go. Default: this toolkit's Backups\GPO.
.PARAMETER SkipReport
    Skip the per-GPO HTML report generation (backup only — faster).

.EXAMPLE
    .\Backup-GPOs.ps1 -WhatIf
.EXAMPLE
    .\Backup-GPOs.ps1

.NOTES
    Run as a Domain Admin (or delegated GPO read + SYSVOL read) with the
    GroupPolicy module (RSAT: Group Policy Management). Read/backup only —
    nothing here modifies a live GPO. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string]$BackupRoot,
    [switch]$SkipReport
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
if (-not $PSBoundParameters.ContainsKey('BackupRoot')) { $__v = Get-ToolkitSetting 'GPO.BackupRoot'; if ($null -ne $__v) { $BackupRoot = $__v; $__cfgUsed += 'GPO.BackupRoot' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- standalone-safe helpers ---------------------------------------------------
function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    try { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } } catch { }
    return $p
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: GPO Backup + Report" -ForegroundColor White
Write-Host "  ========================================" -ForegroundColor DarkGray

if (-not (Get-Module -ListAvailable GroupPolicy)) {
    Write-Log "GroupPolicy module not found (install RSAT: Group Policy Management)." 'ERROR'; return
}
Import-Module GroupPolicy -ErrorAction Stop

$root = Get-ToolkitRoot
if (-not $BackupRoot) { $BackupRoot = Join-Path $root 'Backups\GPO' }
$versionFile = Join-Path $BackupRoot '_lastversions.json'

try { $allGpos = @(Get-GPO -All -ErrorAction Stop) }
catch { Write-Log "Could not enumerate GPOs: $($_.Exception.Message)" 'ERROR'; return }

if (-not $allGpos.Count) { Write-Log "No GPOs found in this domain." 'WARN'; return }
Write-Log "Found $($allGpos.Count) GPO(s)." 'INFO'

# --- change detection vs. last run ---------------------------------------------
$prevVersions = @{}
if (Test-Path $versionFile) {
    try { (Get-Content $versionFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $prevVersions[$_.Name] = $_.Value } }
    catch { Write-Log "Could not read previous version snapshot — treating this as a first run." 'WARN' }
}
$changed = New-Object System.Collections.Generic.List[string]
$currentVersions = @{}
foreach ($g in $allGpos) {
    $ver = "$($g.User.DSVersion).$($g.Computer.DSVersion)"
    $currentVersions[$g.Id.Guid] = $ver
    if ($prevVersions.ContainsKey($g.Id.Guid) -and $prevVersions[$g.Id.Guid] -ne $ver) {
        $changed.Add($g.DisplayName)
    }
}
if ($changed.Count) {
    Write-Log "Changed since last run: $($changed -join ', ')" 'WARN'
} elseif ($prevVersions.Count) {
    Write-Log "No GPO version changes since last run." 'OK'
} else {
    Write-Log "No previous snapshot found — this run establishes the baseline." 'INFO'
}

# --- backup ----------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$dest  = Join-Path $BackupRoot $stamp

if ($PSCmdlet.ShouldProcess($dest, "Backup all $($allGpos.Count) GPO(s)")) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    try {
        $results = Backup-GPO -All -Path $dest -ErrorAction Stop
        Write-Log "Backed up $($results.Count) GPO(s) -> $dest" 'OK'
    } catch {
        Write-Log "Backup failed: $($_.Exception.Message)" 'ERROR'; return
    }

    if (-not $SkipReport) {
        Write-Log "Generating HTML reports..." 'STEP'
        $reportDir = Join-Path $dest 'Reports'
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        foreach ($g in $allGpos) {
            $safeName = ($g.DisplayName -replace '[^\w\-]', '_')
            try { Get-GPOReport -Guid $g.Id -ReportType Html -Path (Join-Path $reportDir "$safeName.html") -ErrorAction Stop }
            catch { Write-Log "Report failed for $($g.DisplayName): $($_.Exception.Message)" 'WARN' }
        }
        Write-Log "Reports -> $reportDir" 'OK'
    }

    ($currentVersions | ConvertTo-Json) | Out-File -FilePath $versionFile -Encoding UTF8
    Write-Log "Saved version snapshot for next run's change detection." 'INFO'
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Backup + reports: $dest" -ForegroundColor Green
    if ($changed.Count) { Write-Host "  Changed since last run: $($changed -join ', ')" -ForegroundColor Yellow }
}
