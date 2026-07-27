VM_NAME=kvm-agent
GUEST_USER=agent

VM_IP="$(
  LC_ALL=C sudo virsh --connect qemu:///system \
    domifaddr "$VM_NAME" --source lease |
  awk '$3 == "ipv4" {split($4,a,"/"); print a[1]; exit}'
)"

KEY="$HOME/.local/share/kvm-agent/$VM_NAME/id_ed25519"
KNOWN_HOSTS="$HOME/.local/share/kvm-agent/$VM_NAME/known_hosts"
OUT="kvm-agent-diagnostics-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT"

SSH_OPTIONS=(
  -o IdentitiesOnly=yes
  -o ForwardAgent=no
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -i "$KEY"
)

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'sudo cat /var/log/kvm-agent-provision.log' \
  > "$OUT/kvm-agent-provision.log"

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'sudo cloud-init status --long' \
  > "$OUT/cloud-init-status.txt" 2>&1

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'sudo cat /var/log/cloud-init-output.log' \
  > "$OUT/cloud-init-output.log" 2>&1

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'sudo cat /var/log/cloud-init.log' \
  > "$OUT/cloud-init.log" 2>&1

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'sudo journalctl \
     -u cloud-final.service \
     -u cloud-config.service \
     -u cloud-init.service \
     -u cloud-init-local.service \
     --no-pager' \
  > "$OUT/cloud-init-journal.txt" 2>&1

ssh "${SSH_OPTIONS[@]}" "$GUEST_USER@$VM_IP" \
  'printf "%s\n" "=== OS ==="; cat /etc/os-release
   printf "%s\n" "=== Relevant paths ==="
   sudo stat /home/agent /home/agent/.local /home/agent/.local/share \
     /home/agent/local /home/agent/local/share 2>&1 || true' \
  > "$OUT/environment.txt" 2>&1

tar -czf "$OUT.tar.gz" "$OUT"

printf 'Created: %s.tar.gz\n' "$OUT"
