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

The repository now has one provisioning script:

```bash
./setup-kvm-agent.sh
```

The script installs the host virtualization stack, authenticates an official
Ubuntu cloud image, creates the VM, installs a minimal Ubuntu desktop, installs
the five requested tools, and waits for the result. Day-to-day operation happens
through the familiar `virt-manager` GUI.

## Architecture

```mermaid
flowchart TB
    H["Trusted Ubuntu host account"]
    M["virt-manager and system libvirt"]

    subgraph V["Disposable Ubuntu 24.04 desktop VM"]
        D["GNOME desktop and terminal"]
        A["Codex · Claude Code · OpenCode · Aider"]
        O["Ollama on 127.0.0.1"]
        D --> A
        D --> O
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

## What the script does

From the ordinary Ubuntu host account, the script:

1. installs KVM, libvirt, `virt-manager`, `virt-install`, and supporting Ubuntu
   packages with `sudo`;
2. adds that host account to the `libvirt` group;
3. starts libvirt's standard NAT network;
4. downloads Ubuntu 24.04's released amd64 cloud image and verifies it against
   Ubuntu's GPG-signed SHA-256 manifest;
5. asks for a local GUI password and creates a dedicated recovery SSH key;
6. creates a graphical VM with SPICE, virtio video, clipboard integration,
   an Ubuntu desktop, and no host directory share;
7. downloads and runs the official Codex, Claude Code, OpenCode, and Ollama
   installers inside the guest, and installs Aider in a per-user `uv`
   environment; and
8. before any vendor installer runs, configures a guest firewall that denies
   unsolicited inbound traffic and, by default, outbound traffic to private
   and link-local address ranges, while leaving internet access open; and
9. verifies each command, keeps Ollama bound to guest loopback
   (`127.0.0.1:11434`), disables future cloud-init runs, and destroys the
   cloud-init seed once provisioning is done.

It deliberately does **not**:

- install an agent, Node.js package, Python agent package, or Ollama on the host;
- sign in to OpenAI, Anthropic, GitHub, Ollama Cloud, or another service;
- download Ollama model weights;
- mount the host home directory or a project directory in the guest;
- configure USB passthrough, SSH-agent forwarding, or a LAN-facing VM console;
- choose a model provider; or
- install the former `formal_methods` profile.

Formal-methods tools are project-specific and can be installed manually inside
a VM that needs them. Users who only need an agent environment no longer pay
their maintenance or provisioning cost.

## Requirements

The supported primary path is:

| Component | Supported configuration |
|---|---|
| Host | Ubuntu 24.04 or 26.04 LTS, x86-64 |
| Guest | Ubuntu 24.04 LTS, amd64 |
| Firmware | Intel VT-x or AMD-V enabled |
| Host privilege | The invoking account can use `sudo` |
| Network | Internet access during initial provisioning |
| Display | Local graphical Ubuntu session for `virt-manager` |
| Disk | At least 50 GiB free; 80 GiB or more recommended |
| Memory | 8 GiB guest recommended; keep at least 2 GiB for the host |

The default memory is half of host RAM, clamped to 8–16 GiB. The default vCPU
count is half of the host CPUs, clamped to 2–8. A 16 GiB host therefore gets an
8 GiB VM, while a 32 GiB host gets a 16 GiB VM.

## Quick start

Download or clone this repository, then run:

```bash
cd kvm-agent
chmod +x setup-kvm-agent.sh
./setup-kvm-agent.sh
```

Do **not** run `sudo ./setup-kvm-agent.sh`. Run it as the host account that will
use `virt-manager`; the script invokes `sudo` only for the operations that need
it.

The script asks for a password for the guest's `agent` account. This password is
for the local graphical login. SSH password login remains disabled. The account
has passwordless sudo inside the disposable guest so the agents can be highly
autonomous without receiving host privilege.

Initial provisioning commonly takes 20–60 minutes. Installing the desktop,
upgrading Ubuntu, or reaching upstream download services may take longer on a
slow machine. The terminal shows the current phase and waits by default.

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

## Options

```text
--name NAME        VM and host name (default: kvm-agent)
--user NAME        Guest login name (default: agent)
--memory MB        Guest RAM in MiB
--vcpus NUMBER     Guest virtual CPUs
--disk GB          Guest virtual disk size (default: 80)
--no-wait          Return after starting the VM
--allow-lan        Permit egress to private/link-local address ranges; UFW
                   remains enabled and continues to deny unsolicited inbound
                   traffic. Only for an internal mirror or model endpoint
```

`--no-wait` returns before provisioning finishes, so the cloud-init seed — which
holds the guest password hash — is not cleaned up and future cloud-init runs are
not disabled on that path. After the provisioning marker appears, run
`sudo install -o root -g root -m 0644 /dev/null /etc/cloud/cloud-init.disabled`
inside the guest. Then remove
`/var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img` yourself, after ejecting
it in virt-manager, once the VM has settled.

For example:

```bash
./setup-kvm-agent.sh \
  --name agent-project-01 \
  --memory 16384 \
  --vcpus 8 \
  --disk 120
```

VM names use lowercase letters, numbers, and hyphens. The script refuses to
replace an existing libvirt domain or disk.

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
5. discard or roll back the VM when its state is no longer trusted.

See [Daily operation](docs/daily-use.md) for snapshots, updates, SSH recovery,
and data transfer.

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
- [Credential handling](docs/credentials.md)
- [Agent tools and model services](docs/agent-tools-and-model-services.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Primary upstream references](docs/references.md)
- [Disclaimer](DISCLAIMER.md)

## Status

This is an experimental reference implementation, not an independently audited
security product. The script has static and mocked workflow tests in this
repository; creating a real VM still depends on host firmware, Ubuntu mirrors,
libvirt, and moving third-party installers. Report failures with the host
release, script options, `cloud-init status --long`, and the relevant tail of
`/var/log/kvm-agent-provision.log`.
