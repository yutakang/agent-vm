# KVM-Agent：コーディングエージェント用の GUI 付き Ubuntu VM

[English](README.md)

> **実験的で非公式な資料です。** これは、新しい AI ツールも一部利用して
> 作成した個人的な作業プロジェクトです。検証済みのセキュリティ製品でも
> 専門的助言でもありません。まず重要なデータや認証情報を入れずに試して
> ください。訂正を歓迎します。自己の責任と費用で使用してください。
> [免責事項全文](DISCLAIMER_jp.md)。

KVM-Agent は、自律的コーディングエージェントを動かすための交換可能な
GUI 付き Ubuntu デスクトップを作ります。ホストで動かすのは Ubuntu の
KVM/libvirt と `virt-manager` だけです。Codex、Claude Code、OpenCode、
Aider、Ollama、プロジェクトのコマンド、および第三者インストーラーは
VM 内で動きます。

現在のリポジトリでは、setup と recovery のコマンドは一つだけです。

```bash
./setup-kvm-agent.sh
```

このスクリプトがホストの仮想化環境を導入し、Ubuntu 公式イメージを認証し、
VM を作り、最小 Ubuntu デスクトップと要求された五つのツールを導入して、
完了まで待ちます。日常的な操作には使い慣れた `virt-manager` の GUI を
使います。

縮小した形式手法環境は opt-in で追加できます。

```bash
./setup-kvm-agent.sh --formal-methods
```

同じ GUI 付き guest 内へ Lean 4、Isabelle/HOL、GHC、Cabal、Haskell Language
Server、HLint、VS Code、および公式 Lean/Haskell extension だけを追加します。
旧 repository の architecture や大きな prover collection は復活させません。

同じコマンドで、中断した finalization の再開や使い捨て VM の置換もできます。
再作成せず削除だけを行う小さな helper も残しています。

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
./setup-kvm-agent.sh --replace-existing --name kvm-agent
./remove-kvm-agent.sh
```

共有の検証済み Ubuntu image cache、host package、利用者が後から接続した
追加 disk は削除しません。

## アーキテクチャ

```mermaid
flowchart TB
    H["信頼する Ubuntu ホストアカウント"]
    M["virt-manager と system libvirt"]

    subgraph V["交換可能な Ubuntu 24.04 デスクトップ VM"]
        D["GNOME デスクトップと端末"]
        A["Codex · Claude Code · OpenCode · Aider"]
        O["127.0.0.1 上の Ollama"]
        F["任意: Lean · Isabelle/HOL · Haskell · VS Code"]
        D --> A
        D --> O
        D --> F
    end

    P["選択したリモートプロバイダーまたはローカルモデル"]

    H --> M
    M -->|"KVM + ホスト内限定 SPICE コンソール"| V
    A -->|"利用者が設定した後だけ"| P
    O -->|"ローカル重みまたは Ollama Cloud"| P
```

GUI は KVM を置き換えたり迂回したりしません。`virt-manager` は同じ
system libvirt/KVM 境界を操作する GUI クライアントです。ホストアカウントは
引き続き信頼主体であり、VM を完全に制御できます。コーディングエージェントを
ホストへ導入することはありません。

## スクリプトが行うこと

通常の Ubuntu ホストアカウントから実行すると、スクリプトは次を行います。

1. KVM、libvirt、`virt-manager`、`virt-install` と補助 Ubuntu パッケージを
   `sudo` で導入する。
2. そのホストアカウントを `libvirt` グループへ追加する。
3. libvirt の標準 NAT ネットワークを起動する。
4. Ubuntu 24.04 のリリース版 amd64 クラウドイメージをダウンロードし、
   Ubuntu が GPG 署名した SHA-256 一覧に対して検証する。
5. ローカル GUI 用パスワードを尋ね、専用の復旧 SSH 鍵を作る。
6. SPICE、virtio video、クリップボード連携、Ubuntu デスクトップを持ち、
   ホストディレクトリを共有しない GUI 付き VM を作る。
7. Codex、Claude Code、OpenCode、Ollama の公式インストーラーをゲスト内で
   ダウンロード・実行し、Aider を利用者専用 `uv` 環境へ導入する。
8. `--formal-methods` を選んだ場合、Lean を `elan` から、
   Isabelle2025-2/HOL を checksum 検証した公式 Linux archive から、
   GHC/Cabal/HLS を GHCup から、HLint を Cabal から導入し、さらに VS Code と
   公式 Lean/Haskell extension を導入する。
9. ベンダー installer を実行する前に、未要求の inbound 通信と、既定では
   private・link-local address range への outbound 通信を拒否する guest firewall を
   構成する（インターネット接続は開いたまま）。
10. 各コマンドを検証し、Ollama をゲストのループバック
   (`127.0.0.1:11434`) に限定し、将来の cloud-init 実行を無効化してから、
   プロビジョニング完了後に cloud-init seed を破棄する。

次のことは意図的に**行いません**。

- ホストへエージェント、Node.js パッケージ、Python エージェントパッケージ、
  Ollama を導入する。
- OpenAI、Anthropic、GitHub、Ollama Cloud その他へログインする。
- Ollama のモデル重みをダウンロードする。
- ホストのホームやプロジェクトディレクトリをゲストへマウントする。
- USB パススルー、SSH agent forwarding、LAN 公開 VM コンソールを設定する。
- モデルプロバイダーを選ぶ。
- Agda、Rocq/OCaml、HOL4、HOL Light、Mathlib、Archive of Formal Proofs を
  導入する。

縮小形式手法環境は任意なので、エージェント環境だけが必要な利用者は、その
download、disk、provisioning 費用を負いません。

## 必要条件

主要対応経路は次のとおりです。

| 構成要素 | 対応構成 |
|---|---|
| ホスト | Ubuntu 24.04 または 26.04 LTS、x86-64 |
| ゲスト | Ubuntu 24.04 LTS、amd64 |
| ファームウェア | Intel VT-x または AMD-V が有効 |
| ホスト権限 | 実行アカウントが `sudo` を利用可能 |
| ネットワーク | 初回プロビジョニング中にインターネット接続 |
| 表示 | `virt-manager` 用のローカル GUI Ubuntu セッション |
| ディスク | Guest 仮想 disk は既定 120 GiB。Host 空きは最低 12 GiB、`--formal-methods` では 30 GiB |
| メモリ | ゲスト 8 GiB を推奨。ホストへ 2 GiB 以上残す |

既定メモリはホスト RAM の半分を 8～16 GiB の範囲に収めた値です。既定
vCPU 数はホスト CPU 数の半分を 2～8 の範囲に収めた値です。そのため、
16 GiB ホストには 8 GiB、32 GiB ホストには 16 GiB の VM が割り当てられます。

## クイックスタート

このリポジトリをダウンロードまたは clone し、次を実行します。

```bash
cd kvm-agent
chmod +x setup-kvm-agent.sh
./setup-kvm-agent.sh
```

`sudo ./setup-kvm-agent.sh` として実行しては**いけません**。`virt-manager` を
使うホストアカウントから実行してください。必要な操作だけスクリプト内部で
`sudo` を呼びます。

ゲストの `agent` アカウント用パスワードを尋ねられます。これはローカル GUI
ログイン用です。SSH のパスワードログインは無効のままです。交換可能なゲスト
内ではこのアカウントにパスワードなし sudo を与えるため、エージェントは
ホスト権限を得ずに高い自律性を持てます。

初回プロビジョニングは通常 20～60 分かかります。遅いマシンではデスクトップ
導入、Ubuntu 更新、上流ダウンロードにさらに時間がかかる場合があります。
`--formal-methods` では Isabelle、Lean、GHC、HLS、VS Code の大きな download と
HLint build のため、**数時間かかる場合があります**。Host terminal は既定で
待機し、この profile には 6 時間の上限を設けます。

スクリプト完了後、そのホストアカウントが初めて `libvirt` に追加された
場合は、Ubuntu **ホスト**から一度ログアウトして再ログインします。その後、
次を実行します。

```bash
virt-manager --connect qemu:///system
```

`kvm-agent` をダブルクリックして GUI コンソールを開き、設定時に選んだ
パスワードで `agent` としてログインします。ゲスト端末では次を実行できます。

```bash
codex
claude
opencode
aider
ollama --version
```

各コーディングエージェントは、初回起動時に独自の認証またはプロバイダー設定を
行います。その前に[認証情報の取り扱い](docs/credentials_jp.md)を読んでください。

`--formal-methods` を指定した guest では次も使えます。

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

正確な対象、editor の扱い、update model は
[縮小形式手法環境](docs/formal-methods_jp.md)を参照してください。

## オプション

```text
--name NAME        VM とホスト名（既定: kvm-agent）
--user NAME        ゲストのログイン名（既定: agent）
--memory MB        ゲスト RAM（MiB）
--vcpus NUMBER     ゲスト仮想 CPU 数
--disk GB          ゲスト仮想ディスク容量（既定: 120）
--no-wait          VM 起動後、完了を待たずに戻る
--allow-lan        private・link-local address range への外向き通信を許可する。
                   UFW は有効なままで、未要求の inbound 通信は引き続き拒否する。
                   社内ミラーやモデル endpoint が必要な場合のみ
--formal-methods   guest 内へ Lean、Isabelle/HOL、Haskell tool、VS Code、
                   公式 Lean/Haskell extension を追加する
--replace-existing 指定した既存 VM を正確な名前の確認後に削除し、再作成する
--finalize-existing
                   既存 VM の検証済み最終 cleanup を再開する
```

既定の 120 GiB は guest から見える上限であり、host 上で直ちに 120 GiB を
確保する意味ではありません。qcow2 は guest の書き込みに応じて増えます。
大容量導入の前に setup は root partition と filesystem を明示的に拡張し、
要求容量を使えることを検証します。また provisioning 中は 512 MiB の緊急用
空き領域を確保し、download や package build の失敗時にはそれを解放して、
容量不足で GUI login まで不能になる事態を避けます。Host には基本 profile で
最低 12 GiB、`--formal-methods` で最低 30 GiB の空きが必要であり、
`--replace-existing` が旧 VM を削除する前に確認します。

`--no-wait` は provisioning 完了前に戻るため、その時点では cloud-init seed の
削除や将来の cloud-init 実行の無効化はできません。後で repository の helper を
実行してください。Helper は provisioning 成功を待ち、必要な update reboot を行い、
変更された DHCP address を再検出し、guest marker を検証してから cloud-init を
無効化し、seed を削除します。

```bash
./setup-kvm-agent.sh --finalize-existing --name NAME
```

例:

```bash
./setup-kvm-agent.sh \
  --name agent-project-01 \
  --memory 16384 \
  --vcpus 8 \
  --formal-methods
```

VM 名には小文字英字、数字、ハイフンを使います。既定では既存の libvirt
domain や disk の置換を拒否します。`--replace-existing` は削除計画を表示し、
VM 名の手入力を要求し、共有 Ubuntu cache と手動で追加した disk を残して
から再作成します。

## 中断した finalization を再開する

Setup が update reboot 後に guest へ到達できなかったと報告しても、desktop と
各 tool が動作する場合は、VM を作り直したり SSH・`virsh` の個別 cleanup command
を手入力したりしないでください。次を実行します。

```bash
./setup-kvm-agent.sh --finalize-existing --name kvm-agent
```

Helper は reboot 前の address を信用せず、libvirt の DHCP lease を再取得します。
Recovery key で `/var/lib/kvm-agent/provisioned` を確認するまで cloud-init や seed
を変更せず、実行中・永続化済みの両 device configuration から管理対象 seed が
外れたことを検証してから、その正確な seed file だけを削除します。SSH と
cloud-init の確認では `cloud-init status --wait` を使わず、各 SSH 呼び出しに
hard timeout を設定します。そのため、guest への接続後に remote command が
停止しても helper が無期限に hang することはありません。
`--no-wait` 後もこの helper が正式な完了手順です。

## VM を完全に削除する

Guest を通常どおり shutdown してから次を実行します。

```bash
./remove-kvm-agent.sh --name kvm-agent
```

Helper は削除前に、libvirt domain、接続済み storage、管理対象 image の正確な
path、復旧 SSH directory、log を表示します。確認には VM の正確な名前を入力します。
Domain、main disk、残っている cloud-init seed、host 側の復旧 data を削除します。
検証済み Ubuntu base-image cache と仮想化 package は残すため、作り直す際に host
導入や image download を繰り返す必要はありません。

`--dry-run` で計画だけを確認できます。実行中 VM の削除は拒否します。まず通常どおり
shutdown してください。`--force` は物理マシンの電源 cable を抜くのと同じ filesystem
破損 risk を受け入れる場合だけ使います。利用者が追加した storage は表示しますが、
自動削除しません。

## 日常的な利用

`virt-manager` からゲストの起動、停止、一時停止、clone、snapshot、容量調整、
画面表示を行います。全画面表示にすれば、通常のもう一台の Ubuntu マシンの
ように利用できます。VM はホスト起動時に自動起動する設定ではありません。

推奨する作業サイクル:

1. クリーンな snapshot を作るか復元する。
2. この作業に必要なプロジェクトデータと失効可能な認証情報だけをゲストへ入れる。
3. エージェントを実行し、commit または patch をレビューする。
4. レビュー済み結果を外へ出す。
5. VM の状態を信頼できなくなったら `remove-kvm-agent.sh` で破棄するか rollback する。

snapshot、更新、復旧 SSH、データ移動については
[日常運用](docs/daily-use_jp.md)を参照してください。

## 重要なセキュリティ上の限界

KVM はエージェントの誤動作による影響を大幅に減らしますが、安全性の証明では
ありません。侵害されたゲストは、そのゲストへ入れた全データを読み、ネット接続と
プロバイダー認証情報を利用し、ハイパーバイザーを攻撃し、悪意ある文字列や
クリップボード内容をホスト利用者へ提示できます。

既定 VM は、プロビジョニングとリモートモデル利用のため外向きインターネット接続を
持ちます。LAN から VM への port forward はなく、ゲスト側 firewall は private・
link-local destination range への通信を遮断します。通常は libvirt host、他 guest、
物理 LAN を含みますが、local に route された public address は対象外です。host から
libvirt の private network 上で guest へ到達することは引き続き可能です。この
firewall は guest 内部にあるため、
sudo を持つエージェントは解除できます。ゲスト外で強制される項目とゲスト内の既定
にすぎない項目の区別は [SECURITY_jp.md](SECURITY_jp.md) を参照してください。
SPICE には TCP listener がなく、`virt-manager` は libvirt 経由で接続します。
利便性のため SPICE クリップボード連携を有効にしているので、クリップボードで
秘密情報を移動しないでください。

`virt-manager` を実行するホストアカウントは `libvirt` グループに属し、これは
host root と同等です。Ubuntu ではこの権限は常時有効で、libvirt の socket 認証を
再構成しない限り session ごとの認証へ下げられません。日常のブラウジングやメールに
使う machine ではなく、専用の VM host を用意することを推奨します。
[SECURITY_jp.md](SECURITY_jp.md) を参照してください。

インストーラー URL は現在の公式 release channel を意図的に追随します。これにより
単一スクリプトを保守しやすくする一方、bit-for-bit の再現性はありません。これらの
インストーラーも、空で認証情報のないゲスト内でだけ実行します。成果物を厳密に
レビューする必要がある組織では、移動するインストーラーを内部承認済み golden
image または pin 済み bundle に置き換えてください。

機密ソース、長期鍵、本番データ、高額 API 認証情報を入れる前に
[SECURITY_jp.md](SECURITY_jp.md)を読んでください。

## 文書

- [セキュリティポリシーと脅威モデル](SECURITY_jp.md)
- [設計と信頼境界](docs/design_jp.md)
- [日常運用](docs/daily-use_jp.md)
- [認証情報の取り扱い](docs/credentials_jp.md)
- [エージェントツールとモデルサービス](docs/agent-tools-and-model-services_jp.md)
- [縮小形式手法環境](docs/formal-methods_jp.md)
- [トラブルシューティング](docs/troubleshooting_jp.md)
- [上流の一次資料](docs/references_jp.md)
- [免責事項](DISCLAIMER_jp.md)

## 状態

これは実験的な参照実装であり、独立監査済みのセキュリティ製品ではありません。
リポジトリでは script の静的検査と mock workflow test を行っていますが、実 VM
作成はホストの firmware、Ubuntu mirror、libvirt、更新される第三者
installer に依存します。問題を報告する際は、ホスト release、script option、
`cloud-init status --long`、および `/var/log/kvm-agent-provision.log` の
関連末尾を添えてください。
