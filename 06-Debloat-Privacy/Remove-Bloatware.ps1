<#
.SYNOPSIS
    Remove pre-installed Windows bloatware from a curated SAFE list — provisioned
    (new-user) and installed AppX packages.

.DESCRIPTION
    Removes only apps on a hand-picked safe list (games, promo apps, Bing junk,
    consumer clutter). It NEVER touches things that break the OS — Store,
    Calculator, Photos, security, .NET/VCLibs runtimes, Terminal, etc. Default
    is a DRY RUN: it lists what it *would* remove. Add -Execute to actually
    remove.

    It removes both the installed copy (current user) and the provisioned copy
    (so new user profiles don't get it back). -AllUsers also strips it from
    every existing profile.

    Show the full list with -List. Add your own IDs with -Extra, or keep some
    with -Keep.

.PARAMETER Execute
    Actually remove. Without this it only reports (dry run).
.PARAMETER AllUsers
    Remove the installed package for all user profiles, not just the current one.
.PARAMETER List
    Print the curated safe list and exit.
.PARAMETER Extra
    Additional package-name wildcards to remove (e.g. 'Spotify*').
.PARAMETER Keep
    Package-name wildcards to exclude from removal this run.

.EXAMPLE
    .\Remove-Bloatware.ps1 -List
.EXAMPLE
    .\Remove-Bloatware.ps1            # dry run — shows what would go
.EXAMPLE
    .\Remove-Bloatware.ps1 -Execute -AllUsers

.NOTES
    Run as Administrator (needed for provisioned + all-users removal).
    A record of what was removed is written to the Backups folder.
    Reinstall anything from the Microsoft Store if a user complains.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$Execute,
    [switch]$AllUsers,
    [switch]$List,
    [string[]]$Extra,
    [string[]]$Keep,
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
if (-not $PSBoundParameters.ContainsKey('Extra')) { $__v = Get-ToolkitSetting 'Provisioning.BloatwareExtra'; if ($null -ne $__v) { $Extra = $__v; $__cfgUsed += 'Provisioning.BloatwareExtra' } }
if (-not $PSBoundParameters.ContainsKey('Keep')) { $__v = Get-ToolkitSetting 'Provisioning.BloatwareKeep'; if ($null -ne $__v) { $Keep = $__v; $__cfgUsed += 'Provisioning.BloatwareKeep' } }
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
Write-Banner "Debloat — remove bloatware"

# --- curated SAFE list (wildcards match PackageFullName / Name) --------------
$bloat = @(
    'Microsoft.3DBuilder', 'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D',
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingFinance', 'Microsoft.BingSports',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.WindowsFeedbackHub',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftMahjong',
    'Microsoft.People', 'Microsoft.windowscommunicationsapps',   # Mail & Calendar / People
    'Microsoft.SkypeApp', 'Microsoft.MixedReality.Portal',
    'Microsoft.WindowsMaps', 'Microsoft.Wallet', 'Microsoft.OneConnect',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.Office.OneNote',   # the promo hub, not real Office
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',                 # Groove / Films&TV (legacy)
    'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'MicrosoftTeams', 'MicrosoftCorporationII.QuickAssist',
    'Clipchamp.Clipchamp', 'Microsoft.GamingApp', 'Microsoft.XboxApp',
    'Microsoft.Xbox.TCUI', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
    # common OEM / third-party consumer promos
    'king.com.*', 'Facebook*', 'Spotify*', 'Disney*', '*CandyCrush*', '*Netflix*', '*TikTok*', '*Instagram*', '*Twitter*', '*Duolingo*', '*Roblox*', '*.Amazon.com.Amazon*'
)

# --- NEVER-touch guard (protects the OS regardless of matches) --------------
$protect = @(
    '*Store*', '*Calculator*', '*Photos*', '*ScreenSketch*', '*SnippingTool*',
    '*WindowsTerminal*', '*Notepad*', '*Paint*', '*SecHealthUI*', '*Defender*',
    '*VCLibs*', '*NET.Native*', '*DesktopAppInstaller*', '*WebpPlatform*', '*UI.Xaml*',
    '*WindowsStore*', '*StorePurchaseApp*', '*Windows.Photos*', '*ImmersiveControlPanel*',
    '*AAD.BrokerPlugin*', '*AccountsControl*', '*LockApp*', '*ShellExperienceHost*', '*StartMenuExperienceHost*'
)

if ($Extra) { $bloat += $Extra }
if ($Keep)  { $protect += $Keep }

if ($List) {
    Write-Host "`n  Curated bloatware removal list:" -ForegroundColor White
    $bloat | Sort-Object | ForEach-Object { Write-Host "   - $_" -ForegroundColor Gray }
    Write-Host "`n  Always protected (never removed):" -ForegroundColor White
    $protect | Sort-Object | ForEach-Object { Write-Host "   - $_" -ForegroundColor DarkGray }
    return
}

if ($Execute -and -not (Assert-Admin)) { return }

function Test-Protected([string]$name) {
    foreach ($p in $protect) { if ($name -like $p) { return $true } }
    return $false
}

# --- find matches ------------------------------------------------------------
$installed = if ($AllUsers) { Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue } else { Get-AppxPackage -ErrorAction SilentlyContinue }
$provisioned = try { Get-AppxProvisionedPackage -Online -ErrorAction Stop } catch { @() }

$toRemove = New-Object System.Collections.Generic.List[object]
foreach ($pkg in $installed) {
    foreach ($b in $bloat) {
        if ($pkg.Name -like $b -and -not (Test-Protected $pkg.Name)) {
            $toRemove.Add([pscustomobject]@{ Kind = 'Installed'; Name = $pkg.Name; Full = $pkg.PackageFullName }); break
        }
    }
}
foreach ($pkg in $provisioned) {
    foreach ($b in $bloat) {
        if ($pkg.DisplayName -like $b -and -not (Test-Protected $pkg.DisplayName)) {
            $toRemove.Add([pscustomobject]@{ Kind = 'Provisioned'; Name = $pkg.DisplayName; Full = $pkg.PackageName }); break
        }
    }
}

if (-not $toRemove.Count) { Write-Log "Nothing on the safe list is present. Clean already." 'OK'; return }

Write-Log "$($toRemove.Count) package(s) matched:" 'STEP'
$toRemove | Sort-Object Kind, Name | Format-Table -AutoSize | Out-Host

if (-not $Execute) {
    Write-Host "  DRY RUN — nothing removed. Re-run with -Execute to remove these." -ForegroundColor DarkYellow
    return
}

# A non-interactive session (OpsBoard, a scheduled task, remoting) can't answer
# the per-app "Remove?" question - every app would fail on its own. Stop once,
# clearly, unless the caller has already confirmed (-Force / -Confirm:$false /
# SYSADMIN_TOOLKIT_FORCE=1).
if (-not $script:__ntForce -and $ConfirmPreference -ne 'None' -and -not [Environment]::UserInteractive) {
    Write-Log "Non-interactive session: can't ask 'Remove?' per app. Re-run with -Force (the caller confirms). Nothing was removed." 'ERROR'
    return
}

# record what we're about to remove
$root = Get-ToolkitRoot
$log  = Join-Path $root ("Backups\Debloat_removed_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))
$toRemove | Format-Table -AutoSize | Out-File $log -Encoding UTF8
Write-Log "Record of removals -> $log" 'INFO'

$removed = 0; $failed = 0; $skipped = 0; $gone = 0
foreach ($item in $toRemove) {
    if (-not $PSCmdlet.ShouldProcess($item.Name, "Remove ($($item.Kind))")) { $skipped++; continue }
    if ($true) {
        try {
            if ($item.Kind -eq 'Installed') {
                # find first, then remove: "Removed" only when something was really there
                $pkgs = @(if ($AllUsers) { Get-AppxPackage -AllUsers -Name $item.Name -ErrorAction SilentlyContinue }
                          else           { Get-AppxPackage -Name $item.Name -ErrorAction SilentlyContinue })
                if ($pkgs.Count -eq 0) { Write-Log "$($item.Name) is no longer installed - nothing to remove." 'INFO'; $gone++; continue }
                if ($AllUsers) { $pkgs | Remove-AppxPackage -AllUsers -ErrorAction Stop }
                else           { $pkgs | Remove-AppxPackage -ErrorAction Stop }
            } else {
                # Windows 11 often removes the template together with the installed
                # app (-AllUsers). If removing the template errors, look again: if
                # it's gone, it's "already gone", not a failure.
                try { Remove-AppxProvisionedPackage -Online -PackageName $item.Full -ErrorAction Stop | Out-Null }
                catch {
                    $still = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.PackageName -eq $item.Full })
                    if ($still.Count -eq 0) { Write-Log "$($item.Name): template already removed together with the installed app." 'INFO'; $gone++; continue }
                    throw
                }
            }
            Write-Log "Removed $($item.Name)" 'OK'; $removed++
        } catch { Write-Log "Could not remove $($item.Name): $($_.Exception.Message)" 'WARN'; $failed++ }
    }
}

# honest summary: what actually happened, not just "complete"
$summary = "Debloat result: $removed removed, $gone already gone, $failed failed, $skipped skipped (of $($toRemove.Count) matched)."
Add-Content -Path $log -Value ('', $summary) -Encoding UTF8
Write-Host ''
$colour = if ($failed -gt 0 -or ($removed + $gone -eq 0 -and $toRemove.Count -gt 0)) { 'Yellow' } else { 'Green' }
Write-Host "  $summary" -ForegroundColor $colour
Write-Host "  Record saved to $log" -ForegroundColor White
if ($removed -gt 0) { Write-Host "  To reinstall any app, get it from the Microsoft Store." -ForegroundColor White }
Write-Log "Debloat finished: $removed removed, $gone already gone, $failed failed, $skipped skipped." $(if ($failed -gt 0) { 'WARN' } else { 'OK' })
