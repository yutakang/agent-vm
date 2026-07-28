# 日常運用

[English](daily-use.md)

## VM を開く・閉じる

初回実行後、新しい `libvirt` group membership を desktop session へ反映するため、
Ubuntu host から一度 logout して再 login します。GUI を起動します。

```bash
virt-manager --connect qemu:///system
```

VM を double-click し、必要なら **View → Fullscreen** を使います。通常は guest
desktop から ACPI shutdown してください。`Force Off` は物理 machine の電源 cable を
抜くのと同じで、filesystem を壊す可能性があります。

Script は VM autostart を有効にしません。Host 起動時に常に guest の memory 消費と
network service 公開を行う必要がある場合だけ、`virt-manager` で有効にしてください。

## Clean snapshot

最も価値がある snapshot は、次の状態で作ります。

- provisioning marker が存在し、将来の cloud-init 実行が無効化されている。
- 五つ全ての command が version を返す。
- Ubuntu が GUI login まで到達した。
- Provider、GitHub、browser、Ollama Cloud account をまだ追加していない。
- 機密 project を VM へまだ入れていない。

`clean-provisioned-no-credentials` のように明確な名前を付けます。

Snapshot 復元前に VM を shutdown します。Running VM snapshot には RAM、active
session、一時 credential が含まれ得ます。Snapshot support と性能は disk format、
libvirt/QEMU version に依存するため、snapshot を recovery として信頼する前に、
復元した test VM が boot することを確認してください。

Snapshot は backup ではありません。通常は同じ host storage に依存し、secret を
含む可能性があります。

## 信頼領域ごとに一つの VM

別 VM または clone が適する例:

- 異なる組織・client。
- Public OSS と confidential work。
- Local-only model と unrestricted remote provider。
- 実験的 plugin または MCP server。
- 支出上限や repository 権限が異なる credential。
- Review 済み変更を取り込む前の非信頼 repository 試験。

蓄積した credential と project のため破棄費用が高くなる巨大な「全部入り VM」を
避けてください。

## Project data の移動

Host folder は自動共有しません。実用的で比較的安全な選択肢:

1. Public または権限を狭く限定した repository を guest 内で clone する。
2. Review 済み archive を `scp` でコピーする。
3. Guest から patch を export して host で review する。
4. 専用の短期 Git branch と scope 限定 token を使う。

Setup script は復旧 key path を表示します。Guest へ file を copy する例:

```bash
VM_IP=192.168.122.100
scp -o IdentitiesOnly=yes \
  -i ~/.local/share/kvm-agent/kvm-agent/id_ed25519 \
  project.tar.gz agent@"$VM_IP":~
```

現在の address:

```bash
virsh --connect qemu:///system domifaddr kvm-agent --source lease
```

Host home 全体の recursive copy は避けてください。Host SSH private key、browser
profile、password-manager vault、cloud 設定 directory、signing key を利便性だけの
ためにコピーしてはいけません。

出力には review しやすい patch を使えます。

```bash
git diff --binary > agent-result.patch
```

`scp` で外へ出し、別 directory で確認・test し、重要 repository へ apply/commit
するのはその後です。

## 復旧 SSH

既定 VM の例:

```bash
ssh -o ForwardAgent=no \
  -o IdentitiesOnly=yes \
  -i ~/.local/share/kvm-agent/kvm-agent/id_ed25519 \
  agent@VM_ADDRESS
```

Guest 内の確認 command:

```bash
sudo cloud-init status --long
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
sudo tail -n 160 /var/log/kvm-agent-provision.log
sudo cat /var/lib/kvm-agent/installed-versions.txt
systemctl status gdm3 qemu-guest-agent ollama --no-pager
ss -ltnp | grep 11434
```

復旧 private key は host に残します。Guest へ copy したり、別 SSH agent を VM へ
forward したりしないでください。

## Agent tool の更新

最も clean な update は、現在の script から新 VM または clean clone を作ることです。
Plugin、model client、build tool、古い実験が残した状態も除去できます。

In-place update は現在の公式手順を使い、必ず guest 内で実行します。この repository が
link する現在の native installer:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
curl -fsSL https://claude.ai/install.sh | bash
curl -fsSL https://opencode.ai/install | bash
curl -fsSL https://ollama.com/install.sh | sh
```

Aider は KVM-Agent が導入した bootstrap から更新します。

```bash
~/.local/share/kvm-agent/uv-bootstrap/bin/uv tool upgrade aider-chat
```

確認:

```bash
codex --version
claude --version
opencode --version
aider --version
ollama --version
systemctl is-active ollama
ss -ltnp | grep 11434
```

`/etc/systemd/system/ollama.service.d/10-kvm-agent-loopback.conf` の Ollama
systemd drop-in が、引き続き `OLLAMA_HOST=127.0.0.1:11434` を設定している必要が
あります。

これらの第三者 installer command を誤って host で実行してはいけません。

## Ubuntu の更新

Guest 内:

```bash
sudo apt update
sudo apt full-upgrade
```

大規模 update 前に rollback point を作るか確認します。Kernel、QEMU guest 連携、
display stack が更新された場合は reboot します。

```bash
sudo reboot
```

Ubuntu host も別に最新化します。Host kernel、QEMU、libvirt、`virt-manager` の
security fix は isolation boundary を守ります。

## Ollama model

既定では model を download しません。

```bash
ollama pull MODEL_NAME
```

で取得した model は VM disk を消費し、GPU passthrough がないため通常 CPU で
動きます。利用前に model license、origin、size、RAM requirement、confidentiality
property を確認してください。

`ollama signin` と Ollama Cloud model は remote inference です。Ollama CLI を
使っても local にはなりません。

## Export、review、discard

作業終了時:

1. `git status`、diff、生成 file、dependency 変更を調べる。
2. Guest で test を実行する。
3. Patch を export するか、scope を狭くした branch から push する。
4. Guest 外で結果を確認する。
5. Guest credential を失効または rotate する。
6. 有用な trust boundary でなくなれば VM を rollback または削除する。

KVM-Agent guest と repository が管理する host 側 state をまとめて削除するには、
guest を shutdown し、repository から次を実行します。

```bash
./remove-kvm-agent.sh --name kvm-agent
```

必要なら先に `--dry-run` を使います。Helper が削除するのは、正確な管理対象 disk、
残存 seed、復旧 directory、現在の libvirt log、指定 domain だけです。共有 Ubuntu
image cache、host package、利用者が追加接続した storage は残します。削除は安全な
消去を保証しません。[SECURITY_jp.md](../SECURITY_jp.md)を参照してください。
