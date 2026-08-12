#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin"

awk '
  {
    line = $0
    gsub(/\047/, "", line)
  }
  index(line, "<<TAILSCALE_UP") {
    capture = 1
    next
  }
  capture && $0 == "TAILSCALE_UP" {
    exit
  }
  capture
' "$REPO_DIR/setup-kvm-agent.sh" > "$TEMP_DIR/tailscale-up"
[[ -s "$TEMP_DIR/tailscale-up" ]]
sed -i \
  "s#marker=/var/lib/kvm-agent/swarm-profile#marker='$TEMP_DIR/swarm-profile'#" \
  "$TEMP_DIR/tailscale-up"
chmod 0755 "$TEMP_DIR/tailscale-up"
printf 'roles=manager\n' > "$TEMP_DIR/swarm-profile"

cat > "$TEMP_DIR/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat > "$TEMP_DIR/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  up)
    printf '%s\n' "$@" > "$MOCK_TAILSCALE_UP_ARGUMENTS"
    ;;
  status)
    if [[ "${2:-}" == --json ]]; then
      if [[ "${MOCK_NO_TAG:-no}" == yes ]]; then
        printf '{"Self":{"Tags":[]}}\n'
      else
        printf '{"Self":{"Tags":["tag:swarm-research-a-manager"]}}\n'
      fi
    else
      printf 'mock peer status\n'
    fi
    ;;
  ip)
    [[ "${2:-}" == -4 ]]
    printf '100.64.0.20\n'
    ;;
  *)
    printf 'Unexpected tailscale command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$TEMP_DIR/bin/"*

export MOCK_TAILSCALE_UP_ARGUMENTS="$TEMP_DIR/tailscale-up.arguments"
MOCK_PATH="$TEMP_DIR/bin:$PATH"
PATH="$MOCK_PATH" "$TEMP_DIR/tailscale-up" --help >/dev/null 2>&1
PATH="$MOCK_PATH" "$TEMP_DIR/tailscale-up" --group research-a \
  > "$TEMP_DIR/output"
for expected in \
    '--reset' \
    '--hostname=research-a-manager' \
    '--advertise-tags=tag:swarm-research-a-manager' \
    '--accept-routes=false' \
    '--exit-node=' \
    '--ssh=false'; do
  grep -Fxq -- "$expected" "$MOCK_TAILSCALE_UP_ARGUMENTS"
done
grep -Fq -- 'Verified device tag:' "$TEMP_DIR/output"

if PATH="$MOCK_PATH" MOCK_NO_TAG=yes \
    "$TEMP_DIR/tailscale-up" --group research-a \
    > "$TEMP_DIR/no-tag-output" 2>&1; then
  echo 'Tailscale helper accepted a missing requested tag.' >&2
  exit 1
fi
grep -Fq -- 'requested tag is absent' "$TEMP_DIR/no-tag-output"

if PATH="$MOCK_PATH" "$TEMP_DIR/tailscale-up" \
    --group research-a --tag tag:swarm-research-b-manager \
    >/dev/null 2>&1; then
  echo 'Tailscale helper accepted an explicit tag with --group.' >&2
  exit 1
fi

echo 'Mock Tailscale join checks passed.'
