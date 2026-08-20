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

## 長時間の作業を `tmux` で維持する

KVM-Agent は guest に `tmux` を導入します。Coding agent、proof search、build など、
Mac の sleep、Wi-Fi 切替、Tailscale reconnect、SSH 切断が起きても継続させたい処理は
`tmux` 内で実行してください。

日常運用では、一つの名前付き session だけでも十分です。

```bash
tmux new -As work
```

既存の `work` session があれば attach し、なければ新規作成します。その中で Claude Code、
Codex、OpenCode、Isabelle job など長時間 command を起動します。

よく使う操作:

```text
Ctrl-b d       detach。処理は継続する
Ctrl-b c       新しい window を作る
Ctrl-b n       次の window
Ctrl-b p       前の window
Ctrl-b ,       現在の window を rename
Ctrl-b [       scroll/copy mode。q で戻る
```

新しい SSH 接続から戻る場合:

```bash
tmux ls
tmux attach -t work
```

`tmux` は terminal・SSH 切断から process を守りますが、VM の shutdown/reboot を越えて
process を維持するものではなく、security boundary でもありません。

## 一つの GitHub issue を一つの agent branch で処理する

GitHub-connected project では agent に `main` を編集させず、protected-default-branch
routine を使います。

1. Acceptance criteria と test command を持つ bounded GitHub issue を書く。
2. Repository 内で agent を開始し issue number を渡す。
3. `origin/main` へ update して `agent/...` branch を作らせる。
4. Edit、test、commit、branch push、`Closes #ISSUE` を含む `gh pr create` を行わせる。
5. GitHub で diff、check、discussion、dependency provenance、submodule commit を確認する。
6. 自分で protected `main` へ merge し、VM checkout を fast-forward する。

GitHub issue は local CLI agent を自動起動しません。Human が project-scoped credential
を load した状態で agent を開始すれば、agent は branch push と PR 作成を実行できます。
Agent を ruleset bypass list に入れず、API token に Contents write を付与しません。

初回 setup、正確な credential 分離、現在の fine-grained-token UI、command、failure
recovery は
[local coding-agent VM の GitHub integration](github-integration_jp.md)に記載しています。

## SSH 切断後に terminal が文字化け・異常表示になった場合

Full-screen の interactive program 実行中に SSH が切れると、入力文字が表示されない、
改行がおかしい、画面が意味不明な文字列に見える、といった terminal state の乱れが
残ることがあります。

まだ foreground program が動いているなら、まず次を試します。

```text
Ctrl-C
```

SSH がすでに切れ、local shell（たとえば Mac の terminal）へ戻っている場合は、**今いる
側の terminal** で次を実行します。

```bash
reset
```

入力した文字自体が見えなくても、`reset` と入力して Enter を押してください。それでも
直らなければ:

```bash
stty sane
reset
```

その後 VM へ再接続し、既存 `tmux` session に戻ります。

```bash
ssh YOUR_VM_NAME
tmux attach -t work
```

SSH 接続自体は生きていて remote shell の表示だけが壊れている場合も、その shell で
`Ctrl-C` → `reset` を試せます。Terminal state を直すだけのために VM を reboot する
必要はありません。

## 再作成せず既存 VM の resource を変更する

Guest を通常どおり shutdown し、host から永続 RAM・vCPU 割当を変更します。

```bash
./setup-kvm-agent.sh --resize-existing \
  --name kvm-agent \
  --memory 24576 \
  --vcpus 12
```

実行中 domain または managed-save image を持つ domain は拒否し、disk の削除・再作成は
行いません。libvirt が running state を保存している場合は、VM を起動して通常の full
shutdown を行ってから resize してください。変更後は既存 VM を通常どおり起動します。
`--memory` または `--vcpus` の一方だけでも指定できます。Ubuntu host 用の RAM・CPU を
残してください。Helper は host RAM を最低 2 GiB 残し、host が報告する CPU 数を超える
vCPU 指定を拒否します。

Guest hot-plug support に依存せず、powered-off configuration change を使う設計です。

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

Host folder は自動共有しません。ローカル VM であっても guest は独立した filesystem
を持つため、host 側の通常の `cp` から guest の `/home` 内を読み書きできません。
実用的で比較的安全な選択肢:

1. Public または権限を狭く限定した repository を guest 内で clone する。
2. Review 済み file を host helper で転送する。
3. Guest から小さな patch を export して host で review する。
4. 専用の短期 Git branch と scope 限定 token を使う。

Setup は、現在の VM address を検出し、専用復旧鍵を guest へ渡さず使う
`kvm-agent-host` を導入します。既定 VM の例では、物理 Ubuntu host から
project を guest へ次のように送ります。

```bash
kvm-agent-host push kvm-agent ./my-project Work/
```

Guest 内で確認しやすい小さな patch を作ります。

```bash
git diff --binary > agent-result.patch
```

信頼する host から取り出します。既定の保存先は mode `0700` の
`~/vm-extraction-quarantine/kvm-agent/` です。

```bash
kvm-agent-host pull kvm-agent Work/agent-result.patch
```

ここで `kvm-agent` は libvirt VM 名の例です。異なる `--name` を使った場合は
置き換えてください。両方向とも信頼する host から開始します。Host SSH private key を
guest へコピーしたり SSH agent forwarding を有効にしたりしてはいけません。

別の信頼する Mac では Mac 専用の別鍵を使い、Mac から `scp` を開始します。
Host の復旧鍵をコピーせず、[安全なリモートアクセス](remote-access_jp.md#macos-から-data-を転送する)
の手順に従ってください。

Host home 全体の recursive copy は避けてください。Browser profile、password-manager
vault、cloud 設定 directory、signing key、その他の長期 credential を利便性だけのために
コピーしてはいけません。

Patch を別 directory で確認・test してから、重要 repository へ
apply/commit します。侵害された可能性がある guest からコピーした file はすべて非信頼
として扱い、review 前に実行、build、IDE workspace としての open を行わないでください。

### より強い offline 抽出

侵害された可能性がある guest と能動的に通信したくない場合は、guest を shutdown し、
仮想 disk から read-only で抽出します。必要なら host へ `libguestfs-tools` を導入します。

```bash
sudo apt update
sudo apt install libguestfs-tools
```

既定 VM 名と disk 配置の例では次を実行します。

```bash
sudo virsh --connect qemu:///system domstate kvm-agent
mkdir -p "$HOME/vm-extraction-quarantine/kvm-agent"
chmod 700 "$HOME/vm-extraction-quarantine/kvm-agent"
sudo guestfish --ro --format=qcow2 \
  -a /var/lib/libvirt/images/kvm-agent/vms/kvm-agent.qcow2 -i \
  copy-out /home/agent/Work/my-project \
  "$HOME/vm-extraction-quarantine/kvm-agent"
sudo chown -R "$USER:$USER" "$HOME/vm-extraction-quarantine/kvm-agent"
```

`domstate` が `shut off` と表示した場合だけ続行してください。Offline 抽出は `scp` より
手間がかかりますが、実行中 guest に依存せず、安定した filesystem view を得られます。

## 復旧 SSH

既定 VM では、導入済み host helper を使います。

```bash
kvm-agent-host ssh kvm-agent
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

Helper は guest host key を固定し、agent、X11、port forwarding を無効化します。
復旧 private key は host に残します。Guest へ copy したり、別 SSH agent を VM へ
forward したりしないでください。脅威 model と macOS controller setup は
[安全なリモートアクセス](remote-access_jp.md)を参照してください。

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
