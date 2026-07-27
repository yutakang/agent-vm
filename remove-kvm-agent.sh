#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Remove one VM created by setup-kvm-agent.sh.
#
# This deliberately does not use libvirt's --remove-all-storage option. It
# removes only KVM-Agent's exact per-VM paths, so an extra disk attached by the
# user is reported but never deleted automatically.

readonly LIBVIRT_URI="qemu:///system"
readonly VM_IMAGE_DIR="/var/lib/libvirt/images/kvm-agent/vms"
readonly LIBVIRT_LOG_DIR="/var/log/libvirt/qemu"

VM_NAME="kvm-agent"
FORCE_OFF="no"
ASSUME_YES="no"
DRY_RUN="no"

usage() {
  cat <<'EOF'
Usage:
  ./remove-kvm-agent.sh [OPTIONS]

Completely remove one VM created by setup-kvm-agent.sh while retaining the
shared Ubuntu base-image cache and the host's KVM/libvirt packages.

Options:
  --name NAME        VM name (default: kvm-agent)
  --force            Force off a running VM before removal
  --yes              Skip the typed confirmation
  --dry-run          Show the removal plan without changing anything
  -h, --help         Show this help

The script removes only:
  * the named libvirt domain and its domain-specific metadata;
  * /var/lib/libvirt/images/kvm-agent/vms/NAME.qcow2;
  * /var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img, if present;
  * ~/.local/share/kvm-agent/NAME; and
  * the named domain's current libvirt QEMU log.

Any additional attached storage is reported and retained.
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

while (($# > 0)); do
  case "$1" in
    --name)
      (($# >= 2)) || die "--name requires a value."
      VM_NAME="$2"
      shift 2
      ;;
    --force)
      FORCE_OFF="yes"
      shift
      ;;
    --yes)
      ASSUME_YES="yes"
      shift
      ;;
    --dry-run)
      DRY_RUN="yes"
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
[[ "$VM_NAME" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || die \
  "VM name must start with a lowercase letter and contain only a-z, 0-9, or '-'."
command -v virsh >/dev/null 2>&1 || die \
  "virsh is not installed. This does not look like a configured KVM-Agent host."

HOST_USER="$(id -un)"
HOST_USER_HOME="$(getent passwd "$HOST_USER" | awk -F: '{print $6}')"
[[ -n "$HOST_USER_HOME" && "$HOST_USER_HOME" == /* \
    && -d "$HOST_USER_HOME" ]] || die \
  "Cannot resolve a usable home directory for host account '$HOST_USER'."

readonly VM_DISK="${VM_IMAGE_DIR}/${VM_NAME}.qcow2"
readonly SEED_IMAGE="${VM_IMAGE_DIR}/${VM_NAME}-seed.img"
readonly KEY_DIR="${HOST_USER_HOME}/.local/share/kvm-agent/${VM_NAME}"
readonly LIBVIRT_LOG="${LIBVIRT_LOG_DIR}/${VM_NAME}.log"

log "Authorising VM removal inspection"
sudo -v

# Query the complete name list once. A failed query is never interpreted as an
# absent domain because that could lead to deleting storage still in use.
if ! domain_names="$(
  LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" list --all --name
)"; then
  die "Could not query system libvirt; nothing has been removed."
fi

DOMAIN_PRESENT="no"
if grep -Fxq -- "$VM_NAME" <<< "$domain_names"; then
  DOMAIN_PRESENT="yes"
fi

domain_state="not defined"
domain_persistent="no"
domain_xml=""
attached_storage=""
if [[ "$DOMAIN_PRESENT" == "yes" ]]; then
  domain_state="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" domstate "$VM_NAME"
  )" || die "Could not read the state of '$VM_NAME'; nothing has been removed."
  domain_state="${domain_state//$'\r'/}"

  domain_info="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" dominfo "$VM_NAME"
  )" || die "Could not inspect '$VM_NAME'; nothing has been removed."
  if grep -Eq '^Persistent:[[:space:]]+yes$' <<< "$domain_info"; then
    domain_persistent="yes"
  fi

  domain_xml="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" dumpxml "$VM_NAME"
  )" || die "Could not inspect the XML of '$VM_NAME'; nothing has been removed."
  attached_storage="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" \
      domblklist "$VM_NAME" --details
  )" || die "Could not inspect storage for '$VM_NAME'; nothing has been removed."
fi

path_exists() {
  local path=$1
  if [[ "$path" == "$KEY_DIR" ]]; then
    [[ -e "$path" || -L "$path" ]]
  else
    sudo test -e "$path" || sudo test -L "$path"
  fi
}

log "Removal plan"
printf 'VM name:       %s\n' "$VM_NAME"
printf 'Domain:        %s (%s)\n' "$DOMAIN_PRESENT" "$domain_state"
printf 'Managed disk:  %s%s\n' "$VM_DISK" \
  "$([[ -e "$VM_DISK" ]] 2>/dev/null && printf ' [visible to host account]' || true)"
printf 'Seed image:    %s\n' "$SEED_IMAGE"
printf 'Recovery data: %s\n' "$KEY_DIR"
printf 'Libvirt log:   %s\n' "$LIBVIRT_LOG"
printf 'Retained:      /var/lib/libvirt/images/kvm-agent/ubuntu-*-cloudimg-*.img\n'
printf 'Retained:      KVM/libvirt/virt-manager host packages\n'

if [[ -n "$attached_storage" ]]; then
  printf '\nCurrently attached storage:\n%s\n' "$attached_storage"
  printf 'Only the two exact managed image paths listed above will be deleted.\n'
  printf 'Any additional attached storage will be retained.\n'
fi

anything_present="$DOMAIN_PRESENT"
for candidate in "$VM_DISK" "$SEED_IMAGE" "$KEY_DIR" "$LIBVIRT_LOG"; do
  if path_exists "$candidate"; then
    anything_present="yes"
  fi
done

if [[ "$anything_present" != "yes" ]]; then
  printf '\nNothing belonging to KVM-Agent VM %q was found.\n' "$VM_NAME"
  exit 0
fi

case "$domain_state" in
  "not defined"|"shut off"|"crashed")
    ;;
  *)
    if [[ "$FORCE_OFF" != "yes" ]]; then
      die "VM '$VM_NAME' is '$domain_state'. Shut it down normally, or rerun with --force."
    fi
    warn "--force will immediately power off the guest and may corrupt its filesystem."
    ;;
esac

if [[ "$DRY_RUN" == "yes" ]]; then
  printf '\nDry run only; nothing was removed.\n'
  exit 0
fi

if [[ "$ASSUME_YES" != "yes" ]]; then
  [[ -t 0 ]] || die \
    "An interactive terminal is required unless --yes is supplied."
  printf '\nThis operation cannot be undone by KVM-Agent.\n'
  read -r -p "Type the exact VM name '$VM_NAME' to remove it: " confirmation
  [[ "$confirmation" == "$VM_NAME" ]] || die "Confirmation did not match; nothing has been removed."
fi

if [[ "$DOMAIN_PRESENT" == "yes" ]]; then
  case "$domain_state" in
    "not defined"|"shut off"|"crashed")
      ;;
    *)
      log "Forcing off the running domain"
      sudo virsh --connect "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null
      ;;
  esac

  # A transient domain disappears when it is destroyed. setup-kvm-agent.sh
  # creates persistent domains, but handling a transient one makes the failure
  # path safe without assuming that every domain retained its original form.
  if [[ "$domain_persistent" == "yes" ]]; then
    log "Undefining the libvirt domain and its metadata"
    undefine_options=(--managed-save --snapshots-metadata)
    if grep -q '<nvram[ >]' <<< "$domain_xml"; then
      undefine_options+=(--nvram)
    fi
    sudo virsh --connect "$LIBVIRT_URI" \
      undefine "$VM_NAME" "${undefine_options[@]}" >/dev/null
  fi

  if ! updated_names="$(
    LC_ALL=C sudo virsh --connect "$LIBVIRT_URI" list --all --name
  )"; then
    die "Could not verify domain removal; VM-specific files have been retained."
  fi
  if grep -Fxq -- "$VM_NAME" <<< "$updated_names"; then
    die "The libvirt domain still exists; VM-specific files have been retained."
  fi
fi

log "Removing exact VM-specific files"
if sudo test -e "$SEED_IMAGE" || sudo test -L "$SEED_IMAGE"; then
  # Best-effort overwrite before deletion. This is not guaranteed secure erase
  # on SSD, copy-on-write, or layered storage.
  sudo shred --remove --zero -- "$SEED_IMAGE" 2>/dev/null \
    || sudo rm -f -- "$SEED_IMAGE"
fi
sudo rm -f -- "$VM_DISK"
sudo rm -f -- "$LIBVIRT_LOG"
if [[ -e "$KEY_DIR" || -L "$KEY_DIR" ]]; then
  rm -rf --one-file-system -- "$KEY_DIR"
fi

for candidate in "$VM_DISK" "$SEED_IMAGE" "$KEY_DIR" "$LIBVIRT_LOG"; do
  if path_exists "$candidate"; then
    die "Removal is incomplete; path still exists: $candidate"
  fi
done

printf '\nKVM-Agent VM %q was completely removed.\n' "$VM_NAME"
printf 'The verified Ubuntu base-image cache and host packages were retained.\n'
