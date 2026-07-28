#!/usr/bin/env bash
set -euo pipefail
umask 077

# Exercise safe removal and fail-closed behavior without a real libvirt host.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p \
  "$TEMP_DIR/bin" \
  "$TEMP_DIR/home" \
  "$TEMP_DIR/images/vms" \
  "$TEMP_DIR/libvirt-log" \
  "$TEMP_DIR/state"

cp "$REPO_DIR/remove-kvm-agent.sh" "$TEMP_DIR/remove-under-test.sh"
sed -i \
  -e "s#readonly VM_IMAGE_DIR=\"/var/lib/libvirt/images/kvm-agent/vms\"#readonly VM_IMAGE_DIR=\"${TEMP_DIR}/images/vms\"#" \
  -e "s#readonly LIBVIRT_LOG_DIR=\"/var/log/libvirt/qemu\"#readonly LIBVIRT_LOG_DIR=\"${TEMP_DIR}/libvirt-log\"#" \
  -e '/^\[\[ $EUID -ne 0 \]\] || die \\$/,+1c\true # root-account check is tested separately' \
  "$TEMP_DIR/remove-under-test.sh"
chmod 0755 "$TEMP_DIR/remove-under-test.sh"

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

cat > "$TEMP_DIR/bin/virsh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--connect" ]]; then
  shift 2
fi
command_name="${1:-}"
shift || true

case "$command_name" in
  list)
    [[ ! -f "$MOCK_STATE/query-failure" ]] || exit 1
    [[ ! -f "$MOCK_STATE/domain-defined" ]] || echo mock-agent
    ;;
  domstate)
    cat "$MOCK_STATE/domain-state"
    ;;
  dominfo)
    cat <<'OUTPUT'
Id:             -
Name:           mock-agent
State:          shut off
Persistent:     yes
OUTPUT
    ;;
  dumpxml)
    cat <<'OUTPUT'
<domain type='kvm'>
  <name>mock-agent</name>
  <devices/>
</domain>
OUTPUT
    ;;
  domblklist)
    cat <<OUTPUT
 Type       Device     Target     Source
--------------------------------------------------------
 file       disk       vda        $MOCK_IMAGES/vms/mock-agent.qcow2
 file       cdrom      sda        $MOCK_IMAGES/vms/mock-agent-seed.img
 file       disk       vdb        $MOCK_EXTERNAL
OUTPUT
    ;;
  destroy)
    touch "$MOCK_STATE/domain-destroyed"
    printf 'shut off\n' > "$MOCK_STATE/domain-state"
    ;;
  undefine)
    touch "$MOCK_STATE/domain-undefined"
    rm -f -- "$MOCK_STATE/domain-defined"
    ;;
  *)
    echo "Unexpected mocked virsh command: $command_name $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  exit 0
fi
command_name="${1:-}"
shift || true
case "$command_name" in
  virsh|test|rm|shred)
    exec "$command_name" "$@"
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
export MOCK_EXTERNAL="$TEMP_DIR/external-data.qcow2"
MOCK_PATH="$TEMP_DIR/bin:$PATH"

reset_case() {
  rm -rf -- "$TEMP_DIR/state" \
    "$TEMP_DIR/home/.local" \
    "$TEMP_DIR/images/vms"
  mkdir -p \
    "$TEMP_DIR/state" \
    "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent" \
    "$TEMP_DIR/images/vms"
  touch \
    "$TEMP_DIR/state/domain-defined" \
    "$TEMP_DIR/images/vms/mock-agent.qcow2" \
    "$TEMP_DIR/images/vms/mock-agent-seed.img" \
    "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519" \
    "$TEMP_DIR/libvirt-log/mock-agent.log"
  printf 'shut off\n' > "$TEMP_DIR/state/domain-state"
}

# Shared and manually attached data must survive every successful removal.
touch "$TEMP_DIR/images/ubuntu-base.img" "$MOCK_EXTERNAL"

reset_case
env PATH="$MOCK_PATH" \
  "$TEMP_DIR/remove-under-test.sh" --name mock-agent --yes \
  > "$TEMP_DIR/stopped-output"
grep -Fq "completely removed" "$TEMP_DIR/stopped-output"
[[ -f "$TEMP_DIR/state/domain-undefined" ]]
[[ ! -e "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]
[[ ! -e "$TEMP_DIR/images/vms/mock-agent-seed.img" ]]
[[ ! -e "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent" ]]
[[ ! -e "$TEMP_DIR/libvirt-log/mock-agent.log" ]]
[[ -f "$TEMP_DIR/images/ubuntu-base.img" ]]
[[ -f "$MOCK_EXTERNAL" ]]

reset_case
printf 'running\n' > "$TEMP_DIR/state/domain-state"
if env PATH="$MOCK_PATH" \
    "$TEMP_DIR/remove-under-test.sh" --name mock-agent --yes \
    > "$TEMP_DIR/running-output" 2>&1; then
  echo "Removal unexpectedly accepted a running VM without --force." >&2
  exit 1
fi
grep -Fq "rerun with --force" "$TEMP_DIR/running-output"
[[ -f "$TEMP_DIR/state/domain-defined" ]]
[[ -f "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]

env PATH="$MOCK_PATH" \
  "$TEMP_DIR/remove-under-test.sh" --name mock-agent --force --yes \
  > "$TEMP_DIR/force-output" 2>&1
[[ -f "$TEMP_DIR/state/domain-destroyed" ]]
[[ -f "$TEMP_DIR/state/domain-undefined" ]]
[[ ! -e "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]

reset_case
touch "$TEMP_DIR/state/query-failure"
if env PATH="$MOCK_PATH" \
    "$TEMP_DIR/remove-under-test.sh" --name mock-agent --yes \
    > "$TEMP_DIR/query-output" 2>&1; then
  echo "Removal unexpectedly treated a failed libvirt query as absence." >&2
  exit 1
fi
grep -Fq "nothing has been removed" "$TEMP_DIR/query-output"
[[ -f "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]
[[ -f "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519" ]]

rm -f -- "$TEMP_DIR/state/query-failure"
env PATH="$MOCK_PATH" \
  "$TEMP_DIR/remove-under-test.sh" --name mock-agent --dry-run \
  > "$TEMP_DIR/dry-run-output"
grep -Fq "Dry run only" "$TEMP_DIR/dry-run-output"
[[ -f "$TEMP_DIR/state/domain-defined" ]]
[[ -f "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]

echo "Mocked removal workflows passed."
