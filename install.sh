#!/bin/bash
# アプリのリポジトリに ralph-kit の中継を置く（導入・移行）。kit の checkout から実行する。
#   usage: ./install.sh [--check] <リポジトリの checkout>
#
# 置くもの（kit の shim/ と同じ内容。既にあれば上書きする）:
#   scripts/ralph-kit.sh と、ralph-setup.sh・ralph-start.sh・ralph-stop.sh・askhub-manual.sh の中継
#   .claude/ralph/README.md（kit への案内）・.github/workflows/close-goal-discussion.yml（kit のワークフローの呼び出し）
#   .claude/ralph/kit.conf（無いときだけ置く。あれば ref をそのまま残す）
# 消すもの（kit に移った雛形）: .claude/ralph/ の playbook.template.md・goal.template.md・state.template.md・
#   settings.deny.example.json・CLAUDE.snippet.md
# CLAUDE.md: ralph-kit:snippet の begin と end の目印があれば、その間を kit の templates/CLAUDE.snippet.md の内容に書き換える。
#   目印が無ければ書き換えず、手で置き換えるよう表示する（このリポジトリだけの書き足しを消さないため）
# コミットはしない。差分を確かめてから、リポジトリの規約でコミットする。
# --check: 何も書き換えずに、kit とずれているものを表示する。ずれがあれば終了コード 1 で終わる
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

fail() { echo "error: $*" >&2; exit 1; }

KIT=$(cd "$(dirname "$0")" && pwd -P)
CHECK=false
if [[ "${1:-}" == --check ]]; then
  CHECK=true
  shift
fi
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { sed -n '3p' "$0" | sed 's/^# //' >&2; exit 64; }
[[ -d "$TARGET" ]] || fail "ディレクトリがありません: $TARGET"
TARGET=$(cd "$TARGET" && git rev-parse --show-toplevel 2>/dev/null) || fail "git の checkout ではありません: $TARGET"
[[ "$TARGET" != "$KIT" ]] || fail "kit そのものには入れられません"

SHIMS=(
  scripts/ralph-kit.sh
  scripts/ralph-setup.sh
  scripts/ralph-start.sh
  scripts/ralph-stop.sh
  scripts/askhub-manual.sh
  .claude/ralph/README.md
  .github/workflows/close-goal-discussion.yml
)
OBSOLETE=(
  .claude/ralph/playbook.template.md
  .claude/ralph/goal.template.md
  .claude/ralph/state.template.md
  .claude/ralph/settings.deny.example.json
  .claude/ralph/CLAUDE.snippet.md
)
DRIFT=0
report() {
  echo "$*"
  DRIFT=1
}

for f in "${SHIMS[@]}"; do
  if cmp -s "$KIT/shim/$f" "$TARGET/$f" && { [[ "$f" != *.sh ]] || [[ -x "$TARGET/$f" ]]; }; then
    continue
  fi
  if $CHECK; then
    report "kit と違います: $f"
    continue
  fi
  mkdir -p "$(dirname "$TARGET/$f")"
  cp "$KIT/shim/$f" "$TARGET/$f"
  if [[ "$f" == *.sh ]]; then chmod +x "$TARGET/$f"; fi
  echo "置きました: $f"
done

CONF=.claude/ralph/kit.conf
if [[ ! -f "$TARGET/$CONF" ]]; then
  if $CHECK; then
    report "ありません: $CONF"
  else
    mkdir -p "$TARGET/.claude/ralph"
    cp "$KIT/shim/$CONF" "$TARGET/$CONF"
    echo "置きました: $CONF"
  fi
fi

for f in "${OBSOLETE[@]}"; do
  [[ -e "$TARGET/$f" ]] || continue
  if $CHECK; then
    report "kit に移ったので要りません: $f"
    continue
  fi
  if git -C "$TARGET" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    git -C "$TARGET" rm -q -- "$f"
  else
    rm -f "$TARGET/$f"
  fi
  echo "消しました: $f"
done

# CLAUDE.md の ralph-loop の節。目印の間だけを kit の内容にそろえる
BEGIN='<!-- ralph-kit:snippet begin'
END='<!-- ralph-kit:snippet end -->'
CLAUDE_MD="$TARGET/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]] || ! grep -qxF '## ralph-loop による自律開発' "$CLAUDE_MD"; then
  report "CLAUDE.md に「## ralph-loop による自律開発」の節がありません。$KIT/templates/CLAUDE.snippet.md の内容を追記してください"
else
  begins=$(grep -c -F "$BEGIN" "$CLAUDE_MD" || true)
  ends=$(grep -c -xF "$END" "$CLAUDE_MD" || true)
  if [[ "$begins" -eq 0 && "$ends" -eq 0 ]]; then
    report "CLAUDE.md の ralph-loop の節に ralph-kit:snippet の目印がありません。節の本文を $KIT/templates/CLAUDE.snippet.md の目印の範囲に置き換え、このリポジトリだけの注意は end の後に移してください"
  elif [[ "$begins" -ne 1 || "$ends" -ne 1 ]] \
    || [[ $(grep -n -F "$BEGIN" "$CLAUDE_MD" | cut -d: -f1) -gt $(grep -n -xF "$END" "$CLAUDE_MD" | cut -d: -f1) ]]; then
    fail "CLAUDE.md の ralph-kit:snippet の目印は、begin・end の順に 1 つずつ置いてください"
  else
    block=$(mktemp)
    updated=$(mktemp)
    trap 'rm -f "$block" "$updated"' EXIT
    awk -v begin="$BEGIN" -v end="$END" 'index($0, begin) == 1 { f = 1 } f { print } $0 == end { f = 0 }' \
      "$KIT/templates/CLAUDE.snippet.md" > "$block"
    # 目印の行から end の行までを、kit の同じ範囲に置き換える（ほかの行はそのまま残す）
    awk -v begin="$BEGIN" -v end="$END" '
      FNR == NR { lines[++n] = $0; next }
      index($0, begin) == 1 { for (i = 1; i <= n; i++) print lines[i]; skip = 1; next }
      skip && $0 == end { skip = 0; next }
      !skip { print }
    ' "$block" "$CLAUDE_MD" > "$updated"
    if ! cmp -s "$updated" "$CLAUDE_MD"; then
      if $CHECK; then
        report "CLAUDE.md の ralph-kit:snippet の範囲が kit と違います"
      else
        cat "$updated" > "$CLAUDE_MD"
        echo "書き換えました: CLAUDE.md の ralph-kit:snippet の範囲"
      fi
    fi
  fi
fi

if $CHECK; then
  if [[ "$DRIFT" -eq 0 ]]; then echo "kit とそろっています"; fi
  exit "$DRIFT"
fi
echo
echo "差分を確かめてからコミットしてください（git -C \"$TARGET\" status）"
