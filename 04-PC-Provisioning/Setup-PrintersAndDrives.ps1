<#
.SYNOPSIS
    Map network drives and install network printers from a simple manifest —
    the without-GPO way to push drives/printers to a machine.

.DESCRIPTION
    Edit the $Drives and $Printers blocks below, then run. Persistent drive
    mappings survive reboot. Printers are added by TCP/IP host; the matching
    driver must already be installed on the machine (the script warns if not).
    Idempotent: existing mappings/printers are skipped. Supports -WhatIf.

    Runs in the CURRENT user's context (drives/printers are per-user).

.EXAMPLE
    .\Setup-PrintersAndDrives.ps1 -WhatIf
.EXAMPLE
    .\Setup-PrintersAndDrives.ps1

.NOTES
    Part of the TechToolkit family.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

# ---------------------------------------------------------------------------
# EDIT THESE. Examples included — replace with your real shares/printers.
# ---------------------------------------------------------------------------
$Drives = @(
    # @{ Letter = 'S'; Path = '\\fileserver\shared';  Label = 'Shared'  }
    # @{ Letter = 'H'; Path = '\\fileserver\home\%USERNAME%'; Label = 'Home' }
)

$Printers = @(
    # @{ Name = 'Office-HP';  HostAddress = '192.168.1.50'; DriverName = 'HP Universal Printing PCL 6'; Default = $true }
    # @{ Name = 'Warehouse';  HostAddress = '192.168.1.51'; DriverName = 'Generic / Text Only' }
)
# ---------------------------------------------------------------------------

if (-not $Drives -and -not $Printers) {
    Write-Warning "No drives or printers defined. Edit the `$Drives / `$Printers blocks at the top of this script."
    return
}

Write-Host "TechToolkit :: Setup-PrintersAndDrives" -ForegroundColor White
if ($WhatIfPreference) { Write-Host "MODE : WhatIf (nothing applied)" -ForegroundColor Yellow }

# ---------- drives ----------
if ($Drives) {
    Write-Host "`n==== Network drives ====" -ForegroundColor Cyan
    foreach ($d in $Drives) {
        $letter = ($d.Letter.TrimEnd(':')) + ':'
        $path   = [Environment]::ExpandEnvironmentVariables($d.Path)

        if (Test-Path $letter) {
            Write-Host "  [=] $letter already mapped" -ForegroundColor DarkGray
            continue
        }
        if ($PSCmdlet.ShouldProcess("$letter -> $path", "Map persistent drive")) {
            try {
                net.exe use $letter $path /persistent:yes | Out-Null
                if ($d.Label) {
                    $sh = New-Object -ComObject Shell.Application
                    $sh.NameSpace($letter).Self.Name = $d.Label
                }
                Write-Host "  [+] $letter -> $path" -ForegroundColor Green
            } catch { Write-Host "  [!] $letter — $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
}

# ---------- printers ----------
if ($Printers) {
    Write-Host "`n==== Printers ====" -ForegroundColor Cyan
    foreach ($p in $Printers) {
        if (Get-Printer -Name $p.Name -ErrorAction SilentlyContinue) {
            Write-Host "  [=] '$($p.Name)' already installed" -ForegroundColor DarkGray
        }
        elseif ($PSCmdlet.ShouldProcess($p.Name, "Add TCP/IP printer $($p.HostAddress)")) {
            try {
                if (-not (Get-PrinterDriver -Name $p.DriverName -ErrorAction SilentlyContinue)) {
                    Write-Host "  [!] driver '$($p.DriverName)' not installed — install it first, skipping '$($p.Name)'" -ForegroundColor Yellow
                    continue
                }
                $port = "IP_$($p.HostAddress)"
                if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
                    Add-PrinterPort -Name $port -PrinterHostAddress $p.HostAddress -ErrorAction Stop
                }
                Add-Printer -Name $p.Name -DriverName $p.DriverName -PortName $port -ErrorAction Stop
                Write-Host "  [+] '$($p.Name)' on $($p.HostAddress)" -ForegroundColor Green
            } catch { Write-Host "  [!] '$($p.Name)' — $($_.Exception.Message)" -ForegroundColor Yellow }
        }

        if ($p.Default -and -not $WhatIfPreference) {
            try {
                (New-Object -ComObject WScript.Network).SetDefaultPrinter($p.Name)
                Write-Host "      set as default" -ForegroundColor DarkGray
            } catch { }
        }
    }
}

Write-Host "`nDone." -ForegroundColor Cyan
