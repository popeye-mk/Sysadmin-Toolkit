<#
.SYNOPSIS
    Onboard a new employee across AD *and* Entra/Intune in one command — the
    hybrid joiner flow, in the right order.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    01-Users\New-ADUserOnboard.ps1 and 09-Entra-Intune\New-EntraUserOnboard.ps1
    (this script does its own AD and Graph work inline, on purpose, so it
    doesn't need either of those to exist or to be run first).

    Detects what's available and does the right thing:
      - AD module present and -SkipAD not set: creates the on-prem AD account
        (temp password, groups, manager/title/department/office) — same as
        the on-prem script, just inline here.
      - Microsoft.Graph present and -SkipCloud not set:
          * If the AD step just ran (hybrid): your tenant syncs the account
            to Entra via Entra Connect, which isn't instant. This script
            polls for the synced account to appear (up to -SyncTimeoutMinutes,
            default 30) and then applies the cloud-only bits Entra Connect
            doesn't sync for you — usage location, license, cloud-only
            group membership. If it times out, just re-run the script later:
            it detects the AD account already exists and skips straight to
            the cloud half.
          * If AD isn't available/skipped (cloud-only tenant, or you're
            deliberately doing the cloud half only): creates the account
            directly in Entra instead, with its own temp password.
      - If a step's module isn't installed, or -SkipAD/-SkipCloud is passed,
        that half is skipped with a clear log line — never a hard failure.

    Re-runnable: if the AD account already exists, creation is skipped (not
    an error) and the script moves straight to the cloud half. That's what
    makes "start it, come back after sync finishes, run it again" a normal
    workflow instead of something you have to remember to do differently.

.PARAMETER GivenName
    Name fields (both mandatory).
.PARAMETER Surname
    Name fields (both mandatory).
.PARAMETER SamAccountName
    Login name / UPN prefix. Default: first initial + surname, lower-case.
.PARAMETER UpnSuffix
    UPN/e-mail domain, e.g. 'contoso.com'. Default: current AD domain's DNS
    root (needs the AD half to run once to auto-detect; pass explicitly for
    a cloud-only run).
.PARAMETER OU
    AD target OU. Required if the AD half runs.
.PARAMETER Title
    Directory attributes. Set on-prem if the AD half runs (Entra Connect
    syncs them); set directly via Graph in cloud-only mode.
.PARAMETER Department
    Directory attributes. Set on-prem if the AD half runs (Entra Connect
    syncs them); set directly via Graph in cloud-only mode.
.PARAMETER Office
    Directory attributes. Set on-prem if the AD half runs (Entra Connect
    syncs them); set directly via Graph in cloud-only mode.
.PARAMETER Manager
    SamAccountName (AD half) / UPN (cloud-only half) of the manager.
.PARAMETER Groups
    On-prem AD group names to add.
.PARAMETER CopyGroupsFrom
    SamAccountName of an existing user whose AD groups to copy.
.PARAMETER CloudGroups
    Entra (cloud-only) group display names to add — assigned groups only;
    dynamic groups pick the user up automatically.
.PARAMETER CopyCloudGroupsFrom
    UPN of an existing user whose Entra (assigned) groups to copy.
.PARAMETER UsageLocation
    Two-letter ISO country code, required before Entra license assignment.
    Default 'BE'.
.PARAMETER LicenseSkuIds
    Entra license SKU GUID(s) to assign.
.PARAMETER SkipAD
    Force-skip a half even if its module is available.
.PARAMETER SkipCloud
    Force-skip a half even if its module is available.
.PARAMETER SyncTimeoutMinutes
    How long / how often to poll Entra for the synced account (hybrid mode).
.PARAMETER SyncPollSeconds
    How long / how often to poll Entra for the synced account (hybrid mode).
.PARAMETER TriggerDeltaSync
    Attempt Start-ADSyncSyncCycle -PolicyType Delta before polling — only
    works when run ON the Entra Connect server itself (that's the only place
    the ADSync module exists). Harmless no-op elsewhere.

.EXAMPLE
    .\New-EmployeeOnboard.ps1 -GivenName Jan -Surname Peeters -OU 'OU=Staff,DC=contoso,DC=local' `
        -CopyGroupsFrom mvanden -CopyCloudGroupsFrom mvanden@contoso.com `
        -UsageLocation BE -LicenseSkuIds "c7df2760-2c81-4ef7-b578-5b5392b571df" -WhatIf

.EXAMPLE
    # cloud-only tenant / no on-prem AD reachable from here:
    .\New-EmployeeOnboard.ps1 -GivenName Jan -Surname Peeters -SkipAD -UpnSuffix contoso.com `
        -UsageLocation BE -LicenseSkuIds "c7df2760-2c81-4ef7-b578-5b5392b571df"

.NOTES
    Needs the ActiveDirectory module for the AD half, Microsoft.Graph for the
    cloud half — either or both. First Graph use prompts for consent to:
    User.ReadWrite.All, Group.ReadWrite.All, Directory.Read.All,
    Organization.Read.All. Part of the Sysadmin-Toolkit family.
    Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$GivenName,
    [Parameter(Mandatory)][string]$Surname,
    [string]$SamAccountName,
    [string]$UpnSuffix,
    [string]$OU,
    [string]$Title,
    [string]$Department,
    [string]$Office,
    [string]$Manager,
    [string[]]$Groups,
    [string]$CopyGroupsFrom,
    [string[]]$CloudGroups,
    [string]$CopyCloudGroupsFrom,
    [string]$UsageLocation = 'BE',
    [string[]]$LicenseSkuIds,
    [switch]$SkipAD,
    [switch]$SkipCloud,
    [int]$SyncTimeoutMinutes = 30,
    [int]$SyncPollSeconds = 60,
    [switch]$TriggerDeltaSync
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
if (-not $PSBoundParameters.ContainsKey('UpnSuffix')) { $__v = Get-ToolkitSetting 'ActiveDirectory.UpnSuffix'; if ($null -ne $__v) { $UpnSuffix = $__v; $__cfgUsed += 'ActiveDirectory.UpnSuffix' } }
if (-not $PSBoundParameters.ContainsKey('OU')) { $__v = Get-ToolkitSetting 'ActiveDirectory.NewUserOU'; if ($null -ne $__v) { $OU = $__v; $__cfgUsed += 'ActiveDirectory.NewUserOU' } }
if (-not $PSBoundParameters.ContainsKey('Groups')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DefaultGroups'; if ($null -ne $__v) { $Groups = $__v; $__cfgUsed += 'ActiveDirectory.DefaultGroups' } }
if (-not $PSBoundParameters.ContainsKey('CloudGroups')) { $__v = Get-ToolkitSetting 'Entra.DefaultGroups'; if ($null -ne $__v) { $CloudGroups = $__v; $__cfgUsed += 'Entra.DefaultGroups' } }
if (-not $PSBoundParameters.ContainsKey('UsageLocation')) { $__v = Get-ToolkitSetting 'Entra.UsageLocation'; if ($null -ne $__v) { $UsageLocation = $__v; $__cfgUsed += 'Entra.UsageLocation' } }
if (-not $PSBoundParameters.ContainsKey('LicenseSkuIds')) { $__v = Get-ToolkitSetting 'Entra.LicenseSkuIds'; if ($null -ne $__v) { $LicenseSkuIds = $__v; $__cfgUsed += 'Entra.LicenseSkuIds' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


# --- standalone-safe helpers ---------------------------------------------------
function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function New-TempPassword {
    $u='ABCDEFGHJKLMNPQRSTUVWXYZ'; $l='abcdefghijkmnpqrstuvwxyz'; $d='23456789'; $s='!@#$%^&*-_=+?'
    $all=($u+$l+$d+$s).ToCharArray()
    $c=@($u[(Get-Random -Maximum $u.Length)],$l[(Get-Random -Maximum $l.Length)],$d[(Get-Random -Maximum $d.Length)],$s[(Get-Random -Maximum $s.Length)])
    for ($i=$c.Count; $i -lt 16; $i++){ $c += $all[(Get-Random -Maximum $all.Length)] }
    -join ($c | Sort-Object { Get-Random })
}
function Connect-ToolkitGraphStandalone {
    param([string[]]$Scopes)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" 'ERROR'
        return $false
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru -ErrorAction SilentlyContinue | Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) { return $true }
    try { Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null; return $true }
    catch { Write-Log "Graph connect failed: $($_.Exception.Message)" 'ERROR'; return $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Employee Onboard (AD + Entra/Intune)" -ForegroundColor White
Write-Host "  ==========================================================" -ForegroundColor DarkGray

if (-not $SamAccountName) {
    $SamAccountName = ("{0}{1}" -f $GivenName.Substring(0, 1), $Surname).ToLower() -replace '[^a-z0-9]', ''
}

$adAvailable    = (-not $SkipAD) -and (Get-Module -ListAvailable ActiveDirectory)
$graphAvailable = (-not $SkipCloud) -and (Get-Module -ListAvailable Microsoft.Graph.Users)

if (-not $adAvailable -and -not $graphAvailable) {
    Write-Log "Neither the ActiveDirectory module nor Microsoft.Graph is available (or both were skipped) — nothing to do." 'ERROR'
    return
}

$adCreated = $false
$adAlreadyExisted = $false
$adTempPw = $null

# ============================================================================
# AD half
# ============================================================================
if ($adAvailable) {
    Import-Module ActiveDirectory -ErrorAction Stop

    if (-not $UpnSuffix) {
        try { $UpnSuffix = (Get-ADDomain).DNSRoot } catch { Write-Log "Could not read domain DNS root; pass -UpnSuffix." 'ERROR'; return }
    }
    $displayName = "$GivenName $Surname"
    $upn = "$SamAccountName@$UpnSuffix"

    $existingAd = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue
    if ($existingAd) {
        Write-Log "AD account '$SamAccountName' already exists — skipping creation, moving to the cloud half." 'INFO'
        $adAlreadyExisted = $true
    } else {
        if (-not $OU) { Write-Log "AD module is available but -OU wasn't given — can't create the account. Pass -OU or -SkipAD." 'ERROR'; return }

        $adTempPw = New-TempPassword
        $secPw = ConvertTo-SecureString $adTempPw -AsPlainText -Force

        Write-Log "AD: creating $displayName ($SamAccountName) in $OU" 'STEP'
        $newParams = @{
            Name = $displayName; GivenName = $GivenName; Surname = $Surname
            SamAccountName = $SamAccountName; UserPrincipalName = $upn; DisplayName = $displayName
            Path = $OU; AccountPassword = $secPw; Enabled = $true; ChangePasswordAtLogon = $true
        }
        if ($Title)      { $newParams.Title      = $Title }
        if ($Department) { $newParams.Department = $Department }
        if ($Office)     { $newParams.Office     = $Office }

        if ($PSCmdlet.ShouldProcess($displayName, "Create AD user in $OU")) {
            try { New-ADUser @newParams -ErrorAction Stop; Write-Log "AD account created." 'OK'; $adCreated = $true }
            catch { Write-Log "AD create failed: $($_.Exception.Message)" 'ERROR'; return }
        } else {
            Write-Host "  (WhatIf) would create AD account $SamAccountName, then continue to the cloud half." -ForegroundColor DarkYellow
        }

        if ($adCreated) {
            if ($Manager -and $PSCmdlet.ShouldProcess($SamAccountName, "Set AD manager to $Manager")) {
                try { Set-ADUser -Identity $SamAccountName -Manager $Manager -ErrorAction Stop; Write-Log "AD manager set." 'OK' }
                catch { Write-Log "AD manager set failed: $($_.Exception.Message)" 'WARN' }
            }
            $allGroups = [System.Collections.Generic.HashSet[string]]::new()
            if ($Groups) { $Groups | ForEach-Object { [void]$allGroups.Add($_) } }
            if ($CopyGroupsFrom) {
                try {
                    (Get-ADPrincipalGroupMembership -Identity $CopyGroupsFrom | Where-Object Name -ne 'Domain Users').Name |
                        ForEach-Object { [void]$allGroups.Add($_) }
                } catch { Write-Log "Could not read AD groups from ${CopyGroupsFrom}: $($_.Exception.Message)" 'WARN' }
            }
            foreach ($g in $allGroups) {
                if ($PSCmdlet.ShouldProcess($SamAccountName, "Add to AD group $g")) {
                    try { Add-ADGroupMember -Identity $g -Members $SamAccountName -ErrorAction Stop; Write-Log "Added to AD group $g" 'OK' }
                    catch { Write-Log "AD group '$g' failed: $($_.Exception.Message)" 'WARN' }
                }
            }
        }
    }
} else {
    Write-Log "AD half skipped ($(if ($SkipAD) {'-SkipAD'} else {'ActiveDirectory module not found'}))." 'INFO'
}

if ($WhatIfPreference -and $adAvailable -and -not $adAlreadyExisted) {
    # Nothing was actually created, so there's no real account to chase into the cloud half.
    return
}

# ============================================================================
# Cloud half
# ============================================================================
if (-not $graphAvailable) {
    Write-Log "Cloud half skipped ($(if ($SkipCloud) {'-SkipCloud'} else {'Microsoft.Graph module not found'}))." 'INFO'
    if (-not $WhatIfPreference) {
        Write-Host ''
        Write-Host "  Onboarding finished (AD only)." -ForegroundColor Green
        if ($adTempPw) { Write-Host "  Temp password: $adTempPw" -ForegroundColor Yellow }
    }
    return
}

$scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'Organization.Read.All')
if (-not (Connect-ToolkitGraphStandalone -Scopes $scopes)) { return }
Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups -ErrorAction Stop

$hybrid = $adAvailable -and ($adCreated -or $adAlreadyExisted)
$upn = if ($UpnSuffix) { "$SamAccountName@$UpnSuffix" } else { $null }
$cloudUser = $null

if ($hybrid) {
    if (-not $upn) { Write-Log "No UPN to look up in Entra (couldn't determine the domain) — stopping here." 'ERROR'; return }

    if ($TriggerDeltaSync -and (Get-Command Start-ADSyncSyncCycle -ErrorAction SilentlyContinue)) {
        Write-Log "Triggering Entra Connect delta sync..." 'STEP'
        try { Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop | Out-Null } catch { Write-Log "Delta sync trigger failed: $($_.Exception.Message)" 'WARN' }
    }

    Write-Log "Waiting for $upn to sync to Entra (up to $SyncTimeoutMinutes minute(s), checking every $SyncPollSeconds second(s))..." 'STEP'
    $deadline = (Get-Date).AddMinutes($SyncTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $cloudUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if ($cloudUser) { break }
        Start-Sleep -Seconds $SyncPollSeconds
    }
    if (-not $cloudUser) {
        Write-Log "Timed out waiting for the sync. This is normal if your sync interval is longer than $SyncTimeoutMinutes minute(s) — just re-run this script later; it'll detect the AD account already exists and pick up here." 'WARN'
        return
    }
    Write-Log "Synced — found $upn in Entra." 'OK'
} else {
    if (-not $upn) { Write-Log "Pass -UpnSuffix for cloud-only account creation." 'ERROR'; return }
    $cloudUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($cloudUser) {
        Write-Log "Entra account $upn already exists — skipping creation." 'INFO'
    } else {
        $cloudTempPw = New-TempPassword
        $displayName = "$GivenName $Surname"
        $body = @{
            accountEnabled = $true; displayName = $displayName; givenName = $GivenName; surname = $Surname
            userPrincipalName = $upn; mailNickname = ($SamAccountName -replace '[^a-zA-Z0-9._-]', '')
            passwordProfile = @{ password = $cloudTempPw; forceChangePasswordNextSignIn = $true }
            usageLocation = $UsageLocation
        }
        if ($Title)      { $body.jobTitle = $Title }
        if ($Department) { $body.department = $Department }
        if ($Office)     { $body.officeLocation = $Office }

        if ($PSCmdlet.ShouldProcess($upn, "Create Entra user (cloud-only)")) {
            try { $cloudUser = New-MgUser -BodyParameter $body -ErrorAction Stop; Write-Log "Entra account created." 'OK' }
            catch { Write-Log "Entra create failed: $($_.Exception.Message)" 'ERROR'; return }
        } else {
            Write-Host "  (WhatIf) would create Entra account $upn with a generated temp password." -ForegroundColor DarkYellow
            return
        }

        if ($Manager) {
            $mgr = Get-MgUser -Filter "userPrincipalName eq '$Manager'" -ErrorAction SilentlyContinue
            if ($mgr -and $PSCmdlet.ShouldProcess($upn, "Set Entra manager to $Manager")) {
                try {
                    Set-MgUserManagerByRef -UserId $cloudUser.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($mgr.Id)" } -ErrorAction Stop
                    Write-Log "Entra manager set." 'OK'
                } catch { Write-Log "Entra manager set failed: $($_.Exception.Message)" 'WARN' }
            } elseif (-not $mgr) { Write-Log "Manager '$Manager' not found in Entra — skipped." 'WARN' }
        }
    }
}

# --- usage location (hybrid: apply post-sync since AD/Entra Connect doesn't set it) ---
if ($UsageLocation -and $PSCmdlet.ShouldProcess($upn, "Set usage location $UsageLocation")) {
    try { Update-MgUser -UserId $cloudUser.Id -UsageLocation $UsageLocation -ErrorAction Stop; Write-Log "Usage location: $UsageLocation" 'OK' }
    catch { Write-Log "Usage location failed (may already be set): $($_.Exception.Message)" 'WARN' }
}

# --- licenses --------------------------------------------------------------------
if ($LicenseSkuIds) {
    $addLicenses = $LicenseSkuIds | ForEach-Object { @{ skuId = $_ } }
    if ($PSCmdlet.ShouldProcess($upn, "Assign license(s): $($LicenseSkuIds -join ', ')")) {
        try { Set-MgUserLicense -UserId $cloudUser.Id -AddLicenses $addLicenses -RemoveLicenses @() -ErrorAction Stop; Write-Log "License(s) assigned." 'OK' }
        catch { Write-Log "License assignment failed: $($_.Exception.Message)" 'WARN' }
    }
}

# --- cloud-only groups (assigned + copied) ----------------------------------------
$allCloudGroups = [System.Collections.Generic.HashSet[string]]::new()
if ($CloudGroups) { $CloudGroups | ForEach-Object { [void]$allCloudGroups.Add($_) } }
if ($CopyCloudGroupsFrom) {
    try {
        $src = Get-MgUser -Filter "userPrincipalName eq '$CopyCloudGroupsFrom'" -ErrorAction Stop
        Get-MgUserMemberOf -UserId $src.Id -All | ForEach-Object {
            $g = Get-MgGroup -GroupId $_.Id -ErrorAction SilentlyContinue
            if ($g) { [void]$allCloudGroups.Add($g.DisplayName) }
        }
    } catch { Write-Log "Could not read Entra groups from ${CopyCloudGroupsFrom}: $($_.Exception.Message)" 'WARN' }
}
foreach ($gName in $allCloudGroups) {
    $g = Get-MgGroup -Filter "displayName eq '$gName'" -ErrorAction SilentlyContinue
    if (-not $g) { Write-Log "Entra group '$gName' not found — skipped." 'WARN'; continue }
    if ($PSCmdlet.ShouldProcess($upn, "Add to Entra group $gName")) {
        try { New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $cloudUser.Id -ErrorAction Stop; Write-Log "Added to Entra group $gName" 'OK' }
        catch { Write-Log "Entra group '$gName' failed (may already be a member): $($_.Exception.Message)" 'WARN' }
    }
}

if (-not $WhatIfPreference) {
    Write-Host ''
    Write-Host "  Onboarding complete: $upn" -ForegroundColor Green
    if ($adTempPw)    { Write-Host "  AD temp password    : $adTempPw" -ForegroundColor Yellow }
    if ($cloudTempPw) { Write-Host "  Entra temp password : $cloudTempPw" -ForegroundColor Yellow }
    if ($adTempPw -or $cloudTempPw) { Write-Host "  (Force-change at first sign-in. Share securely, not by e-mail.)" -ForegroundColor DarkYellow }
    Write-Log "Employee onboarding finished for $upn" 'OK'
}
