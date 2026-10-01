<#
.SYNOPSIS
    Provision a fresh Windows PC — rename, set power plan, install standard
    software, and prep it for a user. The "new machine out of the box" script.

.DESCRIPTION
    Runs the common first-touch steps in order, each optional and each safe to
    re-run:
      1. Rename the computer (queues a reboot; no immediate restart).
      2. Set the active power plan to High performance (good for desktops).
      3. Enable Remote Desktop (optional) with NLA.
      4. Install a standard software set via winget from a simple list.
      5. Set the time zone.
      6. Run a quick Windows Update scan (via PSWindowsUpdate if present, else
         opens Settings).

    Domain join is deliberately a SEPARATE script (Join-Domain.ps1) because it
    needs credentials and its own reboot. This one gets the box to a clean,
    named, patched, standard-software state.

.PARAMETER NewName
    New computer name. Skipped if omitted or already set.
.PARAMETER Apps
    winget package IDs to install. Defaults to a sensible base set.
.PARAMETER TimeZone
    A Windows time-zone id, e.g. 'Romance Standard Time' (Belgium/CET).
.PARAMETER EnableRDP
    Switch: turn on Remote Desktop with Network Level Authentication.
.PARAMETER PowerPlan
    'High' (default), 'Balanced', or 'None' to leave it.

.EXAMPLE
    .\Initialize-NewPC.ps1 -NewName PC-RECEPTIE-01 -TimeZone 'Romance Standard Time' -EnableRDP -WhatIf
.EXAMPLE
    .\Initialize-NewPC.ps1 -NewName PC-RECEPTIE-01 -Apps 7zip.7zip,Google.Chrome,VideoLAN.VLC

.NOTES
    Run as Administrator. winget must be present (App Installer). Part of the
    Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$NewName,
    [string[]]$Apps = @('7zip.7zip', 'Google.Chrome', 'Mozilla.Firefox', 'VideoLAN.VLC', 'Notepad++.Notepad++', 'Adobe.Acrobat.Reader.64-bit'),
    [string]$TimeZone,
    [switch]$EnableRDP,
    [ValidateSet('High', 'Balanced', 'None')][string]$PowerPlan = 'High',
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
if (-not $PSBoundParameters.ContainsKey('Apps')) { $__v = Get-ToolkitSetting 'Provisioning.Apps'; if ($null -ne $__v) { $Apps = $__v; $__cfgUsed += 'Provisioning.Apps' } }
if (-not $PSBoundParameters.ContainsKey('TimeZone')) { $__v = Get-ToolkitSetting 'Regional.TimeZone'; if ($null -ne $__v) { $TimeZone = $__v; $__cfgUsed += 'Regional.TimeZone' } }
if (-not $PSBoundParameters.ContainsKey('PowerPlan')) { $__v = Get-ToolkitSetting 'Provisioning.PowerPlan'; if ($null -ne $__v) { $PowerPlan = $__v; $__cfgUsed += 'Provisioning.PowerPlan' } }
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
Write-Banner "New PC Provisioning"
if (-not (Assert-Admin)) { return }

# --- 1. rename ---------------------------------------------------------------
if ($NewName) {
    if ($env:COMPUTERNAME -eq $NewName) {
        Write-Log "Computer already named $NewName." 'INFO'
    } elseif ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Rename to $NewName (reboot required)")) {
        try { Rename-Computer -NewName $NewName -Force -ErrorAction Stop; Write-Log "Renamed to $NewName (takes effect after reboot)." 'OK' }
        catch { Write-Log "Rename failed: $($_.Exception.Message)" 'WARN' }
    }
}

# --- 2. power plan -----------------------------------------------------------
if ($PowerPlan -ne 'None') {
    $guid = if ($PowerPlan -eq 'High') { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
    if ($PSCmdlet.ShouldProcess("Power plan", "Set active to $PowerPlan")) {
        & powercfg /setactive $guid 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "Power plan set to $PowerPlan." 'OK' } else { Write-Log "Could not set power plan (plan may be hidden)." 'WARN' }
    }
}

# --- 3. RDP ------------------------------------------------------------------
if ($EnableRDP -and $PSCmdlet.ShouldProcess("Remote Desktop", "Enable with NLA")) {
    try {
        Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
        Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Write-Log "Remote Desktop enabled (NLA on)." 'OK'
    } catch { Write-Log "RDP enable failed: $($_.Exception.Message)" 'WARN' }
}

# --- 4. time zone ------------------------------------------------------------
if ($TimeZone -and $PSCmdlet.ShouldProcess("Time zone", "Set to $TimeZone")) {
    try { Set-TimeZone -Id $TimeZone -ErrorAction Stop; Write-Log "Time zone set to $TimeZone." 'OK' }
    catch { Write-Log "Time zone failed (check the id with 'Get-TimeZone -ListAvailable'): $($_.Exception.Message)" 'WARN' }
}

# --- 5. software -------------------------------------------------------------
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Log "winget not found — install 'App Installer' from the Store, then re-run for software." 'WARN'
} elseif ($Apps) {
    Write-Log "Installing $($Apps.Count) app(s) via winget..." 'STEP'
    foreach ($id in $Apps) {
        if ($PSCmdlet.ShouldProcess($id, "winget install")) {
            Write-Log "  installing $id ..." 'INFO'
            & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Log "  $id installed." 'OK' } else { Write-Log "  $id returned exit $LASTEXITCODE (may already be installed)." 'WARN' }
        }
    }
}

# --- 6. updates --------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("Windows Update", "Trigger scan")) {
    if (Get-Module -ListAvailable PSWindowsUpdate) {
        Import-Module PSWindowsUpdate
        Write-Log "Scanning for updates (PSWindowsUpdate)..." 'STEP'
        try { Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop | Format-Table -AutoSize | Out-Host } catch { Write-Log "Update scan issue: $($_.Exception.Message)" 'WARN' }
    } else {
        Write-Log "PSWindowsUpdate not installed. Opening Windows Update settings." 'INFO'
        if ([Environment]::UserInteractive) { Start-Process 'ms-settings:windowsupdate' }
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Provisioning steps done." -ForegroundColor Green
    if ($NewName -and $env:COMPUTERNAME -ne $NewName) { Write-Host "  Reboot to apply the new name ($NewName)." -ForegroundColor DarkYellow }
    Write-Host "  For domain join, run: 04-PC-Provisioning\Join-Domain.ps1" -ForegroundColor White
    Write-Log "New PC provisioning finished." 'OK'
}
