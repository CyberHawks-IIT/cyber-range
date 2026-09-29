# Setup guides

There are two ways to stand up this project. Pick one.

| | Setup 1: Range only | Setup 2: Range + defense tooling |
|---|---|---|
| What you get | The vulnerable `cyberhawks.lab` range (7 VMs) to attack | The same range, **plus** the Zeek and Splunk monitoring stack and the detection content that fires on the attacks |
| Repos needed | `cyber-range` (add `vm-templates` for an attacker box) | `cyber-range`, `defense-tooling`, `splunk-detections` (add `vm-templates`) |
| Extra hosts | none | a Zeek sensor and a Splunk indexer (2 Debian boxes) |
| Optional add-on | none | **Discord alerting**: every Splunk alert pushed to a Discord channel |
| Guide | **[range-only.md](range-only.md)** | **[range-with-monitoring.md](range-with-monitoring.md)** |

Both setups build the identical vulnerable range. Setup 2 only adds monitoring
on top, controlled by one toggle (`range_monitoring`), so you can start with
setup 1 and add monitoring later without rebuilding.

Each guide is self-contained and copy-pasteable, with a check after every major
step so you know it worked before moving on. Read the whole "Prerequisites"
section of your chosen guide first. A few pieces (VM templates, SQL Server
media, Splunk downloads) are one-time manual downloads that the automation
can't do for you.
