#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "statusline: bash >= 4.2 required"; exit 0
fi
command -v jq > /dev/null || { echo "statusline: jq required"; exit 0; }

# ---- settings -----------------------------------------------------------------
CTX_WARN=(6 25 50 76)       # context used %: grey, green, yellow, orange, red
LIMIT_WARN=(6 40 70 85)     # 5h and 7d limits used %: same colors
PACE_WARN=(100 105 110 115) # % of the limit projected at reset: green, yellow, orange, red (below the first: not shown)
CACHE_WARN=(0 50 80)        # % of the cache TTL already used: green, yellow, orange (red = cold)
HIT_WARN=(70 50)            # cache hit %: below the first is yellow, below the second orange; otherwise dim
DOTS=5                      # length of the 5h and 7d meters
MARGIN=4                    # columns kept free at the right edge

RST= BOLD= DIM= GRAY= GREEN= YELLOW= ORANGE= RED= BLUE= CYAN= MAGENTA=
if [[ -z ${NO_COLOR:-} ]]; then
  RST=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[2m' GRAY=$'\e[90m' ORANGE=$'\e[38;5;215m'
  GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m' BLUE=$'\e[34m' CYAN=$'\e[36m' MAGENTA=$'\e[35m'
fi
SEV=("$GRAY" "$GREEN" "$YELLOW" "$ORANGE" "$RED") # color by severity 0-4
SEP=" ${DIM}·${RST} "
QUARTERS=(○ ◔ ◑ ◕ ●)                            # empty to full

# ---- input: jq rounds and defaults, so every field below is text or an integer --
read_input() { # stdin -> one variable per field; unit separator keeps empty fields apart
  IFS=$'\x1f' read -r model effort fast ctx ctx_size five five_at week week_at \
    warm observed expires ttl recache hit < <(jq -r '
    def s:  if . == null then "" else tostring | gsub("[\u0001-\u001f\u007f]"; " ") end;
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
      (.prompt_cache.recache_tokens_if_cold | n), (.prompt_cache.hit_ratio | x100) ] | join("\u001f")' 2>/dev/null)
}

# ---- helpers ------------------------------------------------------------------
severity() { # value thresholds... -> REPLY = how many thresholds it reaches
  local value=$1 t
  shift
  REPLY=0
  for t; do (( value >= t )) && REPLY=$(( REPLY + 1 )); done
}

time_left() { # epoch -> REPLY = 2h10, or 3d from one day on
  local s=$(( $1 - now ))
  (( s < 0 )) && s=0
  if (( s >= 86400 )); then REPLY="$(( s / 86400 ))d"
  else printf -v REPLY '%dh%02d' $(( s / 3600 )) $(( s % 3600 / 60 )); fi
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

truncate_visible() { # text width -> REPLY = text cut to width visible columns, colors kept and closed
  local rest=$1 max=$2 out= seq
  while [[ -n $rest ]] && (( max > 0 )); do
    if [[ $rest == $'\e['* ]]; then              # color sequence: copied whole, takes no column
      seq=${rest%%m*}m; out+=$seq; rest=${rest#"$seq"}
    else
      out+=${rest:0:1}; rest=${rest:1}; max=$(( max - 1 ))
    fi
  done
  REPLY="${out}${RST}"
}

join_by() { # separator parts... -> REPLY = the non-empty parts joined
  local sep=$1 out= part
  shift
  for part; do [[ -n $part ]] && out+=${out:+$sep}$part; done
  REPLY=$out
}

meter() { # pct color -> REPLY = DOTS dots, the filled ones (rounded up) in color
  local filled=$(( ($1 * DOTS + 99) / 100 )) i on= off=
  (( filled > DOTS )) && filled=$DOTS
  for (( i = 0; i < DOTS; i++ )); do
    if (( i < filled )); then on+='●'; else off+='○'; fi
  done
  REPLY="$2${on}${DIM}${off}${RST}"
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

cache_text() { # cache ● hot 38m 94%
  local label="${DIM}cache${RST}" sev=1 glyph='●' word=hot tail= left used out hit_color=$DIM
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
    (( hit < HIT_WARN[0] )) && hit_color=$YELLOW
    (( hit < HIT_WARN[1] )) && hit_color=$ORANGE
    out+=" ${hit_color}${hit}%${RST}"
  fi
  REPLY=$out
}

ctx_text() { # ctx ◑ 42% of 1M /compact?
  local sev q of= hint=
  [[ -n $ctx ]] || { REPLY="${DIM}ctx${RST} ${GRAY}--${RST}"; return; }
  severity "$ctx" "${CTX_WARN[@]}"; sev=$REPLY
  q=$(( (ctx + 12) / 25 )); (( q > 4 )) && q=4   # nearest quarter
  if   (( ${ctx_size:-0} >= 1000000 )); then of=" ${DIM}of $(( ctx_size / 1000000 ))M${RST}"
  elif (( ${ctx_size:-0} > 0 ));        then of=" ${DIM}of $(( ctx_size / 1000 ))k${RST}"; fi
  (( sev == 3 )) && hint=" ${ORANGE}/compact?${RST}"
  (( sev == 4 )) && hint=" ${RED}/compact${RST}"
  REPLY="${DIM}ctx${RST} ${SEV[sev]}${QUARTERS[q]} ${ctx}%${RST}${of}${hint}"
}

limit_text() { # label used reset window -> 5h ●●○○○ 34% ↻ 2h10 ↗ (↗ = on track to pass the limit before reset)
  local sev elapsed text
  [[ -n $2 ]] || { REPLY="${DIM}$1${RST} ${GRAY}--${RST}"; return; }
  severity "$2" "${LIMIT_WARN[@]}"; sev=$REPLY
  meter "$2" "${SEV[sev]}"
  text="${DIM}$1${RST} $REPLY ${SEV[sev]}${2}%${RST}"
  if [[ -n $3 ]]; then
    time_left "$3"; text+=" ${DIM}↻ ${REPLY}${RST}"
    elapsed=$(( $4 - ($3 - now) ))
    (( elapsed > $4 )) && elapsed=$4
    if (( elapsed > 0 )); then
      severity $(( $2 * $4 / elapsed )) "${PACE_WARN[@]}"   # same rate until the reset
      (( REPLY > 0 )) && text+=" ${SEV[REPLY]}↗${RST}"
    fi
  fi
  REPLY=$text
}

# ---- blocks -------------------------------------------------------------------
left_text() { # model effort fast with cache
  local ident
  model_text; ident=$REPLY
  effort_text; join_by ' ' "$ident" "$REPLY" "${fast:+fast}"; ident=$REPLY
  cache_text; join_by ' ' "$ident" "${DIM}with${RST} $REPLY"
}

usage_text() { # ctx · 5h · 7d
  local c h w
  ctx_text; c=$REPLY
  limit_text 5h "$five" "$five_at" $(( 5 * 3600 )); h=$REPLY
  limit_text 7d "$week" "$week_at" $(( 7 * 86400 )); w=$REPLY
  join_by "$SEP" "$c" "$h" "$w"
}

# ---- main ---------------------------------------------------------------------
main() {
  local left right llen rlen free spaces line
  read_input
  now=${STATUSLINE_NOW:-}
  [[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
  cols=${COLUMNS:-100}
  [[ $cols =~ ^[0-9]+$ ]] || cols=100

  left_text;  left=$REPLY;  visible_length "$left";  llen=$REPLY
  usage_text; right=$REPLY; visible_length "$right"; rlen=$REPLY

  free=$(( cols - MARGIN - llen - rlen ))
  (( free < 1 )) && free=1
  printf -v spaces '%*s' "$free" ''
  line=${left}${spaces}${right}
  if (( llen + free + rlen > cols - MARGIN )); then   # does not fit: cut the end at the panel edge
    truncate_visible "$line" $(( cols - MARGIN )); line=$REPLY
  fi
  printf '%s\n' "$line"
}

main
