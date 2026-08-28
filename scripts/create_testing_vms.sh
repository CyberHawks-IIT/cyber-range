#!/usr/bin/env bash
#
# create_testing_vms.sh — bulk-provision student PVE accounts + per-student attacker/target VMs.
#
# Run this ON THE PROXMOX HOST (it drives qm/pveum/pvesh directly). Copy the
# roster CSV there first, e.g.:
#   scp roster.csv root@192.168.192.150:/root/roster.csv
#   ssh root@192.168.192.150
#   ./create_testing_vms.sh --csv /root/roster.csv
#
# Defaults match the existing 610-623 setup: --group Students,
# --templates 604:windows,605:kali, --start-clone-id 610, --pool Attackers —
# override any of these if you're provisioning a different roster/template
# set. VMID and IP collisions with whatever already exists on the host are
# detected and stepped around automatically (see below), so re-running with
# the same defaults over an appended CSV is safe and requires no manual
# bookkeeping.
#
# For each CSV row this:
#   1. creates a PVE user (name/email/username/password), adding it to --group
#   2. clones every template in --templates (in the order given) to the next
#      free VMID at/after --start-clone-id, adding each clone to --pool
#      (pass --pool "" to skip pool assignment)
#   3. names each clone "<username>-<templatename>"
#   4. sets a unique cloud-init IP per clone (see IP scheme below)
#   5. grants the student --role (default PVEVMAdmin) on each of their VMs
#
# CSV format: name,email,username,password  (one row per line, no header
# required — a header row is auto-detected and skipped if column 3 reads
# "username"). email may be blank. Plain comma-separated, no quoting support.
# "password" is used ONLY for the PVE account login — cloned VMs keep
# whatever cloud-init credentials are baked into the source template.
#
# IP scheme (reverse-engineered from VMs 610-623, see CLAUDE.md):
#   network:      <network-prefix>.0/<netmask>            (default 192.168.1.0/24)
#   gateway:      <network-prefix>.1                      (default, override with --gateway)
#   nameserver:   same as gateway unless --nameserver given
#   each CSV row gets a block of --ip-block-size addresses (default 10):
#     block_base = ip-start-offset + ip-block-size * (ip-start-index + row_number)
#   each template within that row gets block_base + its position in --templates
#   e.g. row 0, templates 604:windows,605:kali, defaults -> .10 (windows), .11 (kali)
#        row 1                                             -> .20, .21
#   The script scans every existing VM's ipconfig0 first; if a row's computed
#   block collides with one already in use, it automatically advances to the
#   next free block of the same size (logged when this happens) rather than
#   failing — so you never have to hand-compute --ip-start-index for a
#   follow-up run. Pass --strict to disable this and hard-fail on collisions
#   instead (also aborts the whole run on any PVE user / VM name collision).
#
# Existing PVE users / VM names are left alone (skipped with a warning) so
# the script is safe to re-run over a roster that's partially provisioned.
# Use --dry-run to preview everything without changing anything.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REALM="pve"
ROLE="PVEVMAdmin"
CLONE_MODE="linked"      # linked | full
STORAGE="local-zfs"      # only used when CLONE_MODE=full
BRIDGE="attacker"
NETWORK_PREFIX="192.168.1"
NETMASK="24"
GATEWAY=""               # default: "${NETWORK_PREFIX}.1"
NAMESERVER=""            # default: same as GATEWAY
SEARCHDOMAIN="cyberhawks.lab"
IP_BLOCK_SIZE=10
IP_START_OFFSET=10
IP_START_INDEX=0
START_VMS=0
DRY_RUN=0
STRICT=0                 # 0 = skip+warn on collisions (default), 1 = abort whole run

CSV_FILE=""
GROUP="Students"
TEMPLATES_SPEC="604:windows,605:kali"
START_CLONE_ID=610
POOL="Attackers"

# ---------------------------------------------------------------------------
# Logging helpers
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

usage() {
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)              CSV_FILE="$2"; shift 2 ;;
    --group)             GROUP="$2"; shift 2 ;;
    --templates)         TEMPLATES_SPEC="$2"; shift 2 ;;
    --start-clone-id)    START_CLONE_ID="$2"; shift 2 ;;
    --pool)              POOL="$2"; shift 2 ;;
    --realm)             REALM="$2"; shift 2 ;;
    --role)              ROLE="$2"; shift 2 ;;
    --full)              CLONE_MODE="full"; shift ;;
    --storage)           STORAGE="$2"; shift 2 ;;
    --bridge)             BRIDGE="$2"; shift 2 ;;
    --network-prefix)    NETWORK_PREFIX="$2"; shift 2 ;;
    --netmask)           NETMASK="$2"; shift 2 ;;
    --gateway)           GATEWAY="$2"; shift 2 ;;
    --nameserver)        NAMESERVER="$2"; shift 2 ;;
    --searchdomain)      SEARCHDOMAIN="$2"; shift 2 ;;
    --ip-block-size)     IP_BLOCK_SIZE="$2"; shift 2 ;;
    --ip-start-offset)   IP_START_OFFSET="$2"; shift 2 ;;
    --ip-start-index)    IP_START_INDEX="$2"; shift 2 ;;
    --start-vms)         START_VMS=1; shift ;;
    --strict)            STRICT=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$CSV_FILE" ]]        || die "--csv is required"
[[ -f "$CSV_FILE" ]]        || die "CSV file not found: $CSV_FILE"
[[ -n "$GROUP" ]]           || die "--group must not be empty"
[[ -n "$TEMPLATES_SPEC" ]]  || die "--templates must not be empty (e.g. --templates 604:windows,605:kali)"
[[ -n "$START_CLONE_ID" ]]  || die "--start-clone-id must not be empty"
[[ -z "$GATEWAY" ]]         && GATEWAY="${NETWORK_PREFIX}.1"
[[ -z "$NAMESERVER" ]]      && NAMESERVER="$GATEWAY"

command -v qm    >/dev/null || die "qm not found — this script must run on a Proxmox node"
command -v pveum >/dev/null || die "pveum not found — this script must run on a Proxmox node"
command -v pvesh >/dev/null || die "pvesh not found — this script must run on a Proxmox node"

# ---------------------------------------------------------------------------
# Parse --templates into parallel arrays, preserving order
# ---------------------------------------------------------------------------
TEMPLATE_IDS=()
TEMPLATE_NAMES=()
IFS=',' read -ra _pairs <<< "$TEMPLATES_SPEC"
for pair in "${_pairs[@]}"; do
  [[ "$pair" == *:* ]] || die "Bad --templates entry '$pair' (expected id:name)"
  tid="${pair%%:*}"
  tname="${pair#*:}"
  [[ "$tid" =~ ^[0-9]+$ ]] || die "Bad template id '$tid' in --templates"
  [[ -n "$tname" ]] || die "Empty template name for id '$tid' in --templates"
  qm status "$tid" >/dev/null 2>&1 || die "Template VMID $tid does not exist"
  if ! qm config "$tid" | grep -q '^template: 1'; then
    warn "VMID $tid is not marked as a Proxmox template — will clone it anyway"
  fi
  TEMPLATE_IDS+=("$tid")
  TEMPLATE_NAMES+=("$tname")
done
[[ "${#TEMPLATE_IDS[@]}" -gt 0 ]] || die "No templates parsed from --templates"

_tmpl_desc=""
for i in "${!TEMPLATE_IDS[@]}"; do
  _tmpl_desc="${_tmpl_desc}${TEMPLATE_IDS[$i]}:${TEMPLATE_NAMES[$i]} "
done
log "Templates (in clone order): $_tmpl_desc"

# ---------------------------------------------------------------------------
# Existing state on the host (used for collision checks)
# ---------------------------------------------------------------------------
mapfile -t EXISTING_VMIDS < <(qm list | awk 'NR>1{print $1}')

vmid_exists() {
  local id="$1"
  for existing in "${EXISTING_VMIDS[@]}"; do
    [[ "$existing" == "$id" ]] && return 0
  done
  return 1
}

vm_name_exists() {
  local name="$1"
  qm list | awk -v n="$name" 'NR>1 && $2==n{found=1} END{exit !found}'
}

pve_user_exists() {
  pvesh get "/access/users/$1" >/dev/null 2>&1
}

pve_group_exists() {
  pvesh get "/access/groups/$1" >/dev/null 2>&1
}

pve_pool_exists() {
  pvesh get "/pools/$1" >/dev/null 2>&1
}

declare -A EXISTING_IPS=()
for id in "${EXISTING_VMIDS[@]}"; do
  ip="$(qm config "$id" 2>/dev/null | sed -n 's/^ipconfig0:.*ip=\([0-9.]*\)\/.*/\1/p')"
  [[ -n "$ip" ]] && EXISTING_IPS["$ip"]="$id"
done

NEXT_VMID_POINTER="$START_CLONE_ID"
next_free_vmid() {
  while vmid_exists "$NEXT_VMID_POINTER"; do
    NEXT_VMID_POINTER=$((NEXT_VMID_POINTER + 1))
  done
  echo "$NEXT_VMID_POINTER"
  NEXT_VMID_POINTER=$((NEXT_VMID_POINTER + 1))
}

# Given a desired block base and the number of consecutive offsets needed
# (one per template), return the first block base >= desired that has no
# offset colliding with an already-assigned IP. In --strict mode, no
# advancing happens — the desired base is returned as-is so the per-clone
# collision check further down can hard-fail on it.
find_free_block() {
  local base="$1" count="$2"
  [[ "$STRICT" -eq 1 ]] && { echo "$base"; return; }
  while true; do
    local collision=0 off octet candidate_ip
    for ((off = 0; off < count; off++)); do
      octet=$((base + off))
      if (( octet < 1 || octet > 254 )); then
        collision=1
        break
      fi
      candidate_ip="${NETWORK_PREFIX}.${octet}"
      if [[ -n "${EXISTING_IPS[$candidate_ip]:-}" ]]; then
        collision=1
        break
      fi
    done
    [[ "$collision" -eq 0 ]] && break
    base=$((base + IP_BLOCK_SIZE))
  done
  echo "$base"
}

# ---------------------------------------------------------------------------
# Ensure target group exists
# ---------------------------------------------------------------------------
if pve_group_exists "$GROUP"; then
  log "Group '$GROUP' already exists"
else
  log "Creating group '$GROUP'"
  run pveum group add "$GROUP"
fi

# ---------------------------------------------------------------------------
# Ensure target pool exists (skip entirely if --pool "" was passed)
# ---------------------------------------------------------------------------
if [[ -n "$POOL" ]]; then
  if pve_pool_exists "$POOL"; then
    log "Pool '$POOL' already exists"
  else
    log "Creating pool '$POOL'"
    run pveum pool add "$POOL"
  fi
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
trim() { local s="${1%$'\r'}"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

SUMMARY=()
row_number=0
line_number=0

while IFS=',' read -r raw_name raw_email raw_username raw_password || [[ -n "${raw_name:-}" ]]; do
  line_number=$((line_number + 1))
  name="$(trim "${raw_name:-}")"
  email="$(trim "${raw_email:-}")"
  username="$(trim "${raw_username:-}")"
  password="$(trim "${raw_password:-}")"

  [[ -z "$name" && -z "$username" ]] && continue      # blank line
  [[ "$name" == \#* ]] && continue                    # comment line
  if [[ "$line_number" -eq 1 && "${username,,}" == "username" ]]; then
    log "Skipping header row"
    continue
  fi

  if [[ -z "$username" || -z "$password" ]]; then
    warn "Line $line_number: missing username or password, skipping row"
    continue
  fi

  firstname="$name"
  lastname=""
  if [[ "$name" == *' '* ]]; then
    lastname="${name##* }"
    firstname="${name% *}"
  fi

  person_index=$((IP_START_INDEX + row_number))
  desired_block_base=$((IP_START_OFFSET + IP_BLOCK_SIZE * person_index))
  block_base="$(find_free_block "$desired_block_base" "${#TEMPLATE_IDS[@]}")"
  row_number=$((row_number + 1))

  userid="${username}@${REALM}"
  if [[ "$block_base" != "$desired_block_base" ]]; then
    log "=== Row $line_number: $name <$email> ($userid), IP block .$desired_block_base was taken, using .$block_base instead ==="
  else
    log "=== Row $line_number: $name <$email> ($userid), IP block base .$block_base ==="
  fi

  # ---- 1. PVE user ----
  if pve_user_exists "$userid"; then
    warn "PVE user $userid already exists — skipping user creation"
    if [[ "$STRICT" -eq 1 ]]; then
      die "Aborting on collision (--strict): $userid already exists"
    fi
  else
    add_args=(-groups "$GROUP" -password "$password")
    [[ -n "$firstname" ]] && add_args+=(-firstname "$firstname")
    [[ -n "$lastname" ]]  && add_args+=(-lastname "$lastname")
    [[ -n "$email" ]]     && add_args+=(-email "$email")
    log "Creating PVE user $userid"
    run pveum user add "$userid" "${add_args[@]}"
  fi

  # ---- 2-5. Clones ----
  for i in "${!TEMPLATE_IDS[@]}"; do
    tid="${TEMPLATE_IDS[$i]}"
    tname="${TEMPLATE_NAMES[$i]}"
    vm_name="${username}-${tname}"
    octet=$((block_base + i))
    ip="${NETWORK_PREFIX}.${octet}"

    if (( octet < 1 || octet > 254 )); then
      warn "Computed IP $ip/$NETMASK for $vm_name is out of range — skipping this clone"
      continue
    fi

    if [[ -n "${EXISTING_IPS[$ip]:-}" ]]; then
      err "IP $ip is already used by VMID ${EXISTING_IPS[$ip]} — cannot assign it to $vm_name"
      err "Re-run with a different --ip-start-index / --ip-start-offset to avoid this block"
      if [[ "$STRICT" -eq 1 ]]; then
        die "Aborting on IP collision (--strict)"
      fi
      warn "Skipping clone for $vm_name due to IP collision"
      continue
    fi

    if vm_name_exists "$vm_name"; then
      warn "A VM named '$vm_name' already exists — skipping this clone"
      if [[ "$STRICT" -eq 1 ]]; then
        die "Aborting on collision (--strict): VM name $vm_name already exists"
      fi
      continue
    fi

    newid="$(next_free_vmid)"
    if [[ -n "$POOL" ]]; then
      log "Cloning template $tid -> VMID $newid ('$vm_name'), ip=$ip/$NETMASK, pool=$POOL"
    else
      log "Cloning template $tid -> VMID $newid ('$vm_name'), ip=$ip/$NETMASK"
    fi

    clone_args=(clone "$tid" "$newid" --name "$vm_name")
    if [[ "$CLONE_MODE" == "full" ]]; then
      clone_args+=(--full --storage "$STORAGE")
    fi
    [[ -n "$POOL" ]] && clone_args+=(--pool "$POOL")
    run qm "${clone_args[@]}"

    run qm set "$newid" \
      --ipconfig0 "ip=${ip}/${NETMASK},gw=${GATEWAY}" \
      --nameserver "$NAMESERVER" \
      --searchdomain "$SEARCHDOMAIN" \
      --net0 "virtio,bridge=${BRIDGE},firewall=1"

    run pveum acl modify "/vms/$newid" --users "$userid" --roles "$ROLE"

    EXISTING_IPS["$ip"]="$newid"
    EXISTING_VMIDS+=("$newid")

    if [[ "$START_VMS" -eq 1 ]]; then
      log "Starting VM $newid"
      run qm start "$newid"
    fi

    SUMMARY+=("$username|$vm_name|$newid|$ip/$NETMASK|$ROLE|${POOL:--}")
  done
done < "$CSV_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "Done. Created/updated:"
printf '%-14s %-26s %-8s %-18s %-14s %s\n' "USERNAME" "VM NAME" "VMID" "IP" "ROLE" "POOL"
for row in "${SUMMARY[@]}"; do
  IFS='|' read -r u n id ip role pool <<< "$row"
  printf '%-14s %-26s %-8s %-18s %-14s %s\n' "$u" "$n" "$id" "$ip" "$role" "$pool"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "This was a --dry-run: nothing was actually created."
fi
