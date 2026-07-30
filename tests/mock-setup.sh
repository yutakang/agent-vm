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
  "$TEMP_DIR/keyrings" \
  "$TEMP_DIR/state"
chmod 0777 "$TEMP_DIR/home" "$TEMP_DIR/images" \
  "$TEMP_DIR/images/vms" "$TEMP_DIR/state"
touch "$TEMP_DIR/dev-kvm"
touch "$TEMP_DIR/keyrings/ubuntu-cloudimage-keyring.gpg"

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
cat > "$TEMP_DIR/remove-kvm-agent.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_STATE/remove-arguments"
rm -f -- \
  "$MOCK_STATE/domain-defined" \
  "$MOCK_STATE/reboot-requested" \
  "$MOCK_STATE/rebooted" \
  "$MOCK_STATE/old-boot-probe-observed" \
  "$MOCK_STATE/reboot-before-disable" \
  "$MOCK_STATE/seed-ejected" \
  "$MOCK_STATE/cloud-init-disabled" \
  "$MOCK_STATE/provisioning-failed" \
  "$MOCK_IMAGES/vms/mock-agent.qcow2" \
  "$MOCK_IMAGES/vms/mock-agent-seed.img"
rm -rf -- "$MOCK_HOME/.local/share/kvm-agent/mock-agent"
EOF
chmod 0755 "$TEMP_DIR/remove-kvm-agent.sh"
# The single-quoted sed expression must match the literal shell variable name.
# shellcheck disable=SC2016
sed -i \
  -e "s#/etc/os-release#${TEMP_DIR}/os-release#g" \
  -e "s#/dev/kvm#${TEMP_DIR}/dev-kvm#g" \
  -e "s#/proc/meminfo#${TEMP_DIR}/meminfo#g" \
  -e "s#/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg#${TEMP_DIR}/keyrings/ubuntu-cloudimage-keyring.gpg#g" \
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

cat > "$TEMP_DIR/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
output=""
while (($# > 0)); do
  case "$1" in
    -f)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output" ]] || exit 1
mkdir -p "$(dirname -- "$output")"
printf 'mock-private-key\n' > "$output"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKey kvm-agent-mock\n' \
  > "${output}.pub"
chmod 0600 "$output"
chmod 0644 "${output}.pub"
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
    if [[ -f "$MOCK_STATE/seed-ejected" ]]; then
      cat <<OUTPUT
 Type       Device     Target     Source
--------------------------------------------------------
 file       disk       vda        $MOCK_IMAGES/vms/mock-agent.qcow2
 file       cdrom      sda
OUTPUT
    else
      cat <<OUTPUT
 Type       Device     Target     Source
--------------------------------------------------------
 file       disk       vda        $MOCK_IMAGES/vms/mock-agent.qcow2
 file       cdrom      sda        $MOCK_IMAGES/vms/mock-agent-seed.img
OUTPUT
    fi
    ;;
  change-media)
    touch "$MOCK_STATE/seed-ejected"
    ;;
  dominfo)
    [[ -f "$MOCK_STATE/domain-defined" ]] || exit 1
    cat <<OUTPUT
Id:             -
Name:           mock-agent
State:          shut off
Managed save:   $(if [[ -f "$MOCK_STATE/managed-save" ]]; then echo yes; else echo no; fi)
OUTPUT
    ;;
  domstate)
    [[ -f "$MOCK_STATE/domain-defined" ]] || exit 1
    echo "shut off"
    ;;
  dumpxml)
    [[ -f "$MOCK_STATE/domain-defined" ]] || exit 1
    cat <<'OUTPUT'
<domain type='kvm'>
  <name>mock-agent</name>
  <memory unit='MiB'>8192</memory>
  <currentMemory unit='MiB'>8192</currentMemory>
  <vcpu current='2'>2</vcpu>
</domain>
OUTPUT
    ;;
  vcpucount)
    [[ -f "$MOCK_STATE/domain-defined" ]] || exit 1
    echo 2
    ;;
  setmaxmem|setmem|setvcpus)
    [[ -f "$MOCK_STATE/domain-defined" ]] || exit 1
    printf '%s %s\n' "$command_name" "$*" >> "$MOCK_STATE/resource-changes"
    ;;
  domifaddr)
    if [[ -f "$MOCK_STATE/rebooted" ]]; then
      address="192.168.122.51"
    else
      address="192.168.122.50"
    fi
    cat <<OUTPUT
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet0      52:54:00:00:00:01    ipv4        ${address}/24
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
case "${1:-}" in
  resize)
    printf '%s\n' "$*" > "$MOCK_STATE/qemu-img-resize"
    disk_size="${3%G}"
    printf '%s\n' "$((disk_size * 1024 * 1024 * 1024))" \
      > "$MOCK_STATE/qemu-virtual-bytes"
    ;;
  info)
    virtual_bytes="$(cat "$MOCK_STATE/qemu-virtual-bytes")"
    # QEMU JSON is valid regardless of whitespace and may be emitted compactly.
    # Keep this on one line so a line-oriented sed parser cannot pass the test.
    printf '{"format":"qcow2","virtual-size":%s,"actual-size":4096}\n' \
      "$virtual_bytes"
    ;;
  *)
    echo "Unexpected mocked qemu-img command: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/cloud-localds" <<'EOF'
#!/usr/bin/env bash
touch "$1"
cp "$2" "$MOCK_STATE/user-data"
EOF

cat > "$TEMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
all_arguments="$*"
remote_command="${@: -1}"
if [[ "$all_arguments" == *"/var/lib/kvm-agent/provisioning-failed"* \
    && -f "$MOCK_STATE/provisioning-failed" ]]; then
  exit 42
fi
if [[ "$all_arguments" == *"/var/lib/kvm-agent/provisioned"* \
    && -f "$MOCK_STATE/ssh-hang" ]]; then
  sleep 60
  exit 1
fi
if [[ "$all_arguments" == *"cloud-init status 2>/dev/null"* \
    && -f "$MOCK_STATE/provisioning-failed" ]]; then
  exit 1
fi
if [[ "$all_arguments" == *"/var/run/reboot-required"* ]]; then
  if [[ -f "$MOCK_STATE/rebooted" ]]; then
    echo no
  else
    echo yes
  fi
  exit 0
fi
if [[ "$remote_command" == "cat /proc/sys/kernel/random/boot_id" ]]; then
  if [[ -f "$MOCK_STATE/rebooted" ]]; then
    echo "22222222-2222-4222-8222-222222222222"
  else
    echo "11111111-1111-4111-8111-111111111111"
  fi
  exit 0
fi
if [[ "$all_arguments" == *"sudo systemctl reboot"* ]]; then
  [[ -f "$MOCK_STATE/cloud-init-disabled" ]] \
    || touch "$MOCK_STATE/reboot-before-disable"
  touch "$MOCK_STATE/reboot-requested"
  exit 0
fi
if [[ -f "$MOCK_STATE/reboot-requested" \
    && ! -f "$MOCK_STATE/rebooted" ]]; then
  if [[ "$remote_command" == *"/proc/sys/kernel/random/boot_id"* \
      && "$remote_command" == *"!="* ]]; then
    # The first SSH probe after systemctl reboot still reaches the old boot.
    # It must not be accepted merely because SSH and the provisioning marker
    # remain available for a moment.
    touch \
      "$MOCK_STATE/old-boot-probe-observed" \
      "$MOCK_STATE/rebooted"
    exit 1
  fi
  if [[ "$remote_command" == *"/etc/cloud/cloud-init.disabled"* ]]; then
    # This is the v13 failure: the old-boot probe was accepted, then pam_nologin
    # closed the following marker-creation connection during shutdown.
    touch "$MOCK_STATE/rebooted"
    exit 1
  fi
fi
if [[ -f "$MOCK_STATE/rebooted" \
    && "$all_arguments" == *"@192.168.122.50"* ]]; then
  exit 1
fi
if [[ "$remote_command" == \
    "sudo install -o root -g root -m 0644 /dev/null /etc/cloud/cloud-init.disabled" ]]; then
  touch "$MOCK_STATE/cloud-init-disabled"
fi
if [[ "$remote_command" == \
    "sudo test -f /etc/cloud/cloud-init.disabled" ]]; then
  [[ -f "$MOCK_STATE/cloud-init-disabled" ]]
  exit
fi
if [[ "$all_arguments" == *"installed-versions.txt"* ]]; then
  cat <<'OUTPUT'
Provisioned: 2026-07-28T00:00:00+00:00
Visual Studio Code mock
Lean mock
Isabelle2025-2 mock
GHC mock
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
export MOCK_HOME="$TEMP_DIR/home"
MOCK_PATH="$TEMP_DIR/bin:$PATH"

printf 'mockpass123\nmockpass123\n' \
  | env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --name mock-agent --memory 8192 --vcpus 2 \
      --formal-methods \
      > "$TEMP_DIR/output"

grep -Fq "KVM-Agent setup completed" "$TEMP_DIR/output"
grep -Fq "codex-cli mock" "$TEMP_DIR/output"
grep -Fq "Formal tools:   Lean 4, Isabelle/HOL, GHC, Cabal, HLS, HLint" \
  "$TEMP_DIR/output"
grep -Fq "virt-manager --connect qemu:///system" "$TEMP_DIR/output"
grep -Fq "192.168.122.51" "$TEMP_DIR/output"
grep -Fq "8192 MiB RAM, 2 vCPU, 120 GiB disk" "$TEMP_DIR/output"
grep -Fq "resize $TEMP_DIR/images/vms/mock-agent.qcow2 120G" \
  "$MOCK_STATE/qemu-img-resize"
[[ -f "$MOCK_STATE/domain-defined" ]]
[[ -f "$MOCK_STATE/rebooted" ]]
[[ -f "$MOCK_STATE/old-boot-probe-observed" ]]
[[ ! -f "$MOCK_STATE/reboot-before-disable" ]]
[[ -f "$TEMP_DIR/images/vms/mock-agent.qcow2" ]]
[[ -f "$MOCK_STATE/seed-ejected" ]]
[[ -f "$MOCK_STATE/cloud-init-disabled" ]]
[[ ! -e "$TEMP_DIR/images/vms/mock-agent-seed.img" ]]
[[ -f "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/id_ed25519" ]]
grep -Fxq "formal-methods=yes" \
  "$TEMP_DIR/home/.local/share/kvm-agent/mock-agent/provisioning-mode"
grep -Fq \
  '["/usr/local/sbin/kvm-agent-provision", "agent", "yes", "192.168.122.1", "yes", "120", "none", "none"]' \
  "$MOCK_STATE/user-data"
grep -Fq "growpart:" "$MOCK_STATE/user-data"
grep -Fq "resize_rootfs: true" "$MOCK_STATE/user-data"

env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
  "$TEMP_DIR/setup-under-test.sh" \
    --finalize-existing --name mock-agent --user agent \
    > "$TEMP_DIR/finalize-output"
grep -Fq "KVM-Agent finalization completed" \
  "$TEMP_DIR/finalize-output"
grep -Fq "192.168.122.51" "$TEMP_DIR/finalize-output"

env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
  "$TEMP_DIR/setup-under-test.sh" \
    --add-swarm worker --name mock-agent --user agent \
    --swarm-network tailscale \
    > "$TEMP_DIR/add-swarm-output"
grep -Fq "Adding the 'worker' swarm role with 'tailscale' networking" \
  "$TEMP_DIR/add-swarm-output"
grep -Fq "KVM-Agent swarm setup completed" "$TEMP_DIR/add-swarm-output"

: > "$MOCK_STATE/resource-changes"
env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
  "$TEMP_DIR/setup-under-test.sh" \
    --resize-existing --name mock-agent --memory 12288 --vcpus 4 \
    > "$TEMP_DIR/resize-output"
grep -Fq "Updated persistent resources for 'mock-agent'" \
  "$TEMP_DIR/resize-output"
grep -Fq "setmaxmem mock-agent 12288MiB --config" \
  "$MOCK_STATE/resource-changes"
grep -Fq "setmem mock-agent 12288MiB --config" \
  "$MOCK_STATE/resource-changes"
grep -Fq "setvcpus mock-agent 4 --maximum --config" \
  "$MOCK_STATE/resource-changes"
grep -Fq "setvcpus mock-agent 4 --config" \
  "$MOCK_STATE/resource-changes"

# A libvirt managed-save image can restore stale running-state resources, so
# resizing must stop before making any persistent changes.
touch "$MOCK_STATE/managed-save"
: > "$MOCK_STATE/resource-changes"
if env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --resize-existing --name mock-agent --memory 16384 \
      > "$TEMP_DIR/resize-managed-save-output" 2>&1; then
  echo "Resize unexpectedly accepted a managed-save image." >&2
  exit 1
fi
grep -Fq "has a managed-save image" "$TEMP_DIR/resize-managed-save-output"
[[ ! -s "$MOCK_STATE/resource-changes" ]]
rm -f -- "$MOCK_STATE/managed-save"

# Operation modes and initial-provisioning swarm roles must not silently
# override each other based on option order.
if env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --resize-existing --finalize-existing --name mock-agent --memory 8192 \
      > "$TEMP_DIR/conflicting-operation-output" 2>&1; then
  echo "Setup unexpectedly accepted conflicting operation modes." >&2
  exit 1
fi
grep -Fq "cannot be combined with another operation mode" \
  "$TEMP_DIR/conflicting-operation-output"

if env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --swarm-role manager --add-swarm worker --name mock-agent \
      > "$TEMP_DIR/conflicting-swarm-output" 2>&1; then
  echo "Setup unexpectedly accepted --swarm-role with --add-swarm." >&2
  exit 1
fi
grep -Fq "cannot be combined" "$TEMP_DIR/conflicting-swarm-output"

# A connected SSH session whose remote command never returns must still be
# bounded. This reproduces the v8 cloud-init status --wait hang without making
# the regression suite itself wait indefinitely.
cp "$TEMP_DIR/setup-under-test.sh" "$TEMP_DIR/setup-hang-under-test.sh"
sed -i \
  -e 's/readonly SSH_COMMAND_TIMEOUT_SECONDS=20/readonly SSH_COMMAND_TIMEOUT_SECONDS=1/' \
  -e 's/local provisioning_attempts=1080/local provisioning_attempts=1/' \
  -e 's/provisioning_attempts=4320/provisioning_attempts=1/' \
  "$TEMP_DIR/setup-hang-under-test.sh"
touch \
  "$MOCK_STATE/ssh-hang" \
  "$TEMP_DIR/images/vms/mock-agent-seed.img"
if timeout 8s env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-hang-under-test.sh" \
      --finalize-existing --name mock-agent --user agent \
      > "$TEMP_DIR/finalize-hang-output" 2>&1; then
  echo "Finalization unexpectedly accepted a blocked SSH probe." >&2
  exit 1
fi
grep -Fq "stopped without changing cloud-init" \
  "$TEMP_DIR/finalize-hang-output"
[[ -f "$TEMP_DIR/images/vms/mock-agent-seed.img" ]]
rm -f -- "$MOCK_STATE/ssh-hang"

# If successful provisioning cannot be verified, recovery must not disable
# cloud-init or detach/delete the seed. Shorten the retry loop in this mock.
rm -f -- \
  "$MOCK_STATE/cloud-init-disabled" \
  "$MOCK_STATE/seed-ejected"
touch \
  "$MOCK_STATE/provisioning-failed" \
  "$TEMP_DIR/images/vms/mock-agent-seed.img"
sed -i \
  -e 's/local provisioning_attempts=1080/local provisioning_attempts=1/' \
  -e 's/provisioning_attempts=4320/provisioning_attempts=1/' \
  "$TEMP_DIR/setup-under-test.sh"
if env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
    "$TEMP_DIR/setup-under-test.sh" \
      --finalize-existing --name mock-agent --user agent \
      > "$TEMP_DIR/finalize-failure-output" 2>&1; then
  echo "Finalization unexpectedly accepted an unverified guest." >&2
  exit 1
fi
grep -Fq "stopped without changing cloud-init" \
  "$TEMP_DIR/finalize-failure-output"
[[ ! -f "$MOCK_STATE/cloud-init-disabled" ]]
[[ ! -f "$MOCK_STATE/seed-ejected" ]]
[[ -f "$TEMP_DIR/images/vms/mock-agent-seed.img" ]]
rm -f -- "$MOCK_STATE/provisioning-failed"

printf 'mockpass123\nmockpass123\nmock-agent\n' \
  | env PATH="$MOCK_PATH" MOCK_STATE="$MOCK_STATE" \
      "$TEMP_DIR/setup-under-test.sh" \
        --replace-existing --name mock-agent \
        --memory 8192 --vcpus 2 --disk 80 \
        > "$TEMP_DIR/replace-output"
grep -Fxq -- "--name mock-agent --force" \
  "$MOCK_STATE/remove-arguments"
grep -Fq "KVM-Agent setup completed" "$TEMP_DIR/replace-output"

echo "Mocked setup workflow passed."
