#!/bin/bash
# 手動ループ（ralph-loop）を OpenCode で周回させる。askhub-manual.sh launch / resume から呼ばれる。
#   usage: bin/opencode-loop.sh <完了語>
#
# 位置づけ:
#   既定（ASKHUB_AGENT=claude）では launch が制御用 worktree で claude -p を起動し、
#   ralph-loop プラグインの Stop hook が state ファイルを見ながら周回させる。
#   ASKHUB_AGENT=opencode のときは、launch が代わりにこのスクリプトを起動する。
#   毎周 state ファイル（.claude/ralph-loop.local.md）を読み直し、制御用 worktree で
#   opencode run を回して、最後のメッセージで <promise>完了語</promise> を検知したら
#   state を消して終わる。Claude のときと同じ結果になるので、見張り役（watch-final）・
#   final・status・ralph-stop.sh は無改修でそのまま動く。
#
# 前提:
#   state・playbook・goal は ralph-start.sh（launch が呼ぶ）が作ったもの。制御用 worktree で実行し、
#   標準出力をログ（launch が起動したときは ~/Library/Logs/askhub/manual/…-loop-*.log）に書く。
#
# 環境変数:
#   ASKHUB_OPENCODE            opencode の実行ファイル（既定: PATH → /Applications/OpenCode.app/Contents/Resources/opencode-cli）
#   ASKHUB_OPENCODE_MODEL      使うモデル（例: opencode/deepseek-v4.1-flash-free。省略時は OpenCode の既定）
#   ASKHUB_OPENCODE_MAX_FAILS  連続失敗で止まるまでの回数（既定 5。0 は不可）
#   ASKHUB_OPENCODE_FAIL_SLEEP 失敗 1 回あたりの待ち秒の基数（既定 15。n 回目の失敗で n×この秒だけ待つ）
set -uo pipefail

# Git hook や wrapper から継承した経路変数が別のチェックアウトを指すことがある
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

fail() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

PROMISE="${1:-}"
[[ $# -le 1 && -n "$PROMISE" ]] || usage
command -v jq >/dev/null 2>&1 || fail "jq が見つかりません（brew install jq で入れてください）"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "git リポジトリの中で実行してください"
cd "$ROOT" || exit 1
STATE=".claude/ralph-loop.local.md"
[[ -f "$STATE" ]] || fail "state ファイルがありません（先に scripts/askhub-manual.sh launch を実行してください）: $ROOT/$STATE"

# 完了語は state と一致していること（食い違うと、promise を検知できずに黙って回り続ける）
STATE_PROMISE=$(sed -n 's/^completion_promise: *//p' "$STATE" | tail -1 | sed 's/^"//; s/"$//')
[[ -n "$STATE_PROMISE" ]] || fail "state に完了語（completion_promise）がありません: $STATE"
[[ "$STATE_PROMISE" == "$PROMISE" ]] || fail "完了語が state と一致しません（state: ${STATE_PROMISE} / 指定: ${PROMISE}）"

# ---- opencode の実行ファイル ----------------------------------------------------------------

OC_BIN="${ASKHUB_OPENCODE:-}"
if [[ -z "$OC_BIN" ]]; then
  OC_BIN=$(command -v opencode 2>/dev/null || true)
fi
if [[ -z "$OC_BIN" && -x /Applications/OpenCode.app/Contents/Resources/opencode-cli ]]; then
  OC_BIN=/Applications/OpenCode.app/Contents/Resources/opencode-cli
fi
[[ -n "$OC_BIN" && -x "$OC_BIN" ]] || fail "opencode の実行ファイルが見つかりません。PATH に通すか、ASKHUB_OPENCODE で指定してください（例: ASKHUB_OPENCODE=/Applications/OpenCode.app/Contents/Resources/opencode-cli）"
MODEL="${ASKHUB_OPENCODE_MODEL:-}"

MAX_FAILS="${ASKHUB_OPENCODE_MAX_FAILS:-5}"
FAIL_SLEEP="${ASKHUB_OPENCODE_FAIL_SLEEP:-15}"
[[ "$MAX_FAILS" =~ ^[0-9]+$ && "$MAX_FAILS" -ge 1 ]] || fail "ASKHUB_OPENCODE_MAX_FAILS は 1 以上の整数で指定してください（指定: ${MAX_FAILS}）"
[[ "$FAIL_SLEEP" =~ ^[0-9]+$ ]] || fail "ASKHUB_OPENCODE_FAIL_SLEEP は 0 以上の整数で指定してください（指定: ${FAIL_SLEEP}）"
MAX_FAILS=$((10#$MAX_FAILS))
FAIL_SLEEP=$((10#$FAIL_SLEEP))

# ---- deny 設定（Claude 形式 → OpenCode 形式）-----------------------------------------------

# 制御用 worktree の .claude/settings.json（ralph-setup.sh が置いた deny リスト）を、OpenCode の
# permissions（action/resource/effect。--auto でも deny は常に優先される）に変換して
# .opencode/opencode.json に置く。Claude 版の deny と同じ「多層防御の一段目」。
# 起動のたびに作り直す生成物なので、リポジトリにはコミットしない（共通の git info/exclude に足す）。
setup_deny() {
  local settings="$ROOT/.claude/settings.json" target="$ROOT/.opencode/opencode.json" converted others exclude
  if [[ ! -f "$settings" ]]; then
    warn "$settings がないため deny 設定を作りません（--auto で動くが、多層防御が無い点に注意）"
    return 0
  fi
  if git -C "$ROOT" ls-files --error-unmatch .opencode/opencode.json >/dev/null 2>&1; then
    warn ".opencode/opencode.json はコミット済みのファイルのため触りません"
    return 0
  fi
  converted=$(jq '{
    "$schema": "https://opencode.ai/config.json",
    permissions: ([
      (.permissions.deny // [])[]
      | select(type == "string")
      | if startswith("Bash(") then
          { action: "shell", resource: (sub("^Bash\\("; "") | sub("\\)$"; "") | sub(":\\*$"; " *")), effect: "deny" }
        elif startswith("Read(") then
          { action: "read", resource: (sub("^Read\\("; "") | sub("\\)$"; "")), effect: "deny" }
        elif (startswith("Edit(") or startswith("Write(") or startswith("MultiEdit(")) then
          { action: "edit", resource: (sub("^[A-Za-z]+\\("; "") | sub("\\)$"; "")), effect: "deny" }
        else empty
        end
    ])
  }' "$settings") || { warn "deny リストを変換できませんでした（$settings の形式を確認してください）"; return 0; }
  others=$(jq '[ (.permissions.deny // [])[] | select(type == "string")
      | select((startswith("Bash(") or startswith("Read(") or startswith("Edit(") or startswith("Write(") or startswith("MultiEdit("))) | not) ]
    | length' "$settings" 2>/dev/null || echo 0)
  mkdir -p "$ROOT/.opencode"
  printf '%s\n' "$converted" > "$target"
  exclude="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/info/exclude"
  if [[ -d "${exclude%/*}" ]]; then
    grep -qxF '.opencode/opencode.json' "$exclude" 2>/dev/null || printf '%s\n' '.opencode/opencode.json' >> "$exclude"
  else
    warn "git の exclude ファイルが見つからないため、コミット防止の登録を省略しました: ${exclude}"
  fi
  [[ "$others" -gt 0 ]] && warn "Bash・Read・Edit・Write 以外の deny が ${others} 件あります（OpenCode 版には入れていません。必要なら手で足してください）"
  echo "deny 設定を OpenCode 用に置きました: ${target}（$(jq '.permissions | length' "$target") 件）"
}
setup_deny

# ---- 周回の準備 ------------------------------------------------------------------------------

# 周回中の scripts/askhub-manual.sh status が、起動したときと同じ版の kit を使うように固定する
# （Claude 版の launch が RALPH_KIT_DIR を渡すのと同じ。launch から起動されたときは既に export 済み）
if [[ -z "${RALPH_KIT_DIR:-}" && -x "$ROOT/scripts/ralph-kit.sh" ]]; then
  KIT_DIR=$("$ROOT/scripts/ralph-kit.sh" path 2>/dev/null || true)
  if [[ -n "$KIT_DIR" ]]; then
    export RALPH_KIT_DIR="$KIT_DIR"
  else
    warn "kit の場所を特定できませんでした（周回中の status は、そのときの kit.conf の ref で解決されます）"
  fi
fi

DISCUSSION=$(sed -n 's/^discussion=//p' "$ROOT/.claude/askhub-manual.local.txt" 2>/dev/null | tail -1)
TITLE="ralph-loop（OpenCode）"
if [[ "$DISCUSSION" =~ ^[0-9]+$ ]]; then
  TITLE="ralph d${DISCUSSION}（OpenCode）"
fi

# playbook は Claude Code 向けの記述（Stop hook・Agent ツール）を含む。OpenCode での読み替えを
# プロンプトの先頭に足して渡す（state の本文はそのまま。promise の指示が最後に来るようにする）
NOTE="（このループは Claude Code ではなく OpenCode で回っている。playbook の Claude Code 向けの記述は次で読み替える）
- サブエージェント（B-2a などの「Agent ツール」）は、OpenCode のサブエージェント機能で行う
- シェルの作業ディレクトリはセッションに残る。スロットに cd したままターンを終えないこと（playbook の「絶対禁止」のとおり、git -C かサブシェルで操作する）
- 権限は --auto（明示された deny は常に優先。.claude/settings.json の deny は .opencode/opencode.json に変換済み）"

echo "opencode-loop: ${ROOT}"
echo "  実行ファイル: ${OC_BIN}"
echo "  モデル      : ${MODEL:-OpenCode の既定}"
echo "  完了語      : ${PROMISE}"
echo "  状態        : tail -f でこの出力を追う。止めるには制御用 worktree で scripts/ralph-stop.sh"

OUT=$(mktemp "${TMPDIR:-/tmp}/opencode-loop.XXXXXX.json")
ERR=$(mktemp "${TMPDIR:-/tmp}/opencode-loop.XXXXXX.err")
CURRENT_CHILD=""
trap 'rm -f "$OUT" "$ERR"' EXIT
trap 'echo; echo "中断しました。state を消して止まります（続きから回すには scripts/askhub-manual.sh resume）" >&2; rm -f "$STATE"; kill -TERM "${CURRENT_CHILD:-}" 2>/dev/null || true; exit 130' INT TERM

SID=""
fails=0
iter=0
while :; do
  iter=$((iter + 1))

  # state が消えていたら終わり（ralph-stop.sh・モデルの自己停止）
  if [[ ! -f "$STATE" ]]; then
    echo
    echo "state ファイルが消えています（ralph-stop.sh か、モデルの自己停止）。周回をやめます。"
    exit 0
  fi
  # 上限（Claude 版の Stop hook と同じく、上限に達したら promise なしで止まる）
  MAX=$(sed -n 's/^max_iterations: *//p' "$STATE" | tail -1)
  if [[ "$MAX" =~ ^[0-9]+$ ]] && [[ "$MAX" -gt 0 ]] && [[ "$iter" -gt "$MAX" ]]; then
    echo
    echo "上限 ${MAX} 周に達しました（promise なし）。state を消して終了します。"
    rm -f "$STATE"
    exit 0
  fi

  # Claude 版の Stop hook と同じ見た目になるよう、iteration を更新する
  perl -pi -e "s/^iteration: .*/iteration: $iter/" "$STATE" 2>/dev/null || true

  BODY=$(sed -n '/^---$/,/^---$/!p' "$STATE" | sed '/^$/d')
  PROMPT="${NOTE}

${BODY}"
  started=$(date +%s)
  set -- run --auto --format json
  if [[ -n "$SID" ]]; then
    set -- "$@" --session "$SID"
  else
    set -- "$@" --title "$TITLE"
  fi
  [[ -n "$MODEL" ]] && set -- "$@" --model "$MODEL"
  set -- "$@" "$PROMPT"

  echo
  echo "=== iter ${iter}（$(date '+%F %T')） ==="
  (cd "$ROOT" && exec "$OC_BIN" "$@") >"$OUT" 2>"$ERR" &
  CURRENT_CHILD=$!
  wait "$CURRENT_CHILD"
  status=$?
  CURRENT_CHILD=""
  elapsed=$(( $(date +%s) - started ))

  # ログに残すのは、テキストと、使ったツールの名前だけにする。見張り役（watch-final）はログの
  # <promise>完了語</promise> で最終 PR を作るか決めるので、モデルのメッセージのタグは崩して書く
  # （上限に達したとき・ralph-stop.sh で止めたとき・中断したときも state は消えるため、途中のメッセージの
  # promise がそのままログにあると、誤って最終 PR を作ってしまう）。完了を検知したときだけ、下で完全な形を書く
  jq -r 'if .type == "text" then (.part.text | gsub("<promise>"; "<promise:log>"))
         elif .type == "tool_use" and .part.state.status == "completed" then "[tool] " + (.part.tool // "?")
         else empty end' "$OUT" 2>/dev/null || echo "（opencode の JSON 出力を読み取れませんでした）"
  if [[ -s "$ERR" ]]; then
    printf -- '--- stderr ---\n'
    cat "$ERR"
  fi

  [[ -z "$SID" ]] && SID=$(jq -r 'select(.sessionID != null) | .sessionID' "$OUT" 2>/dev/null | head -1)
  if [[ -n "$SID" ]]; then
    perl -pi -e "s/^session_id:.*/session_id: $SID/" "$STATE" 2>/dev/null || true
  fi

  SUFFIX=""
  [[ -n "$SID" ]] && SUFFIX="、session=${SID}"
  echo "[opencode-loop] iter ${iter}: exit=${status}、${elapsed}秒${SUFFIX}"

  # promise の検知は、最後の assistant メッセージ（最後の text の messageID のものを連結）で行う。
  # 途中の説明に <promise>…</promise> が出てきただけのときに、ループを終えないようにする
  FULL_TEXT=$(jq -r 'select(.type == "text") | .part.text' "$OUT" 2>/dev/null || true)
  LAST_MSG=$(jq -r 'select(.type == "text") | .part.messageID' "$OUT" 2>/dev/null | tail -1)
  if [[ -n "$LAST_MSG" ]]; then
    LAST_TEXT=$(jq -r --arg m "$LAST_MSG" 'select(.type == "text" and .part.messageID == $m) | .part.text' "$OUT" 2>/dev/null || true)
  else
    # messageID が読めない版でも回り続けないよう、全文で判定する
    LAST_TEXT="$FULL_TEXT"
  fi
  if printf '%s' "$LAST_TEXT" | grep -Fq "<promise>$PROMISE</promise>"; then
    rm -f "$STATE"
    echo
    # 見張り役（watch-final）は、ログのこの行で最終 PR を作るか決める（途中のメッセージのタグは崩してある）
    printf '<promise>%s</promise>\n' "$PROMISE"
    echo "完了語を検知しました（${iter} 周）。state を消しました。"
    echo "次: メインの checkout で scripts/askhub-manual.sh final（見張り役が動いていれば自動で作ります）"
    exit 0
  fi
  # 最後のメッセージ以外に出ているときは、取りこぼしに気づけるように警告だけ出す（周回は続ける）
  if [[ "$FULL_TEXT" != "$LAST_TEXT" ]] && printf '%s' "$FULL_TEXT" | grep -Fq "<promise>$PROMISE</promise>"; then
    echo "[opencode-loop] 注意: promise は出ていますが、最後のメッセージではありません（周回を続けます）"
  fi

  if [[ "$status" -ne 0 ]]; then
    fails=$((fails + 1))
    echo "[opencode-loop] opencode が失敗しました（連続 ${fails}/${MAX_FAILS}）。$((fails * FAIL_SLEEP)) 秒待って再試行します"
    sleep $((fails * FAIL_SLEEP))
    if [[ "$fails" -ge "$MAX_FAILS" ]]; then
      echo "連続失敗が ${MAX_FAILS} 回に達したため中止します（state は残しています）。" >&2
      echo "原因を直して scripts/askhub-manual.sh resume で再開するか、制御用 worktree で scripts/ralph-stop.sh で後片付けしてください" >&2
      exit 1
    fi
  else
    fails=0
  fi
done
