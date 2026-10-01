<#
.SYNOPSIS
    Check whether a Windows 10 PC can be upgraded to Windows 11, and flag the
    Windows 10 end-of-support deadline.

.DESCRIPTION
    Windows 10 mainstream support ended 14 October 2025. This read-only check
    tells you, per machine, whether it meets the Windows 11 hardware bar so you
    can plan upgrades vs. replacements:
      - TPM 2.0 present and ready
      - Secure Boot capable / enabled
      - UEFI firmware (not legacy BIOS)
      - CPU 64-bit, >=2 cores, >=1 GHz
      - RAM >= 4 GB
      - System disk >= 64 GB
      - DirectX 12 / WDDM 2.x (best-effort)

    Prints a PASS/FAIL per item, an overall verdict, and days remaining on
    Windows 10 support. Writes a CSV line you can append across a fleet.

.PARAMETER OutputPath
    Report folder. Default: toolkit Reports folder.

.EXAMPLE
    .\Test-Win11Readiness.ps1

.NOTES
    Read-only. Some checks (TPM, Secure Boot) read best with admin but degrade
    gracefully. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding()]
param([string]$OutputPath,
    [switch]$Force)

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
Write-Banner "Windows 11 Upgrade Readiness"

if (-not $OutputPath) { $OutputPath = Join-Path (Get-ToolkitRoot) 'Reports' }
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
    $checks.Add([pscustomobject]@{ Check = $Name; Result = if ($Pass) { 'PASS' } else { 'FAIL' }; Detail = $Detail })
}

# --- TPM ---------------------------------------------------------------------
try {
    $tpm = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -ClassName Win32_Tpm -ErrorAction Stop
    $ver = ($tpm.SpecVersion -split ',')[0].Trim()
    Add-Check 'TPM 2.0' (($tpm.IsEnabled_InitialValue) -and ($ver -ge '2.0')) "SpecVersion $ver, enabled=$($tpm.IsEnabled_InitialValue)"
} catch { Add-Check 'TPM 2.0' $false 'No TPM found or access denied (try as admin)' }

# --- Secure Boot / UEFI ------------------------------------------------------
try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Add-Check 'Secure Boot' $sb "Enabled=$sb"
} catch {
    # Confirm-SecureBootUEFI throws on legacy BIOS
    Add-Check 'Secure Boot' $false 'Not enabled / legacy BIOS (or needs admin)'
}
$fw = try { (Get-CimInstance Win32_ComputerSystem).BootupState } catch { '' }
$uefi = try { $env:firmware_type -eq 'UEFI' -or (bcdedit 2>$null | Select-String -SimpleMatch 'winload.efi') } catch { $false }
Add-Check 'UEFI firmware' ([bool]$uefi) "firmware_type=$env:firmware_type"

# --- CPU ---------------------------------------------------------------------
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cores = $cpu.NumberOfCores
$ghz   = [math]::Round($cpu.MaxClockSpeed / 1000, 2)
$is64  = $cpu.AddressWidth -eq 64
Add-Check 'CPU (2+ cores, 1GHz+, 64-bit)' (($cores -ge 2) -and ($ghz -ge 1) -and $is64) "$($cpu.Name.Trim()) — $cores cores, $ghz GHz, $($cpu.AddressWidth)-bit"

# --- RAM ---------------------------------------------------------------------
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Add-Check 'RAM 4GB+' ($ramGB -ge 4) "$ramGB GB"

# --- disk --------------------------------------------------------------------
$sys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$diskGB = [math]::Round($sys.Size / 1GB, 0)
Add-Check 'System disk 64GB+' ($diskGB -ge 64) "$($env:SystemDrive) $diskGB GB"

# --- graphics (best effort) --------------------------------------------------
$gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
Add-Check 'Graphics (DX12/WDDM 2.x)' $true "$($gpu.Name) — verify DX12 with dxdiag if unsure"

# --- output ------------------------------------------------------------------
$fails = ($checks | Where-Object Result -eq 'FAIL').Count
$verdict = if ($fails -eq 0) { 'READY for Windows 11' } else { "NOT ready ($fails blocker(s))" }

$checks | Format-Table -AutoSize | Out-Host

# EOL countdown
$eol = Get-Date '2025-10-14'
$daysToEol = [math]::Round(($eol - (Get-Date)).TotalDays, 0)
$eolMsg = if ($daysToEol -ge 0) { "$daysToEol days until Windows 10 end of support (2025-10-14)." } else { "Windows 10 support ENDED $([math]::Abs($daysToEol)) days ago (2025-10-14). No more free security updates." }

Write-Host ''
Write-Host "  Verdict: $verdict" -ForegroundColor $(if ($fails -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  $eolMsg" -ForegroundColor $(if ($daysToEol -lt 0) { 'Red' } else { 'DarkYellow' })

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$csv   = Join-Path $OutputPath "Win11Readiness_${env:COMPUTERNAME}_$stamp.csv"
$checks | Select-Object @{n='Computer';e={$env:COMPUTERNAME}}, Check, Result, Detail |
    Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Log "CSV: $csv" 'OK'
Write-Log "Readiness: $verdict; $eolMsg" 'INFO'
