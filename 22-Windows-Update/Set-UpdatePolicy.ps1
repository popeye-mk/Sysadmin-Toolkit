<#
.SYNOPSIS
    Put Windows updates on hold (you approve them first), make a PC a pilot that
    takes Microsoft's updates straight away, or give updates back to Windows.

.DESCRIPTION
    Microsoft's monthly updates sometimes break things. The safe routine for a
    small fleet is a pilot ring: one or two test PCs install updates as soon as
    Microsoft releases them; every other PC holds them until you have seen the
    pilots are fine and approved the updates (OpsBoard > Updates, or
    Install-ApprovedUpdates.ps1).

    -Mode Hold    Windows downloads updates but does NOT install them by itself
                  (policy "Configure Automatic Updates" = 3: download, notify).
    -Mode Pilot   Windows installs updates automatically (policy = 4).
    -Mode Default Removes the settings this script made - Windows decides again.

    Hold and Pilot also:
      - keep the PC on its current Windows version (no 24H2 -> 25H2 jump) until
        you choose (TargetReleaseVersion) - clients only, not Windows Server;
      - never restart automatically while someone is logged on;
      - let Microsoft Defender fetch its signatures itself every 4 hours, so
        antivirus updates never wait for an approval;
      - register a daily SYSTEM task that refreshes Reports\update-status.json.

    Hold also LOCKS Settings > Windows Update (policy "Remove access to use all
    Windows Update features"), so nobody - not even a local admin clicking
    around - installs a held update from there. Approved updates are still
    installed by Install-ApprovedUpdates.ps1 / OpsBoard, which talk to the
    update engine directly. Pilot and Default remove the lock again (only if
    this script set it).

    Only what this script set is removed again by -Mode Default (it keeps a
    marker in HKLM:\SOFTWARE\Sysadmin-Toolkit\WindowsUpdate). Windows Home ignores
    these policies - the script says so. On a domain, a Windows Update GPO wins.

.PARAMETER Mode
    Hold, Pilot or Default.
.PARAMETER ScanTime
    Time of the daily update scan (Hold / Pilot). Default 06:30.

.EXAMPLE
    .\Set-UpdatePolicy.ps1 -Mode Hold -WhatIf
.EXAMPLE
    .\Set-UpdatePolicy.ps1 -Mode Pilot
.EXAMPLE
    .\Set-UpdatePolicy.ps1 -Mode Default

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateSet('Hold', 'Pilot', 'Default')][string]$Mode,
    [ValidatePattern('^\d{1,2}:\d{2}$')][string]$ScanTime = '06:30'
)
$ErrorActionPreference = 'Stop'

$AU   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$WU   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$DEF  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Signature Updates'
$MARK = 'HKLM:\SOFTWARE\Sysadmin-Toolkit\WindowsUpdate'
$TaskName = 'Update Scan (daily)'
$TaskPath = '\Sysadmin-Toolkit\'

function Set-Val([string]$Path, [string]$Name, $Value, [string]$Type) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Remove-Val([string]$Path, [string]$Name) {
    if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}

$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$isClient = ([int]$os.ProductType -eq 1)
$isHome   = ([string]$cv.EditionID -like 'Core*')
$onDomain = [bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain
$current  = $null; try { $current = (Get-ItemProperty -Path $MARK -Name Mode -ErrorAction Stop).Mode } catch { }

# the registry still says "Windows 10" on Windows 11 (a Microsoft leftover) - use the build number
$osName = [string]$cv.ProductName
if ($isClient -and [int]$cv.CurrentBuildNumber -ge 22000) { $osName = $osName -replace '^Windows 10', 'Windows 11' }
$lockedByUs = $false; try { $lockedByUs = ((Get-ItemProperty -Path $MARK -Name SettingsLock -ErrorAction Stop).SettingsLock -eq 1) } catch { }
Write-Output ("Computer : {0} ({1}{2})" -f $env:COMPUTERNAME, $osName, $(if ($cv.DisplayVersion) { ' ' + $cv.DisplayVersion } else { '' }))
Write-Output ("Now      : {0}" -f $(if ($current) { $current } else { 'Default (not managed by the toolkit)' }))

if ($Mode -eq 'Default') {
    if (-not $current) {
        Write-Output 'Nothing to undo - this PC''s Windows Update settings were not set by the toolkit.'
        Write-Output 'UPDATE_POLICY=Default'
        return
    }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Remove the toolkit''s Windows Update settings')) {
        foreach ($n in 'NoAutoUpdate', 'AUOptions', 'NoAutoRebootWithLoggedOnUsers') { Remove-Val $AU $n }
        foreach ($n in 'TargetReleaseVersion', 'ProductVersion', 'TargetReleaseVersionInfo') { Remove-Val $WU $n }
        Remove-Val $DEF 'SignatureUpdateInterval'
        if ($lockedByUs) { Remove-Val $WU 'SetDisableUXWUAccess' }
        Remove-Item -Path $MARK -Recurse -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
        Write-Output 'Done: Windows decides again when to install updates (its normal behaviour).'
        Write-Output 'UPDATE_POLICY=Default'
    }
    return
}

$auOption = $(if ($Mode -eq 'Hold') { 3 } else { 4 })
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Set Windows Update to $Mode")) {
    Set-Val $AU 'NoAutoUpdate' 0 DWord
    Set-Val $AU 'AUOptions' $auOption DWord
    Set-Val $AU 'NoAutoRebootWithLoggedOnUsers' 1 DWord
    $pinned = ''
    if ($isClient -and $cv.DisplayVersion) {
        $product = $(if ([int]$cv.CurrentBuildNumber -ge 22000) { 'Windows 11' } else { 'Windows 10' })
        Set-Val $WU 'TargetReleaseVersion' 1 DWord
        Set-Val $WU 'ProductVersion' $product String
        Set-Val $WU 'TargetReleaseVersionInfo' ([string]$cv.DisplayVersion) String
        $pinned = "$product $($cv.DisplayVersion)"
    }
    Set-Val $DEF 'SignatureUpdateInterval' 4 DWord
    if ($Mode -eq 'Hold') {
        # lock Settings > Windows Update: only approved updates, installed through the toolkit / OpsBoard
        Set-Val $WU 'SetDisableUXWUAccess' 1 DWord
        Set-Val $MARK 'SettingsLock' 1 DWord
    } elseif ($lockedByUs) {
        Remove-Val $WU 'SetDisableUXWUAccess'
        Remove-Val $MARK 'SettingsLock'
    }
    Set-Val $MARK 'Mode' $Mode String
    Set-Val $MARK 'SetAt' ((Get-Date).ToString('yyyy-MM-dd HH:mm')) String

    $scan = Join-Path $PSScriptRoot 'Get-UpdateStatus.ps1'
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scan`" -NoTask"
        $trigger = New-ScheduledTaskTrigger -Daily -At $ScanTime
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    } catch { Write-Warning "Could not register the daily update scan: $($_.Exception.Message)" }

    if ($Mode -eq 'Hold') {
        Write-Output 'Done: updates are ON HOLD - Windows downloads them but only installs what you approve.'
        Write-Output 'Settings > Windows Update is locked: nobody installs a held update from there (it may show "Some settings are managed by your organization").'
    } else {
        Write-Output 'Done: PILOT - this PC installs Microsoft''s updates automatically, so you see problems here first.'
    }
    if ($pinned) { Write-Output "Windows version held at $pinned (no feature upgrade until you change it)." }
    Write-Output 'Defender signatures: updated by Defender itself every 4 hours (never held).'
    Write-Output 'No automatic restart while someone is logged on.'
    if ($isHome) { Write-Warning 'This is Windows HOME: it ignores these policies, so the hold is NOT active here.' }
    if ($onDomain) { Write-Warning 'Domain PC: a Windows Update Group Policy overrides these local settings at the next gpupdate.' }
    Write-Output "UPDATE_POLICY=$Mode"
}
