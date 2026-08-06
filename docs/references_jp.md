# 上流の一次資料

[English](references.md)

この project は、自分の要約を永続的事実と扱わず、上流の一次文書へ link します。
Installation interface、対応 Ubuntu release、provider route、security behavior は
変化します。

最終確認: 2026-07-30。

## Ubuntu、KVM、libvirt、cloud-init

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

## 将来の cloud storage adapter

- [AWS: Amazon EBS volume type と size 範囲](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-volume-types.html)
- [AWS: Amazon EBS pricing](https://aws.amazon.com/ebs/pricing/)
- [さくらのクラウド: server・disk 作成](https://manual.sakura.ad.jp/cloud/server/create-delete.html)
- [さくらのクラウド: 文書化された SSD disk size](https://manual.sakura.ad.jp/cloud/storage/disk-migration.html)

これらは将来の adapter のための資料です。現在の release は local KVM/libvirt guest
だけを provision し、AWS やさくらの resource は作成しません。

## 導入する agent/model tool

- [OpenAI: Codex CLI](https://developers.openai.com/codex/cli)
- [Anthropic: Claude Code setup](https://docs.anthropic.com/en/docs/claude-code/setup)
- [OpenCode documentation](https://opencode.ai/docs/)
- [Aider installation](https://aider.chat/docs/install.html)
- [Ollama Linux download](https://ollama.com/download)

これらが `setup-kvm-agent.sh` の installation origin です。Script は guest 内から
download します。

## 任意の形式手法・editor 環境

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

縮小 profile は Lean、Haskell、VS Code、extension について現在の公式 channel に
従います。Isabelle2025-2 は明示選択し、公式 Linux archive の checksum を検証します。
[縮小形式手法環境](formal-methods_jp.md)も参照してください。

## 任意の cross-host manager/worker network

- [Tailscale の Linux への導入](https://tailscale.com/docs/install/linux)
- [Tailscale grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale routing feature](https://tailscale.com/docs/route)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
- [libvirt virsh command reference](https://www.libvirt.org/manpages/virsh.html)
- [OpenSSH server configuration](https://man.openbsd.org/sshd_config)

任意の swarm profile は overlay client を guest 内へ導入し、command 実行と file
transfer には通常の OpenSSH を引き続き使います。物理 host は自動 enrollment しません。
永続 memory・vCPU 変更は powered-off domain に対する libvirt configuration operation
を使います。[任意の cross-host manager/worker VM](swarm_jp.md)も参照してください。

## Provider 設定

- [Codex configuration](https://developers.openai.com/codex/config-reference)
- [Claude Code model configuration](https://docs.anthropic.com/en/docs/claude-code/model-config)
- [OpenCode providers](https://opencode.ai/docs/providers/)
- [Aider LLM configuration](https://aider.chat/docs/llms.html)
- [Aider with Ollama](https://aider.chat/docs/llms/ollama.html)
- [Ollama documentation](https://docs.ollama.com/)

任意の journal reporter では、Codex は公式
[non-interactive mode](https://developers.openai.com/codex/non-interactive-mode) と
[AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md)、
Claude は公式 [programmatic mode](https://code.claude.com/docs/en/headless) と
[CLI tool control](https://code.claude.com/docs/en/cli-reference) に従います。
OpenCode は unattended journal reporter には使いません。

OpenAI に似た URL だけで provider compatibility を推定しません。Client と service の
現在の文書を確認し、正確な agent workflow を test します。

## 引用の範囲

上流 link が支えるのは近接する技術的記述だけです。Ubuntu、OpenAI、Anthropic、
OpenCode、Aider、Ollama その他の link 先組織が、この repository や security 分析を
推奨していることを意味しません。
