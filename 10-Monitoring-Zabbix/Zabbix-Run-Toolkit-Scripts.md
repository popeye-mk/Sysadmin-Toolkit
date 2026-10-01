# Running toolkit scripts from Zabbix — step by step

**Who this is for:** someone who knows Zabbix as a *monitoring* tool and wants to
also *run things* from it, but hasn't set that up before. Every step says what to
click, what each setting means, and what you should see. No prior experience with
Zabbix "global scripts" assumed.

Everything here was done for real on the lab (Zabbix 7.0 on Ubuntu, a Windows
host with Zabbix Agent 2) — the screenshots-in-words match what you'll see.

---

## 1. The idea, in plain words

Normally Zabbix **watches** your machines: CPU, disk, services, up/down. It
doesn't *do* anything to them.

This turns Zabbix into a place you can also **act** from: you click a computer in
the Zabbix web page, pick an action like "Local admin audit", and Zabbix tells
that computer's **agent** to run a toolkit script — then shows you the result
right there in the browser. Think of it as adding a row of **buttons** to each
computer in your monitoring.

How the pieces fit:

```
  You (browser)  ->  Zabbix server (Ubuntu)  ->  Zabbix Agent 2 (on the Windows PC)  ->  PowerShell runs the kit script
        ^                                                                                          |
        +---------------------------- result text comes back the same way <----------------------+
```

A few words you'll meet:

- **Zabbix server** — the central bit (on your Ubuntu VM). It's what the web page
  talks to.
- **Zabbix agent** — the small program installed on each Windows computer that
  Zabbix watches. It's what actually runs the command on that computer.
- **Host** — one monitored computer in Zabbix (e.g. `dc01`).
- **Host group** — a bag of hosts. You can make one per customer, so a button can
  be offered to *only* that customer's machines.
- **Global script / manual host action** — the Zabbix name for a **button** you
  add to a host's menu. That's what we're creating.

---

## 2. Two kinds of toolkit script — this decides how you expose it

| Kind of script | How to expose it | Why |
| --- | --- | --- |
| **Fast, read-only** — audits, checks, "who is local admin", "is a reboot pending", disk space | a button that **shows the answer** in a result window | it finishes in a second or two; the agent hands the output straight back to the browser |
| **Slow, or changes the machine** — branding, provisioning, desktop setup | **don't** make it a wait-for-it button — launch it detached, or use GPO/Intune | the agent kills a command that runs too long, and you don't want to sit staring at the browser while a machine reconfigures |

**Rule of thumb: read → show it. change → launch it (or don't use a button at
all — use the fleet runner / GPO).**

The rest of this guide is mostly about the first kind (the buttons), because
that's what you'll use day to day.

---

## 3. One-time setup on each Windows computer

Out of the box, the Zabbix agent **refuses** to run commands sent from the
server (a sensible safety default). You turn it on once per computer. Do this on
the **Windows machine**, in a PowerShell window opened **as administrator**.

### 3a. Find the agent's config file

```powershell
(Get-CimInstance Win32_Service -Filter "Name='Zabbix Agent 2'").PathName
```

You'll see a path ending in `zabbix_agent2.conf`. It's almost always:
`C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf`.

*(If that returns nothing, the agent isn't Zabbix Agent 2 or isn't installed —
sort that first.)*

### 3b. Allow command execution and give commands enough time

Two settings go into that config file:

- `AllowKey=system.run[*]` — lets the server ask the agent to run commands.
- `Timeout=30` — how many seconds the agent waits for a command before killing
  it (default is only **3**, which is too short for some checks; 30 is the max).

Add both and restart the agent (still in the admin PowerShell):

```powershell
Add-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' "`nAllowKey=system.run[*]"
Add-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' "`nTimeout=30"
Restart-Service 'Zabbix Agent 2'
```

> ⚠️ **Security note.** `system.run[*]` means "the server may run *any* command
> on this machine." That's fine for a **lab**. For a **real/production** setup,
> don't leave it wide open — use the narrow, toolkit-only allow-list in the last
> section of this guide, and remove this line.

### 3c. Check it worked

```powershell
Get-Content 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf' | Select-String 'AllowKey|Timeout'
Get-Service 'Zabbix Agent 2'
```

You want to see your `AllowKey=system.run[*]` and `Timeout=30` lines, and the
service **Running**.

---

## 4. One-time setup on the Zabbix server (the timeout, again)

The **server** also has its own `Timeout` (again default 3s) — it's how long the
*server* waits for the *agent* to answer. If you skip this, a slow button fails
with:

```
Execute failed: command execution failed: context deadline exceeded
```

even though you already raised the agent's timeout. So raise both, to the same
value. On the **Ubuntu Zabbix server**, in a terminal:

```bash
sudo sed -i -E 's/^#?\s*Timeout=.*/Timeout=30/' /etc/zabbix/zabbix_server.conf
grep -i '^Timeout' /etc/zabbix/zabbix_server.conf     # should print: Timeout=30
sudo systemctl restart zabbix-server
```

The `grep` line printing `Timeout=30` is your confirmation. If a script *still*
can't finish inside 30 seconds, it doesn't belong on a wait-for-it button —
launch it detached (pattern B below) or push it via GPO/Intune.

---

## 5. Create the buttons

You have two ways. **Way A** (the creator) makes all the standard buttons at once
and is what you'll normally use. **Way B** (by hand) is worth doing once so you
understand what the creator is doing for you.

### Way A — the creator (fast, recommended)

From `C:\Sysadmin-Toolkit`, in PowerShell:

```powershell
# 1) Get an API token in the Zabbix web UI: Users -> API tokens -> Create token,
#    assign it to your admin user, click Add, and COPY the string (shown once).

# 2) Dry run first — this creates NOTHING, it just shows what it would do:
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix -ApiToken <token> -WhatIf

# 3) For real:
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ZabbixUrl http://192.168.122.152/zabbix -ApiToken <token>
```

You'll see `Connected to Zabbix 7.0.x` then a list of `Created: Toolkit: …`
lines. That's the 10 standard read-only buttons, made over the API in one go.

Useful variants:

```powershell
# Only offer them on one customer's machines (a host group):
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -HostGroup 'Contoso'

# Expose EVERY read-only script in a whole section at once (folder mode):
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Folder "07-Reporting-Health"

# Remove all the Toolkit buttons again:
.\10-Monitoring-Zabbix\New-ZabbixToolkitScripts.ps1 -ApiToken <token> -Remove
```

It's **idempotent** — run it as often as you like; existing buttons get updated,
new ones get created, nothing is duplicated. The token can also be stored once
(`19-Secrets\Manage-ToolkitSecret.ps1 -Set ZabbixApiToken`) and the URL can come
from `Config` (`Monitoring.ZabbixUrl`), so later you can just run it with no
arguments.

### Way B — add one button by hand (to learn what a button *is*)

In the Zabbix web UI:

1. Go to **Alerts → Scripts**. Click **Create script** (top-right).
2. Fill the form:
   - **Name:** `Toolkit: Local admin audit`
     *(Start every one with `Toolkit: ` so they group together in the menu.)*
   - **Scope:** `Manual host action`
     *(This is the setting that makes it appear as a clickable button on a host.
     The other scopes are for alerting actions, not buttons.)*
   - **Type:** `Script`
   - **Execute on:** `Zabbix agent`
     *(Run it on the target computer's agent — i.e. on the machine you clicked,
     not on the Zabbix server.)*
   - **Commands:** the PowerShell line (see §6). For example:
     `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Sysadmin-Toolkit\17-Security-Audit\Get-LocalAdminAudit.ps1"`
   - **Host group:** leave **blank** to offer it on every host, **or** pick one
     group to limit it to that customer's machines.
   - Go to the **Permissions** tab if you want to restrict *which users* can run
     it (by user group).
3. Click **Add**.

That single form is exactly one "button". The creator in Way A just fills this
form for you, ten times, over the API.

---

## 6. Run a button and read the result

1. In the web UI go to **Monitoring → Hosts** (or **Data collection → Hosts**).
2. **Click the host's name** (e.g. `dc01`). A little menu pops up.
3. Under **Scripts**, click your entry (e.g. **Toolkit: Local admin audit**).
4. A **result window** opens showing the script's output — the same text you'd
   see if you ran it in PowerShell on that machine.

If instead you get a red error, jump to **§9 Troubleshooting** — the message
tells you exactly which thing to fix.

---

## 7. The command line, explained

Every button runs a PowerShell command. The safe pattern is always: full path to
the script, don't load the user profile, and bypass the execution policy.

**A) Read-only check — show the answer** (the common case):

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Sysadmin-Toolkit\17-Security-Audit\Get-LocalAdminAudit.ps1"
```

- `-NoProfile` — don't run the user's PowerShell startup script (faster, cleaner).
- `-ExecutionPolicy Bypass` — allow this one run even if the machine normally
  blocks unsigned scripts. **Without this, many machines answer "cannot be
  loaded" and the button fails.**
- `-File "…"` — the script to run, with its **full path**.

The script's console output comes back into the Zabbix result window. Good
first buttons: `17-Security-Audit\Get-LocalAdminAudit.ps1`,
`03-Windows10\Test-Win11Readiness.ps1`, `07-Reporting-Health\Get-PCInventory.ps1`.

**B) Something that changes the machine — launch it and return immediately:**

```
powershell.exe -NoProfile -Command "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\Sysadmin-Toolkit\20-Desktop-Experience\Set-Branding.ps1'"
```

This says "successful" the moment it kicks off; the real work then runs in the
background on the machine. Use it for section 20, baselines, provisioning — and
add arguments by extending the `-ArgumentList` (e.g. `,'-Rollback'`).

> A script launched this way must be **non-interactive** — no "apply? [y/N]"
> prompt — or it hangs with nobody to answer. The toolkit's changing scripts take
> `-Force` (or the env var `SYSADMIN_TOOLKIT_FORCE=1`) to skip prompts; use that.

**C) With arguments** (either kind):

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Sysadmin-Toolkit\20-Desktop-Experience\Set-PowerAndLock.ps1" -Workstation -WhatIf
```

`-WhatIf` is a safe first click on any changing script — it shows what *would*
happen and changes nothing.

---

## 8. One button, right settings for many customers

Because every script reads its settings from
`C:\Sysadmin-Toolkit\Config\toolkit-settings.json` (and `Config\Branding\`), the
**same** button does the right thing on every machine — it brands with *that*
machine's Config, audits against *that* Config's expected admins, and so on. Put
the correct Config on each customer's machines (via the installer, GPO, or the
fleet runner), and one button set covers all of them.

To control **which customer sees which button**, use the **Host group** field
(§5): make a host group per customer, and scope a script to that group. Combine
with **user-group permissions** so each engineer only sees the buttons they
should, on only the hosts they manage.

---

## 9. Troubleshooting — what each error means

| You see… | What it means | Fix |
| --- | --- | --- |
| `Cannot execute script. … context deadline exceeded` | The command ran longer than the timeout and got killed. | Raise the timeout in **both** places — agent (§3b) *and* server (§4). If it still can't finish in 30s, it's not a button — launch it detached (§7 B). |
| `… cannot be loaded because running scripts is disabled` / `is not digitally signed` | The machine's execution policy blocked the script. | Make sure the command has `-ExecutionPolicy Bypass` (§7). |
| `Get value from agent failed` / `cannot connect` | The server can't reach the agent. | Agent service running? Firewall open on 10050? Host's agent interface correct in Zabbix? |
| `command execution … is not allowed` / nothing happens | The agent isn't allowed to run commands. | Add `AllowKey=system.run[*]` (lab) and restart the agent (§3). |
| The button isn't in the host's menu | Wrong scope, or scoped to a group this host isn't in. | The script's **Scope** must be **Manual host action**, and its **Host group** must be blank or a group that contains this host. |

---

## 10. Automatic remediation (optional, later)

Beyond manual buttons, Zabbix can run a script **automatically when a problem
fires**: **Alerts → Actions → Trigger actions**, add an *Operation* of type "Run
script" on the affected host. Example: a disk-full trigger runs an
`08-TechToolkit` cleanup; a stopped-service trigger runs a restart. Keep these to
**safe, idempotent** scripts, and always test the same script as a manual button
first.

---

## 11. Hardening for production (replace `system.run[*]`)

`system.run[*]` is convenient but broad — it lets the server run *anything*. When
this stops being a lab, replace it with a **toolkit-only allow-list** so the
agent will run **only** PowerShell against `C:\Sysadmin-Toolkit`, nothing else.

Simplest version — in `zabbix_agent2.conf`, instead of the wide `AllowKey`:

```
AllowKey=system.run[powershell*C:\Sysadmin-Toolkit\*]
DenyKey=system.run[*]
```

(First match wins, so the specific `AllowKey` goes **before** the broad
`DenyKey`.)

Stricter version — a named allow-list via `UserParameter`, so the agent exposes
only toolkit actions and nothing resembling a free-form command:

```
UserParameter=sysadmintoolkit.run[*],powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Sysadmin-Toolkit\$1"
```

Then a Zabbix script's key becomes
`sysadmintoolkit.run[17-Security-Audit\Get-LocalAdminAudit.ps1]` — the agent will
only ever run scripts under `C:\Sysadmin-Toolkit`. Combine with per-host-group
script scope and per-user-group permissions so each engineer sees only the right
buttons, on only the right hosts. (A ready-to-import set of these definitions is
on the roadmap — NEXT.md 0.2.)

---

Part of the Sysadmin-Toolkit family. Author: Stojan Tomeski.
