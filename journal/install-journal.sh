#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

guest_user="${1:?guest user is required}"
backend="${2:?reporter backend is required}"
timezone="${3:?timezone is required}"
projects_b64="${4:-W10=}" # []
remote_reporting="${5:-no}"
runtime_source="${6:-/usr/local/lib/kvm-agent-journal/kvm_agent_journal.py}"

[[ $EUID -eq 0 ]] || { echo "Journal installer must run as root." >&2; exit 1; }
case "$backend" in
  claude|codex|evidence) ;;
  *) echo "Invalid journal backend: $backend" >&2; exit 2 ;;
esac
[[ "$remote_reporting" == yes || "$remote_reporting" == no ]] || {
  echo "Invalid remote-reporting consent value: $remote_reporting" >&2
  exit 2
}
if [[ "$backend" != evidence && "$remote_reporting" != yes ]]; then
  echo "A remote journal backend requires explicit host-side consent." >&2
  exit 2
fi
if [[ "$backend" == evidence && "$remote_reporting" != no ]]; then
  echo "Remote-reporting consent is inconsistent with the evidence backend." >&2
  exit 2
fi
[[ "$timezone" =~ ^[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || {
  echo "Invalid journal timezone: $timezone" >&2
  exit 2
}
[[ -f "/usr/share/zoneinfo/$timezone" ]] || {
  echo "Unknown journal timezone: $timezone" >&2
  exit 2
}

guest_home="$(getent passwd "$guest_user" | awk -F: '{print $6}')"
guest_group="$(id -gn "$guest_user")"
[[ -n "$guest_home" && -d "$guest_home" ]] || {
  echo "Cannot resolve guest home for $guest_user." >&2
  exit 1
}
[[ -r "$runtime_source" ]] || {
  echo "Journal runtime is missing: $runtime_source" >&2
  exit 1
}

exec > >(tee -a /var/log/kvm-agent-journal-install.log) 2>&1
echo "Configuring KVM-Agent research journal: backend=$backend timezone=$timezone remote_reporting=$remote_reporting"

install -d -o root -g root -m 0755 /usr/local/lib/kvm-agent-journal
chown root:root "$runtime_source"
chmod 0755 "$runtime_source"
ln -sfn "$runtime_source" /usr/local/bin/kvm-agent-journal

cat > /etc/kvm-agent-journal.conf <<CONFIG
# Managed by setup-kvm-agent.sh --add-journal.
BACKEND=$backend
TIMEZONE=$timezone
REMOTE_REPORTING=$remote_reporting
CONFIG
chown root:root /etc/kvm-agent-journal.conf
chmod 0644 /etc/kvm-agent-journal.conf

guest_path="${guest_home}/.local/bin:${guest_home}/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
network_hardening='RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6'
if [[ "$backend" == evidence ]]; then
  network_hardening=$'PrivateNetwork=true\nRestrictAddressFamilies=AF_UNIX\nIPAddressDeny=any'
fi
for period in daily weekly monthly; do
  cat > "/etc/systemd/system/kvm-agent-journal-${period}.service" <<SERVICE
[Unit]
Description=KVM-Agent ${period} research-journal report
After=network-online.target

[Service]
Type=oneshot
User=${guest_user}
Group=${guest_group}
WorkingDirectory=${guest_home}
Environment=HOME=${guest_home}
Environment=PATH=${guest_path}
ExecStart=/usr/local/bin/kvm-agent-journal report ${period} --all
TimeoutStartSec=3h
Nice=10
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${guest_home}
LockPersonality=true
RestrictSUIDSGID=true
RestrictNamespaces=true
PrivateDevices=true
ProtectClock=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProcSubset=pid
SystemCallArchitectures=native
SystemCallFilter=@system-service
${network_hardening}
SERVICE
done

cat > /etc/systemd/system/kvm-agent-journal-daily.timer <<TIMER
[Unit]
Description=Generate the preceding complete daily research report

[Timer]
OnCalendar=*-*-* 07:00:00 $timezone
Persistent=true
Unit=kvm-agent-journal-daily.service

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/kvm-agent-journal-weekly.timer <<TIMER
[Unit]
Description=Generate the preceding complete Saturday-Friday research report

[Timer]
OnCalendar=Sat *-*-* 07:10:00 $timezone
Persistent=true
Unit=kvm-agent-journal-weekly.service

[Install]
WantedBy=timers.target
TIMER

cat > /etc/systemd/system/kvm-agent-journal-monthly.timer <<TIMER
[Unit]
Description=Generate the preceding complete monthly research report

[Timer]
OnCalendar=*-*-01 07:20:00 $timezone
Persistent=true
Unit=kvm-agent-journal-monthly.service

[Install]
WantedBy=timers.target
TIMER

chmod 0644 /etc/systemd/system/kvm-agent-journal-*.service \
  /etc/systemd/system/kvm-agent-journal-*.timer

projects_json="$(printf '%s' "$projects_b64" | base64 -d)" || {
  echo "Could not decode the journal project list." >&2
  exit 2
}
project_list_file="$(mktemp)"
trap 'rm -f -- "$project_list_file"' EXIT
if ! python3 -c '
import json, sys
value = json.load(sys.stdin)
if not isinstance(value, list) or not all(
    isinstance(item, str)
    and item.startswith("/")
    and "\n" not in item
    and "\r" not in item
    and "\0" not in item
    for item in value
):
    raise SystemExit(2)
for item in value:
    print(item)
' <<< "$projects_json" > "$project_list_file"; then
  echo "The journal project list is not an array of absolute, single-line paths." >&2
  exit 2
fi
mapfile -t project_paths < "$project_list_file"
rm -f -- "$project_list_file"
trap - EXIT

registry=/etc/kvm-agent-journal-projects.json
if [[ ! -e "$registry" ]]; then
  printf '{"projects": []}\n' > "$registry"
fi
chown root:root "$registry"
chmod 0644 "$registry"

for project in "${project_paths[@]}"; do
  runuser -u "$guest_user" -- env \
    HOME="$guest_home" USER="$guest_user" LOGNAME="$guest_user" \
    PATH="$guest_path" \
    /usr/local/bin/kvm-agent-journal init "$project"
  /usr/local/bin/kvm-agent-journal register "$project"
done

systemctl daemon-reload
systemctl enable --now \
  kvm-agent-journal-daily.timer \
  kvm-agent-journal-weekly.timer \
  kvm-agent-journal-monthly.timer

install -d -o root -g root -m 0755 /var/lib/kvm-agent
{
  printf 'backend=%s\n' "$backend"
  printf 'timezone=%s\n' "$timezone"
  printf 'remote_reporting=%s\n' "$remote_reporting"
  printf 'configured=%s\n' "$(date --utc --iso-8601=seconds)"
} > /var/lib/kvm-agent/journal-profile
chmod 0644 /var/lib/kvm-agent/journal-profile

echo "KVM-Agent research journal configured."
runuser -u "$guest_user" -- env HOME="$guest_home" PATH="$guest_path" \
  /usr/local/bin/kvm-agent-journal status
systemctl list-timers --all 'kvm-agent-journal-*' --no-pager
