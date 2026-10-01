# 04 — PC Provisioning (setting up a new machine)

Turning a fresh Windows PC into a ready-to-use company machine: rename it, set
the power plan, install a standard software set, join it to the domain, map
drives and printers, and apply a basic hardening pass.

Run as an **administrator** on the machine you're setting up. As always, try
**`-WhatIf`** first on anything that changes the machine.

| Script | What it does |
| --- | --- |
| `Initialize-NewPC.ps1` | First-touch setup: rename, power plan, enable RDP, install apps with winget, time zone, update scan. |
| `Join-Domain.ps1` | Join the machine to your domain, optionally renaming it and placing it in a specific OU. |
| `Setup-PrintersAndDrives.ps1` | Map network drives and install printers (you edit the list at the top of the script). |
| `Harden-Baseline.ps1` | A conservative security hardening pass for a standalone PC. Has `-Rollback`. |

---

## First-touch setup (worked example)

```powershell
# Preview everything it would do:
.\04-PC-Provisioning\Initialize-NewPC.ps1 -NewName PC-SALES-07 -EnableRDP -WhatIf

# For real:
.\04-PC-Provisioning\Initialize-NewPC.ps1 -NewName PC-SALES-07 -EnableRDP -TimeZone "W. Europe Standard Time"
```

By default it installs a sensible app set with **winget** (7-Zip, Chrome,
Firefox, VLC, Notepad++, Acrobat Reader). Change it with `-Apps "Google.Chrome","Mozilla.Firefox"`.
Needs **winget** present (built into Windows 11 / recent Windows 10).

---

## Join the domain (worked example)

This is high-stakes, so preview first. **Before you run it:** the PC's DNS must
point at a **domain controller** — that's how it finds the domain. If join fails,
that's the first thing to check.

```powershell
# Preview:
.\04-PC-Provisioning\Join-Domain.ps1 -Domain lab.local -NewName PC-SALES-07 -WhatIf

# For real — it will ask for domain-join credentials, then reboot:
.\04-PC-Provisioning\Join-Domain.ps1 -Domain lab.local -NewName PC-SALES-07 `
    -OUPath "OU=Workstations,DC=lab,DC=local" -Restart
```

`-OUPath` drops the computer straight into the right OU (so the right GPOs apply
immediately). `-Restart` reboots to finish the join. Leave `-Restart` off if you
want to reboot yourself later.

**What success looks like:** it reports the machine joined the domain; after the
reboot you can sign in with a domain account.

---

## Drives and printers

Open `Setup-PrintersAndDrives.ps1` and edit the `$Drives` and `$Printers` lists
at the top (there are commented examples). Then:

```powershell
.\04-PC-Provisioning\Setup-PrintersAndDrives.ps1 -WhatIf
.\04-PC-Provisioning\Setup-PrintersAndDrives.ps1
```

It's safe to re-run — it skips anything already there.

---

## Basic hardening (with an undo)

```powershell
.\04-PC-Provisioning\Harden-Baseline.ps1 -WhatIf     # see what it would change
.\04-PC-Provisioning\Harden-Baseline.ps1             # apply
.\04-PC-Provisioning\Harden-Baseline.ps1 -Rollback <backup-folder>   # undo
```

It backs up what it changes first, so `-Rollback` can put it back.
