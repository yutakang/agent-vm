# Daily operation

[日本語版](daily-use_jp.md)

## Open and close the VM

After the first run, log out of the Ubuntu host and back in once so the new
`libvirt` group membership reaches the desktop session. Start the GUI:

```bash
virt-manager --connect qemu:///system
```

Double-click the VM, then use **View → Fullscreen** if desired. A normal ACPI
shutdown from the guest desktop is preferred. `Force Off` is equivalent to
pulling a physical machine's power cable and can corrupt its filesystem.

The script does not enable VM autostart. Enable it in `virt-manager` only if the
guest should consume memory and expose its network services whenever the host
boots.

## Keep long-running work alive with `tmux`

KVM-Agent installs `tmux` in the guest. Use it for coding agents, proof search,
builds, and other work that should continue if the Mac sleeps, Wi-Fi changes,
Tailscale reconnects, or an SSH session is interrupted.

For most daily work, one named session is enough:

```bash
tmux new -As work
```

This attaches to the existing `work` session if one exists, or creates it if
not. Start Claude Code, Codex, OpenCode, Isabelle jobs, or other long-running
commands inside that session.

Useful commands:

```text
Ctrl-b d       detach and leave the work running
Ctrl-b c       create a new window
Ctrl-b n       next window
Ctrl-b p       previous window
Ctrl-b ,       rename the current window
Ctrl-b [       enter scroll/copy mode; press q to leave it
```

From a fresh SSH connection:

```bash
tmux ls
tmux attach -t work
```

`tmux` protects a process from terminal and SSH disconnections. It does **not**
survive a VM shutdown or reboot, and it is not a security boundary.

## Run one GitHub issue through one agent branch

For a GitHub-connected project, use a protected-default-branch routine rather
than asking the agent to edit `main`:

1. write a bounded GitHub issue with acceptance criteria and test commands;
2. start the agent inside the repository and tell it the issue number;
3. have it update from `origin/main` and create an `agent/...` branch;
4. have it edit, test, commit, push the branch, and run `gh pr create` with
   `Closes #ISSUE`;
5. inspect the diff, checks, discussion, dependency provenance, and submodule
   commit on GitHub; and
6. merge the protected `main` yourself, then fast-forward the VM checkout.

An issue on GitHub does not automatically start a local CLI agent. The agent
can handle the branch push and PR creation once a human starts it with the
project-scoped credentials already loaded. Keep the agent out of the ruleset
bypass list and do not grant its API token Contents write.

The complete initial setup, exact credential split, current fine-grained-token
UI, commands, and failure recovery are in
[GitHub integration for a local coding-agent VM](github-integration.md).

## Recover a garbled terminal after an interrupted SSH session

Interactive full-screen programs can leave a terminal in a strange state when
SSH is interrupted: characters may not echo, line breaks may look wrong, or the
screen may appear to contain gibberish.

If a foreground program is still running, first try:

```text
Ctrl-C
```

If SSH has already dropped and you are back at the local shell (for example,
the Mac terminal), repair **that terminal** with:

```bash
reset
```

Even if typed characters are invisible or displayed incorrectly, type `reset`
and press Enter. If the terminal is still broken, try:

```bash
stty sane
reset
```

Then reconnect to the VM and resume the existing `tmux` session:

```bash
ssh YOUR_VM_NAME
tmux attach -t work
```

If SSH is still connected but only the remote shell display is corrupted, the
same `Ctrl-C` then `reset` sequence can be run in that shell. Do not reboot the
VM merely to repair terminal state.

## Resize an existing VM without rebuilding

Shut the guest down normally, then change its persistent RAM and/or vCPU
allocation from the host:

```bash
./setup-kvm-agent.sh --resize-existing \
  --name kvm-agent \
  --memory 24576 \
  --vcpus 12
```

The command refuses a running domain or a domain with a managed-save image and
does not remove or recreate its disk. If libvirt saved the VM's running state,
start it and perform a normal full shutdown before resizing. Start the existing
VM normally after the change. You may specify only `--memory` or only `--vcpus`.
Keep enough RAM and CPU capacity for the Ubuntu host; the helper enforces at
least 2 GiB of host RAM and never permits more vCPUs than the host reports.

This deliberately uses a powered-off configuration change rather than relying
on guest hot-plug support.

## Clean snapshots

Create the most valuable snapshot after:

- the provisioning marker exists and future cloud-init runs are disabled;
- all five command versions work;
- Ubuntu has reached the graphical login;
- no provider, GitHub, browser, or Ollama Cloud account has been added; and
- no confidential project has been copied into the VM.

Name it something obvious such as `clean-provisioned-no-credentials`.

Before restoring a snapshot, shut the VM down. Restoring a running VM snapshot
can include RAM, active sessions, and transient credentials. Snapshot support
and performance depend on disk format and libvirt/QEMU versions; confirm that a
restored test VM boots before depending on snapshots as recovery.

Snapshots are not backups. They normally depend on the same host storage and
may contain secrets.

## One VM per trust domain

Separate VMs or clones are appropriate for:

- different organizations or clients;
- public open-source versus confidential work;
- local-only models versus unrestricted remote providers;
- experimental plugins or MCP servers;
- credentials with different spending or repository authority; and
- testing an untrusted repository before importing reviewed changes.

Do not use a large, permanent "everything VM" if its accumulated credentials
and projects make it too expensive to discard.

## Moving project data

No host folder is shared automatically. A local VM still has a separate
filesystem, so ordinary host-side `cp` cannot read or write files under the
guest's `/home`. Safer practical choices are:

1. clone a public or narrowly authorized repository inside the guest;
2. transfer reviewed files with the host-side helper;
3. export a small patch from the guest and review it on the host; or
4. use a dedicated, short-lived Git branch and scoped token.

Setup installs `kvm-agent-host`, which discovers the current VM address and
uses the dedicated recovery key without exposing it to the guest. For the
default VM, copy a project from the physical Ubuntu host into the guest:

```bash
kvm-agent-host push kvm-agent ./my-project Work/
```

Create a small reviewable patch inside the guest:

```bash
git diff --binary > agent-result.patch
```

Then pull it from the trusted host. The default destination is
`~/vm-extraction-quarantine/kvm-agent/` with mode `0700`:

```bash
kvm-agent-host pull kvm-agent Work/agent-result.patch
```

Here `kvm-agent` is the example libvirt VM name; replace it if setup used a
different `--name`. Both directions begin on the trusted host. Never copy a
host SSH private key into the guest or enable SSH-agent forwarding.

From a separate trusted Mac, use a different Mac-only key and initiate `scp`
from the Mac. Follow [Secure remote access](remote-access.md#transfer-data-from-macos)
instead of copying the host recovery key.

Avoid recursive copies of the host home directory. Never copy browser profiles,
password-manager vaults, cloud configuration directories, signing keys, or
other long-lived credentials merely for convenience.

Inspect the patch in a separate directory, run tests, and only then apply or
commit it to an important repository. Treat every file
copied from a potentially compromised guest as untrusted; do not execute it,
build it, or open the directory as an IDE workspace before review.

### Stronger offline extraction

To avoid active interaction with a potentially compromised guest, shut it down
and extract from its virtual disk read-only. Install `libguestfs-tools` on the
host if necessary:

```bash
sudo apt update
sudo apt install libguestfs-tools
```

Then run the following example for the default VM name and disk layout:

```bash
sudo virsh --connect qemu:///system domstate kvm-agent
mkdir -p "$HOME/vm-extraction-quarantine/kvm-agent"
chmod 700 "$HOME/vm-extraction-quarantine/kvm-agent"
sudo guestfish --ro --format=qcow2 \
  -a /var/lib/libvirt/images/kvm-agent/vms/kvm-agent.qcow2 -i \
  copy-out /home/agent/Work/my-project \
  "$HOME/vm-extraction-quarantine/kvm-agent"
sudo chown -R "$USER:$USER" "$HOME/vm-extraction-quarantine/kvm-agent"
```

Continue only when `domstate` reports `shut off`. Offline extraction is more
cumbersome than `scp`, but it avoids relying on the running guest and gives a
stable filesystem view.

## Recovery SSH

For the default VM, use the installed host helper:

```bash
kvm-agent-host ssh kvm-agent
```

Useful checks inside the guest:

```bash
sudo cloud-init status --long
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
sudo tail -n 160 /var/log/kvm-agent-provision.log
sudo cat /var/lib/kvm-agent/installed-versions.txt
systemctl status gdm3 qemu-guest-agent ollama --no-pager
ss -ltnp | grep 11434
```

The helper pins the guest host key and disables agent, X11, and port forwarding.
The private recovery key stays on the host. Do not copy it into the guest or
forward another SSH agent into the VM. See [Secure remote access](remote-access.md)
for the threat model and macOS controller setup.

## Updating agent tools

The cleanest update is often a new VM or clean clone created by the current
script. This also removes state left by plugins, model clients, build tools, and
old experiments.

When updating in place, use current official instructions and remain inside the
guest. As of the references linked by this repository, the native installers
are:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://opencode.ai/install | bash
curl -fsSL https://ollama.com/install.sh | sh
```

Update Aider through the bootstrap installed by KVM-Agent:

```bash
~/.local/share/kvm-agent/uv-bootstrap/bin/uv tool upgrade aider-chat
```

Then verify:

```bash
codex --version
claude --version
opencode --version
aider --version
ollama --version
systemctl is-active ollama
ss -ltnp | grep 11434
```

The Ollama systemd drop-in under
`/etc/systemd/system/ollama.service.d/10-kvm-agent-loopback.conf` must continue
to set `OLLAMA_HOST=127.0.0.1:11434`.

Never run these third-party installer commands on the host by mistake.

## Ubuntu updates

Inside the guest:

```bash
sudo apt update
sudo apt full-upgrade
```

Take or identify a rollback point before a large upgrade. Reboot if the kernel,
QEMU guest integration, or display stack was updated:

```bash
sudo reboot
```

Keep the Ubuntu host updated separately. Host kernel, QEMU, libvirt, and
`virt-manager` security fixes protect the isolation boundary.

## Ollama models

No model is downloaded by default. A model pulled with:

```bash
ollama pull MODEL_NAME
```

consumes the VM disk and usually runs on CPU because no GPU is passed through.
Check the model license, origin, size, RAM requirement, and confidentiality
properties before use.

`ollama signin` and Ollama Cloud models perform remote inference. They are not
made local by using the Ollama CLI.

## Export, review, discard

At the end of a task:

1. inspect `git status`, diffs, generated files, and dependency changes;
2. run tests in the guest;
3. export a patch or push through a narrowly scoped branch;
4. verify the result outside the guest;
5. revoke or rotate guest credentials; and
6. roll back or delete the VM when it is no longer a useful trust boundary.

To remove a KVM-Agent guest and all of its repository-managed host state, shut
it down and run from the repository:

```bash
./remove-kvm-agent.sh --name kvm-agent
```

Use `--dry-run` first if desired. The helper removes only the exact managed
disk, leftover seed, recovery directory, current libvirt log, and named domain.
It retains the shared Ubuntu image cache, host packages, and any manually
attached extra storage. Deletion is not guaranteed secure erase; see
[SECURITY.md](../SECURITY.md).
