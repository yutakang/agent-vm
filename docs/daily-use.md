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

No host folder is shared automatically. Safer practical choices are:

1. clone a public or narrowly authorized repository inside the guest;
2. copy a reviewed archive with `scp`;
3. export a patch from the guest and review it on the host; or
4. use a dedicated, short-lived Git branch and scoped token.

The setup script prints the recovery key path. To copy a file into the guest:

```bash
VM_IP=192.168.122.100
scp -o IdentitiesOnly=yes \
  -i ~/.local/share/kvm-agent/kvm-agent/id_ed25519 \
  project.tar.gz agent@"$VM_IP":~
```

Resolve the current address with:

```bash
virsh --connect qemu:///system domifaddr kvm-agent --source lease
```

Avoid recursive copies of the host home directory. Never copy host SSH private
keys, browser profiles, password-manager vaults, cloud configuration directories,
or signing keys merely for convenience.

For output, a patch is easy to inspect:

```bash
git diff --binary > agent-result.patch
```

Copy it out with `scp`, inspect it in a separate directory, run tests, and only
then apply or commit it to an important repository.

## Recovery SSH

For the default VM:

```bash
ssh -o ForwardAgent=no \
  -o IdentitiesOnly=yes \
  -i ~/.local/share/kvm-agent/kvm-agent/id_ed25519 \
  agent@VM_ADDRESS
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

The private recovery key stays on the host. Do not copy it into the guest or
forward another SSH agent into the VM.

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

Deleting a VM in `virt-manager` can remove its storage only when the storage
checkbox is selected. Carefully confirm the exact qcow2 path before deletion.
Deletion is not guaranteed secure erase; see [SECURITY.md](../SECURITY.md).
