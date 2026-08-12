# Ubuntu host または macOS 管理端末から安全に接続する

[English](remote-access.md)

この文書では、次の二種類の信頼済み端末を区別します。

- libvirt と VM を動かす**物理 Ubuntu host**
- Tailscale 経由で agent VM に接続する、別の**信頼済み Mac**

`YOUR_...` と書かれた語はすべて placeholder です。実際の値へ置き換えてください。
`research-a-manager` のような名前は、明示的に表示した例であり、必須の名前では
ありません。

## 最短の安全な手順

物理 Ubuntu host では、setup が `kvm-agent-host` を自動導入します。

```bash
kvm-agent-host list
kvm-agent-host ssh YOUR_LIBVIRT_VM_NAME
kvm-agent-host push YOUR_LIBVIRT_VM_NAME ./my-project Work/
kvm-agent-host pull YOUR_LIBVIRT_VM_NAME Work/agent-result.patch
```

`pull` の宛先を省略すると、
`~/vm-extraction-quarantine/YOUR_LIBVIRT_VM_NAME/` を作ります。転送は両方向とも
信頼済み host から開始します。Host の復旧 private key を VM へ渡しません。Pull 時は
実行権限を外し、device・special file・symbolic link を拒否します。これらは誤操作を
減らしますが、guest output を信頼済みにはしません。

信頼済み Mac から接続する場合:

1. Mac と VM を目的の tailnet に参加させます。
2. Mac 上で、この repository から次を実行します。

   ```bash
   ./macos/setup-secure-access.sh YOUR_VM_TAILSCALE_NAME
   ```

3. 表示された `kvm-agent-authorize-controller-key ...` command を、VM のローカル
   graphical terminal で実行します。
4. Mac から接続します。

   ```bash
   ssh YOUR_VM_TAILSCALE_NAME
   ```

5. この接続へ依存する前に、[複数の独立 swarm を一つの tailnet に置く](swarm_jp.md#一つの-tailnet-に複数の独立-swarm-を置く)
   の Tailscale 方向制御を完了します。

Mac helper はこの VM 専用の key を作ります。Passphrase の設定を推奨します。VM へ
登録するのは public key だけです。

## どの名前が何を指すのか

次の識別子は別々の仕組みに属します。似た名前にできますが、交換可能ではありません。

| 識別子 | 使う場所 | 明示的な例 |
|---|---|---|
| 物理 host の呼び名 | 自分のメモだけ | `ThinkPad host` |
| Libvirt VM 名 | `--name`、`virsh`、`kvm-agent-host` | `agent-research-a` |
| Guest Linux hostname | VM 内部 | `agent-research-a` |
| Guest login | SSH/Linux account | `agent` |
| Tailscale device 名 | Machines page、MagicDNS | `research-a-manager` |
| 複合 Tailscale tag | Tailnet policy | `tag:swarm-research-a-manager` |
| Mac SSH alias | `ssh ALIAS` | `research-a-manager` |

`--name` は **libvirt domain 名と guest Linux hostname** を意味します。物理 host の
名前ではありません。Swarm role も VM を改名しません。

既存 VM の libvirt 名は物理 Ubuntu host で確認します。

```bash
sudo virsh --connect qemu:///system list --all --name
```

既存 VM を変更する command では、`--name` が必須になりました。Option の省略で、
意図せず既定の `kvm-agent` を変更することを防ぎます。

## 廊下・扉・鍵: SSH と Tailscale の役割

SSH key と Tailscale policy は別の問題を解決します。

| 制御 | 答える問い | それだけでは行わないこと |
|---|---|---|
| Tailscale grants | A が B の TCP 22 番へ接続を開始してよいか | 通常の OpenSSH で Linux account を認証すること |
| SSH public/private key | SSH へ到達後、この client が login してよいか | 他の待受 service への scan・攻撃を止めること |
| Guest UFW | この interface で TCP/22 を受けるか | Tailscale tag で peer を識別すること |
| Mac SSH config | どの local key と forwarding 機能を使うか | Server や tailnet policy の代替 |

Tailscale policy は machine へ続く施錠された**廊下**です。SSH key は廊下の先にある
一つの**扉の鍵**です。Mac が private key を持ち、VM には対応する public key だけを
置きます。

SSH key だけでも、侵害された VM は Mac の private key を持たないため、通常は Mac へ
逆向き login できません。しかし allow-all tailnet では、他の peer の全 port へ到達し、
scan や攻撃を試せます。制限的な Tailscale policy は、別 service や SSH 認証に到達する
前に、その通信自体を遮断します。

許可済み接続への reply は返せます。Mac → manager を許可した SSH session のために、
manager → Mac の新規接続許可を追加する必要はありません。

## 物理 Ubuntu host から使う

`setup-kvm-agent.sh` は `~/.local/bin/kvm-agent-host` を導入します。初回 setup 後、
`libvirt` group membership が未反映なら、Ubuntu から一度 logout/login します。

```bash
kvm-agent-host list
kvm-agent-host status YOUR_LIBVIRT_VM_NAME
kvm-agent-host start YOUR_LIBVIRT_VM_NAME
kvm-agent-host shutdown YOUR_LIBVIRT_VM_NAME
kvm-agent-host ssh YOUR_LIBVIRT_VM_NAME
```

Helper は現在の DHCP lease を発見し、内部で次を固定します。

- VM ごとの復旧 key
- VM ごとの known-hosts file と、IP が変わっても一定の host-key alias
- `IdentityAgent=none`、`IdentitiesOnly=yes`、`ForwardAgent=no`
- `ForwardX11=no`、`ClearAllForwardings=yes`
- 有限の接続 timeout

`~/.local/share/kvm-agent/YOUR_LIBVIRT_VM_NAME/` の private key を VM へコピーしては
いけません。

## 信頼済み Mac を設定する

### 1. 通常の OpenSSH を安全に準備する

Mac 上で実行します。

```bash
./macos/setup-secure-access.sh YOUR_VM_TAILSCALE_NAME
```

既定以外の guest user または別 local alias を使う場合:

```bash
./macos/setup-secure-access.sh YOUR_VM_TAILSCALE_NAME \
  --alias YOUR_LOCAL_SSH_ALIAS \
  --user YOUR_GUEST_USER
```

この helper は:

- この VM 専用の Ed25519 key を、対話的な passphrase prompt 付きで作る。
- `~/.ssh/kvm-agent.d/` に分離した config を書く。
- `~/.ssh/config` の先頭へ安全に `Include` を追加し、既存 file は timestamp 付きで
  backup する。
- agent、X11、proxy、connection multiplex、port forwarding を無効にする。
- 専用 identity と専用 known-hosts file だけを使う。
- 一般 SSH agent へ自動 load せず、macOS Keychain support を有効にする。

VM への login や Tailscale policy の変更は行いません。

### 2. Mac の public key だけを登録する

Mac helper は次の形の完全な command を表示します。

```bash
kvm-agent-authorize-controller-key 'ssh-ed25519 AAAA... kvm-agent-controller:YOUR_ALIAS'
```

表示された command を、VM のローカル graphical terminal で通常 guest user として
実行します。上の省略例をコピーしてはいけません。

Guest helper は既存 key を残し、Ed25519 public key を検証してから、agent forwarding、
port forwarding、X11、`~/.ssh/rc` を key 単位で禁止します。VM 全体の SSH server baseline
も、password login、root login、agent/X11 forwarding、tunnel、既定では全 port
forwarding を独立して禁止します。

旧 repository で作った VM には、物理 Ubuntu host から現行 baseline を適用できます。

```bash
./setup-kvm-agent.sh \
  --harden-existing \
  --name YOUR_ACTUAL_LIBVIRT_VM_NAME
```

### 3. 初回 SSH host key を確認する

VM のローカル console で期待 fingerprint を確認します。

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Mac から初回接続し、表示された fingerprint を照合してから承認します。

```bash
ssh YOUR_LOCAL_SSH_ALIAS
```

VM を再作成すると host key が変わるため、SSH は mismatch で停止します。新しい key を
local console で確認してから、旧記録を置き換えてください。

## 自動生成する Mac option の意味

| Option | 値 | 理由 |
|---|---:|---|
| `ForwardAgent` | `no` | 侵害 VM が Mac の agent に別の認証を依頼することを防ぐ。 |
| `ForwardX11` | `no` | VM から Mac へ X11 channel を作らない。 |
| `ClearAllForwardings` | `yes` | 広い `Host *` の port-forward rule をこの alias では取り消す。 |
| `IdentityFile` | 専用 key | この VM に一用途の identity だけを使う。 |
| `IdentitiesOnly` | `yes` | 関係のない identity を試さない。 |
| `IdentityAgent` | `none` | 一般 SSH agent の cache を使わない。 |
| `UseKeychain` | `yes` | macOS がこの key の passphrase を保管できる。 |
| `AddKeysToAgent` | `no` | 復号 key を一般 agent に自動保持しない。 |
| `ConnectTimeout` | `15` | Offline VM への長い待機を避ける。隔離機能ではない。 |

`ForwardAgent no` と `ForwardX11 no` は OpenSSH の既定値でもありますが、明記することで、
後から加わった広い `Host *` が意図を変えることを防ぎます。OpenSSH は多くの option で
最初に得た値を使うため、installer は管理対象 `Include` を先頭へ置きます。

### Configuration file の場所

生成 file は無関係な SSH setting から分離します。

| Device | 管理対象 configuration |
|---|---|
| VM | `/etc/ssh/sshd_config.d/00-kvm-agent.conf` |
| VM guest account | controller key ごとの制限を持つ `~/.ssh/authorized_keys` |
| Mac | `~/.ssh/kvm-agent.d/YOUR_LOCAL_SSH_ALIAS.conf` |
| 物理 Ubuntu host | SSH config は変更せず、`kvm-agent-host` が command ごとに固定 option を渡す |

Internet 上の一般的な `sshd_config` を VM の main file へ上書きしないでください。
Review 済み drop-in は `--harden-existing` で再適用します。VM 内で server の実効値を
確認します。

```bash
sudo sshd -T | grep -E \
  '^(passwordauthentication|permitrootlogin|allowagentforwarding|allowtcpforwarding|allowstreamlocalforwarding|x11forwarding|permittunnel) '
```

接続前に Mac の実効値を確認します。

```bash
ssh -G YOUR_LOCAL_SSH_ALIAS | grep -Ei \
  '^(hostname|user|identityfile|identityagent|forwardagent|forwardx11|clearallforwardings|proxyjump|proxycommand) '
```

Client の `ForwardAgent no` は Mac の authentication agent を守り、server の
`AllowAgentForwarding no` は同じ channel を独立して拒否します。同様に client 側は
`ForwardX11 no`、server 側は `X11Forwarding no` です。両端を明記することで、片方の
設定漏れが channel を開く可能性を下げます。

`00-` prefix は意図的です。OpenSSH は多くの server option で最初に読んだ値を使うため、
cloud-image や package の drop-in より先に sort する必要があります。`90-...` へ改名すると、
先にある permissive な値が優先される場合があります。

## macOS から data を転送する

両方向とも信頼済み Mac から開始します。VM から結果を push するために Mac private key
を VM へ入れてはいけません。

Project を VM へ送る例:

```bash
scp -r ./my-project YOUR_LOCAL_SSH_ALIAS:Work/
```

小さな結果・patch を VM から pull する例:

```bash
mkdir -m 700 -p "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS"
scp YOUR_LOCAL_SSH_ALIAS:Work/agent-result.patch \
  "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS/"
chmod 600 \
  "$HOME/vm-extraction-quarantine/YOUR_LOCAL_SSH_ALIAS/agent-result.patch"
```

`scp` は macOS の OpenSSH client に同梱されています。Directory を送る、または pull
する時だけ `-r` を追加します。現在の OpenSSH はこの command に SFTP protocol を使うため、
legacy の `-O` option は追加しないでください。

Agent VM から取り出したものは全て非信頼 input として扱います。Review 前に実行、build、
IDE workspace としての open、重要 repository への移動を行わないでください。Working
tree 全体より patch の方が通常は確認しやすくなります。

```bash
git diff --binary > Work/agent-result.patch
```

## 任意の remote editor

安全な既定値は SSH port forwarding を禁止するため、通常 alias では VS Code
Remote-SSH 等は動きません。必要性が追加 channel の risk を上回る場合だけ、両端で opt-in
します。

物理 Ubuntu host:

```bash
./setup-kvm-agent.sh \
  --harden-existing \
  --name YOUR_ACTUAL_LIBVIRT_VM_NAME \
  --allow-remote-editor
```

Mac:

```bash
./macos/setup-secure-access.sh YOUR_VM_TAILSCALE_NAME \
  --add-remote-editor-alias
```

VM 内では表示された `--allow-port-forwarding` 付き command を使い、editor には
`YOUR_VM_TAILSCALE_NAME-editor` を指定します。通常 shell alias は
`ClearAllForwardings yes` のままです。Agent/X11 forwarding は両 alias とも無効です。

後で deny-forwarding baseline に戻すには、`--allow-remote-editor` なしで
`--harden-existing` を再実行し、key も `--allow-port-forwarding` なしで再登録します。

## `Permission denied (publickey)` の場合

この message は、MagicDNS、Tailscale route、VM の SSH server までは到達したことを
示します。残る問題は login key です。

順番に確認します。

1. Mac helper が、使用中 alias を作ったか。
2. 完全な public key を VM 内で登録したか。
3. `ssh -G YOUR_LOCAL_SSH_ALIAS | grep -Ei 'hostname|user|identityfile'` が期待値か。
4. VM 内の `~/.ssh` が mode `700`、`authorized_keys` が mode `600` か。

SSH password を有効にする、private key を VM へ入れる、`ForwardAgent yes` や
`StrictHostKeyChecking no` を使う方法で解決してはいけません。

## 参考

- [OpenSSH client configuration](https://man.openbsd.org/ssh_config)
- [Apple: OpenSSH and macOS Keychain](https://developer.apple.com/library/archive/technotes/tn2449/_index.html)
- [Tailscale tags](https://tailscale.com/docs/features/tags)
- [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants)
