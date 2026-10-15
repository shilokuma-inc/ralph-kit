#!/bin/bash
# kit のスモークテスト。一時ディレクトリに架空のアプリのリポジトリ（origin つき）を作り、
# install.sh → 中継（scripts/ralph-kit.sh）経由の ralph-setup → ralph-start → ralph-stop を通しで流す。
#   usage: tests/run.sh
# 中継は kit をコミットから取得するので、テストするのは HEAD のコミット（作業ツリーの未コミットの変更は含まない）。
# gh は偽物に差し替え、GitHub には触らない。macOS の /bin/bash（3.2）でも流すこと。
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd -P)
# macOS の一時ディレクトリはシンボリックリンク（/var → /private/var）なので、実体のパスにしておく（中継が返すパスと比べるため）
WORK=$(cd "$(mktemp -d)" && pwd -P)
# 自動ループの代わりに動かすプロセス（後半のテスト）も止める
trap 'kill "${AUTO_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PASSED=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; PASSED=$((PASSED + 1)); }

# ---- 環境: 偽の gh・HOME・kit の取得元 ---------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/home/.claude"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
# テスト用の gh。GitHub の代わりに、状態用の Issue・そのコメント・閉じた Discussion を GH_STATE のファイルで持つ。
# 応答は JSON で作り、--jq があれば jq で絞る（本物の gh と同じく、文字列はそのまま出す）。書き込み権限を持つのは test だけ。
# Discussion はどの番号も manual-loop 付きで test が担当。GH_STATE/closed-<番号> があれば閉じている。
# GH_LOG があれば、呼ばれた引数をそこに書き足す
[[ -z "${GH_LOG:-}" ]] || printf '%s\n' "$*" >> "$GH_LOG"
S="${GH_STATE:?}"
mkdir -p "$S/issues" "$S/comments"

jq_expr="" method="" body="" query="" number="" author=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jq_expr="$2"; shift ;;
    -X) method="$2"; shift ;;
    --body) body="$2"; shift ;;
    --author) author="$2"; shift ;;
    -f | -F)
      case "$2" in
        body=*) body="${2#body=}" ;;
        query=*) query="${2#query=}" ;;
        n=*) number="${2#n=}" ;;
      esac
      shift ;;
    -R | --label | --state | --limit | --json | --title | --color | --description | --base | --head | --assignee) shift ;;
    -*) ;;
    *) positional+=("$1") ;;
  esac
  shift
done
out() { if [[ -n "$jq_expr" ]]; then jq -r "$jq_expr"; else cat; fi; }
next_id() {
  until mkdir "$S/lock" 2>/dev/null; do sleep 0.05; done
  local id=$(( $(cat "$S/counter" 2>/dev/null || echo 100) + 1 ))
  echo "$id" > "$S/counter"
  rmdir "$S/lock"
  echo "$id"
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
comments_of() {
  local d
  for d in "$S/comments"/*; do
    [[ -f "$d/issue" && "$(cat "$d/issue")" == "$1" ]] || continue
    jq -n --argjson id "${d##*/}" --arg login "$(cat "$d/login")" --arg updated "$(cat "$d/updated")" --rawfile body "$d/body" \
      '{id: $id, user: {login: $login}, updated_at: $updated, body: $body}'
  done | jq -s .
}
endpoint="${positional[1]:-}"
case "${positional[0]:-} ${positional[1]:-}" in
  "repo view") echo '{"nameWithOwner":"example/myapp-ios"}' | out ;;
  "api user") echo '{"login":"test"}' | out ;;
  "api graphql")
    closed=false
    [[ -e "$S/closed-$number" ]] && closed=true
    case "$query" in
      *'labels(first:20)'*)
        jq -n --arg n "$number" --argjson closed "$closed" '{data: {repository: {discussion: {id: "D_\($n)", closed: $closed, author: {login: "test"},
          labels: {nodes: [{name: "manual-loop"}]},
          comments: {nodes: [{author: {login: "test"}, body: "<!-- ask-hub:manual-assignee login=\"test\" -->\n@test さんが担当します"}]}}}}}' | out ;;
      *'{ closed }'*) jq -n --argjson closed "$closed" '{data: {repository: {discussion: {closed: $closed}}}}' | out ;;
      *) echo '{"data":{"repository":{"label":null}}}' | out ;;
    esac ;;
  "api repos/example/myapp-ios/collaborators"*) echo '[{"login":"test","permissions":{"push":true}}]' | out ;;
  "api repos/example/myapp-ios/issues/"*)
    rest="${endpoint#repos/example/myapp-ios/issues/}"
    case "${method:-GET} $rest" in
      "GET "*/comments*) comments_of "${rest%%/*}" | out ;;
      "POST "*/comments)
        id=$(next_id)
        mkdir -p "$S/comments/$id"
        printf '%s' "${rest%%/*}" > "$S/comments/$id/issue"
        printf '%s' test > "$S/comments/$id/login"
        printf '%s' "$body" > "$S/comments/$id/body"
        now > "$S/comments/$id/updated"
        echo "{\"id\":$id}" | out ;;
      "PATCH comments/"*)
        [[ -d "$S/comments/${rest#comments/}" ]] || { echo "Not Found" >&2; exit 1; }
        printf '%s' "$body" > "$S/comments/${rest#comments/}/body"
        now > "$S/comments/${rest#comments/}/updated" ;;
      "DELETE comments/"*)
        [[ -d "$S/comments/${rest#comments/}" ]] || { echo "Not Found" >&2; exit 1; }
        rm -r "${S:?}/comments/${rest#comments/}" ;;
    esac ;;
  "issue list")
    for d in "$S/issues"/*; do
      [[ -f "$d/author" ]] || continue
      [[ -z "$author" || "$(cat "$d/author")" == "$author" ]] || continue
      jq -n --argjson number "${d##*/}" --arg state "$(cat "$d/state")" --arg updated "$(cat "$d/updated")" '{number: $number, state: $state, updatedAt: $updated}'
    done | jq -s . | out ;;
  "issue create")
    id=$(next_id)
    mkdir -p "$S/issues/$id"
    printf '%s' test > "$S/issues/$id/author"
    printf '%s' OPEN > "$S/issues/$id/state"
    printf '%s' "$body" > "$S/issues/$id/body"
    now > "$S/issues/$id/updated"
    echo "https://github.com/example/myapp-ios/issues/$id" ;;
  "issue reopen") printf '%s' OPEN > "$S/issues/${positional[2]}/state" ;;
  "issue edit") printf '%s' "$body" > "$S/issues/${positional[2]}/body" ;;
  "pr list") echo '[]' | out ;;
  "pr create") echo "https://github.com/example/myapp-ios/pull/99" ;;
  *) exit 0 ;;
esac
GH
# テスト用の claude。権限モードの確認（stream-json）には init の行を返す。
# ループとしては、STUB_LOOP=promise なら全タスクを終えて最終 PR に載せる内容を書き、Stop hook と同じく state ファイルを消して promise を出す。
# それ以外は state ファイルを残したまま終わる（API のエラーなどの異常終了）
cat > "$WORK/bin/claude" <<'CLAUDE'
#!/bin/bash
case "$*" in
  *stream-json*) echo '{"type":"system","subtype":"init","permissionMode":"bypassPermissions"}'; exit 0 ;;
esac
sleep 2
if [[ "${STUB_LOOP:-}" == promise ]]; then
  perl -pi -e 's/^- \[ \]/- [x]/' .claude/ralph-goal.local.md
  perl -0pi -e 's/(## 最終 PR に載せる内容\n[^\n]*\n)/$1- テストでしたこと\n/' .claude/ralph-state.local.md
  rm -f .claude/ralph-loop.local.md
  echo '<promise>SMOKE DONE</promise>'
else
  echo 'API Error: Connection refused'
  exit 1
fi
CLAUDE
chmod +x "$WORK/bin/gh" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"
export GH_STATE="$WORK/github"
echo '{"enabledPlugins":{"ralph-loop@claude-plugins-official":true}}' > "$HOME/.claude/settings.json"
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch develop

# CI の checkout は detached HEAD なので、clone ではなく HEAD を push して取得元を作る
git init --quiet --bare "$WORK/kit.git"
git -C "$KIT" push --quiet "$WORK/kit.git" HEAD:refs/heads/main
HEAD_SHA=$(git -C "$KIT" rev-parse HEAD)
git --git-dir="$WORK/kit.git" tag -f v1 "$HEAD_SHA" >/dev/null
export RALPH_KIT_URL="file://$WORK/kit.git"
export RALPH_KIT_CACHE="$WORK/cache"
unset RALPH_KIT_DIR RALPH_KIT_REF RALPH_KIT_SHA

# ---- 架空のアプリのリポジトリ -------------------------------------------------------------
git init --quiet --bare "$WORK/origin.git"
APP="$WORK/repos/myapp-ios"
git clone --quiet "$WORK/origin.git" "$APP" 2>/dev/null
mkdir -p "$APP/.claude/ralph" "$APP/scripts"
# 移行前の状態（テンプレートの雛形と、目印の無い古い CLAUDE.md の節）
echo old > "$APP/.claude/ralph/playbook.template.md"
echo old > "$APP/.claude/ralph/CLAUDE.snippet.md"
cat > "$APP/CLAUDE.md" <<'MD'
# myapp

## ralph-loop による自律開発

古い本文

このリポジトリだけの注意

## 次の節
MD
git -C "$APP" add -A
git -C "$APP" commit --quiet -m init
git -C "$APP" push --quiet origin HEAD:develop

# ---- install.sh -----------------------------------------------------------------------------
OUT=$("$KIT/install.sh" "$APP")
for f in scripts/ralph-kit.sh scripts/ralph-setup.sh scripts/ralph-start.sh scripts/ralph-stop.sh scripts/askhub-manual.sh; do
  [[ -x "$APP/$f" ]] || fail "install.sh が $f を実行できる形で置いていない"
done
[[ -f "$APP/.claude/ralph/kit.conf" && -f "$APP/.github/workflows/close-goal-discussion.yml" ]] || fail "install.sh が kit.conf かワークフローを置いていない"
[[ ! -e "$APP/.claude/ralph/playbook.template.md" && ! -e "$APP/.claude/ralph/CLAUDE.snippet.md" ]] || fail "install.sh が古い雛形を消していない"
grep -q '目印がありません' <<<"$OUT" || fail "目印の無い CLAUDE.md の節を知らせていない"
grep -q '古い本文' "$APP/CLAUDE.md" || fail "目印の無い CLAUDE.md の節を書き換えた"
ok "install.sh が中継を置き、古い雛形を消し、目印の無い CLAUDE.md は書き換えない"

# 目印を付けたら、目印の間だけを kit の内容に書き換える（end の後の注意は残す）
cat > "$APP/CLAUDE.md" <<'MD'
# myapp

## ralph-loop による自律開発

<!-- ralph-kit:snippet begin -->
古い本文
<!-- ralph-kit:snippet end -->

このリポジトリだけの注意

## 次の節
MD
"$KIT/install.sh" "$APP" >/dev/null
grep -q '古い本文' "$APP/CLAUDE.md" && fail "目印の間を書き換えていない"
grep -q 'shilokuma-inc/ralph-kit' "$APP/CLAUDE.md" || fail "目印の間に kit の内容が入っていない"
grep -q 'このリポジトリだけの注意' "$APP/CLAUDE.md" || fail "end の後の注意を消した"
grep -qx '## 次の節' "$APP/CLAUDE.md" || fail "次の節を消した"
"$KIT/install.sh" --check "$APP" >/dev/null || fail "install.sh の直後に --check がずれを報告した"
ok "CLAUDE.md の目印の間だけを書き換え、--check がそろっていると判定する"

echo changed >> "$APP/scripts/ralph-stop.sh"
if "$KIT/install.sh" --check "$APP" >/dev/null; then fail "--check が中継の書き換えを見逃した"; fi
"$KIT/install.sh" "$APP" >/dev/null
ok "--check が中継のずれを報告し、install.sh で元に戻る"

# 処理を kit に任せられる scripts/ralph-kit.sh は、古くてもずれとしない（任せられない古い中継はずれとする）
echo '# 古い版' >> "$APP/scripts/ralph-kit.sh"
OUT=$("$KIT/install.sh" --check "$APP") || fail "任せられる中継を、ずれと判定した"
grep -q '更新は要りません' <<<"$OUT" || fail "任せられる中継が古いことを知らせていない"
perl -pi -e 's/RALPH_KIT_DELEGATED/RALPH_KIT_OLD/g' "$APP/scripts/ralph-kit.sh"
if "$KIT/install.sh" --check "$APP" >/dev/null; then fail "任せられない古い中継を、ずれと判定しなかった"; fi
"$KIT/install.sh" "$APP" >/dev/null
ok "--check は、処理を kit に任せられる古い中継をずれとしない"

git -C "$APP" add -A
git -C "$APP" commit --quiet -m "kit を入れる"
git -C "$APP" push --quiet origin HEAD:develop

# ---- 中継（kit の取得）---------------------------------------------------------------------
VERSION=$("$APP/scripts/ralph-kit.sh" version)
[[ "$VERSION" == "v1 $HEAD_SHA" ]] || fail "version が v1 の指すコミットを返していない: $VERSION"
KITDIR=$("$APP/scripts/ralph-kit.sh" path)
[[ "$KITDIR" == "$RALPH_KIT_CACHE/$HEAD_SHA" && -f "$KITDIR/.ralph-kit-complete" && -x "$KITDIR/bin/ralph-setup.sh" ]] \
  || fail "kit を版ごとの場所に展開していない: $KITDIR"
ok "中継が kit.conf の v1 を取得し、コミットごとの場所に展開する"

# v1 のタグが動いたら、取り直す間隔の後に新しい版を使う（古い版の場所は残す）
git -C "$WORK" clone --quiet "$WORK/kit.git" kit-work 2>/dev/null
git -C "$WORK/kit-work" commit --quiet --allow-empty -m "次の版"
NEXT_SHA=$(git -C "$WORK/kit-work" rev-parse HEAD)
git -C "$WORK/kit-work" push --quiet origin HEAD:refs/heads/next
git --git-dir="$WORK/kit.git" tag -f v1 "$NEXT_SHA" >/dev/null
[[ "$("$APP/scripts/ralph-kit.sh" version)" == "v1 $HEAD_SHA" ]] || fail "取り直す間隔の前に v1 を取り直した"
[[ "$(RALPH_KIT_FETCH_INTERVAL=0 "$APP/scripts/ralph-kit.sh" version)" == "v1 $NEXT_SHA" ]] || fail "v1 の移動を取り込んでいない"
[[ -f "$KITDIR/.ralph-kit-complete" ]] || fail "古い版の kit を消した"
git --git-dir="$WORK/kit.git" tag -f v1 "$HEAD_SHA" >/dev/null
RALPH_KIT_FETCH_INTERVAL=0 "$APP/scripts/ralph-kit.sh" version >/dev/null
ok "v1 のタグの移動を、取り直す間隔をあけて取り込む"

# 取得の途中で止められて残ったロック（10 分より前のもの）は外して進む
mkdir "$RALPH_KIT_CACHE/.lock"
touch -t 202001010000 "$RALPH_KIT_CACHE/.lock"
[[ "$("$APP/scripts/ralph-kit.sh" version)" == "v1 $HEAD_SHA" ]] || fail "古いロックが残ったままだと取得できない"
[[ ! -d "$RALPH_KIT_CACHE/.lock" ]] || fail "取得の後にロックが残っている"
ok "取得の途中で残った古いロックを外し、取得の後はロックを残さない"

# ほかのプロセスがロックを持ったまま終わらないときは、待ちきれたら取得せずに手元の版を使う（そのロックは外さない）
mkdir "$RALPH_KIT_CACHE/.lock"
OUT=$(RALPH_KIT_LOCK_TIMEOUT=1 RALPH_KIT_FETCH_INTERVAL=0 "$APP/scripts/ralph-kit.sh" version 2>"$WORK/lock.err") || fail "ロックが空かないと失敗した"
[[ "$OUT" == "v1 $HEAD_SHA" ]] || fail "ロックが空かないときに手元の版を使っていない: $OUT"
grep -q '順番待ち' "$WORK/lock.err" || fail "順番待ちで手元の版を使ったことを知らせていない"
[[ -d "$RALPH_KIT_CACHE/.lock" ]] || fail "ほかのプロセスのロックを外した"
rmdir "$RALPH_KIT_CACHE/.lock"
ok "ロックが空かないときは、取得せずに手元の版を使う"

# 取得に失敗しても時刻を残し、間隔の内は取得し直さない（オフラインのとき、周回ごとに待たせない）
mv "$WORK/kit.git" "$WORK/kit.git.away"
ERR=$(RALPH_KIT_FETCH_INTERVAL=0 "$APP/scripts/ralph-kit.sh" version 2>&1 >/dev/null) || fail "取得できないと失敗した"
grep -q '取得できませんでした' <<<"$ERR" || fail "取得の失敗を知らせていない"
ERR=$("$APP/scripts/ralph-kit.sh" version 2>&1 >/dev/null) || fail "取得の失敗の後に失敗した"
[[ -z "$ERR" ]] || fail "取得に失敗した直後に、また取得を試した: $ERR"
mv "$WORK/kit.git.away" "$WORK/kit.git"
ok "取得に失敗しても手元の版で動き、間隔の内は取得し直さない"

# 取得した kit の中継がリポジトリのものと違えば、そちらに任せる（リポジトリの中継が古くても、kit の中継で動く）
perl -pi -e 's/echo "\$REF \$SHA"/echo "OLD \$REF \$SHA"/' "$APP/scripts/ralph-kit.sh"
[[ "$("$APP/scripts/ralph-kit.sh" version)" == "v1 $HEAD_SHA" ]] || fail "kit の中継に任せていない"
[[ "$(RALPH_KIT_DELEGATED=1 "$APP/scripts/ralph-kit.sh" version)" == "OLD v1 $HEAD_SHA" ]] || fail "任せた印があるのに、また任せた"
[[ "$(cd "$WORK" && "$APP/scripts/ralph-kit.sh" path)" == "$KITDIR" ]] || fail "任せた先で、リポジトリの kit.conf を読んでいない"
"$KIT/install.sh" "$APP" >/dev/null
ok "取得した kit の中継がリポジトリのものと違えば、そちらに任せる"

[[ "$(RALPH_KIT_REF=next "$APP/scripts/ralph-kit.sh" version)" == "next $NEXT_SHA" ]] || fail "RALPH_KIT_REF でブランチを指定できない"
[[ "$(cd "$WORK" && RALPH_KIT_CACHE=cache "$APP/scripts/ralph-kit.sh" path)" == "$(cd "$WORK" && pwd -P)/cache/$HEAD_SHA" ]] \
  || fail "相対パスの RALPH_KIT_CACHE を絶対パスにしていない"
[[ "$(RALPH_KIT_DIR="$KIT" "$APP/scripts/ralph-kit.sh" path)" == "$KIT" ]] || fail "RALPH_KIT_DIR を使っていない"
if RALPH_KIT_REF=--upload-pack=x "$APP/scripts/ralph-kit.sh" version >/dev/null 2>&1; then fail "- で始まる版を受け付けた"; fi
if RALPH_KIT_REF=no-such-ref "$APP/scripts/ralph-kit.sh" version >/dev/null 2>&1; then fail "無い版で成功した"; fi
ok "RALPH_KIT_REF・RALPH_KIT_DIR を使い、不正な版や無い版は断る"

# ---- ralph-setup → ralph-start → ralph-stop -----------------------------------------------
(cd "$APP" && scripts/ralph-setup.sh epic/smoke >/dev/null 2>"$WORK/setup.err") || { cat "$WORK/setup.err" >&2; fail "ralph-setup.sh が失敗した"; }
CTL="$WORK/repos/myapp-ralph-ctl"
for d in "$CTL" "$WORK/repos/myapp-ralph-a" "$WORK/repos/myapp-ralph-b"; do
  [[ -d "$d" ]] || fail "worktree を作っていない: $d"
done
cmp -s "$KITDIR/playbook.md" "$CTL/.claude/ralph-playbook.local.md" || fail "playbook を kit からコピーしていない"
cmp -s "$KITDIR/templates/goal.md" "$CTL/.claude/ralph-goal.local.md" || fail "goal を kit からコピーしていない"
cmp -s "$KITDIR/templates/settings.deny.json" "$CTL/.claude/settings.json" || fail "deny を kit からコピーしていない"
grep -q 'CLAUDE.md に ralph-loop の記載がありません' "$WORK/setup.err" && fail "CLAUDE.md の節があるのに警告した"
ok "ralph-setup.sh が worktree を作り、kit の雛形を制御用 worktree に置く"

# playbook を埋め、タスクを 1 つ書いて起動する
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$CTL/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
(cd "$CTL" && ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null) || fail "ralph-start.sh が失敗した"
grep -qx 'completion_promise: "SMOKE DONE"' "$CTL/.claude/ralph-loop.local.md" || fail "state に完了語を書いていない"
if (cd "$CTL" && ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null 2>&1); then fail "実行中なのに二重に起動した"; fi
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
[[ ! -e "$CTL/.claude/ralph-loop.local.md" ]] || fail "ralph-stop.sh が state を消していない"
ok "ralph-start.sh が state を作り、ralph-stop.sh が消す"

# kit の playbook の更新は、起動のたびに 3-way merge で取り込む（埋めた値は残す）
cmp -s "$KITDIR/playbook.md" "$CTL/.claude/ralph-playbook.base.local.md" || fail "ralph-setup.sh が祖先の playbook を記録していない"
make_kit() { # $1=作る場所 $2=playbook を書き換える perl の式
  rm -rf "$1"
  cp -R "$KITDIR" "$1"
  perl -0pi -e "$2" "$1/playbook.md"
}
ANCHOR='promise は完全一致でしか成立しないため'
make_kit "$WORK/kit-add" "s/(${ANCHOR}[^\n]*\n)/\$1kit で足した行\n/"
(cd "$CTL" && RALPH_KIT_DIR="$WORK/kit-add" ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null 2>"$WORK/start.err") || { cat "$WORK/start.err" >&2; fail "kit の更新があると起動しない"; }
grep -qx 'kit で足した行' "$CTL/.claude/ralph-playbook.local.md" || fail "kit の更新を取り込んでいない"
grep -q '{{' "$CTL/.claude/ralph-playbook.local.md" && fail "取り込みで埋めた値が雛形に戻った"
cmp -s "$WORK/kit-add/playbook.md" "$CTL/.claude/ralph-playbook.base.local.md" || fail "取り込んだ後に祖先を更新していない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "起動のたびに kit の playbook の更新を取り込み、埋めた値は残す"

# 埋めた行を kit も書き換えたとき（衝突）と、新しいプレースホルダが入るときは、取り込まずに起動する
cp "$CTL/.claude/ralph-playbook.local.md" "$WORK/before.md"
make_kit "$WORK/kit-conflict" "s/(${ANCHOR}[^\n]*\n)/\$1kit で足した行\n/; s/- 作業スロット: /- 作業用のスロット: /"
(cd "$CTL" && RALPH_KIT_DIR="$WORK/kit-conflict" ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null 2>"$WORK/start.err") || { cat "$WORK/start.err" >&2; fail "衝突したときに起動しない"; }
cmp -s "$WORK/before.md" "$CTL/.claude/ralph-playbook.local.md" || fail "衝突したのに playbook を書き換えた"
grep -q '書き換えと重なったため' "$WORK/start.err" || fail "衝突を知らせていない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
make_kit "$WORK/kit-placeholder" "s/(${ANCHOR}[^\n]*\n)/\$1kit で足した行\n新しい値: {{NEW_VALUE}}\n/"
(cd "$CTL" && RALPH_KIT_DIR="$WORK/kit-placeholder" ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null 2>"$WORK/start.err") || { cat "$WORK/start.err" >&2; fail "新しいプレースホルダがあるときに起動しない"; }
cmp -s "$WORK/before.md" "$CTL/.claude/ralph-playbook.local.md" || fail "新しいプレースホルダを取り込んだ"
grep -q '新しいプレースホルダがある' "$WORK/start.err" || fail "新しいプレースホルダを知らせていない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "衝突したとき・新しいプレースホルダが入るときは取り込まずに起動する"

# 仮決め一覧への指示による再開は、未完了タスクが 0 件でも起動する
printf '# ゴール\n\n- [x] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
if (cd "$CTL" && ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null 2>&1); then fail "未完了タスクが 0 件なのに起動した"; fi
(cd "$CTL" && ASKHUB_RESUME_REASON=decision-log ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null) || fail "decision-log の再開で起動しない"
grep -q '判断ログ Issue（仮決め一覧）への指示を処理するために再開した' "$CTL/.claude/ralph-loop.local.md" || fail "再開の理由を state に書いていない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "decision-log の再開では、未完了タスクが 0 件でも起動する"

# 2 回目の setup（再開）は既存のファイルを上書きせず、スロットを作り直す
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh --worktrees >/dev/null) || fail "ralph-stop.sh --worktrees が失敗した"
[[ ! -d "$WORK/repos/myapp-ralph-a" ]] || fail "スロットを消していない"
(cd "$APP" && scripts/ralph-setup.sh epic/smoke >/dev/null 2>&1) || fail "2 回目の ralph-setup.sh が失敗した"
[[ -d "$WORK/repos/myapp-ralph-a" ]] || fail "スロットを作り直していない"
grep -q '{{' "$CTL/.claude/ralph-playbook.local.md" && fail "埋めた playbook を雛形で上書きした"
ok "2 回目の ralph-setup.sh は埋めた playbook を残し、スロットを作り直す"

# ---- askhub-manual.sh の見張り役（kit 1.3 までの固定パスで始めた手動ループ）---------------------------
# kit 1.3 までは、手動ループも制御用 worktree（myapp-ralph-ctl）を使っていた。途中のループは、その場所のまま最後まで回せる（番号を省いても見つける）。
# launch はループと一緒に見張り役を起動し、ループが promise を出して終わったら final で最終 PR を作る。
# そのあと、ゴール元の Discussion が閉じたら、ループの状態のコメントを消す
printf 'repository=example/myapp-ios\ndiscussion=1\nepic=epic/smoke\nbase_branch=develop\nrunner=test\n' > "$CTL/.claude/askhub-manual.local.txt"
manual() {
  (cd "$APP" && ASKHUB_LOG_DIR="$WORK/logs" ASKHUB_FINAL_WATCH_INTERVAL=1 ASKHUB_CLOSE_WATCH_INTERVAL=1 GH_LOG="$WORK/gh.log" \
    scripts/askhub-manual.sh "$@")
}
loop_log() { sed -n 's/^log=//p' "${1:-$CTL}/.claude/askhub-manual.local.txt" | tail -n 1; }
wait_for() { # 条件が成り立つまで待つ（最大 30 秒）
  local n=0
  until "$@"; do
    [[ $n -lt 60 ]] || return 1
    n=$((n + 1))
    sleep 0.5
  done
}
wait_watch() { # 見張り役が結果をログに書くまで待つ
  wait_for grep -Eq '最終 PR を作りました|最終 PR は作りません|最終 PR を作れませんでした' "$1" \
    || fail "見張り役が結果をログに書かない: $(cat "$1" 2>/dev/null)"
}
watch_exited() {
  local pid
  pid=$(sed -n 's/^watch_pid=//p' "$1/.claude/askhub-manual.local.txt" | tail -n 1)
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "見張り役の PID を記録していない"
  ! kill -0 "$pid" 2>/dev/null
}
wait_watch_exit() { # 見張り役が終わるまで待つ（$1=制御用 worktree）。最後の状態の書き出しと、次の launch が記録ファイルを取り合わないように
  wait_for watch_exited "${1:-$CTL}" || fail "見張り役が終わらない: $(cat "$(loop_log "${1:-$CTL}")")"
}
loop_comments() { # 状態用の Issue のコメントのうち、Discussion $1 の手動ループのもの（author が ${2:-test} のものの、目印の行）
  local d
  for d in "$GH_STATE/comments"/*; do
    [[ -f "$d/body" && "$(cat "$d/login")" == "${2:-test}" ]] || continue
    head -n 1 "$d/body" | grep -F "\"discussion\":$1," | grep -F '"writer":"manual"' || true
  done
}
comment_count() { loop_comments "$1" | grep -c . || true; }
comment_has() { loop_comments "$1" | grep -qF "$2"; }
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
OUT=$(STUB_LOOP=promise manual launch "SMOKE DONE") || fail "launch が失敗した"
grep -q '最終 PR を自動で作ります' <<<"$OUT" || fail "launch が見張り役を起動したことを知らせていない"
wait_watch "$(loop_log)"
grep -q -- '^pr create .*--base develop --head epic/smoke' "$WORK/gh.log" || fail "見張り役が最終 PR を作っていない: $(cat "$(loop_log)")"
grep -q -- '--label epic-final' "$WORK/gh.log" || fail "最終 PR に epic-final を付けていない"
grep -q 'テストでしたこと' "$WORK/gh.log" || fail "最終 PR に state の「最終 PR に載せる内容」を載せていない"
wait_for comment_has 1 '"state":"completed"' || fail "最終 PR を作った後に、ループの状態のコメントを完了にしていない: $(loop_comments 1)"
[[ "$(comment_count 1)" -eq 1 ]] || fail "ループの状態のコメントが 1 つになっていない（$(comment_count 1) 件）"
for d in "$GH_STATE/issues"/*; do
  grep -q 'ask-hub:loop-status' "$d/body" && fail "手動ループが、状態用の Issue の本文にループの状態を書いた"
done
grep -q '^issue edit' "$WORK/gh.log" && fail "手動ループが、状態用の Issue の本文を書き換えた"
touch "$GH_STATE/closed-1"
wait_watch_exit
[[ "$(comment_count 1)" -eq 0 ]] || fail "ゴール元の Discussion が閉じたのに、ループの状態のコメントを消していない"
grep -q 'コメントを消しました' "$(loop_log)" || fail "コメントを消したことをログに書いていない"
grep -q '^ended_at=' "$CTL/.claude/askhub-manual.local.txt" || fail "ループを終えたことを記録していない"
rm -f "$GH_STATE/closed-1"
ok "固定パスで始めた手動ループも続けて回せ、見張り役が最終 PR を作り、Discussion が閉じたらループの状態のコメントを消す"

# promise を出さずに終わったとき（state ファイルが残る異常終了）は作らない（番号を付けても、固定パスのループを使う）
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
manual launch 1 "SMOKE DONE" >/dev/null || fail "2 回目の launch が失敗した"
grep -q '^ended_at=' "$CTL/.claude/askhub-manual.local.txt" && fail "起動し直したのに、ループを終えた記録が残っている"
wait_watch "$(loop_log)"
grep -q '^pr create' "$WORK/gh.log" && fail "異常終了したのに最終 PR を作った"
grep -q '完了語を出さずに終わった' "$(loop_log)" || fail "最終 PR を作らない理由をログに書いていない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
OUT=$(ASKHUB_AUTO_FINAL=0 manual launch "SMOKE DONE") || fail "ASKHUB_AUTO_FINAL=0 の launch が失敗した"
grep -q '自動では作りません' <<<"$OUT" || fail "ASKHUB_AUTO_FINAL=0 で最終 PR を作らないことを知らせていない"
until ! kill -0 "$(cat "$CTL/.claude/askhub-loop.pid")" 2>/dev/null; do sleep 0.5; done
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "promise を出さずに終わったときと ASKHUB_AUTO_FINAL=0 のときは、最終 PR を作らない"

# ---- 手動ループを Discussion ごとの作業場所で並べる ---------------------------------------------------
# 制御用 worktree（myapp-ralph-ctl）を、オーケストレーターの自動ループが使っている状態にする（固定パスの手動ループの記録は外す）
rm -f "$CTL/.claude/askhub-manual.local.txt"
printf '# ゴール\n\n- [ ] 【FEAT】自動ループのタスク | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
(cd "$CTL" && ../myapp-ios/scripts/ralph-start.sh "AUTO DONE" >/dev/null) || fail "自動ループの state を作れない"
sleep 600 &
AUTO_PID=$!
echo "$AUTO_PID" > "$CTL/.claude/askhub-loop.pid"
auto_untouched() {
  [[ -f "$CTL/.claude/ralph-loop.local.md" && "$(cat "$CTL/.claude/askhub-loop.pid")" == "$AUTO_PID" \
    && ! -e "$CTL/.claude/askhub-manual.local.txt" && "$(git -C "$CTL" symbolic-ref --short HEAD)" == epic/smoke ]]
}
# 状態用の Issue の本文はオーケストレーターのもの。信用外の author が、手動ループの目印を真似たコメントを付けている
for d in "$GH_STATE/issues"/*; do ISSUE="${d##*/}"; break; done
printf '%s' '<!-- ask-hub:loop-status {"checkedAt":"2026-10-15T00:00:00Z","state":"running","writer":"orchestrator"} -->' > "$GH_STATE/issues/$ISSUE/body"
cp "$GH_STATE/issues/$ISSUE/body" "$WORK/issue-body.before"
mkdir -p "$GH_STATE/comments/1"
printf '%s' "$ISSUE" > "$GH_STATE/comments/1/issue"
printf '%s' evil > "$GH_STATE/comments/1/login"
printf '%s' '<!-- ask-hub:loop-status {"checkedAt":"2030-01-01T00:00:00Z","discussion":101,"runner":"evil","state":"running","writer":"manual"} -->' > "$GH_STATE/comments/1/body"
printf '%s' 2030-01-01T00:00:00Z > "$GH_STATE/comments/1/updated"
cp "$GH_STATE/comments/1/body" "$WORK/evil.before"

: > "$WORK/gh.log"
manual start 101 epic/manual-one >"$WORK/start.out" 2>&1 || { cat "$WORK/start.out" >&2; fail "自動ループの制御用 worktree があると、手動ループを start できない"; }
D101="$WORK/repos/myapp-ralph-d101-ctl"
for d in "$D101" "$WORK/repos/myapp-ralph-d101-a" "$WORK/repos/myapp-ralph-d101-b"; do
  [[ -d "$d" ]] || fail "Discussion ごとの作業場所を作っていない: $d"
done
[[ "$(git -C "$D101" symbolic-ref --short HEAD)" == epic/manual-one ]] || fail "Discussion ごとの制御用 worktree が epic を checkout していない"
grep -qx 'discussion=101' "$D101/.claude/askhub-manual.local.txt" || fail "Discussion ごとの制御用 worktree に手動ループの記録が無い"
auto_untouched || fail "手動ループの start が、自動ループの制御用 worktree に触った"
grep -q 'WORKTREE_A: .*myapp-ralph-d101-a' "$WORK/start.out" || fail "start が Discussion ごとのスロットを表示していない"
ok "自動ループの制御用 worktree があっても、手動ループを Discussion ごとの作業場所で start できる"

manual start 102 epic/manual-two >"$WORK/start.out" 2>&1 || { cat "$WORK/start.out" >&2; fail "同じリポジトリで 2 つ目の手動ループを start できない"; }
D102="$WORK/repos/myapp-ralph-d102-ctl"
[[ -d "$D102" && -d "$WORK/repos/myapp-ralph-d102-a" && -d "$WORK/repos/myapp-ralph-d102-b" ]] || fail "2 つ目の手動ループの作業場所を作っていない"
[[ -f "$D101/.claude/askhub-manual.local.txt" ]] || fail "2 つ目の start が、1 つ目の手動ループの記録を消した"
[[ "$(comment_count 101)" -eq 1 && "$(comment_count 102)" -eq 1 ]] || fail "手動ループごとにコメントを 1 つずつ書いていない（101: $(comment_count 101) 件、102: $(comment_count 102) 件）"
comment_has 101 '"runner":"test","state":"waiting-to-start"' || fail "コメントに担当者と開始待ちを書いていない: $(loop_comments 101)"
cmp -s "$WORK/issue-body.before" "$GH_STATE/issues/$ISSUE/body" || fail "手動ループが、状態用の Issue の本文を書き換えた"
cmp -s "$WORK/evil.before" "$GH_STATE/comments/1/body" || fail "信用外の author のコメントを書き換えた"
auto_untouched || fail "2 つ目の start が、自動ループの制御用 worktree に触った"
ok "同じリポジトリで Discussion の違う 2 つの手動ループを start でき、それぞれのループのコメントにだけ状態を書く"

if manual start 103 epic/manual-one >"$WORK/start.out" 2>&1; then fail "ほかの手動ループが使っている epic で start できた"; fi
grep -q '別の worktree' "$WORK/start.out" || fail "epic をほかのループが使っていることを知らせていない: $(cat "$WORK/start.out")"
[[ ! -e "$WORK/repos/myapp-ralph-d103-ctl" ]] || fail "start できなかったのに作業場所を残した"
ok "ほかのループが使っている epic では start しない"

# ループの Claude は、制御用 worktree の中から番号を付けずに status を呼ぶ
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$D101/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [x] 【FEAT】一つ目 | label: enhancement\n- [ ] 【FEAT】二つ目 | label: enhancement\n' > "$D101/.claude/ralph-goal.local.md"
BEFORE_102=$(loop_comments 102)
(cd "$D101" && GH_LOG="$WORK/gh.log" scripts/askhub-manual.sh status --stopping >/dev/null) || fail "制御用 worktree の中から status を書けない"
[[ "$(comment_count 101)" -eq 1 ]] || fail "status がコメントを重ねて作った"
comment_has 101 '"progress":{"completed":1,"deferred":0,"total":2}' || fail "status が Discussion 101 のコメントを書き換えていない: $(loop_comments 101)"
[[ "$(loop_comments 102)" == "$BEFORE_102" ]] || fail "status が、ほかのループのコメントを書き換えた"
if manual resume >"$WORK/resume.out" 2>&1; then fail "手動ループが 2 つあるのに、番号を省いた resume を受け付けた"; fi
grep -q '#101 #102' "$WORK/resume.out" || fail "番号を付けるよう知らせていない: $(cat "$WORK/resume.out")"
ok "制御用 worktree の中の status は自分のループのコメントだけを書き換え、番号を省いた操作はループが複数なら断る"

# 番号を付けた launch。見張り役が最終 PR を作り、Discussion が閉じたら、そのループのコメントだけを消す
: > "$WORK/gh.log"
STUB_LOOP=promise manual launch 101 "SMOKE DONE" >/dev/null || fail "番号を付けた launch が失敗した"
wait_watch "$(loop_log "$D101")"
grep -q -- '^pr create .*--base develop --head epic/manual-one' "$WORK/gh.log" || fail "見張り役が Discussion 101 の最終 PR を作っていない: $(cat "$(loop_log "$D101")")"
wait_for comment_has 101 '"state":"completed"' || fail "最終 PR を作った後に、Discussion 101 のコメントを完了にしていない"
touch "$GH_STATE/closed-101"
wait_watch_exit "$D101"
[[ "$(comment_count 101)" -eq 0 ]] || fail "Discussion 101 が閉じたのに、そのループのコメントを消していない"
[[ "$(comment_count 102)" -eq 1 ]] || fail "ほかのループのコメントを消した"
cmp -s "$WORK/evil.before" "$GH_STATE/comments/1/body" || fail "信用外の author のコメントに触った"
ok "番号を付けた launch の見張り役が最終 PR を作り、Discussion が閉じたら、そのループのコメントだけを消す"

OUT=$(manual end 102) || fail "end が失敗した"
[[ "$(comment_count 102)" -eq 0 ]] || fail "end がループの状態のコメントを消していない"
grep -q '^ended_at=' "$D102/.claude/askhub-manual.local.txt" || fail "end がループを終えたことを記録していない"
grep -q 'ralph-stop.sh" --worktrees' <<<"$OUT" || fail "end が作業場所の消し方を知らせていない"
if manual resume >"$WORK/resume.out" 2>&1; then fail "終えたループを、番号を省いた resume で起動した"; fi
ok "end で、Discussion を閉じずにやめたループのコメントを消す"

# 見張り役が動いていなかった（Mac の再起動など）ループは、次の start が Discussion の閉じたものを片付ける
manual start 104 epic/manual-four >/dev/null 2>&1 || fail "3 つ目の手動ループを start できない"
[[ "$(comment_count 104)" -eq 1 ]] || fail "3 つ目の手動ループのコメントを書いていない"
touch "$GH_STATE/closed-104"
OUT=$(manual start 105 epic/manual-five 2>&1) || fail "4 つ目の手動ループを start できない: $OUT"
[[ "$(comment_count 104)" -eq 0 ]] || fail "start が、Discussion の閉じたほかの手動ループのコメントを消していない"
[[ "$(comment_count 105)" -eq 1 ]] || fail "4 つ目の手動ループのコメントを書いていない"
auto_untouched || fail "手動ループの操作が、自動ループの制御用 worktree に触った"
{ kill "$AUTO_PID" && wait "$AUTO_PID"; } 2>/dev/null || true
ok "start は、Discussion の閉じたほかの手動ループのコメントを消す。手動ループの操作は自動ループの制御用 worktree に触らない"

# askhub-manual.sh は中継から呼べる（引数なしは使い方を出して 64 で終わる）
set +e
(cd "$APP" && scripts/askhub-manual.sh >/dev/null 2>&1)
STATUS=$?
set -e
[[ "$STATUS" -eq 64 ]] || fail "askhub-manual.sh の引数なしが 64 で終わらない（${STATUS}）"
ok "askhub-manual.sh を中継から呼べる"

echo
echo "すべて通りました（${PASSED} 件）"
