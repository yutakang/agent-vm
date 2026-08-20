# Troubleshooting

[日本語版](troubleshooting_jp.md)

The setup script refuses to replace an existing domain or disk. Diagnose the
specific phase before deleting anything. The VM, base image, recovery key, and
temporary provisioning state are separate objects.

## Collect a small diagnostic set

On the host:

```bash
lsb_release -ds
id
ls -l /dev/kvm
virsh --connect qemu:///system list --all
virsh --connect qemu:///system net-info default
virsh --connect qemu:///system dominfo kvm-agent
virsh --connect qemu:///system domifaddr kvm-agent --source lease
```

Inside the guest or over recovery SSH:

```bash
sudo cloud-init status --long
sudo tail -n 200 /var/log/kvm-agent-provision.log
sudo journalctl -u cloud-final -b --no-pager -n 200
sudo systemctl status gdm3 qemu-guest-agent ollama --no-pager --full
```

Do not publish logs without checking them for user names, paths, IP addresses,
repository URLs, tokens, or provider account information.

## `/dev/kvm` is unavailable

Symptoms:

```text
Error: /dev/kvm is unavailable.
```

Check:

```bash
lscpu | grep -i virtualization
lsmod | grep '^kvm'
```

Enable Intel VT-x/VT-d or AMD-V/SVM in UEFI/BIOS. Completely power off and
restart if the firmware setting does not take effect after a warm reboot.
Corporate firmware policy may lock the setting.

Nested virtualization is a separate case. If this Ubuntu host is itself a VM,
its outer hypervisor must expose virtualization extensions.

## `virt-manager` shows no system VMs or permission denied

The first script run adds the host account to `libvirt`, but existing desktop
processes keep their old group list.

Log out of the Ubuntu host completely and log back in. Then:

```bash
id -nG
virsh --connect qemu:///system list --all
```

The groups should include `libvirt`. There is no need for `kvm`: that group
belongs to the QEMU service account. Do not run `virt-manager` with `sudo`;
root-owned GUI configuration and display-authority problems are a poor
workaround.

If you deliberately removed yourself from `libvirt` so that authorisation is
per-session (see `SECURITY.md`), `virt-manager` prompts for an administrator
password on connect and `virsh` needs `sudo`. That is expected, not a fault.

Confirm the GUI is connected to **QEMU/KVM — System**, not a separate user
session. The URI should be `qemu:///system`.

## The default network will not start

Check:

```bash
sudo virsh --connect qemu:///system net-info default
sudo virsh --connect qemu:///system net-dumpxml default
ip address show virbr0
sudo journalctl -u libvirtd -b --no-pager -n 200
```

Common causes are another network already using `192.168.122.0/24`, a stale
`virbr0`, firewall customization, or a partially defined libvirt network.

Do not delete unrelated bridges or firewall rules blindly. If the standard
subnet conflicts with a real network, define a different private libvirt
network deliberately and update the script's `LIBVIRT_NETWORK` and DHCP
expectations together.

## Ubuntu image signature or checksum verification fails

Do not bypass the verification.

Check host time and update the trusted Ubuntu packages:

```bash
timedatectl
sudo apt update
sudo apt install --reinstall ubuntu-keyring ca-certificates
```

Then retry. A captive portal, TLS-inspecting proxy, incomplete mirror update,
or stale keyring can cause failure. The cached image is used only if it matches
the checksum recorded after a successful signed-manifest verification.

## An existing guest is Ubuntu 24.04

Installing a corrected repository does not upgrade an existing VM. Confirm the
selected guest from the trusted Ubuntu host:

```bash
kvm-agent-host ssh YOUR_VM_NAME cat /etc/os-release
```

New setup and finalization require Ubuntu 26.04. A 24.04 result therefore means
that the VM was created by an older version. For this disposable security
boundary, rebuilding from the reviewed 26.04 image is more predictable than an
in-place distribution upgrade with accumulated agent and installer state.

First pull only the source, patches, reports, or other work that must survive:

```bash
kvm-agent-host pull YOUR_VM_NAME Work/
```

The helper puts the result below
`~/vm-extraction-quarantine/YOUR_VM_NAME/`, removes executable permission, and
rejects links and special files. Inspect the data before restoring it. Avoid
copying package caches, build products, browser profiles, provider sessions, or
long-lived credentials into the replacement guest; rebuild dependencies from
reviewed manifests instead.

Then inspect the exact removal scope:

```bash
./remove-kvm-agent.sh --name YOUR_VM_NAME --dry-run
```

Only after confirming the export and the selected name, rebuild:

```bash
./setup-kvm-agent.sh --replace-existing --name YOUR_VM_NAME
```

Add the same opt-in flags required for the replacement, such as
`--formal-methods` or `--swarm-role`. The command displays the VM-specific
artifacts and requires the exact VM name before deletion. The old 24.04 base
image may remain in the shared cache, but the corrected setup uses the distinct
26.04 filename and cannot reuse it as the new guest disk.

## A VM or disk already exists

The script fails rather than overwriting:

```text
A libvirt VM named 'kvm-agent' already exists
```

If it is a useful VM, start it in `virt-manager` or choose another name:

```bash
./setup-kvm-agent.sh --name kvm-agent-02
```

If it belongs only to a failed creation, inspect it first:

```bash
sudo virsh --connect qemu:///system dominfo kvm-agent
sudo virsh --connect qemu:///system domblklist kvm-agent --details
```

If it is confirmed to be a failed KVM-Agent guest, shut it down and inspect the
repository cleanup plan:

```bash
./remove-kvm-agent.sh --name kvm-agent --dry-run
./remove-kvm-agent.sh --name kvm-agent
```

The helper removes the exact managed disk, leftover seed, recovery data, log,
and domain while retaining shared caches and manually attached extra disks. Do
not copy a generic recursive deletion command from a bug report.

## The script cannot find a VM address

Check:

```bash
sudo virsh --connect qemu:///system domstate kvm-agent
sudo virsh --connect qemu:///system domiflist kvm-agent
sudo virsh --connect qemu:///system domifaddr kvm-agent --source lease
sudo virsh --connect qemu:///system net-dhcp-leases default
```

Open the graphical or serial console. An address may be missing because the
guest did not boot, cloud-init networking failed, the default network is
inactive, or another DHCP/network configuration was manually attached.

Once `qemu-guest-agent` is installed and active, this may also work:

```bash
sudo virsh --connect qemu:///system domifaddr kvm-agent --source agent
```

## SSH reports a host-key conflict

Each VM name has a dedicated file:

```text
~/.local/share/kvm-agent/VM_NAME/known_hosts
```

The setup script discards this file when it builds a new VM under an existing
name, so a conflict during setup is unexpected. It normally means the address
was reused by a different guest while the file was current. Confirm the domain
and address in `virt-manager` and `virsh` first. Then remove only the stale
per-VM entry:

```bash
ssh-keygen -R VM_ADDRESS \
  -f ~/.local/share/kvm-agent/kvm-agent/known_hosts
```

Never disable host-key checking globally.

## The terminal is garbled after SSH is interrupted

An interrupted interactive or full-screen SSH session can leave the terminal
with broken echo, line handling, or display state. This is usually a terminal
state problem, not VM corruption.

If a foreground program is still active, press `Ctrl-C` once. If SSH has
already dropped and you are back at the local shell (for example on macOS),
type the following there even if the characters do not display correctly:

```bash
reset
```

If that is not enough:

```bash
stty sane
reset
```

Then reconnect. If the long-running command was started inside `tmux`, resume
it rather than restarting it:

```bash
ssh YOUR_VM_NAME
tmux attach -t work
```

If SSH is still connected but only the remote shell is garbled, run the same
`Ctrl-C` then `reset` sequence in that shell. See
[Daily operation](daily-use.md#recover-a-garbled-terminal-after-an-interrupted-ssh-session)
for the recommended `tmux` workflow that makes dropped SSH sessions routine.

## Setup says it could not verify the qcow2 virtual size

Version 11 resized the image correctly but extracted `virtual-size` with a
line-oriented expression. Valid compact JSON from `qemu-img` could therefore
make verification fail before `virt-install`, even when the image was already
120 GiB.

The current setup parses the JSON structurally and tests compact output in its
mock workflow. A failed version-11 attempt may leave only the new main disk and
seed—without a libvirt domain. Do not delete either path by hand. For a
credential-free disposable guest, rerun the current repository with:

```bash
./setup-kvm-agent.sh \
  --replace-existing \
  --name kvm-agent \
  --formal-methods
```

The removal helper inventories and removes only the selected VM's managed
artifacts before rebuilding it.

## Provisioning reports no space or the graphical login loops

Releases before the root-capacity fix enlarged the qcow2 device but did not
verify that Ubuntu had enlarged `/` before installing the desktop and
toolchains. A small source-image filesystem could therefore fill while the
qcow2 file itself still occupied only a few GiB on the host.

The current setup treats usable root capacity as a required invariant. It:

- requests cloud-init partition and filesystem growth;
- safely retries growth for the standard Ubuntu cloud-image partition;
- refuses package installation unless `/` is at least 90% of `--disk`;
- checks free host backing space before deleting an old VM;
- checks guest free space again before large provisioning stages; and
- reserves 512 MiB that is released automatically on failure.

For a credential-free failed guest, use the corrected repository and rebuild:

```bash
./setup-kvm-agent.sh \
  --replace-existing \
  --name kvm-agent \
  --formal-methods
```

The 120 GiB default is thin-provisioned and normally does not consume 120 GiB
on the host immediately. Do not infer the guest filesystem size from
`du` on the qcow2 file.

## Cloud-init reports an error

Get the actual failing command:

```bash
sudo cloud-init status --long
sudo less /var/log/kvm-agent-provision.log
sudo less /var/log/cloud-init-output.log
```

Typical causes:

- temporary Ubuntu or upstream download failure;
- an official installer changed its interface;
- insufficient disk space or RAM;
- a package-manager interruption;
- DNS, proxy, or certificate problems;
- Aider dependency resolution failing for a newly released package; or
- with `--formal-methods`, a Lean, GHCup, Cabal/HLint, VS Code, extension, or
  Isabelle download failure.

`curl: (23) Failure writing output to destination` while downloading Isabelle
in v12 can be caused by the archive being staged under the small RAM-backed
`/run` filesystem, even when the 120 GiB root filesystem has ample space.
Current versions stage large downloads on the root filesystem and remove
partial files automatically.

The script installs credentials only after none—it does not add any. If
provisioning failed in an otherwise empty VM, the cleanest response is usually
to preserve logs, delete that failed guest, correct the cause, and create a new
VM. Do not add provider credentials to a partially provisioned guest.

### Claude Code reports `EACCES` under `~/.local/share`

Repository revisions before the ownership fix could create `~/.local` and
`~/.local/share` as `root` while creating only their child directories as the
guest user. Claude Code then failed with:

```text
EACCES: permission denied, mkdir '/home/agent/.local/share/claude'
```

Confirm the diagnosis inside the guest:

```bash
stat -c '%U:%G %a %n' \
  "$HOME/.local" "$HOME/.local/share" "$HOME/.local/bin"
```

The current script explicitly creates every XDG parent with guest ownership and
passes conventional `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and
`XDG_CACHE_HOME` values to user-level installers. For a credential-free failed
VM, retain the logs and recreate it with the corrected script. That gives a
cleaner result than completing an unknown partial installer state manually.

## The GUI shows only a console or black screen

Provisioning begins from a server cloud image. The desktop appears only after
`ubuntu-desktop-minimal` and `gdm3` finish installing.

Check:

```bash
sudo cloud-init status --long
sudo systemctl status gdm3 --no-pager --full
sudo systemctl get-default
sudo journalctl -u gdm3 -b --no-pager -n 200
```

The default target should be `graphical.target`. A black screen during the
initial 20–60 minutes can simply mean the desktop is still being installed.
With `--formal-methods`, the display manager deliberately starts only after the
optional toolchains finish, so this phase can last several hours.

In `virt-manager`, confirm the VM has a SPICE display, a virtio video device,
and a SPICE channel. If these were manually changed, restore them while the VM
is shut down.

## Mouse, resolution, or clipboard integration does not work

Inside the guest:

```bash
dpkg -l spice-vdagent
systemctl --user status spice-vdagentd.service --no-pager || true
ps aux | grep '[s]pice-vdagent'
```

Log out of the guest desktop and back in after installing or repairing
`spice-vdagent`. Confirm the SPICE channel exists in `virt-manager`.

Clipboard integration is optional. Leaving it disabled is a valid higher-safety
choice.

## One agent command is missing

Check the explicit guest paths:

```bash
printf '%s\n' "$PATH"
ls -la ~/.local/bin ~/.opencode/bin
sudo cat /var/lib/kvm-agent/installed-versions.txt
```

Open a new terminal so `/etc/profile.d/kvm-agent-tools.sh` and `~/.profile` are
loaded. If cloud-init did not finish successfully, diagnose provisioning rather
than installing credentials and continuing with an unknown partial state.

## A formal-methods command or VS Code extension is missing

This profile is installed only when VM creation used `--formal-methods`.
Confirm the recorded result inside the guest:

```bash
sudo cat /var/lib/kvm-agent/installed-versions.txt
printf '%s\n' "$PATH"
code --list-extensions
```

Open a new terminal so `~/.profile` supplies `~/.elan/bin`, `~/.ghcup/bin`, and
`~/.local/bin`. The expected extension identifiers are exactly:

```text
leanprover.lean4
haskell.haskell
```

Isabelle is not one of those Marketplace extensions. Use `isabelle jedit`, or
the separately bundled `isabelle vscode` environment. If initial provisioning
failed, preserve the log and rebuild the credential-free guest; do not treat a
partially installed toolchain as a successful profile.

## Ollama is unavailable or exposed too broadly

Check:

```bash
systemctl status ollama --no-pager --full
systemctl cat ollama
curl http://127.0.0.1:11434/api/version
ss -ltnp | grep 11434
```

The effective service environment must contain:

```text
OLLAMA_HOST=127.0.0.1:11434
```

and the listener must not be `0.0.0.0:11434`, `[::]:11434`, or `*:11434`.

After repairing the drop-in:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Do not expose Ollama on the LAN merely to solve a guest-local client
configuration error.

## The guest cannot reach something on your own network

By default the guest firewall denies outbound traffic to private address space,
so an internal package mirror, a NAS, a printer, or a model endpoint on your LAN
is unreachable from inside the VM. Internet access is unaffected.

Check what is in force:

```bash
sudo ufw status verbose
```

The intended rules deny `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and
`169.254.0.0/16` outbound, while allowing DNS and DHCP to the libvirt gateway
and inbound SSH from that gateway only.

To allow one internal destination, add a narrow rule ahead of the deny rules
rather than disabling the firewall:

```bash
sudo ufw insert 1 allow out to MIRROR_ADDRESS port 443 proto tcp
```

To permit private-range egress generally, recreate the VM with `--allow-lan`.
This omits the outbound private/link-local deny rules but does not disable UFW:
unsolicited inbound traffic remains denied and recovery SSH remains limited to
the libvirt gateway. Remember that this is a guest-side default: an agent with
sudo can still change it. Where the policy must hold regardless, express it as
a libvirt `nwfilter` on the guest interface instead.

## The cloud-init seed is still present

The setup script ejects and shreds
`/var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img` once provisioning
finishes, because it contains the guest password hash. It is still there when
the run used `--no-wait`, or when the eject failed and the script warned about
it.

On the normal waited path, the script also creates and verifies
`/etc/cloud/cloud-init.disabled` after successful provisioning and before any
required first reboot. This prevents future cloud-init runs; the status command
may therefore report `disabled` afterward. The provisioning marker and log
remain:

```bash
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
sudo tail -n 160 /var/log/kvm-agent-provision.log
```

With `--no-wait`, or after a post-reboot host-side timeout, resume through the
setup command rather than performing the individual SSH and `virsh` operations:

```bash
./setup-kvm-agent.sh --finalize-existing --name NAME
```

It verifies successful provisioning, creates and verifies the disable marker,
and then performs any required reboot. It requires the kernel boot ID to change
before accepting the guest as rebooted, and re-discovers its DHCP address.
Only then does it detach the exact seed from both the live and persistent
configurations and remove the file. If any inspection or verification fails,
it retains the seed and reports an error. The provisioning check uses bounded,
non-blocking SSH polls. If a remote check stops responding, that individual
invocation is terminated and the helper continues retrying until its documented
overall deadline.

`shred` here means "remove, and attempt to overwrite first". On SSDs,
copy-on-write filesystems, and layered storage it cannot guarantee the old
blocks are gone. Treat the guest password as disclosed to anyone who held root
on the host while the seed existed, and choose a password you do not use
elsewhere.

## GitHub integration behaves unexpectedly

Three messages commonly look like failures but describe different states:

- `You've successfully authenticated, but GitHub does not provide shell access`
  from `ssh -T` is success. Confirm that the greeting names the intended
  repository.
- **Compare & pull request** means a feature branch was pushed but no pull
  request exists yet. The local agent can run `gh pr create`; the human does
  not have to click the banner.
- a rejected direct push to `main` is the intended ruleset behavior. Push an
  `agent/...` branch and create a PR instead.

If `gh issue view` reports that Projects Classic or `projectCards` is
deprecated, the Ubuntu-packaged GitHub CLI is too old for the current GitHub
API. Install or update `gh` from GitHub's official APT repository. Until then,
request only explicit data fields:

```bash
gh issue view ISSUE --repo OWNER/REPOSITORY \
  --json number,title,body,url
```

If `gh` works in a terminal but not in a coding agent, restart that agent after
loading the project's token. Environment variables are inherited at process
start and an earlier process does not see a later `export`.

Follow [GitHub integration](github-integration.md) for the full credential,
ruleset, CLI installation, issue-to-PR, and revocation procedure.
