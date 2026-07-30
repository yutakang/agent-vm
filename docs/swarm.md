# Optional cross-host manager/worker VMs

[日本語版](swarm_jp.md)

KVM-Agent can optionally prepare several disposable guests to cooperate across
physical hosts and networks. The usual arrangement is one **manager** VM that
runs the main coding agent and one or more **worker** VMs that execute long,
mostly deterministic jobs such as Isabelle builds or benchmark runs.

This is job distribution, not memory aggregation. A process running in one VM
cannot use RAM assigned to another VM. The useful pattern is to submit an
independent job to a worker, continue other work on the manager, then retrieve
logs and results.

```text
Dell host                                Galleria host
└─ manager VM ── Tailscale/WireGuard ──► worker VM
                  ordinary OpenSSH
```

Both physical hosts remain outside the overlay network. The manager receives
no host credential, host filesystem mount, libvirt socket, or other path to the
worker's physical host.

## What provisioning adds

Use the same `setup-kvm-agent.sh` script for both roles.

During initial creation:

```bash
# Default overlay: Tailscale
./setup-kvm-agent.sh --name agent-manager --formal-methods --swarm-role manager
./setup-kvm-agent.sh --name agent-worker --formal-methods --swarm-role worker

# Raw WireGuard instead
./setup-kvm-agent.sh \
  --name agent-worker \
  --formal-methods \
  --swarm-role worker \
  --swarm-network wireguard
```

Add a role later to an already-provisioned VM created by this repository:

```bash
./setup-kvm-agent.sh \
  --add-swarm manager \
  --name agent-manager \
  --user agent

./setup-kvm-agent.sh \
  --add-swarm worker \
  --name agent-worker \
  --user agent \
  --swarm-network tailscale
```

`--add-swarm` uses the host-side recovery key already managed for that VM. It
does not rebuild or delete the guest. The guest must be running and reachable
through libvirt's private network.

Available roles are:

- `manager`: creates a dedicated Ed25519 SSH key in the normal guest user's
  `~/.ssh/id_ed25519_kvm_agent_swarm` and installs a command that prints only
  its public half;
- `worker`: creates the locked-password, non-sudo `agent-worker` account and
  its `~/jobs` directory, a root-owned manager-key store, and a reviewed helper
  for adding keys with OpenSSH's `restrict` option;
- `both`: installs both sets of facilities for users who need a VM to submit
  and receive jobs.

The profile also installs the selected overlay client and narrow guest-firewall
exceptions. The worker account can use system-wide tools such as the provisioned
Isabelle installation under `/opt` and `/usr/local/bin`; it does not inherit
user-local toolchains or credentials from the normal `agent` account.

It deliberately does **not**:

- sign the VM into a Tailscale account;
- create or transmit Tailscale auth keys;
- invent WireGuard addresses, endpoints, or peer keys;
- enable a Tailscale exit node, subnet router, Funnel, Serve, or Tailscale SSH;
- authorize a manager key on a worker automatically; or
- place API credentials in the worker account.

These decisions require information and trust choices that provisioning cannot
safely infer.

Inside either prepared VM, inspect the current state with:

```bash
kvm-agent-swarm-status
```

Provisioning logs are written to:

```text
/var/log/kvm-agent-swarm.log
```

## Why an overlay network in addition to SSH?

WireGuard or Tailscale does not replace SSH. SSH still authenticates the
manager, starts commands, and transfers files. The overlay supplies a private,
stable network path over which SSH runs.

Direct SSH alone is enough when the VMs are already mutually reachable, such
as on one trusted LAN. Across unrelated home, institute, hotel, or mobile
networks, both VMs are commonly behind routers and libvirt NAT. Direct SSH then
requires public addressing, dynamic DNS, router and host port forwarding, and
usually a publicly reachable SSH port.

An overlay offers:

- stable private VM addresses despite changing Wi-Fi or public addresses;
- no requirement to expose guest port 22 to the public internet;
- encrypted peer-to-peer traffic over untrusted networks;
- a place to express network policy such as manager-to-worker TCP 22 only;
- simpler device revocation and movement between networks.

Tailscale is usually the easiest option for two laptops on unrelated networks.
It uses WireGuard for encrypted data transport and adds device identity,
coordination, NAT traversal, relays when direct peer-to-peer connectivity is
not possible, and centrally managed access policy.

Raw WireGuard has a smaller external trust and software surface, but it does
not itself provide a coordination service or general NAT-traversal solution.
At least one peer normally needs a reachable UDP endpoint, or both peers must
use a reachable hub such as a small VPS. With two laptops behind independent
NATs, raw WireGuard may therefore require router, host, and libvirt forwarding
that Tailscale avoids.

Official background:

- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale grants](https://tailscale.com/docs/features/access-control/grants)
- [Tailscale routing features](https://tailscale.com/docs/route)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [WireGuard overview](https://www.wireguard.com/)
- [WireGuard quick start](https://www.wireguard.com/quickstart/)

## Recommended Tailscale setup

Provision both VMs with `--swarm-role ...` or add the roles later. Then, inside
each VM, run:

```bash
sudo tailscale up
```

Authenticate each VM into the intended tailnet. Do not pass `--ssh`: this
profile deliberately uses ordinary OpenSSH because its dedicated key and the
worker's `authorized_keys` entry can retain command-, forwarding-, and
account-level restrictions.

Do not advertise routes, configure an exit node, or add either physical host to
this worker tailnet. Record the worker address with:

```bash
tailscale ip -4
```

Use Tailscale tags and a deny-by-default policy. A current grants-style policy
can express the intended direction as follows; merge it with the existing
policy rather than replacing unrelated rules blindly:

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

Assign the manager and worker tags to the corresponding VMs. Do not add a
reverse worker-to-manager grant. Tailscale policy is important even though the
VM firewalls also default to denying unsolicited inbound traffic.

The provisioned firewall permits only tailnet-assigned IPv4 destinations
through `tailscale0`; it does not open general private-range routing. That
supports ordinary node-to-node SSH and MagicDNS while intentionally not
supporting subnet routes or exit nodes.

## Raw WireGuard setup

Selecting `--swarm-network wireguard` installs `wireguard-tools` and prepares
UFW rules for an interface named `wg0`. It does not create `wg0.conf`, because
provisioning does not know the peer addresses, public endpoints, or whether a
VPS hub is required.

Use the official WireGuard quick start to generate a distinct key pair inside
each guest and create `/etc/wireguard/wg0.conf`. Prefer one `/32` overlay route
per peer rather than a broad private network, for example manager
`10.203.0.1/32` and worker `10.203.0.2/32`. Do not route either physical LAN,
libvirt network, or `0.0.0.0/0` through the worker tunnel.

After reviewing the files:

```bash
sudo systemctl enable --now wg-quick@wg0
sudo wg show
```

The worker firewall permits inbound SSH only on `wg0`; the manager does not
receive an equivalent inbound exception. WireGuard cryptographically
identifies peers, but the OpenSSH key still controls access to the worker
account.

## Authorize the manager on the worker

On the manager VM:

```bash
kvm-agent-swarm-public-key
```

Copy the single public-key line. It is not secret. On the worker VM, using the
normal `agent` account and its guest-local sudo authority:

```bash
printf '%s\n' 'ssh-ed25519 AAAA... kvm-agent-swarm-manager@manager' |
  sudo kvm-agent-swarm-authorize
```

The helper accepts one Ed25519 public key, validates it with `ssh-keygen`, and
adds it to the root-owned `/etc/ssh/authorized_keys/agent-worker` file with
OpenSSH's `restrict` option. The worker cannot modify that authorization file.
A per-user SSH policy also disables password and keyboard-interactive login,
all SSH forwarding, tunnels, TTY allocation, and user RC files. The resulting
remote account has no sudo. The manager key is separate from every host recovery
key.

Review or revoke worker authorizations from the normal guest account:

```bash
sudo kvm-agent-swarm-authorize --list
sudo kvm-agent-swarm-authorize --clear
```

From the manager, test ordinary OpenSSH over the selected overlay. Provisioning
creates a dedicated known-hosts file so disposable-worker replacement does not
weaken checking for unrelated SSH destinations:

```bash
WORKER_ADDRESS=100.x.y.z  # Tailscale address or WireGuard address
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

If a disposable worker is rebuilt, OpenSSH should report a host-key mismatch.
Verify that the old VM really was replaced, then remove only that worker's old
entry with:

```bash
ssh-keygen -R "$WORKER_ADDRESS" \
  -f "$HOME/.ssh/known_hosts_kvm_agent_swarm"
```

Never work around a mismatch with `StrictHostKeyChecking=no`.

Do not use `ssh -A`. Do not copy the manager's private key to the worker.

## Simple job workflow

The manager can submit an experiment without running a second LLM agent on the
worker:

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

Check and retrieve it later:

```bash
"${SSH[@]}" agent-worker@"$WORKER_ADDRESS" \
  "cd ~/jobs/$JOB && { test -f finished && cat exit-status || tail -n 40 run.log; }"

mkdir -p "./remote-results/$JOB"
rsync -a -e "$RSYNC_SSH" \
  "agent-worker@$WORKER_ADDRESS:jobs/$JOB/" \
  "./remote-results/$JOB/"
```

For repeated use, wrap these operations in a small reviewed command with
`submit`, `status`, `log`, `fetch`, and `cancel` subcommands. Limit concurrent
jobs with `flock`, and use `timeout`, `nice`, and disk quotas or periodic cleanup
on weak worker laptops.

## Security effect and risk elevation

The overlay encrypts traffic and hides SSH from the public internet, but it
also creates a new authenticated route between previously isolated guests.
That is a real, though controllable, increase in lateral-movement risk.

### Risk to the worker

A compromised manager can use its authorized key to control the non-sudo
`agent-worker` account, alter jobs, consume CPU/RAM/disk, read submitted source,
and use whatever outbound internet access the worker account can reach. Treat
the worker as part of the manager's security domain and keep it disposable.
Do not store browser sessions, API tokens, host credentials, or unrelated work
there.

### Risk to the manager

The recommended network policy permits no worker-initiated connection to the
manager. That substantially reduces exposure, but it does not make worker
results trustworthy. A compromised worker can return false logs, malicious
archives, huge files, shell scripts, Isabelle theories containing unexpected
code, or project content intended to influence the manager agent.

Treat retrieved files as untrusted input. Prefer plain logs, hashes, CSV, and
small patches. Inspect results before executing them or opening an entire
returned directory as an IDE workspace.

### Risk to the physical hosts

Install the overlay only inside the guests. Do not join the physical hosts to
the same tailnet merely for convenience, and do not place host SSH private keys
inside either guest. Keep host folders, libvirt sockets, Docker sockets, block
devices, and USB/PCI passthrough out of the worker VM. Under those conditions,
the residual host risk is primarily the ordinary KVM/QEMU escape risk already
accepted when running untrusted agent code in a VM.

### Tailscale-specific trust

Tailscale adds a coordination control plane and receives device/connectivity
metadata needed to operate the tailnet. Traffic payloads remain end-to-end
encrypted. Device tags, grants, account security, and removal of retired VMs
become part of the security boundary. Remove or expire a disposable worker in
the Tailscale admin console when it is discarded.

### WireGuard-specific trust

Raw WireGuard avoids a hosted coordination service, but key distribution,
endpoint availability, firewall rules, route scope, revocation, and NAT
traversal become the operator's responsibility. A broad `AllowedIPs` or route
can expose more networks than intended. Use narrow `/32` peers and a separate
key pair for every VM.

## Recommended baseline

For two ordinary laptops on different networks:

1. use Tailscale inside the VMs;
2. tag one VM as manager and the other as worker;
3. grant only manager-to-worker TCP 22;
4. use ordinary OpenSSH and the dedicated swarm key;
5. authorize only the non-sudo `agent-worker` account;
6. keep hosts, subnet routes, exit nodes, Tailscale SSH, and valuable
   credentials outside this arrangement; and
7. treat every worker result as untrusted until reviewed.

That configuration is easier to operate safely than raw WireGuard for roaming
laptops, while retaining the VM isolation boundary and avoiding a second agent
or additional LLM credentials on the worker.
