# Setup guides — choose your setup

There are two ways to stand up this project. Pick one:

| | Setup 1 — **Range only** | Setup 2 — **Range + defense tooling** |
|---|---|---|
| What you get | The vulnerable `cyberhawks.lab` AD range (7 VMs) to attack | The same range, **plus** the Zeek + Splunk monitoring stack and the detection content that fires on the attacks |
| Repos needed | `cyber-range` (+ `AttackerVMs` for an attacker box) | `cyber-range`, `defense-tooling`, `splunk-detections` (+ `AttackerVMs`) |
| Extra hosts | none | a Zeek sensor + a Splunk indexer (2 Debian boxes) |
| Optional add-on | — | **Discord alerting** — every Splunk alert pushed to a Discord channel |
| Guide | **[range-only.md](range-only.md)** | **[range-with-monitoring.md](range-with-monitoring.md)** |

Both setups build the identical vulnerable range; setup 2 only adds monitoring
on top, controlled by a single toggle (`range_monitoring`), so you can start
with setup 1 and add the monitoring later without rebuilding.

Each guide is self-contained and copy-pasteable, with a check after every major
step so you know it worked before moving on. Read the whole "Prerequisites"
section of your chosen guide first — a few pieces (VM templates, SQL Server
media, Splunk downloads) are one-time manual downloads the automation can't do
for you.
