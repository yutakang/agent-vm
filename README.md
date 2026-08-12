# KVM-Agent: a graphical Ubuntu VM for coding agents

[日本語版](README_jp.md)

> **Experimental, non-authoritative material.** This is a personal working
> project created partly with emerging AI tools. It is not a verified security
> product or professional advice. Test it without important data or credentials
> first. Corrections are welcome. Use it at your own risk and cost.
> [Full disclaimer](DISCLAIMER.md).

KVM-Agent creates a disposable graphical Ubuntu desktop for autonomous coding
agents. The host runs only Ubuntu's KVM/libvirt stack and `virt-manager`; Codex,
Claude Code, OpenCode, Aider, Ollama, project commands, and their third-party
installers run inside the VM.

The repository has one setup and recovery command:

```bash
./setup-kvm-agent.sh
```

The script installs the host virtualization stack, authenticates an official
Ubuntu cloud image, creates the VM, installs a minimal Ubuntu desktop, installs
the five requested tools, and waits for the result. Day-to-day operation happens
through the familiar `virt-manager` GUI.

An opt-in reduced formal-methods environment is available:

```bash
./setup-kvm-agent.sh --formal-methods
```

It adds Lean 4, Isabelle/HOL, GHC, Cabal, Haskell Language Server, HLint,
VS Code, and the official Lean and Haskell extensions inside the same
graphical guest. It does not restore the older repository architecture or its
larger prover collection.

An additional opt-in manager/worker profile can prepare VMs on different
physical hosts to submit long jobs over Tailscale or WireGuard plus ordinary
OpenSSH. It is intentionally not enabled for normal users; see
[Cross-host manager/worker VMs](docs/swarm.md).

An opt-in research-journal profile can also be added to already-running VMs.
It records meaningful agent events and generates evidence-based daily, weekly,
and monthly JSON plus static HTML without recreating the guest; see
[Automatic research journals](docs/journal.md).

The same command can resume interrupted finalization or replace a disposable
VM. A small removal helper remains available when removal without rebuilding
is wanted:

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
./setup-kvm-agent.sh --replace-existing --name kvm-agent
./setup-kvm-agent.sh --resize-existing --name kvm-agent --memory 24576 --vcpus 12
./remove-kvm-agent.sh
```

It does not remove the shared verified Ubuntu image cache, host packages, or
additional disks that a user attached manually.

## Architecture

```mermaid
flowchart TB
    H["Trusted Ubuntu host account"]
    M["virt-manager and system libvirt"]

    subgraph V["Disposable Ubuntu 26.04 desktop VM"]
        D["GNOME desktop and terminal"]
        A["Codex · Claude Code · OpenCode · Aider"]
        O["Ollama on 127.0.0.1"]
        F["Optional Lean · Isabelle/HOL · Haskell · VS Code"]
        D --> A
        D --> O
        D --> F
    end

    P["Chosen remote provider or local model"]

    H --> M
    M -->|"KVM + local SPICE console"| V
    A -->|"only after user configuration"| P
    O -->|"local weights or Ollama Cloud"| P
```

The GUI does not replace or bypass KVM: `virt-manager` is a graphical client
for the same system libvirt/KVM boundary. The host account remains trusted and
can control the VM. Coding agents are never installed on the host.

## Names used in commands

KVM-Agent uses several independent names. In documentation, every `YOUR_...`
word is a placeholder and every concrete sample name is labelled as an example.

| Name | Example | Used by |
|---|---|---|
| Libvirt VM name and guest hostname | `agent-research-a` | `--name`, `virsh`, `kvm-agent-host` |
| Guest login | `agent` | Linux and OpenSSH |
| Tailscale device name | `research-a-manager` | MagicDNS and Machines page |
| Composite Tailscale tag | `tag:swarm-research-a-manager` | Directional grants |
| Mac SSH alias | `research-a-manager` | `ssh` and `scp` on macOS |

The physical host's informal name is not an argument to `--name`. See
[Secure remote access](docs/remote-access.md#which-name-means-what) before
connecting several machines.

## What the script does

From the ordinary Ubuntu host account, the script:

1. installs KVM, libvirt, `virt-manager`, `virt-install`, and supporting Ubuntu
   packages with `sudo`;
2. adds that host account to the `libvirt` group;
3. starts libvirt's standard NAT network;
4. downloads Ubuntu 26.04's released amd64 cloud image and verifies it against
   Ubuntu's GPG-signed SHA-256 manifest;
5. asks for a local GUI password and creates a dedicated recovery SSH key;
6. creates a graphical VM with SPICE, virtio video, clipboard integration,
   an Ubuntu desktop, and no host directory share;
7. downloads and runs the official Codex, Claude Code, OpenCode, and Ollama
   installers inside the guest, and installs Aider in a per-user `uv`
   environment; and
8. when `--formal-methods` is selected, installs Lean through `elan`,
   Isabelle2025-2/HOL from its checksum-verified official Linux archive,
   GHC/Cabal/HLS through GHCup, HLint through Cabal, and VS Code with the
   official Lean and Haskell extensions;
9. when `--swarm-role` is selected, installs either Tailscale or WireGuard
   support, a dedicated manager SSH key and/or a locked-down non-sudo worker
   account, plus helpers for safe Tailscale naming, host-key verification,
   fixed SSH/rsync access, and remote-job lifecycle management; Tailscale
   authentication and manager-key authorization remain explicit human steps;
10. installs a host-side `kvm-agent-host` helper, a guest controller-key helper,
   and an OpenSSH baseline that denies password, root, agent, X11, tunnel, and
   port-forwarding access by default;
11. before any vendor installer runs, configures a guest firewall that denies
   unsolicited inbound traffic and, by default, outbound traffic to private
   and link-local address ranges, while leaving internet access open; and
12. verifies each command, keeps Ollama bound to guest loopback
   (`127.0.0.1:11434`), disables future cloud-init runs, and destroys the
   cloud-init seed once provisioning is done.

It deliberately does **not**:

- install an agent, Node.js package, Python agent package, or Ollama on the host;
- sign in to OpenAI, Anthropic, GitHub, Ollama Cloud, or another service;
- download Ollama model weights;
- mount the host home directory or a project directory in the guest;
- configure USB passthrough, SSH-agent forwarding, or a LAN-facing VM console;
- enroll a VM into Tailscale, configure WireGuard peers, or connect physical
  hosts to a swarm overlay;
- choose a model provider; or
- install Agda, Rocq/OCaml, HOL4, HOL Light, Mathlib, or the Archive of Formal
  Proofs.

The reduced formal-methods environment remains optional, so users who only
need an agent VM do not pay its download, disk, and provisioning cost.

## Requirements

The supported primary path is:

| Component | Supported configuration |
|---|---|
| Host | Ubuntu 24.04 or 26.04 LTS, x86-64 |
| Guest | Ubuntu 26.04 LTS, amd64 |
| Firmware | Intel VT-x or AMD-V enabled |
| Host privilege | The invoking account can use `sudo` |
| Network | Internet access during initial provisioning |
| Display | Local graphical Ubuntu session for `virt-manager` |
| Disk | 120 GiB guest virtual disk by default; at least 12 GiB free on the host, or 30 GiB with `--formal-methods` |
| Memory | Dynamically allocated: 75% of host RAM, capped at 32 GiB, while retaining at least 2 GiB for the host; at least 8 GiB is recommended |

The default memory is 75% of host RAM, capped at 32 GiB while retaining at
least 2 GiB for the host. The default vCPU count is 75% of the host's logical
CPUs, capped at 16. Thus a 16 GiB/8-thread host normally gives the guest about
12 GiB and 6 vCPUs, while a 64 GiB/32-thread host gives it 32 GiB and 16
vCPUs. Explicit `--memory` and `--vcpus` values still override these defaults.

## Guest release guarantee

New VMs are built from Ubuntu's released `ubuntu-26.04-server-cloudimg-amd64.img`.
The setup verifies the signed image manifest, passes `26.04` into early guest
provisioning, reads `/etc/os-release` again over the managed recovery channel,
and refuses final cleanup if the guest does not report Ubuntu 26.04. The
verified release is also recorded in
`/var/lib/kvm-agent/installed-versions.txt`.

Some Ubuntu 24.04 hosts have a `libosinfo` database that predates the
`ubuntu26.04` identifier. In that case the script clearly reports that it is
using `ubuntu24.04` only as compatible **virtual-hardware metadata** for
`virt-install`. This does not select or install Ubuntu 24.04: the disk URL,
signed checksum, early guest check, and final guest check all remain pinned to
26.04.

Updating this repository does not change an already-created VM. Check an
existing guest from the trusted Ubuntu host with:

```bash
kvm-agent-host ssh YOUR_VM_NAME cat /etc/os-release
```

If it reports 24.04, copy the work you intend to keep out of the VM and review
it before using `--replace-existing`, which deliberately deletes and recreates
the selected guest. Follow the guarded migration procedure in
[Troubleshooting](docs/troubleshooting.md#an-existing-guest-is-ubuntu-2404).

## Quick start

Download or clone this repository, then run:

```bash
cd YOUR_AGENT_VM_DIRECTORY
chmod +x setup-kvm-agent.sh
./setup-kvm-agent.sh
```

`YOUR_AGENT_VM_DIRECTORY` is a placeholder. A Git clone is normally named
`agent-vm`; a downloaded ZIP may extract as `agent-vm-main`.

Do **not** run `sudo ./setup-kvm-agent.sh`. Run it as the host account that will
use `virt-manager`; the script invokes `sudo` only for the operations that need
it.

The script asks for a password for the guest's `agent` account. This password is
for the local graphical login. SSH password login remains disabled. The account
has passwordless sudo inside the disposable guest so the agents can be highly
autonomous without receiving host privilege.

Initial provisioning commonly takes 20–60 minutes. Installing the desktop,
upgrading Ubuntu, or reaching upstream download services may take longer on a
slow machine. With `--formal-methods`, the large Isabelle, Lean, GHC, HLS, and
VS Code downloads plus the HLint build may take **several hours**. The host
terminal waits by default and enforces a six-hour upper bound for that profile.

When the script finishes, log out of the Ubuntu **host** and back in if it added
your account to `libvirt` for the first time. Then run:

```bash
virt-manager --connect qemu:///system
```

Double-click `kvm-agent`, open its graphical console, and log in as `agent` with
the password chosen during setup. In the guest terminal:

```bash
codex
claude
opencode
aider
ollama --version
```

Each coding agent performs its own first-run authentication or provider setup.
Do that only after reading [Credential handling](docs/credentials.md).

With `--formal-methods`, the same guest also supports:

```bash
code
lean --version
lake --version
isabelle jedit
ghc --version
cabal --version
haskell-language-server-wrapper --version
hlint --version
```

See [Reduced formal-methods environment](docs/formal-methods.md) for the exact
scope, editor behavior, and update model.

## Options

```text
--name NAME        Libvirt VM name and guest Linux hostname
                   (default for new VMs only: kvm-agent)
--user NAME        Guest login name (default: agent)
--memory MB        Guest RAM in MiB
--vcpus NUMBER     Guest virtual CPUs
--disk GB          Guest virtual disk size (default: 120)
--no-wait          Return after starting the VM
--allow-lan        Permit egress to private/link-local address ranges; UFW
                   remains enabled and continues to deny unsolicited inbound
                   traffic. Only for an internal mirror or model endpoint
--formal-methods   Add Lean, Isabelle/HOL, Haskell tooling, VS Code, and the
                   official Lean/Haskell extensions inside the guest
--allow-remote-editor
                   Opt in to client-initiated local SSH forwarding for a
                   remote editor; agent and X11 forwarding stay disabled
--swarm-role ROLE  Prepare the guest as "manager", "worker", or "both"
--swarm-network N  Use "tailscale" (default) or "wireguard" for swarm traffic
--add-swarm ROLE   Add a swarm role to an already-provisioned managed VM
--add-journal      Add automatic research journals to an existing managed VM
--harden-existing  Reapply the current SSH baseline to a named existing VM
--journal-project P
                   Initialize guest-side Git project P; may be repeated
--journal-backend B
                   Use evidence (default), claude, or codex reporting
--journal-allow-remote-reporting
                   Consent to sending bounded project metadata to the selected
                   claude/codex provider; required for either remote backend
--journal-timezone Z
                   Use IANA timezone Z (default: Etc/UTC)
--resize-existing  Change persistent RAM and/or vCPU allocation of a powered-
                   off existing VM without deleting it
--replace-existing Remove the selected existing VM after exact-name
                   confirmation, then build it again
--finalize-existing
                   Resume verified final cleanup of an existing VM
```

The 120 GiB default is a guest-visible maximum, not 120 GiB allocated
immediately on the host: qcow2 grows as the guest writes data. Before any
large installation, setup explicitly grows and verifies the root partition
and filesystem. It also keeps 512 MiB of emergency space during provisioning
so a failed download or package build can release that space instead of
leaving the graphical login unusable. The host must have at least 12 GiB free
for the base profile or 30 GiB for `--formal-methods`; setup checks this before
`--replace-existing` removes the old VM.

Large installers and archives, including the Isabelle distribution, are staged
in a protected directory on the guest root filesystem. They are not stored in
Ubuntu's RAM-backed `/run` filesystem, and partial downloads are removed
automatically on failure.

`--no-wait` returns before provisioning finishes, so it cannot immediately
remove the cloud-init seed or disable future cloud-init runs. Complete those
steps later with the repository helper; it waits for successful provisioning,
verifies the guest marker, disables cloud-init, performs any required update
reboot, proves that a new boot completed, rediscovers a changed DHCP address,
and removes the seed:

```bash
./setup-kvm-agent.sh --finalize-existing --name NAME
```

For example:

```bash
./setup-kvm-agent.sh \
  --name agent-project-01 \
  --memory 16384 \
  --vcpus 8 \
  --formal-methods
```

VM names use lowercase letters, numbers, and hyphens. By default, the script
refuses to replace an existing libvirt domain or disk. `--replace-existing`
shows the exact removal plan, requires the VM name to be typed, retains the
shared Ubuntu cache and any manually attached extra disks, then rebuilds.

## Change RAM or vCPUs without rebuilding

Memory and vCPU allocation can be changed without deleting the VM or its disk.
Shut the guest down normally, then run, for example:

```bash
./setup-kvm-agent.sh \
  --resize-existing \
  --name kvm-agent \
  --memory 24576 \
  --vcpus 12
```

Either `--memory` or `--vcpus` may be omitted. The helper changes the persistent
libvirt configuration and the new values apply at the next start. It refuses a
running VM, a VM with a managed-save image, RAM that leaves less than 2 GiB for
the host, or more vCPUs than the host reports. If virt-manager/libvirt has saved
the running state, start the VM and perform a normal full shutdown first; this
prevents an old saved state from restoring the previous resource configuration.
No guest filesystem, cloud-init state, or project data is changed. A vCPU count
is the number of virtual logical CPUs visible to the
guest, not a guaranteed exclusive CPU quota; host scheduling still determines
actual execution time.

Libvirt can sometimes hot-plug resources into specially prepared running
guests, but increasing maximum memory or CPU topology live is not uniformly
supported. KVM-Agent therefore uses the predictable powered-off path instead.

## Optional cross-host manager/worker VMs

Most users can ignore this feature. `--swarm-role manager|worker|both` prepares
an initial VM, and `--add-swarm` adds a role later; these roles do not rename
the VM, so separate hosts may both keep the default name `kvm-agent`. Tailscale
is the default and raw WireGuard is optional. Provisioning does not enroll
devices or authorize peers automatically. Read
[Cross-host manager/worker VMs](docs/swarm.md) before enabling it, including the
directional-access and risk guidance.

## Automatic research journals for existing VMs

To retrofit an already-provisioned, running VM from its physical host:

```bash
./setup-kvm-agent.sh \
  --add-journal \
  --name kvm-agent \
  --journal-project /home/agent/YOUR_PROJECT
```

`YOUR_PROJECT` is a placeholder, and the path is inside the guest. Repeat
`--journal-project` for multiple
repositories in the same VM. This operation does not rebuild the guest. It
adds agent-neutral event instructions, canonical JSON plus static HTML
reports, and persistent 07:00 daily, Saturday weekly, and first-of-month
timers. The safe default is deterministic evidence-only reporting with no
model-provider data transfer. Remote Claude/Codex enrichment is an explicit
opt-in with a separate consent flag and falls back to evidence-only on failure.
OpenCode agents may record events but are not used as unattended reporters.
Read
[Automatic research journals](docs/journal.md) for the layout, event commands,
security boundary, and backend behavior.

## Resume interrupted finalization

If setup reports that the guest did not become reachable after its update
reboot, but the desktop and tools work, do not recreate the VM and do not type
the individual SSH and `virsh` cleanup commands. Run:

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
```

The helper verifies `/var/lib/kvm-agent/provisioned` through the recovery key
before changing cloud-init or touching the seed. It creates and verifies the
cloud-init disable marker before requesting an update reboot. Because
`systemctl reboot` is asynchronous, a successful SSH connection alone is not
accepted as proof that reboot finished: the helper waits for the kernel boot ID
to change and re-queries libvirt DHCP leases instead of trusting the pre-reboot
address. It then verifies both the running and persistent device configurations
before deleting the exact managed seed file. SSH and cloud-init checks are
polled without `cloud-init status --wait`; each SSH invocation has a hard
deadline, so a connected but blocked guest cannot make the helper hang
indefinitely. It is also the supported completion path after `--no-wait`.

## Completely remove a VM

Shut the guest down normally, then run:

```bash
./remove-kvm-agent.sh --name kvm-agent
```

The helper displays the libvirt domain, attached storage, exact managed image
paths, recovery SSH directory, and log it will remove. Type the exact VM name
to confirm. It removes the domain, its main disk, any leftover cloud-init seed,
and its host-side recovery data. It retains the verified Ubuntu base-image
cache and virtualization packages, so a later rebuild does not repeat the
host installation or image download.

Use `--dry-run` to inspect the plan. The helper refuses to remove a running VM;
shut it down first, or use `--force` only when accepting the same filesystem
corruption risk as pulling a physical machine's power cable. Extra storage
attached manually is reported but never deleted automatically.

## Daily use

Use `virt-manager` to start, stop, pause, clone, snapshot, resize, and view the
guest. Full-screen mode makes it feel like an ordinary second Ubuntu machine.
The VM is not configured to start automatically with the host.

A good working cycle is:

1. create or restore a clean snapshot;
2. place only the project data and revocable credentials needed for this task
   in the guest;
3. run the agent and review its commits or patch;
4. export the reviewed result; and
5. discard with `remove-kvm-agent.sh`, or roll back the VM, when its state is
   no longer trusted.

See [Daily operation](docs/daily-use.md) for snapshots, updates, SSH recovery,
and data transfer.

### Transfer files between the host and guest

The VM has a separate filesystem and no shared host directory. Setup installs a
host helper with the recovery key, current-address discovery, host-key pinning,
and all forwarding disabled. On the physical Ubuntu host, send a project with:

```bash
kvm-agent-host push kvm-agent ./my-project Work/
```

Pull a result into the automatically created quarantine directory:

```bash
kvm-agent-host pull kvm-agent Work/agent-result.patch
```

Replace `kvm-agent` with the real libvirt VM name. The helper initiates both
directions from the trusted host; never copy its private recovery key into the
guest or enable SSH-agent forwarding. Pulls strip executable permission and
refuse device, special, and symbolic-link entries before placing data
in quarantine.

For a separate trusted Mac, including a hardened `~/.ssh/config`, dedicated
key, Tailscale roles, and Mac-initiated `scp`, follow
[Secure access from an Ubuntu host or macOS controller](docs/remote-access.md).

Treat anything copied out of a potentially compromised guest as untrusted.
Review it in a quarantine directory before executing it, building it, opening
it as an IDE workspace, or moving it into an important repository. A small
reviewable patch is preferable to copying an entire working tree. For stronger
assurance, shut the guest down and extract from its virtual disk read-only
instead; see [Daily operation](docs/daily-use.md).

## Important security limits

KVM sharply reduces the consequences of an agent mistake, but it is not a proof
of safety. A compromised guest can read everything placed in that guest, use
its network connection and provider credentials, attack the hypervisor, and
present malicious text or clipboard content to the host user.

The default VM has outbound internet access because provisioning and remote
model providers require it. It has no port forwarded from the LAN, and its own
firewall blocks private and link-local destination ranges. This normally covers
the libvirt host, other guests, and a physical LAN; locally routed public
addresses are not covered. The host can still reach the guest on libvirt's
private network. That firewall lives inside the guest, so an agent with sudo
can remove it — see
[SECURITY.md](SECURITY.md) for what is enforced outside the guest and what is
only a default. The SPICE console has no TCP listener; `virt-manager` reaches it
through libvirt. SPICE clipboard integration is enabled for usability, so do not
move secrets through the clipboard.

The host account that runs `virt-manager` holds `libvirt` group membership,
which is equivalent to host root. On Ubuntu that authority is ambient and cannot
be downgraded to a per-session prompt without reconfiguring libvirt's socket
authentication, so prefer a dedicated VM host over a machine that is also your
browsing and mail workstation. See [SECURITY.md](SECURITY.md).

The installer URLs intentionally follow the current official release channels.
That makes the one-script workflow maintainable but not bit-for-bit
reproducible. Those installers still run only inside an empty, credential-free
guest. Organizations that require exact artifact review should replace the
moving installers with an internally approved golden image or pinned bundle.

Read [SECURITY.md](SECURITY.md) before adding confidential source code,
long-lived keys, production data, or expensive API credentials.

## Documentation

- [Security policy and threat model](SECURITY.md)
- [Design and trust boundaries](docs/design.md)
- [Daily operation](docs/daily-use.md)
- [Secure access from an Ubuntu host or macOS controller](docs/remote-access.md)
- [Credential handling](docs/credentials.md)
- [Agent tools and model services](docs/agent-tools-and-model-services.md)
- [Reduced formal-methods environment](docs/formal-methods.md)
- [Cross-host manager/worker VMs](docs/swarm.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Primary upstream references](docs/references.md)
- [Disclaimer](DISCLAIMER.md)

## Status

This is an experimental reference implementation, not an independently audited
security product. The script has static and mocked workflow tests in this
repository; creating a real VM still depends on host firmware, Ubuntu mirrors,
libvirt, and moving third-party installers. Report failures with the host
release, script options, `cloud-init status --long`, and the relevant tail of
`/var/log/kvm-agent-provision.log` or `/var/log/kvm-agent-swarm.log`.
