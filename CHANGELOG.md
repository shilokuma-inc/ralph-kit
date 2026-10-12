# 変更履歴

各アプリのリポジトリは `.claude/ralph/kit.conf` の `ref=v1` で、v1 の最新を使う（`VERSION` を上げた PR が main に入ると、`release.yml` が `v1` を動かす）。
互換を崩す変更（各リポジトリの中継・`kit.conf`・ワークフローの呼び出しの形を変える必要があるもの）は v2 にする。

## 1.3.0（2026-10-12）

- 手動ループの `askhub-manual.sh launch` / `resume` が、ループと一緒に見張り役（`watch-final`）を裏で起動する。
  ループが完了語の promise を出して終わったら、見張り役がメインの checkout で `final` を流し、最終 PR を作る（自動ループと同じく、担当者の指示は要らない）
- promise を出さずに終わったとき（state ファイルが残る異常終了・`ralph-stop.sh` での停止・無進捗での停止）は作らない。結果はループのログに書く
- `ASKHUB_AUTO_FINAL=0` を付けて起動すると、これまでどおり見張り役を起動しない（担当者が `final` を流す）

## 1.2.2（2026-10-12）

- `install.sh --check` は、処理を kit の中継に任せられる中継（1.2 以降）が古くても、ずれとしない（kit の中継が動くので、各リポジトリの更新は要らない）

## 1.2.1（2026-10-12）

- `RALPH_KIT_CACHE` を相対パスで指定しても、中継が絶対パスにする（launch で制御用 worktree へ移った後に kit を見つけられなかった）

## 1.2.0（2026-10-12）

- 中継の処理を、取得した kit の中継（`shim/scripts/ralph-kit.sh`）に任せる。中継の修正も各リポジトリへの PR なしで届く（1.2 の中継を入れたリポジトリから）
- 中継の取得が通信の停止で固まらないようにした（低速が 30 秒続いたら打ち切る）。取得に失敗しても時刻を残し、間隔の内は取得し直さない
- ほかのプロセスの取得が 2 分（`RALPH_KIT_LOCK_TIMEOUT`）を超えて終わらないときは、失敗にせず手元の版を使う

## 1.1.0（2026-10-12）

- 起動のたび（`ralph-start.sh`）に、kit の playbook の更新を制御用 worktree の playbook へ 3-way merge で取り込む。
  祖先は `ralph-setup.sh` が初回にコピーした `.claude/ralph-playbook.base.local.md`。衝突・新しいプレースホルダのときは取り込まない
- 1.1 より前に始めた epic（祖先の記録が無い playbook）は、これまでどおり書き換えない

## 1.0.0（2026-10-12）

各リポジトリにコピーしていたループ一式の正本を、このリポジトリに移した。

- template-app-ios の develop（071679d）の一式を取り込んだ。雛形とスクリプトは、各リポジトリの `.claude/ralph/` ではなく kit から読む
- 各リポジトリに置く中継（`scripts/ralph-kit.sh` と 4 本）・`kit.conf`・`install.sh` を足した
- ゴール元の Discussion を閉じるワークフローを、各リポジトリから `uses:` で呼べる形にした
- 各リポジトリにしか無かった改善を取り込んだ
  - ask-hub-apple: 仮決め一覧への指示による再開（未完了タスクが 0 件でも起動）、ラベルの確認のやり直し、実機確認 Issue の `ask-hub:verify` の目印
  - youtube-widget-ios: 保留にしたタスクのスロットを解放する
  - one-tone-apple（制御用 playbook）: 必須 0 件なら任意の指摘は直さずにマージ、ask の回答への対応前にマージしない、
    `前提: タスク N`、マージ前にスロットを detached にして `MERGED` を確かめる、手動ループは状態が変わるたびに status を書く
- 子 PR を squash せず merge commit でマージする
