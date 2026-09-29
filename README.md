# Cyber Range

A personal cyber range for practicing identification and remediation of common
vulnerabilities — primarily Active Directory misconfigurations and Kerberos
delegation abuse, plus adjacent web/SQL findings — under a single in-universe
company theme, **CyberHawks**.

It's a 7-VM Windows Server/AD environment (`cyberhawks.lab`) on Proxmox, driven
by the Ansible in this repo. [CLAUDE.md](CLAUDE.md) is the running source of
truth for project history and design decisions.

> ## 📋 [Range briefing →](https://claude.ai/artifact/LAVSDoKzNEfconPj9NN7Jz)
> **See exactly what you're building** — every host, the starter credentials
> you're handed on day one, and the full list of findings to hunt. This is also
> the handout for whoever attacks the range.

## Start here

Pick a setup. Each guide is a complete, copy-pasteable walkthrough —
prerequisites first, then every command, with a check after each step.

| | Setup | What you get | Guide |
|---|---|---|---|
| **1** | Range only | The vulnerable AD range, to attack | **[range-only.md](docs/setup/range-only.md)** |
| **2** | Range + defense tooling | Setup 1 **plus** Zeek + Splunk monitoring and the detections that fire on it (Discord alerting optional) | **[range-with-monitoring.md](docs/setup/range-with-monitoring.md)** |

Both build the same range — setup 2 just adds monitoring on top via one toggle
(`range_monitoring`), so you can start with setup 1 and add it later without
rebuilding.

## The range

Single AD forest **`cyberhawks.lab`** (NetBIOS `CYBERHAWKS`) on `10.0.2.0/24`:

| Host | Role | OS | IP | Key software |
|---|---|---|---|---|
| dc1 | Domain controller (forest root) | Server 2016 | .2 | AD DS, DNS |
| dc2 | Domain controller | Server 2019 | .3 | AD DS, DNS |
| ca | Certificate authority | Server 2019 | .4 | AD CS — `cyberhawks-CA` + Web Enrollment |
| web | Web server | Server 2022 | .5 | IIS — internal employee portal |
| sql1 | Database | Server 2016 | .6 | SQL Server 2016 SP2 + SSMS |
| sql2 | Database | Server 2022 | .7 | SQL Server 2022 + SSMS |
| workstation | Domain client | Windows 11 Pro N | .8 | — |

The range targets a specific, fully-implemented set of misconfigurations —
delegation coverage, starter accounts, credential-leak locations, ADCS ESC
templates. See CLAUDE.md's **"Vulnerable AD range design"** for the full list.

## Part of a bigger project

| Repo | Layer |
|---|---|
| **cyber-range** *(this repo)* | The AD range |
| [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs) | Attacker VM templates + cloudbase-init |
| [defense-tooling](https://github.com/CyberHawks-IIT/defense-tooling) | Splunk + Zeek monitoring stack |
| [splunk-detections](https://github.com/CyberHawks-IIT/splunk-detections) | Detection content for that Splunk instance |

Each repo stands alone; the setup guides above pull in whichever you need.

<details>
<summary>Optional — the wider network picture</summary>

The [network diagram and layout doc](docs/network-and-infrastructure.md) shows
how everything sits on the shared Proxmox host. It's reference only, and
includes several other lab networks that aren't part of either setup here.

[![Network diagram](docs/network-diagram.jpg)](docs/network-and-infrastructure.md)

</details>

## Repository layout

```
cyber-range/
  docs/setup/              # ← the two step-by-step setup guides (start here)
  docs/                    # network layout doc, student range-briefing handout
  scripts/
    create_range_vms.sh    # clone the 7 range VMs from templates
    create_testing_vms.sh  # bulk student attacker/target VMs
  ansible/
    inventory/hosts.yml.example
    playbooks/
      base-domain.yml        # clean domain build (DCs, CA, SQL, joins)
      vulnerable-range.yml   # the intentional misconfigurations
      detection-logging.yml  # host-side logging (setup 2; imported by the above)
    roles/
  CLAUDE.md                # running source of truth
```

## Scope note

This repo covers the AD range and the network layout it sits on. Out of scope,
by design: attacker VM templates → [AttackerVMs](https://github.com/CyberHawks-IIT/AttackerVMs);
monitoring stack → [defense-tooling](https://github.com/CyberHawks-IIT/defense-tooling);
detection content → [splunk-detections](https://github.com/CyberHawks-IIT/splunk-detections);
and standalone offense tooling (reporting, scanning, attack-path analysis),
which is separately managed and undocumented here.
