#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# KVM-Agent: create one graphical Ubuntu VM and provision coding-agent tools.
#
# Run this script as the ordinary Ubuntu host account that will use
# virt-manager. Do not run the script itself with sudo; it asks for sudo only
# for host package installation and system-libvirt operations. Third-party
# coding-agent and optional formal-methods installers execute inside the guest,
# never on the host.

readonly GUEST_RELEASE="24.04"
readonly GUEST_ARCH="amd64"
readonly LIBVIRT_URI="qemu:///system"
readonly LIBVIRT_NETWORK="default"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly IMAGE_DIR="/var/lib/libvirt/images/kvm-agent"
readonly VM_IMAGE_DIR="${IMAGE_DIR}/vms"
readonly SSH_COMMAND_TIMEOUT_SECONDS=20
readonly SWARM_PROVISION_TIMEOUT_SECONDS=1800
readonly JOURNAL_PROVISION_TIMEOUT_SECONDS=1200
readonly DEFAULT_DISK_GB=120

VM_NAME="kvm-agent"
GUEST_USER="agent"
RAM_MB=""
VCPUS=""
DISK_GB="$DEFAULT_DISK_GB"
WAIT_FOR_GUEST="yes"
RESTRICT_PRIVATE_NETWORKS="yes"
GATEWAY_ADDRESS=""
OPERATION="create"
REPLACE_EXISTING="no"
WITH_FORMAL_METHODS="no"
SWARM_ROLE="none"
SWARM_NETWORK=""
SWARM_ROLE_OPTION_SET="no"
ADD_SWARM_ROLE_SET="no"
JOURNAL_BACKEND="evidence"
JOURNAL_TIMEZONE="Europe/Prague"
JOURNAL_PROJECTS=()
JOURNAL_ALLOW_REMOTE_REPORTING="no"

WORK_DIR=""
VM_DISK=""
SEED_IMAGE=""
CREATED_VM_ARTIFACTS="no"

usage() {
  cat <<'EOF'
Usage:
  ./setup-kvm-agent.sh [OPTIONS]

Create a graphical Ubuntu 24.04 LTS KVM guest and install Codex, Claude Code,
OpenCode, Aider, and Ollama inside it. Formal-methods and cross-host swarm
support are optional.

Options:
  --name NAME        VM and host name (default: kvm-agent)
  --user NAME        Guest login name (default: agent)
  --memory MB        Guest RAM in MiB (default: 75% of host RAM, capped at
                     32 GiB while leaving at least 2 GiB for the host)
  --vcpus NUMBER     Guest virtual CPUs (default: 75% of host CPUs, capped at
                     16)
  --disk GB          Guest virtual disk size (default: 120)
  --no-wait          Start provisioning but do not wait for it to finish
  --allow-lan        Permit guest egress to private and link-local address
                     ranges. The firewall remains enabled and still denies
                     unsolicited inbound traffic. Use only when needed.
  --formal-methods   Also install Lean 4/elan, Isabelle2025-2/HOL,
                     GHC/GHCup, Cabal, HLS, HLint, VS Code, and the official
                     Lean and Haskell VS Code extensions inside the guest.
                     This may add several hours to first provisioning.
  --swarm-role ROLE  Prepare this guest as a cross-host swarm "manager",
                     "worker", or "both". A manager receives a dedicated SSH
                     key; a worker receives a locked-down non-sudo account.
                     The role does not change the VM name.
  --swarm-network NET
                     Overlay network for --swarm-role or --add-swarm:
                     "tailscale" (default) or "wireguard". Installation does
                     not enroll a Tailscale device or invent WireGuard peers.
  --add-swarm ROLE   Add the selected swarm role to an already-provisioned VM.
                     Accepts --name, --user, and --swarm-network.
  --add-journal      Install or update automatic research-journal reporting in
                     an already-provisioned VM. This does not recreate the VM.
  --journal-project PATH
                     Initialize and register this guest-side Git project.
                     May be repeated. With no project, installs the journal
                     commands and timers for later `init` plus root `register`.
  --journal-backend BACKEND
                     Reporter used by --add-journal: evidence-only "evidence"
                     (default), "claude", or "codex". Authentication is never
                     configured here. OpenCode is intentionally unavailable as
                     an unattended reporter because equivalent confinement has
                     not been established.
  --journal-allow-remote-reporting
                     Explicitly consent to sending bounded project metadata to
                     the selected model provider. Required for claude/codex.
  --journal-timezone ZONE
                     IANA timezone for report periods and timers (default:
                     Europe/Prague).
  --resize-existing  Change RAM and/or vCPU allocation of an existing, powered
                     off VM without deleting its disk. Use with --memory and/or
                     --vcpus.
  --replace-existing Completely remove an existing VM of the selected name,
                     then create it again. The exact VM name must be typed to
                     confirm deletion. Shared caches and extra disks are kept.
  --finalize-existing
                     Resume verified final cleanup of an already-provisioned
                     VM after an interrupted wait or a --no-wait setup.
  -h, --help         Show this help without changing the system

Requirements:
  * x86-64 Ubuntu 24.04 or 26.04 LTS host
  * hardware virtualisation enabled in firmware
  * sudo access in the invoking host account
  * an interactive terminal and internet access

Run this file as the ordinary host account, not with "sudo ./...".
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

select_operation() {
  local requested="$1"
  local option="$2"
  if [[ "$OPERATION" != "create" && "$OPERATION" != "$requested" ]]; then
    die "$option cannot be combined with another operation mode."
  fi
  OPERATION="$requested"
}

parse_qemu_virtual_size_bytes() {
  python3 -c '
import json
import sys

try:
    info = json.load(sys.stdin)
except (json.JSONDecodeError, OSError, TypeError, ValueError):
    raise SystemExit(1)

value = info.get("virtual-size") if isinstance(info, dict) else None
if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
    raise SystemExit(1)

print(value)
'
}

guest_ipv4_addresses() {
  LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
    domifaddr "$VM_NAME" --source lease 2>/dev/null \
    | awk '
        $3 == "ipv4" {
          split($4, address, "/")
          if (!seen[address[1]]++) print address[1]
        }
      '
}

guest_ssh_to() {
  local address="$1"
  local timeout_seconds="$2"
  shift 2

  timeout --foreground --signal=TERM --kill-after=5s \
    "${timeout_seconds}s" \
    ssh "${ssh_options[@]}" "${GUEST_USER}@${address}" "$@"
}

guest_ssh() {
  [[ -n "$GUEST_IP" ]] || return 2
  guest_ssh_to "$GUEST_IP" "$SSH_COMMAND_TIMEOUT_SECONDS" "$@"
}

# Set GUEST_IP to a current address that belongs to this domain and accepts the
# repository recovery key. Re-query every iteration because DHCP may assign a
# different address after reboot. Every SSH command has its own hard deadline,
# so a connected guest cannot defeat the overall retry limit by leaving a
# remote command blocked. The first argument denotes five-second polling slots;
# an absolute wall-clock deadline enforces the corresponding overall limit.
wait_for_guest_ssh() {
  local attempts="$1"
  local remote_check="${2:-true}"
  local candidate
  local started="$SECONDS"
  local deadline=$((SECONDS + attempts * 5))
  local next_progress=$((SECONDS + 60))
  local probe_timeout
  local probe_status
  local remaining

  while ((SECONDS < deadline)); do
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      remaining=$((deadline - SECONDS))
      ((remaining > 0)) || return 1
      probe_timeout="$SSH_COMMAND_TIMEOUT_SECONDS"
      ((probe_timeout <= remaining)) || probe_timeout="$remaining"
      if guest_ssh_to "$candidate" "$probe_timeout" \
          "$remote_check" >/dev/null 2>&1; then
        GUEST_IP="$candidate"
        return 0
      else
        probe_status=$?
        if ((probe_status == 42)); then
          GUEST_IP="$candidate"
          return 2
        fi
      fi
    done < <(guest_ipv4_addresses)
    remaining=$((deadline - SECONDS))
    ((remaining > 0)) || break
    if ((SECONDS >= next_progress)); then
      printf 'Still waiting for the guest (%d minute(s) elapsed)...\n' \
        "$(((SECONDS - started) / 60))" >&2
      next_progress=$((SECONDS + 60))
    fi
    if ((remaining < 5)); then
      sleep "$remaining"
    else
      sleep 5
    fi
  done
  return 1
}

# Complete the same verified, fail-closed finalization for both a fresh setup
# and --finalize-existing. Nothing is detached or deleted until the recovery
# key reaches this named domain and the guest provisioning marker is present.
finalize_managed_guest() {
  local managed_seed_image="${VM_IMAGE_DIR}/${VM_NAME}-seed.img"
  local provisioning_attempts=1080
  local pre_reboot_boot_id
  local reboot_required
  local live_blocks
  local config_blocks
  local seed_targets
  local seed_target
  local wait_status=0

  [[ -r "$SSH_PRIVATE_KEY" ]] || die \
    "Recovery SSH key not found: $SSH_PRIVATE_KEY. Check --name: the default VM name is 'kvm-agent', and swarm roles do not rename the VM."
  sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1 || die \
    "No libvirt VM named '$VM_NAME' exists."

  ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ConnectionAttempts=1
    -o ForwardAgent=no
    -o IdentitiesOnly=yes
    -o ServerAliveCountMax=1
    -o ServerAliveInterval=5
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
    -i "$SSH_PRIVATE_KEY"
  )

  # The ordinary agent bundle is allowed 90 minutes. The optional Lean,
  # Isabelle and Haskell toolchains involve several large downloads and may
  # build HLint locally, so their explicitly selected path gets six hours.
  if [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
    provisioning_attempts=4320
  fi

  log "Waiting for recovery SSH and successful guest provisioning"
  GUEST_IP=""
  wait_for_guest_ssh "$provisioning_attempts" \
    "if sudo test -f /var/lib/kvm-agent/provisioning-failed; then exit 42; fi; sudo test -f /var/lib/kvm-agent/provisioned && { test -f /etc/cloud/cloud-init.disabled || sudo cloud-init status 2>/dev/null | grep -Eq '^status: done([[:space:]]|$)'; }" \
    || wait_status=$?
  if ((wait_status != 0)); then
    if ((wait_status == 2)); then
      warn "The guest reported that provisioning failed."
    elif [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
      warn "Could not verify successful provisioning within six hours."
    else
      warn "Could not verify successful provisioning within 90 minutes."
    fi
    # A reachable guest may still contain useful failure diagnostics.
    if wait_for_guest_ssh 1 true; then
      guest_ssh \
        "sudo cloud-init status --long || true; sudo tail -n 160 /var/log/kvm-agent-provision.log || true" \
        >&2 || true
    fi
    die "Finalization stopped without changing cloud-init or deleting the seed."
  fi

  # Disable cloud-init while the verified guest is stable. In earlier releases
  # this happened after requesting a reboot, which allowed the asynchronous
  # shutdown to race the next SSH command. Keeping the seed attached until all
  # post-reboot checks pass remains fail-closed.
  log "Disabling future cloud-init runs in the guest"
  guest_ssh \
    "sudo install -o root -g root -m 0644 /dev/null /etc/cloud/cloud-init.disabled" \
    || die "Could not disable future cloud-init runs; the seed was retained."
  guest_ssh \
    "sudo test -f /etc/cloud/cloud-init.disabled" || die \
    "Could not verify the cloud-init disable marker; the seed was retained."

  # cloud-init caches the original user-data inside the guest. It contains the
  # local GUI password hash, so removing only the host-side seed is incomplete.
  # Keep cloud-init disabled first so a cleanup failure remains fail-closed.
  #
  # "cloud-init clean" is best effort. Its exit status and the exact set of
  # files it removes vary between releases, so the guarantee below comes from
  # verifying the hazard directly - no cached user-data, cloud-config, or
  # vendor-data artifact, and no SHA-512 crypt string anywhere under the
  # cloud-init state and log paths - rather than from trusting that command.
  log "Removing cached cloud-init user data from the guest"
  guest_ssh "$(cat <<'REMOTE_CLOUD_INIT_CLEAN'
set -eu

# An unusable search or a refused sudo would report "nothing found" and read as
# success, so prove both detectors work on a known-positive file before their
# negative result is allowed to mean anything.
probe_directory=/var/lib/cloud/.kvm-agent-clean-probe
sudo rm -rf -- "$probe_directory"
sudo mkdir -p -- "$probe_directory"
sudo tee "$probe_directory/user-data.txt" >/dev/null <<'PROBE'
hashed_passwd: '$6$probe$probe'
PROBE
found_name="$(sudo find /var/lib/cloud -name 'user-data*' -print -quit)"
[ -n "$found_name" ] || {
  echo 'Cannot search guest cloud-init state; cleanup is unverifiable.' >&2
  exit 1
}
sudo grep -rqsF '$6$' /var/lib/cloud || {
  echo 'Cannot scan guest cloud-init state; cleanup is unverifiable.' >&2
  exit 1
}
sudo rm -rf -- "$probe_directory"

sudo cloud-init clean --logs >/dev/null 2>&1 || true
sudo rm -rf -- /var/lib/cloud/instance /var/lib/cloud/instances
sudo rm -f -- /var/log/cloud-init.log /var/log/cloud-init-output.log

remaining="$(
  sudo find /var/lib/cloud \
    \( -name 'user-data*' -o -name 'cloud-config*' -o -name 'vendor-data*' \) \
    -print -quit
)"
if [ -n "$remaining" ]; then
  echo "Cached cloud-init artifact remains: $remaining" >&2
  exit 1
fi
if sudo grep -rqsF '$6$' /var/lib/cloud /var/log/cloud-init.log \
    /var/log/cloud-init-output.log; then
  echo 'A SHA-512 password hash remains in guest cloud-init state.' >&2
  exit 1
fi
REMOTE_CLOUD_INIT_CLEAN
  )" || die "Could not clean cached cloud-init user data; cloud-init is disabled and the seed was retained."

  if ! reboot_required="$(
      guest_ssh \
        "if test -e /var/run/reboot-required; then printf 'yes\n'; else printf 'no\n'; fi"
    )"; then
    die "Could not determine whether the guest requires a reboot; cloud-init is disabled and the seed was retained."
  fi
  [[ "$reboot_required" == "yes" || "$reboot_required" == "no" ]] || die \
    "The guest returned an invalid reboot-required state; cloud-init is disabled and the seed was retained."

  if [[ "$reboot_required" == "yes" ]]; then
    if ! pre_reboot_boot_id="$(
        guest_ssh "cat /proc/sys/kernel/random/boot_id"
      )"; then
      die "Could not read the guest boot ID before reboot; cloud-init is disabled and the seed was retained."
    fi
    [[ "$pre_reboot_boot_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die \
      "The guest returned an invalid boot ID; cloud-init is disabled and the seed was retained."

    log "Rebooting once to activate guest kernel and desktop updates"
    guest_ssh \
      "sudo systemctl reboot" >/dev/null 2>&1 || true

    # systemctl reboot is asynchronous: SSH may briefly remain usable while
    # pam_nologin is already preparing shutdown. A changed kernel boot ID, not
    # merely a successful SSH connection, proves that the new boot is running.
    # The guest may also return with a different DHCP lease.
    GUEST_IP=""
    if ! wait_for_guest_ssh 180 \
        "sudo test -f /var/lib/kvm-agent/provisioned && sudo test -f /etc/cloud/cloud-init.disabled && new_boot_id=\$(cat /proc/sys/kernel/random/boot_id) && test \"\$new_boot_id\" != \"$pre_reboot_boot_id\""; then
      die "The guest did not complete its update reboot within 15 minutes; cloud-init is disabled and the seed was retained."
    fi
  fi

  # Re-check the marker in the final boot before touching the seed.
  guest_ssh \
    "sudo test -f /etc/cloud/cloud-init.disabled" || die \
    "Could not verify the cloud-init disable marker; the seed was retained."

  log "Detaching and destroying the cloud-init seed"
  live_blocks="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domblklist "$VM_NAME" --details
  )" || die \
    "Could not inspect the current block-device configuration; the seed was retained."
  config_blocks="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domblklist "$VM_NAME" --inactive --details
  )" || die \
    "Could not inspect the persistent block-device configuration; the seed was retained."

  seed_targets="$(
    printf '%s\n%s\n' "$live_blocks" "$config_blocks" \
      | awk -v source="$managed_seed_image" \
          '$4 == source { print $3 }' \
      | sort -u
  )"

  if [[ -n "$seed_targets" ]]; then
    while IFS= read -r seed_target; do
      [[ -n "$seed_target" ]] || continue
      if ! sudo virsh --connect "$LIBVIRT_URI" change-media "$VM_NAME" \
          "$seed_target" --eject --live --config --force >/dev/null 2>&1; then
        sudo virsh --connect "$LIBVIRT_URI" change-media "$VM_NAME" \
          "$seed_target" --eject --config --force >/dev/null 2>&1 || die \
          "Could not detach seed target '$seed_target'; the seed file was retained."
      fi
    done <<< "$seed_targets"
  fi

  # Query failures are fatal. They must never be interpreted as proof that the
  # seed is detached.
  live_blocks="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domblklist "$VM_NAME" --details
  )" || die \
    "Could not verify the current block-device configuration; the seed was retained."
  config_blocks="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domblklist "$VM_NAME" --inactive --details
  )" || die \
    "Could not verify the persistent block-device configuration; the seed was retained."

  if grep -Fq -- "$managed_seed_image" <<< "$live_blocks" \
      || grep -Fq -- "$managed_seed_image" <<< "$config_blocks"; then
    die "The seed is still attached; its file was retained."
  fi

  if sudo test -e "$managed_seed_image" \
      || sudo test -L "$managed_seed_image"; then
    # Best-effort overwrite before deletion. This is not guaranteed secure
    # erase on SSD, copy-on-write, or layered storage.
    sudo shred --remove --zero -- "$managed_seed_image" 2>/dev/null \
      || sudo rm -f -- "$managed_seed_image"
  fi
  if sudo test -e "$managed_seed_image" \
      || sudo test -L "$managed_seed_image"; then
    die "The seed file still exists after attempted removal: $managed_seed_image"
  fi

  # Prevent the EXIT trap from treating a successfully removed seed as a
  # partial artifact during a fresh setup.
  if [[ "$SEED_IMAGE" == "$managed_seed_image" ]]; then
    SEED_IMAGE=""
  fi

  log "Installed guest tool versions"
  guest_ssh "sudo cat /var/lib/kvm-agent/installed-versions.txt" || die \
    "Cleanup succeeded, but installed tool versions could not be read."
}

add_swarm_to_managed_guest() {
  local swarm_script_b64

  [[ -r "$SSH_PRIVATE_KEY" ]] || die \
    "Recovery SSH key not found: $SSH_PRIVATE_KEY. Check --name: the default VM name is 'kvm-agent', and swarm roles do not rename the VM."
  sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1 || die \
    "No libvirt VM named '$VM_NAME' exists."

  WORK_DIR="$(mktemp -d)"
  write_swarm_provision_script "$WORK_DIR/swarm-provision.sh"
  swarm_script_b64="$(base64 -w 0 "$WORK_DIR/swarm-provision.sh")"

  ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ConnectionAttempts=1
    -o ForwardAgent=no
    -o IdentitiesOnly=yes
    -o ServerAliveCountMax=1
    -o ServerAliveInterval=5
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
    -i "$SSH_PRIVATE_KEY"
  )

  log "Waiting for recovery SSH to the existing guest"
  GUEST_IP=""
  wait_for_guest_ssh 60 true || die \
    "Could not reach '$VM_NAME' through its managed recovery SSH key within five minutes."

  log "Adding the '$SWARM_ROLE' swarm role with '$SWARM_NETWORK' networking"
  if ! guest_ssh_to "$GUEST_IP" "$SWARM_PROVISION_TIMEOUT_SECONDS" \
      "printf '%s' '$swarm_script_b64' | base64 -d | sudo install -o root -g root -m 0700 /dev/stdin /usr/local/sbin/kvm-agent-swarm-provision && sudo /usr/local/sbin/kvm-agent-swarm-provision '$SWARM_ROLE' '$SWARM_NETWORK' '$GUEST_USER'"; then
    warn "Swarm provisioning failed inside the existing guest."
    warn "Recent guest-side swarm log follows:"
    guest_ssh "sudo tail -n 200 /var/log/kvm-agent-swarm.log 2>/dev/null || true" >&2 || true
    die "Review the log above, correct the reported problem, and rerun --add-swarm."
  fi

  log "Swarm profile"
  guest_ssh "kvm-agent-swarm-status" || die \
    "Swarm provisioning completed, but its status could not be read."
}

add_journal_to_managed_guest() {
  local installer_b64
  local projects_b64
  local projects_json
  local runtime_b64
  local journal_source="${SCRIPT_DIR}/journal/kvm_agent_journal.py"
  local installer_source="${SCRIPT_DIR}/journal/install-journal.sh"

  [[ -r "$SSH_PRIVATE_KEY" ]] || die \
    "Recovery SSH key not found: $SSH_PRIVATE_KEY. Check --name: the default VM name is 'kvm-agent'."
  sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1 || die \
    "No libvirt VM named '$VM_NAME' exists."
  [[ -r "$journal_source" && -r "$installer_source" ]] || die \
    "Journal support files are missing under ${SCRIPT_DIR}/journal. Clone or update the complete repository."

  runtime_b64="$(base64 -w 0 "$journal_source")"
  installer_b64="$(base64 -w 0 "$installer_source")"
  projects_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' \
    "${JOURNAL_PROJECTS[@]}")"
  projects_b64="$(printf '%s' "$projects_json" | base64 -w 0)"

  ssh_options=(
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ConnectionAttempts=1
    -o ForwardAgent=no
    -o IdentitiesOnly=yes
    -o ServerAliveCountMax=1
    -o ServerAliveInterval=5
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
    -i "$SSH_PRIVATE_KEY"
  )

  log "Waiting for recovery SSH to the existing guest"
  GUEST_IP=""
  wait_for_guest_ssh 60 true || die \
    "Could not reach '$VM_NAME' through its managed recovery SSH key within five minutes."

  log "Installing automatic research journals with '$JOURNAL_BACKEND' reporting"
  if ! guest_ssh_to "$GUEST_IP" "$JOURNAL_PROVISION_TIMEOUT_SECONDS" \
      "sudo install -d -o root -g root -m 0755 /usr/local/lib/kvm-agent-journal && printf '%s' '$runtime_b64' | base64 -d | sudo install -o root -g root -m 0755 /dev/stdin /usr/local/lib/kvm-agent-journal/kvm_agent_journal.py && printf '%s' '$installer_b64' | base64 -d | sudo install -o root -g root -m 0700 /dev/stdin /usr/local/sbin/kvm-agent-journal-provision && sudo /usr/local/sbin/kvm-agent-journal-provision '$GUEST_USER' '$JOURNAL_BACKEND' '$JOURNAL_TIMEZONE' '$projects_b64' '$JOURNAL_ALLOW_REMOTE_REPORTING'"; then
    warn "Research-journal installation failed inside the existing guest."
    warn "Recent guest-side journal installation log follows:"
    guest_ssh \
      "sudo tail -n 200 /var/log/kvm-agent-journal-install.log 2>/dev/null || true" \
      >&2 || true
    die "Review the log above, correct the reported problem, and rerun --add-journal."
  fi

  log "Research-journal profile"
  guest_ssh \
    "cat /var/lib/kvm-agent/journal-profile && kvm-agent-journal status" || die \
    "Journal installation completed, but its status could not be read."
}

resize_managed_guest() {
  local state
  local domain_info
  local managed_save="no"
  local current_memory_kib=""
  local current_vcpus=""

  domain_info="$(LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME")" || die \
    "No libvirt VM named '$VM_NAME' exists."
  managed_save="$(awk -F: '
    /^Managed save:/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print tolower(value)
      exit
    }
  ' <<< "$domain_info")"
  [[ "$managed_save" != "yes" ]] || die \
    "VM '$VM_NAME' has a managed-save image. Start it and perform a normal full shutdown before resizing; otherwise libvirt may restore the old saved resource state."
  state="$(LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" domstate "$VM_NAME" | tr -d '\r' | xargs)"
  [[ "$state" == "shut off" ]] || die \
    "Power off '$VM_NAME' before resizing it (current state: ${state:-unknown}). The VM and its disk are not removed."

  if [[ -n "$RAM_MB" ]]; then
    current_memory_kib="$({
      LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" dumpxml "$VM_NAME" --inactive
    } | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
node = root.find("currentMemory")
if node is None:
    node = root.find("memory")
if node is None or not (node.text or "").strip().isdigit():
    raise SystemExit(1)
value = int(node.text.strip())
unit = (node.get("unit") or "KiB").lower()
scale = {"b": 1/1024, "kib": 1, "mib": 1024, "gib": 1024*1024}.get(unit)
if scale is None:
    raise SystemExit(1)
print(int(value * scale))
')" || die "Could not read the existing guest memory configuration."

    if ((RAM_MB * 1024 >= current_memory_kib)); then
      sudo virsh --connect "$LIBVIRT_URI" setmaxmem "$VM_NAME" \
        "${RAM_MB}MiB" --config >/dev/null || die \
        "Could not raise the persistent maximum memory."
      sudo virsh --connect "$LIBVIRT_URI" setmem "$VM_NAME" \
        "${RAM_MB}MiB" --config >/dev/null || die \
        "Could not set the persistent guest memory."
    else
      sudo virsh --connect "$LIBVIRT_URI" setmem "$VM_NAME" \
        "${RAM_MB}MiB" --config >/dev/null || die \
        "Could not lower the persistent guest memory."
      sudo virsh --connect "$LIBVIRT_URI" setmaxmem "$VM_NAME" \
        "${RAM_MB}MiB" --config >/dev/null || die \
        "Could not lower the persistent maximum memory."
    fi
  fi

  if [[ -n "$VCPUS" ]]; then
    current_vcpus="$(LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      vcpucount "$VM_NAME" --maximum --config)" || die \
      "Could not read the existing guest vCPU configuration."
    positive_integer "$current_vcpus" || die \
      "libvirt returned an invalid maximum vCPU count."

    if ((VCPUS >= current_vcpus)); then
      sudo virsh --connect "$LIBVIRT_URI" setvcpus "$VM_NAME" "$VCPUS" \
        --maximum --config >/dev/null || die \
        "Could not raise the persistent maximum vCPU count."
      sudo virsh --connect "$LIBVIRT_URI" setvcpus "$VM_NAME" "$VCPUS" \
        --config >/dev/null || die \
        "Could not set the persistent active vCPU count."
    else
      sudo virsh --connect "$LIBVIRT_URI" setvcpus "$VM_NAME" "$VCPUS" \
        --config >/dev/null || die \
        "Could not lower the persistent active vCPU count."
      sudo virsh --connect "$LIBVIRT_URI" setvcpus "$VM_NAME" "$VCPUS" \
        --maximum --config >/dev/null || die \
        "Could not lower the persistent maximum vCPU count."
    fi
  fi

  log "Updated persistent resources for '$VM_NAME'"
  LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME"
  printf '\nStart the existing VM normally; no disk or guest data was removed.\n'
}

# Report "present", "absent", or "unknown" for the target domain. "unknown"
# means libvirt could not be queried at all, which must never be treated as
# "the domain does not exist": that mistake deletes a live VM's disk.
domain_state() {
  local domain_names

  if ! domain_names="$(
    LC_ALL=C sudo -n virsh --connect "$LIBVIRT_URI" list --all --name 2>/dev/null
  )"; then
    printf 'unknown\n'
    return 0
  fi

  if grep -Fxq -- "$VM_NAME" <<< "$domain_names"; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

cleanup() {
  local exit_status=$?
  local state

  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi

  # Remove only artifacts created by this invocation and only when libvirt is
  # reachable and reports no domain referring to them. A failed virt-install
  # can leave a useful partial domain, in which case the files are deliberately
  # retained. "sudo -n" is used so that an expired sudo timestamp at exit time
  # cannot hang on a password prompt or be misread as an absent domain.
  if [[ "$CREATED_VM_ARTIFACTS" == "yes" ]]; then
    state="$(domain_state)"
    case "$state" in
      absent)
        [[ -z "$VM_DISK" ]] || sudo -n rm -f -- "$VM_DISK" || true
        [[ -z "$SEED_IMAGE" ]] || sudo -n rm -f -- "$SEED_IMAGE" || true
        ;;
      unknown)
        printf 'Warning: could not query libvirt during cleanup; leaving %s in place.\n' \
          "$VM_IMAGE_DIR" >&2
        ;;
    esac
  fi

  exit "$exit_status"
}

trap cleanup EXIT

positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

write_swarm_provision_script() {
  local destination="$1"

  cat > "$destination" <<'SWARM_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

role="${1:?swarm role is required}"
network="${2:?swarm network is required}"
guest_user="${3:?guest user is required}"
marker="/var/lib/kvm-agent/swarm-profile"
worker_user="agent-worker"
worker_home="/home/${worker_user}"

case "$role" in
  manager|worker|both) ;;
  *) echo "Invalid swarm role: $role" >&2; exit 2 ;;
esac
case "$network" in
  tailscale|wireguard) ;;
  *) echo "Invalid swarm network: $network" >&2; exit 2 ;;
esac

guest_home="$(getent passwd "$guest_user" | awk -F: '{print $6}')"
guest_group="$(id -gn "$guest_user")"
[[ -n "$guest_home" && -d "$guest_home" ]] || {
  echo "Cannot resolve guest home for $guest_user." >&2
  exit 1
}

exec > >(tee -a /var/log/kvm-agent-swarm.log) 2>&1
echo "Configuring KVM-Agent swarm profile: role=$role network=$network"

existing_network=""
existing_roles=""
if [[ -r "$marker" ]]; then
  existing_network="$(sed -n 's/^network=//p' "$marker" | head -n 1)"
  existing_roles="$(sed -n 's/^roles=//p' "$marker" | head -n 1)"
fi
if [[ -n "$existing_network" && "$existing_network" != "$network" ]]; then
  echo "This guest already uses swarm network '$existing_network'; refusing to mix it with '$network'." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y openssh-client openssh-server rsync ufw ca-certificates curl

case "$network" in
  tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      installer="$(mktemp /var/lib/kvm-agent/tailscale-install.XXXXXXXX)"
      trap 'rm -f -- "${installer:-}"' EXIT
      curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
        https://tailscale.com/install.sh --output "$installer"
      chown root:root "$installer"
      chmod 0500 "$installer"
      bash "$installer"
      rm -f -- "$installer"
      trap - EXIT
    fi
    systemctl enable --now tailscaled.service
    # Keep the normal private-range egress block intact. Only tailnet-assigned
    # addresses and MagicDNS are reachable through tailscale0; subnet routes
    # and exit nodes are deliberately not enabled by provisioning.
    if ! ufw show added | grep -Fq 'ufw allow out on tailscale0 to 100.64.0.0/10'; then
      ufw insert 1 allow out on tailscale0 to 100.64.0.0/10 >/dev/null
    fi
    if [[ "$role" == worker || "$role" == both ]]; then
      if ! ufw show added | grep -Fq 'ufw allow in on tailscale0 from 100.64.0.0/10 to any port 22 proto tcp'; then
        ufw insert 1 allow in on tailscale0 from 100.64.0.0/10 \
          to any port 22 proto tcp >/dev/null
      fi
    fi
    ;;
  wireguard)
    apt-get -o DPkg::Lock::Timeout=600 install -y wireguard-tools
    # WireGuard peer addresses are selected by the operator later. Interface-
    # scoped rules preserve the default private-range block on every other
    # interface and permit only authenticated wg0 peers once configured.
    if ! ufw show added | grep -Fq 'ufw allow out on wg0'; then
      ufw insert 1 allow out on wg0 >/dev/null
    fi
    if [[ "$role" == worker || "$role" == both ]]; then
      if ! ufw show added | grep -Fq 'ufw allow in on wg0 to any port 22 proto tcp'; then
        ufw insert 1 allow in on wg0 to any port 22 proto tcp >/dev/null
      fi
    fi
    ;;
esac

systemctl enable --now ssh.service
ufw --force enable >/dev/null

has_role() {
  local wanted="$1"
  [[ ",${existing_roles}," == *",${wanted},"* ]]
}

add_role() {
  local wanted="$1"
  if ! has_role "$wanted"; then
    if [[ -n "$existing_roles" ]]; then
      existing_roles="${existing_roles},${wanted}"
    else
      existing_roles="$wanted"
    fi
  fi
}

if [[ "$role" == manager || "$role" == both ]]; then
  add_role manager
  install -d -o "$guest_user" -g "$guest_group" -m 0700 "$guest_home/.ssh"
  manager_key="$guest_home/.ssh/id_ed25519_kvm_agent_swarm"
  if [[ ! -e "$manager_key" && ! -e "${manager_key}.pub" ]]; then
    runuser -u "$guest_user" -- ssh-keygen -q -t ed25519 -N '' \
      -C "kvm-agent-swarm-manager@$(hostname)" -f "$manager_key"
  fi
  chown "$guest_user:$guest_group" "$manager_key" "${manager_key}.pub"
  chmod 0600 "$manager_key"
  chmod 0644 "${manager_key}.pub"
  manager_known_hosts="$guest_home/.ssh/known_hosts_kvm_agent_swarm"
  touch "$manager_known_hosts"
  chown "$guest_user:$guest_group" "$manager_known_hosts"
  chmod 0600 "$manager_known_hosts"

  cat > /usr/local/bin/kvm-agent-swarm-public-key <<PUBLIC_KEY_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
cat '$manager_key.pub'
PUBLIC_KEY_SCRIPT
  chown root:root /usr/local/bin/kvm-agent-swarm-public-key
  chmod 0755 /usr/local/bin/kvm-agent-swarm-public-key

  cat > /usr/local/bin/kvm-agent-swarm-manager-info <<MANAGER_INFO
#!/usr/bin/env bash
set -euo pipefail
printf 'Manager account: %s\n' '$guest_user'
printf 'Manager private key: %s (no passphrase; guest-local)\n' '$manager_key'
printf 'Manager public-key fingerprint: '
ssh-keygen -lf '$manager_key.pub' -E sha256 | awk '{print \$2}'
printf 'Manager public key (copy this entire line to the worker):\n'
cat '$manager_key.pub'
MANAGER_INFO
  chown root:root /usr/local/bin/kvm-agent-swarm-manager-info
  chmod 0755 /usr/local/bin/kvm-agent-swarm-manager-info

  cat > /usr/local/bin/kvm-agent-swarm-configure-worker <<MANAGER_CONFIGURE
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat >&2 <<'USAGE'
Usage:
  kvm-agent-swarm-configure-worker WORKER_ADDRESS SHA256:FINGERPRINT

Read the expected ED25519 host-key fingerprint from
kvm-agent-swarm-worker-info on the worker VM. This command verifies the key
before storing it and creates a dedicated SSH configuration for the worker.
USAGE
  exit 2
}

[[ \$# -eq 2 ]] || usage
worker_address="\$1"
expected_fingerprint="\$2"
[[ "\$worker_address" =~ ^[A-Za-z0-9._:-]+\$ ]] || {
  echo 'Worker address contains unsupported characters.' >&2
  exit 2
}
[[ "\$expected_fingerprint" == SHA256:* ]] || {
  echo 'Expected fingerprint must begin with SHA256:.' >&2
  exit 2
}

manager_key='$manager_key'
known_hosts='$manager_known_hosts'
ssh_config='$guest_home/.ssh/config_kvm_agent_swarm'
[[ -r "\$manager_key" ]] || {
  echo "Manager private key is missing: \$manager_key" >&2
  exit 1
}

scan_file="\$(mktemp)"
key_file="\$(mktemp)"
trap 'rm -f -- "\$scan_file" "\$key_file"' EXIT
ssh-keyscan -T 10 -t ed25519 -- "\$worker_address" >"\$scan_file" 2>/dev/null || {
  echo "Could not read the worker ED25519 host key from \$worker_address:22." >&2
  exit 1
}
grep -v '^[#[:space:]]*\$' "\$scan_file" >"\$key_file"
[[ -s "\$key_file" ]] || {
  echo 'ssh-keyscan returned no ED25519 host key.' >&2
  exit 1
}
actual_fingerprints="\$(ssh-keygen -lf "\$key_file" -E sha256 | awk '{print \$2}' | sort -u)"
[[ "\$actual_fingerprints" == "\$expected_fingerprint" ]] || {
  echo 'Worker host-key verification failed.' >&2
  echo "Expected: \$expected_fingerprint" >&2
  echo "Received: \$actual_fingerprints" >&2
  exit 1
}

install -d -m 0700 '$guest_home/.ssh'
touch "\$known_hosts"
chmod 0600 "\$known_hosts"
ssh-keygen -R "\$worker_address" -f "\$known_hosts" >/dev/null 2>&1 || true
cat "\$key_file" >>"\$known_hosts"

cat >"\$ssh_config" <<SSH_CONFIG
Host kvm-agent-worker
    HostName \$worker_address
    User agent-worker
    IdentityFile \$manager_key
    IdentitiesOnly yes
    IdentityAgent none
    ForwardAgent no
    ForwardX11 no
    BatchMode yes
    ConnectTimeout 10
    StrictHostKeyChecking yes
    UserKnownHostsFile \$known_hosts
    HostKeyAlgorithms ssh-ed25519
    RequestTTY no
SSH_CONFIG
chmod 0600 "\$ssh_config"

printf 'Verified worker host key: %s\n' "\$actual_fingerprints"
printf 'Stored dedicated SSH configuration: %s\n' "\$ssh_config"
printf 'Next test: kvm-agent-swarm-test\n'
MANAGER_CONFIGURE
  chown root:root /usr/local/bin/kvm-agent-swarm-configure-worker
  chmod 0755 /usr/local/bin/kvm-agent-swarm-configure-worker

  cat > /usr/local/bin/kvm-agent-swarm-ssh <<MANAGER_SSH
#!/usr/bin/env bash
set -euo pipefail
config='$guest_home/.ssh/config_kvm_agent_swarm'
[[ -r "\$config" ]] || {
  echo 'Worker is not configured. Run kvm-agent-swarm-configure-worker first.' >&2
  exit 1
}
exec ssh -F "\$config" kvm-agent-worker "\$@"
MANAGER_SSH
  chown root:root /usr/local/bin/kvm-agent-swarm-ssh
  chmod 0755 /usr/local/bin/kvm-agent-swarm-ssh

  cat > /usr/local/bin/kvm-agent-swarm-rsync <<MANAGER_RSYNC
#!/usr/bin/env bash
set -euo pipefail
config='$guest_home/.ssh/config_kvm_agent_swarm'
[[ -r "\$config" ]] || {
  echo 'Worker is not configured. Run kvm-agent-swarm-configure-worker first.' >&2
  exit 1
}
remote_operands=0
for argument in "\$@"; do
  case "\$argument" in
    -e|--rsh|--rsh=*|--rsync-path|--rsync-path=*)
      echo 'This wrapper does not permit overriding its pinned SSH transport.' >&2
      exit 2
      ;;
    -*)
      continue
      ;;
  esac
  if [[ "\$argument" == *:* ]]; then
    [[ "\$argument" == kvm-agent-worker:* \
        && "\$argument" != kvm-agent-worker::* ]] || {
      echo 'Remote rsync operands must use the pinned kvm-agent-worker: alias.' >&2
      exit 2
    }
    ((remote_operands += 1))
  fi
done
[[ \$remote_operands -eq 1 ]] || {
  echo 'Specify exactly one kvm-agent-worker: remote operand.' >&2
  exit 2
}
printf -v remote_shell 'ssh -F %q' "\$config"
exec rsync -e "\$remote_shell" "\$@"
MANAGER_RSYNC
  chown root:root /usr/local/bin/kvm-agent-swarm-rsync
  chmod 0755 /usr/local/bin/kvm-agent-swarm-rsync

  cat > /usr/local/bin/kvm-agent-swarm-test <<'MANAGER_TEST'
#!/usr/bin/env bash
set -euo pipefail
kvm-agent-swarm-ssh 'hostname; whoami; id; printf "Isabelle: "; command -v isabelle || echo not-installed'
MANAGER_TEST
  chown root:root /usr/local/bin/kvm-agent-swarm-test
  chmod 0755 /usr/local/bin/kvm-agent-swarm-test

  cat > /usr/local/bin/kvm-agent-swarm-job <<'JOB_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat >&2 <<'USAGE'
Usage:
  kvm-agent-swarm-job submit DIRECTORY [--timeout SECONDS] -- COMMAND [ARG ...]
  kvm-agent-swarm-job status JOB_ID
  kvm-agent-swarm-job log JOB_ID [LINES]
  kvm-agent-swarm-job fetch JOB_ID DESTINATION
  kvm-agent-swarm-job cancel JOB_ID
  kvm-agent-swarm-job list

The worker runs at most one submitted job at a time. Jobs execute as the
non-sudo agent-worker account under ~/jobs/JOB_ID.
USAGE
  exit 2
}

valid_job_id() {
  [[ "$1" =~ ^job-[A-Za-z0-9._-]+$ ]]
}

remote_script() {
  kvm-agent-swarm-ssh bash -s -- "$@"
}

case "${1:-}" in
  submit)
    shift
    (($# >= 3)) || usage
    source_dir="$1"
    shift
    timeout_seconds=7200
    if [[ "${1:-}" == --timeout ]]; then
      (($# >= 3)) || usage
      timeout_seconds="$2"
      shift 2
    fi
    [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
      echo 'Timeout must be a positive number of seconds.' >&2
      exit 2
    }
    [[ "${1:-}" == -- ]] || usage
    shift
    (($# > 0)) || usage
    [[ -d "$source_dir" ]] || {
      echo "Source directory does not exist: $source_dir" >&2
      exit 1
    }

    job_id="job-$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%04x' "$((RANDOM & 65535))")"
    remote_script "$job_id" <<'REMOTE_MKDIR'
set -Eeuo pipefail
job_id="$1"
mkdir -m 0750 -p "$HOME/jobs/$job_id"
REMOTE_MKDIR
    kvm-agent-swarm-rsync -a --protect-args -- \
      "$source_dir/" "kvm-agent-worker:jobs/$job_id/"

    command_line=""
    printf -v command_line '%q ' "$@"
    staging_dir="$(mktemp -d)"
    trap 'rm -rf -- "${staging_dir:-}"' EXIT
    cat >"$staging_dir/run-command.sh" <<RUN_SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
cd "\$HOME/jobs/$job_id"
exec timeout --foreground $timeout_seconds nice -n 10 $command_line
RUN_SCRIPT
    cat >"$staging_dir/job-wrapper.sh" <<WRAPPER_SCRIPT
#!/usr/bin/env bash
set +e
cd "\$HOME/jobs/$job_id"
exec 9>"\$HOME/.kvm-agent-swarm-job.lock"
if ! flock -n 9; then
  echo 'Another swarm job is already running on this worker.'
  status=75
else
  ./run-command.sh
  status=\$?
fi
printf '%s\\n' "\$status" > exit-status
touch finished
exit "\$status"
WRAPPER_SCRIPT
    chmod 0700 "$staging_dir/run-command.sh" "$staging_dir/job-wrapper.sh"
    kvm-agent-swarm-rsync -a --protect-args -- \
      "$staging_dir/run-command.sh" "$staging_dir/job-wrapper.sh" \
      "kvm-agent-worker:jobs/$job_id/"
    remote_script "$job_id" <<'REMOTE_START'
set -Eeuo pipefail
job_id="$1"
cd "$HOME/jobs/$job_id"
chmod 0700 run-command.sh job-wrapper.sh
nohup setsid ./job-wrapper.sh >run.log 2>&1 </dev/null &
printf '%s\n' "$!" > pid
REMOTE_START
    printf '%s\n' "$job_id"
    ;;
  status)
    [[ $# -eq 2 ]] || usage
    job_id="$2"
    valid_job_id "$job_id" || usage
    remote_script "$job_id" <<'REMOTE_STATUS'
set -euo pipefail
job_id="$1"
cd "$HOME/jobs/$job_id" 2>/dev/null || { echo NOT_FOUND; exit 2; }
if [[ -f finished ]]; then
  printf 'FINISHED '
  cat exit-status
elif [[ -f pid ]] && kill -0 "$(cat pid)" 2>/dev/null; then
  echo RUNNING
else
  echo UNKNOWN
fi
REMOTE_STATUS
    ;;
  log)
    [[ $# -eq 2 || $# -eq 3 ]] || usage
    job_id="$2"
    lines="${3:-60}"
    valid_job_id "$job_id" || usage
    [[ "$lines" =~ ^[1-9][0-9]*$ ]] || usage
    remote_script "$job_id" "$lines" <<'REMOTE_LOG'
set -euo pipefail
job_id="$1"
lines="$2"
cd "$HOME/jobs/$job_id"
tail -n "$lines" run.log
REMOTE_LOG
    ;;
  fetch)
    [[ $# -eq 3 ]] || usage
    job_id="$2"
    destination="$3"
    valid_job_id "$job_id" || usage
    mkdir -p "$destination"
    kvm-agent-swarm-rsync -a --protect-args -- \
      "kvm-agent-worker:jobs/$job_id/" "$destination/"
    ;;
  cancel)
    [[ $# -eq 2 ]] || usage
    job_id="$2"
    valid_job_id "$job_id" || usage
    remote_script "$job_id" <<'REMOTE_CANCEL'
set -euo pipefail
job_id="$1"
cd "$HOME/jobs/$job_id"
if [[ -f pid ]] && kill -0 "$(cat pid)" 2>/dev/null; then
  pid="$(cat pid)"
  kill -- "-$pid" 2>/dev/null || kill "$pid"
  printf '130\n' > exit-status
  touch finished cancelled
  echo CANCELLED
else
  echo NOT_RUNNING
fi
REMOTE_CANCEL
    ;;
  list)
    [[ $# -eq 1 ]] || usage
    remote_script <<'REMOTE_LIST'
set -euo pipefail
find "$HOME/jobs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
REMOTE_LIST
    ;;
  *) usage ;;
esac
JOB_HELPER
  chown root:root /usr/local/bin/kvm-agent-swarm-job
  chmod 0755 /usr/local/bin/kvm-agent-swarm-job
fi

if [[ "$role" == worker || "$role" == both ]]; then
  if id "$worker_user" >/dev/null 2>&1; then
    if ! has_role worker; then
      echo "Reserved account '$worker_user' already exists but was not created by a completed KVM-Agent swarm profile." >&2
      echo "Review or remove that account before retrying; it will not be adopted automatically." >&2
      exit 1
    fi
    actual_worker_home="$(getent passwd "$worker_user" | awk -F: '{print $6}')"
    [[ "$actual_worker_home" == "$worker_home" ]] || {
      echo "Existing '$worker_user' account has unexpected home: $actual_worker_home" >&2
      exit 1
    }
  else
    useradd --create-home --shell /bin/bash --comment 'KVM-Agent swarm worker' \
      "$worker_user"
  fi
  add_role worker
  passwd --lock "$worker_user" >/dev/null
  usermod --shell /bin/bash "$worker_user"
  for privileged_group in sudo adm libvirt kvm docker lxd; do
    if getent group "$privileged_group" >/dev/null 2>&1; then
      gpasswd --delete "$worker_user" "$privileged_group" >/dev/null 2>&1 || true
    fi
  done
  install -d -o "$worker_user" -g "$worker_user" -m 0750 \
    "$worker_home/jobs"

  # Keep manager authorization outside the worker-owned home so jobs running as
  # agent-worker cannot add persistent SSH keys. OpenSSH accepts a root-owned
  # AuthorizedKeysFile selected by this per-user Match block.
  install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
  touch "/etc/ssh/authorized_keys/${worker_user}"
  chown root:root "/etc/ssh/authorized_keys/${worker_user}"
  chmod 0644 "/etc/ssh/authorized_keys/${worker_user}"
  cat > /etc/ssh/sshd_config.d/95-kvm-agent-swarm-worker.conf <<'SSHD_WORKER'
Match User agent-worker
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile /etc/ssh/authorized_keys/agent-worker
    DisableForwarding yes
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
SSHD_WORKER
  chown root:root /etc/ssh/sshd_config.d/95-kvm-agent-swarm-worker.conf
  chmod 0644 /etc/ssh/sshd_config.d/95-kvm-agent-swarm-worker.conf
  sshd -t
  systemctl reload ssh.service

  cat > /usr/local/sbin/kvm-agent-swarm-authorize <<'AUTHORIZE_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

worker_user="agent-worker"
authorized_keys="/etc/ssh/authorized_keys/${worker_user}"

install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
touch "$authorized_keys"
chown root:root "$authorized_keys"
chmod 0644 "$authorized_keys"

case "${1:-}" in
  --list)
    cat "$authorized_keys"
    exit 0
    ;;
  --clear)
    : > "$authorized_keys"
    chown root:root "$authorized_keys"
    chmod 0644 "$authorized_keys"
    echo "All manager keys removed from the '${worker_user}' account."
    exit 0
    ;;
  "") ;;
  *)
    echo "Usage: sudo kvm-agent-swarm-authorize [--list|--clear]" >&2
    echo "Without an option, provide exactly one ssh-ed25519 public key on standard input." >&2
    exit 2
    ;;
esac

temporary_key="$(mktemp)"
trap 'rm -f -- "$temporary_key"' EXIT
cat > "$temporary_key"
line_count="$(grep -cve '^[[:space:]]*$' "$temporary_key" || true)"
[[ "$line_count" == 1 ]] || {
  echo "Provide exactly one SSH public key on standard input." >&2
  exit 2
}
key_line="$(grep -ve '^[[:space:]]*$' "$temporary_key")"
case "$key_line" in
  ssh-ed25519\ *) ;;
  *) echo "Only an ssh-ed25519 manager public key is accepted." >&2; exit 2 ;;
esac
ssh-keygen -l -f "$temporary_key" >/dev/null

entry="restrict ${key_line}"
if ! grep -Fqx -- "$entry" "$authorized_keys"; then
  printf '%s\n' "$entry" >> "$authorized_keys"
fi
chown root:root "$authorized_keys"
chmod 0644 "$authorized_keys"
echo "Manager key authorized for the non-sudo '${worker_user}' account."
AUTHORIZE_SCRIPT
  chown root:root /usr/local/sbin/kvm-agent-swarm-authorize
  chmod 0755 /usr/local/sbin/kvm-agent-swarm-authorize

  cat > /usr/local/bin/kvm-agent-swarm-worker-info <<'WORKER_INFO'
#!/usr/bin/env bash
set -euo pipefail
printf 'Worker account: agent-worker\n'
printf 'Worker host name: %s\n' "$(hostname)"
if command -v tailscale >/dev/null 2>&1; then
  address="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  printf 'Tailscale IPv4: %s\n' "${address:-not-connected}"
fi
printf 'SSH ED25519 host-key fingerprint: '
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256 | awk '{print $2}'
printf 'Authorized manager keys: '
count="$(grep -cve '^[[:space:]]*$' /etc/ssh/authorized_keys/agent-worker 2>/dev/null || true)"
printf '%s\n' "${count:-0}"
WORKER_INFO
  chown root:root /usr/local/bin/kvm-agent-swarm-worker-info
  chmod 0755 /usr/local/bin/kvm-agent-swarm-worker-info
fi

install -d -o root -g root -m 0755 /var/lib/kvm-agent
{
  printf 'network=%s\n' "$network"
  printf 'roles=%s\n' "$existing_roles"
  printf 'configured=%s\n' "$(date --utc --iso-8601=seconds)"
} > "$marker"
chmod 0644 "$marker"

if [[ "$network" == tailscale ]]; then
  cat > /usr/local/bin/kvm-agent-swarm-tailscale-up <<'TAILSCALE_UP'
#!/usr/bin/env bash
set -Eeuo pipefail
marker=/var/lib/kvm-agent/swarm-profile
roles="$(sed -n 's/^roles=//p' "$marker" | head -n 1)"
case "$roles" in
  manager) suffix=manager ;;
  worker) suffix=worker ;;
  *) suffix=swarm ;;
esac
suggested="$(hostname)-${suffix}"
device_name="${1:-$suggested}"
[[ "$device_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || {
  echo 'Tailscale device name must contain only letters, digits, and hyphens.' >&2
  exit 2
}
echo "Joining Tailscale as '$device_name'."
echo 'The physical host is not joined; only this guest VM is enrolled.'
sudo tailscale up \
  --hostname="$device_name" \
  --accept-routes=false \
  --ssh=false
printf '\nTailscale address:\n'
tailscale ip -4
printf '\nPeer status:\n'
tailscale status
TAILSCALE_UP
  chown root:root /usr/local/bin/kvm-agent-swarm-tailscale-up
  chmod 0755 /usr/local/bin/kvm-agent-swarm-tailscale-up
fi

cat > /usr/local/bin/kvm-agent-swarm-status <<'STATUS_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
cat /var/lib/kvm-agent/swarm-profile
if command -v tailscale >/dev/null 2>&1; then
  echo
  tailscale status 2>/dev/null || true
fi
if command -v wg >/dev/null 2>&1; then
  echo
  sudo -n wg show 2>/dev/null || true
fi
if command -v kvm-agent-swarm-manager-info >/dev/null 2>&1; then
  echo
  kvm-agent-swarm-manager-info
fi
if command -v kvm-agent-swarm-worker-info >/dev/null 2>&1; then
  echo
  kvm-agent-swarm-worker-info
fi
STATUS_SCRIPT
chown root:root /usr/local/bin/kvm-agent-swarm-status
chmod 0755 /usr/local/bin/kvm-agent-swarm-status

apt-get clean
echo "KVM-Agent swarm profile configured. Run kvm-agent-swarm-status for details."
SWARM_SCRIPT
  chmod 0700 "$destination"
}

while (($# > 0)); do
  case "$1" in
    --name)
      (($# >= 2)) || die "--name requires a value."
      VM_NAME="$2"
      shift 2
      ;;
    --user)
      (($# >= 2)) || die "--user requires a value."
      GUEST_USER="$2"
      shift 2
      ;;
    --memory)
      (($# >= 2)) || die "--memory requires a value."
      RAM_MB="$2"
      shift 2
      ;;
    --vcpus)
      (($# >= 2)) || die "--vcpus requires a value."
      VCPUS="$2"
      shift 2
      ;;
    --disk)
      (($# >= 2)) || die "--disk requires a value."
      DISK_GB="$2"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_GUEST="no"
      shift
      ;;
    --allow-lan)
      RESTRICT_PRIVATE_NETWORKS="no"
      shift
      ;;
    --formal-methods)
      WITH_FORMAL_METHODS="yes"
      shift
      ;;
    --swarm-role)
      (($# >= 2)) || die "--swarm-role requires a value."
      [[ "$ADD_SWARM_ROLE_SET" == "no" ]] || die \
        "--swarm-role and --add-swarm cannot be combined."
      SWARM_ROLE_OPTION_SET="yes"
      SWARM_ROLE="$2"
      shift 2
      ;;
    --swarm-network)
      (($# >= 2)) || die "--swarm-network requires a value."
      SWARM_NETWORK="$2"
      shift 2
      ;;
    --add-swarm)
      (($# >= 2)) || die "--add-swarm requires a role."
      [[ "$SWARM_ROLE_OPTION_SET" == "no" ]] || die \
        "--add-swarm and --swarm-role cannot be combined."
      [[ "$ADD_SWARM_ROLE_SET" == "no" ]] || die \
        "--add-swarm may be specified only once."
      select_operation "add-swarm" "--add-swarm"
      ADD_SWARM_ROLE_SET="yes"
      SWARM_ROLE="$2"
      shift 2
      ;;
    --add-journal)
      select_operation "add-journal" "--add-journal"
      shift
      ;;
    --journal-project)
      (($# >= 2)) || die "--journal-project requires a guest-side path."
      JOURNAL_PROJECTS+=("$2")
      shift 2
      ;;
    --journal-backend)
      (($# >= 2)) || die "--journal-backend requires a value."
      JOURNAL_BACKEND="$2"
      shift 2
      ;;
    --journal-allow-remote-reporting)
      JOURNAL_ALLOW_REMOTE_REPORTING="yes"
      shift
      ;;
    --journal-timezone)
      (($# >= 2)) || die "--journal-timezone requires a value."
      JOURNAL_TIMEZONE="$2"
      shift 2
      ;;
    --resize-existing)
      select_operation "resize" "--resize-existing"
      shift
      ;;
    --replace-existing)
      REPLACE_EXISTING="yes"
      shift
      ;;
    --finalize-existing)
      select_operation "finalize" "--finalize-existing"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

case "$SWARM_ROLE" in
  none|manager|worker|both) ;;
  *) die "Swarm role must be 'manager', 'worker', or 'both'." ;;
esac
case "$SWARM_NETWORK" in
  ""|tailscale|wireguard) ;;
  *) die "Swarm network must be 'tailscale' or 'wireguard'." ;;
esac
if [[ "$SWARM_ROLE" != "none" && -z "$SWARM_NETWORK" ]]; then
  SWARM_NETWORK="tailscale"
fi
if [[ "$SWARM_ROLE" == "none" && -n "$SWARM_NETWORK" ]]; then
  die "--swarm-network requires --swarm-role or --add-swarm."
fi
case "$JOURNAL_BACKEND" in
  claude|codex|evidence) ;;
  *) die "Journal backend must be 'claude', 'codex', or 'evidence'." ;;
esac
[[ "$JOURNAL_TIMEZONE" =~ ^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || die \
  "--journal-timezone must be an IANA name such as Europe/Prague."
if [[ "$OPERATION" != "add-journal" ]]; then
  [[ ${#JOURNAL_PROJECTS[@]} -eq 0 \
      && "$JOURNAL_BACKEND" == "evidence" \
      && "$JOURNAL_TIMEZONE" == "Europe/Prague" \
      && "$JOURNAL_ALLOW_REMOTE_REPORTING" == "no" ]] || die \
    "--journal-project, --journal-backend, --journal-allow-remote-reporting, and --journal-timezone require --add-journal."
fi
if [[ "$JOURNAL_BACKEND" == "evidence" \
    && "$JOURNAL_ALLOW_REMOTE_REPORTING" == "yes" ]]; then
  die "--journal-allow-remote-reporting requires --journal-backend claude or codex."
fi
if [[ "$JOURNAL_BACKEND" != "evidence" \
    && "$JOURNAL_ALLOW_REMOTE_REPORTING" != "yes" ]]; then
  die "--journal-backend $JOURNAL_BACKEND sends project metadata to a model provider; add --journal-allow-remote-reporting to consent explicitly."
fi

[[ $EUID -ne 0 ]] || die \
  "Run this script as your ordinary host account, not as root or through sudo."
[[ -t 0 ]] || die "An interactive terminal is required for password prompts."
[[ "$(uname -m)" == "x86_64" ]] || die \
  "This release supports x86-64 hosts and amd64 guests only."
[[ "$VM_NAME" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die \
  "VM name must start with a lowercase letter and contain only a-z, 0-9, or '-'."
[[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die \
  "Guest user must be a valid lowercase Linux account name."
[[ "$GUEST_USER" != "root" ]] || die "The guest login name cannot be root."
[[ "$GUEST_USER" != "agent-worker" ]] || die \
  "The guest login name 'agent-worker' is reserved for the optional non-sudo swarm worker account."
if [[ "$OPERATION" == "finalize" ]]; then
  [[ "$REPLACE_EXISTING" == "no" ]] || die \
    "--finalize-existing and --replace-existing cannot be used together."
  [[ -z "$RAM_MB" && -z "$VCPUS" \
      && "$DISK_GB" == "$DEFAULT_DISK_GB" \
      && "$WAIT_FOR_GUEST" == "yes" \
      && "$RESTRICT_PRIVATE_NETWORKS" == "yes" \
      && "$WITH_FORMAL_METHODS" == "no" \
      && "$SWARM_ROLE" == "none" \
      && -z "$SWARM_NETWORK" ]] || die \
    "--finalize-existing accepts only --name and --user."
fi
if [[ "$OPERATION" == "add-swarm" ]]; then
  [[ "$REPLACE_EXISTING" == "no" \
      && -z "$RAM_MB" && -z "$VCPUS" \
      && "$DISK_GB" == "$DEFAULT_DISK_GB" \
      && "$WAIT_FOR_GUEST" == "yes" \
      && "$RESTRICT_PRIVATE_NETWORKS" == "yes" \
      && "$WITH_FORMAL_METHODS" == "no" ]] || die \
    "--add-swarm accepts only --name, --user, and --swarm-network."
fi
if [[ "$OPERATION" == "add-journal" ]]; then
  [[ "$REPLACE_EXISTING" == "no" \
      && -z "$RAM_MB" && -z "$VCPUS" \
      && "$DISK_GB" == "$DEFAULT_DISK_GB" \
      && "$WAIT_FOR_GUEST" == "yes" \
      && "$RESTRICT_PRIVATE_NETWORKS" == "yes" \
      && "$WITH_FORMAL_METHODS" == "no" \
      && "$SWARM_ROLE" == "none" \
      && -z "$SWARM_NETWORK" ]] || die \
    "--add-journal accepts only --name, --user, and journal options."
fi
if [[ "$OPERATION" == "resize" ]]; then
  [[ "$REPLACE_EXISTING" == "no" \
      && "$DISK_GB" == "$DEFAULT_DISK_GB" \
      && "$WAIT_FOR_GUEST" == "yes" \
      && "$RESTRICT_PRIVATE_NETWORKS" == "yes" \
      && "$WITH_FORMAL_METHODS" == "no" \
      && "$SWARM_ROLE" == "none" \
      && -z "$SWARM_NETWORK" ]] || die \
    "--resize-existing accepts only --name, --memory, and/or --vcpus."
  [[ -n "$RAM_MB" || -n "$VCPUS" ]] || die \
    "--resize-existing requires --memory and/or --vcpus."
fi
positive_integer "$DISK_GB" || die "--disk must be a positive integer."
((DISK_GB >= 50)) || die "Use at least 50 GiB for the graphical guest."

[[ -r /etc/os-release ]] || die "Cannot identify the host operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu hosts only."
case "${VERSION_ID:-}" in
  24.04|26.04) ;;
  *)
    die "Supported host releases are Ubuntu 24.04 and 26.04 LTS; detected ${VERSION_ID:-unknown}."
    ;;
esac

HOST_USER="$(id -un)"
HOST_USER_HOME="$(getent passwd "$HOST_USER" | awk -F: '{print $6}')"
[[ -n "$HOST_USER_HOME" && "$HOST_USER_HOME" == /* \
    && -d "$HOST_USER_HOME" ]] || die \
  "Cannot resolve a usable home directory for host account '$HOST_USER'."

readonly KEY_DIR="${HOST_USER_HOME}/.local/share/kvm-agent/${VM_NAME}"
readonly SSH_PRIVATE_KEY="${KEY_DIR}/id_ed25519"
readonly SSH_PUBLIC_KEY_FILE="${SSH_PRIVATE_KEY}.pub"
readonly SSH_KNOWN_HOSTS="${KEY_DIR}/known_hosts"
readonly PROVISIONING_MODE_FILE="${KEY_DIR}/provisioning-mode"
ssh_options=()
GUEST_IP=""

if [[ "$OPERATION" == "finalize" ]]; then
  if [[ -r "$PROVISIONING_MODE_FILE" ]] \
      && grep -Fxq 'formal-methods=yes' "$PROVISIONING_MODE_FILE"; then
    WITH_FORMAL_METHODS="yes"
  fi
  log "Authorising finalization"
  sudo -v
  finalize_managed_guest
  log "KVM-Agent finalization completed"
  printf 'Guest address: %s\n' "$GUEST_IP"
  printf 'Cloud-init is disabled and the provisioning seed is absent.\n'
  exit 0
fi

HOST_RAM_MB="$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"
HOST_CPUS="$(nproc)"
positive_integer "$HOST_RAM_MB" || die "Cannot determine host memory."
positive_integer "$HOST_CPUS" || die "Cannot determine host CPU count."

if [[ "$OPERATION" == "add-swarm" ]]; then
  log "Authorising post-provisioning swarm setup"
  sudo -v
  add_swarm_to_managed_guest
  log "KVM-Agent swarm setup completed"
  printf 'Guest address: %s\n' "$GUEST_IP"
  printf '\nNext steps inside the normal sudo-capable guest account:\n'
  if [[ "$SWARM_NETWORK" == "tailscale" ]]; then
    printf '  kvm-agent-swarm-tailscale-up [DISTINCT-DEVICE-NAME]\n'
  else
    printf '  create and review /etc/wireguard/wg0.conf\n'
  fi
  if [[ "$SWARM_ROLE" == "manager" || "$SWARM_ROLE" == "both" ]]; then
    printf '  kvm-agent-swarm-manager-info\n'
    printf '  kvm-agent-swarm-configure-worker WORKER_ADDRESS SHA256:FINGERPRINT\n'
    printf '  kvm-agent-swarm-test\n'
  fi
  if [[ "$SWARM_ROLE" == "worker" || "$SWARM_ROLE" == "both" ]]; then
    printf '  kvm-agent-swarm-worker-info\n'
    printf '  sudo kvm-agent-swarm-authorize\n'
  fi
  printf 'See docs/swarm.md for the ordered pairing procedure.\n'
  exit 0
fi

if [[ "$OPERATION" == "add-journal" ]]; then
  log "Authorising post-provisioning research-journal setup"
  sudo -v
  if [[ "$JOURNAL_ALLOW_REMOTE_REPORTING" == "yes" ]]; then
    warn "Remote journal reporting is enabled. Bounded commit subjects, changed-file paths, project aims, phase state, and structured journal prose will be sent from the guest to the '$JOURNAL_BACKEND' provider. Repository text is untrusted and may influence report content even though tools are confined."
  else
    log "Using deterministic evidence-only reports; no journal data is sent to a model provider"
  fi
  add_journal_to_managed_guest
  log "KVM-Agent research-journal setup completed"
  printf 'Guest address: %s\n' "$GUEST_IP"
  printf '\nJournal commands inside the guest:\n'
  printf '  kvm-agent-journal status\n'
  printf '  kvm-agent-journal init /path/to/another/project\n'
  printf '  sudo kvm-agent-journal register /path/to/another/project\n'
  printf '  kvm-agent-journal report daily --all\n'
  printf 'See docs/journal.md for report contents, evidence rules, and timers.\n'
  exit 0
fi

if [[ "$OPERATION" == "resize" ]]; then
  if [[ -n "$RAM_MB" ]]; then
    positive_integer "$RAM_MB" || die "--memory must be a positive integer."
    ((RAM_MB >= 6144)) || die \
      "The graphical agent guest needs at least 6144 MiB."
    ((RAM_MB + 2048 <= HOST_RAM_MB)) || die \
      "Leave at least 2 GiB of RAM for the Ubuntu host (host: ${HOST_RAM_MB} MiB)."
  fi
  if [[ -n "$VCPUS" ]]; then
    positive_integer "$VCPUS" || die "--vcpus must be a positive integer."
    ((VCPUS <= HOST_CPUS)) || die \
      "Guest vCPUs (${VCPUS}) cannot exceed host CPUs (${HOST_CPUS})."
  fi
  log "Authorising persistent VM resource change"
  sudo -v
  resize_managed_guest
  exit 0
fi

if [[ -z "$RAM_MB" ]]; then
  RAM_MB=$((HOST_RAM_MB * 3 / 4))
  ((RAM_MB > 32768)) && RAM_MB=32768
  ((RAM_MB < 6144)) && RAM_MB=6144
  ((RAM_MB + 2048 > HOST_RAM_MB)) && RAM_MB=$((HOST_RAM_MB - 2048))
fi
if [[ -z "$VCPUS" ]]; then
  VCPUS=$((HOST_CPUS * 3 / 4))
  ((VCPUS < 2)) && VCPUS=2
  ((VCPUS > 16)) && VCPUS=16
  ((VCPUS > HOST_CPUS)) && VCPUS="$HOST_CPUS"
fi

positive_integer "$RAM_MB" || die "--memory must be a positive integer."
positive_integer "$VCPUS" || die "--vcpus must be a positive integer."
((RAM_MB >= 6144)) || die "The graphical agent guest needs at least 6144 MiB."
((RAM_MB + 2048 <= HOST_RAM_MB)) || die \
  "Leave at least 2 GiB of RAM for the Ubuntu host (host: ${HOST_RAM_MB} MiB)."
((VCPUS <= HOST_CPUS)) || die \
  "Guest vCPUs (${VCPUS}) cannot exceed host CPUs (${HOST_CPUS})."

if ((RAM_MB < 8192)); then
  warn "Less than 8 GiB may make desktop provisioning and agent use slow."
fi
if ((DISK_GB < 120)); then
  warn "Less than 120 GiB leaves less room for toolchains, model weights, and projects."
fi
if [[ "$WITH_FORMAL_METHODS" == "yes" && "$DISK_GB" -lt 100 ]]; then
  warn "Less than 100 GiB is not recommended for the formal-methods profile."
fi

log "Configuration"
printf 'Host account:   %s\n' "$HOST_USER"
printf 'VM name:        %s\n' "$VM_NAME"
printf 'Guest login:    %s\n' "$GUEST_USER"
printf 'Guest release:  Ubuntu %s LTS desktop\n' "$GUEST_RELEASE"
printf 'Resources:      %s MiB RAM, %s vCPU, %s GiB disk\n' \
  "$RAM_MB" "$VCPUS" "$DISK_GB"
printf 'Provisioning:   Codex, Claude Code, OpenCode, Aider, Ollama\n'
if [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
  printf 'Formal tools:   Lean 4, Isabelle/HOL, GHC, Cabal, HLS, HLint\n'
  printf 'Editor:         VS Code with Lean and Haskell extensions\n'
  printf 'Time warning:   formal-methods provisioning may take several hours\n'
else
  printf 'Formal tools:   not requested (use --formal-methods to include them)\n'
fi
if [[ "$SWARM_ROLE" != "none" ]]; then
  printf 'Swarm profile:  %s over %s\n' "$SWARM_ROLE" "$SWARM_NETWORK"
  printf 'Swarm note:     network enrollment and peer authorization remain manual\n'
else
  printf 'Swarm profile:  not requested (see docs/swarm.md)\n'
fi

log "Authorising host setup"
sudo -v

log "Installing Ubuntu's KVM and virt-manager packages on the host"
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-system-x86 \
  libvirt-daemon-system \
  libvirt-clients \
  virt-manager \
  virtinst \
  cloud-image-utils \
  qemu-utils \
  python3 \
  ubuntu-keyring \
  ca-certificates \
  curl \
  gpgv \
  openssl \
  openssh-client

sudo systemctl enable --now libvirtd.service

# Only "libvirt" is required to drive qemu:///system from virt-manager. The
# "kvm" group is for the QEMU service account, not for the human: adding the
# human to it would also make the VM disk and the cloud-init seed - which
# carries the guest password hash - readable by that account.
sudo usermod -aG libvirt -- "$HOST_USER"

[[ -e /dev/kvm ]] || die \
  "/dev/kvm is unavailable. Enable Intel VT-x or AMD-V in firmware and reboot."

WORK_DIR="$(mktemp -d)"
write_swarm_provision_script "$WORK_DIR/swarm-provision.sh"
SWARM_PROVISION_B64="$(base64 -w 0 "$WORK_DIR/swarm-provision.sh")"

if ! sudo virsh --connect "$LIBVIRT_URI" net-info "$LIBVIRT_NETWORK" \
    >/dev/null 2>&1; then
  if [[ -r /usr/share/libvirt/networks/default.xml ]]; then
    sudo virsh --connect "$LIBVIRT_URI" \
      net-define /usr/share/libvirt/networks/default.xml >/dev/null
  else
    cat > "$WORK_DIR/default-network.xml" <<'NETWORK_XML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETWORK_XML
    sudo virsh --connect "$LIBVIRT_URI" \
      net-define "$WORK_DIR/default-network.xml" >/dev/null
  fi
fi

sudo virsh --connect "$LIBVIRT_URI" \
  net-autostart "$LIBVIRT_NETWORK" >/dev/null
if ! LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
    net-info "$LIBVIRT_NETWORK" \
    | grep -Eq '^Active:[[:space:]]+yes$'; then
  start_error=""
  if ! start_error="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      net-start "$LIBVIRT_NETWORK" 2>&1
  )"; then
    grep -qi "already active" <<< "$start_error" || {
      printf '%s\n' "$start_error" >&2
      die "Could not start libvirt's default NAT network."
    }
  fi
fi

GATEWAY_ADDRESS="$(
  LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
    net-dumpxml "$LIBVIRT_NETWORK" 2>/dev/null \
    | sed -n "s/.*<ip[^>]*address='\([0-9][0-9.]*\)'.*/\1/p" \
    | head -n 1
)"
[[ "$GATEWAY_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die \
  "Could not determine the IPv4 gateway of libvirt network '$LIBVIRT_NETWORK'."

# qcow2 is thin-provisioned: DISK_GB is the guest-visible ceiling, not space
# reserved on the host. Refuse to destroy an existing guest when the backing
# filesystem is already too small for a credible provisioning run. This is a
# safety floor, not a promise that every future workload will fit.
sudo install -d -o root -g kvm -m 0750 "$IMAGE_DIR" "$VM_IMAGE_DIR"
host_available_bytes="$(
  LC_ALL=C df -PB1 "$IMAGE_DIR" \
    | awk 'NR == 2 { print $4 }'
)"
positive_integer "$host_available_bytes" || die \
  "Could not determine free space for $IMAGE_DIR."
minimum_host_free_gib=12
if [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
  minimum_host_free_gib=30
fi
minimum_host_free_bytes=$((minimum_host_free_gib * 1024 * 1024 * 1024))
if ((host_available_bytes < minimum_host_free_bytes)); then
  die "The host filesystem backing $IMAGE_DIR has less than ${minimum_host_free_gib} GiB free. No existing VM was removed."
fi
requested_disk_bytes=$((DISK_GB * 1024 * 1024 * 1024))
if ((host_available_bytes < requested_disk_bytes)); then
  warn "The ${DISK_GB} GiB qcow2 disk is thin-provisioned, but the host currently has only $((host_available_bytes / 1024 / 1024 / 1024)) GiB free. The VM cannot consume its full virtual capacity unless host space is added."
fi

if [[ "$REPLACE_EXISTING" == "yes" ]]; then
  log "Replacing the existing KVM-Agent VM"
  printf 'The removal helper will show the exact VM-specific files and require\n'
  printf 'you to type %q before anything is deleted.\n' "$VM_NAME"
  "${SCRIPT_DIR}/remove-kvm-agent.sh" \
    --name "$VM_NAME" --force
fi

if sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" \
    >/dev/null 2>&1; then
  die "A libvirt VM named '$VM_NAME' already exists. Choose another --name or rerun with --replace-existing."
fi

readonly IMAGE_NAME="ubuntu-${GUEST_RELEASE}-server-cloudimg-${GUEST_ARCH}.img"
readonly IMAGE_BASE_URL="https://cloud-images.ubuntu.com/releases/${GUEST_RELEASE}/release"
readonly BASE_IMAGE="${IMAGE_DIR}/${IMAGE_NAME}"
readonly BASE_CHECKSUM="${BASE_IMAGE}.sha256"
readonly UBUNTU_CLOUD_KEYRING="/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg"

[[ -r "$UBUNTU_CLOUD_KEYRING" ]] || die \
  "Ubuntu cloud-image keyring is missing after installing ubuntu-keyring."

base_image_valid="no"
if sudo test -r "$BASE_IMAGE" && sudo test -r "$BASE_CHECKSUM"; then
  expected_base_hash="$(sudo awk 'NR == 1 { print $1 }' "$BASE_CHECKSUM")"
  actual_base_hash="$(sudo sha256sum "$BASE_IMAGE" | awk '{print $1}')"
  if [[ "$expected_base_hash" =~ ^[a-f0-9]{64}$ \
      && "$actual_base_hash" == "$expected_base_hash" ]]; then
    base_image_valid="yes"
  else
    warn "The cached base image failed its recorded checksum and will be replaced."
  fi
fi

if [[ "$base_image_valid" != "yes" ]]; then
  log "Downloading and authenticating Ubuntu's signed cloud image"
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "${IMAGE_BASE_URL}/SHA256SUMS" \
    --output "$WORK_DIR/SHA256SUMS"
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "${IMAGE_BASE_URL}/SHA256SUMS.gpg" \
    --output "$WORK_DIR/SHA256SUMS.gpg"
  gpgv --keyring "$UBUNTU_CLOUD_KEYRING" \
    "$WORK_DIR/SHA256SUMS.gpg" "$WORK_DIR/SHA256SUMS"

  awk -v image="$IMAGE_NAME" '
    $2 == image || $2 == "*" image { print; found = 1 }
    END { if (!found) exit 1 }
  ' "$WORK_DIR/SHA256SUMS" > "$WORK_DIR/IMAGE.SHA256" || die \
    "The signed Ubuntu manifest does not contain $IMAGE_NAME."

  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "${IMAGE_BASE_URL}/${IMAGE_NAME}" \
    --output "$WORK_DIR/$IMAGE_NAME"
  (
    cd "$WORK_DIR"
    sha256sum --check --strict IMAGE.SHA256
  )

  verified_hash="$(awk 'NR == 1 { print $1 }' "$WORK_DIR/IMAGE.SHA256")"
  sudo install -o root -g kvm -m 0640 \
    "$WORK_DIR/$IMAGE_NAME" "$BASE_IMAGE"
  printf '%s\n' "$verified_hash" > "$WORK_DIR/base.sha256"
  sudo install -o root -g root -m 0644 \
    "$WORK_DIR/base.sha256" "$BASE_CHECKSUM"
else
  log "Reusing the locally verified Ubuntu base image"
fi

install -d -m 0700 "$KEY_DIR"
if [[ -e "$SSH_PRIVATE_KEY" || -e "$SSH_PUBLIC_KEY_FILE" ]]; then
  [[ -r "$SSH_PRIVATE_KEY" && -r "$SSH_PUBLIC_KEY_FILE" ]] || die \
    "Incomplete recovery SSH key pair under $KEY_DIR."
  warn "Reusing the existing recovery SSH key for '$VM_NAME'."
else
  ssh-keygen -q -t ed25519 -N "" \
    -C "kvm-agent:${VM_NAME}" -f "$SSH_PRIVATE_KEY"
fi
chmod 0600 "$SSH_PRIVATE_KEY"
chmod 0644 "$SSH_PUBLIC_KEY_FILE"
{
  printf 'formal-methods=%s\n' "$WITH_FORMAL_METHODS"
  printf 'swarm-role=%s\n' "$SWARM_ROLE"
  printf 'swarm-network=%s\n' "${SWARM_NETWORK:-none}"
} > "$PROVISIONING_MODE_FILE"
chmod 0600 "$PROVISIONING_MODE_FILE"

# This point is only reached when no domain of this name exists, so any host
# key recorded for a previous VM of the same name is stale. Leaving it in place
# would turn "accept-new" into a hard mismatch failure fifteen minutes later.
if [[ -e "$SSH_KNOWN_HOSTS" ]]; then
  warn "Discarding the recorded host key of a previous '$VM_NAME' VM."
  rm -f -- "$SSH_KNOWN_HOSTS"
fi

mapfile -t public_key_lines < <(
  sed -e 's/\r$//' -e '/^[[:space:]]*$/d' "$SSH_PUBLIC_KEY_FILE"
)
((${#public_key_lines[@]} == 1)) || die \
  "The recovery public-key file must contain exactly one key."
read -r public_key_type public_key_data _ <<< "${public_key_lines[0]}"
[[ "$public_key_type" =~ ^(ssh-|ecdsa-|sk-) \
    && "$public_key_data" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || die \
  "The recovery public key is not valid OpenSSH public-key text."
SSH_PUBLIC_KEY="${public_key_type} ${public_key_data}"

log "Choosing the guest's local GUI password"
printf 'This password is used only for the %s account inside the VM.\n' "$GUEST_USER"
printf 'SSH password login remains disabled.\n'
printf 'Use a unique password: its hash exists in guest cloud-init state until verified final cleanup.\n'
read -r -s -p "Guest password (at least 8 characters): " guest_password
printf '\n'
((${#guest_password} >= 8)) || die "Guest password is shorter than 8 characters."
read -r -s -p "Confirm guest password: " guest_password_confirmation
printf '\n'
[[ "$guest_password" == "$guest_password_confirmation" ]] || die \
  "Guest passwords do not match."
GUEST_PASSWORD_HASH="$(
  printf '%s' "$guest_password" | openssl passwd -6 -stdin
)"
unset guest_password guest_password_confirmation
[[ "$GUEST_PASSWORD_HASH" == "\$6\$"* ]] || die \
  "Could not create a SHA-512 guest password hash."

cat > "$WORK_DIR/guest-provision.sh" <<'GUEST_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

exec > >(tee -a /var/log/kvm-agent-provision.log) 2>&1

guest_user="${1:?guest user is required}"
restrict_private_networks="${2:?private-network policy is required}"
gateway_address="${3:?gateway address is required}"
with_formal_methods="${4:?formal-methods selection is required}"
requested_disk_gib="${5:?requested disk size is required}"
swarm_role="${6:?swarm role is required}"
swarm_network="${7:?swarm network is required}"
guest_home="$(getent passwd "$guest_user" | awk -F: '{print $6}')"
guest_group="$(id -gn "$guest_user")"
guest_path="${guest_home}/.elan/bin:${guest_home}/.ghcup/bin:${guest_home}/.local/bin:${guest_home}/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root_runtime_home="/root"
isabelle_version="Isabelle2025-2"
isabelle_archive_url="https://www.cl.cam.ac.uk/research/hvg/Isabelle/dist/${isabelle_version}_linux.tar.gz"
isabelle_archive_sha256="a20a507bc7c1270d8be96a9f3fbec06345387789d2dc2c4d3df6260d47bfb33c"

[[ -n "$guest_home" && -d "$guest_home" ]] || {
  echo "Cannot resolve guest home for $guest_user." >&2
  exit 1
}

install -d -o root -g root -m 0755 /var/lib/kvm-agent
rm -f -- \
  /var/lib/kvm-agent/provisioned \
  /var/lib/kvm-agent/provisioning-failed
emergency_reserve="/var/lib/kvm-agent/emergency-space.reserve"
staging_root="/var/lib/kvm-agent/install"
staging_dir=""
record_provisioning_failure() {
  local exit_status=$?
  trap - EXIT
  if ((exit_status != 0)); then
    # Keep a failed provisioning run from leaving / completely full and
    # causing a graphical login loop. The reserve is allocated before large
    # downloads. Remove any partial disk-backed download and release the
    # reserve first on failure.
    if [[ -n "$staging_dir" ]]; then
      rm -rf -- "$staging_dir"
    fi
    rm -f -- "$emergency_reserve"
    apt-get clean >/dev/null 2>&1 || true
    rm -rf -- /var/cache/apt/archives/partial/* 2>/dev/null || true
    printf 'Provisioning failed: %s\n' "$(date --utc --iso-8601=seconds)" \
      > /var/lib/kvm-agent/provisioning-failed
    chmod 0644 /var/lib/kvm-agent/provisioning-failed
  fi
  exit "$exit_status"
}
trap record_provisioning_failure EXIT

root_filesystem_bytes() {
  LC_ALL=C df -B1 --output=size / | awk 'NR == 2 { print $1 }'
}

root_available_bytes() {
  LC_ALL=C df -B1 --output=avail / | awk 'NR == 2 { print $1 }'
}

show_root_storage() {
  echo "Guest block devices:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
  echo "Guest root filesystem:"
  df -h /
}

grow_root_filesystem() {
  local root_source
  local root_device
  local parent_name
  local parent_device
  local partition_number
  local filesystem_type
  local growpart_output=""

  root_source="$(findmnt -n -o SOURCE /)"
  root_device="$(readlink -f -- "$root_source")"
  [[ -b "$root_device" ]] || {
    echo "Root source is not a block device: $root_source -> $root_device" >&2
    return 1
  }

  parent_name="$(lsblk -ndo PKNAME "$root_device" | head -n 1)"
  partition_number="$(lsblk -ndo PARTN "$root_device" | head -n 1)"
  [[ -n "$parent_name" && "$partition_number" =~ ^[1-9][0-9]*$ ]] || {
    echo "Cannot identify the parent disk and partition for $root_device." >&2
    return 1
  }
  parent_device="/dev/${parent_name}"

  command -v growpart >/dev/null || {
    echo "growpart is missing from the Ubuntu cloud image." >&2
    return 1
  }

  echo "Expanding root partition ${parent_device} ${partition_number}..."
  if ! growpart_output="$(growpart "$parent_device" "$partition_number" 2>&1)"; then
    # growpart returns nonzero for an already-maximal partition on some
    # releases. That is safe because the filesystem resize and size
    # verification below remain mandatory.
    grep -Fq "NOCHANGE" <<< "$growpart_output" || {
      printf '%s\n' "$growpart_output" >&2
      return 1
    }
  fi
  [[ -z "$growpart_output" ]] || printf '%s\n' "$growpart_output"
  udevadm settle || true

  filesystem_type="$(findmnt -n -o FSTYPE /)"
  case "$filesystem_type" in
    ext2|ext3|ext4)
      resize2fs "$root_device"
      ;;
    xfs)
      xfs_growfs /
      ;;
    btrfs)
      btrfs filesystem resize max /
      ;;
    *)
      echo "Unsupported root filesystem for automatic growth: $filesystem_type" >&2
      return 1
      ;;
  esac
}

ensure_requested_root_capacity() {
  local current_bytes
  local minimum_bytes

  [[ "$requested_disk_gib" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid requested disk size: $requested_disk_gib" >&2
    return 1
  }
  minimum_bytes=$((requested_disk_gib * 1024 * 1024 * 1024 * 9 / 10))
  current_bytes="$(root_filesystem_bytes)"

  if [[ ! "$current_bytes" =~ ^[1-9][0-9]*$ ]] \
      || ((current_bytes < minimum_bytes)); then
    echo "Root filesystem has not yet expanded to the requested ${requested_disk_gib} GiB disk."
    show_root_storage
    grow_root_filesystem
    current_bytes="$(root_filesystem_bytes)"
  fi

  if [[ ! "$current_bytes" =~ ^[1-9][0-9]*$ ]] \
      || ((current_bytes < minimum_bytes)); then
    show_root_storage
    echo "Root filesystem is smaller than 90% of the requested ${requested_disk_gib} GiB. Refusing large package installation." >&2
    return 1
  fi

  echo "Verified root filesystem capacity: $((current_bytes / 1024 / 1024 / 1024)) GiB usable."
}

require_root_free_gib() {
  local required_gib="$1"
  local available_bytes
  local required_bytes=$((required_gib * 1024 * 1024 * 1024))

  available_bytes="$(root_available_bytes)"
  if [[ ! "$available_bytes" =~ ^[0-9]+$ ]] \
      || ((available_bytes < required_bytes)); then
    show_root_storage
    echo "At least ${required_gib} GiB free on / is required before the next provisioning stage." >&2
    return 1
  fi
}

# Cloud-init normally grows Ubuntu cloud images before runcmd. Repeat the
# operation safely when needed and verify the result before any large download.
ensure_requested_root_capacity
initial_free_gib=10
if [[ "$with_formal_methods" == "yes" ]]; then
  initial_free_gib=25
fi
require_root_free_gib "$initial_free_gib"
rm -f -- "$emergency_reserve"
fallocate -l 512M "$emergency_reserve"
chmod 0600 "$emergency_reserve"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "Installing the Ubuntu desktop and guest integration..."
apt-get update
apt-get upgrade -y
apt-get install -y \
  ubuntu-desktop-minimal \
  qemu-guest-agent \
  spice-vdagent \
  openssh-server \
  ca-certificates \
  curl \
  git \
  jq \
  ripgrep \
  rsync \
  tmux \
  unzip \
  zstd \
  build-essential \
  python3 \
  python3-venv \
  ufw
apt-get clean

if [[ "$with_formal_methods" == "yes" ]]; then
  echo "Installing Ubuntu prerequisites for Lean, Isabelle and Haskell..."
  apt-get install -y \
    debconf-utils \
    gnupg \
    libffi-dev \
    libgmp-dev \
    libncurses-dev \
    libnuma-dev \
    libtinfo-dev \
    pkg-config \
    wget \
    xz-utils
  apt-get clean
fi

systemctl enable --now qemu-guest-agent.service
systemctl enable --now ssh.service
systemctl set-default graphical.target

echo "Configuring the guest firewall before third-party installation..."

# Always retain the inbound firewall policy, including with --allow-lan.
# This runs before the first third-party installer is downloaded.
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Recovery SSH is reachable from the libvirt gateway only, not from other
# guests sharing the same virtual network.
ufw allow from "$gateway_address" to any port 22 proto tcp >/dev/null

if [[ "$restrict_private_networks" == "yes" ]]; then
  echo "Restricting guest egress to private and link-local address ranges..."

  # Outbound internet access stays open: agents need package registries and
  # model APIs. The following rules block the common private and link-local
  # address ranges that normally contain the host, other guests, and a physical
  # LAN. Networks using publicly routable local addresses are not covered.
  #
  # DNS and DHCP to the libvirt gateway must survive; other traffic to a
  # gateway in one of the denied ranges is blocked.
  ufw allow out to "$gateway_address" port 53 proto udp >/dev/null
  ufw allow out to "$gateway_address" port 53 proto tcp >/dev/null
  ufw allow out to "$gateway_address" port 67 proto udp >/dev/null

  ufw deny out to 10.0.0.0/8 >/dev/null
  ufw deny out to 172.16.0.0/12 >/dev/null
  ufw deny out to 192.168.0.0/16 >/dev/null
  ufw deny out to 169.254.0.0/16 >/dev/null

  # Tolerated rather than required: these fail when ufw is built or configured
  # without IPv6 support, and the libvirt default network is IPv4-only anyway.
  ufw deny out to fc00::/7 >/dev/null 2>&1 \
    || echo "Note: skipped the IPv6 unique-local egress rule."
  ufw deny out to fe80::/10 >/dev/null 2>&1 \
    || echo "Note: skipped the IPv6 link-local egress rule."

else
  echo "Permitting private-network egress as requested; inbound filtering remains active."
fi

ufw --force enable >/dev/null
systemctl enable ufw.service
ufw status verbose

if [[ "$swarm_role" != "none" ]]; then
  /usr/local/sbin/kvm-agent-swarm-provision \
    "$swarm_role" "$swarm_network" "$guest_user"
fi

install -d -o "$guest_user" -g "$guest_group" -m 0755 \
  "$guest_home/.local" \
  "$guest_home/.local/bin" \
  "$guest_home/.local/share" \
  "$guest_home/.local/state" \
  "$guest_home/.config" \
  "$guest_home/.cache" \
  "$guest_home/.local/share/kvm-agent" \
  "$guest_home/.elan" \
  "$guest_home/.ghcup" \
  "$guest_home/.ghcup/bin" \
  "$guest_home/.cabal"

cat > /etc/profile.d/kvm-agent-tools.sh <<'PROFILE'
# Paths used by the per-user native coding-agent installers.
if [ -n "${HOME:-}" ]; then
  [ ! -d "$HOME/.elan/bin" ] || PATH="$HOME/.elan/bin:$PATH"
  [ ! -d "$HOME/.ghcup/bin" ] || PATH="$HOME/.ghcup/bin:$PATH"
  [ ! -d "$HOME/.opencode/bin" ] || PATH="$HOME/.opencode/bin:$PATH"
  [ ! -d "$HOME/.local/bin" ] || PATH="$HOME/.local/bin:$PATH"
  export PATH
fi
PROFILE
chmod 0644 /etc/profile.d/kvm-agent-tools.sh

cat >> "$guest_home/.profile" <<'PROFILE'

# KVM-Agent tool paths
export PATH="$HOME/.elan/bin:$HOME/.ghcup/bin:$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
PROFILE
chown "$guest_user:$guest_group" "$guest_home/.profile"

as_guest() {
  runuser -u "$guest_user" -- \
    env HOME="$guest_home" USER="$guest_user" LOGNAME="$guest_user" \
      XDG_CONFIG_HOME="$guest_home/.config" \
      XDG_DATA_HOME="$guest_home/.local/share" \
      XDG_STATE_HOME="$guest_home/.local/state" \
      XDG_CACHE_HOME="$guest_home/.cache" \
      PATH="$guest_path" "$@"
}

# Installers and large archives are staged on the root filesystem, not under
# /run (a small RAM-backed tmpfs on Ubuntu) or a predictable world-writable
# /tmp path. The directory is traversable but not writable by anyone except
# root, and each staged file stays root-owned and read-only. This gives the
# 1+ GiB Isabelle archive access to the verified VM disk capacity and prevents
# the guest user from altering an installer before it runs.
install -d -o root -g root -m 0711 "$staging_root"
staging_dir="$(mktemp -d "${staging_root}/stage.XXXXXXXX")"
chmod 0711 "$staging_dir"

install_guest_script() {
  local tool_name="$1"
  local installer_url="$2"
  local installer_path="${staging_dir}/${tool_name}.sh"

  echo "Downloading the official ${tool_name} installer inside the guest..."
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "$installer_url" --output "$installer_path"
  chown root:root "$installer_path"
  chmod 0555 "$installer_path"
  as_guest bash "$installer_path"
  rm -f -- "$installer_path"
}

install_formal_methods() {
  local vscode_deb="${staging_dir}/vscode-amd64.deb"
  local elan_installer="${staging_dir}/elan-init.sh"
  local ghcup_installer="${staging_dir}/bootstrap-haskell"
  local isabelle_archive="${staging_dir}/${isabelle_version}_linux.tar.gz"
  local isabelle_destination="/opt/${isabelle_version}"

  echo "Installing Visual Studio Code inside the graphical guest..."
  echo "code code/add-microsoft-repo boolean true" \
    | debconf-set-selections
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "https://update.code.visualstudio.com/latest/linux-deb-x64/stable" \
    --output "$vscode_deb"
  chown root:root "$vscode_deb"
  chmod 0444 "$vscode_deb"
  apt-get install -y "$vscode_deb"
  rm -f -- "$vscode_deb"

  echo "Installing Lean 4 through the official elan toolchain manager..."
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "https://elan.lean-lang.org/elan-init.sh" \
    --output "$elan_installer"
  chown root:root "$elan_installer"
  chmod 0555 "$elan_installer"
  as_guest sh "$elan_installer" \
    -y --no-modify-path --default-toolchain stable
  rm -f -- "$elan_installer"

  echo "Installing Isabelle/HOL ${isabelle_version}..."
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "$isabelle_archive_url" --output "$isabelle_archive"
  printf '%s  %s\n' "$isabelle_archive_sha256" "$isabelle_archive" \
    | sha256sum --check --strict -
  rm -rf -- "$isabelle_destination"
  tar -xzf "$isabelle_archive" -C /opt
  [[ -x "$isabelle_destination/bin/isabelle" ]] || {
    echo "Unexpected Isabelle archive layout." >&2
    exit 1
  }
  chown -R root:root "$isabelle_destination"
  ln -sfn "$isabelle_destination/bin/isabelle" /usr/local/bin/isabelle
  rm -f -- "$isabelle_archive"

  echo "Installing GHC, Cabal and Haskell Language Server through GHCup..."
  require_root_free_gib 12
  curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
    "https://get-ghcup.haskell.org" --output "$ghcup_installer"
  chown root:root "$ghcup_installer"
  chmod 0555 "$ghcup_installer"
  as_guest env \
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_INSTALL_HLS=1 \
    BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
    sh "$ghcup_installer"
  rm -f -- "$ghcup_installer"

  echo "Installing HLint through Cabal..."
  require_root_free_gib 10
  as_guest cabal update
  as_guest cabal install \
    --jobs=2 \
    --install-method=copy \
    --installdir="$guest_home/.local/bin" \
    --overwrite-policy=always \
    hlint

  echo "Installing the official Lean and Haskell VS Code extensions..."
  as_guest code --install-extension leanprover.lean4 --force
  as_guest code --install-extension haskell.haskell --force
}

if [[ "$with_formal_methods" == "yes" ]]; then
  install_formal_methods
fi

require_root_free_gib 8
install_guest_script codex "https://chatgpt.com/codex/install.sh"
install_guest_script claude-code "https://claude.ai/install.sh"
install_guest_script opencode "https://opencode.ai/install"

echo "Installing Aider through an isolated uv bootstrap..."
uv_bootstrap="${guest_home}/.local/share/kvm-agent/uv-bootstrap"
as_guest python3 -m venv "$uv_bootstrap"
as_guest "$uv_bootstrap/bin/python" -m pip install --upgrade pip uv
as_guest "$uv_bootstrap/bin/uv" tool install \
  --force --python python3.12 --with pip 'aider-chat@latest'
rm -rf -- "$uv_bootstrap"

# Unlike the three agent installers, this one is invoked directly as root
# because Ollama installs a systemd unit. All installers must nevertheless be
# treated as having effective guest-root capability: the agent account used by
# the others has unrestricted passwordless sudo.
echo "Installing Ollama as root and constraining its API to guest loopback..."
ollama_installer="${staging_dir}/ollama.sh"
curl --proto '=https' --tlsv1.2 --fail --show-error --location --retry 3 \
  "https://ollama.com/install.sh" --output "$ollama_installer"
chown root:root "$ollama_installer"
chmod 0500 "$ollama_installer"
bash "$ollama_installer"
rm -f -- "$ollama_installer"
rm -rf -- "$staging_dir"
staging_dir=""

install -d -o root -g root -m 0755 \
  /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/10-kvm-agent-loopback.conf <<'OLLAMA_UNIT'
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
OLLAMA_UNIT
chmod 0644 /etc/systemd/system/ollama.service.d/10-kvm-agent-loopback.conf
systemctl daemon-reload
systemctl enable ollama.service
systemctl restart ollama.service

ollama_ready="no"
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error \
      http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ollama_ready="yes"
    break
  fi
  sleep 1
done
[[ "$ollama_ready" == "yes" ]] || {
  systemctl status ollama.service --no-pager --full || true
  echo "Ollama did not become ready on guest loopback." >&2
  exit 1
}

if ss -ltnH 'sport = :11434' \
    | awk '{print $4}' \
    | grep -Eq '(^0\.0\.0\.0:|^\*:|^\[::\]:)'; then
  echo "Ollama unexpectedly listens beyond guest loopback." >&2
  ss -ltnp 'sport = :11434' >&2 || true
  exit 1
fi

echo "Verifying installed commands..."
if [[ "$with_formal_methods" == "yes" ]]; then
  vscode_extensions="$(as_guest code --list-extensions)"
  as_guest timeout 60s code --version
  as_guest timeout 60s elan --version
  as_guest timeout 60s lean --version
  as_guest timeout 60s lake --version
  timeout 60s isabelle version
  as_guest timeout 60s ghcup --version
  as_guest timeout 60s ghc --version
  as_guest timeout 60s cabal --version
  as_guest timeout 60s haskell-language-server-wrapper --version
  as_guest timeout 60s hlint --version
  grep -Fxq leanprover.lean4 <<< "$vscode_extensions"
  grep -Fxq haskell.haskell <<< "$vscode_extensions"
fi
as_guest timeout 30s codex --version
as_guest timeout 30s claude --version
as_guest timeout 30s opencode --version
as_guest timeout 30s aider --version
env HOME="$root_runtime_home" OLLAMA_HOST=127.0.0.1:11434 \
  timeout 30s ollama --version
systemctl is-active --quiet ollama.service

apt-get clean
rm -rf -- \
  /var/lib/apt/lists/* \
  "$guest_home/.cache/pip" \
  "$guest_home/.cache/uv"
rm -f -- "$emergency_reserve"

{
  printf 'Provisioned: %s\n' "$(date --utc --iso-8601=seconds)"
  if [[ "$with_formal_methods" == "yes" ]]; then
    printf '\nFormal methods and editor:\n'
    as_guest code --version
    as_guest elan --version
    as_guest lean --version
    as_guest lake --version
    isabelle version
    as_guest ghcup --version
    as_guest ghc --version
    as_guest cabal --version
    as_guest haskell-language-server-wrapper --version
    as_guest hlint --version
    printf 'VS Code extensions:\n'
    as_guest code --list-extensions \
      | grep -E '^(leanprover\.lean4|haskell\.haskell)$'
    printf '\nCoding agents:\n'
  fi
  as_guest codex --version
  as_guest claude --version
  as_guest opencode --version
  as_guest aider --version
  env HOME="$root_runtime_home" OLLAMA_HOST=127.0.0.1:11434 ollama --version
} > /var/lib/kvm-agent/installed-versions.txt
chmod 0644 /var/lib/kvm-agent/installed-versions.txt

# Start the display manager last so package installation cannot replace the
# user's visible session halfway through provisioning.
systemctl enable gdm3.service
systemctl start gdm3.service

touch /var/lib/kvm-agent/provisioned
rm -f -- /var/lib/kvm-agent/provisioning-failed
trap - EXIT
echo "KVM-Agent graphical guest provisioning completed successfully."
GUEST_SCRIPT
chmod 0700 "$WORK_DIR/guest-provision.sh"

GUEST_PROVISION_B64="$(base64 -w 0 "$WORK_DIR/guest-provision.sh")"

cat > "$WORK_DIR/user-data" <<EOF
#cloud-config

users:
  - name: ${GUEST_USER}
    gecos: KVM Agent User
    shell: /bin/bash
    groups: [adm, sudo]
    sudo:
      - "ALL=(ALL:ALL) NOPASSWD: ALL"
    lock_passwd: false
    hashed_passwd: '${GUEST_PASSWORD_HASH}'
    ssh_authorized_keys:
      - ${SSH_PUBLIC_KEY}

disable_root: true
ssh_pwauth: false
package_update: false
package_upgrade: false

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true

write_files:
  - path: /etc/ssh/sshd_config.d/90-kvm-agent.conf
    owner: root:root
    permissions: "0644"
    content: |
      PasswordAuthentication no
      PermitRootLogin no
      AllowAgentForwarding no
      X11Forwarding no

  - path: /usr/local/sbin/kvm-agent-provision
    owner: root:root
    permissions: "0700"
    encoding: b64
    content: ${GUEST_PROVISION_B64}

  - path: /usr/local/sbin/kvm-agent-swarm-provision
    owner: root:root
    permissions: "0700"
    encoding: b64
    content: ${SWARM_PROVISION_B64}

runcmd:
  - ["/usr/local/sbin/kvm-agent-provision", "${GUEST_USER}", "${RESTRICT_PRIVATE_NETWORKS}", "${GATEWAY_ADDRESS}", "${WITH_FORMAL_METHODS}", "${DISK_GB}", "${SWARM_ROLE}", "${SWARM_NETWORK:-none}"]

final_message: "KVM-Agent cloud-init finished after \$UPTIME seconds; verify cloud-init status."
EOF

cat > "$WORK_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}-$(date -u +%Y%m%dT%H%M%SZ)
local-hostname: ${VM_NAME}
EOF

VM_DISK="${VM_IMAGE_DIR}/${VM_NAME}.qcow2"
SEED_IMAGE="${VM_IMAGE_DIR}/${VM_NAME}-seed.img"
if sudo test -e "$VM_DISK" || sudo test -e "$SEED_IMAGE"; then
  die "VM disk artifacts for '$VM_NAME' already exist under $VM_IMAGE_DIR."
fi

log "Creating the VM disk and cloud-init seed"
cloud-localds "$WORK_DIR/seed.img" \
  "$WORK_DIR/user-data" "$WORK_DIR/meta-data"

# The seed carries the guest password hash, so it is created root-only. libvirt
# applies its own ownership to the file when the domain starts; no human
# account needs access to it at any point, and it is destroyed once
# provisioning has finished.
sudo install -o root -g root -m 0600 "$WORK_DIR/seed.img" "$SEED_IMAGE"
sudo cp --reflink=auto --sparse=always "$BASE_IMAGE" "$VM_DISK"
sudo qemu-img resize "$VM_DISK" "${DISK_GB}G"
if ! qemu_info_json="$(
    sudo qemu-img info --output=json "$VM_DISK"
  )"; then
  die "qemu-img could not inspect the qcow2 image after resizing."
fi
if ! vm_virtual_bytes="$(
    printf '%s\n' "$qemu_info_json" | parse_qemu_virtual_size_bytes
  )"; then
  die "qemu-img returned invalid JSON or no positive integer virtual-size."
fi
if ((vm_virtual_bytes < requested_disk_bytes)); then
  die "The qcow2 image reports ${vm_virtual_bytes} bytes after resizing; at least ${requested_disk_bytes} bytes (${DISK_GB} GiB) were requested."
fi
sudo chown root:kvm "$VM_DISK"
sudo chmod 0660 "$VM_DISK"
CREATED_VM_ARTIFACTS="yes"

log "Creating and starting the graphical libvirt guest"
sudo virt-install \
  --connect "$LIBVIRT_URI" \
  --name "$VM_NAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --cpu host-model \
  --osinfo ubuntu24.04 \
  --import \
  --disk "path=${VM_DISK},format=qcow2,bus=virtio,cache=none,discard=unmap" \
  --disk "path=${SEED_IMAGE},device=cdrom,readonly=on" \
  --network "network=${LIBVIRT_NETWORK},model=virtio" \
  --graphics "spice,listen=none" \
  --video virtio \
  --input "tablet,bus=usb" \
  --console "pty,target_type=serial" \
  --rng /dev/urandom \
  --noautoconsole

print_next_steps() {
  local guest_ip="${1:-VM_ADDRESS}"

  printf '\nThe VM is managed by system libvirt and is visible in virt-manager.\n'
  printf 'If this script added your host account to the libvirt group for\n'
  printf 'the first time, log out of Ubuntu and back in once before opening\n'
  printf 'virt-manager.\n\n'
  printf 'Open the graphical console:\n'
  printf '  virt-manager --connect %q\n\n' "$LIBVIRT_URI"
  printf 'Recovery SSH key:\n'
  printf '  %s\n\n' "$SSH_PRIVATE_KEY"
  printf 'Recovery SSH command:\n'
  printf '  ssh -o IdentitiesOnly=yes -i %q %q@%q\n\n' \
    "$SSH_PRIVATE_KEY" "$GUEST_USER" "$guest_ip"
  printf 'Inside the desktop terminal, start a tool with:\n'
  printf '  codex    claude    opencode    aider    ollama\n'
  if [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
    printf '  code     lean      lake        isabelle\n'
    printf '  ghc      ghci      cabal       hlint\n'
    printf 'For Isabelle/HOL, run: isabelle jedit\n'
  fi
  if [[ "$SWARM_ROLE" != "none" ]]; then
    printf '\nOptional swarm profile (%s over %s):\n' \
      "$SWARM_ROLE" "$SWARM_NETWORK"
    printf '  kvm-agent-swarm-status\n'
    if [[ "$SWARM_NETWORK" == "tailscale" ]]; then
      printf 'Join the guest to the intended tailnet manually with:\n'
      printf '  kvm-agent-swarm-tailscale-up [DEVICE-NAME]\n'
    else
      printf 'Create and review /etc/wireguard/wg0.conf before enabling wg-quick@wg0.\n'
    fi
    if [[ "$SWARM_ROLE" == "manager" || "$SWARM_ROLE" == "both" ]]; then
      printf 'Display the dedicated manager public key with:\n'
      printf '  kvm-agent-swarm-manager-info\n'
    fi
    if [[ "$SWARM_ROLE" == "worker" || "$SWARM_ROLE" == "both" ]]; then
      printf 'Authorize one manager key from standard input with:\n'
      printf '  kvm-agent-swarm-worker-info\n'
      printf '  sudo kvm-agent-swarm-authorize\n'
    fi
    printf 'Complete the least-privilege network policy in docs/swarm.md.\n'
  fi
}

if [[ "$WAIT_FOR_GUEST" != "yes" ]]; then
  warn "Provisioning continues inside the running VM."
  printf 'When it has finished, complete the verified cleanup with:\n'
  printf '  %q --finalize-existing --name %q --user %q\n\n' \
    "${SCRIPT_DIR}/setup-kvm-agent.sh" "$VM_NAME" "$GUEST_USER"
  print_next_steps
  exit 0
fi

log "Waiting for desktop and agent-tool provisioning to finish"
if [[ "$WITH_FORMAL_METHODS" == "yes" ]]; then
  printf 'Lean, Isabelle, Haskell, HLint, VS Code, and the agent tools may take several hours to install.\n'
else
  printf 'This commonly takes 20-60 minutes and may take longer on a slow host.\n'
fi
finalize_managed_guest

log "KVM-Agent setup completed"
print_next_steps "$GUEST_IP"
