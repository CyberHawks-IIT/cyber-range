# Cyber Range

A personal cyber range for practicing identification and remediation of
common vulnerabilities — primarily Active Directory misconfigurations and
Kerberos delegation abuse, plus adjacent web/SQL findings, all tied together
under a single in-universe company theme ("CyberHawks").

The range is a 7-VM Windows Server/AD environment (`cyberhawks.lab`) hosted on
a Proxmox server and managed from a Windows control host over a NetBird VPN.
This repo holds the Ansible code used to provision/configure the range, plus
[CLAUDE.md](CLAUDE.md), which is the running source of truth for project
context, decisions, and known issues across sessions.

## Prerequisites

### Control host

A Windows machine with:

- **OpenSSH client** (built into Windows 11) — SSH access to the Proxmox host.
- **[PuTTY](https://www.putty.org/) / `plink`** — only needed for one-off
  password-authenticated bootstrapping (e.g. initial SSH key push), since
  Win32-OpenSSH's `ssh` can't be scripted against a password prompt.
- **[GitHub CLI](https://cli.github.com/)** (`gh`) — for repo/PR operations.
- **WSL2 + Ansible** — the intended way to drive provisioning
  (`ansible-playbook` against `ansible/inventory/hosts.yml`). Requires
  `pywinrm` inside the WSL2 environment for the `winrm` connection plugin
  Ansible uses to reach the Windows VMs.
- An SSH keypair for range hosts (private key gitignored, never committed)
  authorized on the Proxmox host and any Linux support hosts.
- **[NetBird](https://netbird.io/)** (or equivalent) VPN client, joined to the
  same network as the Proxmox host — this routes directly to every VM's IP,
  no separate SSH tunnel or jump host needed.

### Proxmox

- A Proxmox VE host reachable over SSH (key-only) from the control host, with
  enough capacity for 7 Windows VMs (4 vCPU/4GB RAM each by default; sql1 and
  sql2 sized up to 48GB disk, the rest at 32GB).
- Windows Server 2016/2019/2022 and Windows 11 cloud-init/cloudbase-init
  templates already built and available for cloning (this project doesn't
  build the templates themselves — see [CLAUDE.md](CLAUDE.md) for the
  specific templates used and known cloudbase-init quirks on them).

### Windows access

All 7 range VMs are managed over **WinRM** (`Invoke-Command` /
`ansible.windows` modules), authenticating as the local `Administrator`
account. The control host needs `WSMan:\localhost\Client\TrustedHosts` set to
include the 7 VM IPs (see [CLAUDE.md](CLAUDE.md) for the exact list). Because
the control host isn't itself domain-joined, WinRM auth to the range is NTLM,
not Kerberos — this has real implications for anything that needs the target
machine to make its *own* further authenticated call (see the "WinRM
double-hop" note in CLAUDE.md before writing new automation against this
range).

Credentials aren't stored in this repo. Retrieve the current shared local
Administrator password (also used for the domain `Administrator` account and,
on sql1/sql2, the SQL Server `sa` login) by running this on the Proxmox host:

```
qm cloudinit dump <vmid> user
```

## Architecture

Single AD forest/domain **`cyberhawks.lab`** (NetBIOS `CYBERHAWKS`), on the
Proxmox `ad` bridge, network `10.0.2.0/24`, gateway `10.0.2.1`.

| Name | Role | OS | IP | Key software |
|---|---|---|---|---|
| dc1 | Domain controller (forest root) | Windows Server 2016 | 10.0.2.2 | AD DS, DNS |
| dc2 | Domain controller (additional) | Windows Server 2019 | 10.0.2.3 | AD DS, DNS |
| ca | Certificate authority | Windows Server 2019 | 10.0.2.4 | AD CS — Enterprise Root CA (`cyberhawks-CA`) + Web Enrollment (IIS `certsrv`) |
| web | Web server | Windows Server 2022 | 10.0.2.5 | IIS (planned: internal "CyberHawks Employee Portal" site, see CLAUDE.md) |
| sql1 | Database server | Windows Server 2016 | 10.0.2.6 | SQL Server 2016 SP2 (mixed-mode auth) + SSMS |
| sql2 | Database server | Windows Server 2022 | 10.0.2.7 | SQL Server 2022 (mixed-mode auth) + SSMS |
| workstation | Domain-joined client | Windows 11 Pro N | 10.0.2.8 | — |

All 7 are domain members (dc1/dc2 as the domain itself). See
[CLAUDE.md](CLAUDE.md) for VMIDs, MAC addresses, DNS configuration, and the
history of how each was provisioned and fixed up.

The range is intentionally built toward a specific, documented set of
vulnerabilities and misconfigurations for training purposes — see the
"Vulnerable AD range design" section of [CLAUDE.md](CLAUDE.md) for the full
design (delegation coverage, starter accounts, credential-leak locations,
ADCS ESC templates, etc.) and its current implementation status.

## Repository layout

```
cyber-range/
  CLAUDE.md              # running source of truth: decisions, history, known issues
  README.md              # this file
  .gitignore             # excludes private keys, vault secrets, retry files
  ansible/
    ansible.cfg
    inventory/
      hosts.yml           # the 7 range VMs, grouped by role, plus the Proxmox host
    playbooks/             # provisioning/vulnerability playbooks
    group_vars/
    host_vars/
    roles/
```

## Getting started

1. Set up the control host prerequisites above (SSH key, WinRM TrustedHosts,
   WSL2 + Ansible + `pywinrm`).
2. Retrieve the shared Windows credential via `qm cloudinit dump <vmid> user`
   on the Proxmox host and store it somewhere `ansible-vault` can read (not in
   this repo — see `ansible/inventory/hosts.yml` for where it's referenced).
3. From WSL2: `cd ansible && ansible all -i inventory/hosts.yml -m win_ping`
   (Windows hosts) to confirm connectivity.
4. See [CLAUDE.md](CLAUDE.md) for what's actually been built so far vs. what's
   still planned — the domain, CA, and SQL Server instances are live; the
   intentional-vulnerability configuration is not yet implemented.

## Scope note

This repo covers the Proxmox-hosted AD range only. A few standalone security
tools also live on this network for use *against* the range (reporting,
vulnerability scanning, attack-path analysis) — they're separately managed,
outside this repo's scope, and intentionally not documented here.
