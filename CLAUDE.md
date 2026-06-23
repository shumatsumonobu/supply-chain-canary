# CLAUDE.md

## プロジェクト概要

CI/CD のサプライチェーン攻撃を**わざと自分で仕込んで**、[cicd-sensor](https://github.com/cicd-sensor/cicd-sensor)（eBPF で CI/CD ジョブの動きを見張る OSS）が検知できるかを試す公開実験リポ。詳細は [README.md](README.md) を参照

- 攻撃ペイロードは `fake-malicious-dep/payload.sh`（npm の postinstall で発火）
- 検知ルールは `.cicd-sensor/`（`config.yaml` ＋ `rules/custom.yaml`）
- 実行は GitHub Actions（`.github/workflows/cicd-sensor.yml`）。ローカルでは動かせない（eBPF/Linux 必須）
- 実験結果のレポート（HTML）は `results/`

## コミット規約

- コミットメッセージは日本語で書く
- コミットメッセージに著者表記（`Co-Authored-By` など Claude/Anthropic の表記）を絶対に入れない

## 安全性

攻撃は「動き」だけを再現し、本物のデータは一切持ち出さない。認証情報はおとり（AWS 公式サンプルキー）、持ち出し先は何もしない `example.com`。検知の実験以外の目的で payload を流用しない
