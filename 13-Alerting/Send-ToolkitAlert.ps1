<#
.SYNOPSIS
    Send one alert — Teams webhook, e-mail, or both — from the command line or
    from any other script. The one place alert-sending logic lives.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit, and
    nothing else in the kit is required to call it: run it by hand for a
    one-off ping, or invoke it from another script by full path (it's a
    script, not a module, so no Import-Module gymnastics either way).

    With no -TeamsWebhookUrl and no SMTP params, it just prints the formatted
    message and warns that no channel is configured — safe to run/test without
    setup, and it never fails a calling script just because alerting isn't
    wired up yet.

.PARAMETER Message
    The alert text.
.PARAMETER Level
    INFO | OK | WARN | ERROR — affects the color used (Teams: card color;
    console: text color; e-mail: subject prefix).
.PARAMETER Title
    Short title/subject (default 'Sysadmin-Toolkit Alert').
.PARAMETER TeamsWebhookUrl
    An Incoming Webhook URL from a Teams channel connector.
.PARAMETER SmtpServer
    Send via e-mail instead of (or as well as) Teams.
.PARAMETER EmailFrom
    Send via e-mail instead of (or as well as) Teams.
.PARAMETER EmailTo
    Send via e-mail instead of (or as well as) Teams.
.PARAMETER SmtpPort
    Send via e-mail instead of (or as well as) Teams.

.EXAMPLE
    .\Send-ToolkitAlert.ps1 -Message "Disk on SRV01 is below 10%" -Level WARN -TeamsWebhookUrl $webhook

.EXAMPLE
    # from another script, e.g. after a failed check:
    & "$PSScriptRoot\..\13-Alerting\Send-ToolkitAlert.ps1" -Message "AD health: 2 replication failures" -Level ERROR -TeamsWebhookUrl $webhook

.EXAMPLE
    .\Send-ToolkitAlert.ps1 -Message "Backup completed" -Level OK -SmtpServer smtp.contoso.local -EmailFrom toolkit@contoso.local -EmailTo it@contoso.local

.NOTES
    Teams: posts a legacy MessageCard via Invoke-RestMethod (works with any
    Incoming Webhook connector — no extra module needed). If Microsoft
    retires MessageCard support for your tenant's connector, swap in an
    Adaptive Card payload; the -TeamsWebhookUrl plumbing stays the same.
    Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO',
    [string]$Title = 'Sysadmin-Toolkit Alert',
    [string]$TeamsWebhookUrl,
    [string]$SmtpServer,
    [string]$EmailFrom,
    [string]$EmailTo,
    [int]$SmtpPort = 25
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
if (-not $PSBoundParameters.ContainsKey('TeamsWebhookUrl')) { $__v = Get-ToolkitSetting 'Alerting.TeamsWebhookUrl'; if ($null -ne $__v) { $TeamsWebhookUrl = $__v; $__cfgUsed += 'Alerting.TeamsWebhookUrl' } }
if (-not $PSBoundParameters.ContainsKey('SmtpServer')) { $__v = Get-ToolkitSetting 'Alerting.SmtpServer'; if ($null -ne $__v) { $SmtpServer = $__v; $__cfgUsed += 'Alerting.SmtpServer' } }
if (-not $PSBoundParameters.ContainsKey('EmailFrom')) { $__v = Get-ToolkitSetting 'Alerting.EmailFrom'; if ($null -ne $__v) { $EmailFrom = $__v; $__cfgUsed += 'Alerting.EmailFrom' } }
if (-not $PSBoundParameters.ContainsKey('EmailTo')) { $__v = Get-ToolkitSetting 'Alerting.EmailTo'; if ($null -ne $__v) { $EmailTo = $__v; $__cfgUsed += 'Alerting.EmailTo' } }
if (-not $PSBoundParameters.ContainsKey('SmtpPort')) { $__v = Get-ToolkitSetting 'Alerting.SmtpPort'; if ($null -ne $__v) { $SmtpPort = $__v; $__cfgUsed += 'Alerting.SmtpPort' } }
if ($__cfgUsed.Count) { Write-Host ("  [Config] using: " + ($__cfgUsed -join ', ') + "  (from " + $script:__cfg.Dir + ")") -ForegroundColor DarkGray }
# --- end Config -----------------------------------------------------------------------


function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}

$color = @{ INFO = '757575'; OK = '2e7d32'; WARN = 'f9a825'; ERROR = 'c62828' }[$Level]
$sentAny = $false

Write-Log "[$Level] $Title — $Message" $Level

# --- Teams -----------------------------------------------------------------------
if ($TeamsWebhookUrl) {
    $body = @{
        '@type'    = 'MessageCard'
        '@context' = 'http://schema.org/extensions'
        themeColor = $color
        summary    = $Title
        title      = "$Title [$Level]"
        text       = $Message
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
        Write-Log "Teams notification sent." 'OK'
        $sentAny = $true
    } catch {
        Write-Log "Teams notification failed: $($_.Exception.Message)" 'WARN'
    }
}

# --- e-mail ------------------------------------------------------------------------
if ($SmtpServer -and $EmailFrom -and $EmailTo) {
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort -From $EmailFrom -To $EmailTo `
            -Subject "[$Level] $Title" -Body $Message -ErrorAction Stop
        Write-Log "E-mail sent to $EmailTo." 'OK'
        $sentAny = $true
    } catch {
        Write-Log "E-mail send failed: $($_.Exception.Message)" 'WARN'
    }
}

if (-not $sentAny) {
    Write-Log "No alert channel configured (pass -TeamsWebhookUrl, or -SmtpServer/-EmailFrom/-EmailTo) — message was only printed above." 'WARN'
}

# so a calling script can check: if (-not (& .\Send-ToolkitAlert.ps1 ...)) { ... }
return $sentAny
