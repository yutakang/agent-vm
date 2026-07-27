# Primary upstream references

[日本語版](references_jp.md)

This project links primary upstream documentation rather than treating its own
summary as permanent truth. Installation interfaces, supported Ubuntu releases,
provider routes, and security behavior can change.

Last reviewed: 2026-07-28.

## Ubuntu, KVM, libvirt, and cloud-init

- [Ubuntu: Introduction to virtualization](https://ubuntu.com/server/docs/explanation/intro-to/virtualisation/)
- [Ubuntu: libvirt](https://ubuntu.com/server/docs/how-to/virtualisation/libvirt/)
- [Ubuntu: Virtual Machine Manager](https://ubuntu.com/server/docs/how-to/virtualisation/virtual-machine-manager/)
- [Ubuntu: GPU virtualization and graphics concepts](https://ubuntu.com/server/docs/how-to/graphics/gpu-virtualization-with-qemu-kvm/)
- [Ubuntu released cloud images](https://cloud-images.ubuntu.com/releases/)
- [Ubuntu 24.04 LTS released cloud image directory](https://cloud-images.ubuntu.com/releases/24.04/release/)
- [cloud-init: NoCloud data source](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
- [cloud-init: users and groups](https://docs.cloud-init.io/en/latest/reference/yaml_examples/user_groups.html)
- [virt-install Ubuntu manpage](https://manpages.ubuntu.com/manpages/noble/man1/virt-install.1.html)

## Installed agent and model tools

- [OpenAI: Codex CLI](https://developers.openai.com/codex/cli)
- [Anthropic: Claude Code setup](https://docs.anthropic.com/en/docs/claude-code/setup)
- [OpenCode documentation](https://opencode.ai/docs/)
- [Aider installation](https://aider.chat/docs/install.html)
- [Ollama Linux download](https://ollama.com/download)

These are the installation origins used by `setup-kvm-agent.sh`. The script
downloads them from inside the guest.

## Provider configuration

- [Codex configuration](https://developers.openai.com/codex/config-reference)
- [Claude Code model configuration](https://docs.anthropic.com/en/docs/claude-code/model-config)
- [OpenCode providers](https://opencode.ai/docs/providers/)
- [Aider LLM configuration](https://aider.chat/docs/llms.html)
- [Aider with Ollama](https://aider.chat/docs/llms/ollama.html)
- [Ollama documentation](https://docs.ollama.com/)

Provider compatibility is not inferred merely from an OpenAI-like URL. Consult
the current documentation for the client and service, then test the exact
agentic workflow.

## Scope of citation

An upstream link supports only the nearby technical statement. It does not mean
that Ubuntu, OpenAI, Anthropic, OpenCode, Aider, Ollama, or another linked
organization endorses this repository or its security analysis.

