# トラブルシューティング

[English](troubleshooting.md)

Setup script は既存 domain/disk を置き換えません。何かを削除する前に、失敗した段階を
特定してください。VM、base image、復旧 key、一時 provisioning 状態は別 object です。

## 小さな診断情報を集める

Host:

```bash
lsb_release -ds
id
ls -l /dev/kvm
virsh --connect qemu:///system list --all
virsh --connect qemu:///system net-info default
virsh --connect qemu:///system dominfo kvm-agent
virsh --connect qemu:///system domifaddr kvm-agent --source lease
```

Guest または復旧 SSH:

```bash
sudo cloud-init status --long
sudo tail -n 200 /var/log/kvm-agent-provision.log
sudo journalctl -u cloud-final -b --no-pager -n 200
sudo systemctl status gdm3 qemu-guest-agent ollama --no-pager --full
```

User name、path、IP address、repository URL、token、provider account 情報を確認せず
log を公開しないでください。

## `/dev/kvm` がない

症状:

```text
Error: /dev/kvm is unavailable.
```

確認:

```bash
lscpu | grep -i virtualization
lsmod | grep '^kvm'
```

UEFI/BIOS で Intel VT-x/VT-d または AMD-V/SVM を有効にします。Warm reboot で
firmware 設定が反映されない場合は完全 power off して再起動します。組織 firmware
policy によって設定が lock されている場合もあります。

Nested virtualization は別問題です。この Ubuntu host 自体が VM の場合、outer
hypervisor が virtualization extension を渡す必要があります。

## `virt-manager` に system VM が見えない／permission denied

初回 script は host account を `libvirt` へ追加しますが、既存 desktop process の
group list は変わりません。

Ubuntu host から完全 logout して再 login します。

```bash
id -nG
virsh --connect qemu:///system list --all
```

Group に `libvirt` が必要です。`kvm` は不要で、QEMU service account のための group
です。`sudo virt-manager` は使わないでください。Root 所有 GUI 設定や display
authority 問題を作るだけの悪い回避策です。

session ごとの認証にするため意図的に `libvirt` group から抜けた場合
（`SECURITY_jp.md` 参照）、`virt-manager` は接続時に管理者 password を求め、`virsh`
には `sudo` が必要になります。これは異常ではなく期待どおりの動作です。

GUI が別 user session ではなく **QEMU/KVM — System** に接続していることも確認します。
URI は `qemu:///system` です。

## Default network が起動しない

```bash
sudo virsh --connect qemu:///system net-info default
sudo virsh --connect qemu:///system net-dumpxml default
ip address show virbr0
sudo journalctl -u libvirtd -b --no-pager -n 200
```

よくある原因は `192.168.122.0/24` を使う別 network、古い `virbr0`、custom firewall、
部分的に定義された libvirt network です。

無関係な bridge/firewall rule をむやみに削除しないでください。標準 subnet と実
network が衝突する場合は、別 private libvirt network を意図的に定義し、script の
`LIBVIRT_NETWORK` と DHCP 前提を一緒に変更します。

## Ubuntu image の署名・checksum 検証が失敗

検証を迂回してはいけません。Host time と信頼 Ubuntu package を確認・更新します。

```bash
timedatectl
sudo apt update
sudo apt install --reinstall ubuntu-keyring ca-certificates
```

その後 retry します。Captive portal、TLS inspection proxy、不完全な mirror update、
古い keyring が原因になる場合があります。Cache image は、署名済み manifest 検証成功後
に記録した checksum と一致する場合だけ使います。

## VM または disk が既に存在

Script は overwrite せず失敗します。

```text
A libvirt VM named 'kvm-agent' already exists
```

有用な VM なら `virt-manager` から起動するか、別名を選びます。

```bash
./setup-kvm-agent.sh --name kvm-agent-02
```

失敗した作成だけに属する場合も先に検査します。

```bash
sudo virsh --connect qemu:///system dominfo kvm-agent
sudo virsh --connect qemu:///system domblklist kvm-agent --details
```

確認済み VM と選択 storage は `virt-manager` から削除するのが安全です。Bug report
から generic recursive deletion command をコピーしないでください。

## Script が VM address を見つけられない

```bash
sudo virsh --connect qemu:///system domstate kvm-agent
sudo virsh --connect qemu:///system domiflist kvm-agent
sudo virsh --connect qemu:///system domifaddr kvm-agent --source lease
sudo virsh --connect qemu:///system net-dhcp-leases default
```

GUI または serial console を開きます。Guest boot failure、cloud-init network failure、
inactive default network、手作業で付けた別 DHCP/network 設定によって address がない
可能性があります。

`qemu-guest-agent` 導入・起動後は次も使える場合があります。

```bash
sudo virsh --connect qemu:///system domifaddr kvm-agent --source agent
```

## SSH host-key conflict

各 VM 名に専用 file があります。

```text
~/.local/share/kvm-agent/VM_NAME/known_hosts
```

Setup script は同じ名前で新しい VM を作る際にこの file を破棄するため、setup 中の
conflict は想定外です。通常は、この file が有効なまま address を別 guest が再利用
したことを意味します。`virt-manager` と `virsh` で domain/address を先に確認し、
古い VM 専用 entry だけを除去します。

```bash
ssh-keygen -R VM_ADDRESS \
  -f ~/.local/share/kvm-agent/kvm-agent/known_hosts
```

Global に host-key checking を無効化してはいけません。

## Cloud-init error

実際に失敗した command を確認します。

```bash
sudo cloud-init status --long
sudo less /var/log/kvm-agent-provision.log
sudo less /var/log/cloud-init-output.log
```

典型的原因:

- 一時的 Ubuntu/upstream download failure。
- 公式 installer interface の変更。
- Disk/RAM 不足。
- Package manager interruption。
- DNS、proxy、certificate 問題。
- 新 release package による Aider dependency resolution failure。

Script は credential を追加しません。空の VM 内で provisioning に失敗した場合は、
log を保存し、失敗 guest を削除し、原因を直して新 VM を作るのが通常最も clean です。
部分的に provision された guest へ provider credential を追加しないでください。

## GUI が console/black screen のまま

Provisioning は server cloud image から始まります。`ubuntu-desktop-minimal` と
`gdm3` の導入完了後に desktop が現れます。

```bash
sudo cloud-init status --long
sudo systemctl status gdm3 --no-pager --full
sudo systemctl get-default
sudo journalctl -u gdm3 -b --no-pager -n 200
```

Default target は `graphical.target` です。初回 20～60 分の black screen は単に
desktop 導入中の場合があります。

`virt-manager` で SPICE display、virtio video device、SPICE channel を確認します。
手作業で変更した場合は VM shutdown 中に戻します。

## Mouse、解像度、clipboard 連携が動かない

Guest:

```bash
dpkg -l spice-vdagent
systemctl --user status spice-vdagentd.service --no-pager || true
ps aux | grep '[s]pice-vdagent'
```

`spice-vdagent` 導入・修復後、guest desktop から logout/relogin します。
`virt-manager` の SPICE channel も確認します。

Clipboard 連携は任意です。無効のままにすることも妥当な高安全側の選択です。

## Agent command が一つ見つからない

```bash
printf '%s\n' "$PATH"
ls -la ~/.local/bin ~/.opencode/bin
sudo cat /var/lib/kvm-agent/installed-versions.txt
```

新 terminal を開き、`/etc/profile.d/kvm-agent-tools.sh` と `~/.profile` を load
します。Cloud-init が成功していない場合は、credential を追加して不明な partial
state を使い続けず、provisioning を診断します。

## Ollama が使えない／広く公開された

```bash
systemctl status ollama --no-pager --full
systemctl cat ollama
curl http://127.0.0.1:11434/api/version
ss -ltnp | grep 11434
```

Effective service environment に次が必要です。

```text
OLLAMA_HOST=127.0.0.1:11434
```

Listener は `0.0.0.0:11434`、`[::]:11434`、`*:11434` であってはいけません。

Drop-in 修復後:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Guest-local client 設定問題を解決するためだけに Ollama を LAN 公開しないでください。

## Guest から自分の network 上の機器へ到達できない

既定では guest firewall が private address space への外向き通信を拒否するため、
社内 package mirror、NAS、printer、LAN 上の model endpoint へは VM 内から到達でき
ません。internet 接続には影響しません。

適用中の rule を確認します。

```bash
sudo ufw status verbose
```

想定される rule は、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、
`169.254.0.0/16` への外向き通信を拒否し、libvirt gateway への DNS と DHCP、および
その gateway からの inbound SSH のみを許可するものです。

社内の特定の宛先だけを許可する場合は、firewall を無効化せず deny rule より前に
狭い rule を挿入します。

```bash
sudo ufw insert 1 allow out to MIRROR_ADDRESS port 443 proto tcp
```

private range への外向き通信を全般に許可する場合は `--allow-lan` で作り直します。
これは private・link-local outbound deny rule を省きますが、UFW 自体は無効化しません。
未要求の inbound 通信は拒否されたままで、復旧 SSH も libvirt gateway だけに限定
されます。これは guest 側の既定値であり、sudo を持つ agent は変更できます。policy を
必ず維持したい場合は、guest interface の libvirt `nwfilter` として記述してください。

## Cloud-init seed が残っている

`/var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img` はゲストパスワードの hash を
含むため、setup script はプロビジョニング完了後に eject して shred します。`--no-wait`
を使った場合、または eject に失敗して警告が出た場合には残ります。

通常の完了待ち経路では、プロビジョニングと必要な初回 reboot が成功した後、
`/etc/cloud/cloud-init.disabled` も作成します。これにより将来の cloud-init 実行を
防ぐため、その後の status command は `disabled` と表示する場合があります。
provisioning marker と log は残ります。

```bash
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
sudo tail -n 160 /var/log/kvm-agent-provision.log
```

`--no-wait` を使った場合は、provisioning marker が存在することを確認した後にだけ
disable marker を手動で作り、その後 seed を eject・削除してください。

どの device が保持しているかを確認し、eject してから file を削除します。

```bash
sudo virsh --connect qemu:///system domblklist NAME --details
sudo virsh --connect qemu:///system change-media NAME sda --eject --live --config --force
sudo shred --remove --zero /var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img
```

保存された設定からのみ eject できた場合でも問題ありません。動作中の domain は次回
shutdown 時に file を解放します。

ここでの `shred` は「削除し、その前に上書きを試みる」という意味です。SSD、
copy-on-write filesystem、階層化された storage では、古い block が消えたことを保証
できません。seed が存在した間に host の root 権限を持っていた者にはゲストパスワード
が開示されたものとみなし、他で使い回していないパスワードを選んでください。
