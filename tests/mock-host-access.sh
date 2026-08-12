#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_DIR}/host/kvm-agent-host"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin" \
  "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent"
printf 'mock private key\n' > \
  "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519"
printf 'guest-user=coder\n' > \
  "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/provisioning-mode"
chmod 0600 "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519"

cat > "$TEMP_DIR/bin/virsh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --connect ]]; then
  shift 2
fi
command_name="${1:-}"
shift || true
case "$command_name" in
  list)
    printf 'mock-agent\n'
    ;;
  dominfo)
    [[ "${1:-}" == mock-agent ]]
    printf 'Name: mock-agent\nState: running\n'
    ;;
  domifaddr)
    cat <<'OUTPUT'
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet0      52:54:00:00:00:01    ipv4        192.168.122.50/24
OUTPUT
    ;;
  start|shutdown)
    printf '%s %s\n' "$command_name" "$*" >> "$MOCK_VIRSH_LOG"
    ;;
  *)
    printf 'Unexpected virsh command: %s %s\n' "$command_name" "$*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_SSH_ARGUMENTS"
EOF

cat > "$TEMP_DIR/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_RSYNC_ARGUMENTS"
EOF
chmod 0755 "$TEMP_DIR/bin/"*

export MOCK_VIRSH_LOG="$TEMP_DIR/virsh.log"
export MOCK_SSH_ARGUMENTS="$TEMP_DIR/ssh.arguments"
export MOCK_RSYNC_ARGUMENTS="$TEMP_DIR/rsync.arguments"
MOCK_PATH="$TEMP_DIR/bin:$PATH"

HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" "$HELPER" list \
  | grep -Fxq mock-agent
[[ "$(HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" ip mock-agent)" == 192.168.122.50 ]]

HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" ssh mock-agent uname -a
for expected in \
    'ClearAllForwardings=yes' \
    'ForwardAgent=no' \
    'ForwardX11=no' \
    'IdentityAgent=none' \
    'HostKeyAlias=kvm-agent-mock-agent' \
    'coder@192.168.122.50'; do
  grep -Fxq -- "$expected" "$MOCK_SSH_ARGUMENTS"
done

printf 'reviewed input\n' > "$TEMP_DIR/input.patch"
HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" push mock-agent "$TEMP_DIR/input.patch" Work/
grep -Fxq -- '--protect-args' "$MOCK_RSYNC_ARGUMENTS"
grep -Fxq -- 'coder@192.168.122.50:Work/' "$MOCK_RSYNC_ARGUMENTS"

HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" pull mock-agent Work/result.patch >/dev/null
quarantine="$TEMP_DIR/home/vm-extraction-quarantine/mock-agent"
[[ -d "$quarantine" && "$(stat -c %a "$quarantine")" == 700 ]]
grep -Fxq -- 'coder@192.168.122.50:Work/result.patch' \
  "$MOCK_RSYNC_ARGUMENTS"
grep -Fxq -- "$quarantine/" "$MOCK_RSYNC_ARGUMENTS"
for expected in --safe-links --no-devices --no-specials \
    '--chmod=Du=rwx,Dgo=,Fu=rw,Fgo='; do
  grep -Fxq -- "$expected" "$MOCK_RSYNC_ARGUMENTS"
done

if HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
    "$HELPER" pull mock-agent $'unsafe\npath' >/dev/null 2>&1; then
  echo 'Host helper accepted a newline in a remote path.' >&2
  exit 1
fi
if HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
    "$HELPER" --user root ssh mock-agent >/dev/null 2>&1; then
  echo 'Host helper accepted root as the guest login.' >&2
  exit 1
fi

echo 'Mock host-access checks passed.'
