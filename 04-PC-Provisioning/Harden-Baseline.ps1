<#
.SYNOPSIS
    Baseline security hardening for a standalone Windows 10/11 machine (no GPO).

.DESCRIPTION
    Applies a conservative, well-known hardening baseline. Registry changes are
    exported to a timestamped .reg first, so -Rollback restores them. A few items
    are applied via cmdlets (firewall, Defender PUA, SMBv1) — those aren't in the
    .reg rollback, so their revert command is printed next to each.

    Supports -WhatIf. Run as Administrator.

.PARAMETER BackupPath
    Folder for .reg backups. Default: C:\TechToolkit\RegBackup

.PARAMETER Rollback
    Restore registry keys from a previous run's backup folder/.reg.

.EXAMPLE
    .\Harden-Baseline.ps1 -WhatIf
.EXAMPLE
    .\Harden-Baseline.ps1
.EXAMPLE
    .\Harden-Baseline.ps1 -Rollback "C:\TechToolkit\RegBackup\2026-09-18_1600"

.NOTES
    Test on a VM. Some items (SMBv1 off) may need a restart. Part of TechToolkit.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$BackupPath = 'C:\TechToolkit\RegBackup',
    [string]$Rollback
)

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Backup-Key {
    param([string]$Path, [string]$Dest)
    if (-not (Test-Path $Path)) { return }
    $regPath  = $Path -replace '^HK(LM|CU|CR|U|CC):', 'HK$1' -replace ':', ''
    $safeName = ($regPath -replace '[\\/:*?"<>|]', '_')
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
    Start-Process -FilePath reg.exe -ArgumentList @('export', ('"{0}"' -f $regPath), ('"{0}"' -f (Join-Path $Dest "$safeName.reg")), '/y') -Wait -WindowStyle Hidden | Out-Null
}
function Set-Tweak {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$Description = '')
    $cur = $null
    if (Test-Path $Path) { $cur = (Get-ItemProperty $Path -Name $Name -ErrorAction SilentlyContinue).$Name }
    $label = if ($Description) { $Description } else { "$Path\$Name" }
    if ($cur -eq $Value) { Write-Host "  [=] $label (already set)" -ForegroundColor DarkGray; return }
    if ($PSCmdlet.ShouldProcess($label, "Set to $Value")) {
        Backup-Key -Path $Path -Dest $script:RunBackupDir
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Write-Host "  [+] $label" -ForegroundColor Green
    }
}
function Invoke-Hard {
    param([string]$Label, [scriptblock]$Do, [string]$Revert)
    if ($PSCmdlet.ShouldProcess($Label, "Apply")) {
        try   { & $Do; Write-Host "  [+] $Label" -ForegroundColor Green
                if ($Revert) { Write-Host "      revert: $Revert" -ForegroundColor DarkGray } }
        catch { Write-Host "  [!] $Label — $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

# ---------- rollback ----------
if ($Rollback) {
    Write-Host "==== Rollback (registry only) ====" -ForegroundColor Cyan
    $files = if (Test-Path $Rollback -PathType Container) { Get-ChildItem $Rollback -Filter *.reg -File }
             elseif (Test-Path $Rollback -PathType Leaf)  { @(Get-Item $Rollback) }
             else { Write-Error "Not found: $Rollback"; return }
    foreach ($f in $files) { Write-Host "  Restoring $($f.Name)"; Start-Process -FilePath reg.exe -ArgumentList @('import', ('"{0}"' -f $f.FullName)) -Wait -WindowStyle Hidden | Out-Null }
    Write-Host "Done. Firewall/Defender/SMB toggles are not part of this rollback." -ForegroundColor Cyan
    return
}

if (-not (Test-Admin)) { Write-Error "Run as Administrator."; return }
$script:RunBackupDir = Join-Path $BackupPath (Get-Date -Format 'yyyy-MM-dd_HHmm')
Write-Host "TechToolkit :: Harden-Baseline" -ForegroundColor White
Write-Host "Backups : $script:RunBackupDir"
if ($WhatIfPreference) { Write-Host "MODE    : WhatIf (nothing written)" -ForegroundColor Yellow }

$sys  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$exp  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$dns  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
$lanw = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
$rdp  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'

Write-Host "`n==== Logon & UAC ====" -ForegroundColor Cyan
Set-Tweak $sys 'EnableLUA'                 1 -Description 'UAC enabled'
Set-Tweak $sys 'ConsentPromptBehaviorAdmin' 2 -Description 'UAC: prompt for consent on secure desktop'
Set-Tweak $sys 'PromptOnSecureDesktop'     1 -Description 'UAC secure desktop'
Set-Tweak $sys 'DontDisplayLastUserName'   1 -Description "Don't show last signed-in user"
Set-Tweak $sys 'DisableCAD'                0 -Description 'Require Ctrl+Alt+Del at logon'
Set-Tweak $sys 'InactivityTimeoutSecs'   900 -Description 'Auto-lock after 15 min idle'

Write-Host "`n==== Removable media & network ====" -ForegroundColor Cyan
Set-Tweak $exp  'NoDriveTypeAutoRun'     255 -Description 'Disable AutoRun/AutoPlay on all drives'
Set-Tweak $dns  'EnableMulticast'          0 -Description 'Disable LLMNR (spoofing hardening)'
Set-Tweak $lanw 'AllowInsecureGuestAuth'   0 -Description 'Block insecure SMB guest logons'
Set-Tweak $rdp  'UserAuthentication'       1 -Description 'RDP: require Network Level Authentication'

Write-Host "`n==== Accounts & services (cmdlets) ====" -ForegroundColor Cyan
Invoke-Hard 'Disable built-in Guest account' `
    { Disable-LocalUser -Name 'Guest' -ErrorAction Stop } `
    'Enable-LocalUser -Name Guest'

Invoke-Hard 'Enable Windows Firewall (all profiles)' `
    { Set-NetFirewallProfile -All -Enabled True -ErrorAction Stop } `
    'Set-NetFirewallProfile -All -Enabled False'

Invoke-Hard 'Defender: enable PUA protection' `
    { Set-MpPreference -PUAProtection Enabled -ErrorAction Stop } `
    'Set-MpPreference -PUAProtection Disabled'

Invoke-Hard 'Disable SMBv1 (server)' `
    { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop } `
    'Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force'

Write-Host "`n==== Done ====" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "WhatIf run complete." -ForegroundColor Yellow
} else {
    Write-Host "Registry undo: .\Harden-Baseline.ps1 -Rollback `"$script:RunBackupDir`"" -ForegroundColor Cyan
    Write-Host "A restart is recommended so SMB/logon changes fully apply." -ForegroundColor DarkGray
}
