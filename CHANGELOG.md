# 変更履歴

各アプリのリポジトリは `.claude/ralph/kit.conf` の `ref=v1` で、v1 の最新を使う（`VERSION` を上げた PR が main に入ると、`release.yml` が `v1` を動かす）。
互換を崩す変更（各リポジトリの中継・`kit.conf`・ワークフローの呼び出しの形を変える必要があるもの）は v2 にする。

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
