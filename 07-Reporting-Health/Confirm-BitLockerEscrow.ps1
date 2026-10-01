<#
.SYNOPSIS
    Confirms BitLocker recovery keys are actually escrowed — to AD, to
    Entra, or both — before someone's locked out and you find out the key
    was never saved anywhere.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. Checks
    each target machine's encrypted volumes locally (does a recovery
    password protector even exist?), then cross-checks escrow:

      - AD: looks for msFVE-RecoveryInformation objects under the machine's
        AD computer object (the standard on-prem escrow mechanism). Needs
        the ActiveDirectory module; runs fine without it, just skips this
        column.
      - Entra: looks up the machine's Entra device object and queries
        Graph's BitLocker recovery-key resource for it. Needs
        Microsoft.Graph; runs fine without it too. Same honesty note as
        this kit's other newer-Graph-API scripts: calls /v1.0 first, falls
        back to /beta, and says plainly which one worked — verify against
        current Microsoft Learn docs if this ever looks wrong for your
        tenant, since Microsoft has reshaped BitLocker/Graph APIs before.

    A machine can legitimately show "no AD escrow" if it's Entra-joined only
    (no on-prem AD object), or "no Entra escrow" if it's AD-only with no
    Entra Connect device sync — that's expected, not necessarily a problem.
    What's actually worth acting on: a BitLocker-protected volume with
    NEITHER escrow found anywhere this script can check.

.PARAMETER ComputerName
    One or more machines to check. Default: local machine only.
.PARAMETER SkipAD
    Force-skip a check even if its module is available.
.PARAMETER SkipEntra
    Force-skip a check even if its module is available.

.EXAMPLE
    .\Confirm-BitLockerEscrow.ps1
.EXAMPLE
    .\Confirm-BitLockerEscrow.ps1 -ComputerName PC01,PC02,PC03

.NOTES
    Local BitLocker check needs Administrator (locally or on the remote
    target via Invoke-Command). AD check needs the ActiveDirectory module.
    Entra check needs Microsoft.Graph + Device.Read.All and
    BitlockerKey.Read.All (or ReadBasic.All) — never fetches the actual key
    material, only whether an escrow record exists and when it was created.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [switch]$SkipAD,
    [switch]$SkipEntra
)

function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Get-ToolkitRoot {
    $p = 'C:\Sysadmin-Toolkit'
    foreach ($sub in @('', 'Reports')) {
        $full = if ($sub) { Join-Path $p $sub } else { $p }
        try { if (-not (Test-Path $full)) { New-Item -ItemType Directory -Path $full -Force | Out-Null } } catch { }
    }
    return $p
}
function Connect-ToolkitGraphStandalone {
    param([string[]]$Scopes)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { return $false }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $ctx = Get-MgContext
    $haveAll = $ctx -and (-not (Compare-Object -ReferenceObject $Scopes -DifferenceObject $ctx.Scopes -PassThru -ErrorAction SilentlyContinue | Where-Object { $Scopes -contains $_ }))
    if ($ctx -and $haveAll) { return $true }
    try { Connect-MgGraph -Scopes $Scopes -ErrorAction Stop | Out-Null; return $true }
    catch { Write-Log "Graph connect failed: $($_.Exception.Message)" 'ERROR'; return $false }
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: BitLocker Escrow Check" -ForegroundColor White
Write-Host "  ============================================" -ForegroundColor DarkGray

$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }

# --- 1. local BitLocker status per machine ---------------------------------------
$blBlock = {
    try {
        Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                MountPoint = $_.MountPoint
                Protection = $_.ProtectionStatus
                HasRecoveryPasswordProtector = [bool]($_.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')
            }
        }
    } catch { @() }
}
$blResults = @{}
foreach ($target in $targets) {
    Write-Log "Checking local BitLocker status on $target..." 'STEP'
    try {
        if ($target -in @($env:COMPUTERNAME, 'localhost', '.', '')) { $blResults[$target] = & $blBlock }
        else { $blResults[$target] = Invoke-Command -ComputerName $target -ScriptBlock $blBlock -ErrorAction Stop }
    } catch {
        Write-Log "Could not check ${target}: $($_.Exception.Message)" 'WARN'
        $blResults[$target] = @()
    }
}

# --- 2. AD escrow -----------------------------------------------------------------
$adAvailable = (-not $SkipAD) -and (Get-Module -ListAvailable ActiveDirectory)
$adEscrow = @{}
if ($adAvailable) {
    Import-Module ActiveDirectory -ErrorAction Stop
    foreach ($target in $targets) {
        try {
            $comp = Get-ADComputer -Identity $target -ErrorAction Stop
            $recoveryObjs = @(Get-ADObject -SearchBase $comp.DistinguishedName -Filter "objectClass -eq 'msFVE-RecoveryInformation'" -Properties whenCreated -ErrorAction SilentlyContinue)
            $adEscrow[$target] = [pscustomobject]@{ Found = [bool]$recoveryObjs.Count; Count = $recoveryObjs.Count; Newest = if ($recoveryObjs.Count) { ($recoveryObjs | Sort-Object whenCreated -Descending | Select-Object -First 1).whenCreated } else { $null } }
        } catch {
            $adEscrow[$target] = [pscustomobject]@{ Found = $false; Count = 0; Newest = $null }
        }
    }
} else {
    Write-Log "AD check skipped ($(if ($SkipAD) {'-SkipAD'} else {'ActiveDirectory module not found'}))." 'INFO'
}

# --- 3. Entra escrow ----------------------------------------------------------------
$entraAvailable = (-not $SkipEntra) -and (Get-Module -ListAvailable Microsoft.Graph.Authentication) -and (Get-Module -ListAvailable Microsoft.Graph.Identity.DirectoryManagement)
$entraEscrow = @{}
$entraApiUsed = $null
if ($entraAvailable) {
    if (Connect-ToolkitGraphStandalone -Scopes @('Device.Read.All', 'BitlockerKey.Read.All')) {
        Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
        foreach ($target in $targets) {
            try {
                $entraDevice = Get-MgDevice -Filter "displayName eq '$target'" -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $entraDevice) { $entraEscrow[$target] = [pscustomobject]@{ Found = $false; Count = 0; Newest = $null; Note = 'No matching Entra device object' }; continue }

                $keys = $null
                foreach ($ver in @('v1.0', 'beta')) {
                    try {
                        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/$ver/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$($entraDevice.DeviceId)'" -ErrorAction Stop
                        $keys = @($resp.value); $entraApiUsed = $ver; break
                    } catch { continue }
                }
                if ($null -eq $keys) {
                    $entraEscrow[$target] = [pscustomobject]@{ Found = $false; Count = 0; Newest = $null; Note = 'Graph query failed on both /v1.0 and /beta' }
                } else {
                    $newest = if ($keys.Count) { ($keys | Sort-Object createdDateTime -Descending | Select-Object -First 1).createdDateTime } else { $null }
                    $entraEscrow[$target] = [pscustomobject]@{ Found = [bool]$keys.Count; Count = $keys.Count; Newest = $newest; Note = '' }
                }
            } catch {
                $entraEscrow[$target] = [pscustomobject]@{ Found = $false; Count = 0; Newest = $null; Note = $_.Exception.Message }
            }
        }
        if ($entraApiUsed) { Write-Log "Entra check used Graph /$entraApiUsed" 'INFO' }
    } else {
        Write-Log "Entra check skipped — Graph connect did not succeed." 'WARN'
        $entraAvailable = $false
    }
} else {
    Write-Log "Entra check skipped ($(if ($SkipEntra) {'-SkipEntra'} else {'Microsoft.Graph module not found'}))." 'INFO'
}

# --- combine + report ---------------------------------------------------------------
$rows = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($target in $targets) {
    $volumes = $blResults[$target]
    $encryptedVols = @($volumes | Where-Object { $_.Protection -eq 'On' })
    if (-not $encryptedVols.Count) {
        $rows.Add([pscustomobject]@{ ComputerName = $target; Volume = '(none encrypted)'; LocalProtector = $null; ADEscrow = $null; EntraEscrow = $null; AtRisk = $false })
        continue
    }
    foreach ($v in $encryptedVols) {
        $ad = if ($adAvailable) { $adEscrow[$target] } else { $null }
        $entra = if ($entraAvailable) { $entraEscrow[$target] } else { $null }
        $atRisk = $v.HasRecoveryPasswordProtector -and (-not (($ad -and $ad.Found) -or ($entra -and $entra.Found)))
        $rows.Add([pscustomobject]@{
            ComputerName   = $target
            Volume         = $v.MountPoint
            LocalProtector = $v.HasRecoveryPasswordProtector
            ADEscrow       = if ($ad) { $ad.Found } else { $null }
            EntraEscrow    = if ($entra) { $entra.Found } else { $null }
            AtRisk         = $atRisk
        })
    }
}

$atRiskRows = @($rows | Where-Object AtRisk)
Write-Host ''
foreach ($r in $rows) {
    $color = if ($r.AtRisk) { 'Red' } else { 'Gray' }
    Write-Host ("  {0,-15} {1,-6} LocalProtector={2} AD={3} Entra={4}" -f $r.ComputerName, $r.Volume, $r.LocalProtector, $r.ADEscrow, $r.EntraEscrow) -ForegroundColor $color
}

$root = Get-ToolkitRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$reportPath = Join-Path $root ("Reports\BitLockerEscrow_{0}.html" -f $stamp)
$tableRows = ($rows | ForEach-Object {
    $cls = if ($_.AtRisk) { 'atrisk' } else { '' }
    "<tr class='$cls'><td>$($_.ComputerName)</td><td>$($_.Volume)</td><td>$($_.LocalProtector)</td><td>$($_.ADEscrow)</td><td>$($_.EntraEscrow)</td><td>$(if ($_.AtRisk) { 'AT RISK' } else { '' })</td></tr>"
}) -join "`n"
$html = @"
<html><head><title>BitLocker Escrow — $stamp</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}
table{border-collapse:collapse;width:100%} td,th{border:1px solid #ccc;padding:6px 10px;text-align:left} th{background:#f0f0f0}
.atrisk td{background:#fdecea;color:#c62828}</style>
</head><body>
<h1>BitLocker Recovery Key Escrow</h1>
<p>$stamp &nbsp; AD check: $adAvailable &nbsp; Entra check: $entraAvailable &nbsp; At risk (protected, no escrow found anywhere checked): $($atRiskRows.Count)</p>
<table><tr><th>Computer</th><th>Volume</th><th>Local recovery protector</th><th>AD escrow</th><th>Entra escrow</th><th></th></tr>
$tableRows
</table>
<p style="color:#6b7280;font-size:12px">A blank AD/Entra column means that check was skipped (module not available), not that escrow is missing. "AT RISK" means BitLocker is on with a recovery-password protector but no escrow was found in any check that actually ran.</p>
</body></html>
"@
$html | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ''
Write-Host "  Report: $reportPath" -ForegroundColor White
if ($atRiskRows.Count) { Write-Log "$($atRiskRows.Count) volume(s) AT RISK — protected but no escrow found in any check that ran." 'ERROR' }
else { Write-Log "No at-risk volumes found (within what this run could check)." 'OK' }
