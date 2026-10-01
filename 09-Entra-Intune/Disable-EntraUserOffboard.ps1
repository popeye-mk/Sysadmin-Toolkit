<#
.SYNOPSIS
    Offboard a user in Entra ID via Microsoft Graph — block sign-in, kill active
    sessions, strip licenses and group membership, and optionally retire their
    primary Intune device. Cloud-native leaver flow.

.DESCRIPTION
    Best-practice departure handling, cloud side:
      1. Blocks sign-in (accountEnabled = false).
      2. Revokes all refresh/session tokens (kills active sessions everywhere,
         including already-open apps).
      3. Records current group memberships to a file, then removes the user
         from every group (Domain Users / dynamic-membership groups excluded —
         those clear themselves).
      4. Removes all assigned licenses (frees the seat).
      5. Stamps a note on the account (department field) with who/when/why.
      6. Optionally lists the user's Intune-managed devices and retires them
         (wipes company data, leaves personal data — the standard leaver
         action; add -WipeDevices to actually do it, otherwise just reports).

    The account itself is NOT deleted — that stays a deliberate, separate step
    (Remove-MgUser) after your retention window, same as the on-prem script's
    "disable, don't delete" philosophy.

.PARAMETER UserPrincipalName
    The leaver's UPN.
.PARAMETER Reason
    Free text stamped on the account (default 'Offboarded').
.PARAMETER WipeDevices
    Also retire (wipe corporate data from) the user's Intune-managed devices.
    Without this switch, matching devices are only listed.

.EXAMPLE
    .\Disable-EntraUserOffboard.ps1 -UserPrincipalName jan.peeters@contoso.com -WhatIf
.EXAMPLE
    .\Disable-EntraUserOffboard.ps1 -UserPrincipalName jan.peeters@contoso.com -Reason "Left 2026-09-30" -WipeDevices

.NOTES
    Requires Microsoft.Graph and a User Administrator (+ Intune Administrator
    for the device retire step) role. First run prompts for consent to:
    User.ReadWrite.All, Group.ReadWrite.All, DeviceManagementManagedDevices.PrivilegedOperations.All.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$Reason = 'Offboarded',
    [switch]$WipeDevices,
    [switch]$Force
)

$script:__ntForce = $false
if ($Force -or $env:SYSADMIN_TOOLKIT_FORCE -eq '1') { $ConfirmPreference = 'None'; $script:__ntForce = $true }

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
Write-Banner "Entra User Offboard"

$scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementManagedDevices.Read.All')
if (-not (Connect-ToolkitGraph -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions -ErrorAction Stop

$user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -Property Id,DisplayName,AccountEnabled,AssignedLicenses -ErrorAction SilentlyContinue
if (-not $user) { Write-Log "No Entra account found for $UserPrincipalName." 'ERROR'; return }
Write-Log "Offboarding: $($user.DisplayName) ($UserPrincipalName)" 'STEP'

# --- 1. block sign-in ----------------------------------------------------------
if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Disable account (block sign-in)")) {
    try { Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop; Write-Log "Sign-in blocked." 'OK' }
    catch { Write-Log "Block sign-in failed: $($_.Exception.Message)" 'ERROR' }
}

# --- 2. revoke sessions ----------------------------------------------------------
if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Revoke all sign-in sessions")) {
    try { Invoke-MgInvalidateUserRefreshToken -UserId $user.Id -ErrorAction Stop | Out-Null; Write-Log "All sessions revoked." 'OK' }
    catch { Write-Log "Session revoke failed: $($_.Exception.Message)" 'WARN' }
}

# --- 3. record + strip groups ---------------------------------------------------
$root   = Get-ToolkitRoot
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$grpLog = Join-Path $root ("Backups\EntraGroups_{0}_{1}.txt" -f ($UserPrincipalName -replace '[^\w\.-]','_'), $stamp)
$memberships = @(Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction SilentlyContinue)
$groups = $memberships | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group' }

if ($groups.Count) {
    if ($PSCmdlet.ShouldProcess($grpLog, "Save current group list")) {
        $groups | ForEach-Object { "$($_.Id)  $($_.AdditionalProperties.displayName)" } | Out-File -FilePath $grpLog -Encoding UTF8
        Write-Log "Saved $($groups.Count) group membership(s) -> $grpLog" 'OK'
    }
    foreach ($g in $groups) {
        $gName = $g.AdditionalProperties.displayName
        $isDynamic = $g.AdditionalProperties.groupTypes -contains 'DynamicMembership'
        if ($isDynamic) { Write-Log "  $gName is dynamic-membership — clears itself once attributes change, skipping." 'INFO'; continue }
        if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove from $gName")) {
            try { Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop; Write-Log "Removed from $gName" 'OK' }
            catch { Write-Log "Could not remove from ${gName}: $($_.Exception.Message)" 'WARN' }
        }
    }
} else { Write-Log "No group memberships found." 'INFO' }

# --- 4. remove licenses ----------------------------------------------------------
$skuIds = @($user.AssignedLicenses | ForEach-Object { $_.SkuId })
if ($skuIds.Count) {
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove $($skuIds.Count) license(s)")) {
        try { Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds -ErrorAction Stop; Write-Log "Licenses removed (seat(s) freed)." 'OK' }
        catch { Write-Log "License removal failed: $($_.Exception.Message)" 'WARN' }
    }
} else { Write-Log "No licenses assigned." 'INFO' }

# --- 5. stamp a note --------------------------------------------------------------
$note = "$Reason by $env:USERNAME on $(Get-Date -Format 'yyyy-MM-dd')"
if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Stamp department field with offboard note")) {
    try { Update-MgUser -UserId $user.Id -Department $note -ErrorAction Stop; Write-Log "Note: $note" 'OK' }
    catch { Write-Log "Could not stamp note: $($_.Exception.Message)" 'WARN' }
}

# --- 6. Intune devices -------------------------------------------------------------
try {
    Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
    $devices = @(Get-MgDeviceManagementManagedDevice -Filter "userId eq '$($user.Id)'" -ErrorAction SilentlyContinue)
    if ($devices.Count) {
        Write-Log "$($devices.Count) Intune-managed device(s) found for this user:" 'STEP'
        $devices | ForEach-Object { Write-Log "  $($_.DeviceName)  ($($_.OperatingSystem), last sync $($_.LastSyncDateTime))" 'INFO' }
        if ($WipeDevices) {
            foreach ($d in $devices) {
                if ($PSCmdlet.ShouldProcess($d.DeviceName, "Retire (remove company data)")) {
                    try { Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $d.Id -ErrorAction Stop; Write-Log "Retire requested for $($d.DeviceName)." 'OK' }
                    catch { Write-Log "Retire failed for $($d.DeviceName): $($_.Exception.Message)" 'WARN' }
                }
            }
        } else {
            Write-Host "  Devices listed above but NOT retired. Re-run with -WipeDevices to retire them." -ForegroundColor DarkYellow
        }
    } else { Write-Log "No Intune-managed devices found for this user." 'INFO' }
} catch { Write-Log "Could not query Intune devices (module missing or insufficient rights): $($_.Exception.Message)" 'WARN' }

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Offboarding complete for $UserPrincipalName." -ForegroundColor Green
    Write-Host "  Group list saved to: $grpLog" -ForegroundColor White
    Write-Host "  Account is DISABLED, not deleted. Remove it manually after your retention window." -ForegroundColor DarkYellow
    Write-Log "Entra offboarding finished for $UserPrincipalName" 'OK'
}
