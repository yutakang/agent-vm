#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Extract the guest-side cloud-init cleanup from setup-kvm-agent.sh and run it
# against fake guest trees. The cached user-data that this removes carries the
# guest password hash, and the command runs on the path every VM takes, so its
# verification logic is exercised directly rather than mocked at the SSH layer.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

awk '
  /<<.REMOTE_CLOUD_INIT_CLEAN./ { capture = 1; next }
  capture && /^REMOTE_CLOUD_INIT_CLEAN$/ { capture = 0; next }
  capture { print }
' "${REPO_DIR}/setup-kvm-agent.sh" > "$TEMP_DIR/remote-clean.sh"
[[ -s "$TEMP_DIR/remote-clean.sh" ]] \
  || fail 'could not extract the guest cloud-init cleanup command'
grep -Fq 'cloud-init clean --logs' "$TEMP_DIR/remote-clean.sh" \
  || fail 'extracted the wrong block from setup-kvm-agent.sh'

# The guest shell is /bin/sh, which is dash on Ubuntu, not bash.
if command -v dash >/dev/null 2>&1; then REMOTE_SHELL=dash; else REMOTE_SHELL=sh; fi

mkdir -p "$TEMP_DIR/bin"
cat > "$TEMP_DIR/bin/sudo" <<'SUDO'
#!/bin/sh
if [ "${MOCK_SUDO_BROKEN:-no}" = yes ]; then
  echo 'sudo: a password is required' >&2
  exit 1
fi
command="$1"
shift
exec "$command" "$@"
SUDO
cat > "$TEMP_DIR/bin/cloud-init" <<'CLOUD_INIT'
#!/bin/sh
# "cloud-init clean" behaviour varies by release; the caller must not depend on
# it, so this mock can succeed or fail.
[ "${MOCK_CLEAN_STATUS:-0}" = 0 ] || exit "${MOCK_CLEAN_STATUS}"
rm -rf "$MOCK_ROOT/var/lib/cloud/instance" "$MOCK_ROOT/var/lib/cloud/instances"
CLOUD_INIT
chmod 0755 "$TEMP_DIR/bin/sudo" "$TEMP_DIR/bin/cloud-init"

# Point the extracted script at a fake guest filesystem.
export MOCK_ROOT="$TEMP_DIR/guest"
sed -i \
  -e "s#/var/lib/cloud#${MOCK_ROOT}/var/lib/cloud#g" \
  -e "s#/var/log/cloud-init#${MOCK_ROOT}/var/log/cloud-init#g" \
  "$TEMP_DIR/remote-clean.sh"
grep -Fq "${MOCK_ROOT}/var/lib/cloud" "$TEMP_DIR/remote-clean.sh" \
  || fail 'the extracted cleanup was not redirected away from real guest paths'

reset_guest() {
  rm -rf -- "$MOCK_ROOT"
  mkdir -p "$MOCK_ROOT/var/lib/cloud/instance" "$MOCK_ROOT/var/log"
  printf "hashed_passwd: '\$6\$salt\$hash'\n" \
    > "$MOCK_ROOT/var/lib/cloud/instance/cloud-config.txt"
  printf "hashed_passwd: '\$6\$salt\$hash'\n" \
    > "$MOCK_ROOT/var/lib/cloud/instance/user-data.txt"
  printf 'cloud-init running\n' > "$MOCK_ROOT/var/log/cloud-init.log"
}

run_clean() {
  env PATH="$TEMP_DIR/bin:$PATH" MOCK_ROOT="$MOCK_ROOT" "$@" \
    "$REMOTE_SHELL" "$TEMP_DIR/remote-clean.sh" >"$TEMP_DIR/out" 2>&1
}

# 1. Normal case: the cached hash is gone and the command reports success.
reset_guest
run_clean || fail "a clean guest was rejected: $(cat "$TEMP_DIR/out")"
if grep -rqsF '$6$' "$MOCK_ROOT"; then
  fail 'the password hash survived a cleanup that reported success'
fi

# 2. "cloud-init clean" itself failing must not matter: the script removes the
#    instance cache directly and verifies the outcome.
reset_guest
run_clean MOCK_CLEAN_STATUS=1 \
  || fail "a failing cloud-init clean was treated as fatal: $(cat "$TEMP_DIR/out")"
if grep -rqsF '$6$' "$MOCK_ROOT"; then
  fail 'the password hash survived when cloud-init clean failed'
fi

# 3. An artifact that neither the clean nor the explicit removal covers must be
#    detected rather than silently accepted.
reset_guest
mkdir -p "$MOCK_ROOT/var/lib/cloud/seed/nocloud"
printf "hashed_passwd: '\$6\$salt\$hash'\n" \
  > "$MOCK_ROOT/var/lib/cloud/seed/nocloud/user-data"
if run_clean; then
  fail 'a surviving cached user-data artifact was accepted'
fi
grep -Fq 'Cached cloud-init artifact remains' "$TEMP_DIR/out" \
  || fail 'the surviving artifact was not named in the error'

# 4. A leftover hash under a name the artifact search does not match must still
#    be caught by the content scan.
reset_guest
mkdir -p "$MOCK_ROOT/var/lib/cloud/data"
printf "password: \$6\$salt\$hash\n" > "$MOCK_ROOT/var/lib/cloud/data/leftover"
if run_clean; then
  fail 'a surviving SHA-512 password hash was accepted'
fi
grep -Fq 'password hash remains' "$TEMP_DIR/out" \
  || fail 'the surviving hash was not reported'

# 5. Fail closed, not open: if the verification cannot run at all, "nothing
#    found" must never be read as "nothing left".
reset_guest
if run_clean MOCK_SUDO_BROKEN=yes; then
  fail 'an unusable sudo was reported as a successful cleanup'
fi

reset_guest
cat > "$TEMP_DIR/bin/find" <<'BROKEN_FIND'
#!/bin/sh
exit 0
BROKEN_FIND
chmod 0755 "$TEMP_DIR/bin/find"
if run_clean; then
  fail 'a search that finds nothing at all was reported as a clean guest'
fi
grep -Fq 'cleanup is unverifiable' "$TEMP_DIR/out" \
  || fail 'an unusable search was not reported as unverifiable'
rm -f -- "$TEMP_DIR/bin/find"

reset_guest
cat > "$TEMP_DIR/bin/grep" <<'BROKEN_GREP'
#!/bin/sh
exit 1
BROKEN_GREP
chmod 0755 "$TEMP_DIR/bin/grep"
if run_clean; then
  fail 'a scan that matches nothing at all was reported as a clean guest'
fi
rm -f -- "$TEMP_DIR/bin/grep"

# 6. The probe used to prove the detectors work must not be left behind.
reset_guest
run_clean || fail 'clean guest rejected on the probe-residue check'
if [[ -e "$MOCK_ROOT/var/lib/cloud/.kvm-agent-clean-probe" ]]; then
  fail 'the verification probe was left inside the guest'
fi

echo 'Mocked cloud-init cleanup checks passed.'
