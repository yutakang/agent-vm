# Credential handling

[日本語版](credentials_jp.md)

The VM boundary protects the host better than running an agent directly on it.
It does not isolate secrets from other processes inside the same guest. Treat a
coding agent, plugin, MCP server, language server, browser, and project command
as potentially able to read every credential available to the `agent` account.

## Provision before authentication

The setup script intentionally installs all tools before any source code or
provider credential is added. Wait for the success marker and the
post-bootstrap cloud-init disable marker:

```bash
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
```

and confirm the graphical login works. Only then add the minimum credentials
for the project.

If a third-party installer is compromised, this ordering limits its initial
access to an otherwise empty guest. It is not a guarantee: later automatic
updates or plugins can introduce new code.

## Credential categories

| Credential | Recommended handling |
|---|---|
| OpenAI or Anthropic interactive login | Complete the provider's first-run flow in the guest. Use MFA/passkeys from a separate trusted device where possible. Sign out before discarding or sharing the VM. |
| API key | Prefer project-specific, short-lived, revocable keys with spending limits. Store only in the guest that needs it. |
| Git hosting API token | Use a fine-grained, repository-selected token with only the issue/PR permissions needed. Keep Contents read-only when Git pushes use a separate deploy key. |
| SSH key for source hosting | Generate it inside the guest for that repository. Prefer a repository deploy key, never the host's general-purpose private key. |
| Commit-signing key | Sign reviewed commits on a trusted workstation or use a narrowly scoped guest key. Do not import a high-value personal signing key. |
| Cloud administrator credential | Do not place it in an autonomous-agent guest. Create a narrowly scoped workload identity instead. |
| Ollama Cloud login | Treat it as a remote-provider credential; local CLI execution does not make inference local. |
| Recovery SSH key | Keep the private key on the host. Only its public half belongs in the guest. |

## Avoid environment-wide secrets

Environment variables are convenient, but agents commonly inspect process
environments, shell files, logs, and project configuration. Do not export a
broad credential globally if one command or one project alone needs it.

Prefer provider credential stores or a shell wrapper with a restricted file.
The following commands create a private directory and an empty file, then open
that file in an editor:

```bash
mkdir -p ~/.config/project-agent
chmod 700 ~/.config/project-agent
touch ~/.config/project-agent/credentials.env
chmod 600 ~/.config/project-agent/credentials.env
nano ~/.config/project-agent/credentials.env
```

`touch` creates the empty file if it does not exist; it does not install
software. Edit the file manually inside the guest, load it only for the required
command, and ensure it is ignored by Git. Do not put secrets directly in
command-line arguments: they can appear in shell history and process listings.

For a dedicated one-project VM, loading one narrowly scoped token from a mode
`600` file in `~/.bashrc` can be a reasonable convenience. It gives every
interactive shell and every agent started from it that token, so do not use this
pattern in a mixed-client or mixed-project VM. The concrete GitHub pattern and
its split deploy-key/API-token authority are documented in
[GitHub integration](github-integration.md).

Guest file permissions limit accidental access between Unix accounts; they do
not stop an agent running as the same `agent` user or with guest sudo.

## Browser and device authentication

OAuth flows may display a localhost callback URL or device code. Complete them
only on the provider's authentic domain.

Opening a callback URL on another machine can transfer a session to the guest.
Before doing so, verify:

- the CLI that initiated the flow;
- the exact provider domain;
- the requested account and organization;
- the permissions and billing relationship; and
- whether the resulting token can be revoked from a trusted device.

Never paste passwords, MFA recovery codes, seed phrases, or hardware-key secrets
into a coding-agent prompt.

## No SSH-agent forwarding

The guest SSH server rejects agent forwarding, and the documented client
commands set `ForwardAgent=no`. Do not override this. A process in the guest
could ask a forwarded agent to authenticate or sign data even without reading
the private key bytes.

For source hosting, create a separate guest key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/project_ed25519
```

Register only its public key and scope its server-side authority where the
provider permits.

## Spending and push authority

A VM does not prevent a valid credential from incurring API charges or pushing
bad changes. Use provider-side controls:

- hard or soft spending limits;
- low initial quotas;
- usage alerts;
- repository branch protection;
- required reviews and CI;
- no force-push authority;
- no release, package-publishing, billing, or organization-administration
  scope; and
- rapid revocation from a separate trusted device.

The narrowest safe default is often read-only repository access plus patch
export. When direct agent branch pushes materially improve the workflow, use a
repository-only deploy key, protect `main`, and keep merge authority with the
human reviewer. Grant broader write access only when it has a specific use.

## Snapshots and cloning

A snapshot taken after login duplicates the login. A clone can therefore
contain working API tokens, cookies, Git credentials, shell history, and model
provider configuration.

Before cloning for another person or project:

1. sign out from every CLI and browser;
2. revoke the external tokens;
3. remove project files and credential stores;
4. clear history only as hygiene, not as secure erase; and
5. preferably return to a credential-free snapshot instead.

Never publish or attach a VM image that has held valuable credentials without
assuming recovery may be possible.

## Incident response

If the guest may be compromised:

1. disconnect or stop it in `virt-manager`;
2. revoke provider, Git, and cloud credentials from a separate trusted machine;
3. check provider usage and repository audit logs;
4. rotate any secret that entered the VM or its clipboard;
5. export only the minimum evidence or patch needed for review; and
6. rebuild from a clean, credential-free source rather than trying to "clean"
   the guest in place.
