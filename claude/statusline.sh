#!/usr/bin/env bash
# Claude Code status line:
#   <model> <effort> with <cache> in <repo@branch> on <worktree> for <PR> as <agent> using <vim>      ctx · 5h · 7d · cost
#   (session block, then usage block; the usage block drops to a second row when both do not fit)
# Needs bash >= 4.2, jq and git.

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "statusline: bash >= 4.2 required"; exit 0
fi
command -v jq > /dev/null || { echo "statusline: jq required"; exit 0; }
umask 077                                        # the git cache file stays private

# ---- settings -----------------------------------------------------------------
CTX_WARN=(6 25 50 76)       # context used %: grey, green, yellow, orange, red
LIMIT_WARN=(6 40 70 85)     # 5h and 7d  limits used %: grey, green, yellow, orange, red
PACE_WARN=(100 105 110 115) # % of the limit projected at reset: grey(not shown), green, yellow, orange, red
CACHE_WARN=(0 50 80)        # % of the cache TTL already used: green, yellow, orange (red = cold)
HIT_WARN=(70 50)            # cache hit %: below the first is yellow, below the second orange; otherwise dim
DOTS=5                      # length of the 5h and 7d meters
BRANCH_MAX_CHAR=28          # Branch names longer than this number of characters will be truncated
GIT_TTL=5                   # seconds a cached `git status` stays fresh
MARGIN=4                    # columns kept free at the right edge
MIN_GAP=3                   # min spaces between the session and usage blocks on one row
ROWS=${STATUSLINE_ROWS:-auto} # 2: always two rows | 1: one row, two only if it does not fit | auto: by pane width
SESSION_BLOCK_WIDTH=125     # auto only: columns the session block (model … repo … extras) takes when nearly full
USAGE_BLOCK_WIDTH=78        # auto only: columns the usage block (ctx · 5h · 7d · cost) takes when nearly full
                            # auto uses one row only if SESSION + USAGE + MIN_GAP + MARGIN <= COLUMNS, else two

RST= BOLD= DIM= GRAY= GREEN= YELLOW= ORANGE= RED= BLUE= CYAN= MAGENTA=
if [[ -z ${NO_COLOR:-} ]]; then
  RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' GRAY=$'\e[90m' ORANGE=$'\e[38;5;215m'
  GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' BLUE=$'\e[34m' CYAN=$'\e[36m' MAGENTA=$'\e[35m'
fi
SEV=("$GRAY" "$GREEN" "$YELLOW" "$ORANGE" "$RED") # color by severity 0-4
SEP=" ${DIM}·${RST} "                            # inside a block
GAP=" "                                          # between the session block and its extras
QUARTERS=(○ ◔ ◑ ◕ ●)                            # empty to full

# ---- input: jq rounds and defaults, so every field below is text or an integer --
read_input() { # stdin -> one variable per field; unit separator keeps empty fields apart
  IFS=$'\x1f' read -r model effort fast ctx ctx_size five five_at week week_at \
    warm observed expires ttl recache hit misses cents dur_ms \
    dir session origin agent vim worktree pr pr_state < <(jq -r '
    def s:  if . == null then "" else tostring | gsub("[\t\n\r\u001f]"; " ") end;
    def n:  if type == "number" then floor else "" end;
    def pc: if type == "number" then round else "" end;
    def x100: if type == "number" then . * 100 | round else "" end;
    def secs: (. // "" | tostring) as $t
      | if   $t | test("^[0-9]+m$") then ($t[:-1] | tonumber) * 60
        elif $t | test("^[0-9]+h$") then ($t[:-1] | tonumber) * 3600
        else 300 end
      | if . > 0 then . else 300 end;
    [ (.model.display_name // .model.id | s), (.effort.level | s),
      (if .fast_mode == true then "true" else "" end),
      (.context_window.used_percentage | pc), (.context_window.context_window_size | n),
      (.rate_limits.five_hour.used_percentage | pc), (.rate_limits.five_hour.resets_at | n),
      (.rate_limits.seven_day.used_percentage | pc), (.rate_limits.seven_day.resets_at | n),
      (.prompt_cache.warm | s), (.prompt_cache.caching_observed | s),
      (.prompt_cache.expires_at | n), (.prompt_cache.ttl | secs),
      (.prompt_cache.recache_tokens_if_cold | n), (.prompt_cache.hit_ratio | x100),
      (.prompt_cache.misses | n),
      (.cost.total_cost_usd | x100), (.cost.total_duration_ms | n),
      (.workspace.current_dir // .cwd | s), (.session_id | s), (.workspace.repo.name | s),
      (.agent.name | s), (.vim.mode | s),
      (.worktree.name // .workspace.git_worktree | s),
      (.pr.number | s), (.pr.review_state | s) ] | join("\u001f")' 2>/dev/null)
}

# ---- text helpers -------------------------------------------------------------
time_left() { # epoch -> REPLY = 2h10, or 3d from one day on
  local s=$(( $1 - now ))
  (( s < 0 )) && s=0
  if (( s >= 86400 )); then REPLY="$(( s / 86400 ))d"
  else printf -v REPLY '%dh%02d' $(( s / 3600 )) $(( s % 3600 / 60 )); fi
}

duration() { # ms -> REPLY = <1m, 47m or 1h05m
  local m=$(( $1 / 60000 ))
  if   (( m < 1 ));  then REPLY='<1m'
  elif (( m < 60 )); then REPLY="${m}m"
  else printf -v REPLY '%dh%02dm' $(( m / 60 )) $(( m % 60 )); fi
}

tokens() { # n -> REPLY = 900, 45k or 1.2M
  local n=$1 tenths
  if   (( n < 1000 ));    then REPLY=$n
  elif (( n < 1000000 )); then REPLY="$(( (n + 500) / 1000 ))k"
  else tenths=$(( (n + 50000) / 100000 )); REPLY="$(( tenths / 10 )).$(( tenths % 10 ))M"; fi
}

visible_length() { # text -> REPLY = length without color sequences
  local rest=$1 plain=
  while [[ $rest == *$'\e['* ]]; do
    plain+=${rest%%$'\e['*}
    rest=${rest#*$'\e['}
    rest=${rest#*m}
  done
  REPLY=$(( ${#plain} + ${#rest} ))
}

join_by() { # separator parts... -> REPLY = the non-empty parts joined
  local sep=$1 out= part
  shift
  for part; do [[ -n $part ]] && out+=${out:+$sep}$part; done
  REPLY=$out
}

tag() { # label value -> REPLY = dimmed label + value; empty without value
  REPLY=
  [[ -n $2 ]] && REPLY="${DIM}$1${RST} $2"
}

# ---- severity, colors and meters ----------------------------------------------
severity() { # value thresholds... -> REPLY = how many thresholds it reaches
  local value=$1 t
  shift
  REPLY=0
  for t; do (( value >= t )) && REPLY=$(( REPLY + 1 )); done
}

meter() { # pct color -> REPLY = DOTS dots, the filled ones (rounded up) in color
  local filled=$(( ($1 * DOTS + 99) / 100 )) i on= off=
  (( filled > DOTS )) && filled=$DOTS
  for (( i = 0; i < DOTS; i++ )); do
    if (( i < filled )); then on+='●'; else off+='○'; fi
  done
  REPLY="$2${on}${DIM}${off}${RST}"
}

# ---- git: one `git status` per session every GIT_TTL seconds ------------------
declare -A GIT=()           # branch staged modified untracked conflicted ahead behind repo

git_scan() { # dir -> GIT; empty branch outside a repo
  local out line oid= x y staged=0 modified=0 untracked=0 conflicted=0
  GIT=([branch]= [staged]=0 [modified]=0 [untracked]=0 [conflicted]=0 [ahead]=0 [behind]=0 [repo]=)
  out=$(git --no-optional-locks -C "$1" status --porcelain=v2 --branch 2>/dev/null) || return
  while IFS= read -r line; do
    case $line in
      '# branch.oid '*)  oid=${line#'# branch.oid '} ;;
      '# branch.head '*) GIT[branch]=${line#'# branch.head '} ;;
      '# branch.ab '*)   read -r _ _ x y <<< "$line"; GIT[ahead]=${x#+} GIT[behind]=${y#-} ;;
      [12]' '*)          x=${line:2:1} y=${line:3:1}             # changed or renamed: XY
                         [[ $x != . ]] && staged=$(( staged + 1 ))
                         [[ $y != . ]] && modified=$(( modified + 1 )) ;;
      'u '*)             conflicted=$(( conflicted + 1 )) ;;      # unmerged
      '? '*)             untracked=$(( untracked + 1 )) ;;
    esac
  done <<< "$out"
  GIT[staged]=$staged GIT[modified]=$modified GIT[untracked]=$untracked GIT[conflicted]=$conflicted
  [[ ${GIT[branch]} == '(detached)' ]] && GIT[branch]=${oid:0:7}
  out=$(git --no-optional-locks -C "$1" rev-parse --show-toplevel 2>/dev/null)
  GIT[repo]=${out##*/}
}

git_status() { # dir -> GIT, from this session's cache file while it is fresh
  local cache=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/claude-statusline file
  local ts at br st mo un cf ah be rp end
  file=$cache/git-${session//[^A-Za-z0-9_-]/_}
  if [[ -r $file ]]; then
    IFS='|' read -r ts at br st mo un cf ah be rp end < "$file"
    if [[ $end == . && $at == "$1" && $ts =~ ^[0-9]+$ ]] && (( now - ts < GIT_TTL )); then
      GIT=([branch]=$br [staged]=$st [modified]=$mo [untracked]=$un [conflicted]=$cf [ahead]=$ah [behind]=$be [repo]=$rp)
      return
    fi
  else                                           # first run of a session: prune old cache files
    mkdir -p "$cache" 2>/dev/null
    find "$cache" -maxdepth 1 -type f -name 'git-*' -mtime +1 -delete 2>/dev/null
  fi
  git_scan "$1"
  # one line, ended by "." so a file cut short by a cancelled run is never trusted
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|.\n' "$now" "$1" "${GIT[branch]}" "${GIT[staged]}" \
    "${GIT[modified]}" "${GIT[untracked]}" "${GIT[conflicted]}" "${GIT[ahead]}" "${GIT[behind]}" \
    "${GIT[repo]}" > "$file" 2>/dev/null
}

# ---- segments: each sets REPLY ---------------------------------------------------
model_text() { # the family word in bold and its color, the rest as is
  local lower=${model,,} word color before
  REPLY=
  [[ -n $model ]] || return
  case $lower in
    *fable*)  word=fable  color=$MAGENTA ;;
    *mythos*) word=mythos color=$MAGENTA ;;
    *opus*)   word=opus   color=$CYAN ;;
    *sonnet*) word=sonnet color= ;;
    *haiku*)  word=haiku  color=$GRAY ;;
    *)        REPLY="${BOLD}${model}${RST}"; return ;;
  esac
  before=${lower%%"$word"*}
  REPLY="${model:0:${#before}}${BOLD}${color}${model:${#before}:${#word}}${RST}${model:$(( ${#before} + ${#word} ))}"
}

effort_text() {
  case $effort in
    '')     REPLY= ;;
    low)    REPLY="${YELLOW}low${RST}" ;;
    medium) REPLY="${GREEN}medium${RST}" ;;
    high)   REPLY="${BLUE}high${RST}" ;;
    xhigh)  REPLY="${MAGENTA}xhigh${RST}" ;;
    max)    REPLY="${MAGENTA}m${RED}a${YELLOW}x${RST}" ;;
    *)      REPLY="${GRAY}${effort}${RST}" ;;
  esac
}

cache_text() { # cache ● hot 38m 94% · 2 miss
  local label="${DIM}cache${RST}" sev=1 glyph='●' word=hot tail= left used out
  if [[ -z $warm && -z $observed ]]; then REPLY="$label ${GRAY}○ --${RST}"; return; fi
  if [[ $observed == false ]];      then REPLY="$label ${GRAY}○ off${RST}"; return; fi
  if [[ $warm != true ]] || { [[ -n $expires ]] && (( expires <= now )); }; then
    sev=4 glyph='○' word=cold                    # cold: a full rebuild is coming
    [[ -n $recache ]] && { tokens "$recache"; tail=" +$REPLY"; }
  elif [[ -n $expires ]]; then
    left=$(( expires - now ))
    used=$(( (ttl - left) * 100 / ttl ))
    (( used < 0 )) && used=0
    severity "$used" "${CACHE_WARN[@]}"; sev=$REPLY
    (( sev == 3 )) && word=exp
    if (( left < 60 )); then tail=' <1m'; else tail=" $(( (left + 59) / 60 ))m"; fi
  fi
  out="$label ${SEV[sev]}${glyph} ${word}${tail}${RST}"
  if [[ -n $hit ]]; then
    if   (( hit < HIT_WARN[1] )); then out+=" ${ORANGE}${hit}%${RST}"
    elif (( hit < HIT_WARN[0] )); then out+=" ${YELLOW}${hit}%${RST}"
    else                               out+=" ${DIM}${hit}%${RST}"; fi
  fi
  (( ${misses:-0} > 0 )) && out+="${SEP}${misses} miss"
  REPLY=$out
}

project_text() { # folder, or repo@branch +1 ~2 ?3 ↑1 ↓2 inside a git repo
  local folder branch repo parts=()
  REPLY=
  [[ -n $dir ]] || return
  folder=${dir##*/}
  [[ $dir == "${HOME-}" ]] && folder='~'
  [[ -z $folder ]] && folder=/
  git_status "$dir"
  if [[ -z ${GIT[branch]} ]]; then REPLY=$folder; return; fi
  branch=${GIT[branch]}
  (( ${#branch} > BRANCH_MAX_CHAR )) && branch="${branch:0:BRANCH_MAX_CHAR-1}…"
  repo=${origin:-${GIT[repo]:-$folder}}          # origin's name, else the repo folder
  (( GIT[staged] > 0 ))     && parts+=("${GREEN}+${GIT[staged]}${RST}")
  (( GIT[modified] > 0 ))   && parts+=("${YELLOW}~${GIT[modified]}${RST}")
  (( GIT[untracked] > 0 ))  && parts+=("${GRAY}?${GIT[untracked]}${RST}")
  (( GIT[ahead] > 0 ))      && parts+=("${MAGENTA}↑${GIT[ahead]}${RST}")
  (( GIT[behind] > 0 ))     && parts+=("${MAGENTA}↓${GIT[behind]}${RST}")
  (( GIT[conflicted] > 0 )) && parts+=("${RED}=${GIT[conflicted]}${RST}")
  REPLY="${repo}${DIM}@${RST}${branch}${parts:+ ${parts[*]}}"
}

pr_text() { # for PR #123 approved (changes_requested is not shown)
  REPLY=
  [[ -n $pr ]] || return
  tag for "PR #$pr"
  [[ -n $pr_state && $pr_state != changes_requested ]] && REPLY+=" ${DIM}${pr_state}${RST}"
}

ctx_text() { # ctx ◑ 42% of 1M /compact?
  local sev color q of= hint=
  [[ -n $ctx ]] || { REPLY="${DIM}ctx${RST} ${GRAY}--${RST}"; return; }
  severity "$ctx" "${CTX_WARN[@]}"; sev=$REPLY; color=${SEV[sev]}
  q=$(( (ctx + 12) / 25 )); (( q > 4 )) && q=4   # nearest quarter
  if (( ${ctx_size:-0} >= 1000000 )); then of=" ${DIM}of $(( ctx_size / 1000000 ))M${RST}"
  elif (( ${ctx_size:-0} > 0 )); then      of=" ${DIM}of $(( ctx_size / 1000 ))k${RST}"; fi
  (( sev == 3 )) && hint=" ${color}/compact?${RST}"
  (( sev == 4 )) && hint=" ${color}/compact${RST}"
  REPLY="${DIM}ctx${RST} ${color}${QUARTERS[q]} ${ctx}%${RST}${of}${hint}"
}

pace() { # used reset window -> REPLY = " pace+" colored by the % projected at reset
  local elapsed=$(( $3 - ($2 - now) ))
  REPLY=
  (( elapsed > $3 )) && elapsed=$3
  (( elapsed > 0 )) || return
  severity $(( $1 * $3 / elapsed )) "${PACE_WARN[@]}"   # same rate until the reset
  if (( REPLY > 0 )); then REPLY=" ${SEV[REPLY]}pace+${RST}"; else REPLY=; fi
}

limit_text() { # label used reset window -> 5h ●●○○○ 34% ↻ 2h10 pace+
  local label="${DIM}$1${RST}" sev color text
  [[ -n $2 ]] || { REPLY="$label ${GRAY}--${RST}"; return; }
  severity "$2" "${LIMIT_WARN[@]}"; sev=$REPLY; color=${SEV[sev]}
  meter "$2" "$color"
  text="$label $REPLY ${color}${2}%${RST}"
  if [[ -n $3 ]]; then
    time_left "$3"; text+=" ${DIM}↻ ${REPLY}${RST}"
    pace "$2" "$3" "$4"; text+=$REPLY
  fi
  REPLY=$text
}

cost_text() { # ~$1.24 over 47m (a list-price estimate, hence the tilde)
  local cost= elapsed=
  [[ -n $cents ]] && printf -v cost '~$%d.%02d' $(( cents / 100 )) $(( cents % 100 ))
  (( ${dur_ms:-0} > 0 )) && { duration "$dur_ms"; elapsed=$REPLY; }
  if [[ -n $cost && -n $elapsed ]]; then REPLY="${cost} ${DIM}over${RST} ${elapsed}"
  else REPLY=${cost}${elapsed}; fi
}

# ---- main ---------------------------------------------------------------------
main() {
  local ident session_block usage_block ulen two free spaces= extras=() c h w
  read_input
  now=${STATUSLINE_NOW:-}
  [[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
  cols=${COLUMNS:-100}
  [[ $cols =~ ^[0-9]+$ ]] || cols=100

  # session block: "<model> <effort> <fast> with <cache> in <project> on <worktree> for <PR> as <agent> using <vim>"
  model_text; ident=$REPLY
  effort_text; join_by ' ' "$ident" "$REPLY" "${fast:+fast}"; ident=$REPLY
  cache_text; session_block="$ident ${DIM}with${RST} $REPLY"
  project_text; [[ -n $REPLY ]] && session_block+=" ${DIM}in${RST} $REPLY"
  tag on "${worktree:+worktree $worktree}";      extras+=("$REPLY")
  pr_text;                                       extras+=("$REPLY")
  tag as "$agent";                               extras+=("$REPLY")
  tag using "${vim:+vim $vim}";                  extras+=("$REPLY")
  join_by "$GAP" "$session_block" "${extras[@]}"; session_block=$REPLY

  # usage block, pushed to the right edge
  ctx_text; c=$REPLY
  limit_text 5h "$five" "$five_at" $(( 5 * 3600 )); h=$REPLY
  limit_text 7d "$week" "$week_at" $(( 7 * 86400 )); w=$REPLY
  cost_text
  join_by "$SEP" "$c" "$h" "$w" "$REPLY"; usage_block=$REPLY

  visible_length "$session_block"; free=$(( cols - MARGIN - REPLY ))
  visible_length "$usage_block";   ulen=$REPLY; free=$(( free - ulen ))
  # with auto the row count depends on the width only, so it does not jump as git or extras change;
  # `free < MIN_GAP` is the safety net when the blocks do not fit on one row
  two=
  case $ROWS in
    2) two=1 ;;
    1) ;;
    *) (( SESSION_BLOCK_WIDTH + USAGE_BLOCK_WIDTH + MIN_GAP + MARGIN > cols )) && two=1 ;;   # auto
  esac
  if [[ -n $two ]] || (( free < MIN_GAP )); then
    # Claude Code strips leading spaces from each row, so a gray line (not spaces) fills the gap:
    # it keeps the usage block at the right edge and tells the two rows apart
    printf -v spaces '%*s' "$(( cols - MARGIN > ulen + 1 ? cols - MARGIN - ulen - 1 : 0 ))" ''
    printf '%s\n%s\n' "$session_block" "${GRAY}${spaces// /─}${RST} ${usage_block}"
  else
    printf -v spaces '%*s' "$free" ''
    printf '%s\n' "${session_block}${spaces}${usage_block}"
  fi
}

main
