#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# KVM-Agent: create one graphical Ubuntu VM and provision coding-agent tools.
#
# Run this script as the ordinary Ubuntu host account that will use
# virt-manager. Do not run the script itself with sudo; it asks for sudo only
# for host package installation and system-libvirt operations. Third-party
# coding-agent installers execute inside the guest, never on the host.

readonly GUEST_RELEASE="24.04"
readonly GUEST_ARCH="amd64"
readonly LIBVIRT_URI="qemu:///system"
readonly LIBVIRT_NETWORK="default"

VM_NAME="kvm-agent"
GUEST_USER="agent"
RAM_MB=""
VCPUS=""
DISK_GB="80"
WAIT_FOR_GUEST="yes"
RESTRICT_PRIVATE_NETWORKS="yes"
GATEWAY_ADDRESS=""

WORK_DIR=""
VM_DISK=""
SEED_IMAGE=""
CREATED_VM_ARTIFACTS="no"

usage() {
  cat <<'EOF'
Usage:
  ./setup-kvm-agent.sh [OPTIONS]

Create a graphical Ubuntu 24.04 LTS KVM guest and install Codex, Claude Code,
OpenCode, Aider, and Ollama inside it.

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

log "Configuration"
printf 'Host account:   %s\n' "$HOST_USER"
printf 'VM name:        %s\n' "$VM_NAME"
printf 'Guest login:    %s\n' "$GUEST_USER"
printf 'Guest release:  Ubuntu %s LTS desktop\n' "$GUEST_RELEASE"
printf 'Resources:      %s MiB RAM, %s vCPU, %s GiB disk\n' \
  "$RAM_MB" "$VCPUS" "$DISK_GB"
printf 'Provisioning:   Codex, Claude Code, OpenCode, Aider, Ollama\n'

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

if sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME" \
    >/dev/null 2>&1; then
  die "A libvirt VM named '$VM_NAME' already exists. Choose another --name or remove it deliberately in virt-manager."
fi

readonly IMAGE_NAME="ubuntu-${GUEST_RELEASE}-server-cloudimg-${GUEST_ARCH}.img"
readonly IMAGE_BASE_URL="https://cloud-images.ubuntu.com/releases/${GUEST_RELEASE}/release"
readonly IMAGE_DIR="/var/lib/libvirt/images/kvm-agent"
readonly VM_IMAGE_DIR="${IMAGE_DIR}/vms"
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

readonly KEY_DIR="${HOST_USER_HOME}/.local/share/kvm-agent/${VM_NAME}"
readonly SSH_PRIVATE_KEY="${KEY_DIR}/id_ed25519"
readonly SSH_PUBLIC_KEY_FILE="${SSH_PRIVATE_KEY}.pub"
readonly SSH_KNOWN_HOSTS="${KEY_DIR}/known_hosts"

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
guest_home="$(getent passwd "$guest_user" | awk -F: '{print $6}')"
guest_group="$(id -gn "$guest_user")"
guest_path="${guest_home}/.local/bin:${guest_home}/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root_runtime_home="/root"

[[ -n "$guest_home" && -d "$guest_home" ]] || {
  echo "Cannot resolve guest home for $guest_user." >&2
  exit 1
}

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
  "$guest_home/.local/bin" \
  "$guest_home/.local/share/kvm-agent"

cat > /etc/profile.d/kvm-agent-tools.sh <<'PROFILE'
# Paths used by the per-user native coding-agent installers.
if [ -n "${HOME:-}" ]; then
  [ ! -d "$HOME/.opencode/bin" ] || PATH="$HOME/.opencode/bin:$PATH"
  [ ! -d "$HOME/.local/bin" ] || PATH="$HOME/.local/bin:$PATH"
  export PATH
fi
PROFILE
chmod 0644 /etc/profile.d/kvm-agent-tools.sh

cat >> "$guest_home/.profile" <<'PROFILE'

# KVM-Agent tool paths
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
PROFILE
chown "$guest_user:$guest_group" "$guest_home/.profile"

as_guest() {
  runuser -u "$guest_user" -- \
    env HOME="$guest_home" USER="$guest_user" LOGNAME="$guest_user" \
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
as_guest timeout 30s codex --version
as_guest timeout 30s claude --version
as_guest timeout 30s opencode --version
as_guest timeout 30s aider --version
env HOME="$root_runtime_home" OLLAMA_HOST=127.0.0.1:11434 \
  timeout 30s ollama --version
systemctl is-active --quiet ollama.service

install -d -o root -g root -m 0755 /var/lib/kvm-agent
{
  printf 'Provisioned: %s\n' "$(date --utc --iso-8601=seconds)"
  as_guest codex --version
  as_guest claude --version
  as_guest opencode --version
  as_guest aider --version
  env HOME="$root_runtime_home" OLLAMA_HOST=127.0.0.1:11434 ollama --version
} > /var/lib/kvm-agent/installed-versions.txt
chmod 0644 /var/lib/kvm-agent/installed-versions.txt
touch /var/lib/kvm-agent/provisioned

# Start the display manager last so package installation cannot replace the
# user's visible session halfway through provisioning.
systemctl enable gdm3.service
systemctl start gdm3.service

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
  - ["/usr/local/sbin/kvm-agent-provision", "${GUEST_USER}", "${RESTRICT_PRIVATE_NETWORKS}", "${GATEWAY_ADDRESS}"]

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
}

if [[ "$WAIT_FOR_GUEST" != "yes" ]]; then
  warn "Provisioning continues inside the running VM."
  print_next_steps
  exit 0
fi

log "Waiting for the VM to obtain an address"
GUEST_IP=""
for _ in $(seq 1 240); do
  GUEST_IP="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domifaddr "$VM_NAME" --source lease 2>/dev/null \
      | awk '$3 == "ipv4" { split($4, address, "/"); print address[1]; exit }'
  )"
  [[ -z "$GUEST_IP" ]] || break
  sleep 5
done

if [[ -z "$GUEST_IP" ]]; then
  print_next_steps
  die "The VM did not report a DHCP address within 20 minutes. See docs/troubleshooting.md."
fi

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ForwardAgent=no
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${SSH_KNOWN_HOSTS}"
  -i "$SSH_PRIVATE_KEY"
)

log "Waiting for recovery SSH while the graphical guest boots"
ssh_ready="no"
for _ in $(seq 1 180); do
  if ssh "${ssh_options[@]}" \
      "${GUEST_USER}@${GUEST_IP}" true >/dev/null 2>&1; then
    ssh_ready="yes"
    break
  fi
  sleep 5
done
[[ "$ssh_ready" == "yes" ]] || {
  print_next_steps "$GUEST_IP"
  die "Recovery SSH did not become ready within 15 minutes."
}

log "Waiting for desktop and agent-tool provisioning to finish"
printf 'This commonly takes 20-60 minutes and may take longer on a slow host.\n'
if ! ssh "${ssh_options[@]}" \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=20 \
    "${GUEST_USER}@${GUEST_IP}" \
    "sudo cloud-init status --wait && sudo test -f /var/lib/kvm-agent/provisioned"; then
  warn "Guest provisioning failed. The final guest log follows."
  ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "sudo cloud-init status --long || true; sudo tail -n 160 /var/log/kvm-agent-provision.log || true" \
    >&2 || true
  print_next_steps "$GUEST_IP"
  die "Guest provisioning did not complete successfully."
fi

if ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "test -e /var/run/reboot-required"; then
  log "Rebooting once to activate guest kernel and desktop updates"
  ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
    "sudo systemctl reboot" >/dev/null 2>&1 || true

  reboot_started="no"
  for _ in $(seq 1 60); do
    if ! ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
        true >/dev/null 2>&1; then
      reboot_started="yes"
      break
    fi
    sleep 2
  done
  [[ "$reboot_started" == "yes" ]] || warn \
    "The guest did not become unreachable; verify whether its reboot occurred."

  ssh_ready="no"
  for _ in $(seq 1 180); do
    if ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
        "test -f /var/lib/kvm-agent/provisioned" >/dev/null 2>&1; then
      ssh_ready="yes"
      break
    fi
    sleep 5
  done
  [[ "$ssh_ready" == "yes" ]] || {
    print_next_steps "$GUEST_IP"
    die "The guest did not return from its first update reboot."
  }
fi

# Provisioning is complete and any first update reboot has succeeded. Disable
# future cloud-init runs before removing its seed, so this VM becomes an
# ordinary local desktop guest after bootstrap.
log "Disabling future cloud-init runs in the guest"
ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
  "sudo install -o root -g root -m 0644 /dev/null /etc/cloud/cloud-init.disabled"

# The seed has done its job. It contains the guest password hash and is of no
# further use, so it is detached from the domain and destroyed rather than left
# attached as a CD-ROM for the life of the VM.
log "Detaching and destroying the cloud-init seed"
seed_target="$(
  LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
    domblklist "$VM_NAME" --details 2>/dev/null \
    | awk -v source="$SEED_IMAGE" '$4 == source { print $3; exit }'
)"

if [[ -z "$seed_target" ]]; then
  warn "Could not find the seed device on '$VM_NAME'; leaving $SEED_IMAGE in place."
else
  seed_detached="no"
  if sudo virsh --connect "$LIBVIRT_URI" change-media "$VM_NAME" \
      "$seed_target" --eject --live --config --force >/dev/null 2>&1; then
    seed_detached="yes"
  elif sudo virsh --connect "$LIBVIRT_URI" change-media "$VM_NAME" \
      "$seed_target" --eject --config --force >/dev/null 2>&1; then
    seed_detached="yes"
    warn "The seed was detached from the saved configuration only; it is released at the next shutdown."
  fi

  if [[ "$seed_detached" == "yes" ]]; then
    sudo shred --remove --zero -- "$SEED_IMAGE" 2>/dev/null \
      || sudo rm -f -- "$SEED_IMAGE"
    SEED_IMAGE=""
  else
    warn "Could not eject the seed device; $SEED_IMAGE still holds the guest password hash."
  fi
fi

log "Installed guest tool versions"
ssh "${ssh_options[@]}" "${GUEST_USER}@${GUEST_IP}" \
  "sudo cat /var/lib/kvm-agent/installed-versions.txt"

log "KVM-Agent setup completed"
print_next_steps "$GUEST_IP"
