# 13 — Alerting

One place alert-sending lives, instead of every script rolling its own Teams
or e-mail logic. Self-contained — copy just this one file anywhere.

## What's here

| File | What it is |
| --- | --- |
| `Send-ToolkitAlert.ps1` | Sends one alert via a Teams Incoming Webhook, e-mail, or both. With neither configured, it just prints the message — safe to call from anywhere without failing. |

## Usage

Standalone, ad hoc:

```powershell
.\Send-ToolkitAlert.ps1 -Message "Disk on SRV01 is below 10%" -Level WARN -TeamsWebhookUrl $webhook
```

From another script (no import needed — it's called by path, not a module):

```powershell
& "C:\Sysadmin-Toolkit\13-Alerting\Send-ToolkitAlert.ps1" `
    -Message "AD health: 2 replication failures" -Level ERROR -TeamsWebhookUrl $webhook
```

Getting a Teams webhook URL: in the target channel, **⋯ → Connectors →
Incoming Webhook → Configure**, copy the URL it gives you. Nothing else in
this kit is wired to call this script automatically yet — that's on the
roadmap (see `..\ROADMAP.md`) so every health/report script can alert
through the same helper instead of each having its own e-mail plumbing.

## Note

Teams posts use the classic MessageCard format via a plain webhook POST — no
extra module required. If your tenant later requires Adaptive Cards instead
(Microsoft has been migrating Incoming Webhook connectors), the `$body` JSON
in the script is the only thing that needs to change; everything calling
this script keeps working unmodified.
