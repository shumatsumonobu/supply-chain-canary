# supply-chain-canary

> Simulated supply-chain attacks in CI/CD — can cicd-sensor detect, block, and alert at runtime? (+ a commit-time layer, Betterleaks, that stops secrets before they land)
>
> CI/CD にわざとサプライチェーン攻撃を仕込んで、cicd-sensor（ビルド実行時）がちゃんと検知・ブロック・通知できるか試す。コミット時の漏れは Betterleaks で止める2層構成

## 概要

このリポは、CI/CD のサプライチェーン攻撃に**2層**（コミット時 ＋ ビルド実行時）で備える**実践ガイド** ＋ 攻撃を**自分でわざと仕込んで**検知力を試した記録

- **防御は2層**（ここがこのリポの肝）
  - **コミット時** — シークレットの混入を [Betterleaks](https://github.com/betterleaks/betterleaks) で止める
  - **ビルド実行時** — ジョブのふるまいを [cicd-sensor](https://github.com/cicd-sensor/cicd-sensor) で見張る
  - 今回ちゃんと試したのは後者（ビルド実行時＝ランタイム層）。前者はその手前、コミット時の漏れを止める別の層
- **cicd-sensor とは** ── CI/CD ジョブの裏側をまるっと見張る OSS
  - **何を見る** — ジョブ中のプロセス起動・通信先・ファイルアクセス
  - **どうやって** — Linux カーネルの技術 **eBPF**（カーネルから挙動をリアルタイムに捕捉する仕組み）で記録
  - **位置づけ** — PC を守る **EDR**（端末の不審な挙動を検知・対応するセキュリティ製品）の CI/CD 版
  - **作者** — GitLab のセキュリティエンジニア [@rung](https://github.com/rung)
- **なぜ必要か** ── 悪意あるパッケージは `npm install` 時に裏で動く
  - インストール時（npm が自動で走らせる **lifecycle scripts**）に認証情報（`~/.aws/credentials` など）を盗む／メタデータ API（クラウドの認証情報が取れる窓口）でトークンを抜く
  - 普段の CI/CD では、その裏の動きが**まったく見えない**
  - → cicd-sensor が eBPF でそこを可視化
- **検知は3層**（全部を自分で書く必要はない）
  1. **baseline ルール（標準装備）** — 認証情報の読み取りや既知の悪性ドメイン(IOC)など、汎用的な攻撃は最初から検知する。自分で書かなくていい
  2. **観測ログ（ルール不要）** — プロセス起動・通信先・ファイルアクセスは、マッチするルールが無くても全部記録される。あとから調査（フォレンジック）に使える
  3. **カスタムルール（任意・自分で書く）** — 「このビルドはクラウドのメタデータに触るはずがない」のような “自分の環境にとっての正常” は、cicd-sensor 側からは判断できない。そこは自分でルールを書く

```mermaid
flowchart TB
    Dev[開発者]
    subgraph L1["① コミット時 ─ Betterleaks（シークレット混入を止める）"]
        Hook[pre-commit フック<br/>手元でブロック] -->|git push| Scan[GitHub Actions<br/>push / PR で再走査]
    end
    subgraph L2["② ビルド実行時 ─ cicd-sensor（ふるまいを見張る）"]
        Build[CI ビルド<br/>npm install / build] --> Sensor[cicd-sensor（eBPF）<br/>挙動を監視]
        Sensor --> Rules[baseline ＋ カスタムルール<br/>→ 検知 / terminate]
    end
    Dev -->|git commit| Hook
    Scan --> Build
    Rules -->|失敗時| Slack[Slack 通知]
```

> **結論**: `npm install` に 3 つの攻撃（認証情報の読み取り・メタデータアクセス・外部への持ち出し）を仕込んで試した
>
> 1. 標準(baseline)ルールだけ → **1 つしかアラートにならない**
> 2. カスタムルールを 2 本追加 → **残り 2 つもアラート化**（3 つ全部）
>
> 検知されなかった分も、観測ログには最初から全部残っている。さらに `terminate` で**検知時にビルドを止め**、その失敗を **Slack に通知**するところまでつなげた（サーバー不要）

## クイックスタート（自分の CI/CD に導入する）

導入は手元 → CI の順（Betterleaks → cicd-sensor）

> **このリポの設定ファイルを自分のリポにコピーして使う**（`git clone` で取得 → 該当ファイルをコピー）:
>
> - `.githooks/pre-commit`
> - `.github/workflows/betterleaks.yml`
> - `.github/workflows/cicd-sensor.yml`
> - `.cicd-sensor/`
>
> 以下のコード/結果のうち、ラウンド1〜4 はこのリポで取った実証（参考）

| | Betterleaks（コミット時） | cicd-sensor（ビルド実行時） |
|---|---|---|
| **守る対象** | リポジトリに混入するシークレット | CI/CD ジョブの実行時挙動 |
| **いつ効く** | コミット前（pre-commit）＋ push/PR（CI） | ビルド中（postinstall などの実行時） |
| **検知するもの** | API キー・トークン・パスワード等の平文 | 認証情報の読み取り・メタデータ通信・外部送信 |
| **技術** | パターン照合＋エントロピー（ランダムさ）＋トークン解析 | eBPF（カーネルから挙動を捕捉） |

1. **Betterleaks（コミット時にシークレットを止める）**

   [Betterleaks](https://github.com/betterleaks/betterleaks) は [Gitleaks](https://github.com/gitleaks/gitleaks) の後継（原作者が作り直し・設定/CLI 互換で差し替え可能・検出再現率 **70.4% → 98.6%**）。コミット前に API キー・トークンの混入を止める

   > **注意（配布元の取り違え）**: 公式は **`betterleaks/betterleaks`**（MIT・Gitleaks チーム）。`zricethezav/betterleaks`（原作者っぽい名前）は **実在しない（404）**。出どころと checksum を確認してから入れる

   1. **インストール**（バイナリ＋checksum 照合）

      ```bash
      # 例: Linux/macOS x64（mac は darwin_arm64 / darwin_x64 に置換）。以下は Unix シェル前提
      VER=1.5.0
      F=betterleaks_${VER}_linux_x64.tar.gz
      curl -sSfL -O "https://github.com/betterleaks/betterleaks/releases/download/v${VER}/${F}"
      curl -sSfL -O "https://github.com/betterleaks/betterleaks/releases/download/v${VER}/checksums.txt"
      grep "$F" checksums.txt | sha256sum -c -   # ← 必ず OK を確認
      tar -xzf "$F" betterleaks && install -D -m 0755 betterleaks ~/bin/betterleaks
      betterleaks version
      ```

      > **環境別メモ**
      >
      > - `~/bin` が PATH に無ければ通す（`export PATH="$HOME/bin:$PATH"`）。CI と揃えるなら `/usr/local/bin` へ（`sudo install -m 0755 betterleaks /usr/local/bin/betterleaks`）
      > - Windows は `windows_x64.zip` を展開し、`certutil -hashfile betterleaks.exe SHA256` で checksum 照合
      > - 他の入れ方: `brew install betterleaks` ／ `go install github.com/betterleaks/betterleaks@latest` ／ `docker pull ghcr.io/betterleaks/betterleaks:latest`（`@latest`/`:latest` は浮動タグ。固定するなら上のバイナリ取得が本筋）

   2. **pre-commit フック**（手元でブロック）— このリポの [.githooks/pre-commit](.githooks/pre-commit) を**自分のリポにコピー**（`chmod +x .githooks/pre-commit`）してから有効化:

      ```bash
      git config core.hooksPath .githooks
      ```

      - `git commit` のたびにステージ差分を `betterleaks git --staged` で走査 → シークレットがあれば即中止（`git`＝履歴/差分を走査、`detect`＝作業ツリーを走査）
      - 誤検知は行末 `betterleaks:allow` か `.betterleaks.toml` で除外、緊急回避は `git commit --no-verify`

   3. **GitHub Actions**（push/PR でも）— 手元のフックは任意なので、取りこぼし（フック無効・fork 経由）は CI で防ぐ

      - この [.github/workflows/betterleaks.yml](.github/workflows/betterleaks.yml) を自分のリポの `.github/workflows/` に置けば、push / PR で全履歴を走査し、結果（SARIF 形式）を Artifacts に残す
      - バイナリは **バージョン固定＋checksum 照合** で取得 ── これ自体がサプライチェーン対策

   **確認（このリポでの実証）** — 初回スキャン（`betterleaks detect --source .`）→ **`no leaks found`**（おとりの `AKIAIOSFODNN7EXAMPLE` はこのリポ固有・AWS 公式サンプルで標準 allowlist 済み）。自分のリポでも `betterleaks detect --source .` が `no leaks found` なら導入 OK

   手元で試すなら [.env.example](.env.example) を `.env` にコピーしてダミー鍵を入れ、commit を試すと一発で止まる（検証済み）:

   ```console
   # .env.example を .env にコピーし、secret を本物っぽいダミー40桁に変えて commit を試すと…
   $ cp .env.example .env
   $ git add -f .env && git commit -m test
   betterleaks: ステージされた変更をシークレット走査中...
   WRN  leaks found: 1
   シークレットを検出したのでコミットを中止
   # exit=1 → コミットは作られない
   ```

   > `.env` は [.gitignore](.gitignore) にも追加済み（第一防御線）
   >
   > すり抜けた分（`git add -f`・別名ファイル）を捕まえるのが Betterleaks の二段目

2. **cicd-sensor（ビルド実行時のふるまいを見る）**

   1. **cicd-sensor の導入** — 既存ワークフローの steps 先頭に 1 行足すだけ

      - 各ジョブの Artifacts に `cicd-sensor-report.html` が出て、baseline ルールが認証情報の読み取りなどを自動でアラートする
      - Action はリポ直下の `.cicd-sensor/`（`config.yaml`＋`rules/`）を自動で読むので、カスタムルールや terminate を使うならこのディレクトリも自分のリポに置く

      ```yaml
      steps:
        - uses: cicd-sensor/cicd-sensor-action@10fa5e7d8bf293cb679c9859f67d745c17cfc70f # v0.0.32
        # 以降は普段のステップ（checkout, npm install, build ...）
      ```

      > - 前提: eBPF を使うので**特権実行**が必要。GitHub-hosted ランナー（`ubuntu-24.04`）なら kernel ≥ 5.15 / cgroup v2 / 権限が自動で満たされる。self-hosted は privileged 実行が必要（[公式ドキュメント](https://cicd-sensor.github.io/)参照）
      > - オーバーヘッドはカーネル内の軽量フックで一般に小さいが、ジョブ特性次第（気になるなら計測を）
      > - Action は **SHA 固定推奨**（タグは書き換え可能・SHA は不変。このリポの[実ワークフロー](.github/workflows/cicd-sensor.yml)は固定済み。これ自体がサプライチェーン対策）

   2. **カスタムルールの追加（任意）** — 「このビルドはメタデータに触らない」等の環境固有の脅威は、`.cicd-sensor/rules/` にカスタムルールを書く。例（メタデータ通信を検知）:

      ```yaml
      rule_sets:
        - ruleset_id: canary/custom
          rules:
            - rule_id: imds_access
              event_type: network_connect
              condition: remote_ip == "169.254.169.254"
              action: detect
      ```

   3. **検知時のビルド停止（terminate）** — ルールを `action: terminate`、`config.yaml` を `monitor_mode: false` にすると、検知でビルドが失敗（赤）になり攻撃をブロックできる:

      ```yaml
      # .cicd-sensor/config.yaml
      monitor_mode: false   # true=監視のみ（緑のまま）／ false=検知で停止
      ```

      このリポの同梱設定は安全側（`detect` / `monitor_mode: true`）なので、実際にブロックするにはルールの `action` と上の `monitor_mode` の**両方**を変える

   4. **Slack への通知** — 検知でビルドが失敗したら Slack へ通知

      次の 3 つをやる:

      - **Webhook の発行** — Slack で発行:
        - [api.slack.com/apps](https://api.slack.com/apps) → Create New App → **From scratch**
        - App Name（`cicd-sensor-alert`）と workspace を選ぶ → Create App
        - 左メニュー **Incoming Webhooks** を On → **Add New Webhook to Workspace**
        - 通知先チャンネルを選んで許可 → 発行された **Webhook URL** をコピー
        - つまずき: **From scratch** を選ぶ／workspace を間違えない／ページの「Sample curl」URL は**例**（本物は Copy ボタンから）／`#general` が無ければ `#all-...` でよい
        - 任意の動作確認: `curl -X POST -H 'Content-type: application/json' --data '{"text":"test"}' "<Webhook URL>"` で Slack に出れば OK
      - **secret に登録** — Settings → Secrets and variables → Actions → New repository secret → Name `SLACK_WEBHOOK` / Value: Webhook URL（URL は鍵。コードに書かず必ず secret に入れる）
      - **通知ステップを置く** — `if: failure()` の通知ステップを **cicd-sensor を回すジョブの末尾**に置く（このリポでは `malicious-install` ジョブの `Notify Slack on detection`。実装は[実ワークフロー](.github/workflows/cicd-sensor.yml)）。検知失敗時だけ投稿し、secret 未設定（fork 等）では安全にスキップする

   5. **手元で再現（おまけ）** — fork → fork 先で Actions を有効化（fork はデフォルトで無効）→ push または手動実行 → clean / malicious のレポートを比較

> **トラブルシュート**: コミットがブロックされない → `git config core.hooksPath` とフックの実行権限を確認／アラートが出ない → ルールの `event_type`・`condition` を確認／Action がエラー → self-hosted は特権実行が要る／checksum NG → ダウンロードし直す

## 構成

```
.
├── package.json                 # 本体依存（axios 0.21.4）。攻撃の起点はここではなく fake-malicious-dep 側
├── fake-malicious-dep/          # 侵害されたパッケージを模した自作パッケージ
│   ├── package.json             # postinstall で payload を実行
│   └── payload.sh               # 攻撃ペイロード（3 パターン）
├── .cicd-sensor/
│   ├── config.yaml              # monitor_mode: true（検知のみ・kill しない）
│   └── rules/
│       └── custom.yaml          # 自作の検知ルール（ラウンド2で追加）
├── .env.example                 # シークレット混入を試す見本（.env にコピーして使う）
├── .githooks/
│   └── pre-commit               # Betterleaks でコミット前にシークレットを走査
├── .github/workflows/
│   ├── cicd-sensor.yml          # clean-install / malicious-install の 2 ジョブ
│   └── betterleaks.yml          # push/PR でシークレット走査（2層防御の片側）
├── results/                     # 実験で出たレポート（ラウンド1〜3 の HTML）
└── screenshots/                 # ビルド失敗・Slack 通知の画面（READMEで使用）
```

- **clean-install**: 普通に `npm install`。クリーンなレポートになる
- **malicious-install**: おとり認証情報を置いてから `fake-malicious-dep` を入れる。postinstall が発火して、3 つの攻撃の動きが走る → cicd-sensor が検知する

## ルールの書き方

概要の「検知は3層」の3層目＝環境固有のカスタムルール。このリポでラウンド2に足したのがこれ:

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

## 対応範囲

このリポのメインは**ランタイム層（cicd-sensor）**の検証。Betterleaks が守るコミット時のシークレットの漏れは、検知力の実験対象**外**

**実証したこと**: ラウンド1〜4 ＝ 検知 / カスタムルールでアラート化 / `terminate` でブロック / Slack 通知

**やっていないこと**（未実装）:

- **Manager 経由のリアルタイム通知 / SIEM（ログ集約・監視の基盤）連携** — 検知ログを S3・Pub/Sub 等に流す公式機能はあるが、このリポでは扱わない
- **Slack 本文への検知詳細** — このリポの Slack 通知は「ビルド失敗＋レポートへの導線」まで。本文に「どの IP・どのルールで検知したか」まで載せたいなら Manager が必要

## 実験の狙い

既知の攻撃パターンを 3 つ仕込んで、cicd-sensor が**どこまで検知できるか**を見てみる

| 攻撃# | 攻撃 | payload の動作 |
|---|------|---------------|
| 1 | 認証情報の読み取り | `~/.aws/credentials` `~/.npmrc` を `cat` |
| 2 | クラウドメタデータへのアクセス | `169.254.169.254` に `curl` |
| 3 | 外部への持ち出し | 外部ホストに `curl`（持ち出しの模倣） |

> **安全性** — 本物のデータは一切持ち出さない:
>
> - 読み取る認証情報は**おとり**（AWS 公式のサンプルキー `AKIAIOSFODNN7EXAMPLE`）
> - 持ち出し先は何もしない `example.com`
> - 攻撃の「挙動」だけを再現して、検知できるか見るのが目的

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
> 図の「→ アラート」と「観測ログ止まり」はこの違い

## 結果

この実験の肝は「どの攻撃が**アラート**になり、どれが**観測ログ**止まりになるか」。レポート実物は [results/](results/) に置いてある（ラウンド1〜3 の HTML レポート計 5 本。ラウンド4 は Slack 通知のみでレポート無し）

> **レポートの見方**: 上部に**アラート**、下部に**観測ログ**（全プロセス・通信・ファイルアクセス）。各イベントに `payload.sh ← node ← Runner.Worker` のような親子関係（プロセス系譜）が付く

1. **ラウンド1: 標準(baseline)ルールだけ**

   [round1-malicious-install-report.html](results/round1-malicious-install-report.html) / [round1-clean-install-report.html](results/round1-clean-install-report.html)

   | 攻撃# | 攻撃 | 結果 | レポート上の扱い |
   |---|------|------|----------------|
   | 1 | 認証情報の読み取り | **アラート発火** | baseline ルール `generic_credential_access` が発火。`cat ~/.aws/credentials` を捕捉し、`payload.sh ← node ← Runner.Worker` の親子関係まで記録 |
   | 2 | メタデータアクセス（169.254.169.254） | **観測ログのみ**（アラートなし） | `network_connections` に `169.254.169.254:80` への `curl` がプロセス系譜つきで記録された。baseline ルールでのアラートは出ない |
   | 3 | 外部への持ち出し（example.com） | **観測ログのみ**（アラートなし） | `domain_observations` に `example.com` への `curl` がプロセス系譜つきで記録された。同上 |

   攻撃2・3 にアラートが出ないのは「見逃した」からではない。メタデータアクセスや外部通信は、正常なビルドにもある。だから baseline は一律に "悪" とは判定しない。アラートにするかは環境次第 → 自分でルールを書く（ラウンド2）

2. **ラウンド2: カスタムルールを 2 本追加**

   [round2-malicious-install-report.html](results/round2-malicious-install-report.html) / [round2-clean-install-report.html](results/round2-clean-install-report.html)

   `.cicd-sensor/rules/custom.yaml` に「169.254.169.254 への通信」「example.com への送信」を `detect` するルールを足して再実行した

   | 攻撃# | 攻撃 | ラウンド1 | ラウンド2 |
   |---|------|----------|----------|
   | 1 | 認証情報の読み取り | baseline アラート | baseline アラート（変わらず） |
   | 2 | メタデータアクセス | 観測のみ | **`canary/custom/imds_access` がアラート発火** |
   | 3 | 外部への持ち出し | 観測のみ | **`canary/custom/external_exfil_example_com` がアラート発火** |

   **3 つともアラートになった**（攻撃1 は baseline ルール、攻撃2・3 は自作のカスタムルール）。clean-install は両ラウンドとも検知ゼロ＝カスタムルールが正常なビルドを誤検知しないことも確認できた

3. **ラウンド3: terminate でビルドを止める**

   [round3-malicious-install-report.html](results/round3-malicious-install-report.html)

   ラウンド2までは `action: detect`（記録するだけ）。これを `action: terminate` に変え、`config.yaml` の `monitor_mode` を `false` にすると、検知した瞬間にジョブが止まる

   結果:

   - **malicious-install → 失敗（赤）**: 攻撃を検知してジョブが停止した
   - **clean-install → 成功（緑）のまま**: 正常なビルドは止まらない（誤検知なし）
   - **失敗したジョブにもレポートは残る**: Artifacts とジョブサマリから見られる

   ![ビルドが失敗（malicious-install が赤、clean-install は緑）](screenshots/round3-build-failed.png)

   攻撃ジョブは中断（canceled / exit code 1）され、それでもレポート artifact は残る:

   ![ジョブ中断とレポート残存](screenshots/round3-terminated-and-report-kept.png)

   > 注: payload は 3 攻撃を一気に実行するので、terminate が効くまでに 3 つとも検知ログには載る。ただしジョブの最終結果は失敗（赤）になる
   >
   > 注: enforcement（terminate）の検証は一時ブランチで実施。`main` は監視モード（`monitor_mode: true`・CI は緑）のまま。実運用ではルールを `terminate` にしてブロックする

4. **ラウンド4: Slack に通知する**

   最後に、ビルド失敗を Slack へ通知する。malicious-install ジョブ末尾に `if: failure()` の通知ステップを足すと、terminate で失敗したとき Slack の Webhook にこう届く:

   ![Slack に届いた検知通知](screenshots/round4-slack-notification.png)

   追加サーバー不要で、検知から確認まで一本につながる:

   1. 攻撃を検知 → ビルドが赤くなる（terminate）
   2. その失敗が Slack に通知される（ワークフローの通知ステップ）
   3. run を開けば、レポートで「何が・どこで・どのルールで」検知されたか確認できる

## 用語メモ

- **eBPF** — Linux カーネルの中で安全に小さなプログラムを動かす技術。カーネルを改造せずに「プロセスが起動した」「ファイルを開いた」「通信が発生した」をリアルタイムで捕捉できる。cicd-sensor はこれで `npm install` の裏の動きをもれなく記録
- **EDR**（Endpoint Detection and Response）— 端末の挙動を監視して脅威を検知・対応する仕組み。cicd-sensor はそれを CI/CD ジョブに適用したもの
- **lifecycle scripts / postinstall** — npm がインストール時に自動実行するスクリプト。`postinstall` はインストール直後に走る。便利な反面、悪意あるパッケージの「攻撃コードの実行経路」になる
- **メタデータ API（169.254.169.254）** — AWS/GCP/Azure 共通の、VM が自分の設定や認証トークンを取得する内部用エンドポイント。攻撃者がここに到達するとクラウドの認証情報を盗める（**SSRF**＝サーバーを踏み台に内部へ通信させる攻撃、の定番ゴール）
- **CEL**（Common Expression Language）— ルールの条件式を書くための小さな式言語。`==` や `endsWith()` などが使える
- **IOC**（Indicator of Compromise）— 侵害の痕跡。既知の攻撃で使われるドメイン・IP・ハッシュなど。baseline ルールはこれらを検知する

## 参考

- [cicd-sensor](https://github.com/cicd-sensor/cicd-sensor) — eBPF-powered runtime security sensor for CI/CD
- [cicd-sensor ドキュメント](https://cicd-sensor.github.io/)
- [開発者を狙う攻撃と CI/CD セキュリティ（catatsuy）](https://zenn.dev/catatsuy/articles/e2fc71d810613a)

by [週末ものづくり部](https://x.com/shumatsumonobu)
