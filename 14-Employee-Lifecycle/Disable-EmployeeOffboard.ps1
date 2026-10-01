<#
.SYNOPSIS
    Offboard a leaver across Entra/Intune *and* AD in one command — cloud
    access cut first, then on-prem, so nothing waits on sync.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, including
    01-Users\Disable-ADUserOffboard.ps1 and
    09-Entra-Intune\Disable-EntraUserOffboard.ps1 (this script does its own AD
    and Graph work inline, on purpose).

    Order matters here and is deliberate: the CLOUD half runs first — block
    sign-in, revoke every active session/token, strip licenses and cloud
    groups, optionally retire Intune devices — because that's the fastest way
    to actually cut someone off, and it doesn't need to wait for anything.
    The AD half runs independently after: disable the account, randomize the
    password, record then strip groups, optionally move to a Disabled OU.
    Either half works fine on its own — pass only -SamAccountName for AD-only,
    only -UserPrincipalName for cloud-only, or both for the full hybrid leaver
    flow. Neither half needs the other to have run.

    Nothing is ever deleted on either side — same "disable, don't delete"
    philosophy as the rest of this kit. That stays a deliberate separate step
    after your retention window.

.PARAMETER SamAccountName
    The leaver's AD login name. Runs the AD half if the AD module is present.
.PARAMETER UserPrincipalName
    The leaver's Entra UPN. Runs the cloud half if Microsoft.Graph is present.
    If omitted but -SamAccountName and -UpnSuffix are given, it's derived as
    SamAccountName@UpnSuffix.
.PARAMETER UpnSuffix
    Used only to derive -UserPrincipalName when it isn't given directly.
.PARAMETER Reason
    Free text stamped on both accounts (default 'Offboarded').
.PARAMETER DisabledOU
    AD: optional DN to move the account into.
.PARAMETER HideFromGAL
    AD: set msExchHideFromAddressLists (needs the attribute / Exchange).
.PARAMETER WipeDevices
    Cloud: also retire (remove company data from) the user's Intune-managed
    devices. Without this switch, matching devices are only listed.

.EXAMPLE
    .\Disable-EmployeeOffboard.ps1 -SamAccountName jpeeters -UserPrincipalName jan.peeters@contoso.com -WhatIf
.EXAMPLE
    .\Disable-EmployeeOffboard.ps1 -SamAccountName jpeeters -UpnSuffix contoso.com -Reason "Left 2026-09-30" -WipeDevices
.EXAMPLE
    # cloud-only (no AD half):
    .\Disable-EmployeeOffboard.ps1 -UserPrincipalName jan.peeters@contoso.com -WipeDevices

.NOTES
    AD half needs the ActiveDirectory module + rights; cloud half needs
    Microsoft.Graph + User Administrator (+ Intune Administrator for device
    retire). First Graph use prompts for consent to: User.ReadWrite.All,
    Group.ReadWrite.All, Directory.Read.All,
    DeviceManagementManagedDevices.PrivilegedOperations.All,
    DeviceManagementManagedDevices.Read.All.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
.PARAMETER Force
    Skip confirmation prompts, for automation (scheduled tasks, Zabbix, the fleet
    runner). Also honoured via the SYSADMIN_TOOLKIT_FORCE=1 environment variable.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SamAccountName,
    [string]$UserPrincipalName,
    [string]$UpnSuffix,
    [string]$Reason = 'Offboarded',
    [string]$DisabledOU,
    [switch]$HideFromGAL,
    [switch]$WipeDevices,
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
if (-not $PSBoundParameters.ContainsKey('UpnSuffix')) { $__v = Get-ToolkitSetting 'ActiveDirectory.UpnSuffix'; if ($null -ne $__v) { $UpnSuffix = $__v; $__cfgUsed += 'ActiveDirectory.UpnSuffix' } }
if (-not $PSBoundParameters.ContainsKey('DisabledOU')) { $__v = Get-ToolkitSetting 'ActiveDirectory.DisabledOU'; if ($null -ne $__v) { $DisabledOU = $__v; $__cfgUsed += 'ActiveDirectory.DisabledOU' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    try { if (-not (Test-Path (Join-Path $p 'Backups'))) { New-Item -ItemType Directory -Path (Join-Path $p 'Backups') -Force | Out-Null } } catch { }
    return $p
}
function New-RandomPassword {
    $u='ABCDEFGHJKLMNPQRSTUVWXYZ'; $l='abcdefghijkmnpqrstuvwxyz'; $d='23456789'; $s='!@#$%^&*-_=+?'
    $all=($u+$l+$d+$s).ToCharArray()
    $c=@($u[(Get-Random -Maximum $u.Length)],$l[(Get-Random -Maximum $l.Length)],$d[(Get-Random -Maximum $d.Length)],$s[(Get-Random -Maximum $s.Length)])
    for ($i=$c.Count; $i -lt 24; $i++){ $c += $all[(Get-Random -Maximum $all.Length)] }
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
Write-Host "  Sysadmin-Toolkit :: Employee Offboard (Entra/Intune + AD)" -ForegroundColor White
Write-Host "  ===========================================================" -ForegroundColor DarkGray

if (-not $UserPrincipalName -and $SamAccountName -and $UpnSuffix) {
    $UserPrincipalName = "$SamAccountName@$UpnSuffix"
}
if (-not $SamAccountName -and -not $UserPrincipalName) {
    Write-Log "Pass -SamAccountName, -UserPrincipalName, or both." 'ERROR'; return
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$ranCloud = $false
$ranAD = $false

# ============================================================================
# Cloud half FIRST — fastest way to actually cut access off
# ============================================================================
if ($UserPrincipalName) {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Users)) {
        Write-Log "Microsoft.Graph module not found — skipping cloud half for $UserPrincipalName." 'WARN'
    } else {
        $scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.Read.All', 'DeviceManagementManagedDevices.PrivilegedOperations.All', 'DeviceManagementManagedDevices.Read.All')
        if (Connect-ToolkitGraphStandalone -Scopes $scopes) {
            Import-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions -ErrorAction Stop
            $user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -Property Id,DisplayName,AssignedLicenses -ErrorAction SilentlyContinue
            if (-not $user) {
                Write-Log "No Entra account found for $UserPrincipalName — skipping cloud half." 'WARN'
            } else {
                $ranCloud = $true
                Write-Log "Cloud: offboarding $($user.DisplayName) ($UserPrincipalName)" 'STEP'

                if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Block sign-in")) {
                    try { Update-MgUser -UserId $user.Id -AccountEnabled:$false -ErrorAction Stop; Write-Log "Sign-in blocked." 'OK' }
                    catch { Write-Log "Block sign-in failed: $($_.Exception.Message)" 'ERROR' }
                }
                if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Revoke all sessions")) {
                    try { Invoke-MgInvalidateUserRefreshToken -UserId $user.Id -ErrorAction Stop | Out-Null; Write-Log "All sessions revoked." 'OK' }
                    catch { Write-Log "Session revoke failed: $($_.Exception.Message)" 'WARN' }
                }

                $grpLog = Join-Path $root ("Backups\EntraGroups_{0}_{1}.txt" -f ($UserPrincipalName -replace '[^\w\.-]', '_'), $stamp)
                $memberships = @(Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction SilentlyContinue)
                $cloudGroups = $memberships | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.group' }
                if ($cloudGroups.Count) {
                    if ($PSCmdlet.ShouldProcess($grpLog, "Save current Entra group list")) {
                        $cloudGroups | ForEach-Object { "$($_.Id)  $($_.AdditionalProperties.displayName)" } | Out-File -FilePath $grpLog -Encoding UTF8
                        Write-Log "Saved $($cloudGroups.Count) Entra group membership(s) -> $grpLog" 'OK'
                    }
                    foreach ($g in $cloudGroups) {
                        $gName = $g.AdditionalProperties.displayName
                        if ($g.AdditionalProperties.groupTypes -contains 'DynamicMembership') { Write-Log "  $gName is dynamic — clears itself, skipping." 'INFO'; continue }
                        if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Remove from Entra group $gName")) {
                            try { Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop; Write-Log "Removed from $gName" 'OK' }
                            catch { Write-Log "Could not remove from ${gName}: $($_.Exception.Message)" 'WARN' }
                        }
                    }
                } else { Write-Log "No Entra group memberships found." 'INFO' }

                $skuIds = @($user.AssignedLicenses | ForEach-Object { $_.SkuId })
                if ($skuIds.Count -and $PSCmdlet.ShouldProcess($UserPrincipalName, "Remove $($skuIds.Count) license(s)")) {
                    try { Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skuIds -ErrorAction Stop; Write-Log "Licenses removed." 'OK' }
                    catch { Write-Log "License removal failed: $($_.Exception.Message)" 'WARN' }
                }

                $note = "$Reason by $env:USERNAME on $(Get-Date -Format 'yyyy-MM-dd')"
                if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Stamp offboard note")) {
                    try { Update-MgUser -UserId $user.Id -Department $note -ErrorAction Stop; Write-Log "Note: $note" 'OK' }
                    catch { Write-Log "Could not stamp note: $($_.Exception.Message)" 'WARN' }
                }

                try {
                    Import-Module Microsoft.Graph.DeviceManagement -ErrorAction Stop
                    $devices = @(Get-MgDeviceManagementManagedDevice -Filter "userId eq '$($user.Id)'" -ErrorAction SilentlyContinue)
                    if ($devices.Count) {
                        Write-Log "$($devices.Count) Intune-managed device(s):" 'STEP'
                        $devices | ForEach-Object { Write-Log "  $($_.DeviceName)  ($($_.OperatingSystem), last sync $($_.LastSyncDateTime))" 'INFO' }
                        if ($WipeDevices) {
                            foreach ($d in $devices) {
                                if ($PSCmdlet.ShouldProcess($d.DeviceName, "Retire (remove company data)")) {
                                    try { Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $d.Id -ErrorAction Stop; Write-Log "Retire requested for $($d.DeviceName)." 'OK' }
                                    catch { Write-Log "Retire failed for $($d.DeviceName): $($_.Exception.Message)" 'WARN' }
                                }
                            }
                        } else {
                            Write-Host "  Devices listed but NOT retired. Re-run with -WipeDevices to retire them." -ForegroundColor DarkYellow
                        }
                    } else { Write-Log "No Intune-managed devices found." 'INFO' }
                } catch { Write-Log "Could not query Intune devices: $($_.Exception.Message)" 'WARN' }
            }
        }
    }
} else {
    Write-Log "No -UserPrincipalName (and none derivable) — skipping cloud half." 'INFO'
}

# ============================================================================
# AD half
# ============================================================================
if ($SamAccountName) {
    if (-not (Get-Module -ListAvailable ActiveDirectory)) {
        Write-Log "ActiveDirectory module not found — skipping AD half for $SamAccountName." 'WARN'
    } else {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -Properties MemberOf, Description -ErrorAction SilentlyContinue
        if (-not $adUser) {
            Write-Log "No AD account '$SamAccountName' found — skipping AD half." 'WARN'
        } else {
            $ranAD = $true
            Write-Log "AD: offboarding $($adUser.Name) ($SamAccountName)" 'STEP'

            $grpLog = Join-Path $root ("Backups\ADGroups_{0}_{1}.txt" -f $SamAccountName, $stamp)
            $adGroups = @($adUser.MemberOf)
            if ($adGroups.Count -and $PSCmdlet.ShouldProcess($grpLog, "Save current AD group list")) {
                $adGroups | Out-File -FilePath $grpLog -Encoding UTF8
                Write-Log "Saved $($adGroups.Count) AD group membership(s) -> $grpLog" 'OK'
            }

            if ($PSCmdlet.ShouldProcess($SamAccountName, "Disable AD account")) {
                Disable-ADAccount -Identity $SamAccountName
                Write-Log "AD account disabled." 'OK'
            }
            if ($PSCmdlet.ShouldProcess($SamAccountName, "Reset AD password to random")) {
                $sec = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
                Set-ADAccountPassword -Identity $SamAccountName -NewPassword $sec -Reset
                Write-Log "AD password reset to random (not recorded)." 'OK'
            }
            foreach ($g in $adGroups) {
                $gname = ($g -split ',')[0] -replace '^CN='
                if ($gname -eq 'Domain Users') { continue }
                if ($PSCmdlet.ShouldProcess($SamAccountName, "Remove from AD group $gname")) {
                    try { Remove-ADGroupMember -Identity $g -Members $SamAccountName -Confirm:$false -ErrorAction Stop; Write-Log "Removed from $gname" 'OK' }
                    catch { Write-Log "Could not remove from ${gname}: $($_.Exception.Message)" 'WARN' }
                }
            }
            $note = "$Reason by $env:USERNAME on $(Get-Date -Format 'yyyy-MM-dd')"
            if ($PSCmdlet.ShouldProcess($SamAccountName, "Set description")) {
                Set-ADUser -Identity $SamAccountName -Description $note
                Write-Log "AD description: $note" 'OK'
            }
            if ($HideFromGAL -and $PSCmdlet.ShouldProcess($SamAccountName, "Hide from address book")) {
                try { Set-ADUser -Identity $SamAccountName -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop; Write-Log "Hidden from GAL." 'OK' }
                catch { Write-Log "Could not set GAL flag: $($_.Exception.Message)" 'WARN' }
            }
            if ($DisabledOU -and $PSCmdlet.ShouldProcess($SamAccountName, "Move to $DisabledOU")) {
                try { Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $DisabledOU -ErrorAction Stop; Write-Log "Moved to $DisabledOU" 'OK' }
                catch { Write-Log "Move failed: $($_.Exception.Message)" 'WARN' }
            }
        }
    }
} else {
    Write-Log "No -SamAccountName given — skipping AD half." 'INFO'
}

if (-not $WhatIfPreference) {
    Write-Host ''
    if ($ranCloud -or $ranAD) {
        Write-Host "  Offboarding complete. Cloud: $ranCloud   AD: $ranAD" -ForegroundColor Green
        Write-Host "  Nothing deleted — accounts disabled/blocked only. Remove after your retention window." -ForegroundColor DarkYellow
    } else {
        Write-Host "  Nothing was found to offboard — check the name(s) passed in." -ForegroundColor Red
    }
}
