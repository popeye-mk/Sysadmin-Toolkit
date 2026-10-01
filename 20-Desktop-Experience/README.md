# 20 — Desktop Experience

The "make it look and behave like a proper work PC" layer: theme, icons,
shortcuts, branding, pinned apps, right-click menu, regional defaults,
power and lock. Seven independent scripts — each runs on its own, each
backs up before it changes anything, each has `-Rollback` and honours
`-WhatIf`. The baselines in `02-Windows11` / `03-Windows10` (taskbar,
search, ads, classic menu) and `06-Debloat-Privacy` sit alongside these;
together they're the full new-PC finish.

## What's here

| Script | What it does | Needs |
| --- | --- | --- |
| `Set-DesktopExperience.ps1` | Dark/light theme, classic desktop icons, icon size, Explorer view (extensions, hidden files, This PC, compact), Quick Access pins, tips/suggestions off. `-All` for the sensible default. | user |
| `New-DesktopShortcuts.ps1` | Standard shortcuts from a JSON manifest (`Config\desktop-shortcuts.json`, format in `shortcuts-EXAMPLE.json`) — apps, shares, web portals, the toolkit — with `.ico` icons and an optional run-as-admin flag. To this user's desktop or the Public desktop. | user (admin for `-Scope AllUsers`) |
| `Set-Branding.ps1` | Company wallpaper + lock screen for every user (enforced, PersonalizationCSP — works on Pro), images copied locally first; support phone/hours/URL/logo in Settings > About. | admin |
| `Set-StartTaskbarLayout.ps1` | Pinned Start and taskbar apps. Honest per OS: Win11 new users via `LayoutModification.json`, existing users only via the (locking) `ConfigureStartPins` policy; taskbar via layout XML on both. `-ExportCurrent` captures a hand-built reference. | admin |
| `Add-ContextMenuEntries.ps1` | "Open PowerShell here (Admin)", "Copy path", "Open with Notepad", opt-in "Take ownership". Own registry keys, so `-Remove` only ever touches ours. | user (admin for `-AllUsers`) |
| `Set-RegionalSettings.ps1` | Belgium-ready defaults: nl-BE format, Belgian (Period) keyboard, Brussels time zone, home location Belgium, dd/MM/yyyy, week starts Monday. `-CopyToSystem` for welcome screen + new users. Own JSON snapshot for rollback. | user (admin for `-CopyToSystem`) |
| `Set-PowerAndLock.ps1` | Screen-off/sleep timers, lock after N idle minutes, lid/power-button actions, Fast Startup and hibernation. `-Workstation` / `-Laptop` presets. Power scheme exported before changes. | admin |

## A new PC, start to finish

```powershell
# as admin, once per machine
..\04-PC-Provisioning\Initialize-NewPC.ps1 ...        # name, software, updates
..\04-PC-Provisioning\Join-Domain.ps1 ...
.\Set-Branding.ps1 -WallpaperPath \\fs01\IT\branding\wallpaper.jpg -SupportPhone "03 123 45 67" -SupportURL https://helpdesk
.\Set-PowerAndLock.ps1 -Workstation                    # or -Laptop
.\Set-StartTaskbarLayout.ps1 -TaskbarPins '%ProgramFiles%\Microsoft Office\root\Office16\OUTLOOK.EXE', ...
.\Set-RegionalSettings.ps1 -CopyToSystem

# as the user (or in their first-logon script)
..\02-Windows11\Set-Win11Baseline.ps1                  # taskbar, classic menu, search/ads off
.\Set-DesktopExperience.ps1 -All -QuickAccessPins '\\fs01\Shared'
.\New-DesktopShortcuts.ps1 -ManifestPath \\fs01\IT\desktop-shortcuts.json
.\Add-ContextMenuEntries.ps1 -All
```

Every one of those takes `-WhatIf` — do a dry run the first time on a
machine you can afford to get wrong.

## What Windows won't let a script do (so this section doesn't pretend)

- **Default apps** (browser, PDF, mail) for an *existing* user — Windows 10/11
  deliberately block scripted changes. For new users:
  `Dism /Online /Import-DefaultAppAssociations:file.xml` with an XML exported
  from a reference machine, or the equivalent Intune/GPO setting.
- **Start pins for existing Win11 users** without locking them — the only
  mechanism is the policy, and the policy locks. `Set-StartTaskbarLayout.ps1`
  says so and makes it opt-in.
- **Lock screen on Windows 10/11 Pro via Group Policy** — Enterprise/Education
  only. That's why `Set-Branding.ps1` uses the PersonalizationCSP keys instead.

## Rollback

Each script keeps its own backup set under `C:\Sysadmin-Toolkit\Backups\`
(`<Label>_<key>_<stamp>.reg`, plus a `.pow` for power, a `.json` snapshot
for regional). `-Rollback` restores the newest complete set for that script
only — the others are untouched.
