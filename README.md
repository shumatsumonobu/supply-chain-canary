# supply-chain-canary

> Simulated supply chain attacks in CI/CD — can cicd-sensor detect, block, and alert?

[cicd-sensor](https://github.com/cicd-sensor/cicd-sensor) は、**CI/CD ジョブの裏側を丸ごと監視する OSS**。

- **何を見る** — ジョブ中のプロセス起動・通信先・ファイルアクセス
- **どうやって** — Linux カーネルの技術 **eBPF**（カーネルから挙動をリアルタイムに捕捉する仕組み）で記録
- **位置づけ** — PC を守る **EDR**（端末の不審な挙動を検知・対応するセキュリティ製品）の CI/CD 版
- **作者** — GitLab のセキュリティエンジニア [@rung](https://github.com/rung)

本リポは、それを自分の CI/CD に導入して使うための**実践ガイド**。サプライチェーン攻撃を**わざと自分で仕込んで**、本当に検知・ブロックできるかを検証した記録でもある。

> **結論**: `npm install` に 3 つの攻撃（認証情報の読み取り・メタデータアクセス・外部への持ち出し）を仕込んで検証した。
>
> 1. 標準(baseline)ルールだけ → **1 つしかアラートにならない**
> 2. カスタムルールを 2 本追加 → **残り 2 つもアラート化**（3 つ全部）
> 3. 検知されなかった分も、観測ログには最初から全部残っていた
>
> さらに `terminate` で**検知時にビルドを止め**、その失敗を **Slack に通知**するところまで繋いだ（サーバー不要）。
>
> 普段見えない `npm install` の裏側が、ルール次第でここまで見える。→ [結果](#結果)

## 仕組み

- **問題**: `npm install` に悪意あるパッケージが紛れ込むと、インストール時に裏で認証情報を盗んだり外部へ送ったりする
- **でも気づけない**: 普段の CI/CD では、その裏の挙動が**まったく見えない**
- **cicd-sensor がやること**: ジョブの裏側（プロセス・通信・ファイルアクセス）を eBPF で丸ごと監視し、不審な挙動を可視化する
- **このリポ**: その検知力を、攻撃を自分で仕込んで確かめたもの

```mermaid
flowchart TD
    A["npm install ./fake-malicious-dep"] --> B["インストールしただけで<br/>payload.sh が自動実行される<br/>（npm の postinstall の仕組み）"]
    B --> C1["1. cat ~/.aws/credentials<br/>（認証情報を読む）"]
    B --> C2["2. curl 169.254.169.254<br/>（メタデータに通信）"]
    B --> C3["3. curl example.com<br/>（外部へ送信）"]
    C1 --> R1["baseline ルール<br/>generic_credential_access<br/><b>→ アラート</b>"]
    C2 --> R2["カスタムルール<br/>imds_access<br/><b>→ アラート</b><br/>（baseline では観測ログ止まり）"]
    C3 --> R3["カスタムルール<br/>external_exfil_example_com<br/><b>→ アラート</b><br/>（baseline では観測ログ止まり）"]
    SENSOR["cicd-sensor（eBPF）が<br/>ジョブ全体を監視・記録"] -. 監視 .-> B
```

> cicd-sensor の出力は 2 種類:
>
> - **アラート** ＝ ルールに引っかかり「怪しい」と警告されたもの
> - **観測ログ** ＝ ルールには引っかからないが、挙動の記録は残っているもの
>
> 図の「→ アラート」と「観測ログ止まり」はこの違い。

## 対応範囲

**実証したこと**: ラウンド1〜4 ＝ 検知 / カスタムルールでアラート化 / `terminate` でブロック / Slack 通知（詳細は[結果](#結果)）。

**やっていないこと**（未実装）:

- **Manager 経由のリアルタイム通知 / SIEM 連携** — 検知ログを S3・Pub/Sub 等に流す公式機能はあるが、本リポでは扱わない
- **Slack 本文への検知詳細** — 本リポの Slack 通知は「ビルド失敗＋レポートへの導線」まで。本文に「どの IP・どのルールで検知したか」まで載せたい場合は Manager が要る

## 使い方（自分の CI/CD に導入する）

上から順にやれば導入できる。各ステップは [結果](#結果) で実証済み。

1. **cicd-sensor を入れる** — 既存ワークフローの steps 先頭に 1 行足すだけ。各ジョブの Artifacts に `cicd-sensor-report.html` が出て、baseline ルールが認証情報の読み取りなどを自動でアラートする（→ [ラウンド1](#ラウンド1-標準baselineルールだけ)）

   ```yaml
   steps:
     - uses: cicd-sensor/cicd-sensor-action@v0.0.32
     # 以降は普段のステップ（checkout, npm install, build ...）
   ```

   > 前提: GitHub-hosted ランナー（`ubuntu-24.04`）なら kernel ≥ 5.15 / cgroup v2 は自動で満たされる。self-hosted は[公式ドキュメント](https://cicd-sensor.github.io/)を参照。Action は **SHA 固定推奨**（タグは書き換え可能・SHA は不変。本リポの[実ワークフロー](.github/workflows/cicd-sensor.yml)は固定済み。これ自体がサプライチェーン対策）。

2. **自分のルールを足す（任意）** — 「このビルドはメタデータに触らない」等の環境固有の脅威は、`.cicd-sensor/rules/` にカスタムルールを書く（→ [ラウンド2](#ラウンド2-カスタムルールを-2-本追加) / [ルールの考え方](#ルールの考え方全部自分で書く必要はない)）

3. **検知でビルドを止める** — ルールを `terminate` にすると、検知でビルドが失敗（赤）になり攻撃をブロックできる（→ [ラウンド3](#ラウンド3-terminate-でビルドを止める)）

4. **Slack に通知する** — 検知でビルドが失敗したら Slack に飛ばす（→ [ラウンド4](#ラウンド4-slack-に通知する)）。次の 3 つをやる:

   - **Webhook を作る** — Slack で発行する:
     - [api.slack.com/apps](https://api.slack.com/apps) → Create New App → **From scratch**
     - App Name（`cicd-sensor-alert`）と workspace を選ぶ → Create App
     - 左メニュー **Incoming Webhooks** を On → **Add New Webhook to Workspace**
     - 通知先チャンネルを選んで許可 → 発行された **Webhook URL** をコピー
     - つまずき: **From scratch** を選ぶ／workspace を間違えない／ページの「Sample curl」URL は**例**（本物は Copy ボタンから）／`#general` が無ければ `#all-...` でよい
     - 任意の動作確認: `curl -X POST -H 'Content-type: application/json' --data '{"text":"test"}' "<Webhook URL>"` で Slack に出れば OK（Git Bash だと日本語が文字化けするが、GitHub Actions からは正常）
   - **secret に登録** — Settings → Secrets and variables → Actions → New repository secret → Name `SLACK_WEBHOOK` / Value: Webhook URL（URL は鍵。コードに書かず必ず secret に入れる）
   - **通知ステップを置く** — malicious-install ジョブ末尾の `Notify Slack on detection`（実装は[実ワークフロー](.github/workflows/cicd-sensor.yml)）。`if: failure()` で検知失敗時だけ投稿し、secret 未設定（fork 等）では安全にスキップする

5. **この実験を手元で再現する（おまけ）** — fork → fork 先で Actions を有効化（fork はデフォルトで無効）→ push または手動実行 → clean / malicious のレポートを比較

## きっかけ

依存パッケージの脆弱性を調べていて、あることに気づいた。ソースコードを静的に見て「安全」と判断できても、`npm install` の**実行時に裏で何が起きているか**は誰も見ていない。

そこを可視化する [cicd-sensor](https://github.com/cicd-sensor/cicd-sensor) を見つけたので、既知の攻撃を自分で仕込んで本当に検知できるか試した。

## 背景

`npm install` は裏で任意のスクリプトを実行できる（lifecycle scripts）。侵害されたパッケージを入れると、こんなことが起きる:

- ビルドマシン上の認証情報（`~/.aws/credentials` など）を読まれる
- クラウドのメタデータ API（169.254.169.254）経由でトークンを盗まれる

ところが普段の CI/CD では「`npm install` の裏で何が起きたか」が**まったく見えない**。

そこを埋めるのが [cicd-sensor](https://github.com/cicd-sensor/cicd-sensor)（冒頭で触れた CI/CD 版の EDR）。ジョブの裏側を記録して、`npm install` が裏で何をしたかを後から追えるようにする。

## 実験の狙い

既知の攻撃パターンを 3 つ仕込み、cicd-sensor が**どこまで検知できるか**を確かめる。

| # | 攻撃 | payload の動作 |
|---|------|---------------|
| 1 | 認証情報の読み取り | `~/.aws/credentials` `~/.npmrc` を `cat` |
| 2 | クラウドメタデータへのアクセス | `169.254.169.254` に `curl` |
| 3 | 外部への持ち出し | 外部ホストに `curl`（持ち出しの模倣） |

> **安全性** — 本物のデータは一切持ち出さない:
>
> - 読み取る認証情報は**おとり**（AWS 公式のサンプルキー `AKIAIOSFODNN7EXAMPLE`）
> - 持ち出し先は何もしない `example.com`
> - 攻撃の「挙動」だけを再現して、検知できるか見るのが目的

## 構成

```
.
├── package.json                 # 本体依存（axios 0.21.4）。攻撃ベクタはここではなく fake-malicious-dep 側
├── fake-malicious-dep/          # 侵害されたパッケージを模した自作パッケージ
│   ├── package.json             # postinstall で payload を実行
│   └── payload.sh               # 攻撃ペイロード（上記 3 パターン）
├── .cicd-sensor/
│   ├── config.yaml              # monitor_mode: true（検知のみ・kill しない）
│   └── rules/
│       └── custom.yaml          # 自作の検知ルール（ラウンド2で追加）
├── .github/workflows/
│   └── cicd-sensor.yml          # clean-install / malicious-install の 2 ジョブ
├── results/                     # 実験で出たレポート（ラウンド1〜3 の HTML）
└── screenshots/                 # ビルド失敗・Slack 通知の画面（READMEで使用）
```

- **clean-install**: 普通に `npm install`。クリーンなレポートが出るはず
- **malicious-install**: おとり認証情報を置いてから `fake-malicious-dep` を入れる。postinstall が発火し、3 つの攻撃挙動が走る → cicd-sensor が検知するはず

## 結果

この実験の肝は「どの攻撃が**アラート**になり、どれが**観測ログ**止まりになるか」（2 種類の違いは[仕組み](#仕組み)参照）。レポート実物は [results/](results/) に置いてある（ラウンド1〜3 の計 5 本）。

### ラウンド1: 標準(baseline)ルールだけ

[round1-malicious-install-report.html](results/round1-malicious-install-report.html) / [round1-clean-install-report.html](results/round1-clean-install-report.html)

| # | 攻撃 | 結果 | レポート上の扱い |
|---|------|------|----------------|
| 1 | 認証情報の読み取り | **アラート発火** | baseline ルール `generic_credential_access` が発火。`cat ~/.aws/credentials` を捕捉し、`payload.sh ← node ← Runner.Worker` の親子関係まで記録 |
| 2 | メタデータアクセス（169.254.169.254） | **観測ログのみ**（アラートなし） | `network_connections` に `169.254.169.254:80` への `curl` がプロセス系譜つきで記録された。baseline ルールでのアラートは出ない |
| 3 | 外部への持ち出し（example.com） | **観測ログのみ**（アラートなし） | `domain_observations` に `example.com` への `curl` がプロセス系譜つきで記録された。同上 |

②③にアラートが出ないのは「見逃した」からではない。メタデータアクセスや外部通信は、正常なビルドにもある。だから baseline は一律に "悪" とは判定しない。アラートにするかは環境次第 → 自分でルールを書く（ラウンド2）。

### ラウンド2: カスタムルールを 2 本追加

[round2-malicious-install-report.html](results/round2-malicious-install-report.html) / [round2-clean-install-report.html](results/round2-clean-install-report.html)

`.cicd-sensor/rules/custom.yaml` に「169.254.169.254 への通信」「example.com への送信」を `detect` するルールを足して再実行した。

| # | 攻撃 | ラウンド1 | ラウンド2 |
|---|------|----------|----------|
| 1 | 認証情報の読み取り | baseline アラート | baseline アラート（変わらず） |
| 2 | メタデータアクセス | 観測のみ | **`canary/custom/imds_access` がアラート発火** |
| 3 | 外部への持ち出し | 観測のみ | **`canary/custom/external_exfil_example_com` がアラート発火** |

**3 つともアラートになった**（① は baseline ルール、②③ は自作のカスタムルール）。clean-install は両ラウンドとも検知ゼロ＝カスタムルールが正常なビルドを誤検知しないことも確認できた。

### ラウンド3: terminate でビルドを止める

[round3-malicious-install-report.html](results/round3-malicious-install-report.html)

ラウンド2までは `action: detect`（記録するだけ）。これを `action: terminate` に変え、`config.yaml` の `monitor_mode` を `false` にすると、検知した瞬間にジョブが止まる。

結果:

- **malicious-install → 失敗（赤）**: 攻撃を検知してジョブが停止した
- **clean-install → 成功（緑）のまま**: 正常なビルドは止まらない（誤検知なし）
- **失敗したジョブにもレポートは残る**: Artifacts とジョブサマリから見られる

![ビルドが失敗（malicious-install が赤、clean-install は緑）](screenshots/round3-build-failed.png)

攻撃ジョブは中断（canceled / exit code 1）され、それでもレポート artifact は残る:

![ジョブ中断とレポート残存](screenshots/round3-terminated-and-report-kept.png)

> 注: payload は 3 攻撃を一気に実行するので、terminate が効くまでに 3 つとも検知ログには載る。ただしジョブの最終結果は失敗（赤）になる。
>
> 注: enforcement（terminate）の検証は一時ブランチで実施。`main` は監視モード（`monitor_mode: true`・CI は緑）のまま。実運用ではルールを `terminate` にしてブロックする。

### ラウンド4: Slack に通知する

最後に、ビルド失敗を Slack へ通知する（設定手順は [使い方の手順4](#使い方自分の-cicd-に導入する)）。malicious-install ジョブ末尾に `if: failure()` の通知ステップを足すと、terminate で失敗したとき Slack の Webhook にこう届く:

![Slack に届いた検知通知](screenshots/round4-slack-notification.png)

これで、追加インフラ（サーバー）なしで一連の流れがつながった:

1. 攻撃を検知 → ビルドが赤くなる（terminate）
2. その失敗が Slack に通知される（ワークフローの通知ステップ）
3. run を開けば、レポートで「何が・どこで・どのルールで」検知されたか確認できる

## ルールの考え方（全部自分で書く必要はない）

cicd-sensor の検知は 3 層になっている。

1. **baseline ルール（標準装備）** — 認証情報の読み取りや既知の悪性ドメイン(IOC)など、汎用的な攻撃は最初から検知する。自分で書かなくていい。
2. **観測ログ（ルール不要）** — プロセス起動・通信先・ファイルアクセスは、マッチするルールが無くても全部記録される。後からフォレンジックに使える。
3. **カスタムルール（任意・自分で書く）** — 「このビルドはクラウドのメタデータに触るはずがない」のような “自分の環境にとっての正常” は、cicd-sensor 側からは判断できない。そこは自分でルールを書く。

このラウンド2で足したルールが 3 層目:

```yaml
rule_sets:
  - ruleset_id: canary/custom
    rules:
      - rule_id: imds_access
        rule_name: "Cloud metadata endpoint access (169.254.169.254)"
        event_type: network_connect                 # 何を見るか = 外向きのネットワーク接続
        condition: remote_ip == "169.254.169.254"    # 接続先IPが完全一致したら発火
        action: detect                               # 発火時の動作 = 検知記録(ジョブは止めない)

      - rule_id: external_exfil_example_com
        rule_name: "Egress to example.com (simulated exfiltration)"
        event_type: domain                           # 何を見るか = ドメインへのアクセス(DNS解決)
        condition: domain == "example.com" || domain.endsWith(".example.com")
        action: detect
```

- **event_type**: 何のイベントを見るか（`network_connect`=通信 / `domain`=ドメイン解決 / `file_open`=ファイル / `process_exec`=プロセス起動 など）
- **condition**: 条件式（CEL）。`==` `!=` `&&` `||`、文字列は `startsWith()` / `endsWith()` / `contains()`、IP 範囲は `inIpRange(remote_ip, "169.254.0.0/16")`。正規表現は非対応
- **action**: `detect`（検知記録）/ `collect`（調査用に収集）/ `terminate`（ジョブ停止）

書き方の参考（cicd-sensor 公式 User Guide）:

- イベント種別とフィールド → `rule-event-types`
- 条件式の文法 → `rule-cel-conditions`
- ルール構造 → `rule-set`
- 実物のサンプル → [リポジトリの rules/](https://github.com/cicd-sensor/cicd-sensor/tree/main/rules)

## 学び

- 「ソースコードを静的に見て安全」と「実行時に何も起きていない」は別物。後者は実際に走らせて観測しないと確認できない
- 導入コストはワークフローに 1 行だけ。それで `npm install` の裏のプロセス・通信・ファイルアクセスが丸ごと可視化される
- **検知の守備範囲は自分で広げられる**。baseline が拾わない "自分の環境固有の脅威"（このビルドはメタデータに触らない・許可ドメイン以外に通信しない、など）も、カスタムルールを書けばアラートに昇格できる。ラウンド2で実証したのがこれ

## 用語メモ

- **eBPF** — Linux カーネルの中で安全に小さなプログラムを動かす技術。カーネルを改造せずに「プロセスが起動した」「ファイルを開いた」「通信が発生した」をリアルタイムで捕捉できる。cicd-sensor はこれで `npm install` の裏の挙動を漏れなく記録する。
- **EDR**（Endpoint Detection and Response）— 端末の挙動を監視して脅威を検知・対応する仕組み。cicd-sensor はそれを CI/CD ジョブに適用したもの。
- **lifecycle scripts / postinstall** — npm がインストール時に自動実行するスクリプト。`postinstall` はインストール直後に走る。便利な反面、悪意あるパッケージの「攻撃コードの実行経路」になる。
- **メタデータ API（169.254.169.254）** — AWS/GCP/Azure 共通の、VM が自分の設定や認証トークンを取得する内部用エンドポイント。攻撃者がここに到達するとクラウドの認証情報を盗める（SSRF 攻撃の定番ゴール）。
- **CEL**（Common Expression Language）— ルールの条件式を書くための小さな式言語。`==` や `endsWith()` などが使える。
- **IOC**（Indicator of Compromise）— 侵害の痕跡。既知の攻撃で使われるドメイン・IP・ハッシュなど。baseline ルールはこれらを検知する。

## 参考

- [cicd-sensor](https://github.com/cicd-sensor/cicd-sensor) — eBPF-powered runtime security sensor for CI/CD
- [cicd-sensor ドキュメント](https://cicd-sensor.github.io/)
- [開発者を狙う攻撃と CI/CD セキュリティ（catatsuy）](https://zenn.dev/catatsuy/articles/e2fc71d810613a)

by [週末ものづくり部](https://x.com/shumatsumonobu)
