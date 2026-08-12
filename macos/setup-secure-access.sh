#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage:
  ./macos/setup-secure-access.sh TAILSCALE_NAME [OPTIONS]

Options:
  --alias NAME                Local SSH alias (default: TAILSCALE_NAME)
  --user NAME                 Guest login name (default: agent)
  --add-remote-editor-alias   Also create NAME-editor, which permits the local
                              forwarding requested by tools such as VS Code
  -h, --help                  Show this help

This command runs on the trusted Mac. It creates a dedicated Ed25519 key and a
hardened per-VM SSH configuration. It never copies a Mac private key to the VM.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

(($# >= 1)) || {
  usage >&2
  exit 2
}
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[[ "$(uname -s)" == Darwin ]] || die \
  "This helper is for macOS. Run it in Terminal on the trusted Mac."

tailscale_name="$1"
shift
ssh_alias="$tailscale_name"
guest_user="agent"
add_editor_alias="no"

while (($# > 0)); do
  case "$1" in
    --alias)
      (($# >= 2)) || die "--alias requires a value."
      ssh_alias="$2"
      shift 2
      ;;
    --user)
      (($# >= 2)) || die "--user requires a value."
      guest_user="$2"
      shift 2
      ;;
    --add-remote-editor-alias)
      add_editor_alias="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$tailscale_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ \
    && "$tailscale_name" != *..* ]] || die \
  "TAILSCALE_NAME must be a hostname or MagicDNS name, without wildcards."
[[ "$ssh_alias" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || die \
  "SSH alias may contain only letters, digits, dots, and hyphens."
[[ "$guest_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$guest_user" != root ]] \
  || die "Guest user must be a non-root lowercase Linux account name."

ssh_directory="${HOME}/.ssh"
managed_directory="${ssh_directory}/kvm-agent.d"
key_root="${ssh_directory}/kvm-agent"
key_directory="${key_root}/${ssh_alias}"
key_file="${key_directory}/id_ed25519"
known_hosts="${ssh_directory}/kvm-agent/known_hosts"
managed_config="${managed_directory}/${ssh_alias}.conf"
main_config="${ssh_directory}/config"
include_line='Include ~/.ssh/kvm-agent.d/*.conf'

for path in "$ssh_directory" "$managed_directory" "$key_root" "$key_directory"; do
  [[ ! -L "$path" ]] || die "Refusing to use a symbolic-link directory: $path"
  [[ ! -e "$path" || -d "$path" ]] || die \
    "SSH directory path is not a directory: $path"
done
for path in "$main_config" "$managed_config" "$known_hosts" \
    "$key_file" "${key_file}.pub"; do
  [[ ! -L "$path" ]] || die "Refusing to use a symbolic-link SSH file: $path"
  [[ ! -e "$path" || -f "$path" ]] || die \
    "SSH file path is not a regular file: $path"
done

install -d -m 0700 \
  "$ssh_directory" "$managed_directory" "$key_root" "$key_directory"
touch "$known_hosts"
chmod 0600 "$known_hosts"

if [[ ! -e "$key_file" && ! -e "${key_file}.pub" ]]; then
  printf 'Creating a key used only for %s. A passphrase is recommended.\n' \
    "$ssh_alias"
  ssh-keygen -t ed25519 -a 64 \
    -C "kvm-agent-controller:${ssh_alias}" \
    -f "$key_file"
else
  [[ -r "$key_file" && -r "${key_file}.pub" ]] || die \
    "Incomplete key pair under $key_directory"
  printf 'Reusing the existing dedicated key: %s\n' "$key_file"
fi
chmod 0600 "$key_file"
chmod 0644 "${key_file}.pub"

config_staging="$(mktemp "${managed_directory}/.${ssh_alias}.XXXXXXXX")"
main_staging=""
trap 'rm -f -- "$config_staging" "${main_staging:-}"' EXIT

write_host_block() {
  local alias_name="$1"
  local clear_forwardings="$2"

  cat <<EOF
Host ${alias_name}
    HostName ${tailscale_name}
    User ${guest_user}
    IdentityFile ${key_file}
    IdentitiesOnly yes
    IdentityAgent none
    PreferredAuthentications publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForwardAgent no
    ForwardX11 no
    ClearAllForwardings ${clear_forwardings}
    ProxyJump none
    ProxyCommand none
    ControlMaster no
    ConnectTimeout 15
    ConnectionAttempts 1
    ServerAliveInterval 15
    ServerAliveCountMax 2
    HostKeyAlias kvm-agent-${ssh_alias}
    HostKeyAlgorithms ssh-ed25519
    StrictHostKeyChecking ask
    UserKnownHostsFile ${known_hosts}
    UpdateHostKeys no
    Compression no
    AddKeysToAgent no
    IgnoreUnknown UseKeychain
    UseKeychain yes
EOF
}

write_host_block "$ssh_alias" yes > "$config_staging"
if [[ "$add_editor_alias" == "yes" ]]; then
  printf '\n' >> "$config_staging"
  write_host_block "${ssh_alias}-editor" no >> "$config_staging"
fi
chmod 0600 "$config_staging"
mv -f -- "$config_staging" "$managed_config"
config_staging=""

if [[ ! -e "$main_config" ]]; then
  printf '%s\n' "$include_line" > "$main_config"
  chmod 0600 "$main_config"
elif [[ "$(head -n 1 "$main_config")" != "$include_line" \
    || "$(grep -Fxc -- "$include_line" "$main_config" || true)" != 1 ]]; then
  [[ -f "$main_config" ]] || die \
    "SSH config is not a regular file: $main_config"
  backup="$(mktemp "${main_config}.kvm-agent-backup.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")"
  cp -p -- "$main_config" "$backup"
  main_staging="$(mktemp "${ssh_directory}/.config.XXXXXXXX")"
  {
    printf '%s\n\n' "$include_line"
    awk -v managed_include="$include_line" \
      '$0 != managed_include { print }' "$main_config"
  } > "$main_staging"
  chmod 0600 "$main_staging"
  mv -f -- "$main_staging" "$main_config"
  main_staging=""
  printf 'Backed up the previous SSH config to %s\n' "$backup"
fi

ssh -G "$ssh_alias" >/dev/null || die \
  "OpenSSH rejected the generated configuration: $managed_config"

public_key="$(cat "${key_file}.pub")"
printf '\nDedicated Mac public key (safe to copy):\n%s\n' "$public_key"
printf '\nInside the VM, from its local graphical terminal, run:\n'
printf '  kvm-agent-authorize-controller-key %q\n' "$public_key"
if [[ "$add_editor_alias" == "yes" ]]; then
  printf '\nFor the optional editor alias, authorize port forwarding instead with:\n'
  printf '  kvm-agent-authorize-controller-key --allow-port-forwarding %q\n' \
    "$public_key"
  printf 'The VM must also be hardened with --allow-remote-editor.\n'
fi
printf '\nThen connect from this Mac with:\n  ssh %s\n' "$ssh_alias"
printf '\nThe first connection pins the VM host key. Before accepting it, compare the\n'
printf 'fingerprint with this command in the VM console:\n'
printf '  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256\n'
