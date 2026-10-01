<#
.SYNOPSIS
    Onboard or offboard a LOCAL Windows account (no domain/GPO needed).

.DESCRIPTION
    Onboard : creates a local user, adds it to groups, sets a strong temporary
              password (auto-generated if you don't supply one) and forces a
              change at first logon.
    Offboard: DISABLES the account (best practice — not deleted), strips it from
              its groups, and stamps the description with the date. Use -Delete
              only if you really want it gone (guarded).

    Uses the built-in LocalAccounts cmdlets, with a net.exe fallback.

.PARAMETER Action
    Onboard | Offboard | List

.PARAMETER User
    The account name (samAccountName style, no spaces).

.PARAMETER FullName
    Display name (onboard).

.PARAMETER Description
    Free-text note stored on the account.

.PARAMETER Groups
    Local groups to add on onboard. Default: Users.

.PARAMETER Password
    Optional SecureString. If omitted on onboard, a strong one is generated and
    shown once.

.PARAMETER Delete
    Offboard only: permanently remove the account instead of disabling it.

.EXAMPLE
    .\Manage-LocalUser.ps1 -Action List
.EXAMPLE
    .\Manage-LocalUser.ps1 -Action Onboard -User jdoe -FullName "Jane Doe" -Groups Users,Remote Desktop Users
.EXAMPLE
    .\Manage-LocalUser.ps1 -Action Offboard -User jdoe
.EXAMPLE
    .\Manage-LocalUser.ps1 -Action Offboard -User jdoe -Delete -Confirm

.NOTES
    Run as Administrator. Part of the TechToolkit family.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateSet('Onboard', 'Offboard', 'List')]
    [string]$Action,
    [string]$User,
    [string]$FullName,
    [string]$Description,
    [string[]]$Groups = @('Users'),
    [System.Security.SecureString]$Password,
    [switch]$Delete
)

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-RandomPassword {
    param([int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%^&*?-_')
    $pw = foreach ($s in $sets) { $s[(Get-Random -Max $s.Length)] }          # guarantee 1 of each
    $all = -join $sets
    $pw += 1..($Length - 4) | ForEach-Object { $all[(Get-Random -Max $all.Length)] }
    -join ($pw | Sort-Object { Get-Random })
}

if ($Action -eq 'List') {
    Get-LocalUser | Sort-Object Enabled -Descending |
        Format-Table Name, Enabled, LastLogon, Description -AutoSize
    return
}

if (-not (Test-Admin)) { Write-Error "Run as Administrator."; return }
if (-not $User)        { Write-Error "-User is required for $Action."; return }

$exists = Get-LocalUser -Name $User -ErrorAction SilentlyContinue

# ---------------- Onboard ----------------
if ($Action -eq 'Onboard') {
    if ($exists) { Write-Warning "User '$User' already exists — nothing created."; return }

    $shown = $null
    if (-not $Password) {
        $plain = New-RandomPassword
        $Password = ConvertTo-SecureString $plain -AsPlainText -Force
        $shown = $plain
    }

    if ($PSCmdlet.ShouldProcess($User, "Create local user and add to: $($Groups -join ', ')")) {
        New-LocalUser -Name $User -Password $Password -FullName $FullName `
                      -Description $Description -PasswordNeverExpires:$false -ErrorAction Stop | Out-Null
        # force password change at first logon
        net.exe user $User /logonpasswordchg:yes | Out-Null

        foreach ($g in $Groups) {
            try   { Add-LocalGroupMember -Group $g -Member $User -ErrorAction Stop; Write-Host "  [+] added to $g" -ForegroundColor Green }
            catch { Write-Host "  [!] group '$g': $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Write-Host "`n[+] Created '$User'." -ForegroundColor Green
        if ($shown) {
            Write-Host "    Temporary password (shown once): " -NoNewline
            Write-Host $shown -ForegroundColor Cyan
            Write-Host "    User must change it at first logon." -ForegroundColor DarkGray
        }
    }
    return
}

# ---------------- Offboard ----------------
if ($Action -eq 'Offboard') {
    if (-not $exists) { Write-Warning "User '$User' not found."; return }

    if ($Delete) {
        if ($PSCmdlet.ShouldProcess($User, "PERMANENTLY DELETE local account")) {
            Remove-LocalUser -Name $User -ErrorAction Stop
            Write-Host "[+] Deleted '$User'." -ForegroundColor Green
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($User, "Disable account and remove from groups")) {
        Disable-LocalUser -Name $User
        $memberOf = Get-LocalGroup | Where-Object {
            (Get-LocalGroupMember $_ -ErrorAction SilentlyContinue).Name -contains "$env:COMPUTERNAME\$User"
        }
        foreach ($g in $memberOf) {
            try   { Remove-LocalGroupMember -Group $g -Member $User -ErrorAction Stop; Write-Host "  [-] removed from $($g.Name)" -ForegroundColor Yellow }
            catch { }
        }
        $stamp = "Disabled $(Get-Date -Format 'yyyy-MM-dd') via TechToolkit"
        Set-LocalUser -Name $User -Description $stamp
        Write-Host "[+] Offboarded '$User' (disabled, groups stripped)." -ForegroundColor Green
    }
}
