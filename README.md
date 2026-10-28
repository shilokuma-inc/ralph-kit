# ralph-kit

[ralph-loop](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop) で
自律的に実装を回すための一式（playbook・スクリプト・ワークフロー）の正本。各アプリのリポジトリ（shilokuma-inc 以外の organization のものも含む）は、
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
  askhub-manual.sh              手動ループ（担当者の Mac で回す）の準備・起動・状態の書き出し・最終 PR・終了
  opencode-loop.sh              手動ループを OpenCode で回す（ASKHUB_AGENT=opencode のとき、launch が起動する）
  usage-limit.sh                ループのログから Claude の利用上限の解除の時刻を読む（手動ループの見張り役が使う）
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
- **ループは起動したときの版の kit を使い続ける。** `askhub-manual.sh launch` / `resume` は、起動するループ（claude / opencode）に
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

### ほかの organization のリポジトリで使う

kit は public なので、shilokuma-inc 以外の organization のリポジトリからも、そのまま使える（中継の取得も、
`close-goal-discussion.yml` の `uses: shilokuma-inc/ralph-kit/...@v1` も動く）。kit 自身は Actions の secrets を使わない。
入れる手順は上と同じで、加えて次をそろえる。

| どこで | すること |
| --- | --- |
| organization の Settings → Actions → General | 使える Actions を絞っているなら、`shilokuma-inc/ralph-kit/*` を許可する（Discussion を閉じるワークフローが動かない） |
| organization の Member privileges | Base permission を Read にする。Write だと、メンバー全員が書き込み権限を持つ人（信用する author）として、ループに指示できる |
| リポジトリの Settings | Discussions を有効にする（ゴール元の Discussion を使う） |
| AskHub の設定 | 「取得する organization」に足す。トークンは、すべての organization に届くもの（classic PAT の `repo` と `read:org` など）にする |
| オーケストレーターの設定 | `repositories` に `owner/repo` で足す（owner は別の organization でよい） |

- CodeRabbit は任意。入れないと最終 PR に CodeRabbit のレビューが付かないだけで、ループと AskHub のマージ条件には関係しない。
  ただし、ブランチ保護や ruleset で CodeRabbit の check を必須にしているリポジトリでは、入れないとマージできない
- アプリのワークフローが使う secrets（App Store Connect の API Key など）は、その organization にも登録する（kit とは関係ない）
- kit を直すと、v1 のタグが動いた時点で、organization に関係なく `ref=v1`（既定）で使っているすべてのリポジトリのループに届く

既にあるリポジトリを別の organization に移したときは、オーケストレーターの設定の `repository` とメインの checkout の `origin` を書き換える
（GraphQL の `repository(owner:, name:)` は移転前の名前を新しい場所に転送しない）。

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

**子 PR（epic 宛て）のマージ条件は「全 CI が pass」＋「今の head に対する第三者としてのセルフレビューで要修正の指摘なし」＋「未回答の `ask` なし」。**
CI の無いリポジトリでは「全 CI が pass」の代わりに「PR の最新コミットでローカル検証が通った記録がある」を使う。
第三者としてのセルフレビューは、実装した本人の文脈を持ち込まないよう、サブエージェントに diff と
`CLAUDE.md` の「コードレビュー観点」を渡して行う。指摘は重要度（`🔴 要修正` / `🟡 提案`）とカテゴリ（UI・ロジック・データ・並行性・テストなど）を付けて、
見出しに結論（`❌ 修正が必要` / `✅ マージ可`）を書いた表で PR にコメントする。目印には、レビューした head の SHA と件数（`must` / `may`）を入れる。
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
| 最終 PR に信用する author が指示をコメント | 止まっていたループを再開。ループが playbook の B-0b で指示を修正タスクにし、直したら `<!-- ask-hub:final-reply -->` 付きで返信する |
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

担当 PC のオーケストレーターに任せず、**担当者が自分の Mac でループを回す**のが手動ループ（ループの実行エージェントは既定で Claude Code。
OpenCode でも回せる。下の「OpenCode で回す」）。
担当者向けの実践的な進め方（AskHub から指示を貼って、起動・再開・片付けまで）は [`docs/manual-loop.md`](docs/manual-loop.md) にまとめてある。
AskHub の回答画面で、最後の質問を「投稿したら、回答を確定してループを始める」の回し方「手動で回す」にし、担当者を選んで投稿すると、
Discussion に `manual-loop` と担当のコメント（`<!-- ask-hub:manual-assignee login="…" -->`。担当者を @メンションするので通知が届く）が付く。
**信用する author（このリポジトリに書き込み権限を持つ人）の Discussion に付いたときだけ効く。** 担当者は、担当のコメントのうち最後のもの。
GitHub で手で付けるときは、**最後の質問に回答する前に** `manual-loop` を付け、担当のコメント（先頭に上の目印を置き、担当者を @メンションする）を書く。
全問回答した時点で `manual-loop` が無いと、オーケストレーターが `ready-for-loop` を付けて自動で起動することがある。
ラベルは `ralph-setup.sh` が作る（AskHub も「手動で回す」で投稿するときに無ければ作る）。セットアップ前で無いときは
`gh label create manual-loop --color C5DEF5 --description 'この Discussion のループは手で回す（オーケストレーターは起動しない）'` で作る。

**手動ループは、同じリポジトリでいくつでも並べて回せる**（同じ Mac で同じリポジトリの手動ループを複数回すのも含む。
[ask-hub-apple の Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425)）。
作業場所は Discussion ごとに分かれ（下の「作業場所」）、ループの状態もループごとのコメントに書くので、互いに上書きしない。
自動ループはリポジトリごとに 1 つ（オーケストレーターの制御用 worktree `<名前>-ralph-ctl`）で、手動ループはそこに触らない。

`manual-loop` の付いた Discussion について、オーケストレーターは次のように動く:

- 全問回答でも `ready-for-loop` を付けない（`needs-answer` だけ外す）。`ready-for-loop` が付いていても起動しない
- 手動ループが動いていても、同じリポジトリの自動ループを止めないのが Discussion #425 の決定。ただし、その対応が入る前のオーケストレーターは、
  信用する author の open な `manual-loop` の Discussion があるあいだ、同じリポジトリのほかの Discussion を自動で起動しない
- PR の ask に回答が付いても、ループを再開しない（ループは担当者の Mac にある。担当者が AskHub の知らせを見て再開する）
- 手動ループのコメント（ループの状態）を書き換えない（担当者の情報を残す）。最終 PR のコンフリクトの解消と、マージ後の仮決め一覧のクローズは今までどおり行う

担当者は、AskHub のステータスタブの「手動ループ」（または担当のコメント）から指示をコピーし、**このリポジトリの checkout で開いた Claude Code に貼る**:

```
<owner/repo> で Discussion #N の epic を手動ループで回して（scripts/askhub-manual.sh を使う）
<owner/repo> の Discussion #N の手動ループを再開して（scripts/askhub-manual.sh resume）
<owner/repo> の Discussion #N の手動ループの最終 PR を作って（scripts/askhub-manual.sh final）
```

指示を受けた Claude は、**`scripts/askhub-manual.sh` で次を行う**（ラベル・状態の書き出し・最終 PR の目印を手で行わない。抜けると AskHub に正しく出ない）。
`start` 以外も、**Discussion の番号 `<N>` を付けて呼ぶ**（同じリポジトリのほかの手動ループと取り違えないように。
番号を省くと、制御用 worktree・スロットの中ではそのループを、ほかの場所ではこの Mac の手動ループが 1 つだけならそれを使い、2 つ以上なら断る）:

1. `scripts/askhub-manual.sh start <N> epic/<機能名>`（epic 名は Discussion の内容から決める。同じリポジトリのほかのループが使っている epic 名は使えない）。
   担当者が自分か確かめ、`ralph-setup.sh` でこの Discussion の制御用 worktree とスロットを作り（epic は `ASKHUB_BASE_BRANCH`（既定は `develop`）から切る）、epic を origin に push してから `ready-for-loop` を外し、ループの状態を「開始待ち」で書く。
   信用する author（書き込み権限を持つ人）と、次に埋める値（作業場所のパスを含む）を表示する
2. 制御用 worktree の playbook の `{{...}}` を埋め（`TRUSTED_AUTHORS`・`WORKTREE_*` は start が表示した値）、STEP A に沿って goal を作る
   （Discussion の、信用する author の本文・コメント・返信だけを使う）。検証コマンドのスロットごとの場所は、同じリポジトリのほかのループのスロットと共有しない。
   `-derivedDataPath` は `~/Library/Caches/ralph-dd/<名前>-d<N>-<スロット>` にし、`.xcresult`・スクリーンショット・ログなど
   ralph-dd の下に置くものも、すべて `<名前>-d<N>-` で始める（Discussion が閉じたら見張り役が消す。下の 7。playbook の絶対禁止にも書いてある）。
   スロット専用の Simulator を作るときは、名前を `<アプリ名> d<N>-<スロットなど>`（例: `AskHub d743-a`・`PrimePick d409-ipad-b`）にし、
   UDID を playbook の「このアプリ固有の前提」に書く（Discussion が閉じたら見張り役が消す。下の 7）
3. `scripts/askhub-manual.sh launch <N> "<完了語>"`。制御用 worktree でループをバックグラウンドで起動する。
   既定は `claude -p` で、`launch` が、起動の前に実際に効く権限モードを自動で確かめる（`bypassPermissions` が使えればそれで起動し、
   MDM や組織の管理設定で禁止された Mac（エラーにならずにすべての操作が拒否されてループが進まない）では `auto` モードで起動する。
   どちらも使えなければ、理由を出して起動しない。担当者が手で確かめたり選んだりする必要はない）。
   `ASKHUB_AGENT=opencode` のときは、この確認をせずに OpenCode（`opencode run --auto`）で起動する（下の「OpenCode で回す」）。
   （指示を受けた会話そのものはループにならない。ログは `~/Library/Logs/askhub/manual/`）
   あわせて、ループの終了を待つ見張り役（シェル）を裏で起動する（下の 6）。`resume` も同じ
4. 周回中は、playbook の STEP D が制御用 worktree の中で `scripts/askhub-manual.sh status` を呼び（番号は要らない）、ループの状態を書き手 `manual`・回している人つきで書く（10 分に 1 回まで）。
   promise を出す直前に `status --stopping` を呼ぶ（回答待ちの PR を書き、AskHub が回答のそろったところで担当者に再開を促す）。
   書くのは、状態用の Issue（`loop-status`）の**このループのコメント**だけ（本文はオーケストレーターがリポジトリ全体の状態に使うので書かない。
   形式は ask-hub-apple の `docs/protocol.md` の「ループごとのコメントと本文の形」）。コメントの先頭に `<!-- ask-hub:loop-status {...} -->` の目印を置き、
   `discussion`（ゴール元の Discussion の番号）・`writer`（`manual`）・`runner`（担当者）を必ず入れる。
   自分のコメントは、信用する author のコメントのうち目印の `discussion` と `writer` が合うもので見つける（author では見分けない。担当者が替わっても同じコメントを書き換える）。
   gh のアカウントが信用する author でなければ書かない（読む側は信用する author のコメントだけを読む）。
   使う Issue はオーケストレーターと同じ選び方で決める（信用する author が作った `loop-status` の Issue のうち、open で最も新しく更新されたもの。
   無ければ閉じたもののうち最も新しく更新されたものを開き直す。1 つも無ければ、ループの状態を書かない本文で担当者のアカウントで作る）
5. ループが動いている間に付いた回答は、ループ自身が次の周回で拾う（playbook の B-1）。回答待ちの PR を残してループが promise を出して終わった後に付いた回答は、
   見張り役が拾って `scripts/askhub-manual.sh resume <N>` でループを再開する（下の 6）。見張り役が動いていなかったとき（Mac の再起動など）は、
   回答がそろったら（AskHub に「回答がそろいました」が出る）、再開の指示を受けて担当者が `resume <N>` を流す
6. ループが全タスクを終えて promise を出すと、見張り役が**制御用 worktree の外（メインの checkout）で** `scripts/askhub-manual.sh final <N>` を流し、
   ゴール元の目印つきの最終 PR（`epic-final`）を作る（自動ループでオーケストレーターが作るのと同じ。担当者の指示は要らない）。
   見張り役はメインの checkout で動くシェルで、ループの Claude ではないので、ループの deny（`gh pr create --base develop`）には当たらない。
   promise を出さずに終わったとき（API のエラーなどの異常終了・`ralph-stop.sh` での停止・無進捗での停止）は作らない。
   そのうち **Claude の利用上限で止まったとき**（ループのログの末尾が `You've hit your session limit · resets 12pm (Asia/Tokyo)` などの上限のメッセージのとき）は、
   見張り役が解除の時刻の 1 分後に `scripts/askhub-manual.sh resume <N>` でループを再開する（オーケストレーターの自動ループと同じ。解除の時刻の読み方は `bin/usage-limit.sh`）。
   待っている間は、ループの状態を「上限で待機中」（`usage-limited`・`usageLimitedUntil`）で書く。待っている間に担当者が `resume`・`end`・`ralph-stop.sh` で操作したとき、
   ゴール元の Discussion が閉じたときは再開しない。`ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` すると、ログに書くだけで再開しない。
   見張り役が動いていなかったとき（Mac の再起動など）は、解除の後に担当者が `resume <N>` を流す。
   **回答待ちの PR を残して promise を出したとき**は、最終 PR を作った後、見張り役が goal の `※回答待ち（PR #123 / ask id 456）` の ask を
   2 分おき（`ASKHUB_ANSWER_WATCH_INTERVAL`）に確かめ、信用する author の返信（`in_reply_to_id` が ask の id。playbook の B-1 と同じ判定）が付いたら
   `resume <N>` でループを再開する。オーケストレーターは手動ループの epic 宛ての PR の回答では再開しないので、見張り役が代わりに拾う。
   再開に使った ask の id は記録（`resumed_asks`）し、同じ回答ではもう再開しない。promise を出さずに終わったときは、回答が付いても再開しない。
   担当者の `launch` / `resume` と見張り役の再開は、起動ロック（`.claude/askhub-launch.local.txt`。持ち主の PID を書く）で排他し、
   ロックを取れない `launch` / `resume` は「起動している最中です」で断る（持ち主の終わったロックは捨てて取り直す）。
   `ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` すると、回答でも再開しない（担当者が `resume` を流す）。
   `resume` で再開したループがまた promise を出すと、`final` は open な最終 PR を作り直さず、本文を今の「最終 PR に載せる内容」と回答待ちの PR で書き直す
   （オーケストレーターの自動ループと同じ。マージ済みの PR は書き直さない）。
   結果はループのログに `[askhub-manual …]` の行で残る。`ASKHUB_AUTO_FINAL=0` を付けて `launch` / `resume` すると、最終 PR は作らない（見張り役は下の 7 のために動く）。
   見張り役が動かなかったとき（Mac の再起動・ログアウトなど）や `ASKHUB_AUTO_FINAL=0` のときは、AskHub の「手動ループ」の
   「最終 PR の指示をコピー」から最終 PR の指示を受けて、**制御用 worktree の外で** `scripts/askhub-manual.sh final <N>` を流す。
   goal に未完了のタスク（`※回答待ち` のものを除く）が残っていれば作らない。回答待ちの PR だけが残っているときは作り（自動ループと同じ）、その時点で open な回答待ちの PR を本文の「回答待ちの PR」に載せる。
   `※回答待ち` のタスクは、goal に書いた PR（`※回答待ち（PR #123 / ask id 456）`）が open な回答待ちの PR（`needs-answer`）でなければ作らない。
   マージは AskHub の「要対応」タブの「マージ待ち」から（マージするとゴール元の Discussion が閉じる）。
   `final` を流し忘れても、ループの状態が「完了」になってから 30 分たつと、オーケストレーターが GitHub 上の子 PR・仮決め一覧・実機確認から最終 PR を作る
   （手元の state の「最終 PR に載せる内容」は使えないので、内容は `final` で作るものより簡素になる）。
   `ASKHUB_BASE_BRANCH` を `develop` 以外にしたときは、Discussion を閉じるワークフロー（`close-goal-discussion.yml`）が動かないので、
   マージした後に担当者がゴール元の Discussion を閉じる（閉じるまで、ループの状態のコメントが残る。Discussion #425 の対応が入る前のオーケストレーターは、このリポジトリの自動ループも起動しない）
7. 見張り役は、最終 PR の後（promise を出さずに終わったときも）、ゴール元の Discussion が閉じる（最終 PR のマージでワークフローが閉じる・担当者が閉じる）のを
   10 分おき（`ASKHUB_CLOSE_WATCH_INTERVAL`）に確かめ、閉じたら**このループのコメントを消す**（AskHub は閉じた Discussion の手動ループを絞り込まないので、
   消さないと終わったループの行が残り続ける）。Discussion が open なあいだは消さない（状態が無いと、AskHub の「手動ループ」が「未開始」と出す）。
   あわせて、**このループのスロット用の Simulator を消す**（1 台 2〜4 GB あり、残すと担当者の Mac のディスクを使い切る）。
   アプリ名はリポジトリの名前から決まらないので、playbook に UDID を書いた Simulator のうち名前が `<アプリ名> d<N>-…` のものからアプリ名を求め、
   同じ `<アプリ名> d<N>-` で始まる Simulator を、Shutdown でなければ shutdown してから消す（playbook に書き忘れたそのループの Simulator も消す）。
   名前は正規表現を使わず字面の前方一致で比べ、`d<N>-` まで含める（`d74` で `d743` の Simulator を消さない）ので、ほかのアプリ（同じ番号のものも）・ほかのループ・
   手で作った Simulator は消さない。playbook にアプリ名の違う同じ番号の Simulator が書かれていて 1 つに決まらないときは、何も消さない。
   消したもの・消せなかったもの（shutdown できなかったものも。消せなかったものには shutdown と delete の手順を添える）はループのログに `[askhub-manual …]` の行で残る。`ASKHUB_DELETE_SIMULATORS=0` を付けて `launch` / `resume`（下の `start` の片付けでは `start`）すると消さない。
   同じときに、**このループのスロットの DerivedData など**（`~/Library/Caches/ralph-dd` の下。1 スロット 0.3〜7 GB）も消す。
   消すのは ralph-dd の直下の、名前が `<名前>-d<N>-` か `<名前>-d<N>.` で始まるものだけ（`d74` で `d743` のものを消さない）。
   `<名前>` は `start` が案内する名前（上の「作業場所」の `<名前>`）と、playbook に書いた `ralph-dd/<名前>-d<N>-…` の `<名前>`
   （kit 1.10 までは準備の Claude が名前を決めていた。例: dokogacha-app-ios の `dokogacha`）。名前は正規表現を使わず字面で比べるので、
   ほかのループ・ほかのアプリ（同じ番号のものも）・接頭辞の無いもの（`d<N>-…`・`task16-…` など。手で作ったものと見分けられない）は消さない。
   シンボリックリンクはリンクだけを消す。消したもの・消せなかったものはループのログに `[askhub-manual …]` の行で残る。
   `ASKHUB_DELETE_DERIVED_DATA=0` を付けて `launch` / `resume`（`start` の片付けでは `start`）すると消さない。
   `resume` で別のループを起動したら、前の見張り役はそちらに任せて終わる（ほかに見張り役が終わるのは、`end` で終えたとき・リポジトリの checkout を消したときだけ。作業場所を消しても、Discussion が閉じるまで待ち続ける）。見張り役が動いていなかったとき（Mac の再起動など）は、
   この Mac で同じリポジトリの手動ループを次に `start` したときに、Discussion の閉じたループのコメントとスロット用の Simulator・DerivedData などを消す
   （DerivedData などは消し終えるまで数分かかることがあるので、`start` を待たせないよう裏で消し、結果をそのループのログに書く）。
   **Discussion を閉じずにやめる**ときは、ループを止めてから `scripts/askhub-manual.sh end <N>` でコメントを消す
   （作業場所とスロット用の Simulator・DerivedData などは消さない（`resume` で続けると使う）。消し方を表示する）。
   終えたループは、`status` を流しても状態を書き直さず、見張り役も最終 PR を作らない（続けるなら `resume <N>`）。
   Discussion が open で `manual-loop` が付いたままだと、AskHub の「手動ループ」には「未開始」と開始の指示が出るので、やめるなら Discussion を閉じる

ask・判断ログ（`decision-log`）・実機確認（`needs-verify`）の書き方は自動のときと同じ（AskHub の受信箱でそのまま扱える）。

#### OpenCode で回す

担当 Mac のシェル（`~/.zshrc` など）で次を設定すると、`launch` / `resume` が `claude -p` の代わりに
`bin/opencode-loop.sh`（OpenCode の CLI を周回させる）でループを起動する。既定は今までどおり Claude Code で、自動ループ（オーケストレーター）は変わらない:

```bash
export ASKHUB_AGENT=opencode
export ASKHUB_OPENCODE_MODEL=opencode/deepseek-v4.1-flash-free   # 使うモデル（省略時は OpenCode の既定）
# export ASKHUB_OPENCODE=/Applications/OpenCode.app/Contents/Resources/opencode-cli  # 実行ファイル（省略時: PATH → OpenCode.app）
```

AskHub からコピーして Claude Code に貼る指示は、今までどおりそのまま使える（貼る先の Claude Code は段取りだけを行い、ループ本体が OpenCode で回る）。

- 権限モードの確認（`claude` の起動）は行わず、常に `opencode run --auto` で起動する。`--auto` でも明示された deny は常に優先される
- 制御用 worktree の `.claude/settings.json` の deny（`Bash(…)`・`Read(…)`・`Edit(…)` など。`ralph-setup.sh` が置く）は、
  起動のたびに `.opencode/opencode.json` に変換して置く（リポジトリにはコミットしない）
- playbook の Claude Code 向けの記述（Stop hook・Agent ツールなど）は、起動時に OpenCode 向けの読み替えをプロンプトへ足して渡す
- 周回は 1 つの OpenCode セッションで続く（OpenCode の一覧に `ralph d<N>（OpenCode）` で出る）。モデルは前の周の続きから作業する
- state・ログ・PID・見張り役（`watch-final`）・`status`・`resume`・`final`・`end`・`ralph-stop.sh` は Claude のときと同じように動く
- 連続失敗で止まる（既定 5 回。`ASKHUB_OPENCODE_MAX_FAILS` で変更）。再試行の待ち時間は `ASKHUB_OPENCODE_FAIL_SLEEP`（既定 15 秒 × 失敗回数）

#### 作業場所

手動ループの作業場所は Discussion ごとに分かれる（`<名前>` はメインの checkout のディレクトリ名から `-ios` を除いたもの）:

| 作業場所 | パス |
| --- | --- |
| 制御用 worktree | `<名前>-ralph-d<N>-ctl`（記録 `.claude/askhub-manual.local.txt`・playbook・goal・state・PID） |
| スロット | `<名前>-ralph-d<N>-a`・`<名前>-ralph-d<N>-b` |
| ログ | `~/Library/Logs/askhub/manual/<名前>-d<N>-loop-<日時>.log` |
| DerivedData など | `~/Library/Caches/ralph-dd/<名前>-d<N>-…`（準備の Claude とループが作る。Discussion が閉じたら見張り役が消す） |

オーケストレーターの自動ループは `<名前>-ralph-ctl`・`-a`・`-b`（`ralph-setup.sh` の既定）を使い、手動ループはそこに触らない。
同じ epic は 1 つの worktree でしか checkout できないので、ほかのループ（自動・手動）が使っている epic 名では `start` できない。
終わった Discussion の作業場所は自動では消さない（goal・state の記録が残るため）。要らなくなったら `end` が表示するコマンドで消す。
スロット用の Simulator（`<アプリ名> d<N>-…`）と DerivedData など（`~/Library/Caches/ralph-dd/<名前>-d<N>-…`）は、ゴール元の Discussion が閉じたら見張り役が消す（上の 7）。

kit 1.3 までに `<名前>-ralph-ctl` で始めた手動ループは、**移さずにその場所のまま最後まで回す**（動いているループ・記録を壊さないため）。
`resume` / `final` / `status` は、その Discussion の新しい作業場所が無く、`<名前>-ralph-ctl` の記録がその Discussion のもので、記録の epic を今も checkout していれば、そこを使う。
状態の書き出しは、この版で起動し直した（`resume`）ときからループのコメントに変わる（それまでは、起動したときの版の kit が本文に書く）。
本文に残った前の形のこのループの状態（書き手 `manual` で、このループの Discussion のもの）は、この版がこのループのコメントを書くとき（書いた Issue の本文）と消すとき（すべての状態用の Issue の本文）に、
手動ループが Issue を作るときの本文（ループの状態を書かない）に置き換えて片付ける（残すと、コメントを消した後に AskHub が本文から終わったループの行を出し、
手動ループの Discussion が open なあいだはオーケストレーターも本文を書き直さない）。オーケストレーター・ほかのループが書いた本文には触らない。
同じ Mac でオーケストレーターと前の形の手動ループが `<名前>-ralph-ctl` を取り合う制約は、そのループが終わるまで残る。新しく `start` する Discussion は新しい作業場所を使う。

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
