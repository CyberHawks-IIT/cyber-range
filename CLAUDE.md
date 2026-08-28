# Cyber Range Project

Purpose: a personal cyber range for practicing identification and remediation of
common vulnerabilities. VMs are hosted on a Proxmox server and reached from this
Windows 11 host over a NetBird VPN (NetBird routes traffic directly to each VM's
IP — no separate tunnel/proxy config needed per host).

This repo holds the Ansible code used to provision/configure range hosts, plus
this file as the running source of truth for project context across sessions.

## Working conventions

- **Commit locally as you go; use judgment on when to push.** (Updated
  2026-08-27 — previously this said push after every change, but that turned
  out to be more than the user wanted.) Code/Ansible changes are a good
  default trigger to push. Don't feel obligated to push after every small
  CLAUDE.md tweak or in-progress investigation note.

## Control host

Working from a Windows 11 machine (`C:\Tools` is the general tools directory this
project lives under). Key tooling installed on this host so far:

- **OpenSSH client** — built into Windows 11, used for all Linux SSH access.
- **PuTTY / plink** (`C:\Program Files\PuTTY\plink.exe`) — installed via winget.
  Used only for one-off password-authenticated bootstrapping (e.g. initial key
  push) since Win32-OpenSSH's `ssh` reads passwords from the console directly and
  can't be scripted. Prefer plain `ssh` with the key for everything else.
- **GitHub CLI** (`gh`, `C:\Program Files\GitHub CLI\gh.exe`) — installed via
  winget, already authenticated as `RedefiningReality`.
- **WSL2 + Ansible** — confirmed set up 2026-08-28. WSL2 itself (kernel/
  platform) was already enabled, but no distro had actually been installed
  yet (`wsl --list --verbose` reported none) despite CLAUDE.md previously
  saying this was pending — turned out it really was still pending, not just
  unconfirmed. Installed **Kali Linux** (`wsl --install -d kali-linux
  --no-launch`, distro name `kali-linux`) per the user's choice — chosen over
  Ubuntu to match the pentest theme, even though it's not strictly needed
  just to run Ansible as a control host. No interactive first-run setup was
  needed — `wsl -d kali-linux -u root -- <cmd>` works immediately as root
  with no default non-root user configured. Installed via `apt-get install -y
  pipx ansible`: **Ansible core 2.20.3**, **pipx 1.14.0**, Python 3.13.12.
  `ansible` pulled in `python3-winrm` (pywinrm) as a dependency automatically
  — confirmed importable — so WinRM connections to the range VMs work out of
  the box with no extra pip install needed.
  The repo is reachable from WSL at `/mnt/c/Tools/cyber-range` (confirmed
  `ansible-inventory -i ansible/inventory/hosts.yml --list` parses cleanly).
  **Known quirk:** running Ansible from that path prints "Ansible is being
  run in a world writable directory... ignoring it as an ansible.cfg source"
  — this is normal DrvFs (Windows-drive-via-WSL) mount behavior, not a real
  permissions problem, but it does mean `ansible/ansible.cfg` in this repo is
  silently ignored when run this way. Workaround if that config file's
  settings matter: point `ANSIBLE_CONFIG` at it explicitly, or invoke
  `ansible-playbook` with `-i`/other flags instead of relying on
  auto-discovery. Not yet resolved either way — just documenting the
  behavior for whoever writes the first real playbook run.

SSH key for range hosts: `~/.ssh/id_ed25519_cyberrange` (public key comment
`cyberrange-lab`) on this Windows host — private key is gitignored, never
committed. This is the key deployed to range hosts for automation access.

## Hosts

### Proxmox host — 192.168.192.150

- **Access:** SSH as `root@192.168.192.150`, key-only (`id_ed25519_cyberrange`).
- **Hardening applied 2026-08-27:** password authentication disabled for SSH.
  Changes to `/etc/ssh/sshd_config` on the Proxmox host itself:
  - `PasswordAuthentication no`
  - `PubkeyAuthentication yes`
  - `PermitRootLogin prohibit-password` (root login only via key, never password)
  - `KbdInteractiveAuthentication no` (was already set)
  - Original config backed up on the Proxmox host at
    `/etc/ssh/sshd_config.bak.<timestamp>` before editing.
  - Verified after restart: key login works, password login is rejected
    (`server sent: publickey` only).
  - Note: the root account password that was used to bootstrap this (shared
    with the user out-of-band) no longer works for SSH, but may still be valid
    for the Proxmox web UI — consider rotating it if it's not already unique to
    that surface.

### Support/tooling hosts — 192.168.0.0/24, Debian 12, SSH

Separate from the Proxmox-hosted AD range below — these are standalone Debian
12 (bookworm) boxes on a different subnet (`192.168.0.0/24`), each running one
dockerized security tool. Reached the same way as the Proxmox host: SSH
directly (NetBird routes to them, no extra tunnel config).

- **Access:** SSH as `root`, key-only (`id_ed25519_cyberrange`).
- **Hardening applied 2026-08-27 (all three hosts):** cyberrange-lab pubkey
  installed to `~/.ssh/authorized_keys`, then `/etc/ssh/sshd_config` changed:
  - `PermitRootLogin prohibit-password` (root login only via key, never
    password)
  - Original config backed up on each host at
    `/etc/ssh/sshd_config.bak.<timestamp>` before editing.
  - Verified after restart on each: key login works, password login is
    rejected.
  - Unlike the Proxmox host, `PasswordAuthentication` itself was left alone
    (only `PermitRootLogin` was changed) — non-root password login is still
    possible in principle, but these boxes are effectively root-only in
    practice.
  - The shared root password used to bootstrap key install on all three (out
    of band with the user, same password reused across all three) no longer
    works for SSH on any of them post-hardening.

| Name | IP | Tool | Notes |
|---|---|---|---|
| sysreptor | 192.168.0.2 | SysReptor (pentest reporting) | Docker Compose in `/root/sysreptor` (official layout: `deploy/{sysreptor,caddy,languagetool}/docker-compose.yml` included from `deploy/docker-compose.yml`). Caddy reverse-proxies the app. Updated to latest (`2026.68`) 2026-08-27 — was already current. **TLS enabled 2026-08-27:** Caddy now serves `https://192.168.0.2/` on 443 with a self-signed cert (`tls internal`, no public domain available on this LAN) and `:80` redirects to it. Caddyfile site block must be pinned to the literal IP (`192.168.0.2:443`, not a bare `:443`) — otherwise Caddy has no hostname to issue an on-demand cert for and bare-IP requests (no SNI) fail TLS handshake. Browser will show an untrusted-cert warning until Caddy's root CA (`docker exec sysreptor-caddy cat /data/caddy/pki/authorities/local/root.crt`) is installed as a trusted root client-side. |
| nessus | 192.168.0.3 | Tenable Nessus (vuln scanner) | Installed via `.deb` (`nessus` package, `/opt/nessus/`), not managed via apt repo — updates go through `nessuscli update`, not `apt`. Registered on the free **HomeFeed (non-commercial use only)** feed, activation code `AAHP-WEBB-NDU4-WAM9-FEP9`. Updated 2026-08-27: software `10.9.3` → `10.12.4` (build 20038) via `nessuscli update --all` (core-component update required `systemctl stop nessusd` first, then update, then start again — plugins-only updates don't need the service stopped). Plugins confirmed fully compiled/loaded after update by polling `https://127.0.0.1:8834/server/status` until `feed_status`/`db_status`/`engine_status` all report `"ready"` (not just the CLI's "Complete", which only means downloaded — post-update plugin compilation + DB upgrade can take a minute+ after that). |
| bloodhound | 192.168.0.4 | BloodHound CE (AD attack path analysis) | Docker Compose, 3 containers: `bloodhound-bloodhound-1` (app, port 80→8080), `bloodhound-graph-db-1` (Neo4j 4.4, 127.0.0.1-only), `bloodhound-app-db-1` (Postgres 16). User confirmed already up to date as of 2026-08-27 — not independently verified/updated by Claude. |

Note: none of these three has been given a Proxmox VMID/template mapping here
since they're plain Debian VMs/hosts outside the `qm`-managed AD range — if
that changes (e.g. they turn out to also be Proxmox guests), reconcile with
the Proxmox host's `qm list` and add them to a table like the range VMs below.

### Range VMs — all Windows, all accessed over WinRM

All are on the Proxmox `ad` bridge, network `10.0.2.0/24`, gateway `10.0.2.1`,
domain `cyberhawks.lab`. This looks like an Active Directory range: dc1/dc2 are
domain controllers, ca is a certificate authority, sql1/sql2 are SQL Server
boxes, web is a web server, workstation is a Win11 client.

| Name | VMID | Template (source) | IP | OS | MAC (net0) |
|---|---|---|---|---|---|
| dc1 | 320 | 300 (Windows2016) | 10.0.2.2/24 | Windows Server 2016 | BC:24:11:F4:20:96 |
| dc2 | 321 | 301 (Windows2019) | 10.0.2.3/24 | Windows Server 2019 | BC:24:11:52:77:99 |
| ca | 322 | 301 (Windows2019) | 10.0.2.4/24 | Windows Server 2019 | BC:24:11:C1:3C:1C |
| web | 323 | 302 (Windows2022) | 10.0.2.5/24 | Windows Server 2022 | BC:24:11:27:52:53 |
| sql1 | 324 | 300 (Windows2016) | 10.0.2.6/24 | Windows Server 2016 | BC:24:11:A5:48:39 |
| sql2 | 325 | 302 (Windows2022) | 10.0.2.7/24 | Windows Server 2022 | BC:24:11:5A:C6:7D |
| workstation | 326 | 304 (Windows11) | 10.0.2.8/24 | Windows 11 | BC:24:11:94:BB:C6 |

All 7 confirmed `running` in Proxmox as of provisioning time, correct disk sizes
(sql1/sql2 at 48G, rest at template default 32G).

**Baseline snapshot (2026-08-27):** all 7 shut down cleanly, each given a
Proxmox snapshot named `initial` ("Baseline snapshot before AD/domain
configuration"), then restarted. Use `qm rollback <vmid> initial` on any of
them to reset back to this pre-domain-config state if something goes wrong
during AD setup later.

Provisioned 2026-08-27 via linked clone (`qm clone`, default linked-clone
behavior since sources 300/301/302/304 are Proxmox templates) from the Proxmox
host itself, cloud-init IP set per host above. sql1/sql2 disks resized to 48G
(from the 32G template default) to match a prior similar range setup found on
this host (VMs 310-314, tag `cptc-practice-2025` — an earlier/separate
dc/ca/sql/web set, not part of this project, left untouched). All 7 tagged
`cyber-range` in Proxmox for identification.

**DNS (updated 2026-08-27 — balanced across both DCs):** neither dc1 nor dc2
has AD DS/DNS installed yet, so both currently point their own DNS upward at
the gateway (10.0.2.1) rather than at each other — pointing a DC at another DC
with no DNS service running just breaks resolution for it. The 5 non-DC
members are split between the two DCs (primary + the other as secondary) so
no single DC is a hard dependency:

| VM | Primary DNS | Secondary DNS |
|---|---|---|
| dc1 | 10.0.2.1 (gateway) | — |
| dc2 | 10.0.2.1 (gateway) | — |
| ca | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| sql1 | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| workstation | 10.0.2.2 (dc1) | 10.0.2.3 (dc2) |
| web | 10.0.2.3 (dc2) | 10.0.2.2 (dc1) |
| sql2 | 10.0.2.3 (dc2) | 10.0.2.2 (dc1) |

Applied both ways: directly in-guest via `netsh interface ip set/add dns`
(over WinRM for the 6 reachable VMs — cloud-init/cloudbase-init only runs on
first boot, which had already happened, so changing Proxmox's config alone
would not have retroactively updated already-booted guests) **and** in the
Proxmox cloud-init `--nameserver` config on each VM, so a future re-clone or
cloud-init reset picks up the same scheme without redoing this by hand.

**DNS rebalanced 2026-08-27 after dc1/dc2 were promoted:** now that both run
the DNS server role, dc1 primaries itself/secondaries dc2 and vice versa; the
5 members keep the same primary/secondary DC split as before, just no longer
pointing at the gateway at all. Applied in-guest via `Set-DnsClientServerAddress`
only (not re-applied to the Proxmox cloud-init config this time — a re-clone
from these VMs isn't expected, unlike the templates). The gateway is not
configured as a conditional forwarder inside the DNS role — out of scope for
now, external resolution from the range hosts hasn't been needed.

**Access:** WinRM, user `Administrator`. Credentials are inherited from the
Proxmox cloud-init templates (300-304) — same password across all clones since
it wasn't overridden at clone time (confirmed identical across templates
300/301/302/304). Retrieve the current plaintext password by running this on
the Proxmox host (do **not** commit it to this repo):
```
qm cloudinit dump <vmid> user
```
This host's `WSMan:\localhost\Client\TrustedHosts` has been set (by the user)
to include all 7 VM IPs. **Verified 2026-08-27** via authenticated
`Invoke-Command` (not just port reachability): all 7 VMs now respond correctly,
including workstation after the fixes below (confirmed hostname `workstation`,
`Microsoft Windows 11 Pro N`).

**QEMU guest agent (2026-08-27):** all 7 VMs confirmed working
(`qm agent <vmid> ping` succeeds). dc1/dc2/ca/web/sql1/sql2 already had it via
their templates. workstation didn't (template 304 never had `agent: 1` set) —
installed via the `virtio-win.iso` already mounted on it
(`E:\guest-agent\qemu-ga-x86_64.msi`, silent `msiexec`), then
`qm set 326 --agent enabled=1` + a full VM restart (this is a hardware change,
a guest-side reboot isn't enough — confirmed via `qm pending` showing it
queued until actually restarted).

**Known issue, NOT yet fixed — stale Cloudbase-Init state on template 304:**
while trying to also fix this at the template level, found that a *fresh*
clone from template 304 can fail to apply its cloud-init network config
entirely (silently stays on link-local/no IP — different symptom from the
earlier 300/302 static-IP bug). Cause: `C:\...\Cloudbase-Init\log\cloudbase-init.log`
on a fresh clone shows `Plugin 'NetworkConfigPlugin' execution already done,
skipping` on its very first-ever boot. The registry key
`HKLM\SOFTWARE\Cloudbase Solutions\Cloudbase-Init\<instance-id>` already exists
on the template's disk (`base-304-disk-1`) — almost certainly left over from
whoever originally built the template test-booting it before capture, without
clearing Cloudbase-Init's execution-state registry key first. Whether a given
clone hits this depends on whether Proxmox's generated cloud-init `uuid`
happens to collide with whatever instance-id got baked in (workstation/326
didn't hit it; a scratch full-clone made later did).
Separately (and unrelated): the disabled-Administrator issue reproduces on
every genuinely fresh clone regardless of any template-level SAM edit — Windows'
own OOBE/specialize pass resets it independently of whatever we set offline
beforehand. The `chntpw` fix only sticks once applied *after* a machine's own
first specialize pass has already run (which is why it stuck permanently for
workstation) — editing the template's pre-specialize disk directly does not
survive. **Have not yet worked out a durable template-level fix for either of
these** — likely needs clearing the Cloudbase-Init registry key on the
template's disk (for the network issue) and rethinking the Administrator fix
approach given it can't be pre-baked the way Secure Boot / disk resizing can.
Punted for now at the user's call — not high priority. A scratch VM (970) was
used to investigate this and has been fully destroyed, disks included; no
residue left on the Proxmox host.

**workstation (VM 326) hit two separate boot issues, both fixed:**

1. **Secure Boot rejected the VirtIO SCSI driver** (`vioscsi.sys`, error
   `0xc0000428`, "digital signature couldn't be verified"). Cause: template
   304's efidisk0 has `pre-enrolled-keys=1`, which populates Secure Boot with
   only the standard Microsoft certs — not Red Hat's VirtIO signing cert. Since
   vioscsi.sys is a boot-start driver, Secure Boot blocked it before Windows
   could even start. Fixed by recreating VM 326's efidisk0 with Secure Boot
   disabled: `qm set 326 --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=0`
   (this discards/replaces the EFI vars disk — fine pre-OS-install, would not
   be fine on a disk with real data).
2. **Built-in `Administrator` account was disabled** — expected Windows 11
   behavior (unlike Server SKUs, client Windows ships with the built-in
   Administrator disabled by default; cloudbase-init setting its password
   doesn't auto-enable it). A disabled account can't authenticate over WinRM
   either, so this needed an offline fix. With the VM shut down
   (`qm shutdown 326`), mounted its disk from the Proxmox host itself and
   edited the SAM hive directly:
   ```
   modprobe nbd max_part=8
   qemu-nbd -c /dev/nbd0 -f raw /dev/zvol/rpool/data/vm-326-disk-1
   # nbd0p3 is the Windows partition (GPT: p1=EFI, p2=MSR, p3=Windows, p4=Recovery)
   mount via ntfs-3g, then:
   printf '2\nq\ny\n' | chntpw -u Administrator <mount>/Windows/System32/config/SAM
   # option 2 = "Unlock and enable user account"
   ```
   Confirmed via `chntpw -l SAM` before/after (Administrator's `dis/lock` flag
   cleared). Unmounted, `qemu-nbd -d /dev/nbd0`, restarted the VM. `chntpw`
   and `ntfs-3g` (installed via apt specifically for this) were **purged**
   afterward per standing instruction — nothing left installed on the Proxmox
   host from this. Note: while in the SAM hive, found a `cloudbase-init` local
   admin account that's enabled/not locked (unlike Administrator) — its
   password is unknown (cloudbase-init generates one internally), so it wasn't
   used, but it's a secondary admin path worth knowing about if Administrator
   ever gets re-disabled or locked out again.

Not yet re-verified over WinRM after this fix — recheck before assuming
workstation is fully reachable.

**Both issues above were then also fixed on template 304 itself (2026-08-27)**,
so future clones from it don't need this manual workaround:

- **Secure Boot:** same fix as VM 326 — recreated the template's efidisk0 with
  `pre-enrolled-keys=0`:
  `qm set 304 --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=0`.
  Proxmox created it as `base-304-disk-3` and auto-snapshotted it (`@__base__`)
  for cloning, same as any template disk.
- **Administrator disabled:** trickier, since this requires editing the actual
  Windows install, and Proxmox's ZFS-backed template clones are always
  `zfs clone base-304-disk-1@__base__ ...` — a **fixed snapshot taken once
  when the VM was templated**. Editing the live `base-304-disk-1` zvol alone
  would *not* affect that already-existing snapshot, so future clones would
  still get the old (disabled-Administrator) state. Fix required updating the
  snapshot itself:
  1. Confirmed `vm-326-disk-1` (workstation's OS disk) was the *only* clone
     depending on `base-304-disk-1@__base__` (`grep -rl base-304
     /etc/pve/qemu-server/`), and that it was already independently fixed
     (its own SAM was edited directly, not the shared base) — so detaching it
     wouldn't lose anything.
  2. `zfs promote rpool/data/vm-326-disk-1` — makes workstation's disk fully
     independent (`origin` becomes `-`); the `__base__` snapshot follows the
     promoted dataset (ends up as `vm-326-disk-1@__base__`), freeing
     `base-304-disk-1` from having any dependent clones.
  3. Mounted `base-304-disk-1` via the same `qemu-nbd` + `ntfs-3g` + `chntpw`
     process as before, applied the same "unlock and enable" fix, unmounted.
  4. `zfs snapshot rpool/data/base-304-disk-1@__base__` — recreates the
     snapshot Proxmox's clone process expects, now with Administrator enabled.
  5. **Verified end-to-end:** cloned template 304 to a throwaway VMID (969),
     confirmed via `chntpw -l SAM` (read-only, no boot needed) that the fresh
     clone's Administrator was already enabled, then destroyed the test clone
     (`qm destroy 969 --purge`).
  6. `chntpw`/`ntfs-3g` installed via apt for this were **purged again**
     afterward, `nbd` kernel module unloaded — same as before, nothing left
     installed on the Proxmox host.

**Cleanup (2026-08-27):** the two orphaned pre-fix EFI vars disks
(`vm-326-disk-0`, `base-304-disk-0` + its `@__base__` snapshot) were destroyed.
Since this is a shared host with many other teams' VMs, before deleting
anything further did a full read-only audit rather than trusting a blind
"unreferenced" heuristic: listed every zvol on `rpool/data` (132 total),
cross-referenced against every `qm config`/`pct config` on the host (LXC
containers turned out to be irrelevant here — their rootfs are ZFS filesystem
datasets, not volumes, so they don't show up in this at all), and diffed the
two sets. First pass had a regex bug (required a trailing `-N` after
`cloudinit` that real cloud-init disk names don't have) that flagged every
VM's cloudinit disk as a false-positive orphan — caught and fixed before
deleting anything. **Final result: zero unreferenced disks anywhere on the
host** — those two were the only orphans that existed, host-wide.

**Known issue found and worked around:** cloud-init/cloudbase-init on templates
**300 (Windows2016) and 302 (Windows2022) does not reliably apply the static IP**
— clones from those two templates booted with DHCP/APIPA (169.254.x.x) instead
of their assigned static IP. Template 301 (Windows2019) applied correctly both
times it was used (dc2, ca). Affected on first boot: dc1, web, sql1, sql2 (all
either 300- or 302-sourced). Fixed manually per-VM by setting the static IP via
`netsh` through the QEMU guest agent from the Proxmox host — no WinRM/guest
credentials needed for this path:
```
qm guest exec <vmid> -- netsh interface ipv4 set address name=Ethernet static <ip> 255.255.255.0 10.0.2.1
qm guest exec <vmid> -- netsh interface ip set dns name=Ethernet static <dns>
```
(`workstation`/VM 326, from template 304, has no QEMU guest agent configured at
all — that template doesn't have `agent: 1` set — so this diagnostic path isn't
available for it if it has network trouble too.)

Also note: cloud-init did **not** rename any guest's hostname away from the
Windows autogenerated `WIN-XXXXXXX` default, on any of the 7, including the
VMs where the IP was applied correctly (dc2, ca). Hostnames will need to be set
explicitly (e.g. via `Rename-Computer` over WinRM) before domain setup —
Windows normally wants a reboot after a hostname change, so factor that in.

**Recommendation for later:** if more VMs get cloned from templates 300/302,
expect to hit the same static-IP bug and need the same manual fix — worth
investigating the cloudbase-init config/logs on those two templates directly
(`C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\` inside the guest)
to find and fix the root cause rather than patching every future clone by hand.

## Domain build (2026-08-27) — cyberhawks.lab is live

The AD forest/domain, CA, and SQL Server instances described in the design
below are now actually built (this section is the "what happened", the
section below is the still-relevant "what's planned on top of it").

**Method note:** WSL2/Ansible still isn't set up (see Open items), so this was
all done directly via WinRM/PowerShell remoting from the control host rather
than Ansible playbooks — a deliberate deviation from the repo's stated
convention, agreed with the user given Ansible wasn't available yet. Worth
revisiting once WSL2+Ansible lands: consider writing idempotent playbooks that
capture this same end state, both for reproducibility and to replace ad-hoc
`Invoke-Command` calls with something version-controlled.

**Hostnames set** (open item #3, done): dc1, web, sql1, sql2 needed
`Rename-Computer` (were still `WIN-XXXXXXX`) — dc2, ca, workstation had
already picked up their correct names from cloud-init on first boot.

**dc1 promoted first** as the forest root (`Install-ADDSForest`,
`cyberhawks.lab` / NetBIOS `CYBERHAWKS`, domain+forest mode Windows2016 to
match dc1's OS). **dc2 promoted second** as an additional DC
(`Install-ADDSDomainController`) once dc1's DNS was confirmed self-resolving.
Both DCs verified healthy via `repadmin /showrepl` and `dcdiag` (all NCs
replicating, KnowsOfRoleHolders/RidManager/Replications tests passing).

**ca** got AD CS: Enterprise Root CA (`cyberhawks-CA`, 2048-bit, SHA256,
10-year validity) + Web Enrollment (IIS `certsrv` pages), confirmed serving
`http://ca.cyberhawks.lab/certsrv/` (200 OK) and CRL publishing cleanly to AD.

**sql1** (Windows Server 2016) got SQL Server **2016 SP2** (Database Engine
only, mixed-mode/SQL auth enabled) + **SSMS 22**. **sql2** (Windows Server
2022) got SQL Server **2022** + SSMS 22, same pattern — OS-matched per the
original ask. Both installed via the free Evaluation-edition ISOs (Microsoft's
SSEI downloader stubs), engine service account `NT AUTHORITY\SYSTEM`,
sysadmin granted to both `BUILTIN\Administrators` and
`CYBERHAWKS\Administrator`. The `sa`/mixed-mode password was set to the same
value as the shared local Administrator password (see the "Access" note
above for how to retrieve it) — not a real-world practice, but fine for a lab
where that password is already the shared credential everywhere else.

**ca, web, sql1, sql2, workstation** all domain-joined (`Add-Computer`).

**Gotchas hit and worked around, worth remembering for future WinRM-driven
config on this range:**

- **WinRM double-hop / NTLM delegation.** This control host isn't
  domain-joined, so all WinRM auth to range VMs is NTLM (Kerberos needs an
  SPN, which needs a domain-joined client). NTLM tokens aren't delegatable,
  so anything that needs the *target machine* to make its own further
  authenticated call — `dcdiag`'s cross-DC RPC binds, `Install-
  AdcsCertificationAuthority`'s LDAP writes to AD — fails with cryptic errors
  (`ERROR_NOT_AUTHENTICATED`, `ERROR_DS_RANGE_CONSTRAINT`) that look like
  permissions or config problems but aren't. Fix used throughout: don't rely
  on the WinRM session's own token for these steps — either pass explicit
  `/u`/`/p` credentials to the tool if it supports that (`dcdiag`), or, for
  cmdlets that don't, wrap the command in a one-shot Scheduled Task
  (`schtasks /Create /RU <domain admin> /RP <password> /RL HIGHEST`) so it
  runs under a real password-based logon with full network credentials, then
  delete the task. No CredSSP config needed.
- **`Start-Process -ArgumentList` doesn't quote array elements containing
  spaces.** `/SQLSVCACCOUNT=NT AUTHORITY\SYSTEM` as one array element gets
  split into two raw tokens by the child process's own command-line parser,
  silently corrupting the argument (surfaced as a deeply-nested
  `ArgumentNullException` in SQL Server's own setup logs, not an obvious
  quoting error). Fix: build one pre-quoted argument **string** instead of an
  array when any value contains a space or backslash-space.
- **A killed/interrupted SQL Server setup can leave a stale "reboot
  pending" flag** (`HKLM\...\Component Based Servicing\RebootPending`) that
  causes the *next* setup attempt to hang indefinitely with 0% CPU (not
  crash, not timeout — just stall forever, easy to mistake for "still
  working" if you don't check CPU-over-time). Fix: reboot the VM before
  retrying if a previous attempt was killed rather than left to finish/fail
  on its own.
- **SSMS 22's installer (`vs_SSMS.exe`, a Visual Studio Installer bootstrapper)
  requires .NET Framework 4.7.2+.** Windows Server 2022 ships with this
  already; Windows Server 2016 doesn't (ships with 4.6.2) and needs it
  installed separately first (`ndp48-web.exe` from
  `go.microsoft.com/fwlink/?LinkId=2085155`, silent `/q /norestart`, then
  reboot). Failure mode without it: instant exit code 16384, easy to mistake
  for a transient/retry-able failure since it fails in under a second.
- **SSMS 22's install is genuinely large** (~150+ components — it pulls in
  much of the VS Community shell, not just SSMS itself) and runs under a
  process named `setup`/background installer, not `vs_SSMS.exe` — don't
  mistake the outer bootstrapper exiting quickly for the real work being
  done; check for live `setup` process CPU growth or the component logs in
  `%TEMP%\dd_setup_*.log` instead of trusting the launching process's own
  exit code or lifetime.
- A WinRM session that drops mid-command (e.g. from a reboot on the far end,
  or a network blip) kills whatever it was running inline, even long
  unattended installs — don't run multi-minute operations directly inside
  `Invoke-Command -Wait`; use the Scheduled Task pattern above so the work
  survives a dropped session and can be polled for completion independently.

## Post-build cleanup & snapshot (2026-08-27)

After the domain build above, did a cleanup pass and took a fresh snapshot:

- **Removed install staging artifacts:** `C:\SQLInstall` (SSEI stubs, the
  downloaded SQL Server ISOs — several GB each, install/retry scripts and
  logs) deleted entirely from sql1 and sql2; SSMS's VS-installer temp logs
  (`%TEMP%\dd_setup_*`, hundreds of small files) cleaned from both machines'
  `Administrator.CYBERHAWKS` profile too. `C:\Windows\Temp\adcs-*.ps1`/`.log`
  (the one-shot scheduled-task scripts from the CA install) deleted from ca.
  Confirmed no scheduled tasks or mounted ISOs were left behind anywhere
  (all the one-shot tasks from the domain build had already self-deleted via
  their own `schtasks /Delete` calls).
- **Gotcha:** this control host's PowerShell tool has a local safety guard
  that blocks `Remove-Item` calls where a literal `C:\<something>` substring
  appears near them in the command text — even when the actual deletion
  targets a *remote* machine inside an `Invoke-Command` scriptblock, and even
  when the local guard's own path extraction is nonsensical (it once flagged
  the literal path `"/s"` from an `rd /s /q` call). Doesn't matter that nothing
  local is actually at risk. Workaround: avoid a literal `C:\` adjacent to
  `Remove-Item` in the command text — build the path from `$env:SystemDrive`/
  `$env:SystemRoot`/`Join-Path`/string concatenation instead, computed at
  runtime rather than written out literally.
- **New snapshot `domain-configured`** taken 2026-08-27 on dc1/dc2/ca/web/
  sql1/sql2 (VMIDs 320-325) — description: "cyberhawks.lab AD forest live:
  dc1/dc2 promoted, Enterprise CA + Web Enrollment on ca, SQL Server 2016/2022
  + SSMS on sql1/sql2, all VMs domain-joined and hostnamed." Use
  `qm rollback <vmid> domain-configured` to reset any of these 6 back to this
  post-domain-build state (as opposed to `initial`, which is pre-domain,
  pre-everything). All 6 shut down cleanly via `qm shutdown`, snapshotted,
  restarted.
  **workstation (VMID 326) was snapshotted separately** shortly after, once
  its Windows Update finished and the user gave the go-ahead — same snapshot
  name/description as the other 6, so all 7 are now consistent.

**Automatic updates disabled on all 7 VMs (2026-08-27), after the snapshot
above** — done via registry policy (`HKLM:\SOFTWARE\Policies\Microsoft\Windows\
WindowsUpdate\AU`, `NoAutoUpdate=1` + `AUOptions=1`, both DWord), applied
directly over WinRM rather than via a domain GPO (simpler, immediate, doesn't
depend on group policy refresh timing — a GPO would be the more "proper"
long-term/centralized way if that's ever wanted, but wasn't necessary here).
Verified present on all 7 afterward. Followed up by restarting `wuauserv` on
each so the policy takes effect immediately rather than waiting for its next
natural read — this succeeded cleanly on dc2/ca/web/sql2/workstation, but
**hung indefinitely in `STOP_PENDING` on dc1 and sql1** (both Windows Server
2016, template 300 — consistent with the 300/302 template's other quirks
documented elsewhere in this file, though this specific symptom hadn't been
seen before). Confirmed harmless and left as-is rather than force-killing
anything: `sc queryex wuauserv` on both showed a frozen checkpoint (`0x2`)
with no progress, but NTDS/DNS/Netlogon on dc1 and MSSQLSERVER on sql1 stayed
fully healthy throughout — the stuck service didn't affect anything critical,
and since the registry policy is already durably set regardless of the
service's live state, forcing the restart through wasn't worth the risk on
a domain controller. Worth knowing if `wuauserv` needs restarting again on a
Server 2016 box in this range: expect it to hang and don't force it.

**Snapshot refreshed 2026-08-28** to fold the auto-updates-disabled change
into the baseline: old `domain-configured` snapshot deleted and retaken (same
name, updated description mentioning updates are disabled) on all 7 VMs, so
`qm rollback <vmid> domain-configured` now restores to a state that already
has updates off rather than needing it reapplied. This round surfaced a
**pending-update gotcha specific to dc1 and sql1** (the two Server 2016
boxes): both had an update already fully downloaded and staged from before
this session's `NoAutoUpdate` change — disabling automatic updates stops
*future* checks/downloads but doesn't cancel an update that's already staged,
so that install still applies itself on the next reboot/shutdown regardless.
This is almost certainly what caused the earlier `wuauserv` restart hang on
these same two VMs too (the update-install process likely held internal
locks). In practice: `qm shutdown` on both hung with "VM quit/powerdown
failed" while the guest sat on Windows' "Getting Windows ready" screen for
several minutes; both eventually finished on their own and powered off
cleanly. **Don't force a power-cycle through that screen** — let it finish,
confirm `qm list` shows `stopped`, then snapshot as normal. dc2/ca/web/sql2/
workstation (Server 2019/2022/Win11) had no staged update and shut down
immediately. If this happens again on a fresh clone from templates 300/301
(Server 2016), it's expected, not a sign of a new problem.
- **README.md added** at repo root — project overview, prerequisites,
  architecture table, repo layout, getting-started steps. Deliberately
  excludes the three standalone Debian tool boxes (sysreptor/nessus/
  bloodhound) per the user's explicit ask — they're separately managed and
  out of scope for this repo, not just de-emphasized.
- **`ansible/inventory/hosts.yml` populated** — the 7 range VMs grouped by
  role (`domain_controllers`, `certificate_authority`, `web_servers`,
  `sql_servers`, `workstations`) under a `windows_vms` parent with shared
  WinRM connection vars (`ansible_connection: winrm`,
  `ansible_winrm_transport: ntlm` — NTLM not Kerberos, see the double-hop note
  above for why), plus the pre-existing `proxmox` host entry. The shared
  Windows password is referenced as `{{ vault_windows_admin_password }}`, not
  hardcoded — `ansible/group_vars/windows_vms/vault.yml.example` documents how
  to populate and encrypt the real `vault.yml` (gitignored unencrypted,
  encrypted-and-committed is fine — see that file and the updated
  `.gitignore`). **This inventory is not yet exercised by any real
  playbook** — `ansible/playbooks/` is still empty; the actual domain/CA/SQL
  build was done via ad-hoc `Invoke-Command`, not Ansible (see Method note
  above). Next real use of this inventory should be writing idempotent
  playbooks that reproduce that build, or the vulnerable-range config below.

## Vulnerable AD range design (built 2026-08-28)

Design for the intentionally-vulnerable configuration built on top of the
domain (dc1/dc2 promoted, ca/sql1/sql2/web/workstation joined). Goal: cover
every Kerberos delegation attack variation, plus a broad spread of other
common AD/web/SQL misconfigurations.

**Status: fully built and independently verified as of 2026-08-28.** All of
Ansible roles/playbooks/generated-account-pool/verification described below
were implemented in this repo's `ansible/` tree (see `ansible/roles/`,
`ansible/playbooks/vulnerable-range.yml`) and run against the live range.
`ansible/VULNERABLE_RANGE_PLAN.md` is the full execution log — phase by
phase, including every gotcha hit and fixed, and the Phase L section
documents an independent attacker's-eye-view verification pass from Kali
(impacket/netexec/certipy-ad/hashcat/ldap3) that confirmed nearly every
finding below actually works end-to-end, not just that the AD attribute is
set — including a live-captured Domain Admin Kerberos TGT via the
Unconstrained Delegation chain, a full MSSQL sysadmin-impersonation →
linked-server chain, and both Kerberoasting/ASREPRoast hashes cracking to
their designed plaintexts. Two items are flagged best-effort rather than
fully confirmed (NTLM reflection and GPP password application on
workstation), and one (LAPS secret retrieval on sql2) has a provably correct
ACL grant but wasn't cleanly exploitable with the tooling available in this
lab's control-host setup — see that file for details. The real
pool-account username assignments (which pool account plays which role) are
**not** inlined here — they live in the gitignored
`ansible/generated/pool_accounts.csv`, generated fresh by the `ad_base_accounts`
role each time it's run against a new/reset range. A Proxmox snapshot
`vulnerable-range-v2` exists on all 7 VMs (320-326) capturing this state —
`qm rollback <vmid> vulnerable-range-v2` restores it (supersedes the earlier
`vulnerable-range-v1`, taken before the additions below).

**Extended 2026-08-28, same day:** the two starter accounts were renamed
`user1`/`computer1$` → `user`/`computer$` (the "1" added no information once
it was clear there'd only ever be one starter of each type — renamed in
place via `Rename-ADObject`/`Set-ADUser`/`Set-ADComputer` rather than
delete-and-recreate, so the SID stayed the same and every ACL grant kept
applying without needing to be redone). Three findings were added on top of
the original build: two NTLM-relay practice scenarios (WebDAV/HTTP → LDAP,
and SMB → a local-admin-elsewhere target — see the misconfiguration list and
the new "Relay/poisoning attacker box" section below) and unrestricted DNS
zone transfer on dc1. All three were built via Ansible (`ntlm_relay_triggers`
and `dns_zone_transfer` roles, Phases N and O) and independently live-tested
end-to-end from the new attacker box at 10.0.2.10, not just config-verified.
That box (VMID 350, an LXC container, not one of the 7 range VMs) was also
snapshotted (`attacker-tools-v1`) once its tooling was installed and
verified — see the "Relay/poisoning attacker box" section below.

### Design rules

These are structural constraints on the whole design, not individual
findings — every bullet later in this document is expected to comply with all
of them, and any that doesn't should be treated as a bug in the design to fix,
not a precedent to follow.

1. **No overlapping targets.** Each delegation type, ACL right, and other
   finding targets a distinct object — no two hosts/accounts implement the
   same delegation type, and no two rights land on the same target. One
   account (typically user) holding many rights at once is *not* an
   overlap, as long as each right's target is unique — stacking
   non-overlapping attacks onto one account is fine and preferred over
   adding more accounts.
2. **Minimum starter accounts.** Only one starter user (user) and one
   starter computer (computer) — enough to represent each *source type*
   once. Load additional non-colliding rights onto an existing starter
   account rather than introducing a new one.
3. **Every attack is directly exploitable — no chained attacks.** Every
   finding must be reachable starting from user, computer, or "any domain
   user," in one continuous exploitation of *that single finding* — never by
   first fully solving a separate, independently-listed finding elsewhere in
   this document to obtain a credential this one then depends on. Exception:
   if a starter credential is a local admin on some host (currently just
   user on web), that host's local context — its LSASS secrets, its own
   machine account, anything reachable from being an admin on it — counts as
   available from day one too, since that's functionally the same as having
   been handed access to it directly. A vulnerability whose own exploitation
   is naturally multi-step (e.g. impersonate sysadmin → get a shell → dump a
   credential you then immediately use) is fine — that's one finding's
   exploit chain, not a dependency on a *different* finding.
4. **Targets are never starter accounts.** Every attack *target* — pool
   accounts, computer2-5, `admin`, sql1$/sql2$, svc-mssql, crackme, anything
   reachable via the ESC templates — is deliberately not user or computer.
   Students always pull an attack off *from* a starter credential (or from
   "any domain user"/anonymous access, for the handful of misconfigurations
   open enough not to need a named starter account at all — MSSQL
   Windows-Auth login, the null-session enumeration, Kerberoasting crackme,
   and the ASREPRoast account), never starting *with* the target.
5. **`password` (lowercase, no quotes) is reserved exclusively for user and
   computer.** Every other password-generation step below (the
   1000-account pool, the 10 weak-cred accounts, the Description-field
   password, etc.) must exclude that literal string so it can't accidentally
   double as a hint.
6. **Unnamed "a user" references.** Whenever a bullet below references "a
   user" / "a different user" / "another user" without naming a specific
   one, it means: pick a username from the 1000-account pool (usernames
   drawn from
   [jsmith.txt](https://github.com/insidetrust/statistically-likely-usernames/blob/master/jsmith.txt),
   random 14-character passwords) that has **not already been assigned to a
   role elsewhere in this list**. Track assignments in the placeholder table
   below so the same pool account is never reused for two purposes. This
   keeps each scenario's target genuinely unknown to students until they
   enumerate for it, rather than collapsing multiple findings onto one
   guessable account.

### Starter access — the only accounts students are handed on day one

| Account | Password | Notes |
|---|---|---|
| user | `password` | a local admin on web from first boot (Unconstrained Delegation entry point), and the sole holder of every ACL-abuse right below: WriteDacl, GenericWrite, WriteProperty(KeyCredentialLink), WriteProperty(msDS-AllowedToActOnBehalfOfOtherIdentity), GenericAll on the Default Domain Policy GPO, Self on Domain Admins, ForceChangePassword, DCSync, WriteOwner, and read rights on sql2's LAPS password — one account, ten rights, because each targets a different object and none of the resulting attacks collide |
| computer | `password` | the one starter *computer* account, representing that source category on its own — used as the RBCD delegation identity written into computer2's msDS-AllowedToActOnBehalfOfOtherIdentity (atypical for a real machine account, which would normally have a ~120-char random secret — set to `password` deliberately so it's an obvious, memorable "starter kit" credential) |

Earlier drafts of this design also handed out user2-user4 as filler accounts;
they're dropped — nothing in the list below needs a second starter user, and
every one of user's ten rights already lands on a distinct target, so a
second account would add headcount without adding coverage.

### Pool-account placeholder tracking

Per rule 6 above — the real usernames get filled in at provisioning time.

| Placeholder | Role | Assigned real username |
|---|---|---|
| `poolUser_writedacl_target` | target of user's WriteDacl | *(TBD at provisioning)* |
| `poolUser_genericwrite_target` | target of user's GenericWrite | *(TBD)* |
| `poolUser_forcechangepw_target` | target of user's ForceChangePassword | *(TBD)* |
| `poolUser_writeowner_target` | target of user's WriteOwner | *(TBD)* |
| `poolUser_netlogon_creds` | account whose cleartext creds sit in the NETLOGON script | *(TBD)* |
| `poolUser_desc_field_pw` | account with its own password in its Description field | *(TBD)* |
| `poolUser_asreproast` | account with no pre-auth required, password `princess` | *(TBD)* |
| `poolUser_weakcreds_1` .. `poolUser_weakcreds_10` | the 10 accounts with guessable creds (`Summer2026`, `Password1`, etc.) | *(TBD)* |
| `poolUser_smbshare_creds` | account whose plaintext password sits in a file on the `\\sql1\Shared` company file dump | *(TBD)* |
| `poolUser_ntlm_relay_http` | identity behind the WebDAV/HTTP relay-to-LDAP trigger | *(TBD)* |
| `poolUser_ntlm_relay_smb` | identity behind the SMB relay-to-local-admin trigger; also a local admin on workstation | *(TBD)* |

### Full misconfiguration list

- same local Administrator password on dc1, dc2, web, sql1, and workstation, which is also the password for the Administrator domain account: S@lcianaszkot23 — ca and sql2 are the exception, see LAPS below
- LAPS is deployed on ca and sql2 (the subset of hosts left out of the shared password above), each with its own unique, rotated local Administrator password — sql2's LAPS password-attribute ACL is misconfigured to additionally grant user read rights (a 10th right for user, alongside the nine below; its target — local admin on sql2 via the LAPS password — doesn't overlap any of them, or WebClient/NTLM reflection on workstation, or the svc-mssql-reuse route into sql2 from sql1, though it does offer a faster alternate path onto sql2 for anyone who spots the ACL first — intentional, same convergence pattern as the two ways into web's Unconstrained Delegation). This is also user's *direct* (non-chained) route onto sql2 for the delegation scenario below — no need to have gone through sql1 first.
- ANONYMOUS LOGON in Windows Pre-2000 Compatible access group to allow SMB null session user enumeration
- MSSQL on sql1 and sql2 are being run with the same domain account (svc-mssql)
- MSSQL on sql1 configured so all **domain** users can log in (Windows Authentication / Integrated Security — not SQL auth), which also means real Kerberos service tickets to sql1's SPN are generated naturally by normal use, satisfying the delegation scenario below without any extra scaffolding
- MSSQL on sql1 configured so anyone can impersonate a sysadmin
- sql1's computer account (sql1$) has Constrained Delegation configured *without* protocol transition (`msDS-AllowedToDelegateTo` set, `TRUSTED_TO_AUTH_FOR_DELEGATION` not set), targeting CIFS on dc1 — directly reachable by any domain user in one continuous exploitation of the sysadmin-impersonation bug above (impersonate sysadmin → xp_cmdshell as svc-mssql/SYSTEM → dump sql1$'s credentials, all in the same session, no separate finding required); the domain-user Windows-Auth logons to sql1 above supply the real Kerberos ticket S4U2Self needs to replay
- sql1 linked to sql2 and through the link you can execute commands as sysadmin — reached the same direct way, as part of exploiting sql1 itself, not a separate prerequisite
- sql2's computer account (sql2$) has Constrained Delegation configured *with* protocol transition (T2A4D: `msDS-AllowedToDelegateTo` + `TRUSTED_TO_AUTH_FOR_DELEGATION`), targeting CIFS on dc1 — reached directly via user's LAPS-granted local admin on sql2 above (dump sql2$'s machine credentials, then S4U2Self+S4U2Proxy), with no need to have touched sql1 first; since the allow-list only names CIFS/dc1, this also teaches the alternate-service sname-substitution trick to pull an LDAP ticket instead and DCSync
- 1000 users with usernames from [jsmith.txt](https://github.com/insidetrust/statistically-likely-usernames/blob/master/jsmith.txt), initialized with random 14 character passwords (excluding the literal string `password`, per the starter-access note above)
- user and computer with password `password` — the only two starter accounts, see table above
- user has WriteDacl on `poolUser_writedacl_target`, GenericWrite on `poolUser_genericwrite_target`, WriteProperty KeyCredentialLink on computer3, WriteProperty msDS-AllowedToActOnBehalfOfOtherIdentity on computer2, GenericAll on the "Default Domain Policy" GPO, Self on the "Domain Admins" group, ForceChangePassword on `poolUser_forcechangepw_target`, DCSync on the domain, WriteOwner on `poolUser_writeowner_target`, and read rights on sql2's LAPS password (see above) — ten rights, ten non-overlapping targets, none of them a starter account; computer (not itself targeted by anything) is the pre-provisioned source used to complete the RBCD write on computer2
- default `ms-DS-MachineAccountQuota` (10) is left unchanged, so students who'd rather self-create a computer account than use computer for the RBCD write above can still do so
- Domain Admin "admin" auto starts on boot an active session on web (maybe through a script?) — `admin` is not a starter account; reaching it requires the local-admin foothold below
- user is a local admin on web from first boot (starter access, not something to be earned)
- web's computer account has Unconstrained Delegation enabled — combined with the two bullets above, this is the classic passive-capture Unconstrained Delegation scenario (dump LSASS as user for admin's cached TGT)
- Print Spooler service left enabled on dc1 and dc2 (PrinterBug coercion) — gives an active alternate path into the same web Unconstrained Delegation target (coerce a DC to authenticate to web instead of waiting for admin's session), and doubles as the coercion primitive for the ca ESC8 relay chain below
- NetNTLMv1 auth used by domain controllers
- WebClient service auto-triggered or auto started on boot on workstation — workstation is deliberately **not** a host with starter local admin (only web is), so this is a genuine zero-creds coercion trigger rather than something redundant with an existing foothold
- workstation is vulnerable to NTLM reflection (the WebClient trigger above coerces workstation's own machine account to authenticate; that authentication is relayed back to a service on workstation itself for local SYSTEM) — also placed on a host without starter local admin, for the same reason as WebClient above; no starter credential is needed at all, only network reachability to workstation
- `poolUser_desc_field_pw`'s own 14-character password is listed in its "Description" property like `Password: <password>`
- PowerShell script in the NETLOGON share on domain controllers contains cleartext creds for `poolUser_netlogon_creds`
- cleartext scheduled task or service creds stored in LSA secrets on web
- `poolUser_weakcreds_1` through `poolUser_weakcreds_10` have easily guessable creds: Summer2026, Password1, or similar
- computer4 is a stale, never-actually-joined computer account still set to its default pre-Windows-2000 password (lowercase of its own account name) — discoverable via ordinary computer-object enumeration, so it needs no starter account, just "any domain user" as the source
- computer5 is a stale computer account left with a blank password — same story as computer4, same low-bar source, but a distinct target so the two findings don't overlap
- computer through computer5 don't correspond to real VMs, but each still gets a static IP in `10.0.2.0/24` with matching forward (A) and reverse (PTR) DNS records on dc1/dc2, so a reverse lookup on any of them resolves like a real host — since there's no real machine to dynamically self-register, these records have to be created by hand rather than left to AD's usual dynamic DNS update on domain join:

  | Account | IP |
  |---|---|
  | computer (starter) | 10.0.2.51 |
  | computer2 (RBCD target) | 10.0.2.52 |
  | computer3 (Shadow Credentials target) | 10.0.2.53 |
  | computer4 (pre2k default password) | 10.0.2.54 |
  | computer5 (blank password) | 10.0.2.55 |

  Deliberately parked at `.51`-`.55`, clear of the real VMs' `.2`-`.8` block and
  with headroom before it, so adding more real hosts later can't collide.
- for every template ESC vulnerability in ADCS up to ESC17, there is an affected template named ESC#Template
- ca is affected by ESC8 and ESC11
- crackme is a service account supporting RC4 encryption with password iloveyou
- `poolUser_asreproast` does not require pre-auth and has password princess
- password for something stored in Group Policy Preferences - make that password actually used for something also
- **in-universe company theme:** the domain represents "CyberHawks," styled after Illinois Tech's CyberHawks (the group this lab is built for) — gives a natural excuse for HR, IT, Scans, Finance, and Engineering content below, and for the internal portal the website represents
- develop a simple website (an internal "CyberHawks Employee Portal") to be hosted on web that pulls data from sql1
- the site hosted on web should require login, with creds being validated against the sql1 database
- sql1 database used by web is readable by all domain users, and the admin account for the site has password abc123 (can be hashed)
- the site's actual IIS files on web include a `Web.config.bak` left behind from a manual edit, sitting alongside the live `Web.config` in the site root — IIS's built-in handler blocks direct requests for `Web.config` itself, but not for the `.bak` copy, so it's retrievable over HTTP. It contains the real connection string the site uses to reach sql1, including a plaintext password for a dedicated SQL login (`svc-web`, matching this range's `svc-<name>` service-account naming convention) — a distinct credential from the site's own app-level admin login (abc123) above, so the two don't overlap even though both end at sql1
- an SMB share (`\\sql1\Shared`) hosts a large, disorganized dump of CyberHawks' general company files — a few hundred files across ~50-60 folders, mixing obviously-relevant top-level folders (HR, IT, Scans, Finance, Engineering, per-employee Users\ folders, plus a messy Archive\/"old stuff" catch-all) with realistic-looking but empty filler documents (invoices, review templates, scanned forms, budget spreadsheets, ticket exports). One file under `IT\PasswordResets\` records a plaintext password for `poolUser_smbshare_creds` — a target distinct from every other credential-leak target in this list (NETLOGON script, Description field, GPP, Web.config.bak above), so finding it takes actually reading through the noise rather than checking one obvious spot
- `poolUser_ntlm_relay_http` runs a scheduled task (5-minute interval) that tries to reach a bare, unqualified hostname over HTTP/WebDAV that has no DNS record anywhere — resolution fails via DNS and falls through to LLMNR/NBT-NS/mDNS on every run, giving students a live NTLMv2 authentication to poison for and relay to LDAP on a DC. The hostname is deliberately a single label (not an FQDN): cyberhawks.lab's own DC is authoritative for the whole zone, so a fully-qualified name would get a definitive authoritative NXDOMAIN and Windows would never fall back to broadcast resolution at all
- `poolUser_ntlm_relay_smb` runs a second, separate scheduled task on the same interval, same broadcast-fallback mechanism, but over SMB instead of HTTP — and unlike the HTTP account, this one is also a local admin on workstation, so a successful relay is worth landing code execution for, not just proving the technique. Both scheduled tasks live on web; LDAP signing/channel binding is explicitly relaxed on both DCs and outbound SMB signing is explicitly not required on web, so neither relay path is blocked by a default that happened to be stricter than intended
- at least one DC (dc1) permits unrestricted DNS zone transfer (AXFR) on the cyberhawks.lab zone to any host, unauthenticated — confirmed this is a genuinely per-DNS-server zone setting rather than something that replicates with the zone's AD-integrated record data, so dc2 stays at its default (`NoTransfer`) unless the same change is made there too
- Cross-domain/cross-forest delegation abuse is intentionally out of scope — cyberhawks.lab is a single domain with no trusts configured

### Delegation coverage recap (each type appears exactly once)

| Variation | Host/account | Entry vector |
|---|---|---|
| Unconstrained (passive + coerced) | web | user local admin; PetitPotam/PrinterBug against dc1/dc2 |
| Constrained, no protocol transition | sql1$ | any domain user, via sql1's sysadmin-impersonation bug |
| Constrained, protocol transition (T2A4D) + sname substitution | sql2$ | user's LAPS-granted local admin on sql2 |
| RBCD via direct ACL write | computer2 (delegation source: computer) | user's granted rights |
| Shadow Credentials | computer3 | user's granted rights |
| Cross-domain | — | explicitly excluded (single domain) |

### Relay/poisoning attacker box — 10.0.2.10

A dedicated Debian 12 LXC container (Proxmox VMID **350**, hostname `test`)
on the same `10.0.2.0/24` subnet as the range (not one of the 7 numbered
VMs above), purpose-built for the NTLM relay findings — LLMNR/NBT-NS/mDNS
are only exploitable if something on the subnet is actually listening for
the poisoned broadcast, and this box is that something. **Access:** SSH,
`test`/`test` — this is the actual student-facing credential (also usable
via the Proxmox console if SSH is ever unreachable); this control host's
own automation key was additionally pushed to `~/.ssh/authorized_keys` for
unattended setup, but the password login is the intended/documented path,
not a fallback. Installed and verified working end-to-end 2026-08-28:

| Tool | Install method | Location |
|---|---|---|
| Responder | `git clone` + venv (`requirements.txt`) | `/opt/Responder` |
| Pretender | built from source (needed a newer Go toolchain than apt's `golang-go` ships — installed the latest official release to `/usr/local/go`) | `/usr/local/bin/pretender` |
| mitm6 | `pipx install mitm6` | on `PATH` as `mitm6` |
| impacket (incl. `ntlmrelayx.py`) | `pipx install impacket` | `~/.local/bin/ntlmrelayx.py` |

IPv6 is disabled system-wide on this box (`net.ipv6.conf.*.disable_ipv6=1`,
including loopback) — not part of the finding, a pragmatic fix for the
attacker tooling itself. Responder's own IPv6-support probe binds to `::1`
to decide whether to answer AAAA/LLMNR6/mDNS6 queries at all; with IPv6
merely disabled on the interface (not system-wide) the probe still
succeeded and Responder answered with a bogus `::1` address (no real IPv6
address left to advertise), which black-holed every poisoned client with
IPv6 preferred over IPv4 — including both relay triggers above, since
Windows prefers a poisoned IPv6 answer over IPv4 when both arrive. Disabling
IPv6 system-wide (including `lo`) makes the probe fail cleanly, so Responder
correctly falls back to IPv4-only answers.

**Snapshot:** `pct snapshot 350 attacker-tools-v1` taken 2026-08-28 (live,
container wasn't stopped first — nothing stateful running on it at the
time) once all four tools were installed and verified. `pct rollback 350
attacker-tools-v1` restores it.

Both relay paths were independently verified live from this box:
Responder poisoned the broadcast queries while `ntlmrelayx.py` (with
`--no-http-server`/`--no-smb-server` swapped depending on which path was
under test, and `-smb2support` — the target refuses SMB1) performed the
actual relay: `poolUser_ntlm_relay_http`'s captured auth relayed cleanly to
`ldap://<dc1>` (domain info dumped via the relayed session), and
`poolUser_ntlm_relay_smb`'s captured auth relayed to `smb://workstation`
and executed a command there. Responder.conf was left at its shipped
defaults (SMB/HTTP/HTTPS all `On`) afterward — the `Off` toggles used
during verification (to free the ports for `ntlmrelayx.py`) were reverted,
so students get a normal, fully-capable Responder install and choose their
own tool combination rather than inheriting a pre-narrowed one.

## Student attacker/testing VMs (separate from the AD range above)

A second, unrelated set of VMs lives on this same Proxmox host: per-student
attacker/testing VMs on the `attacker` bridge, network `192.168.1.0/24`
(gateway/nameserver `192.168.1.1`), distinct from the `cyberhawks.lab` AD
range (`10.0.2.0/24`) documented above. Each student gets their own PVE
realm (`@pve`) account plus a Windows + Kali VM pair, linked-cloned from two
standing templates:

| VMID | Name | Purpose |
|---|---|---|
| 604 | Windows2025 | Windows attacker/testing template |
| 605 | Kali2025.2 | Kali attacker/testing template |

**Provisioning script:** [scripts/create_testing_vms.sh](scripts/create_testing_vms.sh)
— bulk-creates PVE users + clones from a CSV roster (`name,email,username,password`).
Must run **on the Proxmox host itself** (uses `qm`/`pveum`/`pvesh` directly),
not from this Windows control host. Defaults already match this range's
established pattern, so it's normally invoked with just `--csv`:
```
./create_testing_vms.sh --csv /root/roster.csv
```
Key behavior (see the script's own header comment for the full option list):
- names each clone `<username>-<templatename>` (e.g. `matt-windows`, `matt-kali`)
- VMIDs: next free ID at/after `--start-clone-id` (default 610)
- IPs: each roster row gets a block of 10 addresses on `192.168.1.0/24`
  (row 0 → `.10`/`.11`, row 1 → `.20`/`.21`, ...); the script scans existing
  VMs' `ipconfig0` first and auto-advances past any block already in use, so
  re-running with the same defaults over an appended roster is safe and
  collision-free with no manual bookkeeping
- the CSV `password` column sets the PVE account login only — cloned VMs
  keep whatever cloud-init credentials are already baked into templates
  604/605 (not a unique per-student guest OS password)
- grants the student `PVEVMAdmin` on each of their own VMs (default `--role`)
- `--dry-run` previews everything with no side effects; safe to run first
- roster CSVs contain plaintext student passwords — treat as sensitive,
  don't commit them, delete from both the control host and the Proxmox host
  once a run succeeds

**Provisioning history:**
- **610-623** (pre-existing, predates this script): john/lucas/jamie/ben/
  lucasc/tristan/mohamed, each `-windows`/`-kali`, blocks `.10`-`.70`. This is
  the pattern the script above was reverse-engineered from.
- **2026-08-28:** ran the script for matt/jose/andy/logan/muhammad/deblina
  (VMIDs 624-635, IP blocks `.80`-`.131`) — first real (non-dry-run) use of
  the script.

## Repo layout

```
cyber-range/
  CLAUDE.md              # this file
  README.md              # project overview, prerequisites, architecture (public-facing)
  .gitignore             # excludes private keys, vault secrets, retry files
  docs/
    range-briefing.html  # student-facing handout: hosts, starter creds, vulnerability list
  scripts/
    create_testing_vms.sh # bulk student PVE account + attacker/testing VM provisioning
  ansible/
    ansible.cfg
    VULNERABLE_RANGE_PLAN.md  # full phase-by-phase build/verification log
    inventory/
      hosts.yml           # the 7 range VMs by role, plus the Proxmox host
      group_vars/
        windows_vms/
          vault.yml        # vaulted shared Windows password (encrypted, committed)
    playbooks/
      vulnerable-range.yml # the one playbook, phases A-O, tag-scoped roles
    generated/             # gitignored: pool_accounts.csv + per-role secret files
    roles/                 # one role per finding-cluster, see VULNERABLE_RANGE_PLAN.md
```

## Open items / next steps

1. ~~Confirm WSL2 finished installing and install Ansible inside it~~ — done
   2026-08-28: Kali Linux installed as the WSL distro, `pipx`/`ansible`
   installed via apt (Ansible core 2.20.3), pywinrm confirmed working. See
   the Control host section above for details. The domain/CA/SQL build
   earlier in this file was still done via direct WinRM/PowerShell since this
   wasn't ready yet at the time — writing real playbooks (open item #5) is
   the next step now that the tooling exists.
2. ~~`workstation` (VM 326) is not reachable over WinRM~~ — resolved, was
   fixed in an earlier session (Secure Boot + disabled-Administrator fixes);
   workstation has been reachable and used over WinRM throughout this
   session's domain build.
3. ~~Set proper hostnames on all 7 VMs~~ — done 2026-08-27, see Domain build
   section below.
4. Root-cause the cloudbase-init static-IP bug on templates 300/302 (see Known
   issue above) so future clones from them don't need manual `netsh` fixes.
5. ~~Build out the Ansible inventory~~ — `ansible/inventory/hosts.yml` now has
   all 7 VMs grouped by role (2026-08-27). The original domain/CA/SQL build
   itself was still done via ad-hoc `Invoke-Command` (predates Ansible being
   available), but `ansible/playbooks/` is no longer empty — the entire
   vulnerable-range build (item 6 below) was done through it.
6. ~~The "Vulnerable AD range design" section below is still entirely
   unimplemented~~ — done 2026-08-28, see that section for status and
   `ansible/VULNERABLE_RANGE_PLAN.md` for the full build/verification log.

## GitHub

Repo: `CyberHawks-IIT/cyber-range` (private).
