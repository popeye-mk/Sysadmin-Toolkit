# 09 — Entra ID + Intune (the cloud side)

This is the **cloud** version of section 01. Where `01-Users` talks to your
on-prem Active Directory, this talks to **Entra ID** (formerly Azure AD) and
**Intune** in the Microsoft cloud, through an API called **Microsoft Graph**.
Use it for a cloud-only tenant, or for the cloud steps (licences, Intune groups,
device policy) in a hybrid tenant.

## A few words you'll meet (plain version)

- **Microsoft Graph** — the API these scripts call to read/change your tenant.
- **Scopes / consent** — the permissions a script needs (e.g. "read policies").
  The **first time** you run a script it opens a browser sign-in and asks an
  admin to **consent** (approve) those permissions. After that it's remembered.
- **Usage location** — a two-letter country code (e.g. `BE`) that Entra
  *requires* before it will assign a licence. You set it when creating the user.
- **Licence SKU** — the id of a licence plan (e.g. Business Premium). You pass
  its id to assign it. How to find yours is shown below.
- **CSP** — "Configuration Service Provider", the official Windows setting an
  Intune policy uses (as opposed to a script that just runs once).

## Set-up (once, on the machine that runs these)

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

The first run of any script prompts you to sign in and approve its permissions.
You need an admin role for that (User Administrator, Intune Administrator, or
Global Administrator, depending on the script — each one's `.NOTES` says which).

## The scripts

| Script | What it does | Role needed |
| --- | --- | --- |
| `_GraphCommon.psm1` | Shared helpers, imported by the others. Not run directly. | — |
| `New-EntraUserOnboard.ps1` | Create a cloud user (or configure a synced one with `-ExistingUser`): temp password, usage location, licences, groups, manager. | User + License Admin |
| `Disable-EntraUserOffboard.ps1` | Block sign-in, revoke sessions, save-then-remove groups, remove licences, optionally retire Intune devices. Disables, never deletes. | User Admin (+ Intune) |
| `Get-IntuneDeviceCompliance.ps1` | Report every Intune device's compliance/encryption/staleness. Read-only, HTML + CSV. | Intune (read) |
| `Deploy-ScriptViaIntune.ps1` | Push any `.ps1` from this kit out to a group as an Intune script. | Intune Admin |
| `New-IntuneConfigProfile-Win11Baseline.ps1` | The Win11 AI/telemetry baseline as a real enforced Intune policy. | Intune Admin |

---

## Onboard a cloud user (worked example)

The user's sign-in name (`-UserPrincipalName`, the full `name@domain`) is the
only required field.

```powershell
# Preview:
.\09-Entra-Intune\New-EntraUserOnboard.ps1 -GivenName Anna -Surname Jansen `
    -UserPrincipalName anna.jansen@contoso.com -WhatIf

# For real, with country + department + a licence:
.\09-Entra-Intune\New-EntraUserOnboard.ps1 -GivenName Anna -Surname Jansen `
    -UserPrincipalName anna.jansen@contoso.com -UsageLocation BE -Department Sales `
    -LicenseSkuIds "<sku-id>"
```

**First run:** a browser opens, you sign in as an admin and click **Accept** on
the permissions. Then it creates the user and prints the temporary password once.

**Finding a licence SKU id** (so you know what to put in `-LicenseSkuIds`):

```powershell
Connect-MgGraph -Scopes "Organization.Read.All"
Get-MgSubscribedSku | Select-Object SkuPartNumber, SkuId
```

That lists your tenant's licence plans and their ids — copy the `SkuId` of the
one you want (e.g. the row whose `SkuPartNumber` is `SPB` = Business Premium).

---

## Offboard a cloud user

```powershell
.\09-Entra-Intune\Disable-EntraUserOffboard.ps1 -UserPrincipalName anna.jansen@contoso.com -WhatIf
.\09-Entra-Intune\Disable-EntraUserOffboard.ps1 -UserPrincipalName anna.jansen@contoso.com
```

Blocks sign-in, kills active sessions, saves then removes group/licence
assignments, and can retire their Intune devices. Nothing is deleted.

---

## Baseline: script or policy?

Not every Win11 setting has an official CSP. `New-IntuneConfigProfile-Win11Baseline.ps1`
covers the three that do (Copilot off, telemetry level, tailored experiences) as
an **enforced policy** — better than a script because Intune keeps re-applying it.
Everything else (taskbar, Explorer cosmetics, context menu, Recall) stays a
script, pushed with `Deploy-ScriptViaIntune.ps1`. Use both together.

## Timing (don't expect it to be instant)

Intune scripts and policies apply on Intune's own schedule — usually within about
an hour of assignment, then re-checked roughly daily. For an urgent one-off on a
specific machine, PowerShell remoting or the fleet runner is faster.
