# Config — your environment, filled in once

This folder is created by the installer and **never overwritten** by a later install
or update, so what you put here survives every new version of the kit.

| File | What it holds | Read by |
|---|---|---|
| `toolkit-settings.json` | Everything that is fixed for your environment: company name and helpdesk info, AD OUs and UPN suffix, Entra licences and groups, file server and shares, regional and power defaults, Teams webhook / SMTP, Zabbix server, expected local admins, report folder, schedules. | Every script that has such a value as a parameter |
| `desktop-shortcuts.json` | The shortcuts that belong on every desktop. | `20-Desktop-Experience\New-DesktopShortcuts.ps1` |
| `Branding\` | `wallpaper.jpg`, `lockscreen.jpg`, `logo.bmp` | `20-Desktop-Experience\Set-Branding.ps1` |

## The rule

1. A parameter you type on the command line **always wins**.
2. Otherwise the script looks here (`Config\toolkit-settings.json`).
3. If the value is empty here, the script behaves as its help describes: uses its
   built-in default, asks, or skips that part.

So `Set-Branding.ps1` with no arguments applies *your* wallpaper and support info,
`New-DesktopShortcuts.ps1` creates *your* shortcuts, `Send-ToolkitAlert.ps1` knows
*your* webhook — and the same scripts still work on a PC without this folder.

Every script prints one grey line telling you which values it took from here
(`[Config] using: Alerting.TeamsWebhookUrl, Alerting.EmailTo`), so nothing is silent.

## Where scripts look

In this order: `SYSADMIN_TOOLKIT_CONFIG` environment variable (a folder), the `Config`
folder next to the script's section (`..\Config`), a `Config` folder next to the script,
`C:\Sysadmin-Toolkit\Config`. A single script copied to another PC finds none of these
and simply runs as before.

## Editing

Plain JSON: strings in double quotes, lists in `[ ]`, no trailing comma after the last
item. Keys starting with `_` are comments and are ignored. After editing, run any script
with `-WhatIf` to see the values it picked up. `Tests\Run-Tests.ps1` also checks that
this file is valid JSON.

## Secrets

The Teams webhook URL and SMTP details are readable by anyone who can read this folder.
On a shared machine, keep them in `19-Secrets` (DPAPI-encrypted, per user) instead and
leave them empty here.
