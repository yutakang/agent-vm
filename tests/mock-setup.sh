#!/usr/bin/env bash
set -euo pipefail
umask 077

# Exercise the host orchestration without apt, libvirt, network access, or a
# real VM. This test transforms a temporary copy only; production paths and
# safety checks in setup-kvm-agent.sh remain unchanged.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

chmod 0755 "$TEMP_DIR"
mkdir -p \
  "$TEMP_DIR/bin" \
  "$TEMP_DIR/home" \
  "$TEMP_DIR/images/vms" \
  "$TEMP_DIR/state"
chmod 0777 "$TEMP_DIR/home" "$TEMP_DIR/images" \
  "$TEMP_DIR/images/vms" "$TEMP_DIR/state"
touch "$TEMP_DIR/dev-kvm"

cat > "$TEMP_DIR/os-release" <<'EOF'
ID=ubuntu
VERSION_ID=24.04
EOF

# Fixed host memory so the resource checks behave identically on any machine
# that runs the test suite.
cat > "$TEMP_DIR/meminfo" <<'EOF'
MemTotal:       33554432 kB
EOF

cp "$REPO_DIR/setup-kvm-agent.sh" "$TEMP_DIR/setup-under-test.sh"
# The single-quoted sed expression must match the literal shell variable name.
# shellcheck disable=SC2016
sed -i \
  -e "s#/etc/os-release#${TEMP_DIR}/os-release#g" \
  -e "s#/dev/kvm#${TEMP_DIR}/dev-kvm#g" \
  -e "s#/proc/meminfo#${TEMP_DIR}/meminfo#g" \
  -e "s#readonly IMAGE_DIR=\"/var/lib/libvirt/images/kvm-agent\"#readonly IMAGE_DIR=\"${TEMP_DIR}/images\"#" \
  -e '/^\[\[ $EUID -ne 0 \]\] || die \\$/,+1c\true # root-account check is tested separately' \
  -e 's/^\[\[ -t 0 \]\] || die .*$/true # interactive-terminal check covered separately/' \
  "$TEMP_DIR/setup-under-test.sh"
chmod 0755 "$TEMP_DIR/setup-under-test.sh"

printf 'mock ubuntu image\n' > \
  "$TEMP_DIR/images/ubuntu-24.04-server-cloudimg-amd64.img"
sha256sum "$TEMP_DIR/images/ubuntu-24.04-server-cloudimg-amd64.img" \
  | awk '{ print $1 }' > \
    "$TEMP_DIR/images/ubuntu-24.04-server-cloudimg-amd64.img.sha256"

cat > "$TEMP_DIR/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -un) echo tester ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

cat > "$TEMP_DIR/bin/getent" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "passwd" && "\${2:-}" == "tester" ]]; then
  echo "tester:x:1000:1000:Test User:${TEMP_DIR}/home:/bin/bash"
  exit 0
fi
/usr/bin/getent "\$@"
EOF

cat > "$TEMP_DIR/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  echo x86_64
else
  /usr/bin/uname "$@"
fi
EOF

cat > "$TEMP_DIR/bin/nproc" <<'EOF'
#!/usr/bin/env bash
echo 8
EOF

cat > "$TEMP_DIR/bin/virsh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--connect" ]]; then
  shift 2
fi
command_name="${1:-}"
shift || true

case "$command_name" in
  net-info)
    cat <<'OUTPUT'
Name:           default
UUID:           00000000-0000-0000-0000-000000000000
Active:         yes
Persistent:     yes
Autostart:      yes
OUTPUT
    ;;
  net-autostart|net-start)
    ;;
  net-dumpxml)
    cat <<'OUTPUT'
<network>
  <name>default</name>
  <bridge name='virbr0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
  </ip>
</network>
OUTPUT
    ;;
  list)
    if [[ -f "$MOCK_STATE/domain-defined" ]]; then
      echo mock-agent
    fi
    ;;
  domblklist)
    cat <<OUTPUT
 Type       Device     Target     Source
--------------------------------------------------------
 file       disk       vda        $MOCK_IMAGES/vms/mock-agent.qcow2
 file       cdrom      sda        $MOCK_IMAGES/vms/mock-agent-seed.img
OUTPUT
    ;;
  change-media)
    touch "$MOCK_STATE/seed-ejected"
    ;;
  dominfo)
    [[ -f "$MOCK_STATE/domain-defined" ]]
    ;;
  domifaddr)
    cat <<'OUTPUT'
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet0      52:54:00:00:00:01    ipv4        192.168.122.50/24
OUTPUT
    ;;
  *)
    echo "Unexpected mocked virsh command: $command_name $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/virt-install" <<'EOF'
#!/usr/bin/env bash
touch "$MOCK_STATE/domain-defined"
EOF

cat > "$TEMP_DIR/bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "resize" ]]
EOF

cat > "$TEMP_DIR/bin/cloud-localds" <<'EOF'
#!/usr/bin/env bash
touch "$1"
EOF

cat > "$TEMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
all_arguments="$*"
if [[ "$all_arguments" == *"test -e /var/run/reboot-required"* ]]; then
  exit 1
fi
if [[ "$all_arguments" == *"/etc/cloud/cloud-init.disabled"* ]]; then
  touch "$MOCK_STATE/cloud-init-disabled"
fi
if [[ "$all_arguments" == *"installed-versions.txt"* ]]; then
  cat <<'OUTPUT'
Provisioned: 2026-07-28T00:00:00+00:00
codex-cli mock
claude mock
opencode mock
aider mock
ollama mock
OUTPUT
fi
exit 0
EOF

cat > "$TEMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-n" ]]; then
  shift
fi

command_name="${1:-}"
shift || true

case "$command_name" in
  apt-get|env|systemctl|usermod|chown)
    exit 0
    ;;
  virsh|virt-install|qemu-img)
    exec "$command_name" "$@"
    ;;
  test|awk|sha256sum|cp|rm|chmod|shred)
    exec "$command_name" "$@"
    ;;
  install)
    filtered=()
    while (($# > 0)); do
      case "$1" in
        -o|-g)
          shift 2
          ;;
        *)
          filtered+=("$1")
          shift
          ;;
      esac
    done
    exec /usr/bin/install "${filtered[@]}"
    ;;
  *)
    echo "Unexpected mocked sudo command: $command_name $*" >&2
    exit 1
    ;;
esac
EOF

chmod 0755 "$TEMP_DIR/bin/"*

export MOCK_STATE="$TEMP_DIR/state"
export MOCK_IMAGES="$TEMP_DIR/images"
MOCK_PATH="$TEMP_DIR/bin:$PATH"

printf 'mockpass123\nmockpass123\n' \
  | env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --name mock-agent --memory 8192 --vcpus 2 --disk 80 \
      > "$TEMP_DIR/output"

grep -Fq "KVM-Agent setup completed" "$TEMP_DIR/output"
grep -Fq "codex-cli mock" "$TEMP_DIR/output"
grep -Fq "virt-manager --connect qemu:///system" "$TEMP_DIR/output"
[[ -f "$MOCK_STATE/domain-defined" ]]
[[ -f "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]
[[ -f "$MOCK_STATE/seed-ejected" ]]
[[ -f "$MOCK_STATE/cloud-init-disabled" ]]
[[ ! -e "$TEMP_DIR/images/vms/mock-agent-seed.img" ]]
[[ -f "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519" ]]

echo "Mocked setup workflow passed."
