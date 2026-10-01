<#
.SYNOPSIS
    Create an Intune "Custom" configuration profile (OMA-URI/CSP-backed) that
    delivers the CSP-mappable subset of 02-Windows11\Disable-Win11AITelemetry.ps1
    as a real, centrally-managed policy instead of a per-machine script.

.DESCRIPTION
    Not every setting in the Win11 baseline scripts has an official CSP —
    taskbar alignment and several Explorer cosmetics are per-user preferences
    with no policy backing, and stay as script deployment (see
    Deploy-ScriptViaIntune.ps1). This script covers the subset that DOES have a
    documented, policy-backed CSP:

      - Turn off Windows Copilot            (Policy CSP: WindowsAI/TurnOffWindowsCopilot)
      - Telemetry level                     (Policy CSP: System/AllowTelemetry)
      - Tailored experiences w/ diagnostics (Policy CSP: Experience/AllowTailoredExperiencesWithDiagnosticData)

    Recall / "AI data analysis" is deliberately left OUT of this script:
    Microsoft has renamed and restructured the Recall-related policies more
    than once across 24H2/25H2 builds. Verify the current CSP name against
    Microsoft Learn (Policy CSP - WindowsAI) for your target build before
    adding it — don't trust an older write-up (including this one) blindly.

    Creates a Windows10CustomConfiguration profile via Graph and assigns it to
    a group. Devices apply CSPs on their normal Intune sync — same cadence as
    any other configuration profile, generally faster and more reliable than a
    script re-run since it's enforced, not just executed once.

.PARAMETER GroupName
    Entra group (device group) to assign the profile to.
.PARAMETER ProfileName
    Display name in Intune (default 'Win11 Baseline (Copilot/Telemetry)').
.PARAMETER TelemetryLevel
    0=Security (Enterprise/Education only), 1=Basic, 2=Enhanced (deprecated),
    3=Full. Default 1.

.EXAMPLE
    .\New-IntuneConfigProfile-Win11Baseline.ps1 -GroupName "Intune-Managed-Win11" -WhatIf
.EXAMPLE
    .\New-IntuneConfigProfile-Win11Baseline.ps1 -GroupName "Intune-Managed-Win11" -TelemetryLevel 1

.NOTES
    Requires Microsoft.Graph.DeviceManagement and Intune Administrator rights.
    Consent scopes: DeviceManagementConfiguration.ReadWrite.All, Group.Read.All.
    CSP paths verified against Microsoft Learn's Policy CSP reference as of this
    script's writing — Microsoft does change these, so a failed apply on a
    specific build is a reason to check Microsoft Learn, not assume the script
    is broken. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$GroupName,
    [string]$ProfileName = 'Win11 Baseline (Copilot/Telemetry)',
    [ValidateSet(0, 1, 2, 3)][int]$TelemetryLevel = 1
)

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
if (-not $PSBoundParameters.ContainsKey('GroupName')) { $__v = Get-ToolkitSetting 'Entra.DefaultDeviceGroup'; if ($null -ne $__v) { $GroupName = $__v; $__cfgUsed += 'Entra.DefaultDeviceGroup' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------
# required values that may come from Config - checked here, after the lookup, instead of [Parameter(Mandatory)] (which would prompt before Config is read)
if (-not $GroupName) { Write-Host "  [ERROR] Missing: -GroupName <Entra device group> (or Entra.DefaultDeviceGroup in Config)" -ForegroundColor Red; return }


# --- toolkit helpers (standalone-safe) -------------------------------------
# Uses _GraphCommon.psm1 when it sits next to this script (inside the kit).
# Copied out on its own, this script self-provides the same helpers.
$__graph = Join-Path $PSScriptRoot '_GraphCommon.psm1'
if (Test-Path $__graph) {
    Import-Module $__graph -Force
} else {
    function Get-ToolkitRoot { param([string]$Path = 'C:\Sysadmin-Toolkit')
        try { foreach ($s in @('','Reports','Backups','Logs')) { $p = if ($s) { Join-Path $Path $s } else { $Path }; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } } } catch { }
        return $Path }
    function Write-Log { param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
        $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
        Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
        try { $lf = Join-Path (Get-ToolkitRoot) ("Logs\Toolkit_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd')); Add-Content -Path $lf -Value ("[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -Encoding UTF8 -WhatIf:$false -ErrorAction Stop } catch { } }
    function Write-Banner { param([Parameter(Mandatory)][string]$Title) Write-Host ''; Write-Host "  Sysadmin-Toolkit :: $Title" -ForegroundColor White; Write-Host ('  ' + ('=' * ($Title.Length + 8))) -ForegroundColor DarkGray }
    function Connect-ToolkitGraph { [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Scopes,[string]$TenantId)
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'; return $false }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext
        $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru | Where-Object { $Scopes -contains $_ }))
        if ($ctx -and $haveAll) { Write-Log "Reusing existing Graph connection ($($ctx.Account))." 'INFO'; return $true }
        Write-Log "Connecting to Microsoft Graph (scopes: $($Scopes -join ', '))..." 'STEP'
        try { $p = @{ Scopes = $Scopes; NoWelcome = $true }; if ($TenantId) { $p.TenantId = $TenantId }; Connect-MgGraph @p -ErrorAction Stop; Write-Log "Connected as $((Get-MgContext).Account)." 'OK'; return $true }
        catch { Write-Log "Graph connection failed: $($_.Exception.Message)" 'ERROR'; return $false } }
    function Test-GraphScope { param([Parameter(Mandatory)][string]$Scope) $ctx = Get-MgContext; if (-not $ctx) { return $false }; return ($ctx.Scopes -contains $Scope) }
}
Write-Banner "Intune Config Profile: Win11 Baseline"

$scopes = @('DeviceManagementConfiguration.ReadWrite.All', 'Group.Read.All')
if (-not (Connect-ToolkitGraph -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

$group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
if (-not $group) { Write-Log "Group '$GroupName' not found in Entra." 'ERROR'; return }

# OMA-URI settings — each one documented in Microsoft's Policy CSP reference.
$omaSettings = @(
    @{
        '@odata.type' = '#microsoft.graph.omaSettingInteger'
        displayName   = 'Turn off Windows Copilot'
        omaUri        = './Device/Vendor/MSFT/Policy/Config/WindowsAI/TurnOffWindowsCopilot'
        value         = 1
    },
    @{
        '@odata.type' = '#microsoft.graph.omaSettingInteger'
        displayName   = 'Allow Telemetry'
        omaUri        = './Device/Vendor/MSFT/Policy/Config/System/AllowTelemetry'
        value         = $TelemetryLevel
    },
    @{
        '@odata.type' = '#microsoft.graph.omaSettingInteger'
        displayName   = 'Allow Tailored Experiences With Diagnostic Data'
        omaUri        = './Device/Vendor/MSFT/Policy/Config/Experience/AllowTailoredExperiencesWithDiagnosticData'
        value         = 0
    }
)

Write-Log "Profile   : $ProfileName" 'INFO'
Write-Log "Settings  : $($omaSettings.Count) OMA-URI value(s) — Copilot off, telemetry=$TelemetryLevel, tailored experiences off" 'INFO'
Write-Log "Target    : $GroupName" 'INFO'

$body = @{
    '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'
    displayName   = $ProfileName
    description   = 'Copilot/telemetry baseline — created by Sysadmin-Toolkit New-IntuneConfigProfile-Win11Baseline.ps1'
    omaSettings   = $omaSettings
}

$existing = Get-MgDeviceManagementDeviceConfiguration -All -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $ProfileName } | Select-Object -First 1

if ($existing) {
    if ($PSCmdlet.ShouldProcess($ProfileName, "Update existing profile (id $($existing.Id))")) {
        try {
            Update-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $existing.Id -BodyParameter $body -ErrorAction Stop
            $profileId = $existing.Id
            Write-Log "Updated existing profile." 'OK'
        } catch { Write-Log "Update failed: $($_.Exception.Message)" 'ERROR'; return }
    } else { return }
} else {
    if ($PSCmdlet.ShouldProcess($ProfileName, "Create profile")) {
        try {
            $created = New-MgDeviceManagementDeviceConfiguration -BodyParameter $body -ErrorAction Stop
            $profileId = $created.Id
            Write-Log "Created profile (id $profileId)." 'OK'
        } catch { Write-Log "Create failed: $($_.Exception.Message)" 'ERROR'; return }
    } else { return }
}

if ($PSCmdlet.ShouldProcess($ProfileName, "Assign to group $GroupName")) {
    try {
        $assignment = @{ assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $group.Id } }) }
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations/$profileId/assign" -Body $assignment -ErrorAction Stop
        Write-Log "Assigned to $GroupName." 'OK'
    } catch { Write-Log "Assignment failed: $($_.Exception.Message)" 'WARN' }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Profile deployed. Devices apply it on their next Intune sync." -ForegroundColor Green
    Write-Host "  Everything NOT covered here (taskbar, Explorer cosmetics, Recall) is still" -ForegroundColor White
    Write-Host "  best delivered as a script — see Deploy-ScriptViaIntune.ps1." -ForegroundColor White
    Write-Log "Intune config profile '$ProfileName' deployed." 'OK'
}
