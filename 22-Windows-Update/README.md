# 22 — Windows Update: pilot ring + hold

Microsoft's monthly updates are usually fine — and sometimes they break
printing, VPNs or a line-of-business app. On a small fleet the safe routine is
a **pilot ring**:

| Ring | What Windows does | Set with |
|---|---|---|
| **Pilot** (1–2 test PCs) | installs Microsoft's updates as soon as they come | `Set-UpdatePolicy.ps1 -Mode Pilot` |
| **Hold** (every other PC) | downloads updates but installs **nothing** on its own | `Set-UpdatePolicy.ps1 -Mode Hold` |

When the pilots have run the new updates for a few days without trouble, you
approve them and install them on the held PCs (`Install-ApprovedUpdates.ps1`,
or one click in OpsBoard → **Updates**). A bad update you **decline** is hidden
on the held PCs, so nobody installs it from Settings by accident.

**Hold also locks Settings > Windows Update** (policy *Remove access to use
all Windows Update features*), so nobody installs a held update from there;
OpsBoard / `Install-ApprovedUpdates.ps1` still install approved ones.

Note: installs made through the update engine (OpsBoard, this toolkit) may not
appear in *Settings > Update history*, and the Settings list can stay behind
until Windows checks again. `Get-UpdateStatus.ps1` asks the engine itself.

Both rings also: stay on the current Windows version (no feature upgrade until
you decide), never restart while someone is logged on, and let Defender update
its signatures itself every 4 hours — antivirus updates are never held.

| Script | Does | Changes the PC? |
|---|---|---|
| `Get-UpdateStatus.ps1` | Updates waiting (security flagged), last real patch, hold state. `-Json` for OpsBoard. Saves `Reports\update-status.json` for the Zabbix metrics. | No |
| `Set-UpdatePolicy.ps1 -Mode Hold\|Pilot\|Default` | The ring settings above. `Default` removes only what this script set. `-WhatIf` shows what it would do. | Yes (policy registry + a daily scan task) |
| `Install-ApprovedUpdates.ps1 -UpdateId … [-Hide …] [-IncludeDefinitions]` | Installs exactly the approved updates, hides declined ones. Never restarts. | Yes |

Notes

- Windows refuses to run the update engine from a remote session, so a status
  check over PowerShell Remoting (OpsBoard) starts itself as a short SYSTEM task
  on the PC. An install ALWAYS runs as a SYSTEM task in the background (also
  locally; `-NoTask` to watch it in your window) and returns at once; its
  result lands in `Reports\update-install-last.json`, and the next
  `Get-UpdateStatus.ps1` reports it.
- **Windows Home ignores update policies** — the hold is not active there (the
  script warns). On a **domain**, a Windows Update GPO overrides these local
  settings; use the GPO instead.
- Updates are identified by their Windows Update ID (a GUID), the same on every
  PC — that's what an approval refers to. KB numbers are shown for people.
