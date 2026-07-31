# 物理ホストをまたぐ manager/worker VM

[English](swarm.md)

KVM-Agent では、異なる物理マシン上の disposable guest を接続し、一方の VM で
主 coding agent を動かし、もう一方の VM で Isabelle build や benchmark などの
長時間・比較的決定的な job を実行できます。

この文書では、実機名を公開しないため、次の一般名を使います。

- **Laptop_A**: manager VM を置く物理マシン
- **Desktop_B**: worker VM を置く物理マシン
- **manager VM**: Claude Code、Codex など主 agent を動かす VM
- **worker VM**: file を受け取り job を実行する disposable VM

2 台は別の物理 host 上にあるため、libvirt VM 名は両方とも repository 既定の
`kvm-agent` のままで構いません。ただし Tailscale 上の device 名は別にします。

```text
Laptop_A host                              Desktop_B host
└─ manager VM ── Tailscale/WireGuard ────► worker VM
                    通常の OpenSSH            └─ agent-worker
```

これは独立 job の分散です。2 台の RAM や CPU を 1 台の大きな computer のように
結合するものではありません。

## 推奨構成

異なる network 間を移動したり、別々の NAT の背後に置かれたりする 2 台には、次を
推奨します。

- Tailscale は 2 台の guest VM 内だけに導入する。
- Tailscale 上で通常の OpenSSH を使う。
- manager 専用 key を使う。
- worker 側では password lock 済み・non-sudo の `agent-worker` を使う。
- 導入済みの `kvm-agent-swarm-*` helper command を使う。

便利だからという理由だけで物理 host をこの worker tailnet に追加しないでください。
Tailscale SSH、exit node、subnet route、SSH agent forwarding、host directory share は
この workflow では使いません。

## どこで、どの account から実行するか

ここを区別することが重要です。

| 場所/account | 目的 | 主な command |
|---|---|---|
| Laptop_A の物理 host | 既存 VM に manager role を追加 | `./setup-kvm-agent.sh --add-swarm manager` |
| Desktop_B の物理 host | 既存 VM に worker role を追加 | `./setup-kvm-agent.sh --add-swarm worker` |
| manager VM 内の通常の sudo 可能 account | Tailscale 参加、worker 設定・利用 | `kvm-agent-swarm-tailscale-up`, `kvm-agent-swarm-configure-worker` |
| worker VM 内の通常の sudo 可能 account | Tailscale 参加、manager key 認可 | `kvm-agent-swarm-tailscale-up`, `sudo kvm-agent-swarm-authorize` |
| `agent-worker` account | remote job を自動受信 | 通常は対話 login しない |

`agent-worker` は graphical login 用 account ではありません。Password は lock され、
sudo 権限はなく、SSH TTY は禁止され、自分の authorized-key file を変更できません。

## Provisioning が自動化するもの

Swarm role を選ぶと、setup script は次を導入・準備します。

- Tailscale または WireGuard software
- manager 専用 Ed25519 key
- non-sudo `agent-worker` account と `~/jobs`
- 選択した overlay interface 向けの限定 UFW rule
- 重複しない device 名を設定する安全な Tailscale login helper
- manager key と worker SSH fingerprint を表示する command
- `StrictHostKeyChecking=yes` を使う worker host-key 検証
- 常に `agent-worker` と専用 key を使う SSH/rsync wrapper
- `submit`, `status`, `log`, `fetch`, `cancel`, `list` を持つ job helper

次の 2 つは、人間が trust を判断する必要があるため、意図的に自動化しません。

1. 各 VM を意図した Tailscale account に authenticate すること
2. manager public key を worker で authorize すること

Worker に API credential を作ったり、VM から物理 host への access を与えたりもしません。

## Tailscale setup: 1 step ずつ

### Step 1: Laptop_A で manager role を追加

**Laptop_A の物理 host**で repository directory から実行します。

```bash
./setup-kvm-agent.sh --add-swarm manager
```

新規 VM 作成時に指定する場合:

```bash
./setup-kvm-agent.sh --formal-methods --swarm-role manager
```

`--name` と `--user` は、その VM を初めから非既定値で作った場合だけ指定します。

### Step 2: Desktop_B で worker role を追加

**Desktop_B の物理 host**で実行します。

```bash
./setup-kvm-agent.sh --add-swarm worker
```

新規作成時に指定する場合:

```bash
./setup-kvm-agent.sh --formal-methods --swarm-role worker
```

既存 VM は再作成・削除されません。`--add-swarm` のときは VM が起動し、repository が
管理する recovery SSH key から到達可能である必要があります。

### Step 3: manager VM を Tailscale に参加させる

**manager VM 内の通常の sudo 可能 account**で実行します。

```bash
kvm-agent-swarm-tailscale-up laptop-a-manager
```

この command は次を指定して `tailscale up` を実行します。

- 重複しない MagicDNS device 名
- subnet route を accept しない
- Tailscale SSH を無効にする

Browser login URL が表示されるので、信頼する browser で開き、sign in します。最初の
sign-in なら Tailscale account/tailnet が作成されます。通常は Tailscale 専用の別 username
と password を作らず、選択した identity provider で認証します。

iPhone の Tailscale app は VM 間通信には不要です。iPhone でも sign in して有効にすると、
phone が tailnet の別 device として追加されるだけです。

### Step 4: worker VM を同じ tailnet に参加させる

**worker VM 内の通常の sudo 可能 account**で実行します。

```bash
kvm-agent-swarm-tailscale-up desktop-b-worker
```

Manager VM と同じ Tailscale identity/tailnet で authenticate してください。
`agent-worker` から実行しません。

両 VM で状態を確認します。

```bash
kvm-agent-swarm-status
```

`via DERP(fra)` と表示されても接続は機能しています。Direct peer-to-peer path を作れず、
暗号化済み traffic を relay しているという意味です。SSH、rsync、job helper の使い方は
direct 接続でも DERP でも同じです。

### Step 5: worker address と SSH fingerprint を取得

**worker VM 内の通常 account**で実行します。

```bash
kvm-agent-swarm-worker-info
```

次の 2 値を記録します。

```text
Tailscale IPv4: 100.x.y.z
SSH ED25519 host-key fingerprint: SHA256:...
```

Fingerprint は worker の SSH host public key から local に読み取ります。最初の network
接続で `StrictHostKeyChecking=accept-new` に盲目的に依存せず、manager が本物の worker を
検証するために使います。

### Step 6: worker で manager key を authorize

**manager VM**で:

```bash
kvm-agent-swarm-manager-info
```

`ssh-ed25519` で始まる 1 行全体を copy します。

**worker VM 内の通常 sudo account**で:

```bash
printf '%s\n' 'MANAGER_PUBLIC_KEY_1行全体をここへ貼る' |
  sudo kvm-agent-swarm-authorize
```

確認:

```bash
sudo kvm-agent-swarm-authorize --list
```

これが唯一不可避な pairing 操作です。Public key は secret ではありません。対応する
private key を worker へ copy してはいけません。

### Step 7: manager 側で worker を安全に登録

Step 5 の address と fingerprint を使い、**manager VM**で実行します。

```bash
kvm-agent-swarm-configure-worker \
  desktop-b-worker \
  SHA256:WORKER_HOST_FINGERPRINT
```

Address は Tailscale MagicDNS 名でも `100.x.y.z` address でも構いません。この helper は:

1. worker の ED25519 SSH host key を読む。
2. 信頼済み fingerprint と比較する。
3. 不一致なら接続を拒否する。
4. 検証済み key を専用 `~/.ssh/known_hosts_kvm_agent_swarm` に保存する。
5. `agent-worker`、専用 key、agent forwarding 無効、
   `StrictHostKeyChecking=yes` を固定した別 SSH config を作る。

通常の SSH config は弱めません。

### Step 8: 全接続を test

Manager VM で:

```bash
kvm-agent-swarm-test
```

出力には次が含まれるはずです。

```text
agent-worker
```

さらに worker account から `isabelle` が見えるかも表示します。Isabelle が system-wide に
provisioning されていれば、credential や user-local toolchain を copy せずに通常利用できます。

## 日常利用

### Remote command を 1 つ実行

```bash
kvm-agent-swarm-ssh 'hostname && whoami && nproc && free -h'
```

### File を手動 copy

Upload:

```bash
kvm-agent-swarm-rsync -a ./experiment/ \
  kvm-agent-worker:jobs/manual-test/
```

Download:

```bash
kvm-agent-swarm-rsync -a \
  kvm-agent-worker:jobs/manual-test/ \
  ./returned-manual-test/
```

`kvm-agent-worker` という special hostname は、swarm wrapper が使う専用 SSH config 内だけに
存在します。

### 管理 job を submit

`run-experiment.sh` を含む project なら:

```bash
JOB_ID="$(kvm-agent-swarm-job submit ./experiment \
  --timeout 7200 \
  -- ./run-experiment.sh)"

echo "$JOB_ID"
```

Helper は:

- `/home/agent-worker/jobs` に一意の directory を作る。
- rsync で project を送る。
- `timeout` と `nice` を使って実行する。
- SSH session から detach する。
- `run.log`, `pid`, `exit-status`, `finished` を記録する。
- 弱い worker で管理 job を同時に 1 つだけ実行する。

進捗:

```bash
kvm-agent-swarm-job status "$JOB_ID"
kvm-agent-swarm-job log "$JOB_ID" 80
```

結果取得:

```bash
kvm-agent-swarm-job fetch "$JOB_ID" "./remote-results/$JOB_ID"
```

Cancel:

```bash
kvm-agent-swarm-job cancel "$JOB_ID"
```

Job 一覧:

```bash
kvm-agent-swarm-job list
```

## Claude Code などから使う

Main agent は manager VM に残します。Worker に第 2 LLM agent や追加 OpenAI/Anthropic
credential は不要です。

Project instruction の例:

> 長時間の Isabelle experiment には `kvm-agent-swarm-job` を使う。必要な project
> directory だけを submit し、status/log を確認して結果を fetch する。Credential、
> browser data、private SSH key は worker に copy しない。

初めは helper invocation ごとに個別承認してください。任意の `ssh *` を恒久許可するより、
限定された `kvm-agent-swarm-job` を許可する方が安全です。

## よくある問題

### `Permission denied (publickey)` と `Authenticating ... as 'agent'`

Manager は通常の `agent` ではなく `agent-worker` として接続します。
`kvm-agent-swarm-test` または `kvm-agent-swarm-ssh` を使えば username と key は固定されます。

それでも失敗する場合:

```bash
# manager VM
kvm-agent-swarm-manager-info

# worker VM
sudo kvm-agent-swarm-authorize --list
```

### Graphical “Switch User” に `agent-worker` がない

正常です。Worker の通常 sudo account から確認します。

```bash
getent passwd agent-worker
id agent-worker
sudo -u agent-worker -H sh -lc 'whoami; echo "$HOME"; ls -la ~/jobs'
```

### Worker 再作成後の host-key mismatch

Disposable worker を再作成すると SSH host key は変わります。
`kvm-agent-swarm-worker-info` で新 fingerprint を local に確認後、manager で再実行します。

```bash
kvm-agent-swarm-configure-worker \
  desktop-b-worker \
  SHA256:NEW_VERIFIED_FINGERPRINT
```

`StrictHostKeyChecking=no` で回避しないでください。

### `tailscale ping` が DERP 経由だけ

Isabelle job には通常問題ありません。`UDP: true` でも、VM NAT・host network・router NAT の
組合せによって direct path を作れないことがあります。DERP を消すためだけに host SSH を
公開したり host firewall を弱めたりしないでください。File transfer が実際に遅い場合だけ
最適化します。

### 2 VM が互いに見えない

両方が同じ tailnet に authenticate されたか確認します。

```bash
tailscale status
tailscale ip -4
```

Worker が別 identity/tailnet ではなく `desktop-b-worker` として参加したかも確認します。

## Tailscale access policy

Guest firewall は `tailscale0` 上の worker SSH を許可しますが、tailnet でも deny-by-default
policy を推奨します。

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

既存 policy に merge し、無関係な rule を丸ごと置換しないでください。Worker から manager
への逆方向 grant は追加しません。

## Raw WireGuard alternative

Raw WireGuard を選ぶ場合:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --swarm-network wireguard
```

Script は `wireguard-tools` と interface-scoped UFW rule を準備しますが、peer address、到達可能
endpoint、key、VPS hub を安全に推測できません。各 guest で
`/etc/wireguard/wg0.conf` を手動作成します。

Broad network ではなく narrow peer route を推奨します。

```text
manager: 10.203.0.1/32
worker:  10.203.0.2/32
```

物理 LAN、libvirt network、`0.0.0.0/0` を worker tunnel に route しないでください。
Raw WireGuard は、片方に安定した到達可能 UDP endpoint がある場合、または信頼する hub を
運用する場合に適します。別々の NAT の背後を移動する 2 台には Tailscale の方が通常簡単です。

## Security boundary

Worker VM は disposable でも、Desktop_B の物理 host は trusted として守ります。

- Overlay は guest 内だけに導入する。
- 両物理 host は worker tailnet の外に置く。
- Host private key を VM 内に置かない。
- Host folder、libvirt socket、Docker socket、block device、USB/PCI device を worker に渡さない。
- `ssh -A` を使わない。
- API token と browser session を `agent-worker` に置かない。
- 回収した file と log は untrusted input として扱う。
- QEMU、KVM、libvirt、host kernel を更新する。

Worker VM の `authorized_keys` に物理 host の**public key**があること自体は危険ではありません。
これは host から guest へ authenticate できるという意味です。危険なのは、host へ入れる
**private key**を guest 内に置くことです。

Compromised manager は non-sudo worker account とその resource を制御できます。
Compromised worker は偽または malicious な結果を返せます。どちらにも物理 host への
credential path を与えないでください。

## Worker を廃棄・交換する

Worker VM を捨てる前に:

1. Tailscale admin console で device を remove/expire する。
2. 通常どおり worker VM を廃棄する。
3. replacement worker の新 SSH fingerprint を確認する。
4. manager で `kvm-agent-swarm-configure-worker` を再実行する。

保持する worker の manager authorization 確認・全削除:

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

Provisioning state と log:

```bash
kvm-agent-swarm-status
sudo tail -n 200 /var/log/kvm-agent-swarm.log
```

## 公式資料

- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale CLI: `tailscale up`](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale access-control grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
