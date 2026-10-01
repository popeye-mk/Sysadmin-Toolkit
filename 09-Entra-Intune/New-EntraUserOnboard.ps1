<#
.SYNOPSIS
    Onboard a new user directly in Entra ID (cloud-native) via Microsoft Graph —
    the joiner flow for a tenant with no on-prem AD, or for a cloud-only account
    alongside a synced on-prem population.

.DESCRIPTION
    Creates the Entra user with a temp password (force change at next sign-in),
    sets usage location (required before license assignment), assigns one or
    more licenses by SKU, adds the user to groups (including, typically, your
    Intune/Autopilot dynamic or assigned groups), sets manager, and optionally
    copies another user's group memberships.

    This is the cloud-native counterpart to 01-Users\New-ADUserOnboard.ps1. If
    your tenant syncs from on-prem AD (Entra Connect), create the account there
    instead and use THIS script only for the post-sync steps: licensing, cloud
    group membership, and manager — pass -ExistingUser to skip account creation.

.PARAMETER DisplayName
    Name fields.
.PARAMETER GivenName
    Name fields.
.PARAMETER Surname
    Name fields.
.PARAMETER UserPrincipalName
    UPN, e.g. jan.peeters@contoso.com. Must be in a verified domain of the tenant.
.PARAMETER UsageLocation
    Two-letter ISO country code, required before license assignment (e.g. 'BE').
.PARAMETER LicenseSkuIds
    One or more SKU IDs (GUIDs) to assign. Use Get-MgSubscribedSku to list what
    your tenant has and their skuId.
.PARAMETER Groups
    Display names of Entra groups to add the user to (assigned, not dynamic —
    dynamic groups pick the user up automatically once attributes match).
.PARAMETER CopyGroupsFrom
    UPN of an existing user whose (assigned) group memberships to copy.
.PARAMETER Manager
    UPN of the manager.
.PARAMETER JobTitle
    Optional directory attributes.
.PARAMETER Department
    Optional directory attributes.
.PARAMETER OfficeLocation
    Optional directory attributes.
.PARAMETER ExistingUser
    Skip account creation — treat -UserPrincipalName as an existing user and
    only apply usage location, licenses, groups, and manager. Use this in a
    hybrid tenant where the account itself was created on-prem and synced.

.EXAMPLE
    .\New-EntraUserOnboard.ps1 -DisplayName "Jan Peeters" -GivenName Jan -Surname Peeters `
        -UserPrincipalName jan.peeters@contoso.com -UsageLocation BE `
        -LicenseSkuIds "c7df2760-2c81-4ef7-b578-5b5392b571df" -Groups "All-Staff","Intune-Managed" -WhatIf
.EXAMPLE
    # hybrid tenant: account already synced from on-prem, just license + group it
    .\New-EntraUserOnboard.ps1 -UserPrincipalName jan.peeters@contoso.com -ExistingUser `
        -UsageLocation BE -LicenseSkuIds "c7df2760-2c81-4ef7-b578-5b5392b571df" -Groups "Intune-Managed"

.NOTES
    Requires the Microsoft.Graph module and an account with User Administrator
    (or equivalent) role. First run will prompt for admin consent to the scopes:
    User.ReadWrite.All, Group.ReadWrite.All, Directory.Read.All.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$DisplayName,
    [string]$GivenName,
    [string]$Surname,
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$UsageLocation,
    [string[]]$LicenseSkuIds,
    [string[]]$Groups,
    [string]$CopyGroupsFrom,
    [string]$Manager,
    [string]$JobTitle,
    [string]$Department,
    [string]$OfficeLocation,
    [switch]$ExistingUser
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
if (-not $PSBoundParameters.ContainsKey('UsageLocation')) { $__v = Get-ToolkitSetting 'Entra.UsageLocation'; if ($null -ne $__v) { $UsageLocation = $__v; $__cfgUsed += 'Entra.UsageLocation' } }
if (-not $PSBoundParameters.ContainsKey('LicenseSkuIds')) { $__v = Get-ToolkitSetting 'Entra.LicenseSkuIds'; if ($null -ne $__v) { $LicenseSkuIds = $__v; $__cfgUsed += 'Entra.LicenseSkuIds' } }
if (-not $PSBoundParameters.ContainsKey('Groups')) { $__v = Get-ToolkitSetting 'Entra.DefaultGroups'; if ($null -ne $__v) { $Groups = $__v; $__cfgUsed += 'Entra.DefaultGroups' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


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
Write-Banner "Entra User Onboard"

$scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'Organization.Read.All')
if (-not (Connect-ToolkitGraph -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

function New-TempPassword {
    $u='ABCDEFGHJKLMNPQRSTUVWXYZ'; $l='abcdefghijkmnpqrstuvwxyz'; $d='23456789'; $s='!@#$%^&*-_=+?'
    $all=($u+$l+$d+$s).ToCharArray()
    $c=@($u[(Get-Random -Maximum $u.Length)],$l[(Get-Random -Maximum $l.Length)],$d[(Get-Random -Maximum $d.Length)],$s[(Get-Random -Maximum $s.Length)])
    for ($i=$c.Count; $i -lt 16; $i++){ $c += $all[(Get-Random -Maximum $all.Length)] }
    -join ($c | Sort-Object { Get-Random })
}

$existing = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue

if ($ExistingUser) {
    if (-not $existing) { Write-Log "-ExistingUser was set but no account found for $UserPrincipalName." 'ERROR'; return }
    Write-Log "Using existing account: $($existing.DisplayName) ($UserPrincipalName)" 'INFO'
    $user = $existing
} else {
    if ($existing) { Write-Log "$UserPrincipalName already exists. Use -ExistingUser to configure it instead of creating." 'ERROR'; return }
    if (-not $DisplayName) { $DisplayName = "$GivenName $Surname".Trim() }
    if (-not $DisplayName) { Write-Log "Need -DisplayName, or both -GivenName and -Surname." 'ERROR'; return }

    $tempPw = New-TempPassword
    $mailNickname = ($UserPrincipalName -split '@')[0] -replace '[^a-zA-Z0-9._-]', ''

    $body = @{
        accountEnabled    = $true
        displayName       = $DisplayName
        givenName         = $GivenName
        surname           = $Surname
        userPrincipalName = $UserPrincipalName
        mailNickname      = $mailNickname
        passwordProfile   = @{ password = $tempPw; forceChangePasswordNextSignIn = $true }
    }
    if ($JobTitle)       { $body.jobTitle = $JobTitle }
    if ($Department)     { $body.department = $Department }
    if ($OfficeLocation) { $body.officeLocation = $OfficeLocation }
    if ($UsageLocation)  { $body.usageLocation = $UsageLocation }

    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Create Entra user")) {
        try {
            $user = New-MgUser -BodyParameter $body -ErrorAction Stop
            Write-Log "Created $UserPrincipalName." 'OK'
        } catch { Write-Log "Create failed: $($_.Exception.Message)" 'ERROR'; return }
    } else {
        Write-Host "  (WhatIf) would create $UserPrincipalName with a generated temp password." -ForegroundColor DarkYellow
        return
    }
}

# --- usage location (existing user, if not already set) ----------------------
if ($UsageLocation -and $ExistingUser -and $PSCmdlet.ShouldProcess($UserPrincipalName, "Set usage location $UsageLocation")) {
    try { Update-MgUser -UserId $user.Id -UsageLocation $UsageLocation -ErrorAction Stop; Write-Log "Usage location set to $UsageLocation." 'OK' }
    catch { Write-Log "Usage location failed: $($_.Exception.Message)" 'WARN' }
}

# --- licenses ------------------------------------------------------------------
if ($LicenseSkuIds) {
    if (-not $UsageLocation -and -not $ExistingUser) { Write-Log "No -UsageLocation set — license assignment will likely fail (Entra requires it)." 'WARN' }
    $addLicenses = $LicenseSkuIds | ForEach-Object { @{ skuId = $_ } }
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Assign license(s): $($LicenseSkuIds -join ', ')")) {
        try {
            Set-MgUserLicense -UserId $user.Id -AddLicenses $addLicenses -RemoveLicenses @() -ErrorAction Stop
            Write-Log "License(s) assigned." 'OK'
        } catch { Write-Log "License assignment failed: $($_.Exception.Message)" 'WARN' }
    }
}

# --- groups (explicit + copied) -----------------------------------------------
$allGroups = [System.Collections.Generic.HashSet[string]]::new()
if ($Groups) { $Groups | ForEach-Object { [void]$allGroups.Add($_) } }
if ($CopyGroupsFrom) {
    try {
        $src = Get-MgUser -Filter "userPrincipalName eq '$CopyGroupsFrom'" -ErrorAction Stop
        Get-MgUserMemberOf -UserId $src.Id -All | ForEach-Object {
            $g = Get-MgGroup -GroupId $_.Id -ErrorAction SilentlyContinue
            if ($g) { [void]$allGroups.Add($g.DisplayName) }
        }
    } catch { Write-Log "Could not read groups from ${CopyGroupsFrom}: $($_.Exception.Message)" 'WARN' }
}
foreach ($gName in $allGroups) {
    $g = Get-MgGroup -Filter "displayName eq '$gName'" -ErrorAction SilentlyContinue
    if (-not $g) { Write-Log "Group '$gName' not found — skipped." 'WARN'; continue }
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Add to group $gName")) {
        try {
            New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop
            Write-Log "Added to $gName" 'OK'
        } catch { Write-Log "Group '$gName' failed (may already be a member): $($_.Exception.Message)" 'WARN' }
    }
}

# --- manager -------------------------------------------------------------------
if ($Manager) {
    $mgr = Get-MgUser -Filter "userPrincipalName eq '$Manager'" -ErrorAction SilentlyContinue
    if (-not $mgr) { Write-Log "Manager '$Manager' not found — skipped." 'WARN' }
    elseif ($PSCmdlet.ShouldProcess($UserPrincipalName, "Set manager to $Manager")) {
        try {
            $ref = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($mgr.Id)" }
            Set-MgUserManagerByRef -UserId $user.Id -BodyParameter $ref -ErrorAction Stop
            Write-Log "Manager set to $Manager." 'OK'
        } catch { Write-Log "Manager set failed: $($_.Exception.Message)" 'WARN' }
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Onboarding complete: $UserPrincipalName" -ForegroundColor Green
    if (-not $ExistingUser -and $tempPw) {
        Write-Host "  Temp password: $tempPw" -ForegroundColor Yellow
        Write-Host "  (User must change it at first sign-in. Share it securely, not by e-mail.)" -ForegroundColor DarkYellow
    }
    Write-Log "Entra onboarding finished for $UserPrincipalName" 'OK'
}
