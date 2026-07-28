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

VM_NAME="kvm-agent"
GUEST_USER="agent"
RAM_MB=""
VCPUS=""
DISK_GB="80"
WAIT_FOR_GUEST="yes"
RESTRICT_PRIVATE_NETWORKS="yes"
GATEWAY_ADDRESS=""
OPERATION="create"
REPLACE_EXISTING="no"
WITH_FORMAL_METHODS="no"

WORK_DIR=""
VM_DISK=""
SEED_IMAGE=""
CREATED_VM_ARTIFACTS="no"

usage() {
  cat <<'EOF'
Usage:
  ./setup-kvm-agent.sh [OPTIONS]

Create a graphical Ubuntu 24.04 LTS KVM guest and install Codex, Claude Code,
OpenCode, Aider, and Ollama inside it. Formal-methods tools are optional.

Options:
  --name NAME        VM and host name (default: kvm-agent)
  --user NAME        Guest login name (default: agent)
  --memory MB        Guest RAM in MiB (default: half of host RAM, 8-16 GiB)
  --vcpus NUMBER     Guest virtual CPUs (default: half of host CPUs, 2-8)
  --disk GB          Guest virtual disk size (default: 80)
  --no-wait          Start provisioning but do not wait for it to finish
  --allow-lan        Permit guest egress to private and link-local address
                     ranges. The firewall remains enabled and still denies
                     unsolicited inbound traffic. Use only when needed.
  --formal-methods   Also install Lean 4/elan, Isabelle2025-2/HOL,
                     GHC/GHCup, Cabal, HLS, HLint, VS Code, and the official
                     Lean and Haskell VS Code extensions inside the guest.
                     This may add several hours to first provisioning.
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
  local live_blocks
  local config_blocks
  local seed_targets
  local seed_target
  local wait_status=0

  [[ -r "$SSH_PRIVATE_KEY" ]] || die \
    "Recovery SSH key not found: $SSH_PRIVATE_KEY"
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

  if guest_ssh "test -e /var/run/reboot-required"; then
    log "Rebooting once to activate guest kernel and desktop updates"
    guest_ssh \
      "sudo systemctl reboot" >/dev/null 2>&1 || true

    # The guest may return with a different lease. Successful SSH plus the
    # provisioning marker is the meaningful post-reboot condition.
    GUEST_IP=""
    if ! wait_for_guest_ssh 180 \
        "sudo test -f /var/lib/kvm-agent/provisioned"; then
      die "The guest did not become reachable after its update reboot. Finalization stopped before cleanup."
    fi
  fi

  log "Disabling future cloud-init runs in the guest"
  guest_ssh \
    "sudo install -o root -g root -m 0644 /dev/null /etc/cloud/cloud-init.disabled" \
    || die "Could not disable future cloud-init runs; the seed was retained."
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
    --replace-existing)
      REPLACE_EXISTING="yes"
      shift
      ;;
    --finalize-existing)
      OPERATION="finalize"
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
if [[ "$OPERATION" == "finalize" ]]; then
  [[ "$REPLACE_EXISTING" == "no" ]] || die \
    "--finalize-existing and --replace-existing cannot be used together."
  [[ -z "$RAM_MB" && -z "$VCPUS" && "$DISK_GB" == "80" \
      && "$WAIT_FOR_GUEST" == "yes" \
      && "$RESTRICT_PRIVATE_NETWORKS" == "yes" \
      && "$WITH_FORMAL_METHODS" == "no" ]] || die \
    "--finalize-existing accepts only --name and --user."
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

if [[ -z "$RAM_MB" ]]; then
  RAM_MB=$((HOST_RAM_MB / 2))
  ((RAM_MB < 8192)) && RAM_MB=8192
  ((RAM_MB > 16384)) && RAM_MB=16384
fi
if [[ -z "$VCPUS" ]]; then
  VCPUS=$((HOST_CPUS / 2))
  ((VCPUS < 2)) && VCPUS=2
  ((VCPUS > 8)) && VCPUS=8
fi

positive_integer "$RAM_MB" || die "--memory must be a positive integer."
positive_integer "$VCPUS" || die "--vcpus must be a positive integer."
((RAM_MB >= 6144)) || die "The graphical agent guest needs at least 6144 MiB."
((RAM_MB + 2048 < HOST_RAM_MB)) || die \
  "Leave at least 2 GiB of RAM for the Ubuntu host (host: ${HOST_RAM_MB} MiB)."
((VCPUS <= HOST_CPUS)) || die \
  "Guest vCPUs (${VCPUS}) cannot exceed host CPUs (${HOST_CPUS})."

if ((RAM_MB < 8192)); then
  warn "Less than 8 GiB may make desktop provisioning and agent use slow."
fi
if ((DISK_GB < 80)); then
  warn "Less than 80 GiB leaves limited room for model weights and projects."
fi
if [[ "$WITH_FORMAL_METHODS" == "yes" && "$DISK_GB" -lt 100 ]]; then
  warn "The formal-methods toolchains fit in 80 GiB, but 100-120 GiB is preferable for project dependencies and build products."
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

sudo install -d -o root -g kvm -m 0750 "$IMAGE_DIR" "$VM_IMAGE_DIR"
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
printf 'formal-methods=%s\n' "$WITH_FORMAL_METHODS" \
  > "$PROVISIONING_MODE_FILE"
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
record_provisioning_failure() {
  local exit_status=$?
  trap - EXIT
  if ((exit_status != 0)); then
    printf 'Provisioning failed: %s\n' "$(date --utc --iso-8601=seconds)" \
      > /var/lib/kvm-agent/provisioning-failed
    chmod 0644 /var/lib/kvm-agent/provisioning-failed
  fi
  exit "$exit_status"
}
trap record_provisioning_failure EXIT

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
fi

systemctl enable --now qemu-guest-agent.service
systemctl enable ssh.service
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

# Installers are staged in a root-owned directory rather than under /tmp. The
# directory is traversable but not writable by anyone except root, and each
# staged file stays root-owned and read-only, so a predictable world-writable
# path can never be pre-created as a symlink for a root-run "curl --output" to
# follow, and the guest user cannot alter an installer between the download and
# the moment it runs.
install -d -o root -g root -m 0711 /run/kvm-agent-install
staging_dir="$(mktemp -d /run/kvm-agent-install/stage.XXXXXXXX)"
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

install_guest_script codex "https://chatgpt.com/codex/install.sh"
install_guest_script claude-code "https://claude.ai/install.sh"
install_guest_script opencode "https://opencode.ai/install"

echo "Installing Aider through an isolated uv bootstrap..."
uv_bootstrap="${guest_home}/.local/share/kvm-agent/uv-bootstrap"
as_guest python3 -m venv "$uv_bootstrap"
as_guest "$uv_bootstrap/bin/python" -m pip install --upgrade pip uv
as_guest "$uv_bootstrap/bin/uv" tool install \
  --force --python python3.12 --with pip 'aider-chat@latest'

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

runcmd:
  - ["/usr/local/sbin/kvm-agent-provision", "${GUEST_USER}", "${RESTRICT_PRIVATE_NETWORKS}", "${GATEWAY_ADDRESS}", "${WITH_FORMAL_METHODS}"]

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
