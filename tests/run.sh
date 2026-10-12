#!/bin/bash
# kit のスモークテスト。一時ディレクトリに架空のアプリのリポジトリ（origin つき）を作り、
# install.sh → 中継（scripts/ralph-kit.sh）経由の ralph-setup → ralph-start → ralph-stop を通しで流す。
#   usage: tests/run.sh
# 中継は kit をコミットから取得するので、テストするのは HEAD のコミット（作業ツリーの未コミットの変更は含まない）。
# gh は偽物に差し替え、GitHub には触らない。macOS の /bin/bash（3.2）でも流すこと。
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASSED=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; PASSED=$((PASSED + 1)); }

# ---- 環境: 偽の gh・HOME・kit の取得元 ---------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/home/.claude"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
# テスト用の gh。リポジトリの特定とラベルの作成だけ成功を返す
case "$*" in
  "repo view"*) echo "example/myapp-ios" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$WORK/bin/gh"
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

[[ "$(RALPH_KIT_REF=next "$APP/scripts/ralph-kit.sh" version)" == "next $NEXT_SHA" ]] || fail "RALPH_KIT_REF でブランチを指定できない"
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

# askhub-manual.sh は中継から呼べる（引数なしは使い方を出して 64 で終わる）
set +e
(cd "$APP" && scripts/askhub-manual.sh >/dev/null 2>&1)
STATUS=$?
set -e
[[ "$STATUS" -eq 64 ]] || fail "askhub-manual.sh の引数なしが 64 で終わらない（${STATUS}）"
ok "askhub-manual.sh を中継から呼べる"

echo
echo "すべて通りました（${PASSED} 件）"
