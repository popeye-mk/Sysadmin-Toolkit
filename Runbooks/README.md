# Runbooks

Step-by-step "what to do when" guides for the incidents you'll actually get.
Each one points at the exact kit script to run at each step, so under
pressure you follow the list instead of remembering. They assume the kit is
at `C:\Sysadmin-Toolkit` — adjust paths if yours lives elsewhere.

| Runbook | When |
| --- | --- |
| [RB-01 User cannot log in](RB-01-User-Cannot-Log-In.md) | "My password doesn't work" / "it says account locked" |
| [RB-02 PC slow or won't boot](RB-02-PC-Slow-Or-Wont-Boot.md) | Slow, freezing, blue screen, stuck at boot |
| [RB-03 Network or server unreachable](RB-03-Network-Unreachable.md) | "No internet", "can't open the share", "the server is down" |
| [RB-04 Disk full on a server](RB-04-Disk-Full-On-Server.md) | Low disk alert, services failing, backups failing |
| [RB-05 Printer problems](RB-05-Printer-Problems.md) | Won't print, stuck queue, "printer offline" |
| [RB-06 Suspected malware or phishing](RB-06-Suspected-Malware.md) | Weird pop-ups, ransom note, "I clicked a link" |
| [RB-07 New employee / leaver](RB-07-Joiner-Leaver.md) | Someone starts or leaves |
| [RB-08 Service down on a server](RB-08-Service-Down.md) | Application stopped, users can't reach a system |
| [RB-09 AD or Group Policy misbehaving](RB-09-AD-GPO-Issues.md) | Policies not applying, replication errors, logon script problems |

## The universal first three minutes

Before any runbook, always:

1. **Scope it.** One user or many? One PC or many? Since when? What changed?
   (Ask — most incidents are explained by "what changed".)
2. **Write the ticket note as you go** — use the template below. Future-you,
   and whoever takes over at shift end, will thank you.
3. **Don't reboot the server as step one.** Workstations: fine. Servers:
   only after you've looked and noted what you saw — a reboot destroys the
   evidence you'd need if it comes back.

## Ticket note template

```
Reported by / when :
Symptom (their words):
Scope              : 1 user / N users / 1 PC / site / everyone
Since              :
What changed       :
Checked            :
  -
  -
Fix applied        :
Result             :
Follow-up needed   :
```

## Escalation

If you're past 30 minutes with no progress on something affecting more than
one person, or anything on a server you're unsure about: escalate. Saying
"I've checked X, Y, Z and I'm stuck at W" early is what a senior admin wants
to hear — not a call two hours later.
