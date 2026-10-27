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
# 自動ループの代わりに動かすプロセス（後半のテスト）と、Discussion が閉じるのを待ったままの見張り役（引数に WORK のパスが入る）も止める
trap 'kill "${AUTO_PID:-}" 2>/dev/null || true; pkill -f -- "$WORK/" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PASSED=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; PASSED=$((PASSED + 1)); }

# 担当者の Mac と同じく UTF-8 のロケールで流す（bash 3.2 は UTF-8 のロケールで、$VAR の直後の全角文字を変数名の一部と読む）
for locale in ja_JP.UTF-8 en_US.UTF-8 C.UTF-8 C.utf8; do
  if locale -a 2>/dev/null | grep -qix -- "$locale"; then
    export LC_ALL="$locale"
    break
  fi
done
# 変数の直後に全角文字を続けない（${VAR}（ のように囲む）。ロケールによっては流しても気づけないので、字面でも確かめる
if LC_ALL=C grep -n -E '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' "$KIT"/bin/*.sh "$KIT"/install.sh "$KIT"/shim/scripts/*.sh "$KIT"/tests/run.sh; then
  fail "変数の直後に全角文字が続いています（\${VAR} のように波かっこで囲む）"
fi
ok "変数の直後に全角文字を続けていない"

# ---- 環境: 偽の gh・HOME・kit の取得元 ---------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/home/.claude"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
# テスト用の gh。GitHub の代わりに、状態用の Issue・そのコメント・閉じた Discussion を GH_STATE のファイルで持つ。
# 応答は JSON で作り、--jq があれば jq で絞る（本物の gh と同じく、文字列はそのまま出す）。書き込み権限を持つのは test だけ。
# Discussion はどの番号も manual-loop 付きで test が担当。GH_STATE/closed-<番号> があれば閉じている。
# GH_STATE/hold-<番号> があるあいだは、その Discussion が閉じたかの問い合わせに答えず、止めている印に GH_STATE/held-<番号> を置く
# （見張り役を、記録・PID のファイルを読み終えた後の確認の途中で止める）。
# GH_STATE/needs-answer/<番号> があれば、その PR は needs-answer 付きで open。GH_STATE/pulls/<番号>.json は PR の行コメント（JSON の配列）。
# GH_STATE/final-pr/<head の / を _ にしたもの> は、その head の PR の一覧（JSON の配列。最終 PR が既にあるとき）
# gh のアカウントは GH_VIEWER（既定は test）。GH_LOG があれば、呼ばれた引数をそこに書き足す
[[ -z "${GH_LOG:-}" ]] || printf '%s\n' "$*" >> "$GH_LOG"
S="${GH_STATE:?}"
mkdir -p "$S/issues" "$S/comments"

jq_expr="" method="" body="" query="" number="" author="" label="" head=""
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
    --label) label="$2"; shift ;;
    --head) head="$2"; shift ;;
    -R | --state | --limit | --json | --title | --color | --description | --base | --assignee) shift ;;
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
  "api user") jq -n --arg login "${GH_VIEWER:-test}" '{login: $login}' | out ;;
  "api graphql")
    if [[ "$query" == *'{ closed }'* && -e "$S/hold-$number" ]]; then
      touch "$S/held-$number"
      while [[ -e "$S/hold-$number" ]]; do sleep 0.1; done
      rm -f "$S/held-$number"
    fi
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
        [[ -d "$S/comments/${rest#comments/}" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        printf '%s' "$body" > "$S/comments/${rest#comments/}/body"
        now > "$S/comments/${rest#comments/}/updated" ;;
      "DELETE comments/"*)
        [[ -d "$S/comments/${rest#comments/}" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        rm -r "${S:?}/comments/${rest#comments/}" ;;
    esac ;;
  "api repos/example/myapp-ios/pulls/"*)
    rest="${endpoint#repos/example/myapp-ios/pulls/}"
    if [[ -f "$S/pulls/${rest%%/*}.json" ]]; then out < "$S/pulls/${rest%%/*}.json"; else echo '[]' | out; fi ;;
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
  "issue view") jq -n --rawfile body "$S/issues/${positional[2]}/body" '{body: $body}' | out ;;
  "issue reopen") printf '%s' OPEN > "$S/issues/${positional[2]}/state" ;;
  "issue edit") printf '%s' "$body" > "$S/issues/${positional[2]}/body" ;;
  "pr list")
    if [[ "$label" == needs-answer ]]; then
      for f in "$S/needs-answer"/*; do
        [[ -f "$f" ]] && jq -n --argjson number "${f##*/}" '{number: $number}'
      done | jq -s . | out
    elif [[ -n "$head" && -f "$S/final-pr/${head//\//_}" ]]; then
      out < "$S/final-pr/${head//\//_}"
    else
      echo '[]' | out
    fi ;;
  "pr create") echo "https://github.com/example/myapp-ios/pull/99" ;;
  *) exit 0 ;;
esac
GH
# テスト用の claude。権限モードの確認（stream-json）には init の行を返す。
# ループとしては、STUB_LOOP=promise なら全タスクを終えて最終 PR に載せる内容を書き、Stop hook と同じく state ファイルを消して promise を出す。
# STUB_LOOP=limit-once なら、1 回目（STUB_LIMIT_MARK のファイルが無いとき）は Claude の利用上限のメッセージ（解除は STUB_LIMIT_WAIT 秒後）を出して
# state ファイルを残したまま終わり、2 回目（解除の後の再開）は promise と同じにする。
# STUB_LOOP=answer-once なら、1 回目（STUB_ANSWER_MARK のファイルが無いとき）は、タスクに ※回答待ち（PR #STUB_ANSWER_PR / ask id STUB_ANSWER_ID）を付けて
# その PR を needs-answer にし、promise を出して終わる（回答待ちの PR を残して完了）。2 回目（回答を受けた再開）は、playbook の B-1 と同じく
# 印と needs-answer を外し、最終 PR に載せる内容に「回答を受けて直したこと」を足してから、promise と同じにする。
# それ以外は state ファイルを残したまま終わる（API のエラーなどの異常終了）
cat > "$WORK/bin/claude" <<'CLAUDE'
#!/bin/bash
case "$*" in
  *stream-json*) echo '{"type":"system","subtype":"init","permissionMode":"bypassPermissions"}'; exit 0 ;;
esac
sleep 2
if [[ "${STUB_LOOP:-}" == limit-once ]]; then
  if [[ ! -e "${STUB_LIMIT_MARK:?}" ]]; then
    touch "$STUB_LIMIT_MARK"
    echo "Claude AI usage limit reached|$(( $(date +%s) + ${STUB_LIMIT_WAIT:-5} ))"
    exit 1
  fi
  STUB_LOOP=promise
fi
if [[ "${STUB_LOOP:-}" == answer-once ]]; then
  if [[ ! -e "${STUB_ANSWER_MARK:?}" ]]; then
    touch "$STUB_ANSWER_MARK"
    perl -pi -e 's/^(- \[ \] .*)$/$1  ※回答待ち（PR #$ENV{STUB_ANSWER_PR} \/ ask id $ENV{STUB_ANSWER_ID}）/' .claude/ralph-goal.local.md
    mkdir -p "$GH_STATE/needs-answer"
    touch "$GH_STATE/needs-answer/$STUB_ANSWER_PR"
    perl -0pi -e 's/(## 最終 PR に載せる内容\n[^\n]*\n)/$1- テストでしたこと\n/' .claude/ralph-state.local.md
    rm -f .claude/ralph-loop.local.md
    echo '<promise>SMOKE DONE</promise>'
    exit 0
  fi
  perl -pi -e 's/  ※回答待ち（PR #\d+ \/ ask id \d+）//' .claude/ralph-goal.local.md
  rm -f "$GH_STATE/needs-answer/$STUB_ANSWER_PR"
  perl -0pi -e 's/(## 最終 PR に載せる内容\n[^\n]*\n)/$1- 回答を受けて直したこと\n/' .claude/ralph-state.local.md
  STUB_LOOP=promise
fi
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
grep -q '判断ログ Issue（仮決め一覧）か最終 PR への指示を処理するために再開した' "$CTL/.claude/ralph-loop.local.md" || fail "再開の理由を state に書いていない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "decision-log の再開では、未完了タスクが 0 件でも起動する"
(cd "$CTL" && ASKHUB_RESUME_REASON=final-pr ../myapp-ios/scripts/ralph-start.sh "SMOKE DONE" >/dev/null) || fail "final-pr の再開で起動しない"
grep -q '最終 PR への指示を処理するために再開した' "$CTL/.claude/ralph-loop.local.md" || fail "最終 PR への指示による再開だと state に書いていない"
grep -q 'STEP B-0b' "$CTL/.claude/ralph-loop.local.md" || fail "最終 PR への指示を読む手順を案内していない"
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "final-pr の再開では、未完了タスクが 0 件でも起動し、最終 PR への指示を読むよう伝える"

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
  (cd "$APP" && ASKHUB_LOG_DIR="$WORK/logs" ASKHUB_FINAL_WATCH_INTERVAL=1 ASKHUB_CLOSE_WATCH_INTERVAL=1 ASKHUB_ANSWER_WATCH_INTERVAL=1 GH_LOG="$WORK/gh.log" \
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
  wait_for grep -Eq '最終 PR を作りました|最終 PR の本文を書き直しました|最終 PR は作りません|最終 PR を作れませんでした' "$1" \
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
hold_watch() { # Discussion $1 の見張り役を、次の「Discussion が閉じたか」の確認で止める（その周の記録・PID のファイルの読み出しは終わっている）
  touch "$GH_STATE/hold-$1"
  wait_for test -e "$GH_STATE/held-$1"
}
release_watch() { # 止めた見張り役を進める。問い合わせが返るまで待つ（続けて hold_watch したときに、同じ問い合わせを止めたままと取り違えない）
  rm -f "$GH_STATE/hold-$1"
  wait_for test ! -e "$GH_STATE/held-$1"
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
add_issue() { # $1=番号 $2=本文（author は test、open）
  mkdir -p "$GH_STATE/issues/$1"
  printf '%s' test > "$GH_STATE/issues/$1/author"
  printf '%s' OPEN > "$GH_STATE/issues/$1/state"
  printf '%s' "$2" > "$GH_STATE/issues/$1/body"
  printf '%s' 2026-10-01T00:00:00Z > "$GH_STATE/issues/$1/updated"
}
add_comment() { # $1=id $2=Issue の番号 $3=author $4=本文 $5=更新日時
  mkdir -p "$GH_STATE/comments/$1"
  printf '%s' "$2" > "$GH_STATE/comments/$1/issue"
  printf '%s' "$3" > "$GH_STATE/comments/$1/login"
  printf '%s' "$4" > "$GH_STATE/comments/$1/body"
  printf '%s' "$5" > "$GH_STATE/comments/$1/updated"
}
# kit 1.3 は、状態用の Issue の本文にこのループの状態を書いていた
add_issue 50 '<!-- ask-hub:loop-status {"checkedAt":"2026-10-01T00:00:00Z","discussion":1,"epic":"epic/smoke","runner":"test","state":"running","writer":"manual"} -->
## ループの状態'
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
[[ "$(find "$GH_STATE/issues" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]] || fail "状態用の Issue があるのに、新しく作った"
grep -q 'ask-hub:loop-status' "$GH_STATE/issues/50/body" && fail "本文に残っていた、このループの前の形の状態を片付けていない"
grep -q 'ループ（ゴール元の Discussion）ごとのコメントに書きます' "$GH_STATE/issues/50/body" || fail "片付けた本文が、手動ループが Issue を作るときの本文になっていない"
touch "$GH_STATE/closed-1"
wait_watch_exit
[[ "$(comment_count 1)" -eq 0 ]] || fail "ゴール元の Discussion が閉じたのに、ループの状態のコメントを消していない"
grep -q 'コメントを消しました' "$(loop_log)" || fail "コメントを消したことをログに書いていない"
grep -q '^ended_at=' "$CTL/.claude/askhub-manual.local.txt" || fail "ループを終えたことを記録していない"
rm -f "$GH_STATE/closed-1"
ok "固定パスで始めた手動ループも続けて回せ、本文に残った前の形の状態を片付け、見張り役が最終 PR を作り、Discussion が閉じたらコメントを消す"

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
# 制御用 worktree（myapp-ralph-ctl）を、オーケストレーターの自動ループが使っている状態にする（固定パスの手動ループの記録は外す）。
# 固定パスのループの見張り役は、Discussion 1 が閉じるのを待っているので、先に止める（記録を外すと、ほかのループの場所とみなして待ち続ける）
kill "$(sed -n 's/^watch_pid=//p' "$CTL/.claude/askhub-manual.local.txt" | tail -n 1)" 2>/dev/null || true
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
add_comment 1 "$ISSUE" evil '<!-- ask-hub:loop-status {"checkedAt":"2030-01-01T00:00:00Z","discussion":101,"runner":"evil","state":"running","writer":"manual"} -->' 2030-01-01T00:00:00Z
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

# 同じループのコメントが重なっていたら、最新を書き換えて残りを消す。信用する author でも、オーケストレーターが書いた同じ Discussion のコメントには触らない。
# スロットの中から番号を省いて呼んでも、そのループを使う。番号の先頭の 0 は外す
add_comment 2 "$ISSUE" test '<!-- ask-hub:loop-status {"checkedAt":"2026-01-01T00:00:00Z","discussion":105,"runner":"test","state":"running","writer":"manual"} -->' 2026-01-01T00:00:00Z
add_comment 3 "$ISSUE" test '<!-- ask-hub:loop-status {"checkedAt":"2026-01-01T00:00:00Z","discussion":105,"state":"running","writer":"orchestrator"} -->' 2026-01-01T00:00:00Z
cp "$GH_STATE/comments/3/body" "$WORK/orchestrator.before"
[[ "$(comment_count 105)" -eq 2 ]] || fail "重なったコメントを用意できていない"
(cd "$WORK/repos/myapp-ralph-d105-a" && GH_LOG="$WORK/gh.log" scripts/askhub-manual.sh status --stopping >/dev/null) || fail "スロットの中から status を書けない"
[[ "$(comment_count 105)" -eq 1 && ! -e "$GH_STATE/comments/2" ]] || fail "重なった古いコメントを消していない"
cmp -s "$WORK/orchestrator.before" "$GH_STATE/comments/3/body" || fail "オーケストレーターが書いた、同じ Discussion のコメントに触った"
manual status 0105 --stopping >/dev/null || fail "先頭に 0 の付いた番号で status を書けない"
[[ "$(comment_count 105)" -eq 1 ]] || fail "先頭に 0 の付いた番号で、別のコメントを作った"
ok "重なったコメントは最新だけを残し、オーケストレーターのコメントには触らない。スロットの中・先頭に 0 の付いた番号でも同じループを使う"

# gh のアカウントが信用する author でなければ書かない。番号だけの launch は完了語の付け忘れとして断る
BEFORE_105=$(loop_comments 105)
GH_VIEWER=evil manual status 105 --stopping >/dev/null 2>"$WORK/status.err" || fail "信用外のアカウントの status が失敗で終わった（ループを止めてしまう）"
grep -q '信用する author ではない' "$WORK/status.err" || fail "信用外のアカウントで書かないことを知らせていない"
[[ "$(loop_comments 105)" == "$BEFORE_105" && "$(comment_count 105)" -eq 1 ]] || fail "信用外のアカウントでループの状態を書いた"
if manual launch 105 >"$WORK/launch.out" 2>&1; then fail "番号だけの launch で起動した"; fi
grep -q '完了語を指定してください' "$WORK/launch.out" || fail "完了語の付け忘れを知らせていない: $(cat "$WORK/launch.out")"
ok "信用外のアカウントではループの状態を書かず、番号だけの launch は断る"

# end で終えたループは、status を流してもコメントを作り直さない（片付ける役がいないコメントを残さない）
manual end 105 >"$WORK/end.out" || fail "end が失敗した"
grep -q 'open のままです' "$WORK/end.out" || fail "end が、Discussion が open のままだと知らせていない"
manual status 105 --stopping >"$WORK/status.out" 2>&1 || fail "終えたループの status が失敗で終わった"
grep -q '終えているため' "$WORK/status.out" || fail "終えたループの状態を書かないことを知らせていない"
[[ "$(comment_count 105)" -eq 0 ]] || fail "end で終えたループの status が、コメントを作り直した"
ok "end で終えたループは、status でコメントを作り直さない"

# コメントを消すときは、別の状態用の Issue の本文に残った、このループの前の形の状態も片付ける（この版でコメントを書かずに end したときなど）
add_issue 60 '<!-- ask-hub:loop-status {"checkedAt":"2026-10-01T00:00:00Z","discussion":105,"epic":"epic/manual-five","runner":"test","state":"running","writer":"manual"} -->
## ループの状態'
manual end 105 >/dev/null || fail "2 回目の end が失敗した"
grep -q 'ask-hub:loop-status' "$GH_STATE/issues/60/body" && fail "end が、別の Issue の本文に残ったこのループの前の形の状態を片付けていない"
cmp -s "$WORK/issue-body.before" "$GH_STATE/issues/$ISSUE/body" || fail "end が、オーケストレーターの書いた本文を書き換えた"
ok "コメントを消すときは、別の Issue の本文に残った前の形の状態も片付け、オーケストレーターの本文には触らない"

# 見張り役は、作業場所の記録が消えて別のプロセスの PID が書かれても（オーケストレーターが作り直したなど）、引き継いだと読まずに待ち、
# Discussion が閉じたらコメントを消す
manual start 106 epic/manual-six >/dev/null 2>&1 || fail "手動ループを start できない"
D106="$WORK/repos/myapp-ralph-d106-ctl"
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$D106/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$D106/.claude/ralph-goal.local.md"
STUB_LOOP=promise manual launch 106 "SMOKE DONE" >/dev/null || fail "launch が失敗した"
LOG_106=$(loop_log "$D106")
WATCH_106=$(sed -n 's/^watch_pid=//p' "$D106/.claude/askhub-manual.local.txt" | tail -n 1)
wait_watch "$LOG_106"
wait_for comment_has 106 '"state":"completed"' || fail "最終 PR を作った後に、Discussion 106 のコメントを完了にしていない"
# 記録を消して別の PID を書くのは、見張り役を Discussion が閉じたかの確認で止めている間にする。負荷が高いと、
# - ループ（2 秒で終わる）が launch の状態の書き出しより先に終わり、launch がコメントを先に「完了」と書くので、見張り役の final がまだ記録を書いている
# - 見張り役は周ごとに記録と PID のファイルを別々に読むので、その間に消して書くと、自分のループの記録と別の PID を読んで引き継がれたとみなす
# - 記録の有無を確かめてから sed で読むまでの間に消すと、sed の No such file がログに出る
hold_watch 106 || fail "最終 PR を作った後に、見張り役が Discussion が閉じるのを待っていない: $(cat "$LOG_106")"
rm -f "$D106/.claude/askhub-manual.local.txt"
echo "$$" > "$D106/.claude/askhub-loop.pid"
release_watch 106
# 次の確認まで進んでも（記録が無く、別の PID が書かれているのを読んでも）終わらない
hold_watch 106 || fail "記録が消えて別の PID が書かれただけで、見張り役が終わった: $(cat "$LOG_106")"
kill -0 "$WATCH_106" 2>/dev/null || fail "記録が消えて別の PID が書かれただけで、見張り役が終わった"
# PID のファイルも消えても待ち続け、読めないことをログに書かない
rm -f "$D106/.claude/askhub-loop.pid"
release_watch 106
hold_watch 106 || fail "PID のファイルが消えただけで、見張り役が終わった: $(cat "$LOG_106")"
kill -0 "$WATCH_106" 2>/dev/null || fail "PID のファイルが消えただけで、見張り役が終わった"
touch "$GH_STATE/closed-106"
release_watch 106
wait_for eval '! kill -0 "$WATCH_106" 2>/dev/null' || fail "Discussion が閉じても、見張り役が終わらない"
[[ "$(comment_count 106)" -eq 0 ]] || fail "記録が消えた後に Discussion が閉じたのに、コメントを消していない"
[[ ! -e "$D106/.claude/askhub-manual.local.txt" ]] || fail "消えた記録を作り直した"
grep -q 'No such file' "$LOG_106" && fail "記録が消えた後、見張り役がログにエラーを書いた"
ok "見張り役は、記録が消えて別の PID が書かれても待ち続け、Discussion が閉じたらコメントを消す"

# ---- OpenCode で回す（ASKHUB_AGENT=opencode）--------------------------------------------------
# 手動ループの段取り（AskHub から貼る文言・start → launch → resume → final）は Claude のままで、
# ループ本体だけを OpenCode に差し替えられる。周回は bin/opencode-loop.sh が opencode run を回し、
# 最後のメッセージの promise を検知したら state を消す（見張り役・final はそのまま動く）
cat > "$WORK/bin/opencode" <<'OPENCODE'
#!/bin/bash
# テスト用の opencode。引数を機械的に読める形でログに残す（mode は --session の有無）。
# 1 回目（--session なし）はセッションだけ作って失敗し、2 回目（--session あり）は Claude の stub と同じく
# ゴールを終えて「最終 PR に載せる内容」を書き、promise のテキストを出す（セッションの継続と再試行の確認）。
# STUB_OPENCODE_STRAY=1 のときは、途中のメッセージに promise を出したまま、state を消して止まる
# （完了語を出さずに終わったのに、見張り役が最終 PR を作らないことの確認用）
mode=title model=no
for a in "$@"; do
  [[ "$a" == "--session" ]] && mode=session
  [[ "$a" == "test/model" ]] && model=yes
done
{
  echo "==== invoke mode=$mode model=$model"
  printf 'arg: %s\n' "$@"
} >> "${STUB_OPENCODE_LOG:-/dev/null}"
echo '{"type":"step_start","sessionID":"ses_test"}'
if [[ "${STUB_OPENCODE_STRAY:-}" == 1 ]]; then
  if [[ "$mode" == session ]]; then
    echo '{"type":"text","sessionID":"ses_test","part":{"type":"text","messageID":"msg_3","text":"指示どおり、state を消して止めます。"}}'
    rm -f .claude/ralph-loop.local.md
  else
    echo '{"type":"text","sessionID":"ses_test","part":{"type":"text","messageID":"msg_1","text":"作業中です。\n<promise>SMOKE DONE</promise>"}}'
    echo '{"type":"text","sessionID":"ses_test","part":{"type":"text","messageID":"msg_2","text":"まだ続けます。"}}'
  fi
  exit 0
fi
if [[ "${STUB_OPENCODE_FAIL:-}" == always || "$mode" != session ]]; then
  echo 'API Error: Connection refused' >&2
  exit 1
fi
perl -pi -e 's/^- \[ \]/- [x]/' .claude/ralph-goal.local.md
perl -0pi -e 's/(## 最終 PR に載せる内容\n[^\n]*\n)/$1- テストでしたこと（opencode）\n/' .claude/ralph-state.local.md
echo '{"type":"text","sessionID":"ses_test","part":{"type":"text","messageID":"msg_1","text":"作業を終えました。\n<promise>SMOKE DONE</promise>"}}'
echo '{"type":"step_finish","sessionID":"ses_test","part":{"reason":"stop"}}'
OPENCODE
chmod +x "$WORK/bin/opencode"
invokes() { grep -c '^==== invoke' "$WORK/opencode.log" 2>/dev/null || true; }
invoke_line() { sed -n 's/^==== invoke //p' "$WORK/opencode.log" | sed -n "${1}p"; }

# このテストのあいだだけ、ralph-loop プラグインを無効にする（Claude では起動できない状態。OpenCode はプラグインを使わないので起動できるはず）
cp "$HOME/.claude/settings.json" "$WORK/plugin-settings.before"
echo '{"enabledPlugins":{"ralph-loop@claude-plugins-official":false}}' > "$HOME/.claude/settings.json"

manual start 107 epic/opencode-one >/dev/null 2>&1 || fail "OpenCode 用の手動ループを start できない"
D107="$WORK/repos/myapp-ralph-d107-ctl"
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$D107/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [ ] 【FEAT】OpenCode のテスト | label: enhancement\n' > "$D107/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
: > "$WORK/opencode.log"
OUT=$(ASKHUB_AGENT=opencode ASKHUB_OPENCODE_MODEL=test/model ASKHUB_OPENCODE_MAX_FAILS=3 ASKHUB_OPENCODE_FAIL_SLEEP=0 \
  STUB_OPENCODE_LOG="$WORK/opencode.log" manual launch 107 "SMOKE DONE") || fail "OpenCode の launch が失敗した: $OUT"
grep -q '実行エージェント: OpenCode' <<<"$OUT" || fail "launch が OpenCode で起動したことを知らせていない: $OUT"
LOG_107=$(loop_log "$D107")
wait_watch "$LOG_107"
grep -q -- '^pr create .*--base develop --head epic/opencode-one' "$WORK/gh.log" || fail "見張り役が OpenCode のループの最終 PR を作っていない: $(cat "$LOG_107")"
grep -q -- '--label epic-final' "$WORK/gh.log" || fail "OpenCode のループの最終 PR に epic-final を付けていない"
grep -q 'テストでしたこと（opencode）' "$WORK/gh.log" || fail "OpenCode のループの「最終 PR に載せる内容」を載せていない"
wait_for comment_has 107 '"state":"completed"' || fail "OpenCode のループのコメントを完了にしていない"
[[ ! -e "$D107/.claude/ralph-loop.local.md" ]] || fail "promise を検知したのに state が残っている"
[[ "$(invokes)" -eq 2 ]] || fail "opencode の起動が 2 回ではない（セッションの継続と再試行の確認）: $(invokes)"
[[ "$(invoke_line 1)" == "mode=title model=yes" ]] || fail "1 回目にセッションの名前を付けていない（セッションが無いのに --session で継続しようとした）: $(invoke_line 1)"
[[ "$(invoke_line 2)" == "mode=session model=yes" ]] || fail "2 回目に同じセッションで続けていない: $(invoke_line 2)"
grep -qx 'arg: --auto' "$WORK/opencode.log" || fail "--auto で起動していない"
grep -q 'OpenCode で回っている' "$WORK/opencode.log" || fail "プロンプトに OpenCode 向けの読み替えを足していない"
grep -q '完了語を検知しました' "$LOG_107" || fail "周回のログに、完了語の検知を書いていない"
grep -Fq '<promise>SMOKE DONE</promise>' "$LOG_107" || fail "周回のログに、完了を検知したときの promise を書いていない（見張り役がここから読む）"
[[ "$(grep -cF '<promise>SMOKE DONE</promise>' "$LOG_107" || true)" -eq 1 ]] || fail "周回のログの promise は、完了を検知した 1 行だけにしていない: $(grep -nF 'promise' "$LOG_107")"
grep -qF '<promise:log>SMOKE DONE</promise>' "$LOG_107" || fail "モデルのメッセージの promise を、ログではタグを崩して書いていない"
grep -qx 'permission_mode=auto' "$D107/.claude/askhub-manual.local.txt" || fail "権限モードの確認を飛ばして auto として記録していない"
DENIES=$(jq '.permissions.deny | length' "$D107/.claude/settings.json")
[[ "$(jq '.permissions | length' "$D107/.opencode/opencode.json")" -eq "$DENIES" ]] || fail "deny を OpenCode 形式に変換していない: $(jq '.permissions | length' "$D107/.opencode/opencode.json") 件"
jq -e '.permissions | any(.action == "shell" and .resource == "git push origin develop *" and .effect == "deny")' "$D107/.opencode/opencode.json" >/dev/null \
  || fail "Bash(git push origin develop:*) を shell の deny に変換していない"
grep -qxF '.opencode/opencode.json' "$APP/.git/info/exclude" || fail "OpenCode 用の deny の置き場を、コミット防止に登録していない"
git -C "$D107" status --porcelain | grep -q 'opencode' && fail "OpenCode 用の deny が、コミット対象に見えている"
touch "$GH_STATE/closed-107"
wait_watch_exit "$D107"
[[ "$(comment_count 107)" -eq 0 ]] || fail "Discussion が閉じたのに、OpenCode のループのコメントを消していない"
ok "ASKHUB_AGENT=opencode では、ralph-loop プラグインが無効でも launch でき、opencode run の再試行とセッションの継続で周回し、deny を変換し、見張り役が最終 PR を作る"

# OpenCode が失敗し続けたら state を残して止まり、resume で続きから回せる
manual start 108 epic/opencode-two >/dev/null 2>&1 || fail "2 つ目の OpenCode 用の手動ループを start できない"
D108="$WORK/repos/myapp-ralph-d108-ctl"
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$D108/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [ ] 【FEAT】OpenCode の再開テスト | label: enhancement\n' > "$D108/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
: > "$WORK/opencode.log"
OUT=$(ASKHUB_AGENT=opencode ASKHUB_OPENCODE_MAX_FAILS=1 ASKHUB_OPENCODE_FAIL_SLEEP=0 \
  STUB_OPENCODE_FAIL=always STUB_OPENCODE_LOG="$WORK/opencode.log" manual launch 108 "SMOKE DONE") || fail "OpenCode の launch が失敗した: $OUT"
LOG_108=$(loop_log "$D108")
wait_watch "$LOG_108"
grep -q '連続失敗が 1 回に達したため中止します' "$LOG_108" || fail "連続失敗で止まったことをログに書いていない: $(cat "$LOG_108")"
grep -q '完了語を出さずに終わった' "$LOG_108" || fail "見張り役が、失敗し続けたループを完了語なしの終了として扱っていない"
grep -q '^pr create' "$WORK/gh.log" && fail "OpenCode が失敗し続けたのに、最終 PR を作った"
[[ -f "$D108/.claude/ralph-loop.local.md" ]] || fail "連続失敗で止まったときに state を残していない（resume で続けられない）"
[[ "$(invokes)" -eq 1 ]] || fail "連続失敗の上限（1 回）を超えて起動した: $(invokes)"
: > "$WORK/gh.log"
: > "$WORK/opencode.log"
OUT=$(ASKHUB_AGENT=opencode ASKHUB_OPENCODE_MAX_FAILS=3 ASKHUB_OPENCODE_FAIL_SLEEP=0 \
  STUB_OPENCODE_LOG="$WORK/opencode.log" manual resume 108) || fail "OpenCode の resume が失敗した: $OUT"
grep -q '実行エージェント: OpenCode' <<<"$OUT" || fail "resume が OpenCode で起動していない: $OUT"
wait_watch "$(loop_log "$D108")"
grep -q -- '^pr create .*--head epic/opencode-two' "$WORK/gh.log" || fail "resume の見張り役が最終 PR を作っていない: $(cat "$(loop_log "$D108")")"
[[ ! -e "$D108/.claude/ralph-loop.local.md" ]] || fail "resume 後の周回で promise を出したのに state が残っている"
touch "$GH_STATE/closed-108"
wait_watch_exit "$D108"
[[ "$(comment_count 108)" -eq 0 ]] || fail "Discussion が閉じたのに、OpenCode のループのコメントを消していない"
cp "$WORK/plugin-settings.before" "$HOME/.claude/settings.json"
ok "OpenCode が失敗し続けると state を残して止まり、resume で続きから回して見張り役が最終 PR を作る"

# ループが完了語を出さずに終わったとき（モデル自身が state を消したときなど）は、途中のメッセージの promise が
# あっても最終 PR を作らない（見張り役はログの promise で最終 PR を作るか決めるため）
manual start 109 epic/opencode-three >/dev/null 2>&1 || fail "3 つ目の OpenCode 用の手動ループを start できない"
D109="$WORK/repos/myapp-ralph-d109-ctl"
perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$D109/.claude/ralph-playbook.local.md"
printf '# ゴール\n\n- [ ] 【FEAT】OpenCode の途中の promise テスト | label: enhancement\n' > "$D109/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
: > "$WORK/opencode.log"
OUT=$(ASKHUB_AGENT=opencode ASKHUB_OPENCODE_MAX_FAILS=3 ASKHUB_OPENCODE_FAIL_SLEEP=0 \
  STUB_OPENCODE_STRAY=1 STUB_OPENCODE_LOG="$WORK/opencode.log" manual launch 109 "SMOKE DONE") || fail "OpenCode の launch が失敗した: $OUT"
LOG_109=$(loop_log "$D109")
wait_watch "$LOG_109"
grep -q 'state ファイルが消えています' "$LOG_109" || fail "state が消えたのに周回をやめていない: $(cat "$LOG_109")"
grep -q '注意: promise は出ていますが、最後のメッセージではありません' "$LOG_109" || fail "最後のメッセージ以外の promise に気づいていない: $(cat "$LOG_109")"
! grep -qF '<promise>SMOKE DONE</promise>' "$LOG_109" || fail "途中のメッセージの promise が、そのままログに残っている（見張り役が誤って最終 PR を作る）: $(grep -nF 'promise' "$LOG_109")"
grep -qF '<promise:log>SMOKE DONE</promise>' "$LOG_109" || fail "途中のメッセージの promise を、ログではタグを崩して書いていない"
grep -q '完了語を出さずに終わった' "$LOG_109" || fail "見張り役が、完了語を出さずに終わったループとして扱っていない: $(cat "$LOG_109")"
grep -q '^pr create' "$WORK/gh.log" && fail "完了語を出さずに終わったのに、最終 PR を作った"
[[ ! -e "$D109/.claude/ralph-loop.local.md" ]] || fail "state を消したのに残っている"
touch "$GH_STATE/closed-109"
wait_watch_exit "$D109"
[[ "$(comment_count 109)" -eq 0 ]] || fail "Discussion が閉じたのに、OpenCode のループのコメントを消していない"
ok "ループが完了語を出さずに終わったときは、途中のメッセージの promise がログにあっても、見張り役は最終 PR を作らない"

# ASKHUB_AGENT の値が分からないときは起動せずに断る（書き間違いで Claude のループを起動しない）
if ASKHUB_AGENT=bogus manual launch 108 "SMOKE DONE" >"$WORK/bogus.out" 2>&1; then fail "ASKHUB_AGENT の知らない値で起動した"; fi
grep -q 'ASKHUB_AGENT の値が分かりません' "$WORK/bogus.out" || fail "ASKHUB_AGENT の知らない値を知らせていない: $(cat "$WORK/bogus.out")"
unset ASKHUB_AGENT
ok "ASKHUB_AGENT の知らない値では起動しない"

# ---- Claude の利用上限のメッセージの読み方（bin/usage-limit.sh）---------------------------------
# オーケストレーター（ask-hub-apple の UsageLimit.swift）と同じく、ログの末尾 5 行の上限のメッセージから解除の時刻を読む。
# ログの更新時刻は 2026-10-06T10:00:00Z（日本時間の 19:00）にする
USAGE_LIMIT="$(cd "$APP" && scripts/ralph-kit.sh path)/bin/usage-limit.sh"
expect_reset() { # $1=期待する解除の時刻（上限のメッセージが無ければ none） $2=ログの末尾 $3=この Mac の TZ（既定 UTC）
  local actual
  printf 'ループの出力\n%s\n' "$2" > "$WORK/limit.log"
  TZ=UTC touch -t 202610061000.00 "$WORK/limit.log"
  actual=$(TZ="${3:-UTC}" "$USAGE_LIMIT" "$WORK/limit.log") || actual=none
  [[ "$actual" == "$1" ]] || fail "「${2}」の解除の時刻が ${1} ではない（${actual}）"
}
expect_reset 1791342000 "You've hit your session limit · resets 12pm (Asia/Tokyo)"   # 翌日の 12:00（日本時間）
expect_reset 1791284400 "You've hit your session limit · resets 8pm (Asia/Tokyo)"    # 同じ日の 20:00（日本時間）
expect_reset 1791505800 "You've hit your weekly limit · resets Oct 9, 9:30am (Asia/Tokyo)"
expect_reset 1791298800 "You've hit your session limit · resets 3pm"                 # タイムゾーンが無ければ、この Mac の TZ
expect_reset 1791352800 "You've hit your session limit · resets 3pm" Asia/Tokyo
expect_reset 1791298800 "You've hit your session limit · resets 3pm (Mars/Base)"     # 知らないタイムゾーンも、この Mac の TZ
expect_reset 1791288000 "Claude AI usage limit reached|1791288000"
expect_reset 1791284400 "Claude AI usage limit reached|1791288000000"                # 8 日より先（ミリ秒など）は 1 時間後
expect_reset 1791284400 "Claude AI usage limit reached|1791277200"                   # ログより前の時刻も 1 時間後
expect_reset 1791284400 "You've hit your session limit · resets soon"                # 時刻を読めなければ 1 時間後
expect_reset none "API Error: Connection refused"
expect_reset none "$(printf "You've hit your session limit · resets 12pm (Asia/Tokyo)\n1\n2\n3\n4\n5")"  # 末尾 5 行より前は見ない
ok "Claude の利用上限のメッセージから、オーケストレーターと同じく解除の時刻を読む"

# ---- Claude の利用上限で止まった手動ループの再開 ------------------------------------------------
# 見張り役は、ループのログの末尾に Claude の利用上限のメッセージがあれば、ループの状態を「上限で待機中」（解除の時刻つき）で書き、
# 解除の時刻を過ぎたら resume で再開する。再開したループの見張り役が、いつもどおり最終 PR を作る
limit_loop() { # $1=Discussion の番号 $2=epic。start して playbook と goal を用意する
  local ctl="$WORK/repos/myapp-ralph-d$1-ctl"
  manual start "$1" "$2" >/dev/null 2>&1 || fail "Discussion $1 の手動ループを start できない"
  perl -pi -e 's/\{\{[A-Z_]+\}\}/X/g' "$ctl/.claude/ralph-playbook.local.md"
  printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$ctl/.claude/ralph-goal.local.md"
}
comment_body() { # Discussion $1 の手動ループのコメントの本文
  local d
  for d in "$GH_STATE/comments"/*; do
    [[ -f "$d/body" ]] || continue
    if head -n 1 "$d/body" | grep -F "\"discussion\":$1," | grep -qF '"writer":"manual"'; then cat "$d/body"; fi
  done
}
limit_launch() { # $1=Discussion の番号 $2=解除までの秒数 $3=ASKHUB_AUTO_RESUME（既定 1）。1 回目は利用上限で止まるループを起動する
  local n="$1" wait="$2" auto="${3:-1}"
  (
    export STUB_LOOP=limit-once STUB_LIMIT_MARK="$WORK/limit-hit-$n" STUB_LIMIT_WAIT="$wait" \
      ASKHUB_USAGE_LIMIT_INTERVAL=1 ASKHUB_USAGE_LIMIT_MARGIN=0 ASKHUB_AUTO_RESUME="$auto"
    manual launch "$n" "SMOKE DONE" >/dev/null
  ) || fail "Discussion $n の launch が失敗した"
}
D110="$WORK/repos/myapp-ralph-d110-ctl"
limit_loop 110 epic/manual-ten
: > "$WORK/gh.log"
limit_launch 110 6
LOG_110=$(loop_log "$D110")
wait_for comment_has 110 '"state":"usage-limited"' || fail "利用上限で止まったのに、ループの状態を上限で待機中にしていない: $(loop_comments 110) $(cat "$LOG_110")"
comment_has 110 '"usageLimitedUntil":"' || fail "上限で待機中の状態に、解除の時刻を書いていない: $(loop_comments 110)"
comment_body 110 | grep -q '^| 上限の解除 | ' || fail "コメントの表に、上限の解除の時刻を書いていない: $(comment_body 110)"
grep -q '利用上限で止まりました' "$LOG_110" || fail "利用上限で止まったことを、ループのログに書いていない: $(cat "$LOG_110")"
grep -q '^usage_limited_until=' "$D110/.claude/askhub-manual.local.txt" || fail "解除の時刻を記録していない"
wait_for eval '[[ "$(loop_log "$D110")" != "$LOG_110" ]]' || fail "解除の時刻を過ぎても、ループを再開していない: $(cat "$LOG_110")"
grep -q '解除の時刻を過ぎたので、ループを再開します' "$LOG_110" || fail "再開したことを、止まったループのログに書いていない"
wait_watch "$(loop_log "$D110")"
grep -q -- '^pr create .*--head epic/manual-ten' "$WORK/gh.log" || fail "再開したループの見張り役が、最終 PR を作っていない: $(cat "$(loop_log "$D110")")"
grep -q '^usage_limited_until=' "$D110/.claude/askhub-manual.local.txt" && fail "再開したのに、解除の時刻の記録が残っている"
wait_for comment_has 110 '"state":"completed"' || fail "再開したループが終わった後に、ループの状態を完了にしていない: $(loop_comments 110)"
comment_has 110 'usageLimitedUntil' && fail "完了したのに、解除の時刻が残っている"
touch "$GH_STATE/closed-110"
wait_watch_exit "$D110"
ok "ループが Claude の利用上限で止まったら、見張り役が上限で待機中と書き、解除の時刻の後に再開する"

# 解除を待っている間に担当者が resume したら、待っていた見張り役は何もせずに終わり、新しいループの見張り役に任せる
D111="$WORK/repos/myapp-ralph-d111-ctl"
limit_loop 111 epic/manual-eleven
: > "$WORK/gh.log"
limit_launch 111 600
LOG_111=$(loop_log "$D111")
wait_for comment_has 111 '"state":"usage-limited"' || fail "利用上限で止まったのに、上限で待機中にしていない: $(cat "$LOG_111")"
STUB_LOOP=promise manual resume 111 >/dev/null || fail "解除を待っている間の resume が失敗した"
grep -q '^usage_limited_until=' "$D111/.claude/askhub-manual.local.txt" && fail "resume で起動し直したのに、解除の時刻の記録が残っている"
wait_for grep -q '別のループが起動しているため、自動では再開しません' "$LOG_111" || fail "resume したのに、待っていた見張り役が終わらない: $(cat "$LOG_111")"
wait_watch "$(loop_log "$D111")"
grep -q -- '^pr create .*--head epic/manual-eleven' "$WORK/gh.log" || fail "resume したループの見張り役が、最終 PR を作っていない"
touch "$GH_STATE/closed-111"
wait_watch_exit "$D111"
ok "解除を待っている間に resume したら、待っていた見張り役は自動では再開しない"

# 解除を待っている間に ralph-stop.sh で止めたら、自動では再開しない（ループの状態は開始待ちに戻す）
D112="$WORK/repos/myapp-ralph-d112-ctl"
limit_loop 112 epic/manual-twelve
limit_launch 112 600
LOG_112=$(loop_log "$D112")
wait_for comment_has 112 '"state":"usage-limited"' || fail "利用上限で止まったのに、上限で待機中にしていない: $(cat "$LOG_112")"
# 担当者の resume が state をよけて権限モードを確かめている間（.probe）は、止めたとみなさない
mv "$D112/.claude/ralph-loop.local.md" "$D112/.claude/ralph-loop.local.md.probe"
sleep 3
grep -q 'ループが止められた' "$LOG_112" && fail "resume が state をよけている間に、ループが止められたとみなした: $(cat "$LOG_112")"
mv "$D112/.claude/ralph-loop.local.md.probe" "$D112/.claude/ralph-loop.local.md"
(cd "$D112" && scripts/ralph-stop.sh >/dev/null)
wait_for grep -q 'ループが止められた' "$LOG_112" || fail "ralph-stop.sh で止めたのに、見張り役が待ち続けている: $(cat "$LOG_112")"
wait_for comment_has 112 '"state":"waiting-to-start"' || fail "止めた後に、ループの状態を開始待ちにしていない: $(loop_comments 112)"
grep -q '^usage_limited_until=' "$D112/.claude/askhub-manual.local.txt" && fail "止めたのに、解除の時刻の記録が残っている"
[[ "$(loop_log "$D112")" == "$LOG_112" ]] || fail "ralph-stop.sh で止めたのに、ループを再開した"
touch "$GH_STATE/closed-112"
wait_watch_exit "$D112"
ok "解除を待っている間に ralph-stop.sh で止めたら、自動では再開しない（resume が state をよけている間は、止めたとみなさない）"

# ASKHUB_AUTO_RESUME=0 なら、利用上限で止まったことをログに書くだけで再開しない
D113="$WORK/repos/myapp-ralph-d113-ctl"
limit_loop 113 epic/manual-thirteen
limit_launch 113 1 0
LOG_113=$(loop_log "$D113")
wait_for grep -q 'ASKHUB_AUTO_RESUME=0 のため、自動では再開しません' "$LOG_113" || fail "ASKHUB_AUTO_RESUME=0 で再開しないことを、ログに書いていない: $(cat "$LOG_113")"
sleep 3
[[ "$(loop_log "$D113")" == "$LOG_113" ]] || fail "ASKHUB_AUTO_RESUME=0 なのに再開した"
grep -q '^usage_limited_until=' "$D113/.claude/askhub-manual.local.txt" && fail "ASKHUB_AUTO_RESUME=0 なのに、解除の時刻を記録した"
touch "$GH_STATE/closed-113"
wait_watch_exit "$D113"
ok "ASKHUB_AUTO_RESUME=0 なら、利用上限で止まっても再開しない"

# ---- 回答待ちの PR を残して終わった手動ループの、ask の回答による再開 ----------------------------------
# ループが回答待ちの PR を残して promise を出して終わったら、見張り役は最終 PR を作った後、goal の ※回答待ち の ask に
# 信用する author の返信が付くのを待ち、付いたら resume で再開する（信用しない author の返信・ほかのコメントへの返信では再開しない）。
# 再開したループがまた完了したら、final は既にある open な最終 PR を作り直さず、本文を今の内容で書き直す
answer_launch() { # $1=Discussion の番号 $2=PR の番号 $3=ask の id $4=ASKHUB_AUTO_RESUME（既定 1）。1 回目は回答待ちの PR を残して終わるループを起動する
  local n="$1" auto="${4:-1}"
  (
    export STUB_LOOP=answer-once STUB_ANSWER_MARK="$WORK/answer-asked-$n" STUB_ANSWER_PR="$2" STUB_ANSWER_ID="$3" ASKHUB_AUTO_RESUME="$auto"
    manual launch "$n" "SMOKE DONE" >/dev/null
  ) || fail "Discussion $n の launch が失敗した"
}
D114="$WORK/repos/myapp-ralph-d114-ctl"
limit_loop 114 epic/manual-fourteen
: > "$WORK/gh.log"
answer_launch 114 7 70
LOG_114=$(loop_log "$D114")
wait_watch "$LOG_114"
grep -q -- '^pr create .*--head epic/manual-fourteen' "$WORK/gh.log" || fail "回答待ちの PR を残して終わったのに、最終 PR を作っていない: $(cat "$LOG_114")"
wait_for comment_has 114 '"state":"waiting-for-answer"' || fail "回答待ちの PR を残して終わったのに、ループの状態を回答待ちにしていない: $(loop_comments 114)"
# 最終 PR ができた（以降の final は、既にある open な PR として扱う）
mkdir -p "$GH_STATE/final-pr" "$GH_STATE/pulls"
echo '[{"url":"https://github.com/example/myapp-ios/pull/99","state":"OPEN"}]' > "$GH_STATE/final-pr/epic_manual-fourteen"
echo '[{"id":70,"in_reply_to_id":null,"user":{"login":"test"},"body":"ask"},
  {"id":71,"in_reply_to_id":70,"user":{"login":"stranger"},"body":"回答: A"},
  {"id":72,"in_reply_to_id":69,"user":{"login":"test"},"body":"回答: B"}]' > "$GH_STATE/pulls/7.json"
sleep 4
[[ "$(loop_log "$D114")" == "$LOG_114" ]] || fail "信用しない author の返信か、ほかのコメントへの返信で再開した: $(cat "$LOG_114")"
[[ ! -e "$D114/.claude/askhub-launch.local.txt" ]] || fail "launch が終わったのに、起動ロックが残っている"
# 起動ロックを持つ人（担当者の launch / resume）がいる間は、回答が付いても再開しない。担当者の resume も、ロックを取れなければ断る
sleep 600 &
HOLDER=$!
echo "$HOLDER" > "$D114/.claude/askhub-launch.local.txt"
echo '[{"id":70,"in_reply_to_id":null,"user":{"login":"test"},"body":"ask"},
  {"id":73,"in_reply_to_id":70,"user":{"login":"test"},"body":"回答: A"}]' > "$GH_STATE/pulls/7.json"
if manual resume 114 >"$WORK/locked.out" 2>&1; then fail "起動ロックを取れないのに、resume が起動した"; fi
grep -q '起動している最中です' "$WORK/locked.out" || fail "起動ロックを取れないことを知らせていない: $(cat "$WORK/locked.out")"
sleep 4
[[ "$(loop_log "$D114")" == "$LOG_114" ]] || fail "起動ロックを持つ人がいるのに、回答で再開した: $(cat "$LOG_114")"
# 持ち主が終わったロック（fail で抜けた・強制終了された）は、捨てて取り直す
kill "$HOLDER"
wait "$HOLDER" 2>/dev/null || true
wait_for eval '[[ "$(loop_log "$D114")" != "$LOG_114" ]]' || fail "ask に回答が付いても、ループを再開していない: $(cat "$LOG_114")"
grep -q '回答待ちの PR（#7）の ask に回答が付いたので、ループを再開します' "$LOG_114" || fail "回答で再開したことを、終わったループのログに書いていない: $(cat "$LOG_114")"
grep -q '^resumed_asks=70$' "$D114/.claude/askhub-manual.local.txt" || fail "再開に使った ask の id を記録していない"
wait_for eval '[[ ! -e "$D114/.claude/askhub-launch.local.txt" ]]' || fail "回答で再開した後も、起動ロックが残っている"
LOG_114B=$(loop_log "$D114")
wait_watch "$LOG_114B"
grep -q -- '^pr edit https://github.com/example/myapp-ios/pull/99 ' "$WORK/gh.log" || fail "再開したループが完了したのに、最終 PR の本文を書き直していない: $(cat "$LOG_114B")"
grep -q '回答を受けて直したこと' "$WORK/gh.log" || fail "書き直した本文に、再開したループの「最終 PR に載せる内容」が無い"
[[ "$(grep -c '^pr create' "$WORK/gh.log")" -eq 1 ]] || fail "最終 PR が既にあるのに、作り直した"
grep -q '^final_refresh=' "$D114/.claude/askhub-manual.local.txt" && fail "本文を書き直した後も、書き直しの印が残っている"
wait_for comment_has 114 '"state":"completed"' || fail "再開したループが完了した後に、ループの状態を完了にしていない: $(loop_comments 114)"
# 再開に使った回答では、もう一度は再開しない（ループが印を外さずに終わったときに、起動を繰り返さない）
perl -pi -e 's/^- \[x\] (.*)$/- [ ] $1  ※回答待ち（PR #7 \/ ask id 70）/' "$D114/.claude/ralph-goal.local.md"
sleep 4
[[ "$(loop_log "$D114")" == "$LOG_114B" ]] || fail "再開に使った回答で、もう一度再開した"
touch "$GH_STATE/closed-114"
wait_watch_exit "$D114"
ok "回答待ちの PR を残して終わった手動ループは、ask に信用する author の回答が付いたら再開し、完了したら最終 PR の本文を書き直す"

# ASKHUB_AUTO_RESUME=0 なら、回答が付いても再開しない（回答待ちの PR があることをログに書くだけ）
D115="$WORK/repos/myapp-ralph-d115-ctl"
limit_loop 115 epic/manual-fifteen
answer_launch 115 8 80 0
LOG_115=$(loop_log "$D115")
wait_watch "$LOG_115"
wait_for grep -q 'ASKHUB_AUTO_RESUME=0 のため、回答が付いても自動では再開しません' "$LOG_115" || fail "ASKHUB_AUTO_RESUME=0 で回答では再開しないことを、ログに書いていない: $(cat "$LOG_115")"
echo '[{"id":81,"in_reply_to_id":80,"user":{"login":"test"},"body":"回答: A"}]' > "$GH_STATE/pulls/8.json"
sleep 3
[[ "$(loop_log "$D115")" == "$LOG_115" ]] || fail "ASKHUB_AUTO_RESUME=0 なのに、回答で再開した"
touch "$GH_STATE/closed-115"
wait_watch_exit "$D115"
rm -f "$GH_STATE/needs-answer/8"
ok "ASKHUB_AUTO_RESUME=0 なら、回答待ちの PR に回答が付いても再開しない"

# askhub-manual.sh は中継から呼べる（引数なしは使い方を出して 64 で終わる）
set +e
(cd "$APP" && scripts/askhub-manual.sh >/dev/null 2>&1)
STATUS=$?
set -e
[[ "$STATUS" -eq 64 ]] || fail "askhub-manual.sh の引数なしが 64 で終わらない（${STATUS}）"
ok "askhub-manual.sh を中継から呼べる"

echo
echo "すべて通りました（${PASSED} 件）"
