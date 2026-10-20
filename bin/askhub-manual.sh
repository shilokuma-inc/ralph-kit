#!/bin/bash
# 手動ループ（manual-loop）を、担当者の Mac と Claude アカウントで回すための補助スクリプト。
#   usage: scripts/askhub-manual.sh start <Discussion 番号> <epic/機能名>
#          scripts/askhub-manual.sh launch [<Discussion 番号>] <完了語>
#          scripts/askhub-manual.sh status [<Discussion 番号>] [--stopping]
#          scripts/askhub-manual.sh resume [<Discussion 番号>]
#          scripts/askhub-manual.sh final [<Discussion 番号>]
#          scripts/askhub-manual.sh end [<Discussion 番号>]
#
# 作業場所は Discussion ごとに分ける。同じリポジトリの手動ループを、同じ Mac でも並べて回せる（ask-hub-apple の Discussion #425）:
#   制御用 worktree は <名前>-ralph-d<番号>-ctl、スロットは <名前>-ralph-d<番号>-a / -b（<名前> はメインの checkout のディレクトリ名から -ios を除いたもの）。
#   オーケストレーターの自動ループの <名前>-ralph-ctl には触らない。
#   Discussion の番号を省くと、制御用 worktree・スロットの中ではそのループを、ほかの場所ではこの Mac の手動ループが 1 つだけならそれを使う。
#   kit 1.3 までに <名前>-ralph-ctl で始めた手動ループは、移さずにその場所のまま最後まで回す
#
# 流れ（担当者の Claude Code が、AskHub からコピーした指示を受けて行う）:
#   1. start:  担当者が自分か確かめ、ralph-setup.sh で制御用 worktree とスロットを作り、epic を origin に push してから ready-for-loop を外す。
#              信用する author（このリポジトリに書き込み権限を持つ人）を表示し、ループの状態を「開始待ち」で書く
#   2. （Claude が playbook の {{...}} を埋め、STEP A に沿って goal を作る）
#   3. launch: 完了語を記録し、ralph-start.sh で state を作り、制御用 worktree でループをバックグラウンドで起動する。
#              既定は claude -p（bypassPermissions で起動する。MDM などで禁止された Mac では auto モード。どちらも使えなければ起動しない）。
#              ASKHUB_AGENT=opencode のときは bin/opencode-loop.sh（opencode run --auto）で起動する（README の「OpenCode で回す」を参照）
#              あわせて見張り役（watch-final）を裏で起動し、ループが完了語を出して終わったら final を流す（ASKHUB_AUTO_FINAL=0 なら流さない）。
#              ループが Claude の利用上限で止まったら、見張り役が解除の時刻まで待って resume で再開する（ASKHUB_AUTO_RESUME=0 なら再開しない）。
#              回答待ちの PR を残して終わったら、見張り役が ask の回答を待ち、回答が付いたら resume で再開する（ASKHUB_AUTO_RESUME=0 なら再開しない）
#   4. status: ループの状態を、状態用の Issue のこのループのコメントに、書き手 manual・回している人つきで書く（playbook の STEP D から呼ぶ。10 分に 1 回まで）
#   5. resume: 回答が付いた後などに、記録した完了語でループを起動し直す（launch と同じく見張り役も起動する）
#   6. final:  ループが終わったら、ゴール元の目印つきの最終 PR（epic-final）を作る。制御用 worktree の外から呼ぶ
#              goal に未完了のタスクが残っていれば作らない（回答待ちの PR だけが残っているときは作る）
#              ふだんは見張り役が呼ぶ。手で呼ぶのは、見張り役が動かなかったとき（Mac の再起動など）や ASKHUB_AUTO_FINAL=0 のとき
#   7. 終わり: 見張り役は、ゴール元の Discussion が閉じる（最終 PR のマージでワークフローが閉じる）のを待ち、このループのコメントを消す。
#              見張り役が動いていなかったときは、次の start（同じリポジトリのどの Discussion でも）が消す
#      end:    Discussion を閉じずにループをやめるときに、このループのコメントを消す
#
# 必要なもの: gh（このリポジトリに書き込み権限のあるアカウントでログイン済み）・git・jq・claude（ralph-loop プラグイン入り。
#             ASKHUB_AGENT=opencode のときは claude の代わりに OpenCode の CLI）
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

# ralph-setup.sh・ralph-start.sh は、同じ版の ralph-kit のものを呼ぶ（各リポジトリの scripts/ralph-kit.sh が、取得した kit の場所を RALPH_KIT_DIR に入れて呼ぶ）
KIT_DIR="${RALPH_KIT_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}"

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift

fail() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '3,8p' "$0" | sed 's/^# //' >&2; exit 64; }

[[ -n "$COMMAND" ]] || usage
for command in gh git jq; do
  command -v "$command" >/dev/null 2>&1 || fail "$command が見つかりません"
done

# メインの checkout（制御用 worktree やスロットから呼ばれても、共通の .git から求める）
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || fail "git リポジトリの中で実行してください"
MAIN=$(dirname "$COMMON_DIR")
NAME=$(basename "$MAIN")
STEM="${NAME%-ios}"
PARENT=$(dirname "$MAIN")
# オーケストレーターの自動ループの制御用 worktree（kit 1.3 までは、手動ループもここを使っていた）
LEGACY_CTL="$PARENT/$STEM-ralph-ctl"
# 手動ループの記録。制御用 worktree にこれがあれば、playbook は手動ループとして status を書く
RECORD=".claude/askhub-manual.local.txt"
LOG_DIR="${ASKHUB_LOG_DIR:-$HOME/Library/Logs/askhub/manual}"
BASE_BRANCH="${ASKHUB_BASE_BRANCH:-develop}"
STATUS_INTERVAL=600
# Claude の利用上限で止まったループを、解除の時刻の何秒後に再開するか（解除の直後はまだ上限に当たることがあるので、少し空ける）
USAGE_LIMIT_MARGIN="${ASKHUB_USAGE_LIMIT_MARGIN:-60}"

REPOSITORY=$(cd "$MAIN" && gh repo view --json nameWithOwner --jq .nameWithOwner) || fail "GitHub のリポジトリを特定できません（gh auth status を確認してください）"
OWNER="${REPOSITORY%%/*}"
REPO="${REPOSITORY#*/}"

# ---- ループ（Discussion）ごとの作業場所 ------------------------------------------------------

# Discussion の手動ループの制御用 worktree（スロットは末尾の -ctl を -a / -b にしたもの）
manual_ctl() { printf '%s\n' "$PARENT/$STEM-ralph-d$1-ctl"; }

# 記録ファイル（key=value）の値
record_get() { [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" | tail -1; return 0; }

# 使うループを決める。以降の関数は、このループの記録・state・goal を読み書きする
use_loop() {
  LOOP_DISCUSSION="$1"
  CTL="$2"
  STATE_FILE="$CTL/$RECORD"
  LOOP_STATE="$CTL/.claude/ralph-loop.local.md"
  GOAL="$CTL/.claude/ralph-goal.local.md"
  RALPH_STATE="$CTL/.claude/ralph-state.local.md"
  PLAYBOOK="$CTL/.claude/ralph-playbook.local.md"
  PID_FILE="$CTL/.claude/askhub-loop.pid"
}

# kit 1.3 までに固定パス（<名前>-ralph-ctl）で始めた、その Discussion の手動ループがあるか。
# 記録の epic を今も checkout しているときだけにする（オーケストレーターが同じ場所を自動ループに使っていれば、その記録は古い）
legacy_loop() {
  local record="$LEGACY_CTL/$RECORD"
  [[ "$(record_get "$record" discussion)" == "$1" ]] || return 1
  [[ "$(git -C "$LEGACY_CTL" symbolic-ref --short -q HEAD 2>/dev/null || true)" == "$(record_get "$record" epic)" ]]
}

# Discussion の手動ループの制御用 worktree。新しい場所が無く、固定パスにその Discussion の手動ループがあれば、そこを使い続ける（移さない）
ctl_for() {
  local ctl
  ctl=$(manual_ctl "$1")
  if [[ ! -e "$ctl" ]] && legacy_loop "$1"; then
    ctl="$LEGACY_CTL"
  fi
  printf '%s\n' "$ctl"
}

# この Mac にある、このリポジトリの手動ループ（「番号<TAB>制御用 worktree」）。終えたもの（end・Discussion が閉じた）は除く
manual_loops() {
  local record ctl n
  for record in "$PARENT/$STEM-ralph-d"*"-ctl/$RECORD" "$LEGACY_CTL/$RECORD"; do
    [[ -f "$record" && -z "$(record_get "$record" ended_at)" ]] || continue
    ctl="${record%"/$RECORD"}"
    n=$(record_get "$record" discussion)
    [[ "$n" =~ ^[0-9]+$ && "$(ctl_for "$n")" == "$ctl" ]] || continue
    printf '%s\t%s\n' "$n" "$ctl"
  done
}

# 制御用 worktree・スロットの中から呼ばれたら、そのループの Discussion の番号（ループのエージェントが status を呼ぶとき）
loop_from_cwd() {
  local top base rest
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [[ "$(cd "$(dirname "$top")" && pwd -P)" == "$(cd "$PARENT" && pwd -P)" ]] || return 0
  base=$(basename "$top")
  rest="${base#"$STEM-ralph-"}"
  [[ "$rest" != "$base" ]] || return 0
  if [[ "$rest" =~ ^d([0-9]+)-(ctl|a|b)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$rest" =~ ^(ctl|a|b)$ ]]; then
    # 固定パス（kit 1.3 までの手動ループ）。手動ループの記録が無ければ空
    record_get "$LEGACY_CTL/$RECORD" discussion
  fi
}

# start 以外で使うループを決める。番号を省いたら、呼ばれた場所か、この Mac の手動ループが 1 つだけのときはそれを使う
resolve_loop() {
  local n="${1:-}" loops count
  # 先頭の 0 は外す（作業場所の名前と、目印の JSON の数値をそろえる）
  if [[ -n "$n" ]]; then n=$((10#$n)); fi
  [[ -n "$n" ]] || n=$(loop_from_cwd)
  if [[ -z "$n" ]]; then
    loops=$(manual_loops)
    count=$(printf '%s' "$loops" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
      fail "この Mac に、このリポジトリの手動ループの記録がありません（先に start を実行してください）"
    elif [[ "$count" -gt 1 ]]; then
      fail "この Mac に、このリポジトリの手動ループが複数あります。Discussion の番号を付けて実行してください（$(cut -f 1 <<<"$loops" | sed 's/^/#/' | paste -sd ' ' -)）"
    fi
    n=$(cut -f 1 <<<"$loops")
  fi
  use_loop "$n" "$(ctl_for "$n")"
  [[ -f "$STATE_FILE" ]] || fail "Discussion #$n の手動ループの記録がありません（先に start を実行してください）"
  # start で記録した base branch を、resume・final でも使う（ASKHUB_BASE_BRANCH を付け忘れても、開始時と同じ base になるように）
  local recorded
  recorded=$(state_get base_branch)
  if [[ -n "$recorded" ]]; then BASE_BRANCH="$recorded"; fi
}

# 制御用 worktree とスロットを用意する（ralph-setup.sh は既存の worktree を再利用し、片付け済みのスロットは作り直す）。
# 固定パスで始めたループは、その場所のまま
setup_worktrees() {
  local id=""
  [[ "$CTL" == "$LEGACY_CTL" ]] || id="d$LOOP_DISCUSSION"
  (cd "$MAIN" && RALPH_LOOP_ID="$id" "$KIT_DIR/bin/ralph-setup.sh" "$1" "$BASE_BRANCH" >/dev/null)
}

# 記録（key=value）を読む・書く
state_get() { record_get "$STATE_FILE" "$1"; }
state_set() {
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  local rest
  rest=$(grep -v "^$1=" "$STATE_FILE" || true)
  { [[ -n "$rest" ]] && printf '%s\n' "$rest"; printf '%s=%s\n' "$1" "$2"; } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
state_unset() {
  [[ -f "$STATE_FILE" ]] || return 0
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

viewer() { gh api user --jq .login; }

# このリポジトリで信用する author（書き込み権限を持つアカウント。AskHub と同じ判定）
trusted_authors() {
  gh api "repos/$REPOSITORY/collaborators?affiliation=all" --paginate \
    --jq '.[] | select(.permissions.push or .permissions.maintain or .permissions.admin) | .login' | sort -f | paste -sd, -
}

is_trusted() {
  local login="$1" list="$2"
  [[ -n "$login" ]] && printf '%s\n' "${list//,/$'\n'}" | grep -Fqix -- "$login"
}

loop_alive() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid=$(tr -d '[:space:]' < "$PID_FILE")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Discussion の ready-for-loop を外す（Discussion のラベルは REST で外せないので GraphQL を使う）
remove_ready_label() {
  local discussion_id="$1" label_id
  label_id=$(gh api graphql -f query='query($o:String!,$r:String!){ repository(owner:$o,name:$r){ label(name:"ready-for-loop"){ id } } }' \
    -f o="$OWNER" -f r="$REPO" --jq '.data.repository.label.id // ""')
  [[ -n "$label_id" ]] || return 0
  # shellcheck disable=SC2016  # GraphQL の変数なので展開しない
  gh api graphql -f query='mutation($d:ID!,$l:ID!){ removeLabelsFromLabelable(input:{labelableId:$d,labelIds:[$l]}){ clientMutationId } }' \
    -f d="$discussion_id" -f l="$label_id" >/dev/null
}

# playbook の「信用する author」を今の値に書き直す（epic の途中で招待した人も、次の起動から信用する）
refresh_trusted_authors() {
  local trusted="$1" current
  # 取得できなかった（空）ときは書き換えない（信用する author が空になると、ループがどの指示も読まなくなる）
  [[ -n "$trusted" && -f "$PLAYBOOK" ]] || return 0
  current=$(sed -n -E 's/.*\*\*信用する author: `([^`]*)`\*\*.*/\1/p' "$PLAYBOOK" | head -n 1)
  [[ -n "$current" && "$current" != "$trusted" ]] || return 0
  OLD="$current" NEW="$trusted" perl -pi -e 's/\Q`$ENV{OLD}`\E/`$ENV{NEW}`/g' "$PLAYBOOK"
  echo "playbook の信用する author を更新しました（${trusted}）"
}

# ---- ループの状態（状態用の Issue の、このループのコメント）--------------------------------
# 状態用の Issue（loop-status）はリポジトリに 1 つ。ループ（Discussion）ごとに 1 つのコメントを置き、書き手は自分のループのコメントだけを書き換える
# （ask-hub-apple の docs/protocol.md の「ループごとのコメントと本文の形」）。本文はオーケストレーターがリポジトリ全体の状態に使うので、手動ループは書かない
# （kit 1.3 までがこのループの状態を本文に書いていれば、片付けるだけ）

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# GNU の書き方を先に試し、macOS（BSD）に戻す。GNU の stat は BSD の -f を「ファイルシステムの情報」と読んで成功するので、
# BSD を先にすると Linux や、PATH の先に coreutils がある Mac で数字でない値になる（macOS の date・stat は GNU の -d・-c を拒む）
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# UNIX 時刻を、この Mac のタイムゾーンの時刻にする（ログに書く用。iso_of と同じく GNU の書き方を先に試す）
local_time_of() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M'; }

count_lines() { grep -c -E "$1" "$2" 2>/dev/null || true; }

# 状態を決める。--stopping はループが promise を出して終わる直前（state ファイルがまだあっても止まったものとして扱う）
compute_state() {
  local stopping="$1" waiting="$2" open
  open=$(grep -E '^- \[ \]' "$GOAL" 2>/dev/null | grep -vc '※回答待ち' || true)
  if [[ "$stopping" != true && -f "$LOOP_STATE" ]]; then
    if loop_alive; then
      echo running
    elif usage_limited_until >/dev/null; then
      echo usage-limited
    else
      echo gave-up
    fi
  elif [[ "$open" -gt 0 ]]; then
    echo waiting-to-start
  elif [[ -n "$waiting" ]]; then
    echo waiting-for-answer
  else
    echo completed
  fi
}

# 見張り役が Claude の利用上限の解除を待っているなら、解除の時刻（UNIX 時刻）を出す。
# 再開する時刻（解除の時刻 + USAGE_LIMIT_MARGIN）を過ぎたら待っていない（見張り役が動いていなかったときに、待機中と出し続けない）
usage_limited_until() {
  local limited
  limited=$(state_get usage_limited_until)
  [[ "$limited" =~ ^[0-9]+$ ]] || return 1
  (( limited + USAGE_LIMIT_MARGIN > $(date +%s) )) || return 1
  echo "$limited"
}

state_title() {
  case "$1" in
    running) echo "実行中" ;;
    usage-limited) echo "上限で待機中" ;;
    waiting-for-answer) echo "回答待ち" ;;
    waiting-to-start) echo "開始待ち" ;;
    gave-up) echo "異常終了（再開を諦めた）" ;;
    completed) echo "完了（最終 PR のマージ待ち）" ;;
    *) echo "$1" ;;
  esac
}

write_status() {
  local stopping="${1:-false}" force="${2:-false}"
  local discussion epic runner waiting state total completed deferred last checked marker body signature now limited="" limited_row=""
  discussion=$(state_get discussion)
  epic=$(state_get epic)
  runner=$(state_get runner)
  [[ -n "$discussion" && -n "$epic" && -n "$runner" ]] || fail "手動ループの記録がありません（先に start を実行してください）"
  # end で終えた（コメントを消した）ループは書き直さない。書くと、片付ける役（見張り役・次の start）がいないコメントが残る
  if [[ -n "$(state_get ended_at)" ]]; then
    echo "Discussion #$discussion の手動ループは終えているため、ループの状態は書きません（続けるなら scripts/askhub-manual.sh resume ${discussion}）"
    return 0
  fi
  # 取得できないときも、ほかの書き出しの失敗と同じく警告だけ出して成功で返す（launch がループを起動した後に失敗で終わらないように）
  if ! waiting=$(gh pr list -R "$REPOSITORY" --base "$epic" --label needs-answer --state open --limit 1000 --json number --jq '.[].number' | sort -n | paste -sd, -); then
    warn "回答待ちの PR を取得できないため、ループの状態を書きません（次の呼び出しで書き直します）"
    return 0
  fi
  state=$(compute_state "$stopping" "$waiting")
  if [[ "$state" == usage-limited ]]; then limited=$(usage_limited_until || true); fi
  total=$(count_lines '^- \[[ x]\]' "$GOAL")
  completed=$(count_lines '^- \[x\]' "$GOAL")
  deferred=$(count_lines '^- \[x\].*※保留' "$GOAL")
  signature="$state|$completed/$total/$deferred|$waiting|$limited"
  now=$(date +%s)
  local written
  written=$(state_get status_written_at)
  if [[ "$force" != true && "$signature" == "$(state_get status_signature)" ]] && (( now - ${written:-0} < STATUS_INTERVAL )); then
    return 0
  fi
  last=$(printf '%s\n' "$(mtime "$LOOP_STATE")" "$(mtime "$GOAL")" "$(mtime "$RALPH_STATE")" | sort -n | tail -1)
  checked=$(iso_now)
  marker="{\"checkedAt\":\"$checked\",\"discussion\":$discussion,\"epic\":\"$epic\""
  if [[ "$last" -gt 0 ]]; then marker="$marker,\"lastActivityAt\":\"$(iso_of "$last")\""; fi
  if [[ "$total" -gt 0 ]]; then marker="$marker,\"progress\":{\"completed\":$completed,\"deferred\":$deferred,\"total\":$total}"; fi
  marker="$marker,\"runner\":\"$runner\",\"state\":\"$state\""
  if [[ -n "$limited" ]]; then marker="$marker,\"usageLimitedUntil\":\"$(iso_of "$limited")\""; fi
  if [[ -n "$waiting" ]]; then marker="$marker,\"waitingPullRequests\":[$waiting]"; fi
  marker="$marker,\"writer\":\"manual\"}"
  # オーケストレーターの書く表と同じく、上限で待機しているときだけ、回答待ちの PR の前に解除の時刻の行を足す
  if [[ -n "$limited" ]]; then limited_row="| 上限の解除 | $(iso_of "$limited") |"$'\n'; fi
  body=$(cat <<BODY
<!-- ask-hub:loop-status $marker -->
## ループの状態（Discussion #${discussion}）

手動ループ（@$runner さんの Mac）が書き換えるコメントです。編集・削除しないでください（ゴール元の Discussion が閉じたら、手動ループが消します）。

| 項目 | 値 |
| --- | --- |
| 状態 | $(state_title "$state") |
| 書き手 | 手動 |
| 回している人 | @$runner |
| epic | $epic |
| ゴール元 | Discussion #$discussion |
| 進捗 | $completed / $total タスク完了 |
${limited_row}| 回答待ちの PR | ${waiting:-なし} |
| 確認時刻 | $checked |
BODY
)
  # 記録には、コメントを書く前に書く。書いた後に記録へ書くと、コメントを見て記録を消した（end で終えた・作業場所を消したなど）直後に、
  # 消えた記録を作り直してしまう
  state_set status_signature "$signature"
  state_set status_written_at "$now"
  # 書けなかったときは警告だけ出して成功で返す（ループ（STEP D や launch の後）を止めない）。
  # 書いた記録は取り消し、次の呼び出しで書き直させる
  if ! publish_status_comment "$body"; then
    state_unset status_signature
    return 0
  fi
  echo "ループの状態を書きました: $(state_title "$state")（回答待ちの PR: ${waiting:-なし}）"
}

warn() { echo "warning: $*" >&2; }

# 信用する author が作った状態用の Issue（「open なら 0・閉じていれば 1<TAB>更新日時<TAB>番号」）。
# 信用する author ごとに探す（信用外の author が loop-status の Issue を大量に作っても、件数の上限で取りこぼさない）
status_issue_candidates() {
  local author result candidates=""
  while IFS= read -r author; do
    [[ -n "$author" ]] || continue
    result=$(gh issue list -R "$REPOSITORY" --label loop-status --state all --author "$author" --limit 1000 --json number,state,updatedAt \
               --jq '.[] | "\(if .state == "OPEN" then 0 else 1 end)\t\(.updatedAt)\t\(.number)"') || return 1
    candidates+="$result"$'\n'
  done < <(printf '%s\n' "${1//,/$'\n'}")
  printf '%s' "$candidates" | sed '/^$/d'
}

# 状態用の Issue のうち、このループのコメント（新しく更新された順に「更新日時<TAB>コメントの id」）。
# 同じアカウントがオーケストレーターと手動ループの両方の書き手になりうるので、author ではなく目印の discussion と writer で見分ける。
# public リポジトリでは誰でもコメントできるので、信用する author のコメントだけを見る
own_status_comments() {
  gh api "repos/$REPOSITORY/issues/$1/comments?per_page=100" --paginate \
    | jq -r --arg trusted "$2" --argjson discussion "$LOOP_DISCUSSION" '
        ($trusted | ascii_downcase | split(",")) as $authors
        | .[]
        | select((.user.login // "" | ascii_downcase) as $login | any($authors[]; . == $login))
        | ((.body // "") | sub("^\\s+"; "") | capture("^<!--\\s*ask-hub:loop-status\\s(?<json>[^\\n]*?)-->") | .json | fromjson?) as $report
        | select(($report | type) == "object" and $report.discussion == $discussion and $report.writer == "manual")
        | "\(.updated_at)\t\(.id)"' \
    | sort -t $'\t' -k1,1r -k2,2nr
}

# 状態用の Issue を、手動ループが作るときの本文。ループの状態は書かない（本文はオーケストレーターがリポジトリ全体の状態を書く）
STATUS_ISSUE_BODY='## ループの状態

AskHub のループの状態を書き出す Issue です。ループの状態は、ループ（ゴール元の Discussion）ごとのコメントに書きます。編集・クローズしないでください。'

# kit 1.3 までの手動ループが本文に書いた、このループの状態（前の形の目印。書き手 manual で、このループの Discussion のもの）を片付ける。
# 残すと、このループのコメントを消した後に AskHub が本文から終わったループの行を出し、手動ループの Discussion が open なあいだは
# オーケストレーターも本文を書き直さない。片付けるのはこのループの状態だけ（オーケストレーター・ほかのループが書いた本文には触らない）。
# 本文を読めなかった・書き換えられなかったときは、警告を出して 1 を返す（やり直すかは呼び出し側が決める）
clear_legacy_body() {
  local legacy
  if ! legacy=$(gh issue view "$1" -R "$REPOSITORY" --json body --jq '.body' \
    | jq -R -s -r --argjson discussion "$LOOP_DISCUSSION" '
        sub("^\\s+"; "") | capture("^<!--\\s*ask-hub:loop-status\\s(?<json>[^\\n]*?)-->") | .json | fromjson?
        | select(type == "object" and .writer == "manual" and .discussion == $discussion) | "legacy"'); then
    warn "状態用の Issue（#$1）の本文を読めないため、このループの前の形の状態が残っているかを確かめられません"
    return 1
  fi
  [[ "$legacy" == legacy ]] || return 0
  if ! gh issue edit "$1" -R "$REPOSITORY" --body "$STATUS_ISSUE_BODY" >/dev/null; then
    warn "状態用の Issue（#$1）の本文に残っている、このループの前の形の状態を片付けられませんでした"
    return 1
  fi
  echo "状態用の Issue（#$1）の本文に残っていた、このループの前の形の状態を片付けました"
}

# このループのコメントを書く（無ければ作る）。書けなかったときは警告を出して 1 を返す
publish_status_comment() {
  local body="$1" trusted me candidates chosen issue url comments newest id
  if ! trusted=$(trusted_authors) || [[ -z "$trusted" ]]; then
    warn "信用する author を取得できないため、ループの状態を書きません（gh auth status と、このリポジトリの権限を確認してください）"
    return 1
  fi
  # 信用する author のアカウントで書く（ほかのアカウントのコメントは、AskHub もオーケストレーターも読まない）
  if ! me=$(viewer) || ! is_trusted "$me" "$trusted"; then
    warn "gh のアカウント（@${me:-不明}）は、このリポジトリで信用する author ではないため、ループの状態を書きません（gh auth status を確認してください）"
    return 1
  fi
  # 信用する author が作った状態用の Issue のうち、open で最も新しく更新されたもの（無ければ閉じたもので最も新しく更新されたもの）を使う。
  # 取得に失敗したときは、取りこぼしたまま新しい Issue を作らない
  if ! candidates=$(status_issue_candidates "$trusted"); then
    warn "状態用の Issue を取得できないため、ループの状態を書きません（gh auth status を確認してください）"
    return 1
  fi
  chosen=$(printf '%s\n' "$candidates" | sed '/^$/d' | sort -t $'\t' -k1,1n -k2,2r | head -n 1)
  if [[ -z "$chosen" ]]; then
    gh label create loop-status -R "$REPOSITORY" --color bfdadc --description "AskHub のループの状態を書き出す Issue" >/dev/null 2>&1 || true
    if ! url=$(gh issue create -R "$REPOSITORY" --title "【AskHub】ループの状態" --label loop-status --body "$STATUS_ISSUE_BODY") \
      || [[ ! "${url##*/}" =~ ^[0-9]+$ ]]; then
      warn "状態用の Issue を作れなかったため、ループの状態を書きません"
      return 1
    fi
    issue="${url##*/}"
  else
    issue=$(cut -f 3 <<<"$chosen")
    if [[ "$(cut -f 1 <<<"$chosen")" != 0 ]]; then
      gh issue reopen "$issue" -R "$REPOSITORY" >/dev/null 2>&1 || true
    fi
  fi
  # 片付けられなくても、コメントは書く（次の書き出しでやり直す）
  clear_legacy_body "$issue" || true
  if ! comments=$(own_status_comments "$issue" "$trusted"); then
    warn "状態用の Issue（#${issue}）のコメントを取得できないため、ループの状態を書きません"
    return 1
  fi
  newest=$(head -n 1 <<<"$comments" | cut -f 2)
  if [[ -z "$newest" ]]; then
    gh api -X POST "repos/$REPOSITORY/issues/$issue/comments" -f body="$body" >/dev/null \
      || { warn "状態用の Issue（#${issue}）に、ループの状態のコメントを作れませんでした"; return 1; }
    return 0
  fi
  gh api -X PATCH "repos/$REPOSITORY/issues/comments/$newest" -f body="$body" >/dev/null \
    || { warn "状態用の Issue（#${issue}）の、ループの状態のコメントを書き換えられませんでした"; return 1; }
  # 同じループのコメントが重なっていたら（ほぼ同時に作ったなど）、書き換えたもの以外を消す（読む側は確認時刻の新しいものを使うので、残っても壊れない）
  for id in $(tail -n +2 <<<"$comments" | cut -f 2); do
    gh api -X DELETE "repos/$REPOSITORY/issues/comments/$id" >/dev/null 2>&1 || true
  done
}

# ---- ループの終わり（このループのコメントを消す）----------------------------------------------
# AskHub は閉じた Discussion の手動ループを絞り込まないので、消さないと終わったループの行が残り続ける。
# Discussion が open なあいだは消さない（AskHub の「手動ループ」は、状態が無いと「未開始」と出して開始の指示を出す）

# Discussion が閉じているか（true / false。見つからなければ null）
discussion_closed() {
  gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ discussion(number:$n){ closed } } }' \
    -f o="$OWNER" -f r="$REPO" -F n="$1" --jq '.data.repository.discussion.closed'
}

# 信用する author が作った状態用の Issue（閉じたものも）から、このループのコメントをすべて消す（本文に残った前の形のこのループの状態も片付ける）
delete_status_comments() {
  local trusted candidates issue ids id error
  if ! trusted=$(trusted_authors) || [[ -z "$trusted" ]]; then
    warn "信用する author を取得できないため、ループの状態のコメントを消せません（gh auth status を確認してください）"
    return 1
  fi
  if ! candidates=$(status_issue_candidates "$trusted"); then
    warn "状態用の Issue を取得できないため、ループの状態のコメントを消せません"
    return 1
  fi
  for issue in $(cut -f 3 <<<"$candidates"); do
    # kit 1.3 までがこのループの状態を本文に書いたまま（この版でコメントを書かずに終えた・別の Issue の本文に残っている）なら、それも片付ける。
    # 片付けられなければ失敗にする（終えた記録を書くと、その後は書き出しも start の片付けもこのループを見ないので、やり直せなくなる）
    clear_legacy_body "$issue" || return 1
    if ! ids=$(own_status_comments "$issue" "$trusted"); then
      warn "状態用の Issue（#${issue}）のコメントを取得できないため、ループの状態のコメントを消せません"
      return 1
    fi
    for id in $(cut -f 2 <<<"$ids"); do
      # 見張り役と start がほぼ同時に消したもの（gh の「Not Found (HTTP 404)」）は、もう消えているので成功として扱う。
      # 「404」だけで見ると、通信のエラーの URL に入ったコメントの id（404 を含む番号）を取り違える
      if ! error=$(gh api -X DELETE "repos/$REPOSITORY/issues/comments/$id" 2>&1 >/dev/null) \
        && [[ "$error" != *"(HTTP 404)"* ]]; then
        warn "ループの状態のコメント（${id}）を消せませんでした: $error"
        return 1
      fi
    done
  done
}

# このループを終える（コメントを消し、終えたことを記録する。記録した手動ループは、番号を省いたときの候補から外す）
end_loop() {
  delete_status_comments || return 1
  state_set ended_at "$(iso_now)"
}

# この Mac のほかの手動ループのうち、ゴール元の Discussion が閉じたもののコメントを消す
# （見張り役が、Discussion が閉じるのを待てなかったとき（Mac の再起動など）の後片付け）
sweep_finished_loops() {
  local n ctl
  while IFS=$'\t' read -r n ctl; do
    [[ -n "$n" && "$n" != "$LOOP_DISCUSSION" ]] || continue
    [[ "$(discussion_closed "$n" </dev/null 2>/dev/null || true)" == true ]] || continue
    # 使うループの変数（記録・state の場所）を変えないよう、サブシェルで扱う
    (
      use_loop "$n" "$ctl"
      if loop_alive; then exit 0; fi
      end_loop >/dev/null && echo "Discussion #$n の手動ループは終わっている（Discussion が閉じている）ので、ループの状態のコメントを消しました"
    ) </dev/null || true
  done < <(manual_loops)
}

# ---- ループの起動 --------------------------------------------------------------------------

# claude を指定の権限モードで起動したとき、実際に効く権限モード（起動時の init イベントから読む）。
# MDM や組織の管理設定で bypassPermissions が禁止されていると、エラーにならずに default で起動し、
# 確認の要る操作（ファイルの編集・コマンド）がすべて黙って拒否されるので、起動の前に確かめる。
# 本番のループと同じプロジェクト設定（制御用 worktree の .claude/settings.json など）で判定するよう、制御用 worktree で起動する。
# ループの Stop hook に捕まらないよう、hook を止めて起動し、ループの state ファイルをよけた後に呼ぶ（launch_loop）。
# init の行が出たら（または ASKHUB_PROBE_TIMEOUT 秒（既定 60）たったら）、子プロセスごと止める
# （固まっても launch を止めない。claude の子プロセスが出力を開いたまま残っても待たないよう、新しいプロセスグループで起動する）。読めなければ空
effective_permission_mode() {
  local mode="$1" ticks=0 found="" limit=$(( ${ASKHUB_PROBE_TIMEOUT:-60} * 10 ))
  # 確認の claude には Ctrl-C の SIGINT が届かないので、途中で中断（Ctrl-C・TERM）されたときも止めて、一時ディレクトリを消す。
  # trap からは関数の local 変数が見えないので、PROBE_DIR・PROBE_PID に入れる（コマンド置換の中で呼ぶので、呼び出し元の変数と trap は変えない）
  PROBE_DIR="" PROBE_PID=""
  trap 'stop_probe "${PROBE_PID:-}"; [[ -z "${PROBE_DIR:-}" ]] || rm -rf "$PROBE_DIR"' EXIT
  trap 'exit 130' INT TERM
  PROBE_DIR=$(mktemp -d)
  (cd "$CTL" && exec perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' "${ASKHUB_CLAUDE:-claude}" -p --permission-mode "$mode" \
      --settings '{"disableAllHooks":true}' --no-session-persistence --output-format stream-json --verbose --max-turns 1 \
      "OK とだけ答えてください" </dev/null >"$PROBE_DIR/out" 2>/dev/null) &
  PROBE_PID=$!
  while (( ticks < limit )); do
    found=$(grep -m 1 '"subtype":"init"' "$PROBE_DIR/out" 2>/dev/null | sed -n -E 's/.*"permissionMode": *"([^"]*)".*/\1/p' || true)
    [[ -n "$found" ]] && break
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.1
    ticks=$(( ticks + 1 ))
  done
  # 終わる直前に書かれた init も拾う
  [[ -n "$found" ]] || found=$(grep -m 1 '"subtype":"init"' "$PROBE_DIR/out" 2>/dev/null | sed -n -E 's/.*"permissionMode": *"([^"]*)".*/\1/p' || true)
  stop_probe "$PROBE_PID"
  trap - EXIT INT TERM
  rm -rf "$PROBE_DIR"
  printf '%s' "$found"
}

# 確認の claude を、子プロセスごと止める。
# TERM で止まらないプロセスが残っても wait が戻らなくならないよう、2 秒待って残っていれば KILL する。
# プロセスグループを作る前（setpgrp の前）に中断されたときはグループがないので、PID にも送る
stop_probe() {
  local pid="$1" grace=0
  [[ -n "$pid" ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 -- "-$pid" 2>/dev/null && (( grace < 20 )); do
    sleep 0.1
    grace=$(( grace + 1 ))
  done
  kill -KILL -- "-$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# ループを起動する権限モード。bypassPermissions が使えなければ auto にする。どちらも使えなければ起動しない。
# 確認が中断されたとき（コマンド置換が失敗したとき）は、次の確認に進まずに失敗を返す
loop_permission_mode() {
  local mode
  mode=$(effective_permission_mode bypassPermissions) || return 1
  if [[ "$mode" == bypassPermissions ]]; then
    echo bypassPermissions
    return 0
  fi
  echo "この Mac では bypassPermissions が使えないため（起動時の権限モード: ${mode:-不明}）、auto モードで起動します" >&2
  mode=$(effective_permission_mode auto) || return 1
  if [[ "$mode" != auto ]]; then
    fail "この Mac では bypassPermissions も auto モードも使えません（起動時の権限モード: ${mode:-不明}）。確認の要る操作がすべて拒否されてループが進まないため、起動しません"
  fi
  echo auto
}

# OpenCode の実行ファイル（ASKHUB_AGENT=opencode のときに使う）。ASKHUB_OPENCODE → PATH → macOS の既定の場所の順に探す
opencode_bin() {
  local bin="${ASKHUB_OPENCODE:-}"
  if [[ -z "$bin" ]]; then
    bin=$(command -v opencode 2>/dev/null || true)
  fi
  if [[ -z "$bin" && -x /Applications/OpenCode.app/Contents/Resources/opencode-cli ]]; then
    bin=/Applications/OpenCode.app/Contents/Resources/opencode-cli
  fi
  [[ -n "$bin" && -x "$bin" ]] || return 1
  printf '%s\n' "$bin"
}

# launch_loop の OpenCode 版。権限モードの確認（claude の起動）は行わず、常に opencode run --auto で起動する
# （--auto でも明示された deny は常に優先される）。state のよけ方・ログ・PID・見張り役は Claude 版と同じにして、
# watch-final・final・status・ralph-stop.sh が無改修で動くようにする
launch_loop_opencode() {
  local promise="$1" oc_bin
  oc_bin=$(opencode_bin) || fail "opencode の実行ファイルが見つかりません。PATH に通すか、ASKHUB_OPENCODE で指定してください（例: ASKHUB_OPENCODE=/Applications/OpenCode.app/Contents/Resources/opencode-cli）"
  loop_alive && fail "Discussion #$LOOP_DISCUSSION のループは既に動いています（PID $(cat "$PID_FILE")）。止めるには、$CTL で scripts/ralph-stop.sh"
  # 前のループが残した state をよけてから ralph-start.sh で作り直す（ralph-start.sh は state があると止まる）。
  # 作り終えてから消す。途中で中断されたときは元に戻す（止まったループの状態を status が正しく出せるように）
  local saved_state=""
  if [[ -f "$LOOP_STATE" ]]; then
    saved_state="$LOOP_STATE.saved"
    mv "$LOOP_STATE" "$saved_state"
    # shellcheck disable=SC2064  # trap からは関数の local が見えないので、今の値を printf %q で引用して埋め込む
    trap "mv $(printf '%q' "$saved_state") $(printf '%q' "$LOOP_STATE") 2>/dev/null || true" EXIT
    trap 'exit 130' INT TERM
  fi
  (cd "$CTL" && "$KIT_DIR/bin/ralph-start.sh" "$promise" >/dev/null)
  [[ -f "$LOOP_STATE" ]] || fail "state ファイルを作れませんでした: $LOOP_STATE"
  if [[ -n "$saved_state" ]]; then
    trap - EXIT INT TERM
    rm -f "$saved_state"
  fi
  mkdir -p "$LOG_DIR"
  local log
  # 同じリポジトリのほかの手動ループと取り違えないよう、Discussion の番号を入れる（Claude 版と同じ）
  log="$LOG_DIR/$STEM-d$LOOP_DISCUSSION-loop-$(date +%Y%m%d-%H%M%S).log"
  # 制御用 worktree で opencode-loop.sh のループを起動する。周回中の scripts/askhub-manual.sh status なども、
  # 起動したときと同じ版の kit を使うよう、kit の場所を渡す（ASKHUB_OPENCODE で実行ファイルも固定する）
  (
    cd "$CTL"
    RALPH_KIT_DIR="$KIT_DIR" ASKHUB_OPENCODE="$oc_bin" nohup "$KIT_DIR/bin/opencode-loop.sh" "$promise" </dev/null >>"$log" 2>&1 &
    echo $! > "$PID_FILE"
  )
  state_set log "$log"
  state_set permission_mode auto
  # end で終えたループを起動し直したら、終えた記録を外す（見張り役が、Discussion が閉じたらまたコメントを消せるように）
  state_unset ended_at
  # 利用上限の解除を待っていたループを起動し直したら（解除の後の再開・担当者の resume）、待機の記録を外す
  state_unset usage_limited_until
  echo "ループを起動しました（PID $(cat "$PID_FILE")、実行エージェント: OpenCode、ログ: ${log}）"
  echo "進み具合を見るには: tail -f \"${log}\""
  start_final_watch "$(tr -d '[:space:]' < "$PID_FILE")" "$log"
  write_status false true
}

launch_loop() {
  local promise="$1"
  # ループの実行エージェント。既定は claude（ralph-loop プラグインの Stop hook が周回させる）。
  # opencode のときは bin/opencode-loop.sh が周回させる
  if [[ "${ASKHUB_AGENT:-claude}" == opencode ]]; then
    launch_loop_opencode "$promise"
    return
  fi
  [[ "${ASKHUB_AGENT:-claude}" == claude ]] || fail "ASKHUB_AGENT の値が分かりません: ${ASKHUB_AGENT}（claude か opencode を指定してください）"
  command -v "${ASKHUB_CLAUDE:-claude}" >/dev/null 2>&1 || fail "claude が見つかりません"
  loop_alive && fail "Discussion #$LOOP_DISCUSSION のループは既に動いています（PID $(cat "$PID_FILE")）。止めるには、$CTL で scripts/ralph-stop.sh"
  # 権限モードは、ループの state ファイルをよけてから確かめる（確認の起動がループの Stop hook に捕まらないように）。
  # 確かめられない・新しい state を作れない・途中で中断されたときは元に戻して止める（止まったループの状態を status が正しく出せるように）
  local saved_state="" permission_mode
  if [[ -f "$LOOP_STATE" ]]; then
    saved_state="$LOOP_STATE.probe"
    mv "$LOOP_STATE" "$saved_state"
    # 確かめられなかったとき・途中で中断されたときは、よけた state を元に戻す
    # shellcheck disable=SC2064  # trap からは関数の local が見えないので、今の値を printf %q で引用して埋め込む
    trap "mv $(printf '%q' "$saved_state") $(printf '%q' "$LOOP_STATE") 2>/dev/null || true" EXIT
    trap 'exit 130' INT TERM
  fi
  permission_mode=$(loop_permission_mode) || exit 1
  (cd "$CTL" && "$KIT_DIR/bin/ralph-start.sh" "$promise" >/dev/null)
  [[ -f "$LOOP_STATE" ]] || fail "state ファイルを作れませんでした: $LOOP_STATE"
  # 新しい state を作り終えてから、よけた state を消す（ralph-start.sh が失敗したときも元に戻せるように）
  if [[ -n "$saved_state" ]]; then
    trap - EXIT INT TERM
    rm -f "$saved_state"
  fi
  mkdir -p "$LOG_DIR"
  local log initial
  # 同じリポジトリのほかの手動ループと取り違えないよう、Discussion の番号を入れる
  log="$LOG_DIR/$STEM-d$LOOP_DISCUSSION-loop-$(date +%Y%m%d-%H%M%S).log"
  initial=$(sed -n '/^---$/,/^---$/!p' "$LOOP_STATE" | sed '/^$/d')
  # この Claude Code の会話とは別に、制御用 worktree で claude -p のループを起動する（Stop hook が周回させる）
  # 周回中に呼ぶ scripts/askhub-manual.sh status なども、起動したときと同じ版の kit を使うよう、kit の場所を渡す
  # （中継から呼ばれたときは RALPH_KIT_DIR が export 済みだが、kit の checkout から直接呼ばれたときは無い）
  (
    cd "$CTL"
    RALPH_KIT_DIR="$KIT_DIR" nohup "${ASKHUB_CLAUDE:-claude}" -p --add-dir "${CTL%-ctl}-a" --add-dir "${CTL%-ctl}-b" \
      --permission-mode "$permission_mode" "$initial" </dev/null >>"$log" 2>&1 &
    echo $! > "$PID_FILE"
  )
  state_set log "$log"
  state_set permission_mode "$permission_mode"
  # end で終えたループを起動し直したら、終えた記録を外す（見張り役が、Discussion が閉じたらまたコメントを消せるように）
  state_unset ended_at
  # 利用上限の解除を待っていたループを起動し直したら（解除の後の再開・担当者の resume）、待機の記録を外す
  state_unset usage_limited_until
  echo "ループを起動しました（PID $(cat "$PID_FILE")、権限モード: ${permission_mode}、ログ: ${log}）"
  echo "進み具合を見るには: tail -f \"$log\""
  start_final_watch "$(tr -d '[:space:]' < "$PID_FILE")" "$log"
  write_status false true
}

# ループが終わったら最終 PR を作る見張り役を、裏で起動する（自動ループでオーケストレーターが作るのと同じく、担当者に final を頼ませない）。
# 見張り役はメインの checkout で動くシェルで、ループのエージェントではないので、ループの deny（gh pr create --base develop）には当たらない。
# ASKHUB_AUTO_FINAL=0 なら最終 PR は作らない（担当者が final を流す）。そのときも、Discussion が閉じたらコメントを消すために起動する
start_final_watch() {
  local pid="$1" log="$2" watch_pid
  watch_pid=$(
    cd "$MAIN"
    RALPH_KIT_DIR="$KIT_DIR" nohup "$KIT_DIR/bin/askhub-manual.sh" watch-final "$LOOP_DISCUSSION" "$pid" "$log" </dev/null >>"$log" 2>&1 &
    echo $!
  )
  # 見張り役が動いているかを外から確かめられるように残す（見張り役は final の後も状態の書き出しで記録ファイルを書く）
  state_set watch_pid "$watch_pid"
  if [[ "${ASKHUB_AUTO_FINAL:-1}" == 0 ]]; then
    echo "ASKHUB_AUTO_FINAL=0 のため、最終 PR は自動では作りません（ループが終わったら scripts/askhub-manual.sh final ${LOOP_DISCUSSION}）"
  else
    echo "ループが完了語を出して終わったら、最終 PR を自動で作ります（作れなかったときは scripts/askhub-manual.sh final ${LOOP_DISCUSSION}）"
  fi
}

# 見張り役がループのログに書く 1 行
watch_note() { echo "[askhub-manual $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 見張り役: ゴール元の Discussion が閉じる（最終 PR のマージでワークフローが閉じる・担当者が閉じる）のを待ち、このループを終える。
# resume などで別のループが起動した・end で終えたら、何もせずに終わる（そちらに任せる）。
# 記録・PID のファイルが消えても（作業場所を先に消したなど）待ち続ける（コメントを消すのに記録は要らない。終えると、次の start も見つけられない）。
# 引き継ぐのは、このループの記録が残っているときだけ（固定パスの作業場所をオーケストレーターが作り直して、自分の PID を書いたときに終わらない）。
# $1 が true（ループが完了語を出して終わった）なら、待っている間に回答待ちの PR の ask の回答を確かめ、付いていれば resume で再開する
watch_until_closed() {
  local answers="${1:-false}" noted=false pid ours interval
  while :; do
    # 回答待ちの ask があるうちは、回答を早く拾えるよう短い間隔で確かめる
    interval="${ASKHUB_CLOSE_WATCH_INTERVAL:-600}"
    if [[ "$answers" == true && -n "$(waiting_asks)" ]]; then interval="${ASKHUB_ANSWER_WATCH_INTERVAL:-120}"; fi
    sleep "$interval"
    # リポジトリの checkout ごと消されたら（担当から外したなど）、待つ相手がいないので終わる
    [[ -d "$COMMON_DIR" ]] || return 0
    ours=false
    [[ "$(state_get discussion)" == "$LOOP_DISCUSSION" ]] && ours=true
    # < の失敗の知らせも捨てる（記録が消えた後に、10 分ごとにログへ書かないように）
    pid=$({ tr -d '[:space:]' < "$PID_FILE"; } 2>/dev/null || true)
    if [[ "$ours" == true ]] && { [[ -n "$pid" && "$pid" != "$WATCHED" ]] || [[ -n "$(state_get ended_at)" ]]; }; then
      return 0
    fi
    if [[ "$(discussion_closed "$LOOP_DISCUSSION" 2>/dev/null || true)" != true ]]; then
      # 再開したら、このループの見張りは新しいループの見張り役に任せる
      if [[ "$answers" == true && "$ours" == true ]] && resume_after_answer; then
        return 0
      fi
      continue
    fi
    # このループの記録が無ければ、記録を作り直さずにコメントだけを消す（消した作業場所のディレクトリや、ほかのループの記録に書かない）
    if { [[ "$ours" == true ]] && end_loop >/dev/null; } || { [[ "$ours" != true ]] && delete_status_comments >/dev/null; }; then
      watch_note "ゴール元の Discussion #$LOOP_DISCUSSION が閉じたので、ループの状態のコメントを消しました"
      return 0
    fi
    # 消せなければ次の確認でやり直す（ログには 1 回だけ書く）
    if [[ "$noted" != true ]]; then
      if [[ "$ours" == true ]]; then
        watch_note "ゴール元の Discussion #$LOOP_DISCUSSION が閉じましたが、ループの状態のコメントを消せませんでした（やり直します。止めるなら scripts/askhub-manual.sh end ${LOOP_DISCUSSION}）"
      else
        watch_note "ゴール元の Discussion #$LOOP_DISCUSSION が閉じましたが、ループの状態のコメントを消せませんでした（やり直します）"
      fi
      noted=true
    fi
  done
}

# goal の ※回答待ち の未完了タスクの「PR 番号 ask の id」（※回答待ち（PR #123 / ask id 456））。後続のタスクに付けた同じ印は 1 つにまとめる
waiting_asks() {
  [[ -f "$GOAL" ]] || return 0
  { grep -E '^- \[ \].*※回答待ち' "$GOAL" 2>/dev/null || true; } \
    | sed -n -E 's/.*※回答待ち（PR[[:space:]]*#([0-9]+)[[:space:]]*\/[[:space:]]*ask id[[:space:]]*([0-9]+)）.*/\1 \2/p' | sort -u
}

# 見張り役: ループが回答待ちの PR を残して終わった後、その ask に信用する author の回答が付いたら、resume で再開する
# （オーケストレーターの自動ループと同じ。オーケストレーターは、手動ループの epic 宛ての PR の回答では再開しない）。
# 回答は playbook の B-1 と同じく、ask の行コメントへの返信（in_reply_to_id が ask の id）だけを見る。
# 再開に使った ask の id は記録し、同じ回答では再開し直さない（ループが回答を処理しないまま終わっても、起動を繰り返さない）。
# 再開したら 0 を返す（このループの見張りは、新しいループの見張り役に任せる）。回答が無い・再開しなかったときは 1
resume_after_answer() {
  local asks resumed trusted pr ask logins login answered="" ids=""
  asks=$(waiting_asks)
  [[ -n "$asks" ]] || return 1
  # 担当者の resume・launch が起動している最中（state ファイル・.probe・.saved がある）は、そちらに任せる
  [[ ! -e "$LOOP_STATE" && ! -e "$LOOP_STATE.probe" && ! -e "$LOOP_STATE.saved" ]] || return 1
  resumed=$(state_get resumed_asks)
  # 取得できない（空）ときは、誰の返信も回答とみなさない
  trusted=$(trusted_authors 2>/dev/null) || return 1
  [[ -n "$trusted" ]] || return 1
  while read -r pr ask; do
    [[ -n "$ask" && ",$resumed," != *",$ask,"* ]] || continue
    # 取得に失敗した PR は、次の確認でやり直す。--paginate を付けないと、後ろのページの回答を見落とす
    logins=$(gh api --paginate "repos/$REPOSITORY/pulls/$pr/comments" \
      --jq ".[] | select(.in_reply_to_id == $ask) | .user.login" </dev/null 2>/dev/null) || continue
    while IFS= read -r login; do
      if is_trusted "$login" "$trusted"; then
        answered="$answered${answered:+, }#$pr"
        ids="$ids${ids:+,}$ask"
        break
      fi
    done <<<"$logins"
  done <<<"$asks"
  [[ -n "$ids" ]] || return 1
  # ループを起動する前に記録する（起動した後は、ループの status も記録ファイルを書き換える）
  state_set resumed_asks "$resumed${resumed:+,}$ids"
  watch_note "回答待ちの PR（${answered}）の ask に回答が付いたので、ループを再開します"
  # resume は新しいループと、その見張り役を起動する
  if (cd "$MAIN" && "$KIT_DIR/bin/askhub-manual.sh" resume "$LOOP_DISCUSSION"); then
    return 0
  fi
  ANSWER_RESUME_FAILS=$(( ${ANSWER_RESUME_FAILS:-0} + 1 ))
  if (( ANSWER_RESUME_FAILS < 3 )); then
    # 記録を戻し、次の確認でやり直す
    if [[ -n "$resumed" ]]; then state_set resumed_asks "$resumed"; else state_unset resumed_asks; fi
    watch_note "ループを自動で再開できませんでした（${ANSWER_RESUME_FAILS} / 3 回目。次の確認でやり直します）"
  else
    watch_note "ループを自動で再開できませんでした（3 回続けて失敗したので、この回答ではもう再開しません。上のエラーを確かめて、scripts/askhub-manual.sh resume $LOOP_DISCUSSION を手で流してください）"
  fi
  write_status false true
  return 1
}

# 見張り役: ループが Claude の利用上限で止まったら、解除の時刻（$1。UNIX 時刻）まで待ってから resume で再開する（オーケストレーターの自動ループと同じ）。
# 待っている間は、ループの状態を「上限で待機中」で書く。担当者が resume で別のループを起動した・end で終えたら、何もせずに終わる（そちらに任せる）。
# ralph-stop.sh で止めた（state ファイルを消した）・記録が消えた・ゴール元の Discussion が閉じた・再開できなかったときは 1 を返す
# （呼び出し側は、Discussion が閉じるのを待つ）。再開したら 0 を返す（このループの見張りは、新しいループの見張り役に任せる）
resume_after_usage_limit() {
  local reset="$1" resume_at pid
  resume_at=$(( reset + USAGE_LIMIT_MARGIN ))
  state_set usage_limited_until "$reset"
  watch_note "ループが Claude の利用上限で止まりました。解除の時刻（$(local_time_of "$reset")）の後に、自動で再開します（再開させないなら scripts/askhub-manual.sh end ${LOOP_DISCUSSION}）"
  write_status false true
  while :; do
    pid=$({ tr -d '[:space:]' < "$PID_FILE"; } 2>/dev/null || true)
    if [[ -n "$pid" && "$pid" != "$WATCHED" ]]; then
      watch_note "別のループが起動しているため、自動では再開しません"
      exit 0
    fi
    if [[ -n "$(state_get ended_at)" ]]; then
      watch_note "end で終えたため、自動では再開しません"
      exit 0
    fi
    # 作業場所を消したなど。記録を作り直さないよう、状態は書かない
    if [[ "$(state_get discussion)" != "$LOOP_DISCUSSION" ]]; then
      watch_note "手動ループの記録が無くなったため、自動では再開しません"
      return 1
    fi
    # 担当者の resume・launch が state をよけて権限モードを確かめている間（.probe・.saved がある）は、起動が終わるのを待つ
    # （止めたと読んだり、こちらも resume したりすると、起動中の resume と記録ファイル・ループを取り合う）
    if [[ -e "$LOOP_STATE.probe" || -e "$LOOP_STATE.saved" ]]; then
      sleep "${ASKHUB_USAGE_LIMIT_INTERVAL:-60}"
      continue
    fi
    if [[ ! -f "$LOOP_STATE" ]]; then
      watch_note "ループが止められた（state ファイルが無い）ため、自動では再開しません（続けるなら scripts/askhub-manual.sh resume ${LOOP_DISCUSSION}）"
      state_unset usage_limited_until
      write_status false true
      return 1
    fi
    (( $(date +%s) < resume_at )) || break
    # Mac のスリープ中は sleep の時間が進まないので、解除の時刻まで一度に寝ず、短い間隔で時刻を確かめる
    sleep "${ASKHUB_USAGE_LIMIT_INTERVAL:-60}"
  done
  state_unset usage_limited_until
  if [[ "$(discussion_closed "$LOOP_DISCUSSION" 2>/dev/null || true)" == true ]]; then
    watch_note "ゴール元の Discussion #$LOOP_DISCUSSION が閉じているため、自動では再開しません"
    return 1
  fi
  watch_note "Claude の利用上限の解除の時刻を過ぎたので、ループを再開します"
  # resume は新しいループと、その見張り役を起動する
  if (cd "$MAIN" && "$KIT_DIR/bin/askhub-manual.sh" resume "$LOOP_DISCUSSION"); then
    return 0
  fi
  watch_note "ループを自動で再開できませんでした（上のエラーを確かめて、scripts/askhub-manual.sh resume $LOOP_DISCUSSION を手で流してください）"
  write_status false true
  return 1
}

# ---- サブコマンド --------------------------------------------------------------------------

case "$COMMAND" in
  start)
    DISCUSSION="${1:-}"
    EPIC="${2:-}"
    [[ "$DISCUSSION" =~ ^[0-9]+$ ]] || usage
    # 先頭の 0 は外す（作業場所の名前と、目印の JSON の数値をそろえる）
    DISCUSSION=$((10#$DISCUSSION))
    [[ "$EPIC" =~ ^epic/[a-z0-9][a-z0-9-]*$ ]] || fail "epic のブランチ名は epic/<英小文字・数字・ハイフン> にしてください: $EPIC"
    ME=$(viewer)
    TRUSTED=$(trusted_authors)
    is_trusted "$ME" "$TRUSTED" || fail "@$ME はこのリポジトリに書き込み権限がありません"
    # 1 行目: id・閉じているか・作成者・ラベル。2 行目以降: コメントの作成者と 1 行目（担当のコメントの目印を探す）
    INFO=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ discussion(number:$n){
        id closed author{login} labels(first:20){ nodes{ name } } comments(last:100){ nodes{ author{login} body } } } } }' \
      -f o="$OWNER" -f r="$REPO" -F n="$DISCUSSION" \
      --jq '.data.repository.discussion | if . == null then "MISSING" else
        "\(.id)\t\(.closed)\t\(.author.login // "")\t\([.labels.nodes[].name] | join(","))",
        (.comments.nodes[] | "C\t\(.author.login // "")\t\(.body | ltrimstr("\n") | split("\n")[0])") end') \
      || fail "Discussion #$DISCUSSION を取得できません"
    HEADER=$(printf '%s\n' "$INFO" | head -n 1)
    [[ "$HEADER" != MISSING ]] || fail "Discussion #$DISCUSSION が見つかりません"
    IFS=$'\t' read -r DISCUSSION_ID CLOSED AUTHOR LABELS <<<"$HEADER"
    [[ "$CLOSED" == false ]] || fail "Discussion #$DISCUSSION は閉じています"
    is_trusted "$AUTHOR" "$TRUSTED" || fail "Discussion #$DISCUSSION の作成者（@${AUTHOR}）は、このリポジトリで信用する author ではありません"
    [[ ",$LABELS," == *",manual-loop,"* ]] || fail "Discussion #$DISCUSSION に manual-loop がありません（AskHub の回答画面で「手動で回す」を選んで投稿してください）"
    # 担当者は、信用する author が書いた担当のコメント（<!-- ask-hub:manual-assignee login="…" -->）のうち最後のもの
    ASSIGNEE=""
    while IFS=$'\t' read -r kind author first; do
      [[ "$kind" == C ]] || continue
      login=$(printf '%s' "$first" | sed -n -E 's/^<!-- ask-hub:manual-assignee login="([A-Za-z0-9-]+)" -->.*/\1/p')
      if [[ -n "$login" ]] && is_trusted "$author" "$TRUSTED"; then ASSIGNEE="$login"; fi
    done < <(printf '%s\n' "$INFO" | tail -n +2)
    if [[ -z "$ASSIGNEE" ]]; then
      fail "Discussion #$DISCUSSION に担当のコメントがありません（AskHub の回答画面で担当者を選んで投稿してください）"
    fi
    if [[ "$(printf '%s' "$ASSIGNEE" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')" && "${ASKHUB_MANUAL_FORCE:-}" != 1 ]]; then
      fail "この手動ループの担当者は @$ASSIGNEE です（あなたは @${ME}）。担当を変えるときは、Discussion に担当のコメントを付け直してください"
    fi
    # 作業場所はこの Discussion のもの（ほかの手動ループ・オーケストレーターの自動ループとは分ける）
    use_loop "$DISCUSSION" "$(ctl_for "$DISCUSSION")"
    # 同じ Discussion でも、動いているループの記録（完了語など）を消さないように拒否する
    loop_alive && fail "Discussion #$DISCUSSION の手動ループが動いています（PID $(cat "$PID_FILE")）。止めてから start を実行してください（止めるには、$CTL で scripts/ralph-stop.sh）"
    setup_worktrees "$EPIC"
    # 子 PR の base になるので、epic を origin に置いておく（ralph-setup.sh は push しない）
    git -C "$MAIN" push --quiet -u origin "$EPIC" || fail "$EPIC を origin に push できません"
    # 準備と push が済んでから ready-for-loop を外す（途中で失敗したとき、ラベルだけ外れた状態を残さない）
    remove_ready_label "$DISCUSSION_ID"
    rm -f "$STATE_FILE"
    state_set repository "$REPOSITORY"
    state_set discussion "$DISCUSSION"
    state_set epic "$EPIC"
    state_set base_branch "$BASE_BRANCH"
    state_set runner "$ME"
    write_status false true
    sweep_finished_loops
    cat <<NEXT
手動ループの準備ができました（$REPOSITORY / Discussion #$DISCUSSION / $EPIC / 担当 @${ME}）。
制御用 worktree: $CTL

次に行うこと（Claude Code）:
  1. $PLAYBOOK の {{...}} をすべて埋める（ralph-kit の README.md の「使い方」。$KIT_DIR/README.md）。
     - TRUSTED_AUTHORS: $TRUSTED
     - GOAL_SOURCE: Discussion #$DISCUSSION
     - INTEGRATION_BRANCH: $EPIC / BASE_BRANCH: $BASE_BRANCH
     - WORKTREE_CTL: $CTL
     - WORKTREE_A: ${CTL%-ctl}-a / WORKTREE_B: ${CTL%-ctl}-b
     - VERIFY_COMMANDS: スロットごとの場所（-derivedDataPath など）は、スロットのパスから作る（同じリポジトリのほかのループと共有しない）
  2. playbook の STEP A に沿って $GOAL を作る（Discussion の、信用する author の本文・コメント・返信だけを使う）
  3. 完了語を決めて、ループを起動する:
       scripts/askhub-manual.sh launch $DISCUSSION "<完了語>"
NEXT
    ;;

  launch)
    # 番号を付けるときは launch <番号> <完了語>（番号を省いた 1 つだけの引数は完了語）
    if [[ $# -ge 2 && "$1" =~ ^[0-9]+$ ]]; then
      DISCUSSION="$1"
      PROMISE="$2"
    else
      DISCUSSION=""
      PROMISE="${1:-}"
      # 番号だけを付けて完了語を忘れたとき、番号を完了語にして起動しない
      [[ ! "$PROMISE" =~ ^[0-9]+$ ]] || fail "完了語を指定してください（scripts/askhub-manual.sh launch <Discussion 番号> <完了語>）"
    fi
    [[ -n "$PROMISE" ]] || usage
    resolve_loop "$DISCUSSION"
    refresh_trusted_authors "$(trusted_authors)"
    state_set promise "$PROMISE"
    launch_loop "$PROMISE"
    ;;

  status)
    DISCUSSION=""
    STOPPING=false
    for arg in "$@"; do
      case "$arg" in
        --stopping) STOPPING=true ;;
        *) [[ "$arg" =~ ^[0-9]+$ ]] || usage; DISCUSSION="$arg" ;;
      esac
    done
    resolve_loop "$DISCUSSION"
    if [[ "$STOPPING" == true ]]; then
      write_status true true
    else
      write_status false false
    fi
    ;;

  resume)
    [[ -z "${1:-}" || "$1" =~ ^[0-9]+$ ]] || usage
    resolve_loop "${1:-}"
    PROMISE=$(state_get promise)
    [[ -n "$PROMISE" ]] || fail "完了語の記録がありません（launch で起動してください）"
    # 片付け済みのスロットを作り直す
    setup_worktrees "$(state_get epic)"
    refresh_trusted_authors "$(trusted_authors)"
    launch_loop "$PROMISE"
    ;;

  watch-final)
    # launch / resume が裏で起動する見張り役（担当者は呼ばない）。ループのプロセスが終わるのを待ち、
    # ループが完了語の promise を出して終わったときだけ final を流す（自動ループと同じく、異常終了したものには作らない）。
    # Claude の利用上限で止まったときは、解除の時刻まで待って resume で再開する（ASKHUB_AUTO_RESUME=0 なら再開しない）。
    # そのあと、ゴール元の Discussion が閉じるのを待って、このループのコメントを消す（promise を出さずに終わったときも。Discussion を閉じてやめたときに残さない）。
    # promise を出して終わったときは、待っている間に回答待ちの PR の ask に回答が付いたら resume で再開する（ASKHUB_AUTO_RESUME=0 なら再開しない）
    [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ && -n "${3:-}" ]] || usage
    resolve_loop "$1"
    WATCHED="$2"
    WATCHED_LOG="$3"
    while kill -0 "$WATCHED" 2>/dev/null; do
      sleep "${ASKHUB_FINAL_WATCH_INTERVAL:-30}"
    done
    # 見張っている間に resume などで別のループが起動していたら、そのループの見張り役に任せる
    if [[ "$({ tr -d '[:space:]' < "$PID_FILE"; } 2>/dev/null || true)" != "$WATCHED" ]]; then
      watch_note "別のループが起動しているため、最終 PR はそのループが終わってから作ります"
      exit 0
    fi
    # 見張っている間に end で終えていたら、最終 PR は作らない（担当者がやめると決めたループ）
    if [[ -n "$(state_get ended_at)" ]]; then
      watch_note "end で終えたため、最終 PR は作りません"
      exit 0
    fi
    # Stop hook（Claude）・opencode-loop.sh（OpenCode）は promise を受けると state ファイルを消す。
    # 残っていれば promise を出さずに終わった（API のエラーなどの異常終了）。
    # ralph-stop.sh で止めたとき・無進捗で止まったときも state ファイルは消えるので、ループの最後の出力（ログ）の promise でも確かめる
    PROMISE=$(state_get promise)
    COMPLETED=false
    if [[ ! -f "$LOOP_STATE" && -n "$PROMISE" ]] && grep -Fq "<promise>$PROMISE</promise>" "$WATCHED_LOG" 2>/dev/null; then
      COMPLETED=true
    fi
    # state ファイルが残り、ログの末尾が Claude の利用上限のメッセージなら、上限で止まった（解除の時刻は bin/usage-limit.sh が読む）
    RESET=""
    if [[ -f "$LOOP_STATE" ]]; then
      RESET=$("$KIT_DIR/bin/usage-limit.sh" "$WATCHED_LOG" 2>/dev/null) || RESET=""
    fi
    if [[ -n "$RESET" && "${ASKHUB_AUTO_RESUME:-1}" != 0 ]]; then
      if resume_after_usage_limit "$RESET"; then
        exit 0
      fi
    elif [[ -n "$RESET" ]]; then
      watch_note "ループが Claude の利用上限で止まりました。ASKHUB_AUTO_RESUME=0 のため、自動では再開しません（解除の時刻（$(local_time_of "$RESET")）の後に scripts/askhub-manual.sh resume ${LOOP_DISCUSSION}）"
    elif [[ "${ASKHUB_AUTO_FINAL:-1}" == 0 ]]; then
      : # 最終 PR は担当者が final で作る
    elif [[ "$COMPLETED" != true ]]; then
      watch_note "ループが完了語を出さずに終わったため、最終 PR は作りません（続けるなら scripts/askhub-manual.sh resume ${LOOP_DISCUSSION}）"
    else
      watch_note "ループが完了語を出して終わったので、最終 PR を作ります"
      if ! (cd "$MAIN" && "$KIT_DIR/bin/askhub-manual.sh" final "$LOOP_DISCUSSION"); then
        watch_note "最終 PR を作れませんでした（上のエラーを確かめて、scripts/askhub-manual.sh final $LOOP_DISCUSSION を手で流してください）"
      fi
    fi
    # promise を出さずに終わったループは、回答が付いても再開しない（担当者が止めた・異常終了した理由を確かめてから resume する）
    ANSWERS=false
    if [[ "$COMPLETED" == true && "${ASKHUB_AUTO_RESUME:-1}" != 0 ]]; then ANSWERS=true; fi
    if [[ "$COMPLETED" == true && "$ANSWERS" != true && -n "$(waiting_asks)" ]]; then
      watch_note "回答待ちの PR があります。ASKHUB_AUTO_RESUME=0 のため、回答が付いても自動では再開しません（回答の後に scripts/askhub-manual.sh resume ${LOOP_DISCUSSION}）"
    fi
    watch_until_closed "$ANSWERS"
    ;;

  end)
    # Discussion を閉じずにループをやめるとき（見張り役が動いていないときの後片付けにも使える）
    [[ -z "${1:-}" || "$1" =~ ^[0-9]+$ ]] || usage
    resolve_loop "${1:-}"
    loop_alive && fail "Discussion #$LOOP_DISCUSSION のループがまだ動いています（PID $(cat "$PID_FILE")）。止めてから実行してください（止めるには、$CTL で scripts/ralph-stop.sh）"
    end_loop || fail "ループの状態のコメントを消せませんでした。もう一度 scripts/askhub-manual.sh end $LOOP_DISCUSSION を実行してください"
    echo "Discussion #$LOOP_DISCUSSION の手動ループを終えました（ループの状態のコメントを消しました）"
    # Discussion が open で manual-loop が付いたままだと、AskHub の「手動ループ」は状態の無いこのループを「未開始」と出し、開始の指示を出す
    if [[ "$(discussion_closed "$LOOP_DISCUSSION" 2>/dev/null || true)" != true ]]; then
      echo "Discussion #$LOOP_DISCUSSION は open のままです。やめるなら Discussion を閉じてください（AskHub の「手動ループ」には、閉じるまで「未開始」と出ます）"
    fi
    if [[ "$CTL" != "$LEGACY_CTL" ]]; then
      cat <<NEXT
作業場所は残しています（goal・state の記録があるため）。要らなければ、次で消してください:
  (cd "$CTL" && "$KIT_DIR/bin/ralph-stop.sh" --worktrees)   # スロット（${CTL%-ctl}-a / -b）
  git -C "$MAIN" worktree remove "$CTL"                        # 制御用 worktree
NEXT
    fi
    ;;

  final)
    [[ -z "${1:-}" || "$1" =~ ^[0-9]+$ ]] || usage
    resolve_loop "${1:-}"
    # 制御用 worktree そのものか、その中なら拒否する（前方一致だと …-ralph-ctl2 のような別のディレクトリも拒否してしまう）
    if [[ -d "$CTL" ]]; then
      CTL_REAL=$(cd "$CTL" && pwd -P)
      HERE=$(pwd -P)
      if [[ "$HERE" == "$CTL_REAL" || "$HERE" == "$CTL_REAL/"* ]]; then
        fail "制御用 worktree の外（メインの checkout など）で実行してください"
      fi
    fi
    loop_alive && fail "ループがまだ動いています。終わってから最終 PR を作ってください"
    DISCUSSION=$(state_get discussion)
    EPIC=$(state_get epic)
    # status と同じ判定で状態を求め、goal のタスクが終わっているときだけ進める
    # 回答待ちの PR が残っていても作る（自動ループと同じ。回答待ちの PR は下で本文に載せる）
    # goal が読めないと未完了のタスクを 0 件と数えてしまうので、先に拒否する
    [[ -f "$GOAL" && -r "$GOAL" ]] || fail "goal がありません、または読み込めません: $GOAL"
    WAITING=$(gh pr list -R "$REPOSITORY" --base "$EPIC" --label needs-answer --state open --limit 1000 --json number --jq '.[].number' | sort -n | paste -sd, -)
    # ※回答待ちの未完了タスクごとに、goal に書いた PR（※回答待ち（PR #123 / ask id 456））が open な回答待ちの PR か確かめる
    # PR を閉じた・ラベルを外したタスクは、compute_state では完了扱いになり、本文の「回答待ちの PR」にも載らないので拒否する
    while IFS= read -r TASK; do
      if [[ "${TASK#*※回答待ち}" =~ PR[[:space:]]*#([0-9]+) ]]; then
        [[ ",$WAITING," == *",${BASH_REMATCH[1]},"* ]] \
          || fail "goal の ※回答待ち のタスクの PR #${BASH_REMATCH[1]} が、open な回答待ちの PR（needs-answer）ではありません。goal を直すか、resume でループを再開してください: $TASK"
      else
        fail "goal の ※回答待ち のタスクに PR 番号がありません。goal を直してください: $TASK"
      fi
    done < <(grep -E '^- \[ \].*※回答待ち' "$GOAL" || true)
    FINAL_STATE=$(compute_state true "$WAITING")
    case "$FINAL_STATE" in
      completed | waiting-for-answer) ;;
      waiting-to-start) fail "goal に未完了のタスクが残っています（${GOAL}）。scripts/askhub-manual.sh resume $LOOP_DISCUSSION でループを再開してください" ;;
      *) fail "ループの状態が「$(state_title "$FINAL_STATE")」のため、最終 PR を作れません" ;;
    esac
    # マージせずに閉じた PR は既存として扱わない（作り直せるように）。open かマージ済みがあれば作らない
    EXISTING=$(gh pr list -R "$REPOSITORY" --head "$EPIC" --base "$BASE_BRANCH" --state all --json url,state --jq '[.[] | select(.state != "CLOSED")][0].url // ""')
    if [[ -n "$EXISTING" ]]; then
      echo "最終 PR は既にあります: $EXISTING"
      exit 0
    fi
    SUMMARY=$(awk '/^## 最終 PR に載せる内容/{f=1; next} /^## /{f=0} f' "$RALPH_STATE" 2>/dev/null | grep -v '^<!--.*-->$' || true)
    [[ -n "$(printf '%s' "$SUMMARY" | tr -d '[:space:]')" ]] || fail "$RALPH_STATE の「最終 PR に載せる内容」が空です（ループが STEP D で埋めます）"
    gh label create epic-final -R "$REPOSITORY" --color B60205 --description "epic から develop への最終 PR" >/dev/null 2>&1 || true
    # 回答待ちの PR は、ループが書いた内容に頼らず、この時点で open なものを本文に載せる（ask の内容は各 PR を見てもらう）
    if [[ -n "$WAITING" ]]; then
      SUMMARY=$(printf '%s\n\n## 回答待ちの PR\n\n%s\n\n質問の内容はそれぞれの PR の ask を確認してください。' "$SUMMARY" "$(printf '%s\n' "${WAITING//,/$'\n'}" | sed 's/^/- #/')")
    fi
    # 先頭の 2 行は、マージ時にゴール元の Discussion を閉じるワークフロー（close-goal-discussion.yml）が読む目印
    BODY=$(printf 'ゴール元: Discussion #%s\n<!-- ask-hub:discussion %s -->\n\n%s\n\n---\nこの PR は手動ループ（@%s）が作成しました。AskHub アプリの「要対応」タブの「マージ待ち」から確認して、merge commit でマージしてください。\n' \
      "$DISCUSSION" "$DISCUSSION" "$SUMMARY" "$(state_get runner)")
    URL=$(gh pr create -R "$REPOSITORY" --base "$BASE_BRANCH" --head "$EPIC" --title "【FEAT】$EPIC を $BASE_BRANCH に取り込む" \
      --assignee @me --label epic-final --body "$BODY")
    echo "最終 PR を作りました: $URL"
    if [[ "$BASE_BRANCH" != develop ]]; then
      echo "注意: base が develop ではないため、マージしてもゴール元の Discussion は自動で閉じません（close-goal-discussion.yml は develop へのマージだけを見る）。マージ後に Discussion #$DISCUSSION を手で閉じてください" >&2
    fi
    write_status true true
    ;;

  *)
    usage
    ;;
esac
