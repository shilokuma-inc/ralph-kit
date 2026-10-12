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
trap 'rm -rf "$WORK"' EXIT

PASSED=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; PASSED=$((PASSED + 1)); }

# ---- 環境: 偽の gh・HOME・kit の取得元 ---------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/home/.claude"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
# テスト用の gh。リポジトリの特定・書き込み権限を持つ人・PR の作成だけ値を返し、ほかは成功だけを返す。
# GH_LOG があれば、呼ばれた引数をそこに書き足す
[[ -z "${GH_LOG:-}" ]] || printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "repo view"*) echo "example/myapp-ios" ;;
  "api repos/example/myapp-ios/collaborators"*) echo "test" ;;
  "pr create"*) echo "https://github.com/example/myapp-ios/pull/99" ;;
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

# ---- askhub-manual.sh の見張り役 ------------------------------------------------------------
# launch はループと一緒に見張り役を起動し、ループが promise を出して終わったら final で最終 PR を作る
printf 'repository=example/myapp-ios\ndiscussion=1\nepic=epic/smoke\nbase_branch=develop\nrunner=test\n' > "$CTL/.claude/askhub-manual.local.txt"
manual() { (cd "$APP" && ASKHUB_LOG_DIR="$WORK/logs" ASKHUB_FINAL_WATCH_INTERVAL=1 GH_LOG="$WORK/gh.log" scripts/askhub-manual.sh "$@"); }
loop_log() { sed -n 's/^log=//p' "$CTL/.claude/askhub-manual.local.txt" | tail -n 1; }
wait_watch() { # 見張り役が結果をログに書くまで待つ（最大 30 秒）
  local n=0
  until grep -Eq '最終 PR を作りました|最終 PR は作りません|最終 PR を作れませんでした' "$1" 2>/dev/null; do
    [[ $n -lt 60 ]] || fail "見張り役が結果をログに書かない: $(cat "$1" 2>/dev/null)"
    n=$((n + 1))
    sleep 0.5
  done
}
wait_watch_exit() { # 見張り役が終わるまで待つ（最大 30 秒）。final の後の状態の書き出しと、次の launch が記録ファイルを取り合わないように
  local pid n=0
  pid=$(sed -n 's/^watch_pid=//p' "$CTL/.claude/askhub-manual.local.txt" | tail -n 1)
  [[ "$pid" =~ ^[0-9]+$ ]] || fail "見張り役の PID を記録していない"
  while kill -0 "$pid" 2>/dev/null; do
    [[ $n -lt 60 ]] || fail "見張り役が終わらない（PID ${pid}）"
    n=$((n + 1))
    sleep 0.5
  done
}
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
OUT=$(STUB_LOOP=promise manual launch "SMOKE DONE") || fail "launch が失敗した"
grep -q '最終 PR を自動で作ります' <<<"$OUT" || fail "launch が見張り役を起動したことを知らせていない"
wait_watch "$(loop_log)"
grep -q -- '^pr create .*--base develop --head epic/smoke' "$WORK/gh.log" || fail "見張り役が最終 PR を作っていない: $(cat "$(loop_log)")"
grep -q -- '--label epic-final' "$WORK/gh.log" || fail "最終 PR に epic-final を付けていない"
grep -q 'テストでしたこと' "$WORK/gh.log" || fail "最終 PR に state の「最終 PR に載せる内容」を載せていない"
wait_watch_exit
ok "launch の見張り役が、ループが promise を出して終わったら最終 PR を作る"

# promise を出さずに終わったとき（state ファイルが残る異常終了）は作らない
printf '# ゴール\n\n- [ ] 【FEAT】テスト | label: enhancement\n' > "$CTL/.claude/ralph-goal.local.md"
: > "$WORK/gh.log"
manual launch "SMOKE DONE" >/dev/null || fail "2 回目の launch が失敗した"
wait_watch "$(loop_log)"
grep -q '^pr create' "$WORK/gh.log" && fail "異常終了したのに最終 PR を作った"
grep -q '完了語を出さずに終わった' "$(loop_log)" || fail "最終 PR を作らない理由をログに書いていない"
wait_watch_exit
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
OUT=$(ASKHUB_AUTO_FINAL=0 manual launch "SMOKE DONE") || fail "ASKHUB_AUTO_FINAL=0 の launch が失敗した"
grep -q '自動では作りません' <<<"$OUT" || fail "ASKHUB_AUTO_FINAL=0 で見張り役を起動しないことを知らせていない"
until ! kill -0 "$(cat "$CTL/.claude/askhub-loop.pid")" 2>/dev/null; do sleep 0.5; done
(cd "$CTL" && ../myapp-ios/scripts/ralph-stop.sh >/dev/null)
ok "promise を出さずに終わったときと ASKHUB_AUTO_FINAL=0 のときは、最終 PR を作らない"

# askhub-manual.sh は中継から呼べる（引数なしは使い方を出して 64 で終わる）
set +e
(cd "$APP" && scripts/askhub-manual.sh >/dev/null 2>&1)
STATUS=$?
set -e
[[ "$STATUS" -eq 64 ]] || fail "askhub-manual.sh の引数なしが 64 で終わらない（${STATUS}）"
ok "askhub-manual.sh を中継から呼べる"

echo
echo "すべて通りました（${PASSED} 件）"
