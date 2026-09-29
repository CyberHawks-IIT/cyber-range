# Cyber Range

A personal cyber range for practicing identification and remediation of
common vulnerabilities — primarily Active Directory misconfigurations and
Kerberos delegation abuse, plus adjacent web/SQL findings — under a single
in-universe company theme, **CyberHawks**.

7-VM Windows Server/AD environment (`cyberhawks.lab`), hosted on Proxmox,
managed from a Windows control host over NetBird. This repo holds the
Ansible code and [CLAUDE.md](CLAUDE.md), the running source of truth for
project history and decisions.

> ### ▶ Two things to look at first
> - **[Start here: choose your setup](#-start-here-choose-your-setup)** (just below) — pick a setup and follow its step-by-step guide.
> - **[Range briefing](https://claude.ai/artifact/LAVSDoKzNEfconPj9NN7Jz)** — hosts, starter access, and the full findings list.

## ▶ Start here: choose your setup

There are two ways to stand this up, each with a complete, copy-pasteable,
step-by-step guide:

| Setup | You get | Guide |
|---|---|---|
| **1 — Range only** | Just the vulnerable AD range to attack | **[docs/setup/range-only.md](docs/setup/range-only.md)** |
| **2 — Range + defense tooling** | The range **plus** Zeek + Splunk monitoring and the detections that fire on it (Discord alerting optional) | **[docs/setup/range-with-monitoring.md](docs/setup/range-with-monitoring.md)** |

Both build the same range; setup 2 just adds monitoring on top via a single
toggle (`range_monitoring`), so you can start with setup 1 and add it later
without rebuilding. **[Guide index →](docs/setup/README.md)**

## Part of a bigger project

| Repo | Layer |
|---|---|
| **cyber-range** *(this repo)* | The AD range |
| [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs) | Attacker VM templates + cloudbase-init |
| [defense-tooling](https://github.com/CyberHawks-IIT/defense-tooling) | Splunk + Zeek monitoring stack |
| [splunk-detections](https://github.com/CyberHawks-IIT/splunk-detections) | Detection content for that Splunk instance |

Each repo stands alone — use just this one, or combine them.

> **Optional — the wider network picture.** If you want to see how everything
> sits on the shared Proxmox host, there's a
> [network diagram and layout doc](docs/network-and-infrastructure.md). It's a
> suggestion, not required reading: it includes several other lab networks that
> aren't part of either setup here, so don't let it distract from the two guides
> above.
>
> [![Network diagram](docs/network-diagram.jpg)](docs/network-and-infrastructure.md)

## Architecture

Single AD forest **`cyberhawks.lab`** (NetBIOS `CYBERHAWKS`) on `10.0.2.0/24`.

| Host | Role | OS | IP | Key software |
|---|---|---|---|---|
| dc1 | Domain controller (forest root) | Server 2016 | .2 | AD DS, DNS |
| dc2 | Domain controller | Server 2019 | .3 | AD DS, DNS |
| ca | Certificate authority | Server 2019 | .4 | AD CS — `cyberhawks-CA` + Web Enrollment |
| web | Web server | Server 2022 | .5 | IIS — internal employee portal |
| sql1 | Database | Server 2016 | .6 | SQL Server 2016 SP2 + SSMS |
| sql2 | Database | Server 2022 | .7 | SQL Server 2022 + SSMS |
| workstation | Domain client | Windows 11 Pro N | .8 | — |

The range is built toward a specific, fully-implemented set of
vulnerabilities and misconfigurations — see CLAUDE.md's **"Vulnerable AD
range design"** for the full design (delegation coverage, starter accounts,
credential-leak locations, ADCS ESC templates) and its verification pass.

## Prerequisites

**Control host** (Windows):

- OpenSSH client (built into Windows 11)
- [PuTTY](https://www.putty.org/)/`plink` — one-off password-authenticated bootstrapping only
- [GitHub CLI](https://cli.github.com/) (`gh`)
- WSL2 + Ansible + `pywinrm` — drives provisioning against `ansible/inventory/hosts.yml`
- SSH keypair for range hosts (gitignored, never committed)
- [NetBird](https://netbird.io/) (or equivalent) VPN — routes directly to every VM's IP, no tunnel/jump host needed

**Proxmox**: reachable over SSH (key-only), capacity for 7 Windows VMs
(4 vCPU/4GB each; sql1/sql2 at 48GB disk, rest 32GB), and the
Windows Server 2016/2019/2022 + Windows 11 templates already built
(see [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs)).

**Windows access**: WinRM only, local `Administrator`, NTLM (control host
isn't domain-joined — see CLAUDE.md's "WinRM double-hop" note before writing
automation that needs a target machine to make its *own* further
authenticated call). `WSMan:\localhost\Client\TrustedHosts` must include all
7 VM IPs.

Credentials aren't stored here — retrieve the shared local Administrator
password (also the domain `Administrator` and SQL `sa` password) via:

```bash
qm cloudinit dump <vmid> user
```

## Getting started

Follow the step-by-step guide for your setup — **[range-only](docs/setup/range-only.md)**
or **[range + monitoring](docs/setup/range-with-monitoring.md)** (index:
[docs/setup/](docs/setup/README.md)). In short, the whole build is scripted:

1. `scripts/create_range_vms.sh` (on Proxmox) — clone the 7 range VMs from templates.
2. Copy `inventory/hosts.yml.example` → `hosts.yml` and the vault example, fill them in.
3. `ansible-playbook playbooks/base-domain.yml` — the clean domain (DCs, CA, SQL, joins).
4. `ansible-playbook playbooks/vulnerable-range.yml` — the intentional misconfigurations
   (add `-e range_monitoring=true` for setup 2's host-side logging).

See [CLAUDE.md](CLAUDE.md) for the full project history and design decisions.

## Repository layout

```
cyber-range/
  CLAUDE.md              # running source of truth
  README.md              # this file
  docs/
    setup/                         # ← the two step-by-step setup guides
    network-and-infrastructure.md  # full network layout + manual setup
    range-briefing.html            # student-facing handout
  scripts/
    create_range_vms.sh    # clone the 7 range VMs from templates
    create_testing_vms.sh  # bulk student attacker/target VMs
  ansible/
    inventory/hosts.yml.example  # the 7 range VMs by role (copy to hosts.yml)
    playbooks/
      base-domain.yml            # clean domain build (DCs, CA, SQL, joins)
      vulnerable-range.yml       # the intentional misconfigurations
      detection-logging.yml      # host-side logging (setup 2; imported by the above)
    roles/
```

## Scope note

This repo covers the AD range and the shared network layout it sits on.
Out of scope, by design:

- Attacker VM templates → [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs)
- Monitoring stack → [defense-tooling](https://github.com/CyberHawks-IIT/defense-tooling)
- Detection content → [splunk-detections](https://github.com/CyberHawks-IIT/splunk-detections)
- Standalone offense tooling (reporting, scanning, attack-path analysis) — separately managed, undocumented here
