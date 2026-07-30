# 任意の cross-host manager/worker VM 構成

[English](swarm.md)

KVM-Agent は、異なる物理 host・異なる network 上の複数の disposable guest を
任意で連携させられます。通常は、主 agent を動かす 1 台の **manager** VM と、
Isabelle build や benchmark など長時間の比較的決定的な job を実行する 1 台以上の
**worker** VM を使います。

これは job の分散であり、memory の合算ではありません。ある VM 上の 1 process が
別 VM に割り当てられた RAM を使うことはできません。独立した job を worker に送り、
manager は別作業を続け、後から log と結果を回収する使い方です。

```text
Dell host                                Galleria host
└─ manager VM ── Tailscale/WireGuard ──► worker VM
                  通常の OpenSSH
```

両方の物理 host は overlay network に参加させません。Manager には worker 側の
物理 host credential、host directory mount、libvirt socket などを渡しません。

## Provisioning が追加するもの

両 role とも同じ `setup-kvm-agent.sh` を使います。`manager`、`worker`、
`both` は **role** であり、VM 名ではありません。Guest は異なる物理 host 上に
あるため、両方とも repository の既定 VM 名 `kvm-agent` を使えます。その VM を
custom name で作成した場合だけ `--name` を指定してください。

初回作成時:

```bash
# manager にする VM の物理 host で実行。既定 overlay は Tailscale。
./setup-kvm-agent.sh --formal-methods --swarm-role manager

# worker にする VM の物理 host で実行。
./setup-kvm-agent.sh --formal-methods --swarm-role worker

# raw WireGuard を使う場合は、worker にする VM の物理 host で実行。
./setup-kvm-agent.sh \
  --formal-methods \
  --swarm-role worker \
  --swarm-network wireguard
```

Repository で作成・provisioning 済みの、既定名の VM に後から追加する場合:

```bash
# manager にする VM の物理 host で実行。
./setup-kvm-agent.sh --add-swarm manager

# worker にする VM の物理 host で実行。
./setup-kvm-agent.sh \
  --add-swarm worker \
  --swarm-network tailscale
```

既存 VM が実際に non-default の値を使っている場合だけ、`--name`（および
`--user`）を指定します。例えば:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --name proof-vm-02 \
  --user researcher \
  --swarm-network tailscale
```

`--add-swarm` は、選択した VM 用に host が既に管理している recovery key を
使います。Guest を再作成・削除しません。Guest は起動中で、libvirt private
network 経由で到達可能である必要があります。package の導入には数分かかることが
あるため、この Guest 内処理には最大 30 分を許可します。失敗時には最近の
`/var/log/kvm-agent-swarm.log` を自動表示します。誤った `--name` を指定すると、
script は別の per-VM directory で recovery key を探します。既定名は
`kvm-agent` です。

Role は次の 3 種類です。

- `manager`: 通常 guest user の
  `~/.ssh/id_ed25519_kvm_agent_swarm` に専用 Ed25519 SSH key を作り、public half
  だけを表示する command を導入します。
- `worker`: password lock 済み・non-sudo の `agent-worker` account と `~/jobs`
  directory、root-owned の manager-key store を作り、OpenSSH の `restrict` option
  付きで manager public key を追加する helper を導入します。
- `both`: 送信側・受信側の両方として使う必要がある VM 向けです。

Profile は選択した overlay client と、必要最小限の guest firewall exception も
追加します。Worker account は `/opt` と `/usr/local/bin` にある provision 済み Isabelle
のような system-wide tool を利用できますが、通常の `agent` account の user-local
toolchain や credential は継承しません。

一方で次は自動化しません。

- VM を Tailscale account へ sign in すること
- Tailscale auth key の作成・転送
- WireGuard address、endpoint、peer key の自動決定
- Tailscale exit node、subnet router、Funnel、Serve、Tailscale SSH の有効化
- manager key の worker への自動 authorization
- worker account への API credential 配置

これらは provisioning が安全に推測できない trust decision を含むためです。

VM 内で現在の状態を確認します。

```bash
kvm-agent-swarm-status
```

Log は次に記録されます。

```text
/var/log/kvm-agent-swarm.log
```

## SSH だけでなく overlay network を使う理由

WireGuard/Tailscale は SSH の代替ではありません。SSH は manager の認証、command
実行、file transfer を担当します。Overlay は、その SSH を通す private で安定した
network path を提供します。

2 台の VM が既に同じ trusted LAN で相互到達可能なら、直接 SSH だけでも十分です。
しかし異なる家庭、研究所、hotel、mobile network では、両 VM は通常 router と
libvirt NAT の背後にいます。直接 SSH するには public address、dynamic DNS、router・
host の port forwarding、public に到達可能な SSH port が必要になりがちです。

Overlay の主な利点は次です。

- Wi-Fi や public address が変わっても stable private VM address を使える
- guest port 22 を public internet に公開しなくてよい
- untrusted network 上の peer-to-peer traffic を暗号化できる
- manager から worker の TCP 22 だけ、という network policy を書ける
- device revocation と network 間移動が容易

異なる network 上の 2 台の laptop では、通常 Tailscale が最も簡単です。
WireGuard による end-to-end encrypted transport に加え、device identity、
coordination、NAT traversal、direct 接続できない場合の relay、中央 policy 管理を
提供します。

Raw WireGuard は外部 trust と software surface が小さい一方、coordination service
や一般的 NAT traversal は提供しません。通常は少なくとも 1 peer に到達可能な UDP
endpoint が必要で、そうでなければ VPS などの reachable hub が必要です。両 laptop
が独立 NAT の背後にある場合、router・host・libvirt forwarding が必要になることが
あり、これは Tailscale が回避する部分です。

一次資料:

- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale routing features](https://tailscale.com/docs/route)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)

## 推奨 Tailscale setup

両 VM を `--swarm-role ...` 付きで作るか、後から role を追加します。その後、各 VM
内で次を実行します。

```bash
sudo tailscale up
```

各 VM を intended tailnet に authenticate します。`--ssh` は付けません。この
profile は通常の OpenSSH を意図しており、専用 key と worker の `authorized_keys`
entry で account・forwarding 制限を維持します。

Route advertisement、exit node は使わず、物理 host をこの worker tailnet に追加
しないでください。Worker address は次で確認します。

```bash
tailscale ip -4
```

Tag と deny-by-default policy を使います。現在の grants-style policy では、意図する
方向を例えば次のように表現できます。既存 policy を無条件に置き換えず merge して
ください。

```json
{
  "tagOwners": {
    "tag:kvm-agent-manager": ["autogroup:admin"],
    "tag:kvm-agent-worker": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["tag:kvm-agent-manager"],
      "dst": ["tag:kvm-agent-worker"],
      "ip": ["tcp:22"]
    }
  ]
}
```

Manager/worker VM にそれぞれ tag を付け、worker から manager への逆方向 grant は
追加しません。Guest firewall も unsolicited inbound を deny しますが、Tailscale
policy も重要です。

Provisioning 済み firewall は `tailscale0` 上で tailnet-assigned IPv4 destination
だけを許可します。Node-to-node SSH と MagicDNS を意図し、subnet route や exit node
のための一般 private routing は開きません。

## Raw WireGuard setup

`--swarm-network wireguard` は `wireguard-tools` を導入し、`wg0` interface 用 UFW rule
を準備します。Peer address、public endpoint、VPS hub の要否を provisioning は知らない
ため、`wg0.conf` は作りません。

WireGuard の公式 quick start に従い、各 guest 内で別々の key pair を生成し、
`/etc/wireguard/wg0.conf` を作ります。Broad private network ではなく peer ごとの `/32`
を推奨します。例えば manager `10.203.0.1/32`、worker `10.203.0.2/32` です。物理 LAN、
libvirt network、`0.0.0.0/0` を worker tunnel に route しないでください。

File を review 後:

```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

Worker firewall は `wg0` 上の inbound SSH だけを許可します。Manager 側には同等の
inbound exception を作りません。WireGuard は peer を暗号学的に識別しますが、worker
account への access は OpenSSH key が制御します。

## Manager を worker に authorize する

Manager VM で:

```bash
kvm-agent-swarm-public-key
```

表示された public-key 1 行を copy します。Public key は secret ではありません。
Worker VM で、通常の `agent` account とその guest-local sudo を使って:

```bash
printf '%s\n' 'ssh-ed25519 AAAA... kvm-agent-swarm-manager@manager' |
  sudo kvm-agent-swarm-authorize
```

Helper は Ed25519 public key 1 行だけを受け取り、`ssh-keygen` で検証し、OpenSSH の
`restrict` option 付きで root-owned の
`/etc/ssh/authorized_keys/agent-worker` に追加します。Worker 自身はこの authorization
file を変更できません。User-specific SSH policy は password・keyboard-interactive login、
全 SSH forwarding、tunnel、TTY、user RC file も無効化します。Remote account は
non-sudo です。Manager key は host recovery key とは別物です。

通常の guest account から authorization を確認・全 revoke できます。

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

Manager から overlay 上の通常 OpenSSH を test します。Provisioning は swarm 専用の
known-hosts file を作るため、disposable worker の交換によって無関係な SSH destination
の検証を弱める必要はありません。

```bash
WORKER_ADDRESS=100.x.y.z  # Tailscale または WireGuard address
ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o IdentityAgent=none \
  -o ForwardAgent=no \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts_kvm_agent_swarm" \
  -i ~/.ssh/id_ed25519_kvm_agent_swarm \
  agent-worker@"$WORKER_ADDRESS" \
  'hostname && id && mkdir -p ~/jobs'
```

Disposable worker を再作成すると OpenSSH は host-key mismatch を報告するはずです。
旧 VM が本当に交換されたことを確認してから、その worker の古い entry だけを削除します。

```bash
ssh-keygen -R "$WORKER_ADDRESS" \
  -f "$HOME/.ssh/known_hosts_kvm_agent_swarm"
```

Mismatch を `StrictHostKeyChecking=no` で回避しないでください。

`ssh -A` は使わず、manager private key を worker に copy しないでください。

## 簡単な job workflow

Worker に第 2 の LLM agent を動かさず、manager から experiment を送れます。

```bash
JOB="job-$(date +%Y%m%d-%H%M%S)"
SSH=(
  ssh
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
  -o ForwardAgent=no
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$HOME/.ssh/known_hosts_kvm_agent_swarm"
  -i "$HOME/.ssh/id_ed25519_kvm_agent_swarm"
)
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -o IdentityAgent=none -o ForwardAgent=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts_kvm_agent_swarm -i $HOME/.ssh/id_ed25519_kvm_agent_swarm"

"${SSH[@]}" agent-worker@"$WORKER_ADDRESS" "mkdir -p ~/jobs/$JOB"
rsync -a -e "$RSYNC_SSH" ./experiment/ \
  "agent-worker@$WORKER_ADDRESS:jobs/$JOB/"

"${SSH[@]}" agent-worker@"$WORKER_ADDRESS" "
  cd ~/jobs/$JOB &&
  nohup bash -c '
    timeout 7200 nice -n 10 ./run-experiment.sh
    printf \"%s\\n\" \$? > exit-status
    touch finished
  ' > run.log 2>&1 < /dev/null &
"
```

後で status と結果を取得します。

```bash
"${SSH[@]}" agent-worker@"$WORKER_ADDRESS" \
  "cd ~/jobs/$JOB && { test -f finished && cat exit-status || tail -n 40 run.log; }"

mkdir -p "./remote-results/$JOB"
rsync -a -e "$RSYNC_SSH" \
  "agent-worker@$WORKER_ADDRESS:jobs/$JOB/" \
  "./remote-results/$JOB/"
```

繰り返し使うなら `submit`、`status`、`log`、`fetch`、`cancel` subcommand を持つ小さな
review 済み wrapper を作ってください。弱い worker laptop では `flock` で同時 job
数を制限し、`timeout`、`nice`、disk cleanup を使います。

## Security effect と risk elevation

Overlay は traffic を暗号化し SSH を public internet から隠しますが、以前は分離
されていた guest 間に新しい authenticated route を作ります。これは実在する lateral
movement risk の増加ですが、制御可能です。

### Worker への risk

Manager が compromise されると、その authorized key で non-sudo `agent-worker`
account を制御し、job 改変、CPU/RAM/disk 消費、送信済み source の読取り、worker
account から到達可能な internet 利用が可能になります。Worker は manager の security
domain の一部として扱い、disposable にしてください。Browser session、API token、host
credential、無関係な work を置きません。

### Manager への risk

推奨 network policy は worker initiated connection を manager に許可しません。
これは exposure を大幅に減らしますが、worker result の trustworthiness は保証しません。
Compromised worker は偽 log、malicious archive、巨大 file、shell script、予期しない code
を含む Isabelle theory、manager agent を誘導する project content を返せます。

回収物は untrusted input として扱います。Plain log、hash、CSV、小さな patch を優先し、
実行や IDE workspace として開く前に review してください。

### 物理 host への risk

Overlay は guest 内だけに導入します。便利だからという理由で物理 host を同じ tailnet
に入れず、host SSH private key を guest に置きません。Host folder、libvirt socket、
Docker socket、block device、USB/PCI passthrough を worker VM に渡しません。この条件なら、
残る host risk は untrusted agent code を VM で動かす際に既に受け入れている通常の
KVM/QEMU escape risk が中心です。

### Tailscale 固有の trust

Tailscale は coordination control plane を追加し、tailnet operation に必要な device・
connectivity metadata を受け取ります。Traffic payload は end-to-end encrypted のままです。
Device tag、grant、account security、廃棄 VM の削除が security boundary の一部になります。
Disposable worker を捨てる際は Tailscale admin console から remove/expire してください。

### WireGuard 固有の trust

Raw WireGuard は hosted coordination service を避けますが、key distribution、endpoint
availability、firewall、route scope、revocation、NAT traversal は operator 責任です。
Broad `AllowedIPs` や route は意図以上の network を expose します。VM ごとに別 key pair と
narrow `/32` peer を使ってください。

## 推奨 baseline

異なる network 上の普通の laptop 2 台なら:

1. Tailscale を guest 内だけで使う。
2. 一方を manager、他方を worker として tag する。
3. manager から worker の TCP 22 だけ grant する。
4. 通常 OpenSSH と専用 swarm key を使う。
5. non-sudo `agent-worker` account だけを authorize する。
6. 物理 host、subnet route、exit node、Tailscale SSH、価値ある credential をこの構成の
   外に置く。
7. worker result は review まで untrusted と扱う。

この構成は roaming laptop で raw WireGuard を安全に運用するより簡単で、VM isolation を
維持しつつ、worker に第 2 agent や追加 LLM credential を置く必要もありません。
