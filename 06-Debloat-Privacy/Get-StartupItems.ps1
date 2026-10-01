<#
.SYNOPSIS
    List everything that runs at startup (Run keys, Startup folders, scheduled
    logon tasks) and optionally disable an entry — the fast "why is this PC slow
    to boot" tool.

.DESCRIPTION
    Read-only by default. Enumerates:
      - HKLM + HKCU  ...\CurrentVersion\Run  and  RunOnce
      - The per-user and common Startup folders
      - Scheduled tasks that trigger at logon
    Shows name, command, and source. With -Disable <name> it disables a single
    Run-key entry by moving it to a backup key (reversible), so you can knock
    out one offender without a third-party tool.

.PARAMETER Disable
    Name of a Run-key entry to disable (moved to a *_disabled_toolkit key).
.PARAMETER Scope
    'HKCU' or 'HKLM' — which hive the -Disable entry lives in (default HKCU).
.PARAMETER OutputPath
    Report folder for the CSV. Default: toolkit Reports folder.

.EXAMPLE
    .\Get-StartupItems.ps1
.EXAMPLE
    .\Get-StartupItems.ps1 -Disable "Spotify" -Scope HKCU -WhatIf

.NOTES
    -Disable on an HKLM entry needs admin. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$Disable,
    [ValidateSet('HKCU', 'HKLM')][string]$Scope = 'HKCU',
    [string]$OutputPath,
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
if (-not $PSBoundParameters.ContainsKey('OutputPath')) { $__v = Get-ToolkitSetting 'Reports.OutputPath'; if ($null -ne $__v) { $OutputPath = $__v; $__cfgUsed += 'Reports.OutputPath' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- toolkit helpers (standalone-safe) -------------------------------------
# Uses the shared _Common module when run inside the kit. If this script is
# copied out on its own, it self-provides the same helpers so it still runs.
$__common = Join-Path $PSScriptRoot '..\_Common\SysadminToolkit.Common.psm1'
if (Test-Path $__common) {
    Import-Module $__common -Force
} else {
    function Get-ToolkitRoot { param([string]$Path = 'C:\Sysadmin-Toolkit')
        try { foreach ($s in @('','Reports','Backups','Logs')) { $p = if ($s) { Join-Path $Path $s } else { $Path }; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } } } catch { }
        return $Path }
    function Write-Log { param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
        $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
        Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
        try { $lf = Join-Path (Get-ToolkitRoot) ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')); Add-Content -Path $lf -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { } }
    function Write-Banner { param([Parameter(Mandatory)][string]$Title) Write-Host ''; Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White; Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray }
    function Test-Admin { try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } }
    function Assert-Admin { if (Test-Admin) { return $true } Write-Log 'This tool needs Administrator rights. Right-click PowerShell and Run as administrator.' 'ERROR'; return $false }
    function Confirm-Action { param([Parameter(Mandatory)][string]$Question) if ($script:__ntForce) { return $true } if (-not [Environment]::UserInteractive -or $null -eq $Host.UI.RawUI) { return $false } (Read-Host "$Question [y/N]") -match '^(y|yes)$' }
    function New-StrongPassword { param([int]$Length=16)
        $U='ABCDEFGHJKLMNPQRSTUVWXYZ'; $L='abcdefghijkmnpqrstuvwxyz'; $D='23456789'; $S='!@#$%^&*-_=+?'; $all=($U+$L+$D+$S).ToCharArray()
        $ch=@($U[(Get-Random -Maximum $U.Length)],$L[(Get-Random -Maximum $L.Length)],$D[(Get-Random -Maximum $D.Length)],$S[(Get-Random -Maximum $S.Length)])
        for ($i=$ch.Count; $i -lt $Length; $i++){ $ch += $all[(Get-Random -Maximum $all.Length)] }
        -join ($ch | Sort-Object { Get-Random }) }
    function Get-OSInfo { $o=Get-CimInstance Win32_OperatingSystem; $b=[int]$o.BuildNumber
        $t = if ($o.Caption -match 'Server') { 'Server' } elseif ($b -ge 22000) { 'Win11' } elseif ($b -ge 10240) { 'Win10' } else { 'Older' }
        [pscustomobject]@{ Caption=$o.Caption; Version=$o.Version; Build=$b; Tag=$t } }
    function Backup-RegistryKey { param([Parameter(Mandatory)][string]$Path,[string]$Label='key')
        $tag=(($Path -split '\\' | Select-Object -Last 2) -join '_') -replace '[^\w\-]','_'; $o=Join-Path (Get-ToolkitRoot) ("Backups\{0}_{1}_{2}.reg" -f ($Label -replace '[^\w\-]','_'),$tag,(Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        if (-not (Test-Path -LiteralPath "Registry::$Path")) { return $null }
        $rc = (Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $Path), ('"{0}"' -f $o), '/y') -Wait -PassThru -WindowStyle Hidden).ExitCode; if ($rc -eq 0) { Write-Log "Backed up $Path -> $o" 'OK'; return $o }; return $null }
    function Set-RegValue { [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Value,[ValidateSet('DWord','String','ExpandString','QWord','Binary')][string]$Type='DWord')
        if ($PSCmdlet.ShouldProcess("$Path\$Name","Set to $Value ($Type)")) { if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null; Write-Log "Set $Path\$Name = $Value" 'OK' } }
}
# ---------------------------------------------------------------------------
Write-Banner "Startup Items"
if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }

$items = New-Object System.Collections.Generic.List[object]
$runKeys = @(
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';     Src = 'HKLM Run' }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Src = 'HKLM RunOnce' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';     Src = 'HKCU Run' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Src = 'HKCU RunOnce' }
)
foreach ($rk in $runKeys) {
    if (Test-Path $rk.Path) {
        $props = Get-ItemProperty $rk.Path
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -notmatch '^PS') { $items.Add([pscustomobject]@{ Source = $rk.Src; Name = $p.Name; Command = $p.Value }) }
        }
    }
}
# startup folders
$folders = @(
    @{ Path = [Environment]::GetFolderPath('Startup');       Src = 'User Startup folder' }
    @{ Path = [Environment]::GetFolderPath('CommonStartup'); Src = 'Common Startup folder' }
)
foreach ($f in $folders) {
    if ($f.Path -and (Test-Path $f.Path)) {
        Get-ChildItem $f.Path -File -ErrorAction SilentlyContinue | ForEach-Object {
            $items.Add([pscustomobject]@{ Source = $f.Src; Name = $_.Name; Command = $_.FullName })
        }
    }
}
# logon scheduled tasks
try {
    Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.Triggers.CimClass.CimClassName -contains 'MSFT_TaskLogonTrigger' -and $_.State -ne 'Disabled' } |
        ForEach-Object { $items.Add([pscustomobject]@{ Source = 'Scheduled task (logon)'; Name = $_.TaskName; Command = $_.TaskPath }) }
} catch { }

# --- disable one entry -------------------------------------------------------
if ($Disable) {
    $hive = if ($Scope -eq 'HKLM') { 'HKLM:' } else { 'HKCU:' }
    if ($Scope -eq 'HKLM' -and -not (Assert-Admin)) { return }
    $runPath = "$hive\Software\Microsoft\Windows\CurrentVersion\Run"
    $bakPath = "$hive\Software\Microsoft\Windows\CurrentVersion\Run_disabled_toolkit"
    $val = (Get-ItemProperty $runPath -Name $Disable -ErrorAction SilentlyContinue).$Disable
    if (-not $val) { Write-Log "No '$Disable' under $Scope Run. Nothing to disable." 'WARN' }
    elseif ($PSCmdlet.ShouldProcess("$Scope Run\$Disable", "Disable (move to backup key)")) {
        Backup-RegistryKey -Path ($runPath -replace ':', '') -Label "Startup_$Scope" | Out-Null
        if (-not (Test-Path $bakPath)) { New-Item -Path $bakPath -Force | Out-Null }
        New-ItemProperty -Path $bakPath -Name $Disable -Value $val -PropertyType String -Force | Out-Null
        Remove-ItemProperty -Path $runPath -Name $Disable -Force
        Write-Log "Disabled '$Disable' (backed up in Run_disabled_toolkit). Re-enable by moving it back." 'OK'
    }
}

$items | Sort-Object Source, Name | Format-Table -AutoSize | Out-Host
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$csv = Join-Path $OutputPath "StartupItems_${env:COMPUTERNAME}_$stamp.csv"
$items | Sort-Object Source, Name | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Log "CSV: $csv" 'OK'
