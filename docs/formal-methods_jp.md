# 縮小形式手法環境

[English](formal-methods.md)

この任意 profile は、現在の研究 workflow で要求された tool だけを戻します。
`virt-manager` から管理する同じ GUI 付き VM の内部で動き、旧 repository の
multi-script VM、Remote-SSH、offline bundle、profile 選択 architecture は
復活させません。

## 導入

新しい VM:

```bash
./setup-kvm-agent.sh \
  --name kvm-agent \
  --disk 120 \
  --formal-methods
```

既存の交換可能な VM を破棄し、この profile 付きで再作成:

```bash
./setup-kvm-agent.sh \
  --replace-existing \
  --name kvm-agent \
  --disk 120 \
  --formal-methods
```

`--replace-existing` は削除対象を正確に表示し、削除前に VM 名の手入力を
要求します。共有の検証済み Ubuntu image cache と、利用者が手動追加した
extra disk は残します。

`--formal-methods` は作成時の option であり、`--finalize-existing` の option
ではありません。Setup は選択 mode を recovery data とともに記録するため、
後で `--finalize-existing --name kvm-agent` を実行すると、flag を再指定せずに
形式手法用の長い待機時間を自動選択します。

## 正確な対象

| 分野 | 導入する component | 経路 |
|---|---|---|
| Lean | `elan`、stable Lean 4 toolchain、`lean`、`lake` | 公式 elan installer。各 project は `lean-toolchain` で別版を選択可能 |
| Isabelle | HOL を含む Isabelle2025-2、Isabelle/jEdit、Isabelle/VSCode | 公式 Cambridge HTTPS mirror。展開前に固定 SHA-256 を検証 |
| Haskell | GHCup、推奨 GHC/Cabal、Haskell Language Server、HLint | 公式 GHCup bootstrap。HLint は Cabal から導入 |
| Editor | Stable Microsoft VS Code | 公式 amd64 Debian package |
| Extension | `leanprover.lean4` と `haskell.haskell` | Guest 内の `code` CLI から VS Code Marketplace |

Agda、Rocq、OCaml、HOL4、HOL Light、Mathlib、Archive of Formal Proofs、
Stack、無関係な VS Code extension pack は意図的に導入しません。Project library は
VM provisioning dependency ではなく、各 project の dependency とします。

## 時間と resource

この option は初回 provisioning に**数時間**を追加する場合があります。
Isabelle、Lean、GHC、HLS、VS Code の大きな download 後、Cabal で HLint を
build します。Guest RAM 8 GiB でも導入と小規模作業はできますが、大きな
Isabelle session や並列 build には 16 GiB を推奨します。

既定 80 GiB disk に基本 tool は入りますが、project 固有 Lean package、
Haskell build store、Isabelle session、agent workspace のため 100～120 GiB を
推奨します。Mathlib と AFP は自動 download しません。

この profile の host-side wait 上限は 6 時間です。`--no-wait` を使った場合や
terminal を中断した場合は、同じ setup command で完了させます。

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
```

個別の SSH や `virsh` cleanup command は手入力しません。統合 finalizer は
provisioning 成功を検証してから cloud-init を無効化し、seed を削除します。

## `virt-manager` での日常利用

通常 user として GUI guest へ login します。VS Code は guest 自体に導入される
ため、desktop または次の command から起動できます。

```bash
code
```

新しい guest terminal で確認:

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

Isabelle/HOL の通常 interface:

```bash
isabelle jedit
```

Isabelle 自身の VSCode environment もあります。

```bash
isabelle vscode
```

これは Isabelle に bundled された VSCodium-based integration を使います。
Script は無関係な Marketplace extension を Microsoft VS Code へ導入しません。
Microsoft VS Code は Lean/Haskell 用に provision し、Isabelle では
Isabelle/jEdit を保守的な既定とします。

## Version と trust

Isabelle2025-2 を明示的に選択し、Linux archive を review 済み SHA-256 と
照合します。Lean は elan の stable channel、GHCup は推奨 GHC/Cabal/HLS、
HLint と二つの editor extension は現在の package channel に従います。
便利で project-aware な環境ですが、bit-for-bit reproducible ではありません。

Coding-agent installer と同様、これらの download は provider credential を
追加する前の空 guest 内だけで実行します。Transitive dependency まで完全 pin
する必要がある組織では、review 済み VM image を昇格するか、moving channel を
内部管理 bundle に置き換えてください。

一次 installation source は[上流の一次資料](references_jp.md)にまとめています。
