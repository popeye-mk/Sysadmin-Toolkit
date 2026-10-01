<#
.SYNOPSIS
    List the managed devices of a company (or all) — from Zabbix, with Active
    Directory and Intune as fallbacks. The device source for the fleet runner.

.DESCRIPTION
    Whoever manages several companies already knows every device and which
    company it belongs to — in the monitoring. This reads that: Zabbix host
    groups (one per customer) via the API, and returns a normalised list of
    devices with their OS and online state. When Zabbix isn't reachable, it
    falls back to Active Directory (an OU per company) or Intune (via section 09).

    Returns objects: Company, Name, IPv4, OS, Online, Source. Use it on its own
    to see a fleet, or let Invoke-ToolkitFleet.ps1 call it to pick targets.

    Company → source mapping is optional: Config\companies.json can map a friendly
    company name to its Zabbix host group, AD OU and Config folder. Without it,
    -Company is treated as the Zabbix host-group name directly.

.PARAMETER Company
    Friendly company name (looked up in Config\companies.json) or, without that
    file, the Zabbix host-group name. Omit to list every host.
.PARAMETER Source
    Zabbix (default), AD, Intune, or Auto (Zabbix, then AD).
.PARAMETER ZabbixUrl
    Zabbix frontend URL. Falls back to Config Monitoring.ZabbixUrl.
.PARAMETER ApiToken
    Zabbix API token. Falls back to a 'ZabbixApiToken' secret in 19-Secrets.
.PARAMETER SearchBase
    AD source: the OU distinguished name to search (overrides companies.json).
.PARAMETER OS
    Filter by OS, wildcard (e.g. 'Windows 11*', '*Server*').
.PARAMETER OnlineOnly
    Only devices currently reachable/available.

.EXAMPLE
    .\Get-ManagedFleet.ps1 -Company Contoso
.EXAMPLE
    .\Get-ManagedFleet.ps1 -Company Contoso -OS 'Windows 11*' -OnlineOnly
.EXAMPLE
    .\Get-ManagedFleet.ps1 -Source AD -SearchBase 'OU=Workstations,OU=Contoso,DC=lab,DC=local'

.NOTES
    Read-only. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [string]$Company,
    [ValidateSet('Zabbix','AD','Intune','Auto')][string]$Source = 'Auto',
    [string]$ZabbixUrl,
    [string]$ApiToken,
    [string]$SearchBase,
    [string]$OS,
    [switch]$OnlineOnly
)

# --- inline helpers (standalone-safe) -----------------------------------------------
function Write-Log {
    param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
    $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -ForegroundColor $c
}
function Get-ConfigDir {
    $cands = @()
    if ($env:SYSADMIN_TOOLKIT_CONFIG) { $cands += $env:SYSADMIN_TOOLKIT_CONFIG }
    if ($PSScriptRoot) { $p = Split-Path $PSScriptRoot -Parent; if ($p) { $cands += (Join-Path $p 'Config') } }
    $cands += 'C:\Sysadmin-Toolkit\Config'
    foreach ($d in $cands) { if ($d -and (Test-Path -LiteralPath $d -ErrorAction SilentlyContinue)) { return $d } }
    return $null
}
function Get-ToolkitSetting {
    param([string]$Key)
    $d = Get-ConfigDir; if (-not $d) { return $null }
    $f = Join-Path $d 'toolkit-settings.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { $data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
    $node = $data
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $part)) { return $null }
        $node = $node.$part
    }
    if ($node -is [string] -and $node.Trim() -eq '') { return $null }
    return $node
}
function Get-CompanyMap {
    param([string]$Name)
    $d = Get-ConfigDir; if (-not $d) { return $null }
    $f = Join-Path $d 'companies.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json } catch { return $null }
    foreach ($c in $j.companies) { if ($c.name -eq $Name) { return $c } }
    return $null
}

$map = if ($Company) { Get-CompanyMap $Company } else { $null }

# --- Zabbix source ------------------------------------------------------------------
function Get-FromZabbix {
    if (-not $ZabbixUrl) { $ZabbixUrl = Get-ToolkitSetting 'Monitoring.ZabbixUrl' }
    if (-not $ZabbixUrl) { Write-Log "No Zabbix URL (pass -ZabbixUrl or set Monitoring.ZabbixUrl in Config)." 'WARN'; return $null }
    if (-not $ApiToken) {
        $secret = Join-Path (Split-Path $PSScriptRoot -Parent) '19-Secrets\Manage-ToolkitSecret.ps1'
        if (Test-Path $secret) { try { $ApiToken = & $secret -Get 'ZabbixApiToken' 2>$null } catch { } }
    }
    if (-not $ApiToken) { Write-Log "No Zabbix API token (pass -ApiToken or store 'ZabbixApiToken' in 19-Secrets)." 'WARN'; return $null }
    $api = ($ZabbixUrl.TrimEnd('/')) + '/api_jsonrpc.php'
    function Invoke-Zbx { param([string]$Method,$Params)
        $payload = @{ jsonrpc='2.0'; method=$Method; params=$Params; id=1 } | ConvertTo-Json -Depth 8
        $r = Invoke-RestMethod -Uri $api -Method Post -ContentType 'application/json-rpc' -Body $payload -Headers @{ Authorization = "Bearer $ApiToken" } -ErrorAction Stop
        if ($r.error) { throw ("{0} - {1}" -f $r.error.message, $r.error.data) }
        return $r.result
    }
    $groupName = if ($map -and $map.zabbixGroup) { $map.zabbixGroup } elseif ($Company) { $Company } else { $null }
    $hostParams = @{ output=@('host','name'); selectInterfaces=@('ip','available'); selectInventory=@('os','os_full') }
    if ($groupName) {
        $g = Invoke-Zbx 'hostgroup.get' @{ output='groupid'; filter=@{ name=@($groupName) } }
        if (-not $g) { Write-Log "Zabbix host group '$groupName' not found." 'WARN'; return @() }
        $hostParams.groupids = @($g | ForEach-Object { $_.groupid })
    }
    $hosts = Invoke-Zbx 'host.get' $hostParams
    $out = foreach ($h in $hosts) {
        $ip = ($h.interfaces | Select-Object -First 1).ip
        $avail = ($h.interfaces | ForEach-Object { $_.available }) -contains '1'
        $osTxt = if ($h.inventory.os_full) { $h.inventory.os_full } elseif ($h.inventory.os) { $h.inventory.os } else { '' }
        [pscustomobject]@{ Company=$(if($Company){$Company}else{$groupName}); Name=$h.host; IPv4=$ip; OS=$osTxt; Online=$avail; Source='Zabbix' }
    }
    return @($out)
}

# --- AD source ----------------------------------------------------------------------
function Get-FromAD {
    if (-not (Get-Module -ListAvailable ActiveDirectory)) { Write-Log "ActiveDirectory module not available here." 'WARN'; return $null }
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    $base = if ($SearchBase) { $SearchBase } elseif ($map -and $map.adOU) { $map.adOU } else { $null }
    $params = @{ Filter='*'; Properties=@('OperatingSystem','IPv4Address','LastLogonDate') }
    if ($base) { $params.SearchBase = $base }
    try { $comps = Get-ADComputer @params } catch { Write-Log "Get-ADComputer failed: $($_.Exception.Message)" 'WARN'; return $null }
    $out = foreach ($c in $comps) {
        [pscustomobject]@{ Company=$Company; Name=$c.Name; IPv4=$c.IPv4Address; OS=$c.OperatingSystem; Online=($null -ne $c.IPv4Address); Source='AD' }
    }
    return @($out)
}

# --- resolve ------------------------------------------------------------------------
Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Managed fleet" -ForegroundColor White
Write-Host "  =================================" -ForegroundColor DarkGray

$fleet = $null
switch ($Source) {
    'Zabbix' { $fleet = Get-FromZabbix }
    'AD'     { $fleet = Get-FromAD }
    'Intune' { Write-Log "Intune source: use 09-Entra-Intune\Get-IntuneDeviceCompliance.ps1 for the device list (Graph)." 'INFO'; $fleet = @() }
    'Auto'   { $fleet = Get-FromZabbix; if ($null -eq $fleet) { Write-Log "Falling back to Active Directory." 'INFO'; $fleet = Get-FromAD } }
}
if ($null -eq $fleet) { Write-Log "No source available. See Get-Help for -Source / -ZabbixUrl / -SearchBase." 'ERROR'; return }

$fleet = @($fleet)
if ($OS)         { $fleet = @($fleet | Where-Object { $_.OS -like $OS }) }
if ($OnlineOnly) { $fleet = @($fleet | Where-Object { $_.Online }) }

Write-Log ("{0} device(s){1}." -f $fleet.Count, $(if($Company){" for '$Company'"}else{''})) 'OK'
$fleet | Sort-Object Name | Format-Table Name, IPv4, OS, Online, Source -AutoSize | Out-Host
# emit objects too (for the pipeline / the fleet runner)
$fleet
