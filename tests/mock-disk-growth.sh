#!/usr/bin/env bash
set -euo pipefail
umask 077

# Exercise the embedded guest-side capacity invariant without touching a real
# block device. The first case starts with a 4 GiB root filesystem and observes
# a successful expansion; the second proves that a non-expanding resize is
# rejected before provisioning can continue.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/dev"
touch "$TEMP_DIR/dev/vda1"

awk '
  /^root_filesystem_bytes\(\) \{/ {
    capture = 1
  }
  /^# Cloud-init normally grows Ubuntu cloud images before runcmd\./ {
    capture = 0
  }
  capture
' "$REPO_DIR/setup-kvm-agent.sh" > "$TEMP_DIR/disk-functions.sh"
[[ -s "$TEMP_DIR/disk-functions.sh" ]]
# The production check requires a block device. This isolated regression uses
# a regular placeholder and changes only its temporary extracted copy.
sed -i 's/\[\[ -b "\$root_device" \]\]/[[ -e "$root_device" ]]/' \
  "$TEMP_DIR/disk-functions.sh"

cat > "$TEMP_DIR/bin/df" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--output=size*)
    printf '1B-blocks\n%s\n' "$(cat "$MOCK_STATE/root-bytes")"
    ;;
  *--output=avail*)
    printf 'Avail\n%s\n' "$((30 * 1024 * 1024 * 1024))"
    ;;
  *)
    printf 'Filesystem Size Used Avail Use%% Mounted on\n'
    printf '/dev/vda1 120G 5G 115G 5%% /\n'
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *SOURCE*) echo /dev/root ;;
  *FSTYPE*) echo ext4 ;;
  *) exit 1 ;;
esac
EOF

cat > "$TEMP_DIR/bin/readlink" <<'EOF'
#!/usr/bin/env bash
echo "$MOCK_DEVICE"
EOF

cat > "$TEMP_DIR/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *PKNAME*) echo vda ;;
  *PARTN*) echo 1 ;;
  *)
    cat <<'OUTPUT'
NAME   SIZE TYPE FSTYPE MOUNTPOINTS
vda    120G disk
└─vda1 120G part ext4   /
OUTPUT
    ;;
esac
EOF

cat > "$TEMP_DIR/bin/growpart" <<'EOF'
#!/usr/bin/env bash
echo "CHANGED: partition=1 start=2048 old: size=8386560 end=8388608 new: size=251656159 end=251658207"
EOF

cat > "$TEMP_DIR/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TEMP_DIR/bin/resize2fs" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_NO_GROW:-no}" != "yes" ]]; then
  printf '%s\n' "$((115 * 1024 * 1024 * 1024))" \
    > "$MOCK_STATE/root-bytes"
fi
EOF

chmod 0755 "$TEMP_DIR/bin/"*
printf '%s\n' "$((4 * 1024 * 1024 * 1024))" \
  > "$TEMP_DIR/root-bytes"

cat > "$TEMP_DIR/run-success.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
$(cat "$TEMP_DIR/disk-functions.sh")
requested_disk_gib=120
ensure_requested_root_capacity
require_root_free_gib 25
EOF
chmod 0755 "$TEMP_DIR/run-success.sh"

env \
  PATH="$TEMP_DIR/bin:$PATH" \
  MOCK_STATE="$TEMP_DIR" \
  MOCK_DEVICE="$TEMP_DIR/dev/vda1" \
  "$TEMP_DIR/run-success.sh" > "$TEMP_DIR/success-output"
grep -Fq "Verified root filesystem capacity: 115 GiB usable." \
  "$TEMP_DIR/success-output"

printf '%s\n' "$((4 * 1024 * 1024 * 1024))" \
  > "$TEMP_DIR/root-bytes"
if env \
    PATH="$TEMP_DIR/bin:$PATH" \
    MOCK_STATE="$TEMP_DIR" \
    MOCK_DEVICE="$TEMP_DIR/dev/vda1" \
    MOCK_NO_GROW=yes \
    "$TEMP_DIR/run-success.sh" > "$TEMP_DIR/failure-output" 2>&1; then
  echo "Capacity verification accepted a filesystem that did not grow." >&2
  exit 1
fi
grep -Fq "Refusing large package installation" "$TEMP_DIR/failure-output"

echo "Mocked guest disk-growth checks passed."
