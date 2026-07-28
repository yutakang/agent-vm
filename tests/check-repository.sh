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
    docs/troubleshooting.md docs/troubleshooting_jp.md \
    docs/references.md docs/references_jp.md; do
  [[ -s "${REPO_DIR}/${required}" ]] || fail "missing or empty: $required"
done

for required_text in \
    "readonly DEFAULT_DISK_GB=120" \
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

for required_disk_safety in \
    "growpart:" \
    "resize_rootfs: true" \
    "ensure_requested_root_capacity" \
    "Root filesystem is smaller than 90%" \
    "emergency-space.reserve" \
    "qemu-img info --output=json" \
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
    "usermod -aG libvirt,kvm" \
    "ufw --force disable" \
    "listen=127.0.0.1"; do
  grep -Fq -- "$forbidden_text" "$SETUP_SCRIPT" \
    && fail "setup script still contains: $forbidden_text"
done

for required_text in \
    "/var/lib/kvm-agent/provisioned" \
    "/var/lib/kvm-agent/provisioning-failed" \
    "/etc/cloud/cloud-init.disabled" \
    "domifaddr" \
    "domblklist" \
    "--inactive --details" \
    "change-media" \
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
"${SCRIPT_DIR}/mock-remove.sh"

echo "Repository checks passed."
