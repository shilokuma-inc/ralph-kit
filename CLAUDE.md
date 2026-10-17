# ralph-kit

各アプリのリポジトリ（shilokuma-inc 以外の organization のものも含む）で使う ralph-loop 一式の正本。仕組みは `README.md` を読む。
**ここを直すと、v1 のタグが動いた時点で全リポジトリのループに届く。** 壊れた版を出すと全リポジトリのループが同時に止まるので、次を守る。

## 変更するとき

- 各リポジトリの中継（`shim/`）・`kit.conf`・ワークフローの呼び出しの形は、なるべく変えない。変えると全リポジトリへの PR が要る（v2 になる）
- 中継（`shim/scripts/ralph-kit.sh`）の処理は、取得した kit の版に任される。ただし kit の取得（`repo.git` の clone・fetch・ロック）と任せるかどうかの判定は、
  各リポジトリのコピーで動く。この部分の互換（キャッシュの置き場所・`RALPH_KIT_*` の環境変数・`kit.conf` の書き方）は崩さない
- スクリプトは macOS の `/bin/bash`（3.2）で動かす。連想配列・`mapfile`・`${var,,}` は使わない。`set -u` の下で空の配列を `"${a[@]}"` で展開しない
- 変数の直後に全角文字を続けない。`${VAR}（` のように波かっこで閉じる（bash 3.2 で unbound variable になる）
- スクリプトの出力・コメント・ドキュメントは日本語で書く（各リポジトリの規約と同じ）
- PR を出す前に、macOS の `/bin/bash tests/run.sh` を流す（CI の Linux は bash 5 なので、3.2 でしか起きない不具合を拾えない）。
  テストは HEAD のコミットを取得して流すので、コミットしてから流す
- 振る舞いを変えたら `CHANGELOG.md` に書き、`VERSION` を上げる（互換を保つならマイナーかパッチ）。`VERSION` を上げた PR のマージで
  `release.yml` がタグを打つ。上げない PR はタグを動かさない（docs だけの変更など）
- playbook は、起動のたびに各ループの playbook へ 3-way merge で取り込まれる。**プレースホルダ（`{{...}}`）のある行と、その前後の行は
  なるべく書き換えない**（各ループでは埋めてあるので衝突し、その更新は取り込まれない）。新しいプレースホルダは足さない（取り込まれない）
- playbook の手順を変えたら、オーケストレーター（shilokuma-inc/ask-hub-apple の `scripts/orchestrator/` と `AskHubKit`）が
  同じ目印・ラベル・ファイル名を読んでいないか確かめる（`ask-hub:*` の目印、`※回答待ち`・`※保留` の書式、`.claude/*.local.*` のファイル名）

## Git

- コミットは `[type] 日本語のメッセージ`、PR タイトルは `【TYPE】タイトル`。PR は squash せず merge commit でマージする
- main に直接 push しない（タグは `release.yml` が打つ）
