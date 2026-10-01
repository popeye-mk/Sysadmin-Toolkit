<#
.SYNOPSIS
    Turn off Windows 11 AI / "assistant" features and cut telemetry to the
    minimum — Copilot, Recall, and diagnostic data.

.DESCRIPTION
    Machine-wide policy (HKLM), so run as Administrator. Backs up each policy
    branch first and honours -WhatIf. -Rollback restores the newest backup set.

    What it disables:
      - Windows Copilot (TurnOffWindowsCopilot policy + taskbar button).
      - Recall / "AI data analysis" (DisableAIDataAnalysis policy).
      - Telemetry to the lowest level the edition allows (Security on
        Enterprise/Education, otherwise Basic=1).
      - Advertising ID, "tailored experiences" with diagnostic data,
        and the "let websites show locally relevant content" tracking.

    These are the settings clients and auditors most often ask about. Nothing
    here removes apps.

.PARAMETER Rollback
    Restore the newest backup set this script made and exit.

.EXAMPLE
    .\Disable-Win11AITelemetry.ps1 -WhatIf
.EXAMPLE
    .\Disable-Win11AITelemetry.ps1

.NOTES
    Run as Administrator. A sign-out or reboot fully applies the policies.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param([switch]$Rollback,
    [switch]$Force)

$script:__ntForce = $false
if ($Force -or $env:SYSADMIN_TOOLKIT_FORCE -eq '1') { $ConfirmPreference = 'None'; $script:__ntForce = $true }

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
Write-Banner "Windows 11 AI + Telemetry Off"

if (-not (Assert-Admin)) { return }
$backupDir = Join-Path (Get-ToolkitRoot) 'Backups'

if ($Rollback) {
    $regs = Get-ChildItem $backupDir -Filter 'Win11AITelemetry_*.reg' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $regs) { Write-Log "No backups found." 'WARN'; return }
    $newest = $regs | Select-Object -First 1
    $stampTag = if ($newest.Name -match '_(\d{4}-\d{2}-\d{2}_\d{6})\.reg$') { $Matches[1] } else { '' }
    $set = @($regs | Where-Object { $_.Name -like "*_$stampTag.reg" })
    if ($PSCmdlet.ShouldProcess("backup set $stampTag ($($set.Count) file(s))", "Re-import")) { foreach ($r in $set) { Start-Process -FilePath reg.exe -ArgumentList @('import', ('"{0}"' -f $r.FullName)) -Wait -WindowStyle Hidden | Out-Null }; Write-Log "Restored $($set.Count) key(s) from backup set $stampTag" 'OK' }
    return
}

foreach ($k in @(
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI',
    'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
)) { Backup-RegistryKey -Path $k -Label 'Win11AITelemetry' | Out-Null }

# --- Copilot -----------------------------------------------------------------
Write-Log "Disabling Windows Copilot..." 'STEP'
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord
Set-RegValue -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Value 0 -Type DWord

# --- Recall / AI data analysis ----------------------------------------------
Write-Log "Disabling Recall / AI data analysis..." 'STEP'
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Value 1 -Type DWord
Set-RegValue -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Value 1 -Type DWord

# --- telemetry ---------------------------------------------------------------
Write-Log "Lowering telemetry level..." 'STEP'
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
$level   = if ($edition -match 'Enterprise|Education') { 0 } else { 1 }   # 0=Security (Ent/Edu only), 1=Basic
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value $level -Type DWord
Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1 -Type DWord
$levelName = if ($level -eq 0) { 'Security' } else { 'Basic' }
Write-Log "Telemetry set to $level ($levelName)." 'INFO'

# --- ad id + tailored experiences -------------------------------------------
Write-Log "Turning off advertising ID + tailored experiences..." 'STEP'
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -Type DWord
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 -Type DWord
Set-RegValue -Path 'HKCU:\Control Panel\International\User Profile' -Name 'HttpAcceptLanguageOptOut' -Value 1 -Type DWord

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  AI + telemetry settings applied. Reboot (or sign out) to finish." -ForegroundColor Green
    Write-Host "  Undo with:  .\Disable-Win11AITelemetry.ps1 -Rollback" -ForegroundColor White
    Write-Log "Win11 AI/telemetry policy applied (telemetry=$level)." 'OK'
}
