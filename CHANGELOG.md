# 変更履歴

各アプリのリポジトリは `.claude/ralph/kit.conf` の `ref=v1` で、v1 の最新を使う（`VERSION` を上げた PR が main に入ると、`release.yml` が `v1` を動かす）。
互換を崩す変更（各リポジトリの中継・`kit.conf`・ワークフローの呼び出しの形を変える必要があるもの）は v2 にする。

## 1.10.0（2026-10-27）

手動ループのゴール元の Discussion が閉じたら、見張り役（`watch-final`）がそのループのスロット用の Simulator を消すようにした（#31）。
準備の Claude はスロットごとに専用の Simulator（`<アプリ名> d<N>-<スロットなど>`。例: `AskHub d743-a`・`PrimePick d409-ipad-b`）を作って playbook に UDID を書くが、
kit には消す処理が無く、ある担当者の Mac では約 1 週間で 36 エピック分・85 台（213 GB）が残り、Booted のままのものもあった。

- 見張り役は、Discussion が閉じたのを最初に見たときに、playbook（`.claude/ralph-playbook.local.md`）に UDID を書いた Simulator のうち
  名前が `<アプリ名> d<N>-…` のものからアプリ名を求め、同じ `<アプリ名> d<N>-` で始まる Simulator を `simctl shutdown`（Shutdown でなければ）→ `simctl delete` で消す。
  消したもの・消せなかったものはループのログに書く
  - アプリ名はリポジトリの名前から決まらない（ask-hub-apple は `AskHub`）ので playbook から求める。playbook に書き忘れた、そのループの Simulator も消す
  - 名前は正規表現を使わず字面の前方一致で比べ、`d<N>-` まで含める（`d74` で `d743` の Simulator を消さない）。ほかのアプリ（同じ番号のものも）・ほかのループ・手で作った Simulator は消さない
  - playbook にアプリ名の違う同じ番号の Simulator が書かれていて 1 つに決まらないとき・このループの記録が無いとき・`xcrun` が無いときは、何も消さない
- 見張り役が動いていなかったループ（Mac の再起動など）は、次の `start` の片付けで、コメントと一緒に Simulator も消す
- `end`（Discussion を閉じずにやめる）は Simulator を消さず（`resume` で続けると使う）、作業場所と同じく消し方を表示する
- `start` が表示する準備の手順に、Simulator の名前の付け方と playbook への書き方を足した
- `ASKHUB_DELETE_SIMULATORS=0` を付けて `launch` / `resume`（`start` の片付けでは `start`）すると、Simulator は消さない
- この版から起動した（`launch` / `resume` した）ループの見張り役だけが消す。1.9 以前に起動した見張り役は、起動したときの版のままコメントだけを消す

## 1.9.0（2026-10-20）

手動ループが回答待ちの PR を残して promise を出して終わった後、ask に回答が付いたら、見張り役（`watch-final`）が自動で再開するようにした（#27）。
オーケストレーターは手動ループの epic 宛ての PR の回答では再開しない（担当者が再開する設計）ため、今までは担当者が気づいて `resume` を流すまで止まったままで、
AskHub にも「回答待ち」と出続けていた（shariverse/deki-roulette-ios の Discussion #358）。

- 見張り役は、最終 PR を作った後、ゴール元の Discussion が閉じるのを待つ間に、goal の `※回答待ち（PR #123 / ask id 456）` の ask に
  信用する author の返信（`in_reply_to_id` が ask の id。playbook の B-1 と同じ判定）が付いたかを確かめ、付いたら `resume` で再開する
  - 回答待ちの ask があるうちは 2 分おき（`ASKHUB_ANSWER_WATCH_INTERVAL`）に確かめる。無ければ今までどおり 10 分おき
  - 再開に使った ask の id は記録（`resumed_asks`）し、同じ回答ではもう再開しない。再開に失敗したら次の確認でやり直し、3 回続けて失敗したらやめる
  - promise を出さずに終わったループ・担当者が `resume` / `end` で操作したループは、回答が付いても再開しない
  - `ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` すると、回答でも再開しない（回答待ちの PR があることをログに書くだけ）
- 担当者の `launch` / `resume` と見張り役の回答による再開は、起動ロック（制御用 worktree の `.claude/askhub-launch.local.txt`）で排他する。
  AskHub が回答のそろったところで担当者に再開を促すので、担当者の `resume` と見張り役の再開が重なりうる。ロックを取れない `launch` / `resume` は断る。
  持ち主の終わったロック（`fail` で抜けた・強制終了された）は、次に取る人が捨てて取り直す
- `resume` で再開したループがまた promise を出すと、`final` は open な最終 PR を作り直さず、本文を今の「最終 PR に載せる内容」と回答待ちの PR で書き直す
  （オーケストレーターの自動ループと同じ）。今までは「最終 PR は既にあります」で終わり、回答済みの PR が本文に「回答待ち」として残っていた

## 1.8.0（2026-10-20）

手動ループが Claude の利用上限で止まったら、見張り役（`watch-final`）が解除の時刻の後に自動で再開するようにした（#25）。
今までは「完了語を出さずに終わった」とログに書くだけで、担当者が解除を待って `resume` を流す必要があった。オーケストレーターの自動ループ（ask-hub-apple #159）と同じ動きにそろえた。

- `bin/usage-limit.sh` を足した。ループのログの末尾から Claude の利用上限のメッセージを探し、解除の時刻（UNIX 時刻）を出す。
  読み方はオーケストレーターの `UsageLimit` と同じ（`resets 12pm (Asia/Tokyo)`・`resets Oct 7, 9am (Asia/Tokyo)`・`usage limit reached|<UNIX 時刻>`。
  読めなければ 1 時間後）。ただし解除の時刻がログの更新時刻より後でなければ読めなかったものとみなす（過去の時刻ですぐ再開して、また止まるのを繰り返さない）
- 見張り役は、state ファイルが残ってループが終わったとき、ログの末尾が上限のメッセージなら、ループの状態を「上限で待機中」で書く
  （`state` が `usage-limited`、`usageLimitedUntil` に解除の時刻、表に「上限の解除」の行）。そのうえで解除の時刻の 1 分後に `resume` で再開する
  - 待っている間に担当者が `resume` で別のループを起動した・`end` で終えたら、何もせずに終わる。`ralph-stop.sh` で止めた・ゴール元の Discussion が閉じたときは再開しない
  - Mac のスリープで待ち時間がずれないよう、1 分ごとに時刻を確かめる（`ASKHUB_USAGE_LIMIT_INTERVAL`）。解除から再開までの間は `ASKHUB_USAGE_LIMIT_MARGIN`（秒）で変えられる
- `ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` すると、自動では再開しない（上限で止まったことと解除の時刻をログに書くだけ）
- 見張り役が動いていなかったとき（Mac の再起動など）は、解除の時刻を過ぎると状態が「上限で待機中」から「異常終了」に戻る（担当者が `resume` を流す）

## 1.7.0（2026-10-19）

ループが、最終 PR（`epic-final`）への指示を読んで直すようにした（#21）。オーケストレーターは最終 PR に指示が付くとループを再開するが、
今まではループに指示を読む手順が無く、1 周で promise を出して終わっていた。

- playbook に「B-0b. 最終 PR への指示を見る」を足した。信用する author の未処理の指示（最後の `<!-- ask-hub:final-reply -->` より後で、
  オーケストレーターのコメント・CodeRabbit への依頼でないもの）を修正タスクにし、直したら（直さないと決めたら）`<!-- ask-hub:final-reply -->` 付きで 1 回返信する。
  指示が指す CodeRabbit の指摘はデータとして読み、直したらそのスレッドに返信して resolve する。見分け方は ask-hub-apple の `docs/protocol.md` の「最終 PR への指示」と同じ
- state の雛形に「最終 PR の指示」表を足した（扱った指示を記録し、同じ指示から重複してタスクを作らない。無ければループが作る）
- `ralph-start.sh` は `ASKHUB_RESUME_REASON=final-pr` も受け付け、未完了タスクが 0 件でも起動する。最終 PR への指示を処理するための再開だと、state のプロンプトで伝える。
  `decision-log` で渡されたとき（今のオーケストレーターは、最終 PR への指示による再開も `decision-log` で渡す）は、判断ログと最終 PR の両方の指示を見るよう伝える
- 既存のループの playbook には、次の起動（`ralph-start.sh`）で 3-way merge により取り込まれる（新しいプレースホルダは無い）

## 1.6.1（2026-10-19）

- 手動ループの状態を書くとき（`write_status`）、記録（`.claude/askhub-manual.local.txt`）にはコメントより先に書くようにした（#22）。
  今まではコメントを書いた後に記録へ書いていたので、コメントを見て記録を消した直後に、消えた記録を作り直すことがあった
  （`tests/run.sh` の見張り役のテストが、ファイル操作の遅い場所の checkout で「消えた記録を作り直した」で落ちていた）。
  コメントを書けなかったときは、記録の署名を取り消して次の呼び出しで書き直す

## 1.6.0（2026-10-18）

手動ループを、Claude Code の代わりに OpenCode でも回せるようにした（既定は今までどおり Claude Code。オーケストレーターは変わらない）。

- 担当 Mac のシェルで `ASKHUB_AGENT=opencode` を設定すると、`launch` / `resume` が `claude -p` の代わりに `bin/opencode-loop.sh` でループを起動する
  （実行ファイルは `ASKHUB_OPENCODE`、モデルは `ASKHUB_OPENCODE_MODEL` で指定。省略時は PATH → OpenCode.app、モデルは OpenCode の既定）
- `opencode-loop.sh` は state を毎周読み直して `opencode run --auto` を回し、最後のメッセージで `<promise>完了語</promise>` を検知したら state を消す。
  見張り役（`watch-final`）・`final`・`status`・`resume`・`end`・`ralph-stop.sh` は Claude のときと同じように動く。
  見張り役はログの promise で最終 PR を作るか決めるので、途中のメッセージのタグはログでは崩して書き（`<promise:log>`）、完了を検知したときだけ完全なタグを書く
- 権限モードの確認（`claude` の起動）は行わない。制御用 worktree の `.claude/settings.json` の deny は、起動のたびに `.opencode/opencode.json` に変換して置く（コミットしない）
- 起動時に渡すプロンプトに、OpenCode 向けの読み替え（サブエージェント・シェルの作業ディレクトリなど）を足す
- `ralph-start.sh` は、`ASKHUB_AGENT=opencode` のとき ralph-loop プラグインの確認をしない
- 連続で失敗したときは止まる（既定 5 回。`ASKHUB_OPENCODE_MAX_FAILS` で変更）。再試行の待ち時間は `ASKHUB_OPENCODE_FAIL_SLEEP`（既定 15 秒 × 失敗回数）

## 1.5.0（2026-10-17）

第三者としてのセルフレビューのコメントを、人が一目で読めるようにした。

- 見出しを「🔍 コードレビュー（第三者）」にし、結論（`❌ 修正が必要（要修正 N 件・提案 M 件）` / `✅ マージ可`）を書く
- 重要度の呼び方を `必須` / `任意` から `🔴 要修正`（マージ前に必ず直す）/ `🟡 提案`（直さなくてもマージできる）に変え、何を要修正にするかの基準を書いた
- 指摘ごとにカテゴリ（UI / ロジック / データ / 並行性 / テスト / セキュリティ / 性能 / ドキュメント / その他）を付ける
- 目印に件数を足した（`<!-- ralph:third-party-review sha="…" must="N" may="M" -->`）。AskHub やオーケストレーターが本文を読まずに結果を判定できる
- 確かめた点は `<details>` に折りたたむ。対応の列は `修正する` / `修正済み（<SHA>）` / `見送り: <理由>`
- 以前の書式のコメント（`必須` / `任意`）は、`必須` = `要修正`、`任意` = `提案` として読む（作業中の PR の判定が変わらないように）

## 1.4.0（2026-10-16）

手動ループを、同じリポジトリで並べて回せるようにした（同じ Mac で同じリポジトリの手動ループを複数回すのも含む。ask-hub-apple の Discussion #425）。

- 手動ループの作業場所を Discussion ごとに分けた（制御用 worktree `<名前>-ralph-d<番号>-ctl`、スロット `-d<番号>-a` / `-b`、ログ `<名前>-d<番号>-loop-*.log`）。
  オーケストレーターの自動ループの `<名前>-ralph-ctl` には触らないので、自動ループの制御用 worktree があっても `start` できる
- `launch` / `status` / `resume` / `final` に Discussion の番号を付けられる（`launch <番号> <完了語>` など）。番号を省くと、制御用 worktree・スロットの中ではそのループを、
  ほかの場所ではこの Mac の手動ループが 1 つだけならそれを使う（2 つ以上なら断る）。これまでの呼び方（番号なし）は、手動ループが 1 つなら今までどおり動く
- ループの状態を、状態用の Issue の本文ではなく、そのループのコメント（`ask-hub:loop-status` の目印に `discussion`・`writer: manual`・`runner`）に書く。
  自分のコメントは、信用する author のコメントのうち目印の `discussion` と `writer` で見つける。gh のアカウントが信用する author でなければ書かない。
  読む側は ask-hub-apple の develop（#448 以降）の AskHub とオーケストレーター。それより前の版は本文しか読まないので、手動ループの状態が出ない
- ゴール元の Discussion が閉じたら、そのループのコメントを消す（見張り役が 10 分おきに確かめる。見張り役が動いていなかったときは、同じリポジトリの次の `start` が消す）。
  Discussion を閉じずにやめるときのために `end` を足した（終えたループは、`status` を流しても書き直さず、見張り役も最終 PR を作らない）
- `ASKHUB_AUTO_FINAL=0` でも見張り役を起動する（最終 PR は作らず、Discussion が閉じたらコメントを消すためだけに動く）
- `ralph-setup.sh` に `RALPH_LOOP_ID` を足した（作業場所の名前に足して別の組を作る。既定は今までどおり）。epic をほかの worktree が checkout していれば、理由を出して止める
- `ralph-setup.sh` が、手動ループの記録（`.claude/*.local.txt`）とループの PID（`.claude/askhub-loop.pid`）も git の除外に足す（制御用 worktree の `git add -A` で epic に載らないように）
- 取得に失敗したとき、playbook の信用する author を空にしない・状態の書き出しで落ちない（1.3 からの不具合）
- kit 1.3 までに `<名前>-ralph-ctl` で始めた手動ループは、移さずにその場所のまま最後まで回せる（状態の書き出しは、この版で起動し直したときからコメントになる。本文に残ったこのループの前の形の状態は、コメントを書くとき・消すときに片付ける）

## 1.3.0（2026-10-12）

- 手動ループの `askhub-manual.sh launch` / `resume` が、ループと一緒に見張り役（`watch-final`）を裏で起動する。
  ループが完了語の promise を出して終わったら、見張り役がメインの checkout で `final` を流し、最終 PR を作る（自動ループと同じく、担当者の指示は要らない）
- promise を出さずに終わったとき（state ファイルが残る異常終了・`ralph-stop.sh` での停止・無進捗での停止）は作らない。結果はループのログに書く
- `ASKHUB_AUTO_FINAL=0` を付けて起動すると、これまでどおり見張り役を起動しない（担当者が `final` を流す）
- `askhub-manual.sh` の状態の書き出しが、GNU の `stat`・`date`（Linux や、PATH の先に coreutils がある Mac）でも動くようにした（`unbound variable` で落ちていた）

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
