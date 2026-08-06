# 自動 research journal

[English version](journal.md)

任意の research journal は、複数の academic coding project を同時に管理するための
observability layer です。Agent を autonomous loop に変えるものではなく、Git、
experiment artifact、manager との意思疎通を置き換えません。

## 既存 VM へ追加する

物理 host 上で現在の repository の script を実行します。VM は起動中で、
KVM-Agent が作成した recovery key が残っている必要があります。

```bash
./setup-kvm-agent.sh \
  --add-journal \
  --name kvm-agent \
  --user agent \
  --journal-project /home/agent/PSL_Neural \
  --journal-project /home/agent/Another_Project \
  --journal-timezone Europe/Prague
```

これが推奨 default です。Guest 内で deterministic な report を自動生成し、journal data
を model provider へ送信しません。

`--journal-project` は host ではなく **guest 内の path** で、複数回指定できます。
対象は既存の Git worktree でなければなりません。この操作は VM の shutdown、再作成、
resize、置換を行いません。既存の recovery SSH 経路を通じて journal program を転送し、
timer を導入し、指定 repository を初期化します。同じ command の再実行は runtime と
管理対象 instruction block を idempotent に更新します。

Repository を後で選ぶ場合は `--journal-project` を省略します。その後 guest 内で:

```bash
kvm-agent-journal init /home/agent/Project
sudo kvm-agent-journal register /home/agent/Project
```

`init` は project file を作成・更新し、root-only の `register` が unattended timer の
対象へ追加します。Registry は root 所有・guest user 読み取り専用の
`/etc/kvm-agent-journal-projects.json` です。Ordinary process が別 directory を黙って
timer 対象へ追加することを防ぐ guardrail ですが、通常の `agent` account は disposable
guest 内で passwordless sudo を持つため、security boundary ではありません。

以前の journal preview から更新する場合は、host command で全ての intended
`--journal-project` をもう一度指定するか、各 project に `sudo ... register` を実行して
ください。Hardened installer は以前の user-writable registry を自動 import しません。

初期化は既存 `AGENTS.md`、`CLAUDE.md`、`JOURNAL.md` を保存し、区切られた管理対象
section だけを追加・更新します。`PROJECT.md` と journal data file は未作成の場合だけ
作ります。
`PROJECT.md` は明示的な placeholder から始まり、agent は stable charter を推測せず、
manager に確認するよう instruction を受けます。

## Data と directory

```text
PROJECT.md                         長期的な aim、hypothesis、scope、success criteria
JOURNAL.md                         coding agent 共通 instruction
AGENTS.md / CLAUDE.md              JOURNAL.md への短い managed pointer
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

Structured event と Git/test/experiment path が source material です。JSON が canonical
report、HTML は inline CSS だけを持つ静的で escape 済みの表示です。JavaScript や
外部 resource は使いません。Weekly/monthly report は HTML を scrape せず、対象期間の
event と Git evidence を直接読んで生成します。

## Agent が記録するもの

Agent は全 command や全 file read ではなく、意味のある変化だけを記録します。

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

Event type は plan、decision、implementation、experiment の開始・結果、failure、
discovery、予想以上の成功、plan change、manager への質問、misunderstanding の可能性、
claim change、handoff です。Daily JSONL は append-only で、同時 agent の書き込みが
混ざらないよう file lock を使います。
Agent は `--actor claude-code`、`--actor codex`、`--actor opencode` などで正確に
自身を識別します。

Research を誤解を招く単一 percentage にしません。各 phase の状態を記録します。

```bash
kvm-agent-journal phase . evaluation active \
  --evidence results/protocol.md
```

標準 phase は idea、implementation、evaluation、paper、rebuttal、presentation です。
State は `complete`、`active`、`blocked`、`queued`、`not-started`、`unknown`。

## Schedule

Installer は ordinary guest account として動く system-level timer を作るため、GUI login
session に依存しません。

| Timer | Local time | Report 対象 |
|---|---:|---|
| Daily | 毎日 07:00 | 直前の完了した calendar day |
| Weekly | 土曜 07:10 | 直前の土曜–金曜 |
| Monthly | 毎月1日 07:20 | 完了した前月 |

選択した IANA timezone を `OnCalendar` に埋め込み、`Persistent=true` により VM 停止中の
missed run は次回起動後に catch up します。Per-project `flock` と atomic replacement に
より report の重複実行・途中 file を防ぎます。

```bash
systemctl list-timers 'kvm-agent-journal-*'
journalctl -u kvm-agent-journal-daily.service
kvm-agent-journal status
kvm-agent-journal report daily --all
```

## Evidence-only report と任意の remote enrichment

`evidence` が推奨 default です。LLM を呼ばず、structured event、Git history、working-tree
summary、phase state から canonical JSON と静的 HTML を生成します。

Remote model に narrative を補わせる場合は `claude` または `codex` を明示し、別の
consent flag が必要です。

```bash
./setup-kvm-agent.sh \
  --add-journal \
  --name kvm-agent \
  --user agent \
  --journal-project /home/agent/PSL_Neural \
  --journal-backend claude \
  --journal-allow-remote-reporting \
  --journal-timezone Europe/Prague
```

この flag により、長さを制限した以下の metadata が VM 外の provider へ送信され得ます。

- project name と `PROJECT.md` の `Overall aim`;
- commit hash・時刻・subject;
- changed-file path と diff statistic;
- journal summary・reason・follow-up・evidence path;
- lifecycle phase state と evidence path。

Embargo、NDA、その他 confidential な project では、provider/account policy が許可する
ことを確認しない限り有効にしないでください。Authentication は guest user の責任です。

OpenCode は他 backend と同等の confinement を確認できないため unattended reporter から
外しました。OpenCode agent も journal event を記録できるため、data format 自体は
agent-neutral です。導入済 CLI によって挙動が変わる旧 `auto` も廃止し、古い
`BACKEND=auto` config は更新 runtime では evidence-only として扱います。

明示的に有効化した CLI が未認証、timeout、invalid output の場合も、
timer は evidence-only report を生成し、失敗を canonical JSON に記録します。記録されて
いないもっともらしい活動を補いません。

Token/cost field は backend が返した report-generation call だけを対象とします。

## Security と現在の境界

Deterministic reporter は disposable guest 内で ordinary guest account として動きます。
Evidence-only mode の systemd service には private network namespace と outbound IP deny を
加え、`NoNewPrivileges`、read-only system filesystem、namespace restriction なども使います。

Repository text は prompt injection を含み得る untrusted data です。Remote reporter を明示的に
有効化した場合、free text・list count を制限し、control/bidirectional-formatting character を
除去し、evidence を空の temporary directory へ copy します。Model process は repository では
なくそこから起動します。Claude は safe mode で MCP、slash command、project customization を
無効化し、許可する tool は `StructuredOutput` の 1 つだけです。これは CLI が `--json-schema`
の結果を返すための channel です。これも拒否しても hardening にはなりません。Model は report を
作成した後それを提出できず、evidence を送信し課金も発生した上で evidence-only へ fallback する
だけです。Codex は user config/rule を無視し、no approval、read-only
sandbox、ephemeral execution、output schema を使います。返却された string length と list size
も report へ入れる前に検証します。

これは prompt-injection risk を減らしますが、remote model の narrative の正しさを証明しません。
特に Codex は disposable guest 内で read-only tool runtime を持ちます。重要な claim は adjacent
evidence JSON と照合してください。Evidence-only mode は model-input trust problem を避けるため
default です。

Guest から取得する report は untrusted data です。HTML は script と外部 resource を
含みませんが、host は quarantine directory へ pull し、guest 由来 program を実行しては
いけません。Provider credential は guest 内にとどめ、Gmail credential と将来の
cross-project mail sender は trusted host に置きます。

この release は各 VM 内の per-project report までを生成します。Cross-VM portfolio page
や email 送信はまだ行いません。将来の host helper は recovery SSH key で canonical JSON
を pull・validate し、portfolio summary を render・mail できます。その場合も Gmail
credential を guest に渡す必要はありません。
