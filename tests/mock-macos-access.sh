#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_DIR}/macos/setup-secure-access.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/home/.ssh"
cat > "$TEMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -s ]]; then
  echo Darwin
else
  /usr/bin/uname "$@"
fi
EOF
cat > "$TEMP_DIR/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($# > 0)); do
  case "$1" in
    -f) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
mkdir -p "$(dirname -- "$output")"
printf 'mock encrypted private key\n' > "$output"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockController controller test\n' \
  > "${output}.pub"
EOF
cat > "$TEMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -G ]]
printf 'hostname %s\n' "${2:-}" >/dev/null
EOF
chmod 0755 "$TEMP_DIR/bin/"*

# Deliberately put the managed Include below a broad Host block. The helper
# must move it to the first line so first-value-wins OpenSSH parsing is safe.
cat > "$TEMP_DIR/home/.ssh/config" <<'EOF'
Host *
    ForwardAgent yes
    ForwardX11 yes
Include ~/.ssh/kvm-agent.d/*.conf
EOF
chmod 0600 "$TEMP_DIR/home/.ssh/config"

MOCK_PATH="$TEMP_DIR/bin:$PATH"
HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" research-a-manager > "$TEMP_DIR/output"

main_config="$TEMP_DIR/home/.ssh/config"
managed_config="$TEMP_DIR/home/.ssh/kvm-agent.d/research-a-manager.conf"
[[ "$(head -n 1 "$main_config")" == \
  'Include ~/.ssh/kvm-agent.d/*.conf' ]]
[[ "$(grep -Fxc 'Include ~/.ssh/kvm-agent.d/*.conf' "$main_config")" == 1 ]]
[[ "$(stat -c %a "$main_config")" == 600 ]]
[[ "$(stat -c %a "$managed_config")" == 600 ]]
for expected in \
    '    IdentityAgent none' \
    '    ForwardAgent no' \
    '    ForwardX11 no' \
    '    ClearAllForwardings yes' \
    '    ProxyJump none' \
    '    StrictHostKeyChecking ask' \
    '    AddKeysToAgent no' \
    '    UseKeychain yes'; do
  grep -Fxq -- "$expected" "$managed_config"
done
grep -Fq -- 'kvm-agent-authorize-controller-key' "$TEMP_DIR/output"

backup_count="$(find "$TEMP_DIR/home/.ssh" -maxdepth 1 \
  -name 'config.kvm-agent-backup.*' -type f | wc -l)"
HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" research-a-manager >/dev/null
[[ "$(find "$TEMP_DIR/home/.ssh" -maxdepth 1 \
  -name 'config.kvm-agent-backup.*' -type f | wc -l)" == "$backup_count" ]]

HOME="$TEMP_DIR/home" PATH="$MOCK_PATH" \
  "$HELPER" research-a-manager --add-remote-editor-alias \
  > "$TEMP_DIR/editor-output"
grep -Fxq -- 'Host research-a-manager-editor' "$managed_config"
grep -Fq -- 'kvm-agent-authorize-controller-key --allow-port-forwarding' \
  "$TEMP_DIR/editor-output"
awk '
  /^Host research-a-manager-editor$/ { editor = 1; next }
  /^Host / { editor = 0 }
  editor && /ClearAllForwardings no/ { found = 1 }
  END { exit(found ? 0 : 1) }
' "$managed_config"

echo 'Mock macOS-access checks passed.'
