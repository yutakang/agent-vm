# Troubleshooting

[日本語版](troubleshooting_jp.md)

The setup script refuses to replace an existing domain or disk. Diagnose the
specific phase before deleting anything. The VM, base image, recovery key, and
temporary provisioning state are separate objects.

## Collect a small diagnostic set

On the host:

```bash
lsb_release -ds
id
ls -l /dev/kvm
virsh --connect qemu:///system list --all
virsh --connect qemu:///system net-info default
virsh --connect qemu:///system dominfo kvm-agent
virsh --connect qemu:///system domifaddr kvm-agent --source lease
```

Inside the guest or over recovery SSH:

```bash
sudo cloud-init status --long
sudo tail -n 200 /var/log/kvm-agent-provision.log
sudo journalctl -u cloud-final -b --no-pager -n 200
sudo systemctl status gdm3 qemu-guest-agent ollama --no-pager --full
```

Do not publish logs without checking them for user names, paths, IP addresses,
repository URLs, tokens, or provider account information.

## `/dev/kvm` is unavailable

Symptoms:

```text
Error: /dev/kvm is unavailable.
```

Check:

```bash
lscpu | grep -i virtualization
lsmod | grep '^kvm'
```

Enable Intel VT-x/VT-d or AMD-V/SVM in UEFI/BIOS. Completely power off and
restart if the firmware setting does not take effect after a warm reboot.
Corporate firmware policy may lock the setting.

Nested virtualization is a separate case. If this Ubuntu host is itself a VM,
its outer hypervisor must expose virtualization extensions.

## `virt-manager` shows no system VMs or permission denied

The first script run adds the host account to `libvirt`, but existing desktop
processes keep their old group list.

Log out of the Ubuntu host completely and log back in. Then:

```bash
id -nG
virsh --connect qemu:///system list --all
```

The groups should include `libvirt`. There is no need for `kvm`: that group
belongs to the QEMU service account. Do not run `virt-manager` with `sudo`;
root-owned GUI configuration and display-authority problems are a poor
workaround.

If you deliberately removed yourself from `libvirt` so that authorisation is
per-session (see `SECURITY.md`), `virt-manager` prompts for an administrator
password on connect and `virsh` needs `sudo`. That is expected, not a fault.

Confirm the GUI is connected to **QEMU/KVM — System**, not a separate user
session. The URI should be `qemu:///system`.

## The default network will not start

Check:

```bash
sudo virsh --connect qemu:///system net-info default
sudo virsh --connect qemu:///system net-dumpxml default
ip address show virbr0
sudo journalctl -u libvirtd -b --no-pager -n 200
```

Common causes are another network already using `192.168.122.0/24`, a stale
`virbr0`, firewall customization, or a partially defined libvirt network.

Do not delete unrelated bridges or firewall rules blindly. If the standard
subnet conflicts with a real network, define a different private libvirt
network deliberately and update the script's `LIBVIRT_NETWORK` and DHCP
expectations together.

## Ubuntu image signature or checksum verification fails

Do not bypass the verification.

Check host time and update the trusted Ubuntu packages:

```bash
timedatectl
sudo apt update
sudo apt install --reinstall ubuntu-keyring ca-certificates
```

Then retry. A captive portal, TLS-inspecting proxy, incomplete mirror update,
or stale keyring can cause failure. The cached image is used only if it matches
the checksum recorded after a successful signed-manifest verification.

## A VM or disk already exists

The script fails rather than overwriting:

```text
A libvirt VM named 'kvm-agent' already exists
```

If it is a useful VM, start it in `virt-manager` or choose another name:

```bash
./setup-kvm-agent.sh --name kvm-agent-02
```

If it belongs only to a failed creation, inspect it first:

```bash
sudo virsh --connect qemu:///system dominfo kvm-agent
sudo virsh --connect qemu:///system domblklist kvm-agent --details
```

Prefer deleting the confirmed VM and selected storage through `virt-manager`.
Do not copy a generic recursive deletion command from a bug report.

## The script cannot find a VM address

Check:

```bash
sudo virsh --connect qemu:///system domstate kvm-agent
sudo virsh --connect qemu:///system domiflist kvm-agent
sudo virsh --connect qemu:///system domifaddr kvm-agent --source lease
sudo virsh --connect qemu:///system net-dhcp-leases default
```

Open the graphical or serial console. An address may be missing because the
guest did not boot, cloud-init networking failed, the default network is
inactive, or another DHCP/network configuration was manually attached.

Once `qemu-guest-agent` is installed and active, this may also work:

```bash
sudo virsh --connect qemu:///system domifaddr kvm-agent --source agent
```

## SSH reports a host-key conflict

Each VM name has a dedicated file:

```text
~/.local/share/kvm-agent/VM_NAME/known_hosts
```

The setup script discards this file when it builds a new VM under an existing
name, so a conflict during setup is unexpected. It normally means the address
was reused by a different guest while the file was current. Confirm the domain
and address in `virt-manager` and `virsh` first. Then remove only the stale
per-VM entry:

```bash
ssh-keygen -R VM_ADDRESS \
  -f ~/.local/share/kvm-agent/kvm-agent/known_hosts
```

Never disable host-key checking globally.

## Cloud-init reports an error

Get the actual failing command:

```bash
sudo cloud-init status --long
sudo less /var/log/kvm-agent-provision.log
sudo less /var/log/cloud-init-output.log
```

Typical causes:

- temporary Ubuntu or upstream download failure;
- an official installer changed its interface;
- insufficient disk space or RAM;
- a package-manager interruption;
- DNS, proxy, or certificate problems; or
- Aider dependency resolution failing for a newly released package.

The script installs credentials only after none—it does not add any. If
provisioning failed in an otherwise empty VM, the cleanest response is usually
to preserve logs, delete that failed guest, correct the cause, and create a new
VM. Do not add provider credentials to a partially provisioned guest.

## The GUI shows only a console or black screen

Provisioning begins from a server cloud image. The desktop appears only after
`ubuntu-desktop-minimal` and `gdm3` finish installing.

Check:

```bash
sudo cloud-init status --long
sudo systemctl status gdm3 --no-pager --full
sudo systemctl get-default
sudo journalctl -u gdm3 -b --no-pager -n 200
```

The default target should be `graphical.target`. A black screen during the
initial 20–60 minutes can simply mean the desktop is still being installed.

In `virt-manager`, confirm the VM has a SPICE display, a virtio video device,
and a SPICE channel. If these were manually changed, restore them while the VM
is shut down.

## Mouse, resolution, or clipboard integration does not work

Inside the guest:

```bash
dpkg -l spice-vdagent
systemctl --user status spice-vdagentd.service --no-pager || true
ps aux | grep '[s]pice-vdagent'
```

Log out of the guest desktop and back in after installing or repairing
`spice-vdagent`. Confirm the SPICE channel exists in `virt-manager`.

Clipboard integration is optional. Leaving it disabled is a valid higher-safety
choice.

## One agent command is missing

Check the explicit guest paths:

```bash
printf '%s\n' "$PATH"
ls -la ~/.local/bin ~/.opencode/bin
sudo cat /var/lib/kvm-agent/installed-versions.txt
```

Open a new terminal so `/etc/profile.d/kvm-agent-tools.sh` and `~/.profile` are
loaded. If cloud-init did not finish successfully, diagnose provisioning rather
than installing credentials and continuing with an unknown partial state.

## Ollama is unavailable or exposed too broadly

Check:

```bash
systemctl status ollama --no-pager --full
systemctl cat ollama
curl http://127.0.0.1:11434/api/version
ss -ltnp | grep 11434
```

The effective service environment must contain:

```text
OLLAMA_HOST=127.0.0.1:11434
```

and the listener must not be `0.0.0.0:11434`, `[::]:11434`, or `*:11434`.

After repairing the drop-in:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Do not expose Ollama on the LAN merely to solve a guest-local client
configuration error.

## The guest cannot reach something on your own network

By default the guest firewall denies outbound traffic to private address space,
so an internal package mirror, a NAS, a printer, or a model endpoint on your LAN
is unreachable from inside the VM. Internet access is unaffected.

Check what is in force:

```bash
sudo ufw status verbose
```

The intended rules deny `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, and
`169.254.0.0/16` outbound, while allowing DNS and DHCP to the libvirt gateway
and inbound SSH from that gateway only.

To allow one internal destination, add a narrow rule ahead of the deny rules
rather than disabling the firewall:

```bash
sudo ufw insert 1 allow out to MIRROR_ADDRESS port 443 proto tcp
```

To permit private-range egress generally, recreate the VM with `--allow-lan`.
This omits the outbound private/link-local deny rules but does not disable UFW:
unsolicited inbound traffic remains denied and recovery SSH remains limited to
the libvirt gateway. Remember that this is a guest-side default: an agent with
sudo can still change it. Where the policy must hold regardless, express it as
a libvirt `nwfilter` on the guest interface instead.

## The cloud-init seed is still present

The setup script ejects and shreds
`/var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img` once provisioning
finishes, because it contains the guest password hash. It is still there when
the run used `--no-wait`, or when the eject failed and the script warned about
it.

On the normal waited path, the script also creates
`/etc/cloud/cloud-init.disabled` after successful provisioning and any required
first reboot. This prevents future cloud-init runs; the status command may
therefore report `disabled` afterward. The provisioning marker and log remain:

```bash
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
sudo tail -n 160 /var/log/kvm-agent-provision.log
```

With `--no-wait`, create the disable marker yourself only after the provisioning
marker exists, then eject and remove the seed.

Confirm which device holds it, eject it, then remove the file:

```bash
sudo virsh --connect qemu:///system domblklist NAME --details
sudo virsh --connect qemu:///system change-media NAME sda --eject --live --config --force
sudo shred --remove --zero /var/lib/libvirt/images/kvm-agent/vms/NAME-seed.img
```

Ejecting only from the saved configuration is fine; the running domain releases
the file at its next shutdown.

`shred` here means "remove, and attempt to overwrite first". On SSDs,
copy-on-write filesystems, and layered storage it cannot guarantee the old
blocks are gone. Treat the guest password as disclosed to anyone who held root
on the host while the seed existed, and choose a password you do not use
elsewhere.
