<#
.SYNOPSIS
    Push ANY script from this toolkit (or any .ps1) out to your fleet as an
    Intune device management script — no GPO, no manual per-PC runs.

.DESCRIPTION
    Uploads a PowerShell script as an Intune "Platform script" (Win32/Windows
    device management script), runs it as SYSTEM (or the signed-in user), and
    assigns it to a group. This is the practical bridge between everything else
    in this kit and a fleet you manage through Intune — e.g. push
    02-Windows11\Set-Win11Baseline.ps1 or 06-Debloat-Privacy\Remove-Bloatware.ps1
    to every machine in a group, on Intune's own schedule (roughly every hour,
    then daily), instead of running it by hand on each PC.

    If a script is already deployed under the same -Name, this UPDATES it
    (new script content, same assignment) rather than creating a duplicate.

.PARAMETER ScriptPath
    Local path to the .ps1 to deploy.
.PARAMETER Name
    Display name in Intune (also the "same script" key for updates).
.PARAMETER GroupName
    Entra group to assign it to (device group for RunAsAccount SYSTEM, user
    group for RunAsAccount User).
.PARAMETER RunAsAccount
    'System' (default) or 'User'.
.PARAMETER RunAs32Bit
    Run in a 32-bit PowerShell host. Default off (64-bit).
.PARAMETER Description
    Optional description shown in the Intune console.

.EXAMPLE
    .\Deploy-ScriptViaIntune.ps1 -ScriptPath ..\02-Windows11\Set-Win11Baseline.ps1 `
        -Name "Win11 Baseline" -GroupName "Intune-Managed-Win11" -WhatIf
.EXAMPLE
    .\Deploy-ScriptViaIntune.ps1 -ScriptPath ..\07-Reporting-Health\Invoke-HealthCheck.ps1 `
        -Name "Daily Health Check" -GroupName "All-Managed-Devices"

.NOTES
    Requires Microsoft.Graph.DeviceManagement and Intune Administrator (or
    equivalent) rights. First run prompts for consent to:
    DeviceManagementManagedDevices.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All, Group.Read.All.

    Intune device scripts run on its own check-in cycle, not instantly — expect
    up to ~1 hour for the policy to reach a device, then it re-runs roughly
    daily (or whenever the script content changes). For a one-time immediate
    push to specific machines, TechToolkit's Remote Tools department or a
    direct PsExec/WinRM session is faster.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$Name,
    [string]$GroupName,
    [ValidateSet('System', 'User')][string]$RunAsAccount = 'System',
    [switch]$RunAs32Bit,
    [string]$Description = 'Deployed via Sysadmin-Toolkit Deploy-ScriptViaIntune.ps1'
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
if (-not $GroupName) { Write-Host "  [ERROR] Missing: -GroupName <Entra group> (or Entra.DefaultDeviceGroup in Config)" -ForegroundColor Red; return }


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
Write-Banner "Deploy Script via Intune"

if (-not (Test-Path $ScriptPath)) { Write-Log "Script not found: $ScriptPath" 'ERROR'; return }
$scopes = @('DeviceManagementManagedDevices.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'Group.Read.All')
if (-not (Connect-ToolkitGraph -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.DeviceManagement, Microsoft.Graph.Groups -ErrorAction Stop

$group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
if (-not $group) { Write-Log "Group '$GroupName' not found in Entra." 'ERROR'; return }

$scriptContent = Get-Content -Path $ScriptPath -Raw -Encoding UTF8
$scriptBytes   = [System.Text.Encoding]::UTF8.GetBytes($scriptContent)
$scriptB64     = [Convert]::ToBase64String($scriptBytes)
$fileName      = Split-Path $ScriptPath -Leaf

Write-Log "Script    : $fileName ($([math]::Round($scriptBytes.Length/1KB,1)) KB)" 'INFO'
Write-Log "Intune name: $Name" 'INFO'
Write-Log "Target group: $GroupName" 'INFO'
Write-Log "Runs as   : $RunAsAccount" 'INFO'

# does a script with this display name already exist? (update path)
$existing = Get-MgDeviceManagementDeviceManagementScript -All -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq $Name } | Select-Object -First 1

$body = @{
    displayName            = $Name
    description             = $Description
    scriptContent           = $scriptB64
    fileName                = $fileName
    runAsAccount             = $RunAsAccount
    enforceSignatureCheck    = $false
    runAs32Bit               = [bool]$RunAs32Bit
}

if ($existing) {
    if ($PSCmdlet.ShouldProcess($Name, "Update existing Intune script (id $($existing.Id))")) {
        try {
            Update-MgDeviceManagementDeviceManagementScript -DeviceManagementScriptId $existing.Id -BodyParameter $body -ErrorAction Stop
            Write-Log "Updated existing Intune script '$Name'." 'OK'
            $scriptId = $existing.Id
        } catch { Write-Log "Update failed: $($_.Exception.Message)" 'ERROR'; return }
    } else { return }
} else {
    if ($PSCmdlet.ShouldProcess($Name, "Create new Intune script")) {
        try {
            $created = New-MgDeviceManagementDeviceManagementScript -BodyParameter $body -ErrorAction Stop
            $scriptId = $created.Id
            Write-Log "Created Intune script '$Name' (id $scriptId)." 'OK'
        } catch { Write-Log "Create failed: $($_.Exception.Message)" 'ERROR'; return }
    } else { return }
}

# assignment (idempotent — replaces existing assignments with this one group)
$assignBody = @{
    deviceManagementScriptGroupAssignments = @(
        @{ targetGroupId = $group.Id }
    )
}
if ($PSCmdlet.ShouldProcess($Name, "Assign to group $GroupName")) {
    try {
        # the cmdlet name varies by SDK version; fall back to a raw Graph call if it's not present
        if (Get-Command Set-MgDeviceManagementDeviceManagementScriptGroupAssignment -ErrorAction SilentlyContinue) {
            Set-MgDeviceManagementDeviceManagementScriptGroupAssignment -DeviceManagementScriptId $scriptId -BodyParameter $assignBody -ErrorAction Stop
        } else {
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts/$scriptId/assign" -Body $assignBody -ErrorAction Stop
        }
        Write-Log "Assigned to $GroupName." 'OK'
    } catch { Write-Log "Assignment failed: $($_.Exception.Message)" 'WARN' }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Deployed. Devices in '$GroupName' pick this up on their next Intune check-in" -ForegroundColor Green
    Write-Host "  (typically within ~1 hour, then re-checked roughly daily)." -ForegroundColor White
    Write-Log "Intune script deployment finished for '$Name'." 'OK'
}
