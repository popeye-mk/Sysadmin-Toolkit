<#
.SYNOPSIS
    Extract a Microsoft "Administrative Templates (.admx)" package and deploy it
    into your domain's Group Policy Central Store (SYSVOL), backing up whatever
    is already there first.

.DESCRIPTION
    Without a Central Store, every admin editing GPOs sees whatever ADMX/ADML
    ships with their own Windows build — inconsistent, and missing anything
    newer (like Windows Server 2025 / Windows 11 24H2+ policies). This script
    fixes that in one step:

      1. If you point it at the downloaded MSI (-SourceMsi), it runs a silent
         *administrative* install (msiexec /a) to unpack the ADMX/ADML files
         without actually installing anything on this machine, then finds the
         resulting PolicyDefinitions folder on its own.
         (If you already extracted/installed it yourself, skip straight to
         step 2 with -SourcePolicyDefinitions instead.)
      2. Backs up the domain's current Central Store (if one already exists)
         to a local, timestamped folder under Backups\.
      3. Creates the Central Store if it doesn't exist yet (that's literally
         what "activates" it domain-wide — Group Policy Management Console
         picks it up automatically, no restart needed), then copies the new
         ADMX/ADML files in. Existing files for templates you're not touching
         are left alone.

    Run this from a machine that can reach SYSVOL on a writable DC (normally
    a domain-joined admin workstation or a DC itself), signed in as a Domain
    Admin (or delegated with write access to
    \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions).

.PARAMETER SourceMsi
    Path to the downloaded "Administrative Templates (.admx) for ..." MSI.
    Mutually exclusive with -SourcePolicyDefinitions.
.PARAMETER SourcePolicyDefinitions
    Path to an already-extracted PolicyDefinitions folder (skips the MSI
    extraction step entirely). Mutually exclusive with -SourceMsi.
.PARAMETER ExtractPath
    Where to unpack -SourceMsi to. Default: a timestamped folder under this
    toolkit's Backups directory (kept, not cleaned up, so you can inspect it).
.PARAMETER DomainDns
    Domain FQDN, e.g. 'contoso.local'. Default: auto-detected from this
    machine's domain membership.
.PARAMETER SkipBackup
    Skip backing up the existing Central Store before overwriting. Not
    recommended — the backup is local and cheap; leave this off.

.EXAMPLE
    .\Deploy-GPOCentralStore.ps1 -SourceMsi 'C:\Downloads\Administrative Templates (.admx) for Windows Server2025 Oct 2025 Update-V3.msi' -WhatIf

.EXAMPLE
    .\Deploy-GPOCentralStore.ps1 -SourceMsi 'C:\Downloads\...msi' -DomainDns contoso.local

.EXAMPLE
    # Already extracted / installed it yourself:
    .\Deploy-GPOCentralStore.ps1 -SourcePolicyDefinitions 'C:\Program Files (x86)\Microsoft Group Policy\Windows Server 2025 Oct 2025 Update (.admx)\PolicyDefinitions'

.NOTES
    Run as a Domain Admin (or equivalent delegated rights on SYSVOL). Needs
    line-of-sight to a writable domain controller. Change replicates to other
    DCs via normal SYSVOL replication (DFSR) — allow a few minutes on a
    multi-DC domain before it shows everywhere.

    This script only ever ADDS/UPDATES files in the Central Store; it never
    deletes anything that's already there, and it always backs up first
    unless you pass -SkipBackup. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'FromMsi')]
param(
    [Parameter(ParameterSetName = 'FromMsi')]
    [string]$SourceMsi,

    [Parameter(Mandatory, ParameterSetName = 'FromFolder')]
    [string]$SourcePolicyDefinitions,

    [string]$ExtractPath,

    [string]$DomainDns,

    [switch]$SkipBackup,
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
if (-not $PSBoundParameters.ContainsKey('SourceMsi')) { $__v = Get-ToolkitSetting 'GPO.AdmxMsi' -File; if ($null -ne $__v) { $SourceMsi = $__v; $__cfgUsed += 'GPO.AdmxMsi' } }
if (-not $PSBoundParameters.ContainsKey('DomainDns')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DomainDns'; if ($null -ne $__v) { $DomainDns = $__v; $__cfgUsed += 'ActiveDirectory.DomainDns' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $SourceMsi -and -not $SourcePolicyDefinitions) { Write-Host "  [ERROR] Missing: -SourceMsi <ADMX .msi> or -SourcePolicyDefinitions <folder> (or GPO.AdmxMsi in Config)" -ForegroundColor Red; return }


# --- standalone-safe logging (no dependency on _Common) ----------------------
function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Backups', 'Logs')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}
function Test-Admin {
    try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: GPO Central Store Deploy" -ForegroundColor White
Write-Host "  =============================================" -ForegroundColor DarkGray

if (-not (Test-Admin)) {
    Write-Log "Not running elevated. The msiexec extraction step doesn't strictly need it, but writing to SYSVOL needs Domain Admin (or delegated) rights on the account you're signed in as — this is about your DOMAIN permissions, not local admin." 'WARN'
}

$toolkitRoot = Get-ToolkitRoot

# --- Step 1: get a PolicyDefinitions folder -----------------------------------
$sourcePolicyDefs = $null

if ($PSCmdlet.ParameterSetName -eq 'FromFolder') {
    if (-not (Test-Path $SourcePolicyDefinitions)) {
        Write-Log "Folder not found: $SourcePolicyDefinitions" 'ERROR'; return
    }
    $sourcePolicyDefs = (Resolve-Path $SourcePolicyDefinitions).Path
    Write-Log "Using already-extracted folder: $sourcePolicyDefs" 'INFO'
}
else {
    if (-not (Test-Path $SourceMsi)) {
        Write-Log "MSI not found: $SourceMsi" 'ERROR'; return
    }
    $SourceMsi = (Resolve-Path $SourceMsi).Path

    if (-not $ExtractPath) {
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $ExtractPath = Join-Path $toolkitRoot ("Backups\AdmxExtract_{0}" -f $stamp)
    }

    Write-Log "Source MSI  : $SourceMsi" 'INFO'
    Write-Log "Extract to  : $ExtractPath" 'INFO'

    if ($PSCmdlet.ShouldProcess($SourceMsi, "Administrative install (extract only) to $ExtractPath")) {
        if (-not (Test-Path $ExtractPath)) { New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null }
        $logPath = Join-Path $toolkitRoot ("Logs\AdmxExtract_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))

        # /a = administrative install: unpacks the package's files to TARGETDIR
        # without installing/registering anything on this machine.
        $msiArgs = @(
            '/a', "`"$SourceMsi`"",
            '/qn',
            "TARGETDIR=`"$ExtractPath`"",
            '/l*v', "`"$logPath`""
        )
        Write-Log "Running: msiexec.exe $($msiArgs -join ' ')" 'STEP'
        $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) {
            Write-Log "msiexec exited with code $($p.ExitCode). Full log: $logPath" 'ERROR'
            Write-Log "If this keeps failing, try running the MSI normally (double-click), let it install to its default folder, then re-run this script with -SourcePolicyDefinitions pointing at the PolicyDefinitions folder it created." 'INFO'
            return
        }
        Write-Log "Extraction completed (exit 0)." 'OK'

        $found = Get-ChildItem -Path $ExtractPath -Recurse -Directory -Filter 'PolicyDefinitions' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            Write-Log "Extraction succeeded but no 'PolicyDefinitions' folder was found under $ExtractPath. Check $logPath, or browse $ExtractPath by hand and re-run with -SourcePolicyDefinitions." 'ERROR'
            return
        }
        $sourcePolicyDefs = $found.FullName
        Write-Log "Found PolicyDefinitions: $sourcePolicyDefs" 'OK'
    }
    else {
        # -WhatIf: nothing was actually extracted, so there's nothing further to preview.
        Write-Log "WhatIf: would extract $SourceMsi to $ExtractPath, then continue to the Central Store copy." 'INFO'
        return
    }
}

$admxCount = (Get-ChildItem -Path $sourcePolicyDefs -Filter '*.admx' -File -ErrorAction SilentlyContinue | Measure-Object).Count
if ($admxCount -eq 0) {
    Write-Log "No .admx files found directly in $sourcePolicyDefs — that doesn't look like a PolicyDefinitions folder. Aborting." 'ERROR'
    return
}
$langFolders = Get-ChildItem -Path $sourcePolicyDefs -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
Write-Log "Source has $admxCount .admx file(s) and $($langFolders.Count) language folder(s): $($langFolders -join ', ')" 'INFO'

# --- Step 2: work out the domain + Central Store path -------------------------
if (-not $DomainDns) {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.PartOfDomain) { $DomainDns = $cs.Domain }
}
if (-not $DomainDns) {
    Write-Log "Could not auto-detect a domain (this machine may not be domain-joined). Pass -DomainDns explicitly, e.g. -DomainDns contoso.local" 'ERROR'
    return
}

$centralStore = "\\{0}\SYSVOL\{0}\Policies\PolicyDefinitions" -f $DomainDns
Write-Log "Domain        : $DomainDns" 'INFO'
Write-Log "Central Store : $centralStore" 'INFO'

$storeExists = Test-Path $centralStore
if (-not $storeExists) {
    Write-Log "No Central Store found yet — this run will CREATE it (that's what activates it domain-wide)." 'WARN'
}

# --- Step 3: back up whatever's already there ----------------------------------
if ($storeExists -and -not $SkipBackup) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $backupDest = Join-Path $toolkitRoot ("Backups\CentralStore_{0}" -f $stamp)
    if ($PSCmdlet.ShouldProcess($centralStore, "Back up existing Central Store to $backupDest")) {
        try {
            Copy-Item -Path $centralStore -Destination $backupDest -Recurse -Force -ErrorAction Stop
            Write-Log "Backed up existing Central Store -> $backupDest" 'OK'
        } catch {
            Write-Log "Backup failed: $($_.Exception.Message). Aborting rather than overwrite unbacked-up files — re-run with -SkipBackup only if you're sure." 'ERROR'
            return
        }
    }
} elseif ($storeExists -and $SkipBackup) {
    Write-Log "Skipping backup (-SkipBackup) — existing Central Store contents will be overwritten where names match." 'WARN'
}

# --- Step 4: copy in -------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($centralStore, "Copy $admxCount .admx file(s) + language folders ($($langFolders -join ', ')) from $sourcePolicyDefs")) {
    try {
        if (-not $storeExists) {
            New-Item -ItemType Directory -Path $centralStore -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path (Join-Path $sourcePolicyDefs '*') -Destination $centralStore -Recurse -Force -ErrorAction Stop
        Write-Log "Copied into Central Store." 'OK'
    } catch {
        Write-Log "Copy failed: $($_.Exception.Message)" 'ERROR'
        Write-Log "Check you have write access to SYSVOL on a writable DC, and that no file there is locked/open in GPMC." 'INFO'
        return
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Done. Open Group Policy Management on any admin workstation — it reads" -ForegroundColor Green
    Write-Host "  the Central Store automatically, no restart needed." -ForegroundColor Green
    Write-Host "  On a multi-DC domain, allow a few minutes for SYSVOL/DFSR replication" -ForegroundColor White
    Write-Host "  before every DC has the update." -ForegroundColor White
}
