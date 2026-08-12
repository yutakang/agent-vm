# 物理 host をまたぐ manager/worker VM

[English](swarm.md)

この任意 profile は、一つの使い捨て VM 内の agent から、別の使い捨て VM にある
non-sudo account へ、時間制限付きの作業を送ります。大多数の利用者には不要です。

以下の `YOUR_...` はすべて置き換える placeholder です。`research-a` のような名前は
明示した例であり、必須の名前ではありません。

## command を入力する前に読むこと

次の構成を使います。

- Tailscale は物理 host ではなく **guest VM 内**だけで動かす。
- Tailscale 上で通常の OpenSSH を使い、Tailscale SSH は無効のままにする。
- manager から対応する worker の TCP/22 だけへ新規接続できる。
- 信頼済み Mac から manager の TCP/22 へ接続できるが、worker へは接続できない。
- worker から manager、Mac、別 group への新規接続を許可しない。
- SSH private key は、それを作った信頼済み device から外へ出さない。
- host directory、libvirt socket、device passthrough を共有しない。

Tagged VM を参加させる**前に** Tailscale policy を設定してください。Join helper は要求
tag が得られなければ停止しますが、既存の広い allow rule があると subgroup 隔離は
失われます。後述の policy test はこのよくある間違いを検出します。

Mac access と Tailscale/SSH key の役割は、先に
[安全なリモートアクセス](remote-access_jp.md#廊下扉鍵-ssh-と-tailscale-の役割)
を参照してください。

## 名前と command の実行場所

次は別々の識別子です。

| 識別子 | Placeholder | 明示的な例 |
|---|---|---|
| manager の libvirt VM 名 | `YOUR_MANAGER_LIBVIRT_VM_NAME` | `agent-research-a-manager` |
| worker の libvirt VM 名 | `YOUR_WORKER_LIBVIRT_VM_NAME` | `agent-research-a-worker` |
| swarm group | `YOUR_SWARM_GROUP` | `research-a` |
| manager Tailscale 名 | `GROUP-manager` から自動生成 | `research-a-manager` |
| worker Tailscale 名 | `GROUP-worker` から自動生成 | `research-a-worker` |
| manager tag | `tag:swarm-GROUP-manager` から自動生成 | `tag:swarm-research-a-manager` |
| worker tag | `tag:swarm-GROUP-worker` から自動生成 | `tag:swarm-research-a-worker` |

`--name` は常に libvirt VM 名兼 guest Linux hostname です。Swarm role は VM を
改名しません。

| 実行場所 | 目的 | Command |
|---|---|---|
| 各 VM の物理 Ubuntu host | role の追加・修復 | `./setup-kvm-agent.sh --add-swarm ... --name ...` |
| manager VM の通常 guest account | Tailscale 参加、pairing、job 実行 | `kvm-agent-swarm-tailscale-up`、`kvm-agent-swarm-configure-worker`、job helper |
| worker VM の通常 sudo 可能 guest account | Tailscale 参加、manager public key 認可 | `kvm-agent-swarm-tailscale-up`、`sudo kvm-agent-swarm-authorize` |
| 信頼済み Mac | manager 操作、review 対象結果の pull | `ssh`、`scp`。[remote access](remote-access_jp.md)参照 |

VM 内で `setup-kvm-agent.sh` を実行したり、物理 host で guest helper を実行したり
しないでください。

## Setup が自動化するもの

Swarm profile は次を導入・設定します。

- Tailscale、または上級者向け手動構成用 WireGuard tool
- 選択した overlay interface の TCP/22 だけを公開する UFW rule
- manager-to-worker job 専用の guest-local Ed25519 key
- password lock 済み non-sudo `agent-worker` account
- SSH forwarding と TTY を無効化した root-owned worker authorization
- ED25519 host key fingerprint の照合と固定
- SSH transport を上書きできない SSH/rsync wrapper
- timeout、log、status、fetch、cancel 付き one-job-at-a-time helper

Tailnet owner、tag approval、peer identity、初回 SSH fingerprint は安全に推測できないため、
目に見える人間の手順として残します。

## 一つの swarm を安全な順番で設定する

### 1. 二つの物理 Ubuntu host から role を追加する

Manager VM を動かす物理 host:

```bash
./setup-kvm-agent.sh \
  --add-swarm manager \
  --name YOUR_MANAGER_LIBVIRT_VM_NAME
```

Worker VM を動かす物理 host:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --name YOUR_WORKER_LIBVIRT_VM_NAME
```

新規 VM では初回 setup の明示的な `--name` と一緒に `--swarm-role manager` または
`--swarm-role worker` を指定します。Manager と worker は別 VM を推奨します。`both`
role には別の `tag:swarm-GROUP-swarm` policy が必要で、侵害時の影響範囲も広がります。

既存 VM を変える操作では `--name` が必須です。不明なら先に実名を確認します。

```bash
sudo virsh --connect qemu:///system list --all --name
```

### 2. 参加前に subgroup policy を追加する

[一つの tailnet に複数の独立 swarm を置く](#一つの-tailnet-に複数の独立-swarm-を置く)
の tag と grant を作ります。一 group だけなら、その group の entry だけを残します。
既存の allow-all rule は削除または限定し、無関係で必要な rule は慎重に merge し、
policy test が成功した場合だけ保存します。

### 3. 両 guest を同じ group 名で参加させる

Manager VM 内:

```bash
kvm-agent-swarm-tailscale-up --group YOUR_SWARM_GROUP
```

Worker VM 内:

```bash
kvm-agent-swarm-tailscale-up --group YOUR_SWARM_GROUP
```

Helper は device 名と一つの複合 role tag を作り、設定 reset、subnet route 拒否、exit node
なし、Tailscale SSH 無効の `tailscale up` を実行します。意図した tailnet へ browser
authentication を完了します。物理 host は参加しません。

両 VM で確認します。

```bash
kvm-agent-swarm-status
```

`SECURITY WARNING`、tag なし、別 group、別 tailnet の場合は停止してください。
`via DERP(...)` は暗号化済みで動作します。Direct path より遅い場合があるだけです。

### 4. manager SSH key を worker と pair にする

Worker VM 内で、local address と host-key fingerprint を記録します。

```bash
kvm-agent-swarm-worker-info
```

Manager VM 内で manager public key を表示します。

```bash
kvm-agent-swarm-manager-info
```

`ssh-ed25519` で始まる完全な一行だけをコピーします。Worker VM でその public line を
次へ貼り付けます。

```bash
printf '%s\n' 'PASTE_THE_COMPLETE_MANAGER_PUBLIC_KEY_HERE' |
  sudo kvm-agent-swarm-authorize
```

Public key は secret ではありません。対応する private key は manager VM の
`~/.ssh/id_ed25519_kvm_agent_swarm` に残し、worker や物理 host へコピーしません。
定期 guest-to-worker job のため passphrase はありません。従って manager 侵害時には、
その key を認可した全 worker が影響を受けます。

Worker authorization を確認します。

```bash
sudo kvm-agent-swarm-authorize --list
```

### 5. manager で worker host key を固定する

Manager VM で、worker Tailscale 名と worker local console で読んだ fingerprint を使います。

```bash
kvm-agent-swarm-configure-worker \
  YOUR_WORKER_TAILSCALE_NAME \
  SHA256:PASTE_THE_WORKER_HOST_FINGERPRINT
```

Group `research-a` の worker 名の例は `research-a-worker` です。Helper は fingerprint
mismatch を拒否し、`agent-worker` account、guest-local key、`ForwardAgent no`、
`ForwardX11 no`、`StrictHostKeyChecking yes` の専用 SSH config を作ります。

全接続を test します。

```bash
kvm-agent-swarm-test
```

期待 output には `agent-worker` が含まれます。

## 一つの tailnet に複数の独立 swarm を置く

一般的な `manager` tag と `research-a` tag の二つを付け、Tailscale が両方を要求すると
考えてはいけません。複数 tag の権限は積集合ではなく加算されます。そのため KVM-Agent
は VM ごとに一つの複合 tag を要求します。

次は `research-a` と `research-b` という明示的な例の二 group を定義します。信頼済み
Mac の Tailscale IPv4 の例は `100.64.0.10` です。Mac で `tailscale ip -4` を実行した
正確な値へ置き換えてください。Policy はこの IP に明示的な host alias `trusted-mac` を
付けます。Device の exact IP を使うことで、同じ human account で sign-in した全
device への許可を避けます。

```json
{
  "hosts": {
    "trusted-mac": "100.64.0.10"
  },
  "tagOwners": {
    "tag:swarm-research-a-manager": ["autogroup:admin"],
    "tag:swarm-research-a-worker": ["autogroup:admin"],
    "tag:swarm-research-b-manager": ["autogroup:admin"],
    "tag:swarm-research-b-worker": ["autogroup:admin"]
  },
  "acls": [],
  "grants": [
    {
      "src": ["trusted-mac"],
      "dst": ["tag:swarm-research-a-manager", "tag:swarm-research-b-manager"],
      "ip": ["tcp:22"]
    },
    {
      "src": ["tag:swarm-research-a-manager"],
      "dst": ["tag:swarm-research-a-worker"],
      "ip": ["tcp:22"]
    },
    {
      "src": ["tag:swarm-research-b-manager"],
      "dst": ["tag:swarm-research-b-worker"],
      "ip": ["tcp:22"]
    }
  ],
  "tests": [
    {
      "src": "trusted-mac",
      "proto": "tcp",
      "accept": ["tag:swarm-research-a-manager:22", "tag:swarm-research-b-manager:22"],
      "deny": ["tag:swarm-research-a-worker:22", "tag:swarm-research-b-worker:22"]
    },
    {
      "src": "tag:swarm-research-a-manager",
      "proto": "tcp",
      "accept": ["tag:swarm-research-a-worker:22"],
      "deny": ["tag:swarm-research-b-worker:22", "trusted-mac:22"]
    },
    {
      "src": "tag:swarm-research-b-manager",
      "proto": "tcp",
      "accept": ["tag:swarm-research-b-worker:22"],
      "deny": ["tag:swarm-research-a-worker:22", "trusted-mac:22"]
    },
    {
      "src": "tag:swarm-research-a-worker",
      "proto": "tcp",
      "deny": ["tag:swarm-research-a-manager:22", "tag:swarm-research-b-manager:22", "trusted-mac:22"]
    },
    {
      "src": "tag:swarm-research-b-worker",
      "proto": "tcp",
      "deny": ["tag:swarm-research-a-manager:22", "tag:swarm-research-b-manager:22", "trusted-mac:22"]
    }
  ]
}
```

必要な既存 policy と merge し、無関係な rule を不用意に上書きしないでください。
明示的な `"acls": []` は重要です。Legacy `acls` field を省略すると Tailscale の既定
allow-all policy が有効になる場合があります。Source `*` から destination `*` のような
広い ACL/grant は残しません。Permission は加算されるため、広い rule が意図した隔離を
無効化します。上の `deny` は明示的 deny rule ではなく policy test です。誤って経路を
許可する policy の保存を止めます。

第三 group には、新しい二つの複合 tag、manager-to-worker grant、必要なら Mac-to-manager
destination、対応する正・負 test を追加します。両 VM を新しい group 名で参加させ、
別 group の tag を再利用しません。

Tag 付き device は user-owned Tailscale node ではなくなります。`tagOwners` は tag を
割り当てられる人を、grant は tagged node が接続できる宛先を制御します。Join helper は
authentication 後に要求 tag を検証します。

## manager の日常利用

Remote command 一つを実行します。

```bash
kvm-agent-swarm-ssh 'hostname && whoami && nproc && free -h'
```

固定済み transport で directory を upload または retrieve します。

```bash
kvm-agent-swarm-rsync -a --protect-args ./experiment/ \
  kvm-agent-worker:jobs/manual-test/

kvm-agent-swarm-rsync -a --protect-args \
  kvm-agent-worker:jobs/manual-test/ ./returned-manual-test/
```

`kvm-agent-worker` は wrapper の専用 SSH config 内だけの名前です。Wrapper は別 remote
alias と SSH transport の上書きを拒否します。

時間制限付き background job を submit します。

```bash
kvm-agent-swarm-job submit ./experiment \
  --timeout 7200 \
  -- ./run-experiment.sh
```

Command は `job-...` identifier を表示します。`YOUR_JOB_ID` をその値へ置き換えます。

```bash
kvm-agent-swarm-job status YOUR_JOB_ID
kvm-agent-swarm-job log YOUR_JOB_ID 80
kvm-agent-swarm-job fetch YOUR_JOB_ID ./remote-results/YOUR_JOB_ID
kvm-agent-swarm-job cancel YOUR_JOB_ID
kvm-agent-swarm-job list
```

Helper は選択 directory を copy し、non-sudo worker account として `timeout`、`nice` を
使い一度に一 job だけを実行し、detach 後も log と exit status を保存します。Payload は
その account 内の任意 code なので、helper 自体は command allow-list ではありません。

Model-provider credential は manager に残します。Agent instruction の例:

> 長時間 experiment には `kvm-agent-swarm-job` を使う。必要な project directory だけを
> submit し、status/log を確認して結果を fetch する。Credential、browser data、private
> SSH key は worker へコピーしない。

## よくある問題

### `Permission denied (publickey)`

常に `agent-worker` と専用 key を選ぶ `kvm-agent-swarm-test` または
`kvm-agent-swarm-ssh` を使います。Manager public key と worker の root-owned
authorization を比較します。

```bash
kvm-agent-swarm-manager-info
sudo kvm-agent-swarm-authorize --list
```

一つ目は manager、二つ目は worker で実行します。

### Worker 交換後の host-key mismatch

再作成 VM では正常です。Worker local console の `kvm-agent-swarm-worker-info` で新
fingerprint を読み、manager で `kvm-agent-swarm-configure-worker` を再実行します。
`StrictHostKeyChecking=no` は使いません。

### Peer は見えるが SSH が遮断される

両 guest で確認します。

```bash
kvm-agent-swarm-status
tailscale status
tailscale ip -4
```

正確な group tag、Tailscale policy test の結果、manager key authorization を確認します。
Allow-all grant、SSH password、物理 host SSH の公開で解決してはいけません。

## Raw WireGuard alternative

Raw WireGuard は上級者向けの手動代替です。

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --name YOUR_WORKER_LIBVIRT_VM_NAME \
  --swarm-network wireguard
```

Script は `wireguard-tools` と interface-scoped UFW rule を導入しますが、peer address、
endpoint、key、hub を安全に推測できません。Operator が各 guest の
`/etc/wireguard/wg0.conf` を作ります。Manager `10.203.0.1/32`、worker
`10.203.0.2/32` のような narrow peer route を使い、物理 LAN、libvirt network、
`0.0.0.0/0` を worker 経由にしません。別 NAT 内の machine には通常 Tailscale の方が
簡単です。

## Security boundary と交換

Worker VM は disposable ですが、両方の物理 host は trusted のままです。侵害 manager は
その key を認可した全 worker を操作できます。侵害 worker は guest resource を消費し、
悪意ある結果を返せます。どちらにも物理 host への credential path を与えません。

- Overlay は guest 内だけに置く。
- Host folder、libvirt/Docker socket、block device、USB を共有しない。
- `ssh -A` を使わず、host private key を guest へ置かない。
- API token と browser session を `agent-worker` へ入れない。
- Fetch した file と log は review まで非信頼 data として扱う。
- QEMU、KVM、libvirt、両 host kernel を更新する。

Worker を破棄する前に Tailscale device を remove/expire します。残す worker の manager
authorization は次で確認・削除できます。

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

交換後は新 SSH fingerprint を local で確認し、manager を再設定します。診断:

```bash
kvm-agent-swarm-status
sudo tail -n 200 /var/log/kvm-agent-swarm.log
```

## 公式資料

- [Tailscale tags](https://tailscale.com/docs/features/tags)
- [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants)
- [Tailscale policy tests](https://tailscale.com/docs/reference/syntax/policy-file#tests)
- [Tailscale CLI: `tailscale up`](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
