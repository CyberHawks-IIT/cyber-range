#!/usr/bin/env bash
#
# create_range_vms.sh — clone the 7 cyberhawks.lab AD range VMs from the
# Windows Server / Windows 11 templates.
#
# Run this ON THE PROXMOX HOST (it drives qm directly), same as
# create_testing_vms.sh:
#   scp scripts/create_range_vms.sh root@<proxmox>:/root/
#   ssh root@<proxmox>
#   ./create_range_vms.sh --dry-run      # preview
#   ./create_range_vms.sh                # do it
#
# This produces the fresh, un-configured VMs that base-domain.yml then turns
# into the domain (promotion, CA, SQL, joins). It reproduces the layout in
# CLAUDE.md's "Range VMs" table: VMIDs 320-326, the ad bridge (10.0.2.0/24),
# 4 vCPU / 4 GB each, sql1/sql2 resized to 48 GB.
#
# It does NOT build the templates themselves — those come from the AttackerVMs
# repo / the Windows Server + Windows 11 base images (see that repo and
# docs/network-and-infrastructure.md). Point the --tmpl-* flags at your own
# template VMIDs if they differ from this host's defaults.
#
# Idempotent: a VM whose target VMID already exists is skipped (a warning),
# so re-running over a partially-built range is safe. --dry-run previews
# everything with no changes.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults — the range's fixed layout (override via flags)
# ---------------------------------------------------------------------------
BRIDGE="ad"
NETWORK_PREFIX="10.0.2"
NETMASK="24"
GATEWAY=""                # default: "${NETWORK_PREFIX}.1"
SEARCHDOMAIN="cyberhawks.lab"
CORES=4
MEMORY=4096
STORAGE="local-zfs"       # only used when --full
CLONE_MODE="linked"       # linked | full
TAG="cyber-range"
START_VMS=0
DRY_RUN=0

# Default template VMIDs per OS (this host's, per CLAUDE.md). Override if yours
# differ.
TMPL_2016=300             # Windows Server 2016
TMPL_2019=301             # Windows Server 2019
TMPL_2022=302             # Windows Server 2022
TMPL_WIN11=304            # Windows 11

# ---------------------------------------------------------------------------
# Logging helpers (same style as create_testing_vms.sh)
# ---------------------------------------------------------------------------
log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
run()  {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
  else
    "$@"
  fi
}

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge)          BRIDGE="$2"; shift 2 ;;
    --network-prefix)  NETWORK_PREFIX="$2"; shift 2 ;;
    --netmask)         NETMASK="$2"; shift 2 ;;
    --gateway)         GATEWAY="$2"; shift 2 ;;
    --searchdomain)    SEARCHDOMAIN="$2"; shift 2 ;;
    --cores)           CORES="$2"; shift 2 ;;
    --memory)          MEMORY="$2"; shift 2 ;;
    --full)            CLONE_MODE="full"; shift ;;
    --storage)         STORAGE="$2"; shift 2 ;;
    --tmpl-2016)       TMPL_2016="$2"; shift 2 ;;
    --tmpl-2019)       TMPL_2019="$2"; shift 2 ;;
    --tmpl-2022)       TMPL_2022="$2"; shift 2 ;;
    --tmpl-win11)      TMPL_WIN11="$2"; shift 2 ;;
    --start-vms)       START_VMS=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -z "$GATEWAY" ]] && GATEWAY="${NETWORK_PREFIX}.1"
command -v qm >/dev/null || die "qm not found — this script must run on a Proxmox node"

# ---------------------------------------------------------------------------
# The range definition: name vmid template_os last_octet disk_gb
#   disk_gb empty = leave the template's default disk size
# ---------------------------------------------------------------------------
RANGE_SPEC=(
  "dc1 320 2016 2 -"
  "dc2 321 2019 3 -"
  "ca  322 2019 4 -"
  "web 323 2022 5 -"
  "sql1 324 2016 6 48"
  "sql2 325 2022 7 48"
  "workstation 326 win11 8 -"
)

tmpl_id_for() {
  case "$1" in
    2016)  echo "$TMPL_2016" ;;
    2019)  echo "$TMPL_2019" ;;
    2022)  echo "$TMPL_2022" ;;
    win11) echo "$TMPL_WIN11" ;;
    *) die "Unknown template OS key: $1" ;;
  esac
}

vmid_exists() { qm status "$1" >/dev/null 2>&1; }

# Find the primary OS disk key (scsi0/virtio0/sata0/ide0) for a resize.
primary_disk_key() {
  qm config "$1" 2>/dev/null | grep -oP '^(scsi0|virtio0|sata0|ide0)(?=:)' | head -n1
}

# ---------------------------------------------------------------------------
# Validate templates exist up front
# ---------------------------------------------------------------------------
for os in 2016 2019 2022 win11; do
  tid="$(tmpl_id_for "$os")"
  qm status "$tid" >/dev/null 2>&1 || die "Template VMID $tid (for $os) does not exist — set --tmpl-$os"
done

SUMMARY=()
for row in "${RANGE_SPEC[@]}"; do
  read -r name vmid os octet disk <<< "$row"
  ip="${NETWORK_PREFIX}.${octet}"
  tid="$(tmpl_id_for "$os")"

  if vmid_exists "$vmid"; then
    warn "VMID $vmid ($name) already exists — skipping"
    continue
  fi

  log "=== $name -> VMID $vmid (template $tid / $os), ip=$ip/$NETMASK ==="

  clone_args=(clone "$tid" "$vmid" --name "$name")
  [[ "$CLONE_MODE" == "full" ]] && clone_args+=(--full --storage "$STORAGE")
  run qm "${clone_args[@]}"

  run qm set "$vmid" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --agent enabled=1 \
    --tags "$TAG" \
    --ipconfig0 "ip=${ip}/${NETMASK},gw=${GATEWAY}" \
    --nameserver "$GATEWAY" \
    --searchdomain "$SEARCHDOMAIN" \
    --net0 "virtio,bridge=${BRIDGE},firewall=1"

  if [[ "$disk" != "-" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf '[DRY-RUN] qm resize %s <primary-disk> %sG\n' "$vmid" "$disk"
    else
      dkey="$(primary_disk_key "$vmid")"
      if [[ -n "$dkey" ]]; then
        log "Resizing $name disk $dkey to ${disk}G"
        run qm resize "$vmid" "$dkey" "${disk}G"
      else
        warn "Could not determine primary disk for $name ($vmid) — resize skipped; set it to ${disk}G by hand"
      fi
    fi
  fi

  [[ "$START_VMS" -eq 1 ]] && { log "Starting $name ($vmid)"; run qm start "$vmid"; }

  SUMMARY+=("$name|$vmid|$tid|$ip/$NETMASK|${disk}")
done

echo
log "Done. Range VMs:"
printf '%-12s %-6s %-9s %-18s %s\n' "NAME" "VMID" "TEMPLATE" "IP" "DISK(GB)"
for r in "${SUMMARY[@]}"; do
  IFS='|' read -r n id t ip d <<< "$r"
  printf '%-12s %-6s %-9s %-18s %s\n' "$n" "$id" "$t" "$ip" "$d"
done

cat <<'NEXT'

Next steps:
  1. The IP-not-applied bug on some 2016/2022 template clones (CLAUDE.md's
     "Known issue found and worked around") may leave a VM on APIPA. If a host
     is unreachable, set its IP from the Proxmox host via the guest agent:
       qm guest exec <vmid> -- netsh interface ipv4 set address name=Ethernet static <ip> 255.255.255.0 10.0.2.1
  2. Retrieve the shared Administrator password: qm cloudinit dump <vmid> user
  3. Run the base-domain.yml playbook to build the domain (see the setup guide).
NEXT

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "This was a --dry-run: nothing was actually created."
fi
