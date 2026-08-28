# Build out the vulnerable CyberHawks AD range

## Context

`CLAUDE.md`'s "Vulnerable AD range design" section is a fully-specified but
entirely unimplemented design: dc1/dc2/ca/sql1/sql2/web/workstation exist and
are domain-joined, but none of the intentional misconfigurations, starter
accounts, delegation setups, ADCS ESC-vulnerable templates, the CyberHawks
Employee Portal website, or the SMB file dump exist yet. WSL2 + Ansible (Kali)
was just confirmed working, closing the last blocker. The user has asked to
write the full set of Ansible roles/playbooks, run them against the live
range, and verify every finding actually landed — i.e. finish the entire
design in one continuous effort.

This is the largest and highest-blast-radius task this repo has taken on: it
touches ACLs, delegation, GPOs, and a live Enterprise CA across 7 domain
VMs. The mitigating factor is that a `domain-configured` Proxmox snapshot
already exists on all 7 VMs as a clean rollback point, and additional
snapshots are taken before the riskiest phases (see Safety net below).

A research pass against current ADCS documentation (Certipy wiki, SpecterOps)
found that roughly half of ESC1–17 aren't actually certificate-template
misconfigurations at all — details and the resulting per-ESC treatment are
in Phase H below.

## Repo/tooling decisions

- **Ansible collections** (installed in Kali WSL): `ansible.windows`,
  `community.windows`, `microsoft.ad`. These cover users/groups/computers/OUs
  reasonably, but NOT exotic AD primitives (ACE grants for specific rights,
  RBCD/shadow-cred attribute writes, ADCS template objects, LAPS, GPP). For
  those, roles push a templated `.ps1` to a DC (dc1) or the relevant member
  server and run it once via `ansible.windows.win_shell`/`win_powershell` —
  this also avoids 1000+ separate WinRM round-trips for the user-pool role.
- **Verification tooling** installed on the Kali control node itself
  (pipx/apt): `impacket-scripts`, `netexec` (crackmapexec successor),
  `certipy-ad`. Used in the final verification phase to confirm findings
  from an actual attacker's-eye view, not just "the AD attribute is set."
- **1000-user pool**: source usernames from the `jsmith.txt` list referenced
  in CLAUDE.md (fetched once, saved as a static data file in the repo).
  Passwords generated once and written to a **gitignored** credentials/
  assignment file (matches the existing convention for roster CSVs and
  `vault.yml`) so re-runs are idempotent and the placeholder→real-username
  mapping (writedacl target, forcechangepw target, etc.) stays fixed and
  documented for later reference.
- **LAPS**: switched to **native Windows LAPS** (checked live — both `ca`
  (Server 2019) and `sql2` (Server 2022) already have the in-box `LAPS`
  PowerShell module and `Get-LapsADPassword`, so no download/install step is
  needed at all, and there's no dependency on Microsoft's legacy LAPS
  download page possibly no longer existing in 2026). Uses
  `msLAPS-Password`, not `ms-Mcs-AdmPwd`.
- **Website**: ASP.NET Web Forms (loose `.aspx` files, IIS compiles on first
  request — no build/publish pipeline needed), so `Web.config` naturally
  holds a real `<connectionStrings>` entry per the design's requirement that
  `Web.config.bak` leak a real SQL connection string.
- **Repo layout**: one Ansible role per finding-cluster under
  `ansible/roles/`, one top-level playbook (`ansible/playbooks/vulnerable-range.yml`)
  that applies them in dependency order via `import_role`/tags, so any phase
  can be re-run individually (`--tags acls`, `--tags adcs`, etc.) without
  re-running the whole thing.

## Safety net

- Before Phase D (first live AD mutation): fresh Proxmox snapshot
  `pre-vuln-build` on dc1/dc2/ca/sql1/sql2/web/workstation (all 7), in
  addition to the existing `domain-configured` one — gives a same-day
  rollback point specific to this build.
- Before Phase H (ADCS): an additional snapshot of `ca` alone
  (`pre-adcs-templates`) immediately before touching the CA, since a bad CA
  registry flag (ESC6/ESC11/ESC16) needs a `certsvc` restart and is the one
  step in this whole build that could plausibly wedge a live service.
- Every role's PowerShell is check-before-act (idempotent) so a partial
  failure can be safely re-run rather than needing a hand rollback.

## Execution cadence / usage checks

The user asked to check their token usage between phases and stop rather
than start a phase that doesn't fit within remaining usage. Important
limitation to flag up front: **there is no tool that reports the user's
Claude account usage/rate-limit quota** — that's not exposed to Claude. What
*is* visible and used as the throttle instead: Claude's own remaining
context-window budget for the session, plus how much a phase actually cost
once it's done. Between every phase, report that remaining-budget figure and
an estimate of the next phase's cost, and stop and ask before starting a
phase that risks running the session out, rather than guessing silently.
This is a proxy for "usage," not a direct read of it.

## Phases

Each phase = one Ansible role (or a couple of tightly-coupled roles), run via
`ansible-playbook ansible/playbooks/vulnerable-range.yml --tags <phase>` from
Kali WSL, then verified before moving on.

**A. Control-node prep** — install the 3 collections + pipx tools above;
retrieve the real shared Windows admin password (`qm cloudinit dump <vmid>
user` on the Proxmox host) and encrypt it into `group_vars/windows_vms/vault.yml`
(currently only `.example` exists); fetch the jsmith.txt username list.

**B. Foundational AD objects** (role `ad_base_accounts`) — user1/computer1
(password `password`); bulk-create the 1000-account pool in one remote
PowerShell loop with generated 14-char passwords (excluding the literal
string `password`); assign the pool placeholders (writedacl/genericwrite/
forcechangepw/writeowner targets, netlogon-creds account, description-field
account, ASREPRoast account, 10 weak-cred accounts, SMB-share-creds account)
to specific pool usernames, recorded in the gitignored assignment file;
create computer2–5 as placeholder computer objects; add static A/PTR DNS
records for computer1–5 (10.0.2.51–.55) on dc1/dc2.

**C. LAPS** (role `laps`) — schema extension via dc1 (`Update-AdmPwdADSchema`),
then `repadmin /syncall /AdeP` + a schema-cache refresh check before anything
depends on the new attribute (schema replication can lag longer than normal
object replication since DCs cache it in memory); install `AdmPwd.E.msi` on
`ca` and `sql2` only; confirm `ms-Mcs-AdmPwd` is actually populated on sql2
(client has to rotate the password once) before phase D's dependent step.

**D. ACL grants** (role `ad_acls`) — the ten rights onto user1, each a
distinct target: WriteDacl → writedacl-target user, GenericWrite →
genericwrite-target user, WriteProperty(msDS-KeyCredentialLink) →
computer3, WriteProperty(msDS-AllowedToActOnBehalfOfOtherIdentity) →
computer2, GenericAll → "Default Domain Policy" GPO, Self → "Domain Admins"
group, ForceChangePassword → forcechangepw-target user, DCSync (Replicating
Directory Changes + Changes All) → domain root, WriteOwner → writeowner-target
user, CONTROL_ACCESS read on `msLAPS-Password` (Windows LAPS attribute,
switched from legacy LAPS's `ms-Mcs-AdmPwd` — see Phase C) → sql2's computer
object (the only one of the ten with a hard dependency on C above). Note:
computer2/computer3's delegation/shadow-cred *attributes* are deliberately
left empty here — only the ACE granting user1 write access is created; the
attribute write itself is the student's exploit step. All AD reads/writes
across every role are pinned to a single DC (dc1) rather than
load-balancing, to avoid "object not found yet" races against the DC that
didn't originate a given write.

**E. Delegation configs** (role `ad_delegation`) — Unconstrained Delegation
on `web$`; confirm Print Spooler running on dc1+dc2; autologon-based
always-on session for the `admin` Domain Admin account on `web` (registry
autologon + a trivial keep-alive scheduled task) so its TGT lands in LSASS;
Constrained Delegation (no protocol transition) on `sql1$` → CIFS/dc1;
Constrained Delegation with protocol transition (T2A4D) on `sql2$` →
CIFS/dc1.

**F. MSSQL misconfiguration** (role `mssql_misconfig`) — shared `svc-mssql`
domain account running both SQL instances; sql1 Windows Auth open to all
domain users; sysadmin-impersonation bug on sql1 (`GRANT IMPERSONATE`);
linked server sql1→sql2 with a sysadmin-mapped login; standalone
Kerberoastable `crackme` account (SPN set, RC4 allowed, password
`iloveyou`).

**G. Website** (role `web_portal`) — ASP.NET Web Forms "CyberHawks Employee
Portal" on `web`; `CyberHawksPortal` DB on sql1 with a `Users` table (admin /
`abc123`, hashed); `Domain Users` granted read on that DB (ties into F's
Windows-Auth-for-everyone finding); `Web.config` with the real `websvc` SQL
login connection string; `Web.config.bak` left alongside it, retrievable
over HTTP.

**H. ADCS ESC1–17 on `ca`** (role `adcs_esc_templates`, own snapshot
checkpoint first) — research (SpecterOps/Certipy wiki) confirms several
ESCs are not actually template-object misconfigurations at all. **Per
explicit direction: no placeholder template gets created for an ESC that
isn't genuinely template-level** — those findings are implemented purely as
the real CA-level/DC-level/account-level config, with no `ESC#Template`
object at all. Final per-ESC treatment:

| ESC | Treatment |
|---|---|
| 1, 2, 3, 13, 15, 17 | Genuine template misconfig — a real `ESC#Template` object is created and published. ESC13 also needs an `msPKI-Enterprise-Oid` object linked (`msDS-OIDToGroupLink`) to the **Domain Admins** group (not a starter/pool account — just the standard real-world demo target). ESC15 needs true schema version 1 (`msPKI-Template-Schema-Version=1`, no `msPKI-Certificate-Application-Policy`) — add a post-build assertion this landed correctly, since template-duplication tooling can silently upgrade it. |
| 4 | Genuine template misconfig — a real `ESC4Template` object, with WriteOwner/WriteDacl/GenericWrite granted on the **template's own** `nTSecurityDescriptor` to Domain Users, rather than a cert-issuance setting — the template itself stays otherwise benign. |
| 9 | Genuine template misconfig — a real `ESC9Template` (`msPKI-Enrollment-Flag` includes `CT_FLAG_NO_SECURITY_EXTENSION`, Enroll granted to **Domain Computers**, not Domain Users — see MAQ note below) **plus** its required DC-level half: `StrongCertificateBindingEnforcement` = 0 or 1 on **both dc1 and dc2**, as its own explicit task (not left to OS defaults). |
| 5 | **No template object.** Real finding is excess rights (WriteDacl/GenericWrite) on `CN=NTAuthCertificates,...`, granted to Domain Users. |
| 6 | **No template object.** CA-level: `certutil -setreg policy\EditFlags +EDITF_ATTRIBUTESUBJECTALTNAME2` + `Restart-Service CertSvc` (baked into the same task via a handler). **CA-wide blast radius** — retroactively makes every other client-auth template on `cyberhawks-CA` (including the pre-existing `Machine`/`User`/`WebServer` templates and ESC1Template) SAN-injectable too. Enabled only after ESC1 has been independently verified, so the two stay distinguishable. |
| 7 | **No template object.** CA-level: grant `ManageCA` (+`ManageCertificates`) on the CA object to Domain Users. |
| 8 | **No template object — explicitly configured on the CA per explicit direction, not just left as a side-effect.** This role adds a task that actively confirms/enforces Web Enrollment (`certsrv`) is reachable over plain HTTP with NTLM allowed and no Extended Protection for Authentication, so ESC8 is a deliberate, verified CA state rather than an assumption inherited from the earlier domain build. |
| 10 | **No template object.** Pure DC/Schannel registry: `CertificateMappingMethods` (include UPN bit `0x4`) + `StrongCertificateBindingEnforcement=0` on dc1 and dc2. |
| 11 | **No template object — explicitly configured on the CA per explicit direction.** Disable `IF_ENFORCEENCRYPTICERTREQUEST` on the CA + restart CertSvc, exposing the RPC/ICPR enrollment endpoint to NTLM relay, matching CLAUDE.md's explicit "ca is affected by ESC8 and ESC11." |
| 12 | **Not reproducible, no template object, no config attempted.** Real finding needs a YubiHSM-protected CA key; no HSM exists in this lab. Documented as out-of-scope in CLAUDE.md rather than faked. |
| 14 | **No template object.** Weak/writable `altSecurityIdentities` on a target *account*. Reuses the **existing** GenericWrite right user1 already holds over `poolUser_genericwrite_target` (from phase D) as the write primitive — no new account, right, or template needed. |
| 16 | **No template object.** CA-level, global: add `szOID_NTDS_CA_SECURITY_EXT` (`1.3.6.1.4.1.311.25.2`) to `policy\DisableExtensionList` + restart CertSvc. Same blast-radius issue as ESC6 but stronger — makes ESC9Template's own flag redundant domain-wide. **Enabled last**, only after ESC9/ESC10 have been independently verified working off their own settings. |

**ESC9/ESC10/ESC14 entry vector:** all three need write control over some
*other* account's attribute (UPN for 9/10, `altSecurityIdentities` for 14)
to be reachable by "any domain user" without a chained finding. Decision:
ESC9/ESC10 templates grant Enroll to **Domain Computers**, and lean on the
already-intentional default `ms-DS-MachineAccountQuota=10` — any domain
user can self-create a computer account via MAQ and freely rewrite that
computer's own attributes (owner/creator control), satisfying the
write-primitive requirement with zero new ACL grants. ESC14 reuses user1's
existing GenericWrite right (above). No new pool accounts needed for any
ESC finding — every one is either "any domain user" (via broad Enroll
grants + MAQ self-service) or rides on a right user1 already has.

**CA registry flags (ESC6/7/11/16) always restart CertSvc in the same
handler**, never as a separate manual step, to avoid false negatives when
verifying. Snapshot `pre-adcs-templates` on `ca` taken immediately before
this phase starts.

**I. SMB file dump** (role `smb_file_dump`) — `\\sql1\Shared`, ~50-60
folders / few hundred mostly-empty placeholder files, one real leaked
credential for the SMB-share-creds pool account under
`IT\PasswordResets\`.

**J. Misc credential-leak findings** (role `ad_misc_findings`) — NETLOGON
logon script with cleartext creds; description-field password; a GPP
(Local Users and Groups) item that sets a **real** local account password
somewhere via cpassword; LSA secrets on `web` from a service/scheduled task
running as a domain account; ANONYMOUS LOGON added to "Pre-Windows 2000
Compatible Access"; NetNTLMv1 (`LmCompatibilityLevel`) on the DCs;
computer4 (pre-2k default password) / computer5 (blank password);
`poolUser_asreproast` (no pre-auth, password `princess`). Both the NETLOGON
script and the GPP item live in SYSVOL, which replicates via DFSR on its own
schedule separate from AD object replication — this role explicitly checks
SYSVOL sync status before treating either as done, rather than assuming it's
live domain-wide just because the underlying AD object replicated.

**K. Workstation coercion setup** (role `workstation_coercion`) — WebClient
service set to auto-start; registry weakening for local NTLM reflection
(SMB signing not required, loopback-check/NTLM restrictions not blocking).
**Flagged as best-effort** — genuine reflection-to-SYSTEM is patch-level
sensitive; the standard weakening config is landed but flagged as needing a
manual PoC check afterward rather than claiming certainty. Re-verified after
phase H, since CertSvc restarts/DC registry changes don't touch workstation
directly but a stray GPO refresh could in principle clobber local security
policy there without it being obvious.

**L. Verification pass** — from Kali, using the tools from Phase A, hit as
many findings as practically checkable from an attacker's perspective:
`GetNPUsers.py` (ASREPRoast), `GetUserSPNs.py` (crackme Kerberoasting),
`findDelegation.py` (all 3 delegation types), `certipy-ad find`/`req` against
a sample of the ESC templates, `netexec smb` (null session / anonymous
enumeration, SMB share listing), `smbclient` (file dump + NETLOGON script),
direct `sqlcmd`/impersonation check against sql1, `curl` for the web portal
+ `Web.config.bak` retrieval. Anything that can't be cleanly verified this
way gets called out explicitly rather than assumed working.

**M. Wrap-up** — new Proxmox snapshot (`vulnerable-range-v1`) across all 7
VMs once verified; update CLAUDE.md's design section to mark it built (with
the real pool-account assignments referenced, not inlined — those stay in
the gitignored file); commit the Ansible code (not the generated
credentials file).

## Verification approach (per-phase, not just at the end)

Each role's tasks end with a small set of check tasks (e.g. `Get-ADUser
-Properties`, `Get-ADComputer -Properties msDS-AllowedToDelegateTo`,
`certutil -CATemplates`, a `sqlcmd` query, `Invoke-WebRequest`) so failures
surface immediately rather than only in the Phase L sweep — Phase L is the
attacker's-eye-view confirmation on top of that, not the only check.

## Known caveats

- **ESC12 is not reproducible** in this lab at all (needs real HSM
  hardware) — no template, no config attempted, documented as out-of-scope.
- **ESC5, ESC6, ESC7, ESC8, ESC10, ESC11, ESC14, ESC16 are not actually
  certificate-template misconfigurations** — they're CA-level, DC-level, or
  target-account-level settings, and per explicit direction **no
  `ESC#Template` placeholder object is created for any of these** — only
  the real underlying config. ESC8 and ESC11 specifically are still fully
  built and verified as active CA-level configuration (matching CLAUDE.md's
  "ca is affected by ESC8 and ESC11"), just with no template object
  attached to them.
- **ESC6 and ESC16 are CA-wide, not scoped to their own template** — turning
  either on retroactively makes every other client-auth-capable template on
  `cyberhawks-CA` (including the pre-existing `Machine`/`User`/`WebServer`
  templates from the original domain build) vulnerable in that same way too.
  Treating this as intentional realism rather than a bug, and sequencing
  them last within Phase H so the more narrowly-scoped ESCs can be verified
  independently first.
- NTLM reflection on workstation (Phase K) is the one item treated as
  best-effort rather than guaranteed-exploitable, since genuine
  reflection-to-SYSTEM is patch-level sensitive.
- This is a big enough build that it spans many tool calls / a long
  continuous run. Progress is narrated phase-by-phase, and execution stops
  to flag anything that fails destructively or hits a judgment call bigger
  than the caveats above.

## Execution log

Update this section as phases complete, so a resumed/new session can see
what's actually been done vs. still pending, without re-deriving it from
scratch.

- [x] A. Control-node prep — collections, verification tooling, vault populated (`S@lcianaszkot23`), jsmith.txt fetched (48,705 names), WinRM confirmed to all 7 VMs, `/mnt/c` DrvFs metadata mode fixed (was silently ignoring ansible.cfg)
- [x] B. Foundational AD objects — user1/computer1 converged to `password` (had to disable domain password complexity first; a pre-existing disabled `user1` from unrelated earlier testing was corrected), 1000-account pool created (18 special roles assigned, verified via real domain auth + ASREPRoast flag + description field), computer2-5 + DNS A/PTR records created and resolution-verified. Also fixed group_vars location (was under `ansible/group_vars`, `ansible-playbook` needs it alongside the inventory) and `ansible.cfg` (`roles_path`, `vault_password_file`).
- [x] C. LAPS — switched to native Windows LAPS (already present on ca/sql2, no download needed). Hit 3 real issues along the way: (1) schema updates weren't allowed on the schema master by default — enabled via registry; (2) `Update-LapsADSchema`/`Set-LapsADComputerSelfPermission` hit the same NTLM double-hop issue documented elsewhere in CLAUDE.md — fixed via the same scheduled-task workaround, and split into two steps with a replication pause between them since the self-permission grant needs the schema change to have replicated first; (3) `BackupDirectory=1` means Azure AD not Active Directory (2 is AD) — first attempt silently configured Azure AD backup and rotated nothing. Verified end-to-end: LAPS actually rotated ca/sql2's local Administrator passwords (confirmed via real authentication) — which meant updating `ansible_user` to the domain account for ca/sql2 in the inventory, since the old shared local-admin password Ansible used no longer works for them (by design — that's the point of LAPS).
- [x] D. ACL grants — all ten rights granted to user1, idempotent (re-run shows "Already present"). Found and fixed a real gotcha: the Self-Membership grant on Domain Admins was silently stripped within the hour by AdminSDHolder/SDPROP (Domain Admins is a protected group) — fixed by placing the ACE on the AdminSDHolder template itself instead (the standard durable technique for this, also forced an immediate SDPROP run rather than waiting up to 60 min). Verified 5 of 10 rights via actual exploitation as user1 from Kali over real LDAP/DRSUAPI: ForceChangePassword (reset skhan's password), Self-membership (added+removed self from Domain Admins), DCSync (dumped krbtgt via impacket-secretsdump), GenericWrite (modified ssmith's description), and the LAPS read grant (via `Set-LapsADReadPasswordPermission`, Microsoft's own cmdlet for this). The other 4 (WriteDacl, both WriteProperty grants, GenericAll on the GPO, WriteOwner) use the identical proven ACE-grant code path — not individually re-exploited here, left for Phase L's fuller sweep.
- [x] E. Delegation configs — web$ Unconstrained Delegation, sql1$ constrained (no protocol transition), sql2$ constrained+T2A4D, all confirmed via `Get-ADComputer`. Created the "admin" Domain Admin account (not previously specced with a concrete build step) with autologon configured on web + a reboot to establish its session. Print Spooler confirmed running on dc1/dc2. **Found and fixed two environment-wide gaps that would have silently blocked huge swaths of the whole range's exploitability, not just this phase:** (1) vanilla Windows Server ships with the "File and Printer Sharing" firewall rule group (incl. SMB-In) disabled — SMB was completely unreachable on every host until fixed; (2) Windows Defender real-time protection was on by default and blocked LSASS access outright. Both fixed via a new `network_prereqs` role applied to all 7 VMs (not a named CLAUDE.md finding — foundational plumbing the design depends on). Also found user1 was never actually added as a local admin on web (CLAUDE.md describes this as existing "starter access" but no prior step had created it) — added that too. **Fully verified the complete exploit chain end-to-end**: `netexec`'s lsassy module, run as user1 from Kali, dumped LSASS on web and captured admin's NTLM hash plus 16 Kerberos tickets.
- [ ] F. MSSQL misconfiguration
- [ ] G. Website
- [ ] H. ADCS ESC1–17
- [ ] I. SMB file dump
- [ ] J. Misc credential-leak findings
- [ ] K. Workstation coercion setup
- [ ] L. Verification pass
- [ ] M. Wrap-up
