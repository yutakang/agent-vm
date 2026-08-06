#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/setup-kvm-agent.sh"
REMOVE_SCRIPT="${REPO_DIR}/remove-kvm-agent.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$SETUP_SCRIPT"
"$SETUP_SCRIPT" --help >/dev/null
[[ -x "$SETUP_SCRIPT" ]] || fail "setup-kvm-agent.sh is not executable"
bash -n "$REMOVE_SCRIPT"
"$REMOVE_SCRIPT" --help >/dev/null
[[ -x "$REMOVE_SCRIPT" ]] || fail "remove-kvm-agent.sh is not executable"
[[ -x "${SCRIPT_DIR}/mock-swarm-job.sh" ]] || fail \
  "mock-swarm-job.sh is not executable"
[[ -x "${SCRIPT_DIR}/mock-journal.sh" ]] || fail \
  "mock-journal.sh is not executable"
[[ -x "${SCRIPT_DIR}/mock-cloud-init-clean.sh" ]] || fail \
  "mock-cloud-init-clean.sh is not executable"
bash -n "${REPO_DIR}/journal/install-journal.sh"
python3 - "${REPO_DIR}/journal/kvm_agent_journal.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding='utf-8'), str(path), 'exec')
PY
if ((EUID == 0)); then
  root_output="$("$SETUP_SCRIPT" --name root-guard-test 2>&1 || true)"
  grep -Fq "not as root" <<< "$root_output" || fail \
    "setup script did not reject direct root execution"
  remove_root_output="$("$REMOVE_SCRIPT" --name root-guard-test --dry-run 2>&1 || true)"
  grep -Fq "not as root" <<< "$remove_root_output" || fail \
    "remove script did not reject direct root execution"
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

awk '
  /^cat > "\$WORK_DIR\/guest-provision.sh" <<'\''GUEST_SCRIPT'\''$/ {
    capture = 1
    next
  }
  /^GUEST_SCRIPT$/ {
    capture = 0
  }
  capture
' "$SETUP_SCRIPT" > "$TEMP_DIR/guest-provision.sh"
[[ -s "$TEMP_DIR/guest-provision.sh" ]] || fail \
  "could not extract embedded guest provisioning script"
bash -n "$TEMP_DIR/guest-provision.sh"

awk '
  /^  cat > "\$destination" <<'\''SWARM_SCRIPT'\''$/ {
    capture = 1
    next
  }
  /^SWARM_SCRIPT$/ {
    capture = 0
  }
  capture
' "$SETUP_SCRIPT" > "$TEMP_DIR/swarm-provision.sh"
[[ -s "$TEMP_DIR/swarm-provision.sh" ]] || fail \
  "could not extract embedded swarm provisioning script"
bash -n "$TEMP_DIR/swarm-provision.sh"

for helper_marker in \
    PUBLIC_KEY_SCRIPT MANAGER_INFO MANAGER_CONFIGURE MANAGER_SSH MANAGER_RSYNC \
    MANAGER_TEST JOB_HELPER AUTHORIZE_SCRIPT WORKER_INFO TAILSCALE_UP STATUS_SCRIPT; do
  awk -v marker="$helper_marker" '
    {
      line = $0
      gsub(/\047/, "", line)
    }
    index(line, "<<" marker) {
      capture = 1
      next
    }
    capture && $0 == marker {
      exit
    }
    capture
  ' "$TEMP_DIR/swarm-provision.sh" > "$TEMP_DIR/${helper_marker}.sh"
  [[ -s "$TEMP_DIR/${helper_marker}.sh" ]] || fail \
    "could not extract embedded swarm helper: $helper_marker"
  bash -n "$TEMP_DIR/${helper_marker}.sh" || fail \
    "embedded swarm helper has invalid shell syntax: $helper_marker"

  case "$helper_marker" in
    PUBLIC_KEY_SCRIPT|MANAGER_INFO|MANAGER_CONFIGURE|MANAGER_SSH|MANAGER_RSYNC)
      rendered="$TEMP_DIR/${helper_marker}.rendered.sh"
      renderer="$TEMP_DIR/${helper_marker}.renderer.sh"
      {
        printf 'manager_key=%q\n' "$TEMP_DIR/id_ed25519_kvm_agent_swarm"
        printf 'manager_known_hosts=%q\n' "$TEMP_DIR/known_hosts_kvm_agent_swarm"
        printf 'guest_home=%q\n' "$TEMP_DIR/guest-home"
        printf 'guest_user=%q\n' 'agent'
        printf 'cat > %q <<%s\n' "$rendered" "$helper_marker"
        cat "$TEMP_DIR/${helper_marker}.sh"
        printf '%s\n' "$helper_marker"
      } > "$renderer"
      bash "$renderer"
      bash -n "$rendered" || fail \
        "rendered swarm helper has invalid shell syntax: $helper_marker"
      ;;
  esac
done

# The rsync convenience wrapper must pin both its SSH config and remote alias;
# otherwise a caller can silently fall through to unrelated SSH defaults.
mkdir -p "$TEMP_DIR/guest-home/.ssh" "$TEMP_DIR/mock-bin"
touch "$TEMP_DIR/guest-home/.ssh/config_kvm_agent_swarm"
cat > "$TEMP_DIR/mock-bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_RSYNC_ARGUMENTS"
EOF
chmod 0755 "$TEMP_DIR/mock-bin/rsync"
MOCK_RSYNC_ARGUMENTS="$TEMP_DIR/rsync-arguments" \
  PATH="$TEMP_DIR/mock-bin:$PATH" \
  bash "$TEMP_DIR/MANAGER_RSYNC.rendered.sh" -a ./input/ kvm-agent-worker:/tmp/output/
grep -Fq -- 'kvm-agent-worker:/tmp/output/' "$TEMP_DIR/rsync-arguments" \
  || fail "swarm rsync wrapper did not pass its pinned worker operand"
if MOCK_RSYNC_ARGUMENTS="$TEMP_DIR/rsync-arguments" \
    PATH="$TEMP_DIR/mock-bin:$PATH" \
    bash "$TEMP_DIR/MANAGER_RSYNC.rendered.sh" -a ./input/ other-host:/tmp/output/ \
      >/dev/null 2>&1; then
  fail "swarm rsync wrapper accepted an unpinned remote host"
fi
if MOCK_RSYNC_ARGUMENTS="$TEMP_DIR/rsync-arguments" \
    PATH="$TEMP_DIR/mock-bin:$PATH" \
    bash "$TEMP_DIR/MANAGER_RSYNC.rendered.sh" -e 'ssh -F /tmp/other' \
      ./input/ kvm-agent-worker:/tmp/output/ >/dev/null 2>&1; then
  fail "swarm rsync wrapper accepted an SSH transport override"
fi

awk '
  /^install -d -o "\$guest_user" -g "\$guest_group"/ {
    capture = 1
  }
  capture {
    print
  }
  capture && /\$guest_home\/\.local\/share\/kvm-agent/ {
    exit
  }
' "$TEMP_DIR/guest-provision.sh" > "$TEMP_DIR/guest-owned-directories"
[[ -s "$TEMP_DIR/guest-owned-directories" ]] || fail \
  "could not extract guest-owned directory creation"

# Regression check for the real Claude Code EACCES failure: GNU install creates
# omitted parents as root, so every XDG parent must be an explicit owned target.
for guest_directory in \
    '"$guest_home/.local"' \
    '"$guest_home/.local/bin"' \
    '"$guest_home/.local/share"' \
    '"$guest_home/.local/state"' \
    '"$guest_home/.config"' \
    '"$guest_home/.cache"' \
    '"$guest_home/.local/share/kvm-agent"'; do
  grep -Fq -- "$guest_directory" "$TEMP_DIR/guest-owned-directories" \
    || fail "guest provisioning omits owned directory: $guest_directory"
done

for guest_environment in \
    'XDG_CONFIG_HOME="$guest_home/.config"' \
    'XDG_DATA_HOME="$guest_home/.local/share"' \
    'XDG_STATE_HOME="$guest_home/.local/state"' \
    'XDG_CACHE_HOME="$guest_home/.cache"'; do
  grep -Fq -- "$guest_environment" "$TEMP_DIR/guest-provision.sh" \
    || fail "guest provisioning omits environment: $guest_environment"
done

for required in \
    README.md README_jp.md \
    SECURITY.md SECURITY_jp.md \
    DISCLAIMER.md DISCLAIMER_jp.md \
    docs/design.md docs/design_jp.md \
    docs/daily-use.md docs/daily-use_jp.md \
    docs/credentials.md docs/credentials_jp.md \
    docs/agent-tools-and-model-services.md \
    docs/agent-tools-and-model-services_jp.md \
    docs/formal-methods.md docs/formal-methods_jp.md \
    docs/swarm.md docs/swarm_jp.md \
    docs/journal.md docs/journal_jp.md \
    docs/troubleshooting.md docs/troubleshooting_jp.md \
    docs/references.md docs/references_jp.md; do
  [[ -s "${REPO_DIR}/${required}" ]] || fail "missing or empty: $required"
done

for required_text in \
    "readonly DEFAULT_DISK_GB=120" \
    "readonly SWARM_PROVISION_TIMEOUT_SECONDS=1800" \
    "https://chatgpt.com/codex/install.sh" \
    "https://claude.ai/install.sh" \
    "https://opencode.ai/install" \
    "aider-chat@latest" \
    "https://ollama.com/install.sh" \
    "https://elan.lean-lang.org/elan-init.sh" \
    "https://www.cl.cam.ac.uk/research/hvg/Isabelle/dist/" \
    "https://get-ghcup.haskell.org" \
    "https://update.code.visualstudio.com/latest/linux-deb-x64/stable" \
    "leanprover.lean4" \
    "haskell.haskell" \
    "haskell-language-server-wrapper" \
    "hlint" \
    "--formal-methods" \
    "formal-methods=yes" \
    "--swarm-role" \
    "--add-swarm" \
    "--add-journal" \
    "--journal-project" \
    "--journal-allow-remote-reporting" \
    "readonly JOURNAL_PROVISION_TIMEOUT_SECONDS=1200" \
    "--resize-existing" \
    "id_ed25519_kvm_agent_swarm" \
    "agent-worker" \
    "https://tailscale.com/install.sh" \
    "wireguard-tools" \
    "HOST_RAM_MB * 3 / 4" \
    "HOST_CPUS * 3 / 4" \
    "OLLAMA_HOST=127.0.0.1:11434" \
    "ubuntu-desktop-minimal" \
    "graphics \"spice,listen=none\"" \
    "ForwardAgent=no" \
    "ufw default deny incoming" \
    "ufw --force enable" \
    "/etc/cloud/cloud-init.disabled" \
    "--finalize-existing" \
    "--replace-existing" \
    'remove-kvm-agent.sh" \' \
    "usermod -aG libvirt --"; do
  grep -Fq -- "$required_text" "$SETUP_SCRIPT" \
    || fail "setup script is missing: $required_text"
done

for required_swarm_text in \
    'ufw insert 1 allow in on tailscale0' \
    'ufw insert 1 allow in on wg0' \
    'entry="restrict ${key_line}"' \
    'passwd --lock "$worker_user"' \
    'authorized_keys="/etc/ssh/authorized_keys/${worker_user}"' \
    'known_hosts_kvm_agent_swarm' \
    'case "${1:-}" in' \
    '--clear)' \
    'DisableForwarding yes' \
    'PermitTTY no' \
    'systemctl enable --now tailscaled.service' \
    'DPkg::Lock::Timeout=600' \
    'kvm-agent-swarm-tailscale-up' \
    'kvm-agent-swarm-configure-worker' \
    'StrictHostKeyChecking yes' \
    'User agent-worker' \
    'kvm-agent-swarm-job submit' \
    'SSH ED25519 host-key fingerprint:'; do
  grep -Fq -- "$required_swarm_text" "$TEMP_DIR/swarm-provision.sh" \
    || fail "swarm provisioning is missing: $required_swarm_text"
done

grep -Fq -- 'guest_ssh_to "$GUEST_IP" "$SWARM_PROVISION_TIMEOUT_SECONDS"' "$SETUP_SCRIPT" \
  || fail "post-provisioning swarm setup still uses the short SSH probe timeout"
grep -Fq -- 'sudo tail -n 200 /var/log/kvm-agent-swarm.log' "$SETUP_SCRIPT" \
  || fail "post-provisioning swarm setup does not report its guest log on failure"

for required_journal_text in \
    'OnCalendar=*-*-* 07:00:00 $timezone' \
    'OnCalendar=Sat *-*-* 07:10:00 $timezone' \
    'OnCalendar=*-*-01 07:20:00 $timezone' \
    'Persistent=true' \
    'NoNewPrivileges=true' \
    'ProtectSystem=strict' \
    'RestrictNamespaces=true' \
    'PrivateNetwork=true' \
    '/etc/kvm-agent-journal-projects.json'; do
  grep -Fq -- "$required_journal_text" \
    "${REPO_DIR}/journal/install-journal.sh" \
    || fail "journal installer is missing: $required_journal_text"
done
for required_journal_text in \
    '"codex", "--ask-for-approval", "never", "exec", "--ephemeral"' \
    '"claude", "--safe-mode", "-p"' \
    '"--tools", "StructuredOutput"' \
    'def confinement_canary' \
    'def reporter_command' \
    'def sanitized_narrative' \
    'def resolve_initialized_project' \
    'GIT_CONFIG_GLOBAL' \
    'safe.directory=' \
    'cwd=working_directory' \
    '"trust": "untrusted_repository_evidence"' \
    'fallback"] = "evidence-only"' \
    'os.replace(temporary, path)' \
    'fcntl.flock'; do
  grep -Fq -- "$required_journal_text" \
    "${REPO_DIR}/journal/kvm_agent_journal.py" \
    || fail "journal runtime is missing: $required_journal_text"
done
if grep -Fq -- '"opencode", "run"' \
    "${REPO_DIR}/journal/kvm_agent_journal.py"; then
  fail "OpenCode remains available as an unattended journal reporter"
fi

# --json-schema output arrives through a StructuredOutput tool call, so a
# blanket tool denial silently disables reporting while still sending the
# evidence and billing for the call.
if grep -Fq -- '"--disallowedTools", "*"' \
    "${REPO_DIR}/journal/kvm_agent_journal.py"; then
  fail "a blanket tool denial also blocks the reporter's structured-output channel"
fi

# A test-only escape hatch for a privilege check outlives the test that needed
# it. The registry's file mode is the control; the root check must have no
# environment-variable bypass.
if grep -Fq 'ALLOW_UNPRIVILEGED' "${REPO_DIR}/journal/kvm_agent_journal.py"; then
  fail "journal runtime still carries a test-only privilege bypass"
fi

# Registration runs as root against directories a compromised agent controls,
# so it must not shell out to Git there.
python3 - "${REPO_DIR}/journal/kvm_agent_journal.py" <<'PY' \
  || fail "register_project resolves its target with Git"
import ast, sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
function = next(
    node for node in ast.walk(tree)
    if isinstance(node, ast.FunctionDef) and node.name == "register_project"
)
called = {
    node.func.id for node in ast.walk(function)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
}
raise SystemExit(0 if "resolve_project" not in called else 1)
PY

# The canary must exercise the same argv as the reporting run, or it proves
# nothing about the invocation that actually sees repository text.
python3 - "${REPO_DIR}/journal/kvm_agent_journal.py" <<'PY' \
  || fail "the confinement canary does not share reporter_command with run_reporter"
import ast, sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
functions = {
    node.name: node for node in ast.walk(tree)
    if isinstance(node, ast.FunctionDef)
}
for name in ("confinement_canary", "run_reporter"):
    called = {
        node.func.id for node in ast.walk(functions[name])
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    }
    if "reporter_command" not in called:
        raise SystemExit(1)
raise SystemExit(0)
PY

# Finalization must verify the outcome of the cloud-init cleanup rather than
# trusting the exit status of a command whose behaviour varies by release.
for required_cleanup_text in \
    'sudo rm -rf -- /var/lib/cloud/instance /var/lib/cloud/instances' \
    'cleanup is unverifiable' \
    "A SHA-512 password hash remains in guest cloud-init state." \
    'cloud-init is disabled and the seed was retained.'; do
  grep -Fq -- "$required_cleanup_text" "$SETUP_SCRIPT" \
    || fail "setup script is missing cloud-init cleanup check: $required_cleanup_text"
done
# The guest shell is dash. "set -eu" is the backstop for failures the explicit
# positive controls do not anticipate. A multi-line -F pattern is an
# alternation, not a literal newline, so check the following line directly.
awk "
  /<<.REMOTE_CLOUD_INIT_CLEAN./ { expect = 1; next }
  expect { found = (\$0 == \"set -eu\"); exit }
  END { exit(found ? 0 : 1) }
" "$SETUP_SCRIPT" \
  || fail "the guest cloud-init cleanup no longer aborts on unexpected errors"

# Swarm roles are independent of libvirt VM names. Keep the primary examples
# on the repository default and prevent role-looking example names from
# reintroducing recovery-key lookup confusion.
for swarm_doc in "${REPO_DIR}/docs/swarm.md" "${REPO_DIR}/docs/swarm_jp.md"; do
  grep -Fq -- '`kvm-agent`' "$swarm_doc" \
    || fail "swarm guide does not explain the default VM name: $swarm_doc"
  grep -Fq -- 'Laptop_A' "$swarm_doc" \
    || fail "swarm guide omits the generic manager-host name: $swarm_doc"
  grep -Fq -- 'Desktop_B' "$swarm_doc" \
    || fail "swarm guide omits the generic worker-host name: $swarm_doc"
  for helper in \
      kvm-agent-swarm-tailscale-up \
      kvm-agent-swarm-worker-info \
      kvm-agent-swarm-manager-info \
      kvm-agent-swarm-configure-worker \
      kvm-agent-swarm-test \
      kvm-agent-swarm-job; do
    grep -Fq -- "$helper" "$swarm_doc" \
      || fail "swarm guide omits helper '$helper': $swarm_doc"
  done
  if grep -Eq -- '--name[[:space:]]+(agent-manager|agent-worker)' "$swarm_doc"; then
    fail "swarm guide uses a role as a VM name: $swarm_doc"
  fi
done
if rg -n -i --glob '*.md' --glob '*.sh' --glob '!check-repository.sh' '(dell|galleria)' "$REPO_DIR" >/dev/null; then
  fail "repository exposes private physical-machine names"
fi
grep -Fq -- 'The role does not change the VM name.' "$SETUP_SCRIPT" \
  || fail "setup help does not distinguish swarm role from VM name"
grep -Fq -- "Check --name: the default VM name is 'kvm-agent'" "$SETUP_SCRIPT" \
  || fail "recovery-key error does not explain the default VM name"

for required_resource_text in \
    '((RAM_MB > 32768)) && RAM_MB=32768' \
    '((VCPUS > 16)) && VCPUS=16' \
    'setmaxmem "$VM_NAME"' \
    'setvcpus "$VM_NAME" "$VCPUS"' \
    'domstate "$VM_NAME"' \
    '^Managed save:'; do
  grep -Fq -- "$required_resource_text" "$SETUP_SCRIPT" \
    || fail "resource-management support is missing: $required_resource_text"
done

for required_disk_safety in \
    "growpart:" \
    "resize_rootfs: true" \
    "ensure_requested_root_capacity" \
    "Root filesystem is smaller than 90%" \
    "emergency-space.reserve" \
    'staging_root="/var/lib/kvm-agent/install"' \
    "qemu-img info --output=json" \
    "json.load(sys.stdin)" \
    "minimum_host_free_gib=30"; do
  grep -Fq -- "$required_disk_safety" "$SETUP_SCRIPT" \
    || fail "disk-capacity protection is missing: $required_disk_safety"
done

grep -Fq \
  'isabelle_archive_sha256="a20a507bc7c1270d8be96a9f3fbec06345387789d2dc2c4d3df6260d47bfb33c"' \
  "$TEMP_DIR/guest-provision.sh" || fail \
  "guest provisioning omits the reviewed Isabelle2025-2 checksum"

for excluded_formal_tool in agda rocq opam hol4 hol-light; do
  if rg -n --glob 'setup-kvm-agent.sh' \
      "\\b${excluded_formal_tool}\\b" "$REPO_DIR" >/dev/null; then
    fail "reduced formal-methods profile still installs or documents: $excluded_formal_tool"
  fi
done

for forbidden_text in \
    "/tmp/kvm-agent-install-" \
    "/run/kvm-agent-install" \
    "usermod -aG libvirt,kvm" \
    "ufw --force disable" \
    "listen=127.0.0.1"; do
  grep -Fq -- "$forbidden_text" "$SETUP_SCRIPT" \
    && fail "setup script still contains: $forbidden_text"
done

grep -Fq 'rm -rf -- "$staging_dir"' "$TEMP_DIR/guest-provision.sh" || fail \
  "guest provisioning does not clean disk-backed staging"

for required_text in \
    "/var/lib/kvm-agent/provisioned" \
    "/var/lib/kvm-agent/provisioning-failed" \
    "/etc/cloud/cloud-init.disabled" \
    "cloud-init clean --logs" \
    "domifaddr" \
    "domblklist" \
    "--inactive --details" \
    "change-media" \
    "/proc/sys/kernel/random/boot_id" \
    "timeout --foreground" \
    "shred --remove --zero"; do
  grep -Fq -- "$required_text" "$SETUP_SCRIPT" \
    || fail "integrated finalization is missing: $required_text"
done

[[ ! -e "${REPO_DIR}/finalize-kvm-agent.sh" ]] || fail \
  "obsolete standalone finalize-kvm-agent.sh still exists"
[[ ! -e "${SCRIPT_DIR}/mock-finalize.sh" ]] || fail \
  "obsolete standalone finalization test still exists"
if grep -Fq -- "cloud-init status --wait" "$SETUP_SCRIPT"; then
  fail "setup script still contains an unbounded cloud-init wait"
fi
disable_line="$(grep -n -m1 'log "Disabling future cloud-init runs in the guest"' \
  "$SETUP_SCRIPT" | cut -d: -f1)"
reboot_line="$(grep -n -m1 'log "Rebooting once to activate guest kernel' \
  "$SETUP_SCRIPT" | cut -d: -f1)"
[[ -n "$disable_line" && -n "$reboot_line" \
    && "$disable_line" -lt "$reboot_line" ]] || fail \
  "cloud-init must be disabled and verified before an update reboot is requested"
if rg -n --glob '*.md' --glob '*.sh' --glob '!check-repository.sh' \
    'finalize-kvm-agent\.sh' "$REPO_DIR" >/dev/null; then
  fail "repository still refers to finalize-kvm-agent.sh"
fi

[[ ! -d "${REPO_DIR}/formal-methods" ]] || fail \
  "obsolete formal-methods directory still exists"
[[ ! -d "${REPO_DIR}/host" ]] || fail \
  "obsolete multi-script host directory still exists"
[[ ! -d "${REPO_DIR}/toolchain" ]] || fail \
  "obsolete toolchain directory still exists"

python3 - "$REPO_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
missing = []
pattern = re.compile(r"\[[^\]]+\]\(([^)]+)\)")

for source in root.rglob("*.md"):
    for target in pattern.findall(source.read_text(encoding="utf-8")):
        if "://" in target or target.startswith("#") or target.startswith("mailto:"):
            continue
        path_text = target.split("#", 1)[0]
        if not path_text:
            continue
        resolved = (source.parent / path_text).resolve()
        if not resolved.exists():
            missing.append(f"{source.relative_to(root)} -> {target}")

if missing:
    print("Broken local Markdown links:", file=sys.stderr)
    for item in missing:
        print(f"  {item}", file=sys.stderr)
    raise SystemExit(1)
PY

"${SCRIPT_DIR}/mock-setup.sh"
"${SCRIPT_DIR}/mock-disk-growth.sh"
"${SCRIPT_DIR}/mock-cloud-init-clean.sh"
"${SCRIPT_DIR}/mock-swarm-job.sh"
"${SCRIPT_DIR}/mock-journal.sh"
"${SCRIPT_DIR}/mock-remove.sh"

echo "Repository checks passed."
