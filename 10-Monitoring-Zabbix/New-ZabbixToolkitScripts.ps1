<#
.SYNOPSIS
    Create the toolkit's Zabbix buttons in one go — one manual host-action global
    script per fast read-only kit script, from toolkit-zabbix-scripts.json.

.DESCRIPTION
    Instead of adding each Zabbix script by hand (Alerts > Scripts), this reads
    the definitions in `toolkit-zabbix-scripts.json` next to it and creates them
    over the Zabbix API. Each becomes a "Manual host action" script that executes
    on the Zabbix agent and shows the kit script's output in the result window.

    Idempotent: a script whose name already exists is updated, not duplicated.
    `-WhatIf` shows what would be created/updated and changes nothing.

    Prerequisite on each host: the agent must allow command execution. For a lab,
    `AllowKey=system.run[*]`. For production, restrict it to the toolkit only
    (see Zabbix-Run-Toolkit-Scripts.md):
        AllowKey=system.run[powershell*C:\Sysadmin-Toolkit\*]
        DenyKey=system.run[*]

.PARAMETER ZabbixUrl
    Base URL of the Zabbix frontend, e.g. http://192.168.122.152/zabbix .
    Falls back to Config `Monitoring.ZabbixUrl`. The API endpoint
    (`api_jsonrpc.php`) is appended automatically.
.PARAMETER ApiToken
    A Zabbix API token (Users > API tokens). Preferred. If omitted, the script
    looks for a stored secret named `ZabbixApiToken` in 19-Secrets, then falls
    back to -Credential.
.PARAMETER Credential
    Zabbix user/password (used only if no API token is available).
.PARAMETER HostGroup
    Limit the buttons to hosts in this Zabbix host group (e.g. a customer group).
    Omit to offer them on every host.
.PARAMETER DefinitionsPath
    The JSON definitions. Default: toolkit-zabbix-scripts.json next to this script.
.PARAMETER InstallRoot
    Where the kit is installed on the target hosts. Default C:\Sysadmin-Toolkit.
.PARAMETER Folder
    Instead of the curated JSON, scan a kit section folder and expose every
    read-only script in it (Get-/Test-/Find-/Measure-/Show-/Read-/Confirm-) as a
    button in one shot. Machine-changing scripts (Set-/New-/Disable-/Remove-/
    Enable-/Invoke-/...) are skipped automatically so they can't become one-click
    buttons. Button names are humanised from the file name; descriptions come
    from each script's .SYNOPSIS. Re-run it any time — the kit folder is the
    source of truth for folder mode.
.PARAMETER Remove
    Delete the toolkit's Zabbix scripts (those whose name starts with the prefix)
    instead of creating them.

.EXAMPLE
    .\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix -ApiToken <token> -WhatIf
.EXAMPLE
    .\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Folder "07-Reporting-Health"
.EXAMPLE
    .\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -HostGroup 'Contoso'
.EXAMPLE
    .\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Remove

.NOTES
    Read-only against the hosts; it only creates script *definitions* on the
    Zabbix server. Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ZabbixUrl,
    [string]$ApiToken,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$HostGroup,
    [string]$Folder,
    [string]$DefinitionsPath = (Join-Path $PSScriptRoot 'toolkit-zabbix-scripts.json'),
    [string]$InstallRoot = 'C:\Sysadmin-Toolkit',
    [switch]$Remove
)

# --- inline helpers (standalone-safe) -----------------------------------------------
function Write-Log {
    param([Parameter(Position=0,Mandatory)][string]$Message,[Parameter(Position=1)][ValidateSet('INFO','OK','WARN','ERROR','STEP')][string]$Level='INFO')
    $c = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; STEP='Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Message) -ForegroundColor $c
}
function Get-ToolkitSetting {
    param([string]$Key)
    if (-not $script:__cfg) {
        $script:__cfg = @{ Data = $null }
        $cands = @()
        if ($env:SYSADMIN_TOOLKIT_CONFIG) { $cands += $env:SYSADMIN_TOOLKIT_CONFIG }
        if ($PSScriptRoot) { $p = Split-Path $PSScriptRoot -Parent; if ($p) { $cands += (Join-Path $p 'Config') } }
        $cands += 'C:\Sysadmin-Toolkit\Config'
        foreach ($d in $cands) {
            $f = $null; try { $f = Join-Path $d 'toolkit-settings.json' -ErrorAction Stop } catch { continue }
            if ($f -and (Test-Path -LiteralPath $f -ErrorAction SilentlyContinue)) {
                try { $script:__cfg.Data = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; break } catch { }
            }
        }
    }
    if (-not $script:__cfg.Data) { return $null }
    $node = $script:__cfg.Data
    foreach ($part in $Key.Split('.')) {
        if ($null -eq $node -or -not ($node.PSObject.Properties.Name -contains $part)) { return $null }
        $node = $node.$part
    }
    if ($node -is [string] -and $node.Trim() -eq '') { return $null }
    return $node
}

Write-Host ''
Write-Host "  Sysadmin-Toolkit :: Zabbix button set" -ForegroundColor White
Write-Host "  =====================================" -ForegroundColor DarkGray

# --- resolve connection -------------------------------------------------------------
if (-not $ZabbixUrl) { $ZabbixUrl = Get-ToolkitSetting 'Monitoring.ZabbixUrl' }
if (-not $ZabbixUrl) { Write-Log "No Zabbix URL. Pass -ZabbixUrl or set Monitoring.ZabbixUrl in Config." 'ERROR'; return }
$api = ($ZabbixUrl.TrimEnd('/')) + '/api_jsonrpc.php'

if (-not $ApiToken) {
    # try 19-Secrets store
    $secretScript = Join-Path (Split-Path $PSScriptRoot -Parent) '19-Secrets\Manage-ToolkitSecret.ps1'
    if (Test-Path $secretScript) {
        try { $ApiToken = & $secretScript -Get 'ZabbixApiToken' 2>$null } catch { }
    }
}

$authHeader = $null; $sessionAuth = $null
if ($ApiToken) {
    $authHeader = @{ Authorization = "Bearer $ApiToken" }
} elseif ($Credential) {
    $body = @{ jsonrpc='2.0'; method='user.login'; params=@{ username=$Credential.UserName; password=$Credential.GetNetworkCredential().Password }; id=1 } | ConvertTo-Json
    try {
        $r = Invoke-RestMethod -Uri $api -Method Post -ContentType 'application/json-rpc' -Body $body -ErrorAction Stop
        if ($r.error) { Write-Log "Login failed: $($r.error.data)" 'ERROR'; return }
        $sessionAuth = $r.result
    } catch { Write-Log "Cannot reach Zabbix API at $api : $($_.Exception.Message)" 'ERROR'; return }
} else {
    Write-Log "No credentials. Pass -ApiToken (preferred), store a 'ZabbixApiToken' secret in 19-Secrets, or pass -Credential." 'ERROR'; return
}

function Invoke-Zbx {
    param([string]$Method,$Params)
    $payload = @{ jsonrpc='2.0'; method=$Method; params=$Params; id=[int](Get-Random -Maximum 100000) }
    if ($sessionAuth) { $payload.auth = $sessionAuth }
    $json = $payload | ConvertTo-Json -Depth 8
    $params = @{ Uri=$api; Method='Post'; ContentType='application/json-rpc'; Body=$json; ErrorAction='Stop' }
    if ($authHeader) { $params.Headers = $authHeader }
    $resp = Invoke-RestMethod @params
    if ($resp.error) { throw ("{0} - {1}" -f $resp.error.message, $resp.error.data) }
    return $resp.result
}

# --- connectivity + version ---------------------------------------------------------
try {
    # apiinfo.version is a public method and Zabbix rejects it if an auth header is sent, so call it header-free.
    $__verBody = @{ jsonrpc='2.0'; method='apiinfo.version'; params=@(); id=1 } | ConvertTo-Json
    $ver = (Invoke-RestMethod -Uri $api -Method Post -ContentType 'application/json-rpc' -Body $__verBody -ErrorAction Stop).result
} catch { Write-Log "API call failed: $($_.Exception.Message)" 'ERROR'; return }
Write-Log "Connected to Zabbix $ver at $ZabbixUrl" 'OK'

# --- resolve host group id (optional) ----------------------------------------------
$groupIds = $null
if ($HostGroup) {
    try {
        $g = Invoke-Zbx 'hostgroup.get' @{ output='groupid'; filter=@{ name=@($HostGroup) } }
        if (-not $g) { Write-Log "Host group '$HostGroup' not found." 'ERROR'; return }
        $groupIds = @($g | ForEach-Object { $_.groupid })
        Write-Log "Scoping to host group '$HostGroup' (groupid $($groupIds -join ','))." 'INFO'
    } catch { Write-Log "hostgroup.get failed: $($_.Exception.Message)" 'ERROR'; return }
}

# --- load definitions ---------------------------------------------------------------
if ($Folder) {
    # Folder mode: scan a kit section and expose every read-only script in it as a button.
    $kitRoot = Split-Path $PSScriptRoot -Parent
    if ([System.IO.Path]::IsPathRooted($Folder)) { $folderPath = $Folder } else { $folderPath = Join-Path $kitRoot $Folder }
    if (-not (Test-Path -LiteralPath $folderPath)) { Write-Log "Folder not found: $folderPath" 'ERROR'; return }
    $rp = (Resolve-Path -LiteralPath $folderPath).Path
    if ($rp.ToLower().IndexOf($kitRoot.ToLower()) -ne 0) { Write-Log "Folder must be inside the kit ($kitRoot) so the targets can find the scripts." 'ERROR'; return }
    # Only these verbs are treated as read-only and auto-exposed. Everything else (Set-/New-/Disable-/
    # Remove-/Enable-/Invoke-/...) is skipped so a machine-changing script can't become a one-click button.
    $readVerbs = @('Get','Test','Find','Measure','Show','Read','Confirm')
    $scriptsFound = @(); $skipped = @()
    foreach ($fi in (Get-ChildItem -LiteralPath $rp -Filter *.ps1 -File)) {
        $verb = ($fi.BaseName -split '-')[0]
        if ($readVerbs -notcontains $verb) { $skipped += $fi.Name; continue }
        $rel  = $fi.FullName.Substring($kitRoot.Length).TrimStart('\')
        $core = $fi.BaseName -replace ('^' + [regex]::Escape($verb) + '-'), ''
        $nm   = ($core -creplace '([A-Z]+)([A-Z][a-z])','$1 $2') -creplace '([a-z0-9])([A-Z])','$1 $2'
        $desc = ''
        try {
            $lines = Get-Content -LiteralPath $fi.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '\.SYNOPSIS') {
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].Trim()) { $desc = $lines[$j].Trim(); break } }
                    break
                }
            }
        } catch { }
        $scriptsFound += [pscustomobject]@{ name = $nm; script = $rel; description = $desc }
    }
    if (-not $scriptsFound.Count) { Write-Log "No read-only scripts (Get-/Test-/Find-/Measure-/Show-/Read-/Confirm-) in $rp." 'WARN'; return }
    $def = [pscustomobject]@{ menuPathPrefix = 'Toolkit'; scripts = $scriptsFound }
    $prefix = 'Toolkit'
    Write-Log ("Folder scan of '{0}': {1} read-only script(s) to expose, {2} change-script(s) skipped for safety." -f (Split-Path $rp -Leaf), $scriptsFound.Count, $skipped.Count) 'INFO'
    if ($skipped.Count) { Write-Log ("Skipped (not read-only): {0}" -f ($skipped -join ', ')) 'INFO' }
} else {
    if (-not (Test-Path -LiteralPath $DefinitionsPath)) { Write-Log "Definitions not found: $DefinitionsPath" 'ERROR'; return }
    try { $def = Get-Content -LiteralPath $DefinitionsPath -Raw | ConvertFrom-Json } catch { Write-Log "Definitions JSON invalid: $($_.Exception.Message)" 'ERROR'; return }
    $prefix = if ($def.menuPathPrefix) { $def.menuPathPrefix } else { 'Toolkit' }
}

# existing toolkit scripts (by name prefix)
try { $existing = Invoke-Zbx 'script.get' @{ output=@('scriptid','name') } } catch { $existing = @() }
$byName = @{}
foreach ($e in $existing) { $byName[$e.name] = $e.scriptid }

# --- remove mode --------------------------------------------------------------------
if ($Remove) {
    $ids = @()
    foreach ($e in $existing) { if ($e.name -like "$prefix*") { $ids += $e.scriptid } }
    if (-not $ids.Count) { Write-Log "No '$prefix' scripts to remove." 'INFO'; return }
    if ($PSCmdlet.ShouldProcess("$($ids.Count) Zabbix script(s)", "Delete")) {
        try { Invoke-Zbx 'script.delete' $ids | Out-Null; Write-Log "Removed $($ids.Count) toolkit script(s)." 'OK' }
        catch { Write-Log "script.delete failed: $($_.Exception.Message)" 'ERROR' }
    }
    return
}

# --- create / update ----------------------------------------------------------------
$created = 0; $updated = 0
foreach ($s in $def.scripts) {
    $name = "{0}: {1}" -f $prefix, $s.name
    $rel  = $s.script
    $extra = if ($s.args) { ' ' + $s.args } else { '' }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}\{1}"{2}' -f $InstallRoot.TrimEnd('\'), $rel, $extra

    $obj = @{
        name        = $name
        command     = $cmd
        type        = 0     # custom script
        execute_on  = 0     # Zabbix agent
        scope       = 2     # manual host action
        description = [string]$s.description
    }
    if ($groupIds) { $obj.groupid = $groupIds[0] }

    if ($byName.ContainsKey($name)) {
        $obj.scriptid = $byName[$name]
        if ($PSCmdlet.ShouldProcess($name, "Update Zabbix script")) {
            try { Invoke-Zbx 'script.update' $obj | Out-Null; Write-Log "Updated: $name" 'OK'; $updated++ }
            catch { Write-Log "Update failed for '$name': $($_.Exception.Message)" 'WARN' }
        }
    } else {
        if ($PSCmdlet.ShouldProcess($name, "Create Zabbix script")) {
            try { Invoke-Zbx 'script.create' $obj | Out-Null; Write-Log "Created: $name" 'OK'; $created++ }
            catch { Write-Log "Create failed for '$name': $($_.Exception.Message)" 'WARN' }
        }
    }
}

Write-Host ''
Write-Host ("  Done. Created {0}, updated {1}. In Zabbix: click a host -> Scripts -> '{2}: ...'." -f $created, $updated, $prefix) -ForegroundColor Green
Write-Host "  Each host's agent needs command execution allowed (see Zabbix-Run-Toolkit-Scripts.md)." -ForegroundColor DarkGray
