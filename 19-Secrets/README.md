# 19 — Secrets (passwords & tokens, kept safe)

Some scripts need a secret to do their job — a **Zabbix API token**, a **Teams
webhook URL**, an **email (SMTP) password**. You don't want those sitting in
plain text inside a script or a config file where anyone can read them.

This section stores each secret **encrypted**, and hands it back to a script
when it's needed. You save a secret **once**, under a **name**; from then on
scripts look it up by that name. You never type the secret again.

There is **one script** here: `Manage-ToolkitSecret.ps1`. It does four things.

---

## The four commands

Run these from `C:\Sysadmin-Toolkit`.

| You want to… | Command |
| --- | --- |
| **Save** a secret (asks you for the value, hidden) | `.\19-Secrets\Manage-ToolkitSecret.ps1 -Set <Name>` |
| **See** which secrets are stored (names only, never values) | `.\19-Secrets\Manage-ToolkitSecret.ps1 -List` |
| **Read** one back (scripts do this for you) | `.\19-Secrets\Manage-ToolkitSecret.ps1 -Get <Name>` |
| **Delete** one | `.\19-Secrets\Manage-ToolkitSecret.ps1 -Remove <Name>` |

You'll mostly use `-Set` (to save) and `-List` (to check). Scripts use `-Get`
behind the scenes — you rarely run it yourself.

---

## Walkthrough: save your Zabbix API token

This is the exact thing to do so the Zabbix scripts stop needing `-ApiToken`
every time.

**Step 1 — make the token in Zabbix.**
In the Zabbix web page: **Users → API tokens → Create token**. Give it a name,
assign it to your admin user, click **Add**, and **copy the token string**
(Zabbix shows it once).

**Step 2 — save it here, under the exact name `ZabbixApiToken`.**
On the machine you run the Zabbix scripts from:

```powershell
cd C:\Sysadmin-Toolkit
.\19-Secrets\Manage-ToolkitSecret.ps1 -Set ZabbixApiToken
```

It asks: `Value:` — **paste the token and press Enter.** The typing is hidden
(you won't see it) — that's normal. You'll get a green line saying it was saved.

> ⚠️ The name must be **exactly** `ZabbixApiToken` — that's the name the Zabbix
> scripts look for. Spelling it differently means they won't find it.

**Step 3 — check it's there.**

```powershell
.\19-Secrets\Manage-ToolkitSecret.ps1 -List
```

You should see `ZabbixApiToken` in the list (just the name — the value stays
secret).

**Done.** Now the Zabbix scripts find the token on their own — no `-ApiToken`:

```powershell
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix
```

---

## The names the toolkit looks for

When a script "finds a secret automatically", it's looking for one of these
exact names. Save yours under the matching name:

| Save it as this name | Used by |
| --- | --- |
| `ZabbixApiToken` | The Zabbix button creator and the fleet device list |
| `TeamsWebhook` | The alerting script (`13-Alerting\Send-ToolkitAlert.ps1`) |
| `SmtpPassword` | Email alerts / reports that send mail |

(You can save secrets under any name you like for your own use — these three
are just the ones scripts auto-detect.)

---

## Where it's stored, and the one catch

- **Where:** one file, `C:\Sysadmin-Toolkit\secrets.json`. The values in it are
  **encrypted** (Windows DPAPI). Even if someone copies that file, they can't
  read your secrets. It's in the kit's `.gitignore` — don't commit it anyway.
- **The one catch (DPAPI):** a secret is encrypted for **your** Windows account
  on **this** machine. So it only decrypts when *you* run a script on *this*
  machine. It will **not** decrypt for a different user or on a different PC —
  and a **Scheduled Task running as SYSTEM** counts as a different user, so it
  can't read a secret you saved as yourself.
  - If you need a scheduled task (as SYSTEM) to use a secret, save it *while
    running as that account* once: open a SYSTEM PowerShell with
    `psexec -s -i powershell.exe`, then run the `-Set` command there.
  - For everything you run by hand, you don't have to worry about this.

---

## Example: use a saved secret in another script

You normally don't do this by hand (scripts do it), but this is what's happening
under the hood — read a secret into a variable and pass it on:

```powershell
$webhook = .\19-Secrets\Manage-ToolkitSecret.ps1 -Get TeamsWebhook
.\13-Alerting\Send-ToolkitAlert.ps1 -Message "Backup done" -Level OK -TeamsWebhookUrl $webhook
```
