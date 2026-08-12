# Automatic research journals

[日本語版](journal_jp.md)

The optional research journal is an observability layer for several concurrent
academic coding projects. It does not make the agents autonomous and it does
not replace Git, experiment artifacts, or communication with the project
manager.

## Add it to an existing VM

Run the current repository script on the physical host. The VM must be running
and must still have the recovery key created by KVM-Agent.

```bash
./setup-kvm-agent.sh \
  --add-journal \
  --name kvm-agent \
  --user agent \
  --journal-project /home/agent/YOUR_PROJECT_A \
  --journal-project /home/agent/YOUR_PROJECT_B
```

This default is the recommended mode: scheduled reports are produced
deterministically inside the guest and no journal data is sent to a model
provider. `YOUR_PROJECT_A` and `YOUR_PROJECT_B` are placeholders. The default
timezone is `Etc/UTC`; add `--journal-timezone YOUR_IANA_TIMEZONE` only when a
different local reporting boundary is useful.

`--journal-project` is a path **inside the guest**, not on the host, and may be
repeated. Each target must already exist and be a Git worktree. The operation
does not shut down, recreate, resize, or replace the VM. It transfers the
repository's journal program through the existing recovery SSH path, installs
timers, and initializes the selected repositories. Rerunning the same command
updates the journal runtime and managed instruction blocks idempotently.

To install the commands and timers before choosing repositories, omit every
`--journal-project`. Later, inside the guest, run:

```bash
kvm-agent-journal init /home/agent/YOUR_PROJECT
sudo kvm-agent-journal register /home/agent/YOUR_PROJECT
```

`init` creates or updates the project files. The separate root-only `register`
step opts the project into unattended timers. The registry is
`/etc/kvm-agent-journal-projects.json`, owned by root and readable by the guest
user. This prevents an ordinary process from silently adding another directory
to scheduled reporting. It is a guardrail rather than a security boundary,
because the disposable guest's normal `agent` account deliberately has
passwordless sudo.

When upgrading from the earlier journal preview, repeat every intended
`--journal-project` on the host command (or run `sudo ... register` for each
project). The hardened installer deliberately does not import the former
user-writable registry automatically.

Initialization preserves existing `AGENTS.md`, `CLAUDE.md`, and `JOURNAL.md`
content. It adds or updates a delimited managed section in each file, then
creates `PROJECT.md` and journal data files only where they do not already
exist.
`PROJECT.md` begins with explicit placeholders; the agents are instructed to
ask the manager to confirm the stable charter rather than inventing it.

## Data model and layout

```text
PROJECT.md                         stable aim, hypotheses, scope, criteria
JOURNAL.md                         instructions shared by coding agents
AGENTS.md / CLAUDE.md              short managed pointers to JOURNAL.md
journal/
├── events/YYYY/MM/YYYY-MM-DD.jsonl
├── daily/YYYY/MM/YYYY-MM-DD.{json,html}
├── weekly/YYYY/YYYY-MM-DD_to_YYYY-MM-DD.{json,html}
├── monthly/YYYY/YYYY-MM.{json,html}
├── decisions/
├── experiments/
├── legacy-memos-index.yaml
└── state.json
```

Structured events and Git/test/experiment paths are the source material. JSON
is the canonical report. HTML is a static, escaped view with inline CSS, no
JavaScript, and no external resources. Weekly and monthly generation reads the
period's events and Git evidence directly instead of scraping HTML.

## What agents record

Agents receive a durable instruction to record only meaningful developments,
not every command or file read. For example:

```bash
kvm-agent-journal event . \
  --type experiment_result \
  --summary "Combo underperformed pure Abduction on full TIP15" \
  --why-it-matters "The combined strategy is not uniformly better" \
  --evidence results/tip15_full.csv \
  --confidence high \
  --follow-up "Inspect timeout distribution and ordering effects" \
  --actor claude-code
```

Supported event types include plans, decisions, implementation, experiment
starts/results, failures, discoveries, unexpectedly good results, plan
changes, manager questions, possible misunderstandings, claim changes, and
handoffs. Events use an append-only daily JSONL file and take a file lock so
concurrent agents do not interleave writes.
Agents should identify themselves accurately with `--actor claude-code`,
`--actor codex`, `--actor opencode`, or another truthful identifier.

The research lifecycle is not reduced to a misleading percentage. Record the
state of each phase instead:

```bash
kvm-agent-journal phase . evaluation active \
  --evidence results/protocol.md
```

The six standard phases are idea, implementation, evaluation, paper, rebuttal,
and presentation. States are `complete`, `active`, `blocked`, `queued`,
`not-started`, and `unknown`. A phase may regress when new evidence requires
more implementation or evaluation.

## Scheduling

The installer creates system-level timers that execute as the ordinary guest
account, so they do not depend on a graphical login session:

| Timer | Local time | Completed period reported |
|---|---:|---|
| Daily | 07:00 every day | preceding calendar day |
| Weekly | 07:10 Saturday | preceding Saturday–Friday |
| Monthly | 07:20 on day 1 | preceding calendar month |

The selected IANA timezone is embedded in each `OnCalendar` expression.
`Persistent=true` causes a missed run to catch up after the VM starts. A
per-project `flock` lock and atomic file replacement prevent overlapping or
half-written reports. Inspect the schedule and logs inside the guest with:

```bash
systemctl list-timers 'kvm-agent-journal-*'
journalctl -u kvm-agent-journal-daily.service
kvm-agent-journal status
```

Manual generation is also available:

```bash
kvm-agent-journal report daily --all
kvm-agent-journal report weekly --project /home/agent/YOUR_PROJECT
```

## Evidence-only reports and optional remote enrichment

`evidence` is the default and recommended backend. It makes no LLM call. It
turns the meaningful structured events, Git history, working-tree summary, and
phase state into canonical JSON and readable static HTML. This keeps the
automatic journal useful even when no model CLI is authenticated.

Optional remote narrative enrichment is available only through an explicitly
named Claude or Codex backend. It requires a separate consent flag:

```bash
./setup-kvm-agent.sh \
  --add-journal \
  --name kvm-agent \
  --user agent \
  --journal-project /home/agent/YOUR_PROJECT \
  --journal-backend claude \
  --journal-allow-remote-reporting \
  --journal-timezone YOUR_IANA_TIMEZONE
```

Both `YOUR_PROJECT` and `YOUR_IANA_TIMEZONE` are placeholders; for example,
an actual timezone value could be `Europe/Prague`.

That flag means that bounded versions of the following data may leave the VM:

- project name and the `Overall aim` section of `PROJECT.md`;
- commit hashes, timestamps, and subjects;
- changed-file paths and Git diff statistics;
- structured journal summaries, reasons, follow-ups, and evidence paths; and
- lifecycle phase states and evidence paths.

Do not enable it for an embargoed, NDA-controlled, or otherwise confidential
project unless the selected provider and account policy permit this data flow.
Authentication remains the responsibility of the guest user.

OpenCode is intentionally not offered as an unattended reporter. Its previous
adapter did not enforce confinement equivalent to the other backends. OpenCode
agents can still work on a project and record events; the journal format is
agent-neutral. The earlier `auto` mode is also removed so installed software
cannot silently change the reporter. An old `BACKEND=auto` configuration is
treated as evidence-only by the updated runtime.

If an explicitly enabled CLI is unavailable, unauthenticated, times out, or returns invalid structured
output, the timer still writes an evidence-only report and records the failure
in the canonical JSON. It never substitutes plausible unrecorded activity.

Token and cost fields cover only the report-generation invocation when the
backend exposes them. They do not claim to measure all interactive agent work
during the day, week, or month.

## Security and trust boundary

The deterministic reporter runs inside the already disposable guest as the
ordinary guest account. In evidence-only mode its systemd service also receives
a private network namespace and an outbound IP deny rule, in addition to
`NoNewPrivileges`, a read-only system filesystem, namespace restrictions, and
other systemd hardening.

Repository-controlled text is untrusted and may contain prompt injection. For
an explicitly enabled remote reporter, free text and list counts are bounded,
control and bidirectional-formatting characters are removed, and the evidence
is copied into a new empty temporary directory. The model process is launched
from that directory, not from the repository. Claude runs in safe mode with
MCP tools, slash commands, and project customizations disabled, and with a
single permitted tool: `StructuredOutput`, which is how the CLI returns a
`--json-schema` result. Denying that one too would not harden anything — the
model would compose the report, fail to submit it, and the run would fall back
to evidence-only after the evidence had already been sent and billed. Codex
runs ephemerally with ignored user configuration/rules, no
approvals, a read-only sandbox, and an output schema. Returned strings and list
sizes are validated before they enter the report.

These measures reduce prompt-injection impact; they cannot prove that a remote
model's narrative is correct. In particular, Codex still has a read-only tool
runtime inside the disposable guest. Treat every generated narrative as an
untrusted interpretation and verify consequential claims against the adjacent
evidence JSON. Evidence-only mode avoids this model-input trust problem and is
therefore the default.

Reports copied from a guest are untrusted data. The generated HTML has no
scripts or external resources, but the host should still pull it into a
quarantine directory and should never execute guest-supplied programs. Provider
credentials stay inside the guest; email credentials and any future
cross-project mail sender should remain on the trusted host.

## Current boundary

This release generates per-project reports in each VM. It does not yet create a
host-side cross-VM portfolio page or send email. A later host helper can pull
the canonical JSON through the existing recovery SSH key, validate it, render
one portfolio summary, and send mail without giving Gmail credentials to any
guest.
