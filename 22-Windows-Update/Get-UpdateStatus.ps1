<#
.SYNOPSIS
    Which Windows updates are waiting on this PC, when it was last patched, and
    whether its updates are on hold - as a report or as JSON for OpsBoard.

.DESCRIPTION
    Asks the Windows Update Agent (the same engine as Settings > Windows Update)
    which updates are offered but not installed yet, and reads the update history
    for the date of the last real patch (Defender signature updates don't count).

    The result is also saved to Reports\update-status.json, which the Zabbix
    metrics script reads - so the dashboard shows "3 updates waiting" without
    running a slow update scan on every poll.

    Windows doesn't let the update engine be used from a remote session
    (PowerShell Remoting gets "access denied"), so when this runs remotely it
    starts itself as a short-lived SYSTEM task on the PC and waits for it.

    Read-only: nothing is downloaded, installed or changed.

.PARAMETER Json
    Print one line of JSON (for OpsBoard) instead of the readable report.
.PARAMETER NoTask
    Scan in this process (used by the SYSTEM task itself; also fine when you run
    it locally as administrator).
.PARAMETER WaitSeconds
    How long to wait for the SYSTEM task when run remotely. Default 150.

.EXAMPLE
    .\Get-UpdateStatus.ps1
.EXAMPLE
    .\Get-UpdateStatus.ps1 -Json

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoTask,
    [int]$WaitSeconds = 150
)
$ErrorActionPreference = 'Stop'

$kitRoot    = Split-Path $PSScriptRoot -Parent
$reports    = Join-Path $kitRoot 'Reports'
$statusFile = Join-Path $reports 'update-status.json'
$installFile = Join-Path $reports 'update-install-last.json'
$markerKey  = 'HKLM:\SOFTWARE\Sysadmin-Toolkit\WindowsUpdate'

function New-WUSession {
    # test hook: a fake session can be injected; on Windows this is the real COM object
    if ($global:SysadminToolkitWUSessionFactory) { $s = & $global:SysadminToolkitWUSessionFactory }
    else { $s = New-Object -ComObject Microsoft.Update.Session }
    try { $s.ClientApplicationID = 'Sysadmin-Toolkit' } catch { }
    $s
}

function Invoke-WUAsSystem {
    # Run this script as SYSTEM through a one-off scheduled task (same name every
    # time, so nothing piles up) and wait for it. Returns $true when it finished.
    param([string]$TaskName, [string]$Arguments, [int]$Wait)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + $Arguments)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\Sysadmin-Toolkit\' -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName -TaskPath '\Sysadmin-Toolkit\'
    $deadline = (Get-Date).AddSeconds($Wait)
    Start-Sleep -Seconds 2
    while ((Get-Date) -lt $deadline) {
        $state = (Get-ScheduledTask -TaskName $TaskName -TaskPath '\Sysadmin-Toolkit\').State
        if ($state -ne 'Running') { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function ConvertTo-WUItem {
    param($u)
    $cats = @(); foreach ($c in $u.Categories) { $cats += [string]$c.Name }
    $kbs = @(); foreach ($k in $u.KBArticleIDs) { $kbs += "KB$k" }
    $sev = [string]$u.MsrcSeverity
    $released = ''
    try { $released = ([datetime]$u.LastDeploymentChangeTime).ToString('yyyy-MM-dd') } catch { }
    $reboot = $false
    try { $reboot = ([int]$u.InstallationBehavior.RebootBehavior -ne 0) } catch { }
    [pscustomobject]@{
        id         = [string]$u.Identity.UpdateID
        kb         = ($kbs -join ',')
        title      = [string]$u.Title
        severity   = $sev
        security   = [bool](($cats -contains 'Security Updates') -or $sev)
        category   = $(if ($cats.Count) { $cats[0] } else { '' })
        definition = [bool]($cats -contains 'Definition Updates')
        upgrade    = [bool]($cats -contains 'Upgrades')
        driver     = [bool]([int]$u.Type -eq 2)
        sizeMB     = [math]::Round(([double]$u.MaxDownloadSize) / 1MB, 1)
        released   = $released
        hidden     = [bool]$u.IsHidden
        downloaded = [bool]$u.IsDownloaded
        reboot     = $reboot
    }
}

function Get-WUPolicy {
    $mode = $null; $au = $null; $pin = $null; $lock = $false
    try { $mode = (Get-ItemProperty -Path $markerKey -Name Mode -ErrorAction Stop).Mode } catch { }
    try { $au = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name AUOptions -ErrorAction Stop).AUOptions } catch { }
    try {
        $w = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop
        if ($w.TargetReleaseVersion -eq 1) { $pin = "$($w.ProductVersion) $($w.TargetReleaseVersionInfo)".Trim() }
        if ($w.SetDisableUXWUAccess -eq 1) { $lock = $true }
    } catch { }
    [pscustomobject]@{ mode = $(if ($mode) { $mode } else { 'Default' }); auOptions = $au; versionPinnedTo = $pin; settingsLocked = $lock }
}

function Invoke-WUScan {
    $session  = New-WUSession
    $searcher = $session.CreateUpdateSearcher()
    $result   = $searcher.Search('IsInstalled=0')
    $items = @(); foreach ($u in $result.Updates) { $items += ConvertTo-WUItem $u }

    # last real patch: newest successful install in the history, Defender signatures excluded
    $last = $null
    try {
        $n = $searcher.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($e in $searcher.QueryHistory(0, [math]::Min($n, 300))) {
                if ([int]$e.Operation -eq 1 -and ([int]$e.ResultCode -eq 2 -or [int]$e.ResultCode -eq 3) -and
                    ([string]$e.Title -notmatch 'Security Intelligence|Definition Update|Antivirus antimalware platform')) {
                    $d = [datetime]$e.Date
                    if (-not $last -or $d -gt $last) { $last = $d }
                }
            }
        }
    } catch { }
    if (-not $last) {
        try {
            $last = Get-CimInstance Win32_QuickFixEngineering -ErrorAction Stop | Where-Object { $_.InstalledOn } |
                ForEach-Object { [datetime]$_.InstalledOn } | Sort-Object -Descending | Select-Object -First 1
        } catch { }
    }

    $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $lastInstall = $null
    if (Test-Path $installFile) { try { $lastInstall = Get-Content $installFile -Raw | ConvertFrom-Json } catch { } }

    [pscustomobject]@{
        computer      = $env:COMPUTERNAME
        scannedAt     = (Get-Date).ToUniversalTime().ToString('o')
        policy        = Get-WUPolicy
        lastPatchDate = $(if ($last) { $last.ToString('yyyy-MM-dd') } else { $null })
        lastPatchDays = $(if ($last) { [math]::Round(((Get-Date) - $last).TotalDays, 0) } else { $null })
        rebootPending = [bool]$rebootPending
        updates       = @($items)
        lastInstall   = $lastInstall
    }
}

# ---- run ------------------------------------------------------------------------
if (-not $NoTask -and $PSSenderInfo) {
    # remote session: the update engine refuses remote callers - run as SYSTEM on the PC
    $done = Invoke-WUAsSystem -TaskName 'Update Scan' -Arguments '-NoTask' -Wait $WaitSeconds
    if (-not $done) {
        Write-Output 'The update scan is still running on this PC (Windows Update can be slow). Run this again in a few minutes.'
        return
    }
    if (-not (Test-Path $statusFile)) { throw "The update scan finished but wrote no result ($statusFile)." }
    $data = Get-Content $statusFile -Raw | ConvertFrom-Json
} else {
    $data = Invoke-WUScan
    if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }
    $data | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $statusFile -Encoding UTF8
}

if ($Json) {
    $data | ConvertTo-Json -Depth 6 -Compress
    return
}
$pending = @($data.updates | Where-Object { -not $_.hidden -and -not $_.definition })
Write-Output ("Computer     : {0}" -f $data.computer)
Write-Output ("Update mode  : {0}{1}" -f $data.policy.mode, $(if ($data.policy.versionPinnedTo) { " (Windows version held at $($data.policy.versionPinnedTo))" } else { '' }))
Write-Output ("Last patched : {0}" -f $(if ($data.lastPatchDate) { "$($data.lastPatchDate) ($($data.lastPatchDays) days ago)" } else { 'unknown' }))
Write-Output ("Waiting      : {0} update(s), {1} security" -f $pending.Count, @($pending | Where-Object { $_.security }).Count)
if ($data.rebootPending) { Write-Output 'Reboot       : pending' }
if ($pending.Count) { $pending | Sort-Object -Property @{ Expression = 'security'; Descending = $true }, title | Format-Table kb, severity, released, sizeMB, title -AutoSize | Out-String -Width 200 }
