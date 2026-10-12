# ralph-kit

[ralph-loop](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop) で
自律的に実装を回すための一式（playbook・スクリプト・ワークフロー）の正本。shilokuma-inc の各アプリのリポジトリは、
このリポジトリをコピーせずに、中継スクリプトで呼んで使う。設計の根拠と、実際に踏んだ落とし穴は
[template-app-ios の Discussion #87](https://github.com/shilokuma-inc/template-app-ios/discussions/87) を参照。

## 構成

```
playbook.md                     手順の雛形。制御用 worktree にコピーされ、毎イテレーション読み直される
templates/
  goal.md                       タスクと確定済みの決定事項
  state.md                      in-flight / 回答待ち / 保留 の記録
  settings.deny.json            権限の deny リスト（制御用 worktree の settings.json へ）
  CLAUDE.snippet.md             各リポジトリの CLAUDE.md に貼るポインタ（新しいセッションの入口）
bin/
  ralph-setup.sh                worktree と統合ブランチを用意する
  ralph-start.sh                state ファイルを生成する（＝ループ開始）
  ralph-stop.sh                 停止と後片付け
  askhub-manual.sh              手動ループ（担当者の Mac で回す）の準備・起動・状態の書き出し・最終 PR
shim/                           各リポジトリに置くファイルの原本（install.sh が配る）
install.sh                      リポジトリに中継を入れる・ずれを確かめる
.github/workflows/
  close-goal-discussion.yml     最終 PR のマージでゴール元の Discussion を閉じる（各リポジトリから uses で呼ぶ）
```

各アプリのリポジトリに置くのは、kit を呼ぶ中継と、使う版だけ:

| リポジトリのファイル | 役割 |
| --- | --- |
| `scripts/ralph-setup.sh`・`ralph-start.sh`・`ralph-stop.sh`・`askhub-manual.sh` | kit の同名のスクリプトを呼ぶ中継。使い方は kit と同じ |
| `scripts/ralph-kit.sh` | kit を取得して実行する。`path`・`version` で場所と版を表示する |
| `.claude/ralph/kit.conf` | 使う kit の版（`ref=v1`） |
| `.claude/ralph/README.md` | この README への案内 |
| `.github/workflows/close-goal-discussion.yml` | kit のワークフローの呼び出し |

ループが実際に読むのは、制御用 worktree に置かれた次の3ファイル。

| ファイル | 役割 |
| --- | --- |
| `ralph-playbook.local.md` | 手順。**直せば次の周回から反映される**（ループの張り直し不要） |
| `ralph-goal.local.md` | タスクのチェックリストと決定事項 |
| `ralph-state.local.md` | in-flight の PR と、人間への申し送り |

いずれも `.git/info/exclude` で除外される（`ralph-setup.sh` が追記する）。

## 版と更新

各リポジトリの中継は、`.claude/ralph/kit.conf` の `ref`（既定は `v1`）が指す kit を `~/.cache/ralph-kit/<コミット>/` に取得して実行する。

- **互換を保つ修正は、kit に PR を 1 本出すだけで全リポジトリに届く。** `VERSION` を上げた PR が main に入ると、
  ワークフロー（`release.yml`）が `vX.Y.Z` のタグを打ち、`v1` をそのコミットに動かす。各リポジトリへの PR は要らない
- タグ・ブランチは 5 分おきに取り直す（`RALPH_KIT_FETCH_INTERVAL`）。取得できないとき・ほかのプロセスの取得が 2 分を超えて終わらないときは、手元にある版で動く
- **中継（`scripts/ralph-kit.sh`）の処理も kit の版に従う。** 取得した kit の `shim/scripts/ralph-kit.sh` が各リポジトリのものと違えば、処理をそちらに任せる。
  各リポジトリのコピーが使われるのは、kit の取得と、任せるかどうかの判定だけになる
- **ループは起動したときの版の kit を使い続ける。** `askhub-manual.sh launch` / `resume` は、起動する claude に
  `RALPH_KIT_DIR`（取得した kit の場所）を渡すので、周回中に呼ぶ `scripts/askhub-manual.sh status` も同じ版を使う。新しい版は次の起動から効く
- 互換を崩す変更（中継・`kit.conf`・ワークフローの呼び出しの形を変えるもの）は `v2` にし、各リポジトリの `kit.conf` を書き換える
- **制御用 worktree の playbook は、起動のたび（`ralph-start.sh`。launch・resume・オーケストレーターの起動）に kit の更新を取り込む。**
  epic を始めたときにコピーした kit の playbook（`.claude/ralph-playbook.base.local.md`）を共通の祖先にして 3-way merge するので、
  埋めた値・「このアプリ固有の前提」・この epic で書き足した手順は残る。kit の変更が playbook の書き換えた行と重なったとき、
  新しいプレースホルダが入るときは取り込まずに、今の playbook のまま起動する（手で取り込んだら、祖先を kit の playbook で置き換える）
- 祖先の記録が無い playbook（1.1 より前に始めた epic）は書き換えない。`ralph-setup.sh` を再実行すると、**既存の playbook に無い kit の節を見出し単位で報告する**ので、必要なものを手で取り込む

### 各リポジトリに入れる・ずれを確かめる

```bash
git clone https://github.com/shilokuma-inc/ralph-kit.git
ralph-kit/install.sh ~/path/to/myapp-ios          # 中継を置き、kit に移った雛形を消す（コミットはしない）
ralph-kit/install.sh --check ~/path/to/myapp-ios  # ずれがあれば表示して終了コード 1
```

`CLAUDE.md` の「## ralph-loop による自律開発」の節は、`<!-- ralph-kit:snippet begin -->` と `end` の間だけを kit の内容にそろえる。
このリポジトリだけの注意（検証コマンドの癖など）は end の後に書く。

### kit を直すとき

1. **アプリのリポジトリで中継や雛形を直さない。** 直すのは kit だけ（直してもアプリのリポジトリには届かない・次の install で消える）
2. 手元の kit で試すときは、アプリのリポジトリで `RALPH_KIT_DIR=<kit の checkout> scripts/ralph-setup.sh …` のように、kit の場所を指定する
3. macOS の `/bin/bash`（3.2）で `tests/run.sh` を流してから PR を出す。互換を保つ修正なら `VERSION` のパッチかマイナーを上げ、`CHANGELOG.md` に書く

## まず CLAUDE.md にポインタを置く

新しい Claude Code セッションはこの仕組みの存在を知らない。**`CLAUDE.md` は毎セッション
自動で読み込まれる唯一の入口**なので、`templates/CLAUDE.snippet.md` の内容を各リポジトリの `CLAUDE.md` に
追記しておく。これが無いと、文脈を持たないセッションは state ファイルを手書きしたり、
統合ブランチを挟まずに develop へ直接マージしたりする。

## 使い方

以下は `myapp-ios` で `epic/monetization` を回す場合の例。
**ブランチ名とパスは自分のものに読み替えること**（そのまま貼っても動くよう、
山かっこのプレースホルダは使っていない）。

```bash
# 1. worktree と統合ブランチを用意（epic/[機能名] をテーマ単位で指定する）
scripts/ralph-setup.sh epic/monetization

# 2. 制御用 worktree の playbook と goal を埋める
#    playbook の二重波かっこをすべて置換し、「このアプリ固有の前提」を書く

# 3. 統合ブランチを push
cd ../myapp-ralph-ctl && git push -u origin epic/monetization

# 4. ループ開始（state ファイルを生成）
../myapp-ios/scripts/ralph-start.sh "MONETIZATION DONE"

# 5. 起動（ralph-start.sh が出力するコマンドをそのまま使う）
```

停止は `scripts/ralph-stop.sh`。worktree ごと消すなら、**Claude のセッションが終了してから**
`scripts/ralph-stop.sh --worktrees` を実行する（実行中のループを止めたのと同じ呼び出しでは、
作業中のスロットを壊さないよう削除しない）。

## 設計上の要点

**統合ブランチを挟む。** `develop` へ直接マージさせると push のたびに Upload 系
ワークフローが発火し、1タスクごとにビルドが App Store Connect へ積まれる。
**`epic/[機能名]`**（テーマ単位）に集約し、人間が最後に1本の PR でレビューして取り込む。
`epic/**` はフィーチャーブランチと同じく Build / Archive が走るので、CI の検証力は保たれる。
CI の無いリポジトリでは、playbook のローカル検証（`{{VERIFY_COMMANDS}}`）を通したことを state に記録し、それを CI の代わりにする。
1ループ = 1 epic。epic を分ければ、ループ自体を複数走らせて並列化できる。

**`gh pr checks --watch` を使わない。** 最大10分ブロックしてループが止まる。
各イテレーションの冒頭で非ブロッキングに確認し、pending なら次のタスクへ進む。
worktree 2枠で PR を常時2本 in-flight に保てる。

**Issue は明示的に閉じる。** `resolve #N` の自動クローズは
デフォルトブランチへのマージでしか発火しない。統合ブランチ運用では効かない。

**指示は author で絞る。** public リポジトリでは Discussion / Issue / PR に
誰でもコメントできる。「本文だけ読む」にすると決定（コメント欄に書かれる）を
取りこぼすので、**author で判定する**。信用する author は playbook に
`{{TRUSTED_AUTHORS}}` としてリストで書き、共同開発者が増えたら追記する。
リポジトリの collaborator から自動で導出しない — 招待した瞬間に自律ループへの
指示権限が付く形になるため、増やす操作は明示的な判断であるべき。
信用外 author のコメントは**黙殺せず** state に記録し、人間が判断できるようにする。

**スラッシュコマンドを経由しない。** プラグインのコマンドは名前空間付きで
解決が不安定なうえ、`/hooks` に Stop hook が表示されないため状態を誤認しやすい。
`ralph-start.sh` が state ファイルを直接書く方式なら、これらに依存しない。
`session_id` を空にすると hook 側のセッション照合がスキップされる。

**Stop hook は作業ディレクトリでループを判定する。** hook は、その時点の作業ディレクトリにある
`.claude/ralph-loop.local.md` を探す。また `session_id` が空なので、どのセッションのものかは区別しない。そのため次の 2 つに注意する。
- ループの Claude がスロットに `cd` したままターンを終えると、ループが無いと判断され、**エラーも出さずに止まる**。
  playbook では、スロットでの操作を `git -C` とサブシェルに限り、ターンの終わりに作業ディレクトリを確認させている
- **制御用 worktree の中で、別の Claude Code セッションを開かない（`cd` もしない）。** そのセッションも
  ループ本体として Stop hook に捕まり、ループの指示を受け取ってしまう

**子 PR（epic 宛て）のマージ条件は「全 CI が pass」＋「今の head に対する第三者としてのセルフレビューで必須の指摘なし」＋「未回答の `ask` なし」。**
CI の無いリポジトリでは「全 CI が pass」の代わりに「PR の最新コミットでローカル検証が通った記録がある」を使う。
第三者としてのセルフレビューは、実装した本人の文脈を持ち込まないよう、サブエージェントに diff と
`CLAUDE.md` の「コードレビュー観点」を渡して行う。結果は、レビューした head の SHA を目印に入れて PR にコメントする。
push で head が変わったら再レビューする。

**CodeRabbit は epic → develop の最終 PR でだけ使う。** CodeRabbit のレート制限（OSS は 1 時間に 3 回）は
PR の作者単位で、同じアカウントで回る全リポジトリのループが 1 つの枠を取り合う。子 PR ごとにレビューを待つと、
CI が通ってもマージされない時間が 1 時間を超えることがあった。そのため `.coderabbit.yaml` で epic 宛ての PR を
自動レビューの対象から外している。子 PR に CodeRabbit の指摘が付いた場合（人間が頼んだときなど）は、
コードレビューとして対応し、各コメントに返信する。
自分が `ask` を残した PR は**マージせず保留**し、回答が付くまで待つ。
ただし保留中の PR がスロットを占有すると前に進めなくなるため、
**スロットは解放して state の「回答待ち」へ移す**。

**マージを止める `ask` は「epic にマージした時点で手遅れになるもの」に絞る。**
epic → develop の最終 PR で人間のレビューは必ず入るので、子 PR ごとに止めると
同じ確認を2回することになる。ninjacord-ios では ask の大半が「既定値で進めても後から直せる判断」か
「実機での確認依頼」で、1件ずつ回答するまで後続が止まり、人間がボトルネックになっていた。
セルフレビューのコメントは次の3種類に分ける。

| 種類 | 条件 | マージ | 行き先 |
| --- | --- | --- | --- |
| `ask` | 後から戻せない / App Store Connect などリポジトリ外の作業が必須 / 決定事項と矛盾 / 後続タスクの前提が変わる | 止める | PR コメントで回答を待つ |
| `decision` | 既定値で進めても後から安く直せる判断 | 止めない | epic ごとの判断ログ Issue に集約 |
| 実機確認 | 実機・実データでしか確かめられない | 止めない | 個別の Issue に起票し、PR には memo で起票した旨を書く |

判断ログ Issue は、人間が都合のよいときにまとめて見る。チェックを付ければ承認、
コメントで別案を指示すればループが修正タスクとして積んで epic 内で直す。
**返答のない decision は既定値のまま確定**し、promise を出す前に state の
「最終 PR に載せる内容」へ一覧で書き出される。承認・変更された判断はゴールファイルの
決定事項に書き戻されるので、次の epic へ持ち越せば同じ種類の判断で止まらない。

**deny リストは制御用 worktree の `.claude/settings.json` に置き、リポジトリにはコミットしない。**
`settings.local.json` は個人の上書き用で gitignore される前提のファイルであり、
Claude Code が権限承認を自動追記するため、deny がそこに同居すると失われうる。
一方でリポジトリにコミットすると、`gh pr create --base <base>` の deny が
通常開発の PR 作成まで塞ぐ。制御用 worktree に置けば、ループにだけ効く。

**`max_iterations: 0`（無制限）で回すなら、詰まりを扱えること。**
promise は完全一致でしか成立せず「詰まった」を表現できないため、
着手不能なタスクがあると無限ループになる。playbook の「詰まったときの扱い」で
タスクを**保留として閉じられる**ようにし、無進捗が続いたら自分で停止させる。
`ralph-start.sh` はこの節が playbook に無いと 0 での起動を拒否する。

## AskHub・オーケストレーターとの連携

[AskHub](https://github.com/shilokuma-inc/ask-hub-apple) は、人間の判断が要るものだけを集めて iPhone / Mac から回答する受信箱アプリ。
家の Mac に常駐するオーケストレーター（`askhub-orchestrator`）が回答を見て、このループを自動で起動・再開し、最終 PR を作る。
手で `ralph-start.sh` を叩く運用から、次の流れに置き換わる。

| きっかけ | 自動で起きること |
| --- | --- |
| Discussion の質問に回答して「確定」（`ready-for-loop`） | 起動スクリプト（`askhub-start-loop`）が goal を作り、`ralph-setup.sh` → `ralph-start.sh` → ループを起動 |
| PR の ask に回答（`needs-answer`） | 止まっていたループを再開 |
| 全タスク完了 | オーケストレーターが epic → develop の最終 PR（`epic-final`）を作る |
| 最終 PR を develop にマージ | ワークフロー（`close-goal-discussion.yml`）が、ゴール元の Discussion を解決済みで閉じる |

**ループの側で守ること**（形式の正本は ask-hub-apple の `docs/protocol.md`）:

- ask のコメントは質問の目印（`<!-- ask-hub:question id="…" options="…" -->`）で始め、PR に `needs-answer` を付ける。
  目印が無い ask は AskHub に届かず、回答してもループが再開しない
- 判断ログ Issue には `decision-log`、実機確認 Issue には `needs-verify` を付ける（AskHub の「任意判断」「実機確認」に出る）
- 実機確認 Issue の本文の**先頭**に `ask-hub:verify` の目印を置く（AskHub が元の PR 番号を一覧に出す。「実機確認の扱い」の例を参照）
- 最終 PR はループで作らない。通常の自動ループではオーケストレーターが「最終 PR に載せる内容」を読んで作り、
  手動ループ（manual-loop）ではループが promise を出して終わったとき、`launch` / `resume` が起動した見張り役が `scripts/askhub-manual.sh final` で作る
- 不足しているプロトコルのラベルは `ralph-setup.sh` が作る

セットアップ（Mac ごとの手順・設定ファイル）は ask-hub-apple の `docs/orchestrator.md` を参照。

### 手で回す（manual-loop）

担当 PC のオーケストレーターに任せず、**担当者が自分の Mac と Claude アカウントでループを回す**のが手動ループ。
AskHub の回答画面で、最後の質問を「投稿したら、回答を確定してループを始める」の回し方「手動で回す」にし、担当者を選んで投稿すると、
Discussion に `manual-loop` と担当のコメント（`<!-- ask-hub:manual-assignee login="…" -->`。担当者を @メンションするので通知が届く）が付く。
**信用する author（このリポジトリに書き込み権限を持つ人）の Discussion に付いたときだけ効く。** 担当者は、担当のコメントのうち最後のもの。
GitHub で手で付けるときは、**最後の質問に回答する前に** `manual-loop` を付け、担当のコメント（先頭に上の目印を置き、担当者を @メンションする）を書く。
全問回答した時点で `manual-loop` が無いと、オーケストレーターが `ready-for-loop` を付けて自動で起動することがある。
ラベルは `ralph-setup.sh` が作る（AskHub も「手動で回す」で投稿するときに無ければ作る）。セットアップ前で無いときは
`gh label create manual-loop --color C5DEF5 --description 'この Discussion のループは手で回す（オーケストレーターは起動しない）'` で作る。

`manual-loop` の付いた Discussion について、オーケストレーターは次のように動く:

- 全問回答でも `ready-for-loop` を付けない（`needs-answer` だけ外す）。`ready-for-loop` が付いていても起動しない
- Discussion が open なあいだ（最終 PR のマージで閉じられるまで）、**同じリポジトリのほかの Discussion も自動で起動しない**（1 リポジトリにつきループは 1 つ）
- PR の ask に回答が付いても、ループを再開しない（ループは担当者の Mac にある。担当者が AskHub の知らせを見て再開する）
- 手動ループが書いた loop-status を上書きしない（担当者の情報を残す）。最終 PR のコンフリクトの解消と、マージ後の仮決め一覧のクローズは今までどおり行う

担当者は、AskHub のステータスタブの「手動ループ」（または担当のコメント）から指示をコピーし、**このリポジトリの checkout で開いた Claude Code に貼る**:

```
<owner/repo> で Discussion #N の epic を手動ループで回して（scripts/askhub-manual.sh を使う）
<owner/repo> の Discussion #N の手動ループを再開して（scripts/askhub-manual.sh resume）
<owner/repo> の Discussion #N の手動ループの最終 PR を作って（scripts/askhub-manual.sh final）
```

指示を受けた Claude は、**`scripts/askhub-manual.sh` で次を行う**（ラベル・状態の書き出し・最終 PR の目印を手で行わない。抜けると AskHub に正しく出ない）:

1. `scripts/askhub-manual.sh start <N> epic/<機能名>`（epic 名は Discussion の内容から決める）。
   担当者が自分か確かめ、`ralph-setup.sh` で制御用 worktree とスロットを作り（epic は `ASKHUB_BASE_BRANCH`（既定は `develop`）から切る）、epic を origin に push してから `ready-for-loop` を外し、loop-status を「開始待ち」で書く。
   信用する author（書き込み権限を持つ人）と、次に埋める値を表示する
2. 制御用 worktree の playbook の `{{...}}` を埋め（`TRUSTED_AUTHORS` は start が表示した値）、STEP A に沿って goal を作る
   （Discussion の、信用する author の本文・コメント・返信だけを使う）
3. `scripts/askhub-manual.sh launch "<完了語>"`。制御用 worktree で `claude -p` のループをバックグラウンドで起動する
   （`launch` が、起動の前に実際に効く権限モードを自動で確かめる。`bypassPermissions` が使えればそれで起動し、
   MDM や組織の管理設定で禁止された Mac（エラーにならずにすべての操作が拒否されてループが進まない）では `auto` モードで起動する。
   どちらも使えなければ、理由を出して起動しない。担当者が手で確かめたり選んだりする必要はない）
   （指示を受けた会話そのものはループにならない。ログは `~/Library/Logs/askhub/manual/`）
   あわせて、ループの終了を待つ見張り役（シェル）を裏で起動する（下の 6）。`resume` も同じ
4. 周回中は、playbook の STEP D が `scripts/askhub-manual.sh status` を呼び、loop-status を書き手 `manual`・回している人つきで書く（10 分に 1 回まで）。
   promise を出す直前に `status --stopping` を呼ぶ（回答待ちの PR を書き、AskHub が回答のそろったところで担当者に再開を促す）
   書き込む Issue はオーケストレーターと同じ選び方で決める（信用する author が作った `loop-status` の Issue のうち、open で最も新しく更新されたもの。
   無ければ閉じたもののうち最も新しく更新されたものを開き直す。1 つも無ければ担当者のアカウントで作る）
5. 回答がそろったら（AskHub に「回答がそろいました」が出る）、再開の指示を受けて `scripts/askhub-manual.sh resume`
6. ループが全タスクを終えて promise を出すと、見張り役が**制御用 worktree の外（メインの checkout）で** `scripts/askhub-manual.sh final` を流し、
   ゴール元の目印つきの最終 PR（`epic-final`）を作る（自動ループでオーケストレーターが作るのと同じ。担当者の指示は要らない）。
   見張り役はメインの checkout で動くシェルで、ループの Claude ではないので、ループの deny（`gh pr create --base develop`）には当たらない。
   promise を出さずに終わったとき（API のエラーなどの異常終了・`ralph-stop.sh` での停止・無進捗での停止）は作らない。
   結果はループのログに `[askhub-manual …]` の行で残る。`ASKHUB_AUTO_FINAL=0` を付けて `launch` / `resume` すると、見張り役を起動しない。
   見張り役が動かなかったとき（Mac の再起動・ログアウトなど）や `ASKHUB_AUTO_FINAL=0` のときは、AskHub の「手動ループ」の
   「最終 PR の指示をコピー」から最終 PR の指示を受けて、**制御用 worktree の外で** `scripts/askhub-manual.sh final` を流す。
   goal に未完了のタスク（`※回答待ち` のものを除く）が残っていれば作らない。回答待ちの PR だけが残っているときは作り（自動ループと同じ）、その時点で open な回答待ちの PR を本文の「回答待ちの PR」に載せる。
   `※回答待ち` のタスクは、goal に書いた PR（`※回答待ち（PR #123 / ask id 456）`）が open な回答待ちの PR（`needs-answer`）でなければ作らない。
   マージは AskHub の「要対応」タブの「マージ待ち」から（マージするとゴール元の Discussion が閉じる）。
   `final` を流し忘れても、loop-status が「完了」になってから 30 分たつと、オーケストレーターが GitHub 上の子 PR・仮決め一覧・実機確認から最終 PR を作る
   （手元の state の「最終 PR に載せる内容」は使えないので、内容は `final` で作るものより簡素になる）。
   `ASKHUB_BASE_BRANCH` を `develop` 以外にしたときは、Discussion を閉じるワークフロー（`close-goal-discussion.yml`）が動かないので、
   マージした後に担当者がゴール元の Discussion を閉じる（閉じるまで、このリポジトリの自動ループは止まったまま）

ask・判断ログ（`decision-log`）・実機確認（`needs-verify`）の書き方は自動のときと同じ（AskHub の受信箱でそのまま扱える）。

## ループに向かないタスク

判定基準は**自動検証器があるか**。lint とビルドで正しさを担保できないものは向かない。

| 種類 | 理由 |
| --- | --- |
| 新規ターゲット追加（App Extension / Widget / App Intents） | `.xcodeproj` と Provisioning Profile、CI の書き換えに波及する |
| StoreKit の実機・Sandbox 検証 | `.storekit` は Xcode から起動したときだけ適用される。`simctl` では効かない |
| 多言語の訳文品質 | 生成した訳を検証できない |
| 外部コンソール作業（App Store Connect / 広告管理画面） | リポジトリ外 |
| UI の見た目・文言の妥当性 | ビルドが通ることと正しく見えることは別 |

ゴールファイルの「対象外」に明示して着手させないこと。

## 実績

`ninjacord-ios` で Phase 0〜2 を実装。**33 本の PR を生成し v2.0.0 として develop にマージ済み。**
1タスクあたりのイテレーション数は、立ち上がりで約2.5、パイプラインが埋まった定常状態で
**約1.2**（ほぼ毎周1タスク進む）。2枠のスロットで、モデルが CI 待ちで遊ぶ時間をほぼ埋められていた。
