# Primary upstream references

[日本語版](references_jp.md)

This project links primary upstream documentation rather than treating its own
summary as permanent truth. Installation interfaces, supported Ubuntu releases,
provider routes, and security behavior can change.

Last reviewed: 2026-07-30.

## Ubuntu, KVM, libvirt, and cloud-init

- [Ubuntu: Introduction to virtualization](https://ubuntu.com/server/docs/explanation/intro-to/virtualisation/)
- [Ubuntu: libvirt](https://ubuntu.com/server/docs/how-to/virtualisation/libvirt/)
- [Ubuntu: Virtual Machine Manager](https://ubuntu.com/server/docs/how-to/virtualisation/virtual-machine-manager/)
- [Ubuntu: GPU virtualization and graphics concepts](https://ubuntu.com/server/docs/how-to/graphics/gpu-virtualization-with-qemu-kvm/)
- [Ubuntu released cloud images](https://cloud-images.ubuntu.com/releases/)
- [Ubuntu 24.04 LTS released cloud image directory](https://cloud-images.ubuntu.com/releases/24.04/release/)
- [cloud-init: NoCloud data source](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
- [cloud-init: users and groups](https://docs.cloud-init.io/en/latest/reference/yaml_examples/user_groups.html)
- [cloud-init: growpart and resizefs modules](https://docs.cloud-init.io/en/latest/reference/modules.html)
- [virt-install Ubuntu manpage](https://manpages.ubuntu.com/manpages/noble/man1/virt-install.1.html)

## Future cloud storage adapters

- [AWS: Amazon EBS volume types and size ranges](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [AWS: Amazon EBS pricing](https://aws.amazon.com/ebs/pricing/)
- [Sakura Cloud: server and disk creation](https://manual.sakura.ad.jp/cloud/server/create-delete.html)
- [Sakura Cloud: documented SSD disk sizes](https://manual.sakura.ad.jp/cloud/storage/disk-migration.html)

These links inform future adapters only. The current release provisions local
KVM/libvirt guests and does not create AWS or Sakura resources.

## Installed agent and model tools

- [OpenAI: Codex CLI](https://developers.openai.com/codex/cli)
- [Anthropic: Claude Code setup](https://docs.anthropic.com/en/docs/claude-code/setup)
- [OpenCode documentation](https://opencode.ai/docs/)
- [Aider installation](https://aider.chat/docs/install.html)
- [Ollama Linux download](https://ollama.com/download)

These are the installation origins used by `setup-kvm-agent.sh`. The script
downloads them from inside the guest.

## Optional formal-methods and editor environment

- [Lean installation](https://lean-lang.org/install/)
- [elan: Lean version manager](https://github.com/leanprover/elan)
- [Lean 4 VS Code extension](https://marketplace.visualstudio.com/items?itemName=leanprover.lean4)
- [Isabelle current release](https://isabelle.in.tum.de/)
- [Isabelle installation](https://isabelle.in.tum.de/installation.html)
- [Isabelle2025-2 NEWS](https://www.cl.cam.ac.uk/research/hvg/Isabelle/dist/Isabelle2025-2/doc/NEWS.html)
- [GHCup installation](https://www.haskell.org/ghcup/install/)
- [GHCup user guide](https://www.haskell.org/ghcup/guide/)
- [Haskell VS Code extension](https://marketplace.visualstudio.com/items?itemName=haskell.haskell)
- [Visual Studio Code on Linux](https://code.visualstudio.com/docs/setup/linux)

The reduced profile follows current official channels for Lean, Haskell, VS
Code, and extensions. Isabelle2025-2 is selected explicitly and its official
Linux archive is checksum-verified. See
[Reduced formal-methods environment](formal-methods.md).

## Optional cross-host manager/worker networking

- [Tailscale installation on Linux](https://tailscale.com/docs/install/linux)
- [Tailscale grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale routing features](https://tailscale.com/docs/route)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
- [libvirt virsh command reference](https://www.libvirt.org/manpages/virsh.html)
- [OpenSSH server configuration](https://man.openbsd.org/sshd_config)

The optional swarm profile installs an overlay client inside the guests and
continues to use ordinary OpenSSH for command execution and file transfer. The
physical hosts are not enrolled automatically. Persistent memory and vCPU
changes use libvirt's configuration operations on a powered-off domain. See
[Optional cross-host manager/worker VMs](swarm.md).

## Provider configuration

- [Codex configuration](https://developers.openai.com/codex/config-reference)
- [Claude Code model configuration](https://docs.anthropic.com/en/docs/claude-code/model-config)
- [OpenCode providers](https://opencode.ai/docs/providers/)
- [Aider LLM configuration](https://aider.chat/docs/llms.html)
- [Aider with Ollama](https://aider.chat/docs/llms/ollama.html)
- [Ollama documentation](https://docs.ollama.com/)

For the optional journal reporter, Codex follows the official
[non-interactive mode](https://developers.openai.com/codex/non-interactive-mode) and
[AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md)
interfaces. Claude follows its official
[programmatic mode](https://code.claude.com/docs/en/headless) and
[CLI tool controls](https://code.claude.com/docs/en/cli-reference). OpenCode is
not used as an unattended journal reporter.

Provider compatibility is not inferred merely from an OpenAI-like URL. Consult
the current documentation for the client and service, then test the exact
agentic workflow.

## Scope of citation

An upstream link supports only the nearby technical statement. It does not mean
that Ubuntu, OpenAI, Anthropic, OpenCode, Aider, Ollama, or another linked
organization endorses this repository or its security analysis.
