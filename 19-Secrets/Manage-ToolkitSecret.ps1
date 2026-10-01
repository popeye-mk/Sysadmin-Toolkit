<#
.SYNOPSIS
    Store and retrieve small secrets (webhook URLs, app-registration client
    secrets, SMTP passwords) encrypted with Windows DPAPI — so they never sit
    in plaintext inside a script or config file.

.DESCRIPTION
    Fully standalone — no dependency on any other file in this kit. No extra
    infrastructure either: it uses Windows Data Protection (DPAPI) via
    ConvertFrom-SecureString, which ties the encrypted value to THIS user
    account on THIS machine. That's the point and the limitation in one:

      - Nobody else can decrypt the file, even with a copy of it.
      - It won't decrypt on another machine or as another user (e.g. a
        Scheduled Task running as SYSTEM can't read a secret you saved as
        yourself — save it while running as that account instead:
        psexec -s -i powershell, then run -Set there).

    Secrets are kept in one JSON file (default C:\Sysadmin-Toolkit\secrets.json)
    as name -> encrypted blob. Reading one back gives you a plain string,
    ready to pass to Send-ToolkitAlert.ps1 or a Graph app-only sign-in.

.PARAMETER Set
    Name of the secret to store. You'll be prompted for the value (hidden
    input), or pass -Value.
.PARAMETER Value
    The secret value (plaintext) — only for scripting; interactive prompt is
    safer because the value never lands in your command history.
.PARAMETER Get
    Name of the secret to read back. Returns the plaintext string.
.PARAMETER List
    List stored secret names (never the values).
.PARAMETER Remove
    Name of the secret to delete.
.PARAMETER StorePath
    Path to the secrets file. Default: C:\Sysadmin-Toolkit\secrets.json

.EXAMPLE
    .\Manage-ToolkitSecret.ps1 -Set TeamsWebhook
    # (prompts, hidden)
.EXAMPLE
    $webhook = .\Manage-ToolkitSecret.ps1 -Get TeamsWebhook
    & .\13-Alerting\Send-ToolkitAlert.ps1 -Message "hi" -TeamsWebhookUrl $webhook
.EXAMPLE
    .\Manage-ToolkitSecret.ps1 -List
    .\Manage-ToolkitSecret.ps1 -Remove TeamsWebhook

.NOTES
    Windows only (DPAPI). Works on Windows PowerShell 5.1 and PowerShell 7 on
    Windows. The secrets file is safe to leave on disk but keep it out of
    source control anyway (it's in the kit's .gitignore). Part of the
    Sysadmin-Toolkit family. Author: Stojan Tomeski.
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Set')][string]$Set,
    [Parameter(ParameterSetName = 'Set')][string]$Value,
    [Parameter(Mandatory, ParameterSetName = 'Get')][string]$Get,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][string]$Remove,
    [string]$StorePath = 'C:\Sysadmin-Toolkit\secrets.json'
)

function Write-Log {
    param([Parameter(Mandatory, Position = 0)][string]$Message, [Parameter(Position = 1)][string]$Level = 'INFO')
    $c = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host ("[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $c
}
function Read-Store {
    if (-not (Test-Path $StorePath)) { return @{} }
    try {
        $obj = Get-Content $StorePath -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { Write-Log "Could not read ${StorePath}: $($_.Exception.Message)" 'ERROR'; return $null }
}
function Write-Store {
    param([hashtable]$Store)
    $dir = Split-Path $StorePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($Store | ConvertTo-Json) | Set-Content -Path $StorePath -Encoding UTF8
}

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Log "DPAPI is Windows-only — this script doesn't work on Linux/macOS." 'ERROR'; return
}

switch ($PSCmdlet.ParameterSetName) {
    'Set' {
        $secure = if ($Value) { ConvertTo-SecureString $Value -AsPlainText -Force }
                  else { Read-Host -Prompt "Value for '$Set' (hidden)" -AsSecureString }
        if (-not $secure -or $secure.Length -eq 0) { Write-Log "Empty value — nothing stored." 'WARN'; return }
        $store = Read-Store; if ($null -eq $store) { return }
        $store[$Set] = ($secure | ConvertFrom-SecureString)   # DPAPI-encrypted, user+machine bound
        Write-Store -Store $store
        Write-Log "Stored '$Set' (encrypted for $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME) -> $StorePath" 'OK'
    }
    'Get' {
        $store = Read-Store; if ($null -eq $store) { return }
        if (-not $store.ContainsKey($Get)) { Write-Log "No secret named '$Get' in $StorePath" 'ERROR'; return }
        try {
            $secure = $store[$Get] | ConvertTo-SecureString -ErrorAction Stop
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } catch {
            Write-Log "Could not decrypt '$Get' — it was saved by a different user or on a different machine (DPAPI). Re-save it as the account that needs to read it." 'ERROR'
        }
    }
    'Remove' {
        $store = Read-Store; if ($null -eq $store) { return }
        if (-not $store.ContainsKey($Remove)) { Write-Log "No secret named '$Remove'." 'WARN'; return }
        $store.Remove($Remove)
        Write-Store -Store $store
        Write-Log "Removed '$Remove'." 'OK'
    }
    default {
        $store = Read-Store; if ($null -eq $store) { return }
        if (-not $store.Count) { Write-Log "No secrets stored yet in $StorePath" 'INFO'; return }
        Write-Host ''
        Write-Host "  Secrets in $StorePath (names only):" -ForegroundColor White
        $store.Keys | Sort-Object | ForEach-Object { Write-Host "    - $_" }
    }
}
