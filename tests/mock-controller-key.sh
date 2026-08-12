#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_DIR}/guest/kvm-agent-authorize-controller-key"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/home"
ssh-keygen -q -t ed25519 -N '' -C 'controller test key' \
  -f "$TEMP_DIR/controller"
public_key="$(cat "$TEMP_DIR/controller.pub")"

HOME="$TEMP_DIR/home" "$HELPER" "$public_key" >/dev/null
authorized="$TEMP_DIR/home/.ssh/authorized_keys"
[[ "$(stat -c %a "$TEMP_DIR/home/.ssh")" == 700 ]]
[[ "$(stat -c %a "$authorized")" == 600 ]]
grep -Fq -- \
  "no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc $public_key" \
  "$authorized"

HOME="$TEMP_DIR/home" "$HELPER" "$public_key" >/dev/null
key_data="$(awk '{print $2}' "$TEMP_DIR/controller.pub")"
[[ "$(grep -Fc -- "$key_data" "$authorized")" == 1 ]]

HOME="$TEMP_DIR/home" "$HELPER" --allow-port-forwarding "$public_key" \
  >/dev/null 2> "$TEMP_DIR/warning"
grep -Fq -- 'port forwarding is enabled' "$TEMP_DIR/warning"
grep -Fq -- "no-agent-forwarding,no-X11-forwarding,no-user-rc $public_key" \
  "$authorized"
if grep -Fq -- 'no-port-forwarding' "$authorized"; then
  echo 'Controller helper retained no-port-forwarding after explicit opt-in.' >&2
  exit 1
fi

if HOME="$TEMP_DIR/home" "$HELPER" \
    'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQInvalid invalid' \
    >/dev/null 2>&1; then
  echo 'Controller helper accepted a non-Ed25519 key.' >&2
  exit 1
fi

mkdir -p "$TEMP_DIR/symlink-home/.ssh" "$TEMP_DIR/symlink-target"
ln -s "$TEMP_DIR/symlink-target/authorized_keys" \
  "$TEMP_DIR/symlink-home/.ssh/authorized_keys"
if HOME="$TEMP_DIR/symlink-home" "$HELPER" "$public_key" \
    >/dev/null 2>&1; then
  echo 'Controller helper followed a symbolic authorized_keys path.' >&2
  exit 1
fi

echo 'Mock controller-key checks passed.'
