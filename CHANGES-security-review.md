# Changes from the security review

Applied to the single-script GUI variant. Each entry names what changed and why,
so a reviewer can judge the reasoning rather than only the diff.

## Host account privilege

The host account is added to `libvirt` only, never to `kvm`. The `kvm` group
belongs to the QEMU service account; putting a human in it bought nothing and
made the VM disk and the cloud-init seed readable by that human.

No second host account was introduced. The `vmadmin` / `devui` split is not
what contains the agent — KVM does that, identically either way. What the split
changes is the blast radius after the *host* desktop account is compromised, and
the privilege held by the account rendering untrusted guest output on the
console. `SECURITY.md` states that residual risk directly.

It does not offer a way to keep one account and drop the ambient part of the
privilege. Ubuntu configures libvirt for group-based socket access rather than
polkit authentication, so leaving the `libvirt` group removes access to
`qemu:///system` instead of downgrading to a per-session prompt. An earlier
draft of these changes recommended exactly that and was wrong; the docs now say
what reconfiguring it would actually involve, and otherwise point at using a
dedicated VM host.

## Cloud-init seed

- created `0600 root:root` instead of `0640 root:kvm` (libvirt and QEMU still
  reach it while the domain runs);
- disabled future cloud-init runs after successful provisioning and any
  required first reboot; and
- ejected from the domain and removed once provisioning completes, with a
  best-effort overwrite — `shred` cannot guarantee erasure on SSDs or
  copy-on-write storage, so the guest password should not be reused elsewhere.

The seed carries the guest password's SHA-512 crypt hash. Previously it stayed
attached as a CD-ROM for the life of the VM and was readable by the `kvm` group.
The `--no-wait` path cannot clean up, so the README and troubleshooting docs
give the manual steps.

## SPICE console

`--graphics spice,listen=none` replaces `listen=127.0.0.1`. Loopback still meant
any local account on the host could attach to the console; with no listener,
`virt-manager` reaches it through libvirt and no socket exists.

## Guest network policy

New default: the guest firewall denies outbound traffic to `10/8`,
`172.16/12`, `192.168/16`, and link-local ranges, while leaving internet access
open. It is configured before the first vendor installer is downloaded, so no
third-party code runs in the guest with private-range access. DNS and DHCP to
the libvirt gateway are allowed, and inbound SSH is accepted only from that
gateway. `--allow-lan` omits the outbound private/link-local denies for internal
mirrors or model endpoints; it no longer disables UFW or the inbound policy.

This normally closes the guest's reach into the host, other guests, and the
physical LAN. It does not cover locally routed public addresses. The policy
lives inside the guest, so it is a default rather than a boundary — the docs
say so, and point at libvirt `nwfilter` for anyone who needs enforcement.

## Installer staging in the guest

Installers are staged in a root-owned `/run/kvm-agent-install` (mode `0711`)
instead of predictable `/tmp` paths, and each file stays root-owned and
read-only while it runs. This removes both the symlink-pre-creation target for a
root-run `curl --output` and the window in which the guest account could alter
an installer between download and execution.

Ollama's installer is invoked as root, since it registers a systemd unit. The
other installers run as `agent`, which holds unrestricted passwordless sudo, so
all of them have effective guest-root capability; the docs say this plainly
rather than singling Ollama out.

## Cleanup no longer deletes live VM disks

`cleanup()` distinguishes three states via `sudo -n virsh list --all --name`:
domain present, domain absent, or libvirt unreachable. Only "absent" removes
artifacts. Previously any `sudo` or `virsh` failure at exit time was read as
"the domain does not exist", which deleted the disk of a VM that did exist.
`sudo -n` also avoids a password prompt hanging during exit handling.

## Rebuilding a VM under an existing name

The stale per-VM `known_hosts` file is discarded when a new VM is created. A
reused name previously produced a host-key mismatch — a hard failure under
`accept-new` — fifteen minutes into the SSH wait, with a misleading message.

## CPU model

`--cpu host-model` replaces `host-passthrough`, narrowing the host CPU feature
set exposed to a guest that exists to run untrusted code. Minor.

## Tests

- `tests/check-repository.sh` asserts the new required strings and now also
  asserts that the replaced patterns (`/tmp/kvm-agent-install-`,
  `usermod -aG libvirt,kvm`, `listen=127.0.0.1`) are absent.
- `tests/mock-setup.sh` mocks `virsh net-dumpxml`, `list`, `domblklist`, and
  `change-media`, tolerates `sudo -n`, and asserts that the seed is ejected and
  removed.
- The mock now supplies a fixed `/proc/meminfo`, so the suite runs on hosts with
  less RAM than the guest defaults require.

## Documentation

`SECURITY.md` / `SECURITY_jp.md` replace the flat "Default protections" list
with two lists: controls enforced outside the guest, which hold even against a
fully compromised `agent` account, and defaults inside the guest, which that
account can remove with one command. The network model, privilege, design,
daily-use, troubleshooting, and agent-tools docs were updated to match, in both
languages.

## Not changed

- The guest `agent` account keeps passwordless sudo. The VM remains the
  security boundary.
- Third-party installers are still fetched from vendor release channels without
  pinning or signature verification. They run inside the guest; the existing
  supply-chain caveat still applies.
- Network policy is a guest-side default, not a host-enforced `nwfilter`.
- The tests exercise the mocked success path and string presence. They do not
  cover the cleanup failure states, real ufw behaviour, SPICE, or an actual KVM
  launch.
