<#
.SYNOPSIS
    Install only the Windows updates you approved (and hide the ones you
    declined) - never anything else, never a restart.

.DESCRIPTION
    Companion of Set-UpdatePolicy.ps1 -Mode Hold. You give the update IDs you
    approved (OpsBoard does this for you); the script installs exactly those,
    plus Defender signature updates, and hides the declined ones so nobody can
    install them from Settings by accident.

    Installing can take a long time, and Windows refuses to install from a remote
    session, so it always starts itself as a SYSTEM task on the PC and returns at
    once (locally too - a caller with a time limit, like OpsBoard on its own
    server, must never cut an install off half-way). Use -NoTask to install in
    this window and watch it. The result is written to Reports\update-install-last.json
    (Get-UpdateStatus.ps1 reports it). It never restarts the PC - if an update
    needs a restart, the result says so.

.PARAMETER UpdateId
    Windows Update IDs (GUIDs) to install. Comma-separated is fine.
.PARAMETER Hide
    Update IDs to hide (declined).
.PARAMETER IncludeDefinitions
    Also install Defender signature updates that are waiting.
.PARAMETER NoTask
    Install in this process and wait for it (used by the SYSTEM task; fine by
    hand as admin when you want to watch).

.EXAMPLE
    .\Install-ApprovedUpdates.ps1 -UpdateId 3f1b9c2e-1111-4a2b-9c3d-000000000001 -IncludeDefinitions -WhatIf

.NOTES
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string[]]$UpdateId = @(),
    [string[]]$Hide = @(),
    [switch]$IncludeDefinitions,
    [switch]$NoTask
)
$ErrorActionPreference = 'Stop'

$kitRoot     = Split-Path $PSScriptRoot -Parent
$reports     = Join-Path $kitRoot 'Reports'
$installFile = Join-Path $reports 'update-install-last.json'
$TaskName = 'Update Install'
$TaskPath = '\Sysadmin-Toolkit\'
$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Split-Ids([string[]]$List) {
    $ids = @()
    foreach ($x in $List) { foreach ($p in ([string]$x -split '[,;\s]+')) { if ($p) { $ids += $p.ToLower() } } }
    foreach ($i in $ids) { if ($i -notmatch $guid) { throw "Not a Windows Update ID: '$i'" } }
    @($ids | Select-Object -Unique)
}
$approve = Split-Ids $UpdateId
$decline = Split-Ids $Hide
if (-not $approve.Count -and -not $decline.Count -and -not $IncludeDefinitions) {
    Write-Output 'Nothing to do: no approved or declined updates given.'
    return
}

function New-WUSession {
    if ($global:SysadminToolkitWUSessionFactory) { $s = & $global:SysadminToolkitWUSessionFactory }
    else { $s = New-Object -ComObject Microsoft.Update.Session }
    try { $s.ClientApplicationID = 'Sysadmin-Toolkit' } catch { }
    $s
}
function New-WUCollection {
    # the leading comma stops PowerShell from unrolling the (empty) collection into $null
    if ($global:SysadminToolkitWUCollectionFactory) { return ,(& $global:SysadminToolkitWUCollectionFactory) }
    return ,(New-Object -ComObject Microsoft.Update.UpdateColl)
}

# ---- hand the work to a SYSTEM task on the PC and return (remote AND local) ------
if (-not $NoTask) {
    $running = $null
    try { $running = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Where-Object { $_.State -eq 'Running' } } catch { }
    if ($running) { Write-Output 'An update install is already running on this PC - wait for it to finish.'; return }
    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install $($approve.Count) approved update(s), hide $($decline.Count)")) { return }
    $a = '-NoTask'
    if ($approve.Count) { $a += ' -UpdateId ' + ($approve -join ',') }
    if ($decline.Count) { $a += ' -Hide ' + ($decline -join ',') }
    if ($IncludeDefinitions) { $a += ' -IncludeDefinitions' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + $a)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    Write-Output ("Started on {0}: installing {1} approved update(s){2}, hiding {3} declined." -f $env:COMPUTERNAME, $approve.Count, $(if ($IncludeDefinitions) { ' + Defender signatures' } else { '' }), $decline.Count)
    Write-Output 'It runs in the background (no restart). Check the result later with "Check for Windows updates".'
    Write-Output "INSTALL_STARTED=$($approve.Count)"
    return
}

# ---- the work (SYSTEM task, or local admin) ----------------------------------
$started = (Get-Date).ToUniversalTime().ToString('o')
$session = New-WUSession
$result  = $session.CreateUpdateSearcher().Search('IsInstalled=0')
$coll    = New-WUCollection
$picked  = @(); $hidden = 0; $seen = @()
foreach ($u in $result.Updates) {
    $id = ([string]$u.Identity.UpdateID).ToLower()
    $seen += $id
    $cats = @(); foreach ($c in $u.Categories) { $cats += [string]$c.Name }
    if ($decline -contains $id) {
        if (-not $u.IsHidden -and $PSCmdlet.ShouldProcess($u.Title, 'Hide (declined)')) { $u.IsHidden = $true; $hidden++ }
        continue
    }
    if ($u.IsHidden) { continue }
    $isDef = ($cats -contains 'Definition Updates')
    if (($approve -contains $id) -or ($IncludeDefinitions -and $isDef)) {
        if (-not $PSCmdlet.ShouldProcess($u.Title, 'Install')) { continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coll.Add($u)
        $kbs = @(); foreach ($k in $u.KBArticleIDs) { $kbs += "KB$k" }
        $picked += [pscustomobject]@{ id = $id; kb = ($kbs -join ','); title = [string]$u.Title }
    }
}
$notOffered = @($approve | Where-Object { $seen -notcontains $_ })

$results = @(); $reboot = $false
if ($coll.Count -gt 0) {
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
    $r = $inst.Install()
    $reboot = [bool]$r.RebootRequired
    $names = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
    for ($i = 0; $i -lt $picked.Count; $i++) {
        $ur = $r.GetUpdateResult($i)
        $results += [pscustomobject]@{
            id = $picked[$i].id; kb = $picked[$i].kb; title = $picked[$i].title
            result = $names[[int]$ur.ResultCode]; hresult = ('0x{0:X8}' -f [int]$ur.HResult)
        }
    }
}
$ok = @($results | Where-Object { $_.result -like 'Succeeded*' }).Count
$summary = [pscustomobject]@{
    computer       = $env:COMPUTERNAME
    startedAt      = $started
    finishedAt     = (Get-Date).ToUniversalTime().ToString('o')
    installed      = $ok
    failed         = @($results).Count - $ok
    hidden         = $hidden
    notOffered     = $notOffered
    rebootRequired = $reboot
    results        = @($results)
}
if (-not $WhatIfPreference) {
    if (-not (Test-Path $reports)) { New-Item -ItemType Directory -Path $reports -Force | Out-Null }
    $summary | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $installFile -Encoding UTF8
}
Write-Output ("Installed {0}, failed {1}, hidden {2}{3}." -f $ok, $summary.failed, $hidden, $(if ($notOffered.Count) { ", $($notOffered.Count) no longer offered (already installed or replaced)" } else { '' }))
foreach ($x in $results) { Write-Output ("  {0,-20} {1,-12} {2}" -f $x.result, $x.kb, $x.title) }
if ($reboot) { Write-Output 'A restart is needed to finish - OpsBoard will show "reboot pending". Restart when it suits the user.' }
Write-Output ("INSTALL_RESULT=installed:{0};failed:{1};reboot:{2}" -f $ok, $summary.failed, [int]$reboot)
