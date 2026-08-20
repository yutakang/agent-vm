# 認証情報の取り扱い

[English](credentials.md)

VM 境界は agent を host 上で直接動かすより host をよく保護しますが、同じ guest 内の
別 process から secret を隔離しません。Coding agent、plugin、MCP server、language
server、browser、project command は、`agent` account から利用できる全 credential を
読める可能性があるものとして扱ってください。

## 認証前に provisioning を完了する

Setup script は source code や provider credential を追加する前に全 tool を導入します。
成功 marker と bootstrap 後の cloud-init disable marker を確認してください。

```bash
sudo test -f /var/lib/kvm-agent/provisioned
sudo test -f /etc/cloud/cloud-init.disabled
```

GUI login も確認し、その後、この project に必要な最小 credential だけを追加します。

第三者 installer が侵害されていた場合、この順序により初回 access は空の guest に
限定されます。保証ではありません。後の自動 update や plugin が新しい code を
持ち込む可能性があります。

## Credential の種類

| Credential | 推奨する扱い |
|---|---|
| OpenAI/Anthropic interactive login | Guest 内の初回 flow を使う。可能なら別の信頼端末から MFA/passkey を完了する。VM の破棄・共有前に sign out する。 |
| API key | Project 固有、短期、失効可能、支出上限付きの key を優先する。必要な guest だけへ置く。 |
| Git hosting API token | 必要な issue/PR permission だけを持つ fine-grained・repository-selected token を使う。Git push を別 deploy key で行う場合は Contents read-only に保つ。 |
| Source hosting 用 SSH key | Guest 内で repository 専用 key を作る。Repository deploy key を優先し、host の汎用 private key を VM へコピーしない。 |
| Commit signing key | Review 済み commit を信頼 workstation で sign するか、限定 guest key を使う。高価値 personal signing key を import しない。 |
| Cloud administrator credential | 自律 agent guest へ入れない。scope を狭くした workload identity を作る。 |
| Ollama Cloud login | Remote-provider credential として扱う。CLI が local でも inference は local にならない。 |
| 復旧 SSH key | Private key を host に保つ。Guest へ入るのは public half だけ。 |

## Environment 全体へ secret を置かない

Environment variable は便利ですが、agent は process environment、shell file、log、
project 設定を調べることがあります。一 command または一 project だけに必要な
credential を global export しないでください。

Provider credential store、または permission を限定した file を読む shell wrapper を
優先します。次は private directory と空 file を作り、その file を editor で開く
command です。

```bash
mkdir -p ~/.config/project-agent
chmod 700 ~/.config/project-agent
touch ~/.config/project-agent/credentials.env
chmod 600 ~/.config/project-agent/credentials.env
nano ~/.config/project-agent/credentials.env
```

`touch` は存在しない場合に空 file を作るだけで、software を install しません。
Guest 内で手動編集し、必要 command だけで読み、Git ignore を確認します。Secret を
command-line argument へ直接書かないでください。shell history と process listing に
残る可能性があります。

一つの project 専用 VM では、scope の狭い token 一つを mode `600` file から
`~/.bashrc` で読むことは実用的な選択です。その場合、全 interactive shell とそこから
開始した agent が token を取得します。複数 client・複数 project を混在させる VM では
使わないでください。具体的な GitHub pattern と deploy-key/API-token authority の分離は
[GitHub integration](github-integration_jp.md)に記載しています。

Guest file permission は Unix account 間の偶発的 access を減らしますが、同じ
`agent` user または guest sudo で動く agent は止めません。

## Browser と device 認証

OAuth flow が localhost callback URL または device code を表示する場合があります。
Provider の正しい domain だけで完了してください。

別 machine で callback URL を開くと session を guest へ渡せる場合があります。
その前に次を確認します。

- Flow を開始した CLI。
- 正確な provider domain。
- 対象 account と organization。
- 要求 permission と billing 関係。
- 信頼端末から token を失効できるか。

Password、MFA recovery code、seed phrase、hardware-key secret を coding-agent prompt
へ貼り付けてはいけません。

## SSH-agent forwarding を使わない

Guest SSH server は agent forwarding を拒否し、文書の client command も
`ForwardAgent=no` を設定します。上書きしないでください。Guest process は private
key byte を読めなくても、forward 済み agent へ認証・署名を要求できます。

Source hosting 用には別の guest key を作ります。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/project_ed25519
```

Public key だけを登録し、provider が許す範囲で server-side 権限も限定します。

## 支出と push 権限

VM は、有効 credential による API 課金や悪い変更の push を防ぎません。Provider 側
control を使います。

- Hard/soft spending limit。
- 低い初期 quota。
- Usage alert。
- Repository branch protection。
- 必須 review と CI。
- Force-push 権限なし。
- Release、package publish、billing、organization administration scope なし。
- 別の信頼端末からの迅速な失効。

最も狭い安全側の既定は、read-only repository access と patch export です。Agent branch
への直接 push が workflow を実質的に改善する場合は repository-only deploy key を使い、
`main` を保護し、merge authority を human reviewer に残します。より広い write access
は具体的な用途がある場合だけ付与します。

## Snapshot と clone

Login 後の snapshot は login 状態を複製します。Clone は working API token、cookie、
Git credential、shell history、model provider 設定を含む可能性があります。

別 person/project 用に clone する前:

1. 全 CLI と browser から sign out する。
2. 外部 token を失効する。
3. Project file と credential store を除去する。
4. History clear は hygiene としてだけ行い、安全な消去とは見なさない。
5. できれば credential-free snapshot へ戻る。

価値ある credential を保持した VM image は、recovery され得ると想定せずに公開・添付
してはいけません。

## Incident response

Guest の侵害が疑われる場合:

1. `virt-manager` から network を切るか停止する。
2. 別の信頼 machine から provider、Git、cloud credential を失効する。
3. Provider usage と repository audit log を調べる。
4. VM または clipboard に入った secret を rotate する。
5. Review に必要な最小 evidence/patch だけを export する。
6. Guest をその場で「掃除」せず、clean で credential のない source から rebuild する。
