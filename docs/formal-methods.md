# Reduced formal-methods environment

[日本語版](formal-methods_jp.md)

The optional profile deliberately restores only the tools requested for the
current research workflow. It runs inside the same graphical VM created and
managed through `virt-manager`; it does not restore the older multi-script VM,
Remote-SSH, offline-bundle, or profile-selection architecture.

## Install it

For a new VM:

```bash
./setup-kvm-agent.sh \
  --name kvm-agent \
  --formal-methods
```

To discard an existing disposable VM and rebuild it with the profile:

```bash
./setup-kvm-agent.sh \
  --replace-existing \
  --name kvm-agent \
  --formal-methods
```

`--replace-existing` shows the exact removal plan and requires the VM name to
be typed before deletion. It keeps the shared verified Ubuntu image cache and
manually attached extra disks.

`--formal-methods` affects creation, not `--finalize-existing`. Setup records
the selected mode with the recovery data, so a later
`--finalize-existing --name kvm-agent` automatically uses the longer
formal-methods wait without needing the flag again.

## Exact scope

| Area | Installed component | Route |
|---|---|---|
| Lean | `elan`, a stable Lean 4 toolchain, `lean`, and `lake` | Official elan installer; projects may select another toolchain through `lean-toolchain` |
| Isabelle | Isabelle2025-2 with HOL, including Isabelle/jEdit and Isabelle/VSCode | Official Cambridge HTTPS mirror; fixed SHA-256 checked before extraction |
| Haskell | GHCup, recommended GHC and Cabal, Haskell Language Server, and HLint | Official GHCup bootstrap; HLint installed through Cabal |
| Editor | Stable Microsoft VS Code | Official amd64 Debian package |
| Extensions | `leanprover.lean4` and `haskell.haskell` | VS Code Marketplace through the guest-side `code` CLI |

It intentionally does **not** install Agda, Rocq, OCaml, HOL4, HOL Light,
Mathlib, the Archive of Formal Proofs, Stack, or unrelated VS Code extension
packs. Project libraries remain project dependencies rather than VM
provisioning dependencies.

## Time and resources

This option may add **several hours** to the first provisioning run. The large
Isabelle, Lean, GHC, HLS, and VS Code downloads are followed by a Cabal build
of HLint. Eight GiB of guest RAM is adequate for installation and small work;
16 GiB is preferable for larger Isabelle sessions or parallel builds.

The 120 GiB default leaves substantial headroom for project-specific Lean
packages, Haskell build stores, Isabelle sessions, and agent workspaces.
Ordinary Isabelle/HOL, Lean, and Haskell work with the reduced profile normally
needs much less than 120 GiB; Mathlib, AFP, large model weights, and project
datasets are not downloaded automatically.

The disk is thin-provisioned locally. Setup verifies at least 30 GiB of free
host backing space before replacing an existing formal-methods VM, then grows
and checks the guest root filesystem before package installation. This check
prevents a nominally 120 GiB qcow2 device from silently retaining the small
root filesystem of the source cloud image.

The Isabelle archive is downloaded to a protected staging directory on the
guest root filesystem. Ubuntu mounts `/run` as a comparatively small
RAM-backed filesystem, so it is deliberately not used for this 1+ GiB
download. The staging directory is removed after installation or on failure.

The host-side wait is bounded at six hours for this profile. If `--no-wait`
was used or the terminal was interrupted, finish through the same setup
command:

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
```

Do not type individual SSH or `virsh` cleanup commands. The integrated
finalizer verifies successful provisioning before disabling cloud-init or
removing the seed.

## Daily use in `virt-manager`

Log in to the graphical guest as its ordinary user. VS Code is installed in
the guest itself, so it can be opened from the desktop or with:

```bash
code
```

Check the tools from a new guest terminal:

```bash
lean --version
lake --version
isabelle version
ghc --version
cabal --version
haskell-language-server-wrapper --version
hlint --version
code --list-extensions
```

For Isabelle/HOL, the normal interface is:

```bash
isabelle jedit
```

Isabelle also supplies its own VSCode environment:

```bash
isabelle vscode
```

That command uses Isabelle's bundled VSCodium-based integration. The script
does not install an unrelated Marketplace extension into Microsoft VS Code.
Microsoft VS Code is provisioned for Lean and Haskell, while Isabelle/jEdit
remains the conservative default for Isabelle work.

## Versions and trust

Isabelle2025-2 is explicitly selected and its Linux archive is verified against
the reviewed SHA-256 value. Lean follows elan's stable channel, while GHCup
chooses its recommended GHC/Cabal/HLS releases; HLint and the two editor
extensions follow their current package channels. The resulting environment is
convenient and project-aware, but not bit-for-bit reproducible.

As with the coding-agent installers, these downloads run only inside the empty
guest, before provider credentials are added. For an organization requiring
fully pinned transitive dependencies, promote a reviewed VM image or replace
the moving channels with an internally maintained bundle.

Primary installation sources are collected in [References](references.md).
