# Cross-host manager/worker VMs

[日本語版](swarm_jp.md)

This optional profile lets an agent in one disposable VM submit bounded work to
a non-sudo account in another disposable VM. Most users do not need it.

All `YOUR_...` words below are placeholders. Replace them. Names such as
`research-a` are explicitly labelled examples, not required names.

## Read this before typing commands

Use the following shape:

- Tailscale runs **inside the guest VMs**, not on either physical host;
- ordinary OpenSSH runs over Tailscale; Tailscale SSH stays off;
- the manager may initiate TCP/22 to its worker;
- a trusted Mac may initiate TCP/22 to a manager, but not to workers;
- workers cannot initiate connections to managers, the Mac, or other groups;
- SSH private keys never leave the trusted device that created them; and
- host directories, libvirt sockets, and device passthrough are not shared.

Configure the Tailscale policy **before joining tagged VMs**. The join helper
stops if Tailscale does not grant the requested tag, but an existing broad
allow rule can still defeat subgroup isolation. The policy tests below catch
that common mistake.

For Mac access and the roles of Tailscale versus SSH keys, first read
[Secure remote access](remote-access.md#corridor-door-and-key-ssh-versus-tailscale).

## Names and command locations

These identifiers serve different purposes. Keep machine identity stable by
using one unique VM name for libvirt, the guest hostname, Tailscale, and the
Mac SSH alias. Keep the swarm group in the tag/policy layer.

| Identifier | Placeholder | Recommended example |
|---|---|---|
| Manager VM/libvirt/hostname/Tailscale name | `YOUR_MANAGER_LIBVIRT_VM_NAME` | `vm-manager-01` |
| Worker VM/libvirt/hostname/Tailscale name | `YOUR_WORKER_LIBVIRT_VM_NAME` | `vm-worker-01` |
| Swarm group | `YOUR_SWARM_GROUP` | `research-a` |
| Manager tag | derived as `tag:swarm-GROUP-manager` | `tag:swarm-research-a-manager` |
| Worker tag | derived as `tag:swarm-GROUP-worker` | `tag:swarm-research-a-worker` |

`--name` during VM setup sets the libvirt VM name and guest Linux hostname. A
swarm role does not rename the VM. When joining Tailscale, pass that same guest
hostname explicitly so the Tailscale device name stays identical.

| Where to run | Purpose | Commands |
|---|---|---|
| Physical Ubuntu host of each VM | Add or repair a role | `./setup-kvm-agent.sh --add-swarm ... --name ...` |
| Manager VM, normal guest account | Join Tailscale, pair and run work | `kvm-agent-swarm-tailscale-up`, `kvm-agent-swarm-configure-worker`, job helpers |
| Worker VM, normal sudo-capable guest account | Join Tailscale and authorize one manager public key | `kvm-agent-swarm-tailscale-up`, `sudo kvm-agent-swarm-authorize` |
| Trusted Mac | Control a manager and pull reviewed results | `ssh`, `scp`; see [remote access](remote-access.md) |

Do not run `setup-kvm-agent.sh` inside a VM. Do not run a guest helper on a
physical host.

## What setup automates

The swarm profile installs and configures:

- Tailscale or, for advanced manual setups, WireGuard tools;
- UFW rules exposing only TCP/22 on the chosen overlay interface;
- a guest-local Ed25519 manager key used only for manager-to-worker jobs;
- a locked, non-sudo `agent-worker` account;
- root-owned worker authorization with SSH forwarding and TTY disabled;
- verified ED25519 host-key pinning;
- SSH and rsync wrappers whose transport cannot be overridden; and
- a one-job-at-a-time helper with timeout, log, status, fetch, and cancel.

Setup cannot safely decide who owns a tailnet, approve tags, select peer
identities, or compare a first-use SSH fingerprint. Those remain visible human
steps.

## One swarm: safe setup in order

### 1. Add the two roles from their physical Ubuntu hosts

On the physical host that runs the manager VM:

```bash
./setup-kvm-agent.sh \
  --add-swarm manager \
  --name YOUR_MANAGER_LIBVIRT_VM_NAME
```

On the physical host that runs the worker VM:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --name YOUR_WORKER_LIBVIRT_VM_NAME
```

For a new VM, use `--swarm-role manager` or `--swarm-role worker` together
with an explicit `--name` during initial setup. Separate manager and worker VMs
are recommended. A `both` role needs a separate `tag:swarm-GROUP-swarm` policy
and has a larger compromise radius.

All existing-VM operations require an explicit `--name`; list the real names
first if unsure:

```bash
sudo virsh --connect qemu:///system list --all --name
```

### 2. Add the subgroup policy before joining

Create the tags and grants described in
[Multiple independent swarms in one tailnet](#multiple-independent-swarms-in-one-tailnet).
For one group, keep only that group's entries. Remove or narrow any existing
allow-all rule, merge unrelated necessary rules carefully, and save only when
the policy tests pass.

### 3. Join each guest with the same group and its existing VM name

Inside the manager VM:

```bash
kvm-agent-swarm-tailscale-up \
  --group YOUR_SWARM_GROUP \
  --name "$(hostname)"
```

Inside the worker VM:

```bash
kvm-agent-swarm-tailscale-up \
  --group YOUR_SWARM_GROUP \
  --name "$(hostname)"
```

The explicit `--name "$(hostname)"` keeps the Tailscale device name identical
to the VM/libvirt/guest name. The helper derives the single composite role tag
from the group, then runs `tailscale up` with a reset configuration, subnet
routes rejected, no exit node, and Tailscale SSH disabled. Complete the browser
authentication for the intended tailnet. The physical hosts are not enrolled.

For compatibility, omitting `--name` is still supported; in that case the
helper derives a device name such as `research-a-manager`. That is convenient
for quick swarm-only deployments, but using the existing unique VM name is the
recommended convention for machines you operate directly.

Verify in both VMs:

```bash
kvm-agent-swarm-status
```

Stop if the output says `SECURITY WARNING`, shows no device tag, shows the
wrong group, or shows a different tailnet. A `via DERP(...)` path is encrypted
and functional; it may only be slower than a direct path.

### 4. Pair the manager SSH key with the worker

In the worker VM, record the local address and host-key fingerprint:

```bash
kvm-agent-swarm-worker-info
```

In the manager VM, display the manager public key:

```bash
kvm-agent-swarm-manager-info
```

Copy only the complete line beginning with `ssh-ed25519`. In the worker VM,
paste that public line into this command:

```bash
printf '%s\n' 'PASTE_THE_COMPLETE_MANAGER_PUBLIC_KEY_HERE' |
  sudo kvm-agent-swarm-authorize
```

The public key is not secret. The matching private key remains in the manager
VM at `~/.ssh/id_ed25519_kvm_agent_swarm`; never copy it to the worker or a
physical host. It has no passphrase because scheduled guest-to-worker jobs are
non-interactive. Compromise of the manager therefore exposes every worker that
authorizes it.

Verify the worker authorization:

```bash
sudo kvm-agent-swarm-authorize --list
```

### 5. Pin the worker host key on the manager

Back in the manager VM, use the worker Tailscale name and the fingerprint read
locally in the worker:

```bash
kvm-agent-swarm-configure-worker \
  YOUR_WORKER_TAILSCALE_NAME \
  SHA256:PASTE_THE_WORKER_HOST_FINGERPRINT
```

For a worker named `vm-worker-01`, use `vm-worker-01` here as well. The helper
refuses a fingerprint mismatch and creates a dedicated SSH config using
the `agent-worker` account, the guest-local key, `ForwardAgent no`,
`ForwardX11 no`, and `StrictHostKeyChecking yes`.

Test the complete connection:

```bash
kvm-agent-swarm-test
```

Expected output includes `agent-worker`.

## Multiple independent swarms in one tailnet

Do not attach a general `manager` tag plus a general `research-a` tag and
expect Tailscale to require both. Permissions from multiple tags are additive,
not an intersection. KVM-Agent therefore requests one composite tag per VM.

This example defines two independent groups named `research-a` and
`research-b`. The trusted Mac's example Tailscale IPv4 address is
`100.64.0.10`; replace it with the exact output of `tailscale ip -4` on the
Mac. The policy gives that IP the explicit host alias `trusted-mac`. Using the
exact device IP avoids granting every device signed in as the same human user.

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

Merge this with necessary existing policy; do not overwrite unrelated rules
blindly. The explicit `"acls": []` is important: omitting the legacy `acls`
field can activate Tailscale's default allow-all policy. Do not retain a broad
ACL or grant such as source `*` to destination `*`; permissions are additive,
so it overrides the intended isolation. The `deny` entries above are policy
tests, not explicit deny rules; they make the editor reject a policy that
accidentally permits those paths.

For a third group, add two new composite tags, one manager-to-worker grant, the
Mac-to-manager destination if required, and matching positive and negative
tests. Join both VMs with that new group name. Never reuse one group's tags for
another group.

Tagged devices are no longer user-owned Tailscale nodes. `tagOwners` controls
who may assign a tag; grants control what a tagged node may contact. The join
helper verifies the requested tag after authentication.

## Daily manager use

Run one command:

```bash
kvm-agent-swarm-ssh 'hostname && whoami && nproc && free -h'
```

Upload or retrieve a directory through the pinned transport:

```bash
kvm-agent-swarm-rsync -a --protect-args ./experiment/ \
  kvm-agent-worker:jobs/manual-test/

kvm-agent-swarm-rsync -a --protect-args \
  kvm-agent-worker:jobs/manual-test/ ./returned-manual-test/
```

The special `kvm-agent-worker` name exists only in the wrapper's dedicated SSH
configuration. The wrapper rejects another remote alias and rejects attempts
to override its SSH transport.

Submit a bounded background job:

```bash
kvm-agent-swarm-job submit ./experiment \
  --timeout 7200 \
  -- ./run-experiment.sh
```

The command prints a `job-...` identifier. Use it directly in place of
`YOUR_JOB_ID`:

```bash
kvm-agent-swarm-job status YOUR_JOB_ID
kvm-agent-swarm-job log YOUR_JOB_ID 80
kvm-agent-swarm-job fetch YOUR_JOB_ID ./remote-results/YOUR_JOB_ID
kvm-agent-swarm-job cancel YOUR_JOB_ID
kvm-agent-swarm-job list
```

The helper copies the selected directory, runs one job at a time as the
non-sudo worker account with `timeout` and `nice`, detaches it, and records its
log and exit status. Its command payload is still arbitrary code in that
account; the helper is not a command allow-list.

Keep model-provider credentials on the manager. A useful agent instruction is:

> For long experiments, use `kvm-agent-swarm-job`. Submit only the required
> project directory, inspect status and logs, and fetch results. Never copy
> credentials, browser data, or private SSH keys to the worker.

## Common problems

### `Permission denied (publickey)`

Use `kvm-agent-swarm-test` or `kvm-agent-swarm-ssh`; they always select
`agent-worker` and the dedicated key. Compare the manager public key with the
worker's root-owned authorization:

```bash
kvm-agent-swarm-manager-info
sudo kvm-agent-swarm-authorize --list
```

Run the first command in the manager and the second in the worker.

### Host-key mismatch after replacing a worker

This is expected for a rebuilt VM. Read its new fingerprint locally with
`kvm-agent-swarm-worker-info`, then rerun `kvm-agent-swarm-configure-worker` in
the manager. Never use `StrictHostKeyChecking=no`.

### Peers are visible but SSH is blocked

Check both guests:

```bash
kvm-agent-swarm-status
tailscale status
tailscale ip -4
```

Confirm the exact group tags, inspect Tailscale policy test results, and check
that the manager key is authorized. Do not solve it by adding an allow-all
grant, enabling passwords, or opening physical-host SSH.

## Raw WireGuard alternative

Raw WireGuard is an advanced, manual alternative:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --name YOUR_WORKER_LIBVIRT_VM_NAME \
  --swarm-network wireguard
```

The script installs `wireguard-tools` and interface-scoped UFW rules. It cannot
safely invent peer addresses, endpoints, keys, or a hub, so an operator must
create `/etc/wireguard/wg0.conf` in each guest. Use narrow peer routes, for
example manager `10.203.0.1/32` and worker `10.203.0.2/32`. Never route a
physical LAN, libvirt network, or `0.0.0.0/0` through the worker. Tailscale is
normally easier for machines behind unrelated NATs.

## Security boundary and replacement

The worker VM is disposable; both physical hosts remain trusted. A compromised
manager can control every worker that authorizes its key. A compromised worker
can consume its guest resources and return malicious output. Neither should
have a credential path to a physical host.

- Keep the overlay inside guests only.
- Never share host folders, libvirt or Docker sockets, block devices, or USB.
- Never use `ssh -A` or place a host private key in a guest.
- Keep API tokens and browser sessions out of `agent-worker`.
- Treat fetched files and logs as untrusted until reviewed.
- Keep QEMU, KVM, libvirt, and both host kernels updated.

Before discarding a worker, remove or expire its Tailscale device. On a retained
worker, inspect or clear manager authorizations with:

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

After replacement, verify the new SSH fingerprint locally and reconfigure the
manager. Diagnostics are available with:

```bash
kvm-agent-swarm-status
sudo tail -n 200 /var/log/kvm-agent-swarm.log
```

## Official background

- [Tailscale tags](https://tailscale.com/docs/features/tags)
- [Tailscale grants](https://tailscale.com/docs/reference/syntax/grants)
- [Tailscale policy tests](https://tailscale.com/docs/reference/syntax/policy-file#tests)
- [Tailscale CLI: `tailscale up`](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
