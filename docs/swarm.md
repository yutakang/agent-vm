# Cross-host manager/worker VMs

[日本語版](swarm_jp.md)

KVM-Agent can connect disposable guests on different physical machines so that
one VM runs the main coding agent and another VM executes long, mostly
deterministic jobs such as Isabelle builds or benchmark runs.

This guide uses generic labels throughout:

- **Laptop_A**: the physical machine that hosts the manager VM;
- **Desktop_B**: the physical machine that hosts the worker VM;
- **manager VM**: the VM in which Claude Code, Codex, or another main agent runs;
- **worker VM**: the disposable VM that receives files and executes jobs.

The two libvirt VMs may both retain the repository's default VM name,
`kvm-agent`, because they exist on different physical hosts. Their Tailscale
names should be distinct.

```text
Laptop_A host                              Desktop_B host
└─ manager VM ── Tailscale/WireGuard ────► worker VM
                    ordinary OpenSSH         └─ agent-worker
```

This distributes independent jobs. It does not combine the RAM or CPUs of the
two machines into one larger computer.

## Recommended configuration

For two machines that may move between networks or sit behind unrelated NATs,
use:

- Tailscale inside the two guest VMs only;
- ordinary OpenSSH over Tailscale;
- a dedicated manager key;
- the locked, non-sudo `agent-worker` account on the worker;
- the installed `kvm-agent-swarm-*` helper commands.

Do not add either physical host to this worker tailnet merely for convenience.
Do not use Tailscale SSH, an exit node, subnet routes, SSH agent forwarding, or
host directory sharing for this workflow.

## Where each command is run

This distinction is essential:

| Location/account | Purpose | Typical commands |
|---|---|---|
| Laptop_A physical host | Add the manager role to its existing VM | `./setup-kvm-agent.sh --add-swarm manager` |
| Desktop_B physical host | Add the worker role to its existing VM | `./setup-kvm-agent.sh --add-swarm worker` |
| Normal sudo-capable account inside manager VM | Join Tailscale, configure and use the worker | `kvm-agent-swarm-tailscale-up`, `kvm-agent-swarm-configure-worker` |
| Normal sudo-capable account inside worker VM | Join Tailscale and authorize the manager key | `kvm-agent-swarm-tailscale-up`, `sudo kvm-agent-swarm-authorize` |
| `agent-worker` account | Receives remote jobs automatically | Normally no interactive login |

The `agent-worker` account is intentionally absent from the graphical login
workflow. It has a locked password, no sudo rights, no TTY over SSH, and no
ability to edit its own authorized-key file.

## What provisioning now automates

Selecting a swarm role installs and prepares:

- Tailscale or WireGuard software;
- the dedicated manager Ed25519 key;
- the non-sudo `agent-worker` account and `~/jobs` directory;
- narrow UFW rules for the selected overlay interface;
- a safe Tailscale login helper that assigns a distinct device name;
- commands that print the manager key and worker SSH fingerprint;
- verified worker host-key enrollment using `StrictHostKeyChecking=yes`;
- fixed SSH and rsync wrappers that always use `agent-worker` and the dedicated
  manager key;
- a reviewed job helper with `submit`, `status`, `log`, `fetch`, `cancel`, and
  `list` operations.

The script deliberately does not automate the two trust decisions that require
human control:

1. authenticating each VM into the intended Tailscale account; and
2. authorizing the manager public key on the worker.

It also does not create API credentials on the worker or give either VM access
to a physical host.

## Step-by-step Tailscale setup

### Step 1: add the manager role on Laptop_A

Run this on the **Laptop_A physical host**, from the repository directory:

```bash
./setup-kvm-agent.sh --add-swarm manager
```

For a newly created VM, the role may instead be selected during initial setup:

```bash
./setup-kvm-agent.sh --formal-methods --swarm-role manager
```

Use `--name` and `--user` only if that VM was originally created with
non-default values.

### Step 2: add the worker role on Desktop_B

Run this on the **Desktop_B physical host**:

```bash
./setup-kvm-agent.sh --add-swarm worker
```

Or during initial creation:

```bash
./setup-kvm-agent.sh --formal-methods --swarm-role worker
```

The existing VM is not rebuilt or deleted. For `--add-swarm`, the VM must be
running and reachable through the repository-managed recovery SSH key.

### Step 3: join the manager VM to Tailscale

Log in to the normal sudo-capable account inside the **manager VM** and run:

```bash
kvm-agent-swarm-tailscale-up laptop-a-manager
```

The command runs `tailscale up` with:

- a distinct MagicDNS device name;
- subnet-route acceptance disabled; and
- Tailscale SSH disabled.

It prints a browser login URL. Open that URL in a trusted browser and sign in.
The first sign-in creates a Tailscale account/tailnet if necessary. A separate
Tailscale username and password is normally not required; Tailscale uses the
selected identity provider.

The Tailscale iOS app is not needed for VM-to-VM operation. Installing or
signing in on an iPhone simply adds the phone as another tailnet device.

### Step 4: join the worker VM to the same tailnet

Inside the normal sudo-capable account of the **worker VM**, run:

```bash
kvm-agent-swarm-tailscale-up desktop-b-worker
```

Authenticate with the same Tailscale identity/tailnet used for the manager VM.
Do not run this as `agent-worker`.

Check both VMs with:

```bash
kvm-agent-swarm-status
```

A result such as `via DERP(fra)` is functional. It means Tailscale is relaying
the already encrypted connection because a direct peer-to-peer path was not
established. SSH, rsync, and the job helper work identically over direct and
DERP paths.

### Step 5: obtain the worker address and SSH fingerprint

Inside the **worker VM**, using the normal sudo-capable account:

```bash
kvm-agent-swarm-worker-info
```

Record these two values:

```text
Tailscale IPv4: 100.x.y.z
SSH ED25519 host-key fingerprint: SHA256:...
```

The fingerprint is read locally from the worker's SSH host public key. It lets
the manager verify the first network connection instead of blindly using
`StrictHostKeyChecking=accept-new`.

### Step 6: authorize the manager key on the worker

Inside the **manager VM**:

```bash
kvm-agent-swarm-manager-info
```

The manager private key is
`~/.ssh/id_ed25519_kvm_agent_swarm`. It is generated without a passphrase so
scheduled and agent-driven jobs can use it non-interactively. It belongs to the
normal manager guest account; therefore, a compromise of that account exposes
the key and every worker that authorizes it. This is a guest-to-worker key, not
a physical-host key.

Copy the complete line beginning with `ssh-ed25519`.

Inside the **worker VM**, still using its normal sudo-capable account:

```bash
printf '%s\n' 'PASTE_THE_COMPLETE_MANAGER_PUBLIC_KEY_HERE' |
  sudo kvm-agent-swarm-authorize
```

Verify it:

```bash
sudo kvm-agent-swarm-authorize --list
```

This is the one unavoidable pairing step. The public key is not secret. Never
copy the corresponding private key to the worker.

### Step 7: configure the worker safely on the manager

Back inside the **manager VM**, use the address and fingerprint recorded in
Step 5:

```bash
kvm-agent-swarm-configure-worker \
  desktop-b-worker \
  SHA256:PASTE_THE_WORKER_HOST_FINGERPRINT
```

The address may be the Tailscale MagicDNS name or its `100.x.y.z` address.
This helper:

1. reads the worker's ED25519 SSH host key;
2. compares it with the trusted fingerprint;
3. refuses the connection if they differ;
4. stores the verified key in the dedicated
   `~/.ssh/known_hosts_kvm_agent_swarm` file; and
5. writes a separate SSH configuration that always uses `agent-worker`, the
   swarm key, no agent forwarding, and `StrictHostKeyChecking=yes`.

It does not weaken the user's ordinary SSH configuration.

### Step 8: test the complete connection

Inside the manager VM:

```bash
kvm-agent-swarm-test
```

Expected output includes:

```text
agent-worker
```

It also reports whether `isabelle` is visible to the worker account. If
Isabelle was provisioned system-wide, the path should normally be available to
`agent-worker` without copying credentials or user-local toolchains.

## Daily use

### Run one remote command

```bash
kvm-agent-swarm-ssh 'hostname && whoami && nproc && free -h'
```

### Copy files manually

Upload a directory:

```bash
kvm-agent-swarm-rsync -a ./experiment/ \
  kvm-agent-worker:jobs/manual-test/
```

Download it again:

```bash
kvm-agent-swarm-rsync -a \
  kvm-agent-worker:jobs/manual-test/ \
  ./returned-manual-test/
```

The special hostname `kvm-agent-worker` exists only inside the dedicated swarm
SSH configuration used by the wrappers.

### Submit a managed job

A project containing `run-experiment.sh` can be submitted with:

```bash
JOB_ID="$(kvm-agent-swarm-job submit ./experiment \
  --timeout 7200 \
  -- ./run-experiment.sh)"

echo "$JOB_ID"
```

The helper:

- creates a unique directory under `/home/agent-worker/jobs`;
- copies the project with rsync;
- runs it with `timeout` and `nice`;
- detaches it from the SSH session;
- records `run.log`, `pid`, `exit-status`, and `finished`; and
- permits only one managed job at a time on the weak worker.

Check progress:

```bash
kvm-agent-swarm-job status "$JOB_ID"
kvm-agent-swarm-job log "$JOB_ID" 80
```

Retrieve all files:

```bash
kvm-agent-swarm-job fetch "$JOB_ID" "./remote-results/$JOB_ID"
```

Cancel it:

```bash
kvm-agent-swarm-job cancel "$JOB_ID"
```

List known jobs:

```bash
kvm-agent-swarm-job list
```

## Using Claude Code or another coding agent

The main agent remains on the manager VM. The worker does not need another LLM
agent or additional OpenAI/Anthropic credentials.

A useful project instruction is:

> For long Isabelle experiments, use `kvm-agent-swarm-job`. Submit only the
> required project directory, inspect status and logs, and fetch the results.
> Never copy credentials, browser data, or private SSH keys to the worker.

Initially approve each helper invocation individually. `kvm-agent-swarm-job`
is narrower operationally than arbitrary `ssh *`: it fixes the worker alias,
working directory, timeout, niceness, and concurrency. Its `-- COMMAND [ARG…]`
payload is still an arbitrary command under the non-sudo worker account, so do
not treat the helper name itself as a command allow-list or security boundary.

## Common problems

### `Permission denied (publickey)` and `Authenticating ... as 'agent'`

The manager must connect as `agent-worker`, not the normal `agent` account.
Use `kvm-agent-swarm-test` or `kvm-agent-swarm-ssh`; these wrappers fix the
username and key automatically.

If access still fails, compare:

```bash
# Manager VM
kvm-agent-swarm-manager-info

# Worker VM
sudo kvm-agent-swarm-authorize --list
```

### The `agent-worker` account is not shown by graphical “Switch User”

That is expected. Verify it from the worker's normal sudo-capable account:

```bash
getent passwd agent-worker
id agent-worker
sudo -u agent-worker -H sh -lc 'whoami; echo "$HOME"; ls -la ~/jobs'
```

### Host-key mismatch after rebuilding the worker

A rebuilt disposable worker receives a new SSH host key. Verify the new
fingerprint locally with `kvm-agent-swarm-worker-info`, then rerun:

```bash
kvm-agent-swarm-configure-worker \
  desktop-b-worker \
  SHA256:THE_NEW_VERIFIED_FINGERPRINT
```

Never bypass the mismatch with `StrictHostKeyChecking=no`.

### `tailscale ping` works only through DERP

This is normally acceptable for Isabelle jobs. `UDP: true` does not guarantee
that two layers of VM/NAT/router translation can establish a direct path. Do
not expose host SSH or weaken host firewalls merely to remove DERP. Optimize it
only if file-transfer speed is actually inadequate.

### The two VMs cannot see each other

Check that both were authenticated into the same tailnet:

```bash
tailscale status
tailscale ip -4
```

Also confirm that the worker was joined as `desktop-b-worker`, not accidentally
under a different identity or tailnet.

## Tailscale access policy

The guest firewall permits worker SSH on `tailscale0`, but a deny-by-default
tailnet policy is still recommended. For example:

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

Merge this with the existing policy; do not replace unrelated rules blindly.
Do not add a reverse worker-to-manager grant.

## Raw WireGuard alternative

Select raw WireGuard with:

```bash
./setup-kvm-agent.sh \
  --add-swarm worker \
  --swarm-network wireguard
```

The script installs `wireguard-tools` and prepares interface-scoped UFW rules,
but it cannot safely invent peer addresses, reachable endpoints, keys, or a VPS
hub. Create `/etc/wireguard/wg0.conf` manually in each guest.

Prefer narrow peer routes such as:

```text
manager: 10.203.0.1/32
worker:  10.203.0.2/32
```

Do not route a physical LAN, the libvirt network, or `0.0.0.0/0` through the
worker. Raw WireGuard is appropriate when one peer has a stable reachable UDP
endpoint or when you operate a trusted hub. Tailscale is usually simpler for
two roaming machines behind unrelated NATs.

## Security boundary

The worker VM is disposable, but the physical Desktop_B host should remain
trusted. Preserve that boundary:

- install the overlay only inside the guests;
- keep both physical hosts outside the worker tailnet;
- do not place a host private key inside either VM;
- do not expose host folders, libvirt sockets, Docker sockets, block devices,
  or USB/PCI devices to the worker;
- do not use `ssh -A`;
- keep API tokens and browser sessions out of `agent-worker`;
- treat retrieved files and logs as untrusted input; and
- keep QEMU, KVM, libvirt, and the host kernel updated.

The worker having the **public** key of its physical host in an
`authorized_keys` file is not dangerous. That allows the host to authenticate
to the guest. The dangerous arrangement would be a host-access **private** key
inside the guest.

A compromised manager can control the non-sudo worker account and consume its
resources. A compromised worker can return false or malicious results. Neither
should have a credential path to a physical host.

## Removing or replacing a worker

Before discarding a worker VM:

1. remove or expire the device in the Tailscale admin console;
2. discard the worker VM normally;
3. verify the replacement worker's new SSH fingerprint; and
4. rerun `kvm-agent-swarm-configure-worker` on the manager.

Review or clear manager authorizations on a retained worker with:

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

Provisioning state and diagnostic output are available through:

```bash
kvm-agent-swarm-status
sudo tail -n 200 /var/log/kvm-agent-swarm.log
```

## Official background

- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale CLI: `tailscale up`](https://tailscale.com/docs/reference/tailscale-cli/up)
- [Tailscale access-control grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)
