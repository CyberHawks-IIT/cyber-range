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

---

**Added after the initial M wrap-up, same day (2026-08-28), per follow-up
requests:**

**Starter account rename** — `user1`/`computer1$` → `user`/`computer$`,
in place (`Rename-ADObject` + `Set-ADUser`/`Set-ADComputer`, not
delete-and-recreate) so the SID — and therefore every ACL grant already
made against it — survives untouched. Folded into `ad_base_accounts` as a
one-time, idempotent migration step that's a no-op once the old names no
longer exist, so a fresh future build never needs it (the role creates
`user`/`computer` directly).

**N. NTLM relay triggers** (role `ntlm_relay_triggers`) — two new pool
accounts (`ntlm_relay_http`, `ntlm_relay_smb`, both simply the next two
unassigned rows already sitting in the existing 1000-account pool CSV —
no regeneration needed) each get a 5-minute scheduled task on `web`
that tries to reach a bare single-label hostname with no DNS record at all,
one over HTTP/WebDAV, one over SMB. `ntlm_relay_smb`'s account is also
granted local admin on `workstation`, so a successful relay is worth
landing code execution for. LDAP signing/channel binding relaxed on both
DCs (`LDAPServerIntegrity`/`LdapEnforceChannelBinding`) and outbound SMB
signing confirmed not required on `web`, so neither relay path is blocked
by a stricter-than-intended default.

**O. Unrestricted DNS zone transfer** (role `dns_zone_transfer`) — `dc1`'s
`cyberhawks.lab` zone set to `SecureSecondaries = TransferAnyServer`.

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
- [x] F. MSSQL misconfiguration — svc-mssql now runs both instances (service account changed via `sc.exe config` + restart), sql1 opened to all domain users via Windows Auth, sysadmin-impersonation bug on `sa`, linked server sql1→sql2, `crackme` Kerberoastable (RC4, `iloveyou`). Found and fixed three real gotchas: (1) SQL Server port 1433 has no default inbound firewall rule (same class of issue as the SMB one in Phase E) — added explicitly; (2) domain password complexity aside, Kerberos itself was broken domain-wide because `dc1` (PDC Emulator) had drifted ~2 hours from real time, likely from repeated snapshot/rollback cycles — fixed by pointing dc1 at real external NTP and raising the default 5-minute max-phase-correction limit (formalized into `network_prereqs`, not one-off, since this environment gets paused/snapshotted often); (3) the linked server initially used `@useself='True'`, which delegates the *caller's* identity (a real Kerberos double-hop requiring delegation on sql1$, not configured) rather than a fixed identity — switched to the correct, well-known technique of mapping all local logins to static `sa` credentials on sql2, and had to explicitly register SPNs for svc-mssql (a domain user account can't self-register SPNs the way a computer account can). **Verified all 5 findings end-to-end from Kali**: Kerberoasted crackme and cracked it with hashcat (confirmed password `iloveyou`), impersonated `sa` as user1 via T-SQL, and reached sysadmin on sql2 through the linked server as a plain domain user.
- [x] G. Website — ASP.NET Web Forms "CyberHawks Employee Portal" (Default.aspx login + Home.aspx) deployed to `web` via IIS, backed by a `CyberHawksPortal` DB on sql1 (`Users` table, admin/`abc123` SHA1-hashed). Per the user's mid-build request, renamed the app's SQL login from the plan's original `websvc` to `svc-web` to match the `svc-<name>` convention (also updated CLAUDE.md's design text and dropped the old login). Found and fixed a real IIS quirk: `.bak` isn't a registered MIME type by default, so `Web.config.bak` 404'd even though it existed — not a real block, just IIS's static handler refusing to serve any unmapped extension — registered it server-wide via appcmd. **Verified fully end-to-end**: real HTTP POST login as admin/abc123 redirects to Home.aspx showing "Welcome, admin"; `Web.config.bak` retrieves the real `svc-web` connection string over HTTP while `Web.config` itself still correctly 404s; the leaked `svc-web` credential authenticates to sql1 and reads the Users table; the stored hash matches `SHA1('abc123')` exactly.
- [x] H. ADCS ESC1–17 — the biggest, highest-risk phase, and the most iteration. Built exactly per the corrected plan: 8 genuine template objects (ESC1,2,3,4,9,13,15,17, duplicated from "User" preserving its tricky byte-array fields rather than hand-rolling them), no placeholder templates for the other 9 (ESC5/6/7/8/10/11/12/14/16 implemented as their real CA-level/DC-level/account-level config only, per the user's explicit direction). Snapshot `pre-adcs-templates` taken on `ca` first. Real gotchas hit and fixed: `msDS-OIDToGroupLink` requires a Universal-scope, **empty** group (Domain Admins is Global; Enterprise Admins already has members) — fixed by creating an empty Universal group and nesting it inside Enterprise Admins; ESC7's rights live in the CA's own registry-stored security descriptor, not a normal AD ACL (reverse-engineered the exact bitmask by inspecting Domain Admins' existing ACEs: ManageCA=0x1, ManageCertificates=0x2); `ca` lacks the RSAT ActiveDirectory module (moved ESC5 to run on dc1 instead, passed the one value `ca` still needed — Domain Users' SID — across hosts rather than fighting cross-machine ADWS calls that turned out to be unreliable for reasons not worth chasing further); and the big one — `certutil -CATemplates`/`-SetCATemplates` talk live to the running CertSvc process via RPC and hit the exact same NTLM double-hop issue documented elsewhere in this file, silently failing while the wrapper script still reported success (fixed with the same scheduled-task-under-real-password pattern used for LAPS/MSSQL). ESC6/ESC16 (CA-wide, blast radius flagged in the design) applied last, only after ESC1/ESC9 were independently confirmed. **Verified 13 of 17 via certipy-ad (a real, independent third-party tool) plus one direct LDAP test as user1** — ESC1,2,3,4,5,6,7,8,9,11,13,15,16 all confirmed, including the expected/designed overlaps (ESC2↔ESC3 by design, ESC1↔ESC15 as a benign side effect of sharing a v1-schema/Client-Auth base) and the ESC13 group-link correctly resolving to the new nested group. Confirmed the CA survived every restart along the way (Web Enrollment still responds). ESC10 (DC-level cert mapping) and ESC12/14 (documented-only per the design) weren't separately re-verified here — ESC12/14 have no live config to check by design, ESC10 needs a different verification approach than certipy's `-vulnerable` sweep.
- [x] I. SMB file dump — `\\sql1\Shared`, 57 folders across 9 top-level categories (HR/IT/Finance/Engineering/Scans/Archive/Legal/Marketing/Facilities + 20 per-employee `Users\` folders), 317 mostly-empty realistically-named filler files, one real leaked credential (`IT\PasswordResets\ResetLog_2026.txt`) for the smbshare-creds pool account. Hit a real Ansible/Jinja gotcha extracting the credential from the generated CSV: Python's `csv.writer` defaults to `\r\n` line endings even on Linux, which silently broke the `$`-anchored regex used to pull the row out — fixed with `\r?$`. **Verified end-to-end from Kali**: accessed the share as user1 (domain-qualified `CYBERHAWKS\user1` — bare `user1` fails against this share for the same reason bare `Administrator` meant something different earlier in this build), retrieved the leaked file, and confirmed the recorded password actually authenticates as the target account.
- [x] J. Misc credential-leak findings — NETLOGON script (cleartext creds for skumar), ANONYMOUS LOGON added to Pre-Windows 2000 Compatible Access, `svc-backup` account + a real Windows service (`BackupSyncAgent`) caching its password in LSA secrets, computer4 (pre-2k default password) / computer5 (blank password), NetNTLMv1 enabled on both DCs, and a GPP Local Users and Groups preference. (description-field password and ASREPRoast were already done in Phase B.) Hit and fixed several real gotchas: `Add-ADGroupMember` can't add well-known SIDs like ANONYMOUS LOGON at all (client-side identity validation rejects them, and AD blocks direct `foreignSecurityPrincipal` creation too) — fixed with raw ADSI `PutEx` using the `<SID=...>` distinguished-name-by-SID syntax, which lets AD auto-vivify the FSP object as a side effect; a scheduled task's credential caches as a crackable DCC2/MSCACHEv2 hash, not a plaintext LSA secret — switched the LSA-secrets finding to a Windows service instead (confirmed instantly plaintext-recoverable as `_SC_BackupSyncAgent`); my GPP `cpassword` encryption had the wrong AES key (misremembered bytes) and wrong base64 variant (needs base64url, not standard) — fixed both and independently verified the corrected encryption byte-for-byte against Microsoft's published algorithm; a GPO built by writing directly to SYSVOL/AD rather than through GPMC's settings APIs needs `versionNumber` manually bumped (packed with `GPT.INI`) or the client treats it as empty regardless of a correct extension GUID. **One finding, flagged rather than silently claimed working**: even after all of the above was fixed and independently verified correct, updating the built-in Administrator's password via GPP — and even creating a brand-new local account via GPP — never actually changed the resulting password on this specific (very recent) Windows 11 build, despite the GP client logging clean success with no errors at every step; this looks like a platform-level mitigation neutering GPP's cpassword application specifically (account creation/attributes still apply fine), not a bug in this implementation. Documented as best-effort, same treatment as the already-flagged NTLM reflection finding on this same host. **Verified everything else end-to-end from Kali**: retrieved the NETLOGON script over SMB, confirmed computer4/computer5's passwords authenticate, and dumped `_SC_BackupSyncAgent` via impacket-secretsdump to recover svc-backup's real password.
- [x] K. Workstation coercion setup — WebClient (WebDAV Redirector) set to Automatic startup and confirmed running (verified via `Get-Service`), plus the standard registry weakenings for local NTLM reflection (`DisableLoopbackCheck=1`, SMB signing not required on client or server). As planned from the start, this is treated as best-effort and not independently live-tested with a real reflection exploit — genuine reflection-to-SYSTEM is patch-level sensitive, and the config here is the standard prerequisite state documented for it rather than a verified working PoC.
- [x] L. Verification pass — a genuine attacker's-eye-view sweep from Kali (WSL) against the live range, deliberately using independent tools (impacket, netexec, certipy-ad, ldap3/ldapsearch, hashcat, smbclient, curl) rather than re-reading the AD state the build scripts themselves wrote. Almost everything confirmed working end-to-end, not just "the attribute is set":
  - **ASREPRoast**: `impacket-GetNPUsers` got asmith's hash with no pre-auth; hashcat cracked it to `princess`.
  - **Kerberoasting**: `impacket-GetUserSPNs` got crackme's TGS hash; hashcat cracked it to `iloveyou` (RC4/etype 23, confirming weak encryption is allowed).
  - **All three delegation types**: `impacket-findDelegation` confirmed web$ Unconstrained, sql1$ Constrained without protocol transition, sql2$ Constrained with protocol transition — exactly one of each, matching the design's non-overlap rule.
  - **Unconstrained Delegation, full chain**: `netexec`'s lsassy module, run as user1 (local admin on web), dumped LSASS and captured a real Domain Admin (`admin`) Kerberos TGT ccache file directly off the box — this is the actual, complete exploit, not just a config check.
  - **All nine of user1's AD-object ACL grants**: verified individually via a custom ldap3 script that reads each target's raw security descriptor and decodes the ACE's `ObjectType` GUID, cross-checked against the *live domain schema's own* `schemaIDGUID`/`rightsGUID` values (not a hardcoded guess) — WriteDacl (jsmith), GenericWrite-equivalent (ssmith), ForceChangePassword (skhan, GUID-matched to `User-Force-Change-Password`), WriteOwner (msmith), RBCD write on computer2 (GUID-matched to `msDS-AllowedToActOnBehalfOfOtherIdentity`), Shadow Credentials write on computer3 (GUID-matched to `msDS-KeyCredentialLink`), Self on Domain Admins (GUID-matched to the Self-Membership control access right), GenericAll on the Default Domain Policy GPO, and DCSync (both `DS-Replication-Get-Changes` and `-Get-Changes-All` GUIDs present at the domain root). All nine matched exactly.
  - **ADCS**: `certipy-ad find -vulnerable` independently flagged ESC1, ESC2, ESC3, ESC4, ESC6, ESC7, ESC8, ESC9, ESC11, ESC13, ESC15, ESC16 correctly, with ESC6/7/8/11/16 correctly attributed to the CA object itself (no template) exactly as designed. ESC5 doesn't surface in certipy's default output — verified separately via a direct ACE/GUID read on `NTAuthCertificates`, confirming Domain Users holds WriteDacl there. ESC10 confirmed via direct registry read on both DCs (`CertificateMappingMethods=4`, the UPN-mapping bit). ESC17 template is built with the correct flags (schema v1, enrollee-supplies-subject, Server Authentication EKU) but this certipy version (5.0.4) has no dedicated ESC17 detection logic at all (confirmed by checking its own source) — config verified by direct attribute inspection instead of tool flagging. ESC12/14 remain out-of-scope/no-template by design, as documented.
  - **MSSQL chain, fully live**: authenticated to sql1 as a plain pool account (dsmith) via Windows Auth, confirmed *not* sysadmin, ran `EXECUTE AS LOGIN='sa'`, confirmed sysadmin achieved, enabled and ran `xp_cmdshell` — output was `cyberhawks\svc-mssql`, confirming the shared service account. From that same sysadmin session, queried the sql1→sql2 linked server via `OPENQUERY`, which came back `sysadmin`/`sa` on sql2 too. Also confirmed svc-web's leaked SQL login (from `Web.config.bak`) authenticates and reads the real `admin` password hash (`SHA1('abc123')`, byte-for-byte match) from the portal DB, and that a random unrelated domain user can read the same DB via Windows Auth.
  - **Web portal**: `/` serves the real login page directly (no redirect needed — this is the correct post-fix behavior), `Web.config.bak` retrieves the real connection string over HTTP, `Web.config` itself still 404s.
  - **SMB dump + NETLOGON**: retrieved `IT\PasswordResets\ResetLog_2026.txt` (jjohnson's leaked password) and the NETLOGON `MapDrives.ps1` script (skumar's cleartext creds) over SMB as user1; both passwords independently confirmed to authenticate.
  - **GPP**: downloaded `Groups.xml` from SYSVOL and manually decrypted the `cpassword` (bypassing a `gpp-decrypt` CLI quirk — the ciphertext string happens to contain a literal `--`, which the tool's own argument parser misreads as an end-of-options marker, truncating its input) — decrypted value matched the generated password file exactly.
  - **computer4/computer5**: computer4's pre-2k default password got a real TGT via `impacket-getTGT`. computer5's TGT request hung indefinitely for unclear reasons specific to requesting a truly-empty-password AS-REQ against this KDC (a tool/protocol quirk, retried multiple ways) — confirmed instead via DCSync-equivalent hash dump that its NT hash is exactly `31d6cfe0d16ae931b73c59d7e0c089c0`, the well-known hash of an empty string, which is the actual fact the finding depends on.
  - **ANONYMOUS LOGON / null-session enumeration**: confirmed working — unauthenticated SMB null session successfully enumerated the full user list including description-field contents (independently reconfirmed csmith's password-in-description here too).
  - **Weak-cred pool accounts**: spot-checked one (dsmith/`Summer2026`) — authenticates.
  - **NetNTLMv1**: confirmed via registry (`LmCompatibilityLevel=1` on both DCs) — permits NTLMv1 responses rather than rejecting them; not separately forced/exploited live.
  - **Not cleanly verified, called out rather than assumed**: (1) **LAPS read on sql2** — user1's ACE is provably correct (ReadProperty+ControlAccess on `msLAPS-EncryptedPassword`'s exact schema GUID, matching what `Set-LapsADReadPasswordPermission` itself produces), and Administrator can read the raw attribute fine when queried directly on a DC, but every remote-tool attempt to actually retrieve the value as user1 — `ldap3` (both plain LDAP and LDAPS), `ldapsearch`, netexec's `laps` module (which turned out to only check the legacy/plaintext attribute names, not `msLAPS-EncryptedPassword`), and even the real `Get-LapsADPassword`/`Find-LapsADExtendedRights` cmdlets run via a double-hop `Invoke-Command` — either returned nothing or hit this lab's already-documented NTLM double-hop wall. The configuration is verified correct; true end-to-end secret retrieval as user1 was not, and would need either a Kerberos-authenticated session or a tool with proper NTLM sealing to confirm cleanly. (2) **NTLM reflection on workstation** and (3) **GPP password application on workstation** remain best-effort per Phases K/J — not retested here.
  - Also reconfirmed the DCSync right works in practice (impersonated-TGT DCSync itself hit an unrelated impacket/Kerberos-ccache tool bug — `-k` ccache auth to `secretsdump.py` — but the *ACE* was already independently proven via the GUID-matched read above, and DCSync via a plaintext-authenticated session was already proven working back in Phase D).
- [x] M. Wrap-up — new Proxmox snapshot `vulnerable-range-v1` taken on all 7 VMs (320-326), following the same clean-shutdown/snapshot/restart pattern as the earlier `domain-configured` snapshot (all 7 shut down without incident this time — no repeat of the earlier Server-2016 staged-update hang). CLAUDE.md's "Vulnerable AD range design" section updated from "(planned)" to "(built 2026-08-28)" with a status summary pointing at this plan file for detail, without inlining the real pool-account assignments (those stay in the gitignored `ansible/generated/pool_accounts.csv`). Open items #5/#6 at the bottom of CLAUDE.md updated to reflect the playbooks and design are no longer outstanding.
- [x] Starter account rename (`user1`/`computer1$` → `user`/`computer$`) — folded into `ad_base_accounts` as a one-time idempotent migration (`Rename-ADObject` + `Set-ADUser`/`Set-ADComputer`, plus renaming the matching DNS A/PTR record from `computer1`→`computer`). SID preserved on both, confirmed by comparing the post-rename SID against the one recorded during Phase L's ACL verification — identical. Re-verified post-rename: `user`/`password` still authenticates and is still `Pwn3d!` (local admin) on web via netexec, so every ACL/group-membership grant made in earlier phases survived untouched, as expected for a rename rather than a delete+recreate.
- [x] N. NTLM relay triggers — two new pool accounts pulled from the *already-generated* 1000-account CSV (rows that had no role assigned yet — no regeneration, no disturbance to the 998 other already-provisioned accounts): `bsmith` → `ntlm_relay_http`, `rsmith` → `ntlm_relay_smb`. Both get a 5-minute scheduled task on `web` (`CyberHawksSync-FileServiceCheck` / `CyberHawksSync-BackupMountCheck`) trying to reach a bare single-label hostname (`filesvc` / `backupsvc`) with no DNS record. `rsmith` is also added to workstation's local Administrators group. Three real gotchas hit and fixed along the way:
  - **DC-hosted scheduled tasks silently fail their batch logon.** Originally placed both tasks on `dc1` (seemed like the natural "always-on, central" choice) — they registered fine but every run failed at `LogonUserExEx` with `STATUS_LOGON_FAILURE` (Win32 `2147943785`), even though the exact same credentials authenticate fine interactively. Root cause: Domain Controllers enforce "Log on as a batch job" via the *Default Domain Controllers Policy* (GPO-controlled, restricted by default to Administrators/Backup Operators/etc.), which `schtasks /Create /RU /RP` cannot grant around the way it can on a member server. Moved both tasks to `web` instead — same error reproduced there too, which ruled out "DC-specific" as the root cause and pointed at the real one below.
  - **`schtasks /Create /RU + /RP` does not itself grant "Log on as a batch job."** This is a persistent misconception (some documentation/tutorials claim it auto-grants the right) — verified directly via `secedit /export /areas USER_RIGHTS` that neither `bsmith` nor `rsmith` held `SeBatchLogonRight` after task creation, on `web` or `dc1`. Fixed by explicitly granting the right via `secedit /export` → edit the `SeBatchLogonRight` line → `secedit /configure` (the standard scriptable technique now that `ntrights.exe` no longer ships with Windows), done automatically inside `setup_relay_triggers.ps1` before registering each task. Confirmed fixed via the Task Scheduler operational event log showing clean start→launch→finish (event IDs 100/200/102/201) instead of the earlier 101/104 logon-failure pair.
  - **A fully-qualified trigger hostname never falls back to broadcast resolution.** The very first version used `filesvc.cyberhawks.lab`/`backupsvc.cyberhawks.lab` — packet capture on the relay box showed **zero** LLMNR/NBT-NS/mDNS traffic ever generated, because `dc1`/`dc2` are authoritative for the entire `*.cyberhawks.lab` zone and return a definitive authoritative NXDOMAIN for those names, which Windows treats as final (no reason to guess further via broadcast). Switched both trigger scripts to bare single-label names (`filesvc`, `backupsvc`, no domain suffix) — DNS-with-suffix-search still fails, but *that* failure mode does fall through to LLMNR/NBT-NS/mDNS, exactly like every real-world "mistyped share name" scenario this technique is modeled on.
  - **Verified fully live end-to-end from the new attacker box (10.0.2.10, see CLAUDE.md)**: Responder captured real NTLMv2/NTLMv2-SSP hashes for both `bsmith` (HTTP) and `rsmith` (SMB) on the first attempt after the hostname fix. Went further than a capture: reconfigured Responder to poison-only (its own HTTP/SMB servers off) and ran `impacket-ntlmrelayx` to perform the actual relay — `bsmith`'s HTTP auth relayed to `ldap://dc1` and successfully dumped domain info via the relayed session; `rsmith`'s SMB auth relayed to `smb://workstation` and executed a command there. Both are genuine, live, complete attack chains, not just "the right hash showed up in a log." One additional gotcha surfaced during the live-relay verification specifically (not needed for the capture-only case, but worth recording): Responder answers LLMNR/mDNS **AAAA** queries too, and its own IPv6-capability probe binds to `::1` to decide whether to do so — disabling IPv6 on just the relay box's `eth0` still left loopback IPv6 working, so the probe kept succeeding and Responder advertised the useless `::1` as its IPv6 address once it had no real one, black-holing any client (both triggers) that preferred the poisoned IPv6 answer over IPv4. Fixed by disabling IPv6 system-wide on the relay box including `lo`, which makes the probe fail cleanly and Responder fall back to IPv4-only.
  - **Attacker tooling install** (10.0.2.10 / Proxmox VMID 350, Debian 12 LXC hostname `test`): Responder (git clone + venv), mitm6 (`pipx install mitm6`), impacket/`ntlmrelayx.py` (`pipx install impacket`), and Pretender (built from source — its `go.mod` requires Go ≥1.25, newer than apt's `golang-go` 1.19.8, so installed the latest official Go release to `/usr/local/go` instead). This control host's own automation key was pushed to `~/.ssh/authorized_keys` for unattended setup, but `test`/`test` remains the actual documented student credential, not a bootstrap-only fallback. Responder.conf left at shipped defaults (all servers on) once verification finished, so students get a normal, unmodified install.
- [x] O. Unrestricted DNS zone transfer — `dc1`'s `cyberhawks.lab` zone set to `Set-DnsServerPrimaryZone -SecureSecondaries TransferAnyServer`. Confirmed live and unauthenticated via `dig axfr cyberhawks.lab @<dc1>` from Kali — full zone dump including every A/SRV/NS record. Checked whether this also applied to `dc2` (an AD-integrated zone's *record data* replicates, so it seemed plausible the transfer-policy setting would too) — it does not: `dig axfr ... @<dc2>` failed, and `Get-DnsServerZone` on `dc2` confirmed `SecureSecondaries` is still `NoTransfer` there. This is a genuinely per-DNS-server zone property, not something that rides along with AD replication — documented as such rather than assumed. Matches the "at least one DC" ask exactly; extending to `dc2` would just be the same one-line change run there too, if ever wanted.
- [x] Wrap-up (round 2) — `docs/range-briefing.html` updated to match: starter-access cards renamed (`user`/`computer$`), a new attacker-box access card (10.0.2.10, `test`/`test`, tools list), a new "NTLM Relay Practice" section (2 findings), a new DNS-zone-transfer row in Weak & Missing Authentication (now 8 findings), and an Essential Notes bullet clarifying that pool usernames come from a public statistically-likely-usernames list (guessable) even though most of their passwords aren't. Republished to the same artifact URL from earlier. All 7 range VMs (320-326) shut down cleanly, `vulnerable-range-v1` deleted and replaced with `vulnerable-range-v2` (same clean-shutdown/snapshot/restart pattern as every prior range-wide snapshot), then restarted and re-verified (`user`/`password` still authenticates and is still local admin on web — took ~30s post-restart for DC/Netlogon services to fully come up before auth succeeded, not a real issue). The attacker box (VMID 350) got its own snapshot, `attacker-tools-v1`, taken live (container wasn't stopped — nothing stateful running on it) once all four tools were confirmed installed and working.
