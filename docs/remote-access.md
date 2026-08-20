# Secure access from an Ubuntu host or macOS controller

[日本語版](remote-access_jp.md)

This guide covers two different trusted devices:

- the **physical Ubuntu host** that runs libvirt and the VM; and
- a separate **trusted Mac** that reaches an agent VM through Tailscale.

All words written as `YOUR_...` are placeholders. Replace them. For normal
operation, choose one globally unique VM name and reuse it for the libvirt
domain, guest hostname, Tailscale device, and Mac SSH alias.

## The short, safe path

For the physical Ubuntu host, setup installs `kvm-agent-host` automatically:

```bash
kvm-agent-host list
kvm-agent-host ssh YOUR_LIBVIRT_VM_NAME
kvm-agent-host push YOUR_LIBVIRT_VM_NAME ./my-project Work/
kvm-agent-host pull YOUR_LIBVIRT_VM_NAME Work/agent-result.patch
```

The `pull` command creates
`~/vm-extraction-quarantine/YOUR_LIBVIRT_VM_NAME/` by default. Both transfers
are initiated by the trusted host. The VM never receives the host's private
recovery key. On pull, the helper also removes executable permission, refuses
device, special, and symbolic-link entries. These safeguards reduce accidents;
they do not make guest output trusted.

For a trusted Mac:

1. Join the Mac and the VM to the intended tailnet.
2. On the Mac, from this repository, run:

   ```bash
   ./macos/setup-secure-access.sh YOUR_VM_NAME
   ```

3. The command prints one `kvm-agent-authorize-controller-key ...` command.
   Open the VM's local graphical terminal and run that printed command there.
4. On the Mac, connect with:

   ```bash
   ssh YOUR_VM_NAME
   ```

5. Before relying on the connection, complete the directional Tailscale policy
   in [Cross-host manager/worker VMs](swarm.md#multiple-independent-swarms-in-one-tailnet).

The setup helper creates a new key for this VM. A passphrase is recommended.
Only the public key is copied into the VM.

## Which name means what?

These identifiers belong to different systems, but KVM-Agent recommends
deliberately giving the same machine identity to all four user-visible VM
names. This makes `virsh`, Tailscale, and `ssh` agree about which VM you mean.

| Identifier | Used where | Recommended example |
|---|---|---|
| Physical-host label | Your notes only | `ThinkPad host` |
| Libvirt VM name | `--name`, `virsh`, `kvm-agent-host` | `vm-workstation-01` |
| Guest Linux hostname | Inside the VM | `vm-workstation-01` |
| Tailscale device name | Machines page and MagicDNS | `vm-workstation-01` |
| Mac SSH alias | `ssh ALIAS`; normally same as MagicDNS | `vm-workstation-01` |
| Guest login | SSH/Linux account | `agent` |
| Tailscale tag | Tailnet access policy | `tag:development` or `tag:swarm-research-a-manager` |

`--name` sets the **libvirt domain name and guest Linux hostname**. When joining
Tailscale, explicitly reuse that name with `--name`; on the Mac, use the same
name as the default SSH alias. The physical host's label and Tailscale tags are
different concepts: tags describe security role/group and should not be used
as machine identity.

To find existing libvirt names, run this on the physical Ubuntu host:

```bash
sudo virsh --connect qemu:///system list --all --name
```

Commands that modify an existing VM now require `--name` explicitly. This
prevents an omitted option from silently targeting the default `kvm-agent` VM.

## Corridor, door, and key: SSH versus Tailscale

SSH keys and Tailscale policy solve different problems.

| Control | Question it answers | What it does not do |
|---|---|---|
| Tailscale grants | May device A contact TCP port 22 on device B at all? | Authenticate the Linux account for ordinary OpenSSH |
| SSH public/private key | After reaching SSH, may this client log in? | Stop scans or attacks against other listening services |
| Guest UFW | Is TCP/22 reachable on this network interface? | Identify a peer by Tailscale tag |
| Mac SSH configuration | Which local key and forwarding features may this connection use? | Replace server or tailnet policy |

Tailscale policy is the locked **corridor** leading to a machine. An SSH key is
the lock on one **door** at the end of that corridor. The Mac holds the private
key; the VM stores only the matching public key.

With SSH keys alone, a compromised VM normally cannot log back into the Mac,
because it lacks a Mac private key. However, an allow-all tailnet still lets it
reach and probe every port on every peer. A restrictive Tailscale policy blocks
those network attempts before another service or SSH authentication is reached.

Replies to an allowed connection are still possible. A rule allowing
Mac → manager does not need a reverse manager → Mac rule for an established
SSH session to work.

## Access from the physical Ubuntu host

`setup-kvm-agent.sh` installs `~/.local/bin/kvm-agent-host`. After the first
setup, log out and in once if Ubuntu has not yet refreshed the `libvirt` group
membership.

Common commands are:

```bash
kvm-agent-host list
kvm-agent-host status YOUR_LIBVIRT_VM_NAME
kvm-agent-host start YOUR_LIBVIRT_VM_NAME
kvm-agent-host shutdown YOUR_LIBVIRT_VM_NAME
kvm-agent-host ssh YOUR_LIBVIRT_VM_NAME
```

The helper discovers the current DHCP lease and pins these settings internally:

- the VM-specific recovery key;
- a VM-specific known-hosts file and stable host-key alias;
- `IdentityAgent=none`, `IdentitiesOnly=yes`, and `ForwardAgent=no`;
- `ForwardX11=no` and `ClearAllForwardings=yes`; and
- a finite connection timeout.

Do not copy the recovery private key from
`~/.local/share/kvm-agent/YOUR_LIBVIRT_VM_NAME/` into the VM.

## Set up the trusted Mac

### 1. Prepare ordinary OpenSSH safely

On the Mac, run:

```bash
./macos/setup-secure-access.sh YOUR_VM_NAME
```

For a non-default guest user or a separate local alias:

```bash
./macos/setup-secure-access.sh YOUR_VM_NAME \
  --alias YOUR_LOCAL_SSH_ALIAS \
  --user YOUR_GUEST_USER
```

The helper:

- creates a dedicated Ed25519 key with an interactive passphrase prompt;
- writes a separate file under `~/.ssh/kvm-agent.d/`;
- safely adds an `Include` at the beginning of `~/.ssh/config`, keeping a
  timestamped backup if that file already exists;
- disables agent, X11, proxy, multiplexing, and port forwarding;
- uses only the dedicated identity and a separate known-hosts file; and
- enables macOS Keychain support without loading the key into the general SSH
  agent automatically.

It does not log in to the VM or change Tailscale policy.

### 2. Register only the Mac public key

The Mac helper prints a complete command resembling this:

```bash
kvm-agent-authorize-controller-key 'ssh-ed25519 AAAA... kvm-agent-controller:YOUR_ALIAS'
```

Run the printed command inside the VM's local graphical terminal as the normal
guest user. Do not use a made-up key or copy the abbreviated example above.

The guest helper preserves existing keys, validates the Ed25519 public key, and
adds per-key restrictions for agent forwarding, port forwarding, X11, and
`~/.ssh/rc`. The VM-wide SSH server baseline independently disables password
login, root login, agent forwarding, X11 forwarding, tunnels, and, by default,
all port forwarding.

For an older VM made with a previous repository version, reapply that baseline
from its physical Ubuntu host:

```bash
./setup-kvm-agent.sh \
  --harden-existing \
  --name YOUR_ACTUAL_LIBVIRT_VM_NAME
```

### 3. Verify the SSH host key on first connection

Inside the VM's local console, obtain the expected fingerprint:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

On the first Mac connection, compare the fingerprint before accepting it:

```bash
ssh YOUR_LOCAL_SSH_ALIAS
```

After acceptance, a rebuilt VM has a different key and SSH will stop with a
host-key mismatch. Verify the new key locally before replacing the old record.

## Why the generated Mac options matter

| Option | Generated value | Reason |
|---|---:|---|
| `ForwardAgent` | `no` | A compromised VM cannot ask the Mac's agent to authenticate elsewhere. |
| `ForwardX11` | `no` | The VM cannot use an X11 channel back into the Mac. |
| `ClearAllForwardings` | `yes` | Cancels broad `Host *` port-forward rules for this shell alias. |
| `IdentityFile` | dedicated key | Limits this VM to one purpose-specific identity. |
| `IdentitiesOnly` | `yes` | Prevents SSH from trying unrelated identities. |
| `IdentityAgent` | `none` | Bypasses keys cached in a general SSH agent. |
| `UseKeychain` | `yes` | Lets macOS store this key's passphrase. |
| `AddKeysToAgent` | `no` | Does not automatically keep the decrypted key in the general agent. |
| `ConnectTimeout` | `15` | Avoids a long hang when the VM is offline; this is reliability, not isolation. |

`ForwardAgent no` and `ForwardX11 no` are also the OpenSSH defaults, but writing
them explicitly prevents a later broad `Host *` entry from silently changing
the intended policy. OpenSSH processes the first value obtained for most
options, so the installer places the managed `Include` first.

### Where the configuration lives

The generated files are deliberately separate from unrelated SSH settings:

| Device | Managed configuration |
|---|---|
| VM | `/etc/ssh/sshd_config.d/00-kvm-agent.conf` |
| VM guest account | `~/.ssh/authorized_keys`, with restrictions on each controller key |
| Mac | `~/.ssh/kvm-agent.d/YOUR_LOCAL_SSH_ALIAS.conf` |
| Physical Ubuntu host | No SSH config edit; `kvm-agent-host` supplies fixed options per command |

Do not copy a generic internet `sshd_config` over the VM's main file. Reapply
the reviewed drop-in with `--harden-existing`. Verify the server's effective
values inside the VM with:

```bash
sudo sshd -T | grep -E \
  '^(passwordauthentication|permitrootlogin|allowagentforwarding|allowtcpforwarding|allowstreamlocalforwarding|x11forwarding|permittunnel) '
```

Verify what the Mac will actually use before connecting:

```bash
ssh -G YOUR_LOCAL_SSH_ALIAS | grep -Ei \
  '^(hostname|user|identityfile|identityagent|forwardagent|forwardx11|clearallforwardings|proxyjump|proxycommand) '
```

Client `ForwardAgent no` protects the Mac's authentication agent; server
`AllowAgentForwarding no` independently refuses that channel. Likewise,
`ForwardX11 no` is the client refusal and `X11Forwarding no` is the server
refusal. Keeping both ends explicit makes a partial configuration mistake less
likely to open a channel.

The `00-` prefix is intentional. OpenSSH uses the first value it reads for
most server options, so this file must sort before cloud-image or package
drop-ins; renaming it to `90-...` can make an earlier permissive value win.

## Transfer data from macOS

Initiate both directions from the trusted Mac. Do not put a Mac private key in
the VM merely so the VM can push a result outward.

Send a project into the VM:

```bash
scp -r ./my-project YOUR_LOCAL_SSH_ALIAS:Work/
```

Pull a small result or patch out of the VM:

```bash
mkdir -m 700 -p "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS"
scp YOUR_LOCAL_SSH_ALIAS:Work/agent-result.patch \
  "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS/"
chmod 600 \
  "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS/agent-result.patch"
```

`scp` is included with macOS's OpenSSH client. Add `-r` only when sending or
pulling a directory. Current OpenSSH uses the SFTP protocol for this command;
do not add the legacy `-O` option.

Treat everything pulled from an agent VM as untrusted. Review it before running
it, building it, opening it as an IDE workspace, or moving it into an important
repository. A patch is normally easier to review than an entire working tree:

```bash
git diff --binary > Work/agent-result.patch
```

## Optional remote editor

The secure default disables SSH port forwarding, so VS Code Remote-SSH and
similar tools do not work through the normal alias. This is deliberate.

If the benefit justifies the larger channel, opt in at both ends.

On the physical Ubuntu host:

```bash
./setup-kvm-agent.sh \
  --harden-existing \
  --name YOUR_ACTUAL_LIBVIRT_VM_NAME \
  --allow-remote-editor
```

On the Mac, create a separate alias:

```bash
./macos/setup-secure-access.sh YOUR_VM_NAME \
  --add-remote-editor-alias
```

Then use the printed `--allow-port-forwarding` authorization command inside
the VM and point the editor at `YOUR_VM_NAME-editor`. The ordinary
shell alias remains hardened with `ClearAllForwardings yes`. Agent and X11
forwarding remain disabled for both aliases.

Restore the deny-forwarding server baseline later by rerunning
`--harden-existing` without `--allow-remote-editor` and reauthorizing the key
without `--allow-port-forwarding`.

## If SSH says `Permission denied (publickey)`

This message is useful: MagicDNS, Tailscale routing, and the VM's SSH server
were reached. The remaining problem is the login key.

Check, in order:

1. the Mac helper printed and configured the alias you are using;
2. the complete public key was registered inside the VM;
3. `ssh -G YOUR_LOCAL_SSH_ALIAS | grep -Ei 'hostname|user|identityfile'` shows
   the expected values; and
4. `~/.ssh` is mode `700` and `~/.ssh/authorized_keys` is mode `600` in the VM.

Do not fix this by enabling SSH passwords, copying a private key into the VM,
using `ForwardAgent yes`, or setting `StrictHostKeyChecking no`.

## References

- [OpenSSH client configuration](https://man.openbsd.org/ssh_config)
- [Apple: OpenSSH and macOS Keychain](https://developer.apple.com/library/archive/technotes/tn2449/_index.html)
- [Tailscale tags](https://tailscale.com/docs/features/tags)
- [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants)
