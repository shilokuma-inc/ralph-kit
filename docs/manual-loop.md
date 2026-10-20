# 手動ループの手順書（担当者向け）

この手順書は、**手動ループ（manual-loop）を回す担当者**が、AskHub から届いた指示をコピーして貼り、
ループを起動し、最終 PR まで持っていくための流れを書いたもの。

- 仕組み（worktree の分け方・state ファイル・playbook・オーケストレーターとの関係）は `README.md` の「手で回す（manual-loop）」を参照
- 対象リポジトリ固有の注意（検証コマンドの癖など）は、そのリポジトリの `CLAUDE.md` に書いてある
- ループの手順やスクリプトを直したいときは、アプリのリポジトリではなく **この kit（ralph-kit）に PR を出す**（全リポジトリに届く）

登場人物（どのシェルで動くか）を先に整理する:

- **Claude Code**（担当者が開いているもの）: AskHub から貼られた指示を受けて段取りする（`start` → playbook → goal → `launch`）
- **ループ本体**: `launch` がバックグラウンドで起動する。実行エージェントは既定で Claude Code、`ASKHUB_AGENT=opencode` を設定した Mac では OpenCode
- **見張り役**: `launch` が同時に起動するシェル。ループの終了を待って最終 PR を作る。Claude の利用上限で止まったときは、解除の時刻の後にループを再開する

## 0. 担当 Mac で 1 回だけやること

### Claude Code（既定）で回す人

何も設定しなくてよい。Claude Code に [ralph-loop プラグイン](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-loop) が入っていることだけ確認する:

```bash
claude plugin list | grep ralph-loop           # 無ければ
claude plugin install ralph-loop@claude-plugins-official
```

### OpenCode で回す人

次を用意する:

- OpenCode アプリ（`opencode` の実行ファイルに PATH を通す必要はない。省略時は PATH → `/Applications/OpenCode.app/Contents/Resources/opencode-cli` の順に探す）
- OpenCode で使うモデル（例: `opencode/deepseek-v4.1-flash-free`）が使える状態

シェルの設定（`~/.zshrc` など）に次を足し、**ターミナルを開き直す**:

```bash
export ASKHUB_AGENT=opencode
export ASKHUB_OPENCODE_MODEL=opencode/deepseek-v4.1-flash-free   # 使うモデル（省略時は OpenCode の既定）
```

OpenCode のときは ralph-loop プラグインは使わない（`opencode run --auto` を外側のシェルが周回させる）。

設定できたか確かめる（OpenCode 対応は kit の 1.6.0 以降）:

```bash
echo "$ASKHUB_AGENT"           # opencode と出る
scripts/ralph-kit.sh version   # v1 <SHA> が新しい版（1.6.0 以降）になっている
```

`v1` の取り直しは既定で 5 分間隔。古い版のままなら少し待つか、次のように取り直す:

```bash
RALPH_KIT_FETCH_INTERVAL=0 scripts/ralph-kit.sh version
```

## 1. 割り当てが届く

AskHub で最後の質問を「投稿したら、回答を確定してループを始める」・回し方「手動で回す」にして担当者を選び、投稿すると:

- Discussion に `manual-loop` ラベルが付き、**担当のコメント**（担当者に @メンション）が届く
- 担当者は、担当のコメントのうち**最後のもの**（担当を付け替えると新しいコメントが足される）

## 2. 貼って、段取りしてもらう

1. 対象リポジトリの checkout で Claude Code を開く
2. **AskHub のステータスタブの「手動ループ」（または担当のコメント）から指示をコピーして、そのまま貼る**:

   ```
   <owner/repo> で Discussion #N の epic を手動ループで回して（scripts/askhub-manual.sh を使う）
   ```

3. あとは Claude の指示に沿って進む。`scripts/askhub-manual.sh` が行うこと:
   - `start <N> epic/<機能名>` — 制御用 worktree（`<名前>-ralph-d<N>-ctl`）とスロットを作り、epic ブランチを origin に push、ループの状態を「開始待ち」で書く
   - playbook（制御用 worktree の `.claude/ralph-playbook.local.md`）の `{{...}}` をすべて埋める
   - playbook の STEP A に沿って、Discussion のゴール（`- [ ] タスク | label: ...`）を作る
   - 完了語（promise）を決めて、`launch <N> "<完了語>"` — ループ本体と見張り役を裏で起動する

OpenCode のときの起動は、権限モードの確認（`claude` の起動テスト）は行わず、常に `opencode run --auto`（確認なし）。
ただし `--auto` でも、kit が置く deny（`push` の禁止など）は変換して**常に優先**される。

## 3. 回っている間

- ログを見る: `~/Library/Logs/askhub/manual/` の `<リポジトリ>-d<N>-loop-<日時>.log` を `tail -f`
- 進み具合: `scripts/askhub-manual.sh status <N>`（どのフォルダで実行してもよい。番号を付ける）
- OpenCode のときは、周回は 1 つのセッションで続く（一覧に `ralph d<N>（OpenCode）`）。前の続きから作業する
- 答えてほしいこと（ask）があると、PR に書かれ、AskHub から知らせが届く。AskHub で答えるだけでよい（差し戻しは下の「4.」）
  - ループが動いている間の回答は、ループが次の周回で拾う
  - 回答待ちの PR を残してループが終わった後の回答は、見張り役が 2 分以内に拾って `resume` で再開する（ログに `[askhub-manual …] 回答待ちの PR（#…）の ask に回答が付いたので、ループを再開します`）
  - 自動で再開させたくないとき: `ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` する（答えたら指示をコピーして `resume`）
  - Mac を再起動した後など、見張り役が止まっているときは、答えたら指示をコピーして `resume`
- 止めたいとき: 制御用 worktree で `scripts/ralph-stop.sh`（state が消えてループが止まる）

## 4. 終わり・止まったとき

- 完了語を検知すると state が消えてループが終わり、**見張り役が自動で最終 PR を作る**（epic → ベースブランチ、`epic-final` ラベル）
- 回答待ちの PR が残っているうちは、最終 PR に入っていない変更がある。回答で再開したループが終わると、見張り役が最終 PR の本文を書き直すので、それからマージする
- 最終 PR の中身と CI を確認して**マージ**する
- 元の Discussion を**閉じる**と、ループの状態コメントが片付く

**Claude の利用上限で止まったときは、何もしなくてよい。** 見張り役が解除の時刻の 1 分後に `resume` で再開する（自動ループと同じ）。
待っている間、AskHub には「上限で待機中（〇時に再開）」と出て、ログには `[askhub-manual …] ループが Claude の利用上限で止まりました。解除の時刻（…）の後に、自動で再開します` が残る。

- 待たずにやめるとき: `scripts/askhub-manual.sh end <N>`（制御用 worktree で `scripts/ralph-stop.sh` を流しても、再開しない）
- 自動で再開させたくないとき: `ASKHUB_AUTO_RESUME=0` を付けて `launch` / `resume` する（ログに書くだけになる）
- 待っている間に Mac を再起動したときは、見張り役も止まる。解除の後に下の指示で `resume` する

ほかの理由で止まった（API エラーなど）・差し戻されたときは、ログや AskHub の知らせを見て直し、次の指示をコピーして貼る:

```
<owner/repo> の Discussion #N の手動ループを再開して（scripts/askhub-manual.sh resume）
```

- `resume` は前回の続きから回す（OpenCode は同じセッションの続き）。続けて失敗すると自動で止まる（既定で連続 5 回。`ASKHUB_OPENCODE_MAX_FAILS` で変更）
- 続けずにやめるとき: `scripts/askhub-manual.sh end <N>`（最終 PR は作らず、コメントを片付ける）
- ループは終わったのに最終 PR が無いとき: ログに `最終 PR を作れませんでした` があれば、checkout で `scripts/askhub-manual.sh final <N>` を手で流す

## 5. 困ったとき

| 症状 | 対処 |
| --- | --- |
| `opencode の実行ファイルが見つかりません` | PATH に通すか `ASKHUB_OPENCODE` を設定する（省略時は OpenCode.app 内を探す） |
| 設定したのに Claude Code で回る | そのターミナルで `echo "$ASKHUB_AGENT"` が `opencode` か、`scripts/ralph-kit.sh version` が 1.6.0 以降かを確認する（設定後はターミナルを開き直す） |
| `ralph-loop@claude-plugins-official が有効になっていません` と言われて始まらない | Claude Code（既定）で回す人向け。`claude plugin install ralph-loop@claude-plugins-official` で入れる。OpenCode のつもりなら `ASKHUB_AGENT` の設定を確認する |
| ループが止まっている | ログの末尾を確認し、`resume`（AskHub から指示をコピー）。Claude の利用上限で止まり「自動で再開します」とあれば、解除の時刻まで待つ |
| 回答したのに「回答待ち」のまま | 見張り役が動いているか（`askhub-manual.local.txt` の `watch_pid`）と、ログの末尾を確認する。動いていなければ `resume` |
| 古い kit のまま | `v1` の取り直しは既定 5 分間隔。`RALPH_KIT_FETCH_INTERVAL=0 scripts/ralph-kit.sh version` |
| 最終 PR が無い | 見張り役のメッセージ（ログ）を確認し、`final <N>` を手で流す |
| 同じリポジトリで並べて回したい | そのままでよい。作業場所・状態コメントは Discussion ごとに分かれる |

## 6. 参考

- `README.md`「手で回す（manual-loop）」「OpenCode で回す」— 仕組みと細かい決まり
- `CHANGELOG.md` の 1.6.0 — OpenCode 対応の内容
