# RB-01 — User cannot log in

**Symptoms:** "wrong password", "account locked", "the trust relationship
failed", spinning at logon, or logs in but everything's broken.

## 1. Narrow it down (1 minute)

- Can they log in on **another PC**? → yes: the PC is the problem (go to 4).
  no: the account is (go to 2).
- Exact error text. "Locked out" and "incorrect password" are different
  problems. "Trust relationship between this workstation and the primary
  domain failed" → go to 5.

## 2. Account state (AD)

```powershell
Get-ADUser jpeeters -Properties LockedOut, Enabled, PasswordExpired, PasswordLastSet, AccountExpirationDate, BadLogonCount, LastBadPasswordAttempt |
    Select-Object Name, LockedOut, Enabled, PasswordExpired, PasswordLastSet, AccountExpirationDate, BadLogonCount, LastBadPasswordAttempt
```

- **LockedOut = True** → `Unlock-ADAccount jpeeters`. Then find *why*: a
  saved old password somewhere (phone mail app, mapped drive, scheduled
  task, RDP session on another PC) keeps re-locking it. Ask what device
  they changed the password on and what else has it saved.
- **Enabled = False** → someone disabled it. Check with your senior before
  re-enabling — offboarding disables on purpose.
- **PasswordExpired = True** → reset it (below).
- **AccountExpirationDate in the past** → temp/contractor account expired;
  extend only with manager approval.

Password reset, forcing change at next logon:

```powershell
Set-ADAccountPassword jpeeters -Reset -NewPassword (Read-Host -AsSecureString "Temp password")
Set-ADUser jpeeters -ChangePasswordAtLogon $true
```

Weekly view of who's about to expire (prevents half of these tickets):
`01-Users\Get-ADPasswordExpiry.ps1`

## 3. Cloud / Entra sign-in problems

"Your account has been locked" in Microsoft 365, MFA loops, Conditional
Access blocks:

- Entra admin center → Users → the user → **Sign-in logs**. The failure
  reason is written there in plain words (blocked by CA policy X, MFA
  required, risky sign-in).
- Blocked sign-in? Check `AccountEnabled` — an offboard may have run.
- If Entra Connect sync is the issue (password changed on-prem, not
  working in the cloud yet): sync runs every 30 min; from the Entra Connect
  server `Start-ADSyncSyncCycle -PolicyType Delta` forces it.

## 4. The PC is the problem

- Try logging in with **a different account** on that PC. Works → the
  user's profile is damaged. Doesn't → PC/domain link.
- Profile damaged: log in as admin, rename `C:\Users\<name>` to
  `<name>.old`, remove the profile entry under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` for that
  SID, log the user back in (fresh profile), copy their data back from
  `.old`.
- Quick health look while you're there: `07-Reporting-Health\Invoke-HealthCheck.ps1`

## 5. Trust relationship failed

The PC's machine-account password is out of sync with AD. Fix from the PC
as a local admin, without leaving the domain:

```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential CONTOSO\admin)
```

Still failing → `04-PC-Provisioning\Join-Domain.ps1` to re-join (after
removing the computer object or resetting it in AD).

## 6. Note + close

Record cause, not just "reset password". If locks keep recurring on the
same user, the cause is a stale credential on a device — find it.
