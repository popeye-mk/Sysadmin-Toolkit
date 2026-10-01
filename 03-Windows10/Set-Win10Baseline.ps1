<#
.SYNOPSIS
    Apply a per-user Windows 10 baseline — the standard tweaks for a Win10 work
    PC (privacy, Explorer defaults, Cortana/search).

.DESCRIPTION
    Per-user (HKCU) with a couple of machine policies for Cortana. Backs up each
    branch first, honours -WhatIf, and -Rollback restores the newest backup set.

    What it does:
      - Show file extensions + hidden files; open Explorer to This PC.
      - Turn off Cortana and Bing web results in the Start search.
      - Disable the advertising ID and "suggested apps"/tips (Spotlight).
      - Turn off "let apps use my advertising ID" and lock-screen tips.
      - Disable the "People" bar and Timeline activity upload.

    No apps are removed here — see the Debloat section for that.

.PARAMETER Rollback
    Restore the newest backup set this script made and exit.

.EXAMPLE
    .\Set-Win10Baseline.ps1 -WhatIf
.EXAMPLE
    .\Set-Win10Baseline.ps1

.NOTES
    Cortana policy needs admin; the rest is per-user. Restarts Explorer at the
    end. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
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
Write-Banner "Windows 10 Baseline (per-user)"

$os = Get-OSInfo
if ($os.Tag -ne 'Win10') { Write-Log "This looks like $($os.Caption) (tag $($os.Tag)), not Windows 10. Continuing anyway." 'WARN' }

$backupDir = Join-Path (Get-ToolkitRoot) 'Backups'
if ($Rollback) {
    $regs = Get-ChildItem $backupDir -Filter 'Win10Baseline_*.reg' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if (-not $regs) { Write-Log "No Win10Baseline backups found." 'WARN'; return }
    $newest = $regs | Select-Object -First 1
    $stampTag = if ($newest.Name -match '_(\d{4}-\d{2}-\d{2}_\d{6})\.reg$') { $Matches[1] } else { '' }
    $set = @($regs | Where-Object { $_.Name -like "*_$stampTag.reg" })
    if ($PSCmdlet.ShouldProcess("backup set $stampTag ($($set.Count) file(s))", "Re-import")) {
        foreach ($r in $set) { Start-Process -FilePath reg.exe -ArgumentList @('import', ('"{0}"' -f $r.FullName)) -Wait -WindowStyle Hidden | Out-Null }
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Write-Log "Restored $($set.Count) key(s) from backup set $stampTag; explorer restarted." 'OK'
    }
    return
}

foreach ($k in @(
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo',
    'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'
)) { Backup-RegistryKey -Path $k -Label 'Win10Baseline' | Out-Null }

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

Write-Log "Explorer defaults..." 'STEP'
Set-RegValue -Path $adv -Name 'HideFileExt' -Value 0 -Type DWord
Set-RegValue -Path $adv -Name 'Hidden'      -Value 1 -Type DWord
Set-RegValue -Path $adv -Name 'LaunchTo'    -Value 1 -Type DWord
Set-RegValue -Path $adv -Name 'PeopleBand'  -Value 0 -Type DWord

Write-Log "Cortana + web search off..." 'STEP'
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -Value 0 -Type DWord
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'CortanaConsent'    -Value 0 -Type DWord
if (Test-Admin) {
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0 -Type DWord
} else {
    Write-Log "Not elevated — skipping machine-wide Cortana policy (per-user consent still set)." 'WARN'
}

Write-Log "Advertising ID + suggestions off..." 'STEP'
Set-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -Type DWord
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($v in 'SystemPaneSuggestionsEnabled','SubscribedContent-338389Enabled','SubscribedContent-310093Enabled','SilentInstalledAppsEnabled','SoftLandingEnabled') {
    Set-RegValue -Path $cdm -Name $v -Value 0 -Type DWord
}

Write-Log "Timeline activity upload off..." 'STEP'
if (Test-Admin) {
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Value 0 -Type DWord
}

if (-not $WhatIfPreference) {
    if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart to apply')) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host "  Windows 10 baseline applied. Explorer restarted." -ForegroundColor Green
    Write-Host "  Undo with:  .\Set-Win10Baseline.ps1 -Rollback" -ForegroundColor White
    Write-Log "Win10 baseline applied." 'OK'
}
