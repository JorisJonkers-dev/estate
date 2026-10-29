# shellcheck shell=bash
# shellcheck disable=SC2034 # the names below are read by the drills that source this
#
# What every drill shares, on top of bootstrap's wizard and estate libraries.
#
# A drill runs its own changes: each is a block of commands it shows, saves in
# the run's record and runs, stopping if they fail. Between changes it checks
# the cluster, Vault, RabbitMQ and the network from this machine until the
# change has taken effect, and carries on by itself. A drill that stops early
# removes what it created. A run that goes to plan asks for nothing.
#
# DRILL_HAND=1 hands every change to you instead: it is copied to the
# clipboard for you to run in a second terminal, and the drill waits until it
# sees the effect.
#
# Unlike the bootstrap wizards, a drill never clears the screen: what it saw
# stays on screen, and every line also lands in the run's record.

if ((BASH_VERSINFO[0] < 5)); then
  printf 'A drill needs bash 5 or newer (brew install bash).\n' >&2
  exit 1
fi

DRILLS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../../bootstrap/lib/wizard.sh
source "$DRILLS/../bootstrap/lib/wizard.sh"
# shellcheck source=../../bootstrap/lib/estate.sh
source "$DRILLS/../bootstrap/lib/estate.sh"

# Every time a drill prints or records is UTC, so a record reads the same
# wherever it was made.
export TZ=UTC
CYAN=""
[[ -n "$BLUE" ]] && CYAN=$(tput setaf 6)

DRILL_POLL=${DRILL_POLL:-2}
DRILL_STATE=${DRILL_STATE:-$HOME/.local/state/estate-drills}
DRILL_HAND=${DRILL_HAND:-}  # set: hand every change to you rather than run it
DRILL_POST=${DRILL_POST:-yes} # no: write the result, but do not post it
DRILL_CHECK=""  # --check: run the preflight and stop
ISSUE=""        # the deploy-kit issue the drill settles
CTX=""          # the kubectl context every read and every change names
KC=""           # the kubectl prefix every change starts with
RUN_ID=""       # <issue>-<UTC time>: names the record and marks the posted result
RUN_DIR=""
EVENTS=""       # every line the drill printed, with its time
RESULT=""       # the Markdown the drill posts on its issue
T0=$EPOCHSECONDS
CHANGES=0
LAST_CHANGE=""
WAITING_ON_YOU="" # set when a change is handed to you, until a wait sees its effect
HINT=""         # what a wait's check last saw, shown beside the spinner
CHOICE=""
TEARDOWN=""     # commands that remove what the drill created
TEARDOWN_DONE=""
BG_PIDS=()

# Events print on fd 3, which stays the terminal while a wait silences its
# check, so a check can report what it sees as it sees it.
exec 3>&1

# ── Output ────────────────────────────────────────────────────────────────

_log() { [[ -n "$EVENTS" ]] && printf '%(%Y-%m-%dT%H:%M:%SZ)T  %s\n' -1 "$*" >>"$EVENTS"; return 0; }
_strip() { sed 's/\x1b\[[0-9;]*m//g; s/\x1b(B//g' <<<"$1"; }

say() { _spin_clear; printf '  %s\n' "$1" >&3; _log "$(_strip "$1")"; }
step() { _spin_clear; printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1" >&3; _log "$1"; }
note() { _spin_clear; printf '  %s%s%s\n' "$DIM" "$1" "$RESET" >&3; _log "$1"; }
warn() { _spin_clear; printf '  %s⚠ %s%s\n' "$YELLOW" "$1" "$RESET" >&3; _log "WARN $1"; }
ok() { _spin_clear; printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1" >&3; _log "OK $(_strip "$1")"; }
bad() { _spin_clear; printf '  %s✗%s %s\n' "$RED" "$RESET" "$1" >&3; _log "FAIL $1"; }
die() {
  _spin_clear
  trap - ERR
  printf '\n  %s✗ %s%s\n\n' "$RED" "$1" "$RESET" >&2
  _log "STOP $1"
  exit 1
}
# event TEXT prints a line of the drill's timeline, stamped with the time
# since the drill started.
event() { _spin_clear; printf '  %s%s%s  %s\n' "$CYAN" "$(since)" "$RESET" "$1" >&3; _log "EVENT $(_strip "$1")"; }
# shout TEXT is an instruction for something only you can do: it rings the
# terminal bell.
shout() {
  _spin_clear
  _bell
  printf '\n  %s%s▶ %s%s\n' "$BOLD" "$YELLOW" "$1" "$RESET" >&3
  _log "ASK $1"
}

stage() {
  _spin_clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ %s/%s  %s%s\n' "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET" >&3
  _log "STAGE $_STAGE_INDEX/$TOTAL_STAGES $1"
}

_bell() { [[ -t 1 ]] && printf '\a'; return 0; }
_dur() { if (($1 >= 60)); then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi; }
since() { local s=$((EPOCHSECONDS - T0)); printf '+%d:%02d' $((s / 60)) $((s % 60)); }
# ms_now prints the time in epoch milliseconds.
ms_now() { local t=${EPOCHREALTIME/[.,]/}; printf '%s' "${t:0:${#t}-3}"; }

_SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
_SPIN_I=0
_SPUN=""
_spin() {
  [[ -t 1 ]] || return 0
  local s=$((EPOCHSECONDS - $2)) line
  line="${_SPIN[_SPIN_I++ % 10]} $1 · $(_dur "$s")${HINT:+ · $HINT}"
  ((${#line} > ${COLUMNS:-100} - 4)) && line="${line:0:${COLUMNS:-100}-5}…"
  printf '\r\033[K  %s%s%s%s%s' "$CYAN" "${line:0:1}" "$DIM" "${line:1}" "$RESET" >&3
  _SPUN=yes
}
_spin_clear() { [[ -n "$_SPUN" ]] && printf '\r\033[K' >&3; _SPUN=""; return 0; }
COLUMNS=$( (tput cols 2>/dev/null || echo 100) | tail -n 1)

# ── Changes ───────────────────────────────────────────────────────────────

_copy() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s\n' "$1" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s\n' "$1" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then printf '%s\n' "$1" | xclip -selection clipboard
  else return 1
  fi
}

# change TITLE shows the commands on stdin as a block, saves them as the run's
# next numbered file, and runs them with bash -e; their output lands beside
# the file. When they fail it asks whether to run them again or stop (stop,
# without a terminal). With DRILL_HAND set it runs nothing: it copies them to
# the clipboard, and the next wait waits on you.
change() {
  local title="$1" body line file out rc
  body=$(cat)
  CHANGES=$((CHANGES + 1))
  file="$RUN_DIR/$(printf '%02d' "$CHANGES")-$(tr 'A-Z ' 'a-z-' <<<"$title" | tr -cd 'a-z0-9-').sh"
  printf '%s\n' "$body" >"$file"
  LAST_CHANGE=$body
  _spin_clear
  if [[ -n "$DRILL_HAND" ]]; then
    WAITING_ON_YOU=yes
    _bell
    printf '\n  %s┌─ you run: %s%s%s\n' "$YELLOW" "$BOLD" "$title" "$RESET" >&3
    while IFS= read -r line; do printf '  %s│%s %s\n' "$YELLOW" "$RESET" "$line" >&3; done <<<"$body"
    if _copy "$body"; then
      printf '  %s└─ copied to the clipboard · also in %s%s\n' "$YELLOW" "$file" "$RESET" >&3
    else
      printf '  %s└─ saved in %s%s\n' "$YELLOW" "$file" "$RESET" >&3
    fi
    _log "HANDED $title ($file)"
    return 0
  fi
  printf '\n  %s┌─ %s%s%s\n' "$CYAN" "$BOLD" "$title" "$RESET" >&3
  while IFS= read -r line; do printf '  %s│%s %s\n' "$CYAN" "$RESET" "$line" >&3; done <<<"$body"
  while :; do
    rc=0
    out=$(bash -e -o pipefail "$file" 2>&1 </dev/null) || rc=$?
    printf '%s\n' "$out" >"$file.out"
    while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  %s│ %s%s\n' "$CYAN" "$DIM$line" "$RESET" >&3
    done <<<"$out"
    if ((rc == 0)); then
      printf '  %s└─ done%s\n' "$CYAN" "$RESET" >&3
      _log "RAN $title ($file)"
      return 0
    fi
    printf '  %s└─ failed, exit %s%s\n' "$RED" "$rc" "$RESET" >&3
    _log "FAILED $rc $title ($file): $(tail -n 3 <<<"$out" | tr '\n' ' ')"
    choose "Run it again (r), or stop (q)?" r q
    [[ "$CHOICE" == q ]] && die "stopped: $title failed"
  done
}

# ── Waiting on a check ────────────────────────────────────────────────────

# wait_until DESCRIPTION SECONDS CHECK...: runs CHECK every DRILL_POLL seconds,
# with its output silenced, until it succeeds; SECONDS 0 waits for as long as
# it takes. While it waits, c copies the last change again, s gives up on the
# wait and q stops the drill. Returns 0 once CHECK succeeded, 1 on the time
# limit, 2 when skipped.
#
# The first wait after a change handed to you waits at your pace: it has no
# time limit, and says so until its check sees something.
wait_until() {
  local desc="$1" limit="$2" start=$EPOCHSECONDS key i
  shift 2
  HINT=""
  [[ -n "$WAITING_ON_YOU" ]] && limit=0
  while :; do
    if "$@" >/dev/null 2>&1; then
      WAITING_ON_YOU=""
      ok "$desc $DIM($(_dur $((EPOCHSECONDS - start))))$RESET"
      return 0
    fi
    [[ -n "$WAITING_ON_YOU" && -z "$HINT" ]] && HINT="waiting for you to run the command above in a second terminal (c copies it again)"
    if ((limit > 0 && EPOCHSECONDS - start >= limit)); then
      bad "$desc: not within $(_dur "$limit")${HINT:+ (last seen: $HINT)}"
      return 1
    fi
    for ((i = 0; i < DRILL_POLL * 5; i++)); do
      _spin "$desc" "$start"
      key=""
      if [[ -t 0 ]]; then read -rsn1 -t 0.2 key || true; else sleep 0.2; fi
      case "$key" in
        c) [[ -n "$LAST_CHANGE" ]] && _copy "$LAST_CHANGE" && note "copied the last change again" ;;
        s) warn "skipped: $desc"; return 2 ;;
        q) die "stopped while waiting for: $desc" ;;
      esac
    done
  done
}

# need is wait_until, except that on its time limit it asks once whether to
# keep waiting, carry on without it, or stop. Returns 0, 1 (carried on) or 2.
need() {
  local rc
  while :; do
    rc=0
    wait_until "$@" || rc=$?
    ((rc == 1)) || return "$rc"
    choose "Keep waiting (w), carry on without it (c), or stop (q)?" w c q
    case "$CHOICE" in
      c) return 1 ;;
      q) die "stopped at: $1" ;;
    esac
  done
}

# choose QUESTION KEY...: reads one of the keys into CHOICE. Without a
# terminal to ask, it takes the last key, which every caller makes the
# cautious one.
choose() {
  local question="$1" key option
  shift
  _spin_clear
  if [[ ! -t 0 ]]; then
    CHOICE=${!#}
    printf '  %s? %s%s %s(no terminal: %s)%s\n' "$YELLOW" "$question" "$RESET" "$DIM" "$CHOICE" "$RESET" >&3
    _log "CHOSE $CHOICE, no terminal: $question"
    return 0
  fi
  _bell
  while :; do
    printf '  %s? %s%s ' "$YELLOW" "$question" "$RESET" >&3
    key=""
    read -rsn1 key || true
    printf '%s\n' "$key" >&3
    for option in "$@"; do
      if [[ "$key" == "$option" ]]; then
        CHOICE=$key
        _log "CHOSE $key: $question"
        return 0
      fi
    done
  done
}

# ── The run ───────────────────────────────────────────────────────────────

# drill_start ISSUE TITLE ARG...: opens the run's record and says what the
# drill does. --check runs the preflight and stops.
drill_start() {
  ISSUE="$1"
  local title="$2"
  shift 2
  case "${1:-}" in
    --check) DRILL_CHECK=yes ;;
    "") ;;
    *) die "unknown argument $1 (only --check)" ;;
  esac
  RUN_ID="$ISSUE-$(printf '%(%Y%m%dT%H%M%SZ)T' -1)"
  RUN_DIR="$DRILL_STATE/$RUN_ID"
  (umask 077 && mkdir -p "$RUN_DIR")
  EVENTS="$RUN_DIR/events.log"
  RESULT="$RUN_DIR/result.md"
  : >"$EVENTS"
  trap drill_exit EXIT
  trap 'exit 130' INT TERM
  # A command that fails where the drill did not expect it says where, rather
  # than the drill ending without a word.
  set -E
  trap '_failed "$LINENO" "$BASH_COMMAND" "$?"' ERR
  printf '\n%s%s  Drill #%s · %s%s\n' "$BOLD" "$BLUE" "$ISSUE" "$title" "$RESET" >&3
  printf '  %shttps://github.com/%s/deploy-kit/issues/%s%s\n' "$DIM" "$ORG" "$ISSUE" "$RESET" >&3
  printf '  %s%s stages · record in %s%s\n\n' "$DIM" "$TOTAL_STAGES" "$RUN_DIR" "$RESET" >&3
  _log "drill #$ISSUE, run $RUN_ID, estate $(estate_revision)"
  if [[ -n "$DRILL_CHECK" ]]; then
    note "--check: the preflight only; it changes nothing."
    return 0
  fi
  if [[ -n "$DRILL_HAND" ]]; then
    say "DRILL_HAND: each change is a command copied for you to run in a second terminal;"
    say "the drill checks the result itself and moves on."
  else
    say "This drill makes its changes itself, each shown before it runs, and checks"
    say "every result before it moves on. Stopping early removes what it created."
  fi
  say "While it waits: ${BOLD}s${RESET} skips the wait · ${BOLD}q${RESET} stops."
  printf '\n' >&3
  [[ -t 0 ]] && pause "Enter to start, Ctrl-C to leave."
  return 0
}

_failed() {
  # A command substitution inherits the trap; only the drill itself reports.
  [[ "$BASHPID" == "$$" ]] || return 0
  trap - ERR
  _spin_clear
  printf '\n  %s✗ %s, line %s: "%s" exited %s%s\n' "$RED" "$(basename "$0")" "$1" "$2" "$3" "$RESET" >&2
  _log "STOP line $1: $2 exited $3"
}

# check_only ends a --check run after its preflight.
check_only() {
  [[ -n "$DRILL_CHECK" ]] || return 0
  printf '\n' >&3
  ok "preflight passed; --check stops here"
  exit 0
}

drill_exit() {
  local code=$? pid
  trap - ERR
  _spin_clear
  for pid in "${BG_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ -n "$TEARDOWN" && -z "$TEARDOWN_DONE" ]]; then
    TEARDOWN_DONE=yes
    printf '\n' >&3
    warn "The drill stopped before its teardown; this removes what it created:"
    change "Remove what the drill created" <<<"$TEARDOWN" || true
  fi
  [[ -n "$RUN_DIR" ]] && note "Record: $RUN_DIR"
  estate_cleanup
  return "$code"
}

estate_revision() {
  local rev
  rev=$(git -C "$DRILLS" rev-parse --short HEAD 2>/dev/null) || { printf 'unknown'; return; }
  git -C "$DRILLS" diff --quiet HEAD -- . 2>/dev/null || rev="$rev, with local changes"
  printf '%s' "$rev"
}

# ── The cluster ───────────────────────────────────────────────────────────

kc() { "$KUBECTL" --context "$CTX" --request-timeout=20s "$@"; }

preflight_cluster() {
  require_tools "$KUBECTL" jq
  CTX=${DRILL_CONTEXT:-$("$KUBECTL" config current-context 2>/dev/null || true)}
  [[ -n "$CTX" ]] || die "kubectl has no current context: set DRILL_CONTEXT"
  local nodes
  nodes=$(kc get nodes -o name 2>/dev/null | wc -l | tr -d ' ')
  ((nodes > 0)) || die "kubectl cannot list the nodes of context $CTX"
  KC="kubectl --context $CTX"
  ok "kubectl reads context $BOLD$CTX$RESET: $nodes nodes"
}

# absent ARG...: succeeds when `kubectl get ARG...` answers NotFound. A read
# that fails any other way is never taken for "absent".
absent() {
  local out
  out=$(kc get "$@" -o name 2>&1) && return 1
  grep -q -e NotFound -e 'not found' <<<"$out"
}

node_ready() {
  [[ "$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}

# pick_nodes SELECTOR PREFERRED...: sets NODES to two Ready, schedulable nodes
# matching SELECTOR, DRILL_NODES's when it names them, else the preferred ones
# first.
NODES=()
pick_nodes() {
  local selector="$1" candidates node
  shift
  candidates=$(kc get nodes ${selector:+-l "$selector"} -o json | jq -r '.items[]
    | select((.spec.unschedulable // false) | not)
    | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))
    | .metadata.name') || die "cannot list the nodes"
  NODES=()
  if [[ -n "${DRILL_NODES:-}" ]]; then
    for node in $DRILL_NODES; do
      grep -qx "$node" <<<"$candidates" || die "DRILL_NODES names $node, which is not a Ready, schedulable node${selector:+ matching $selector}"
      NODES+=("$node")
    done
  else
    for node in "$@" $candidates; do
      ((${#NODES[@]} < 2)) || break
      grep -qx "$node" <<<"$candidates" || continue
      [[ " ${NODES[*]} " == *" $node "* ]] || NODES+=("$node")
    done
  fi
  ((${#NODES[@]} == 2)) || die "need two Ready, schedulable nodes${selector:+ matching $selector}; found: ${candidates//$'\n'/ }"
  ok "the drill runs on $BOLD${NODES[0]}$RESET and $BOLD${NODES[1]}$RESET ${DIM}(DRILL_NODES to choose others)$RESET"
}

# clear_leftovers NAMESPACE...: a namespace an earlier run left is removed
# before this one starts, so every run starts from nothing.
clear_leftovers() {
  local ns
  for ns in "$@"; do
    if absent namespace "$ns"; then
      ok "no namespace $ns left from an earlier run"
      continue
    fi
    warn "namespace $ns is still there from an earlier run; it goes first"
    change "Remove the earlier run's namespace $ns" <<<"$KC delete namespace $ns --wait=false"
    need "namespace $ns gone" 600 absent namespace "$ns" || die "namespace $ns is still there"
  done
}

# no_release_in_flight succeeds when no Canary is mid-analysis anywhere, so a
# drill that takes a node or Flagger down disturbs no release.
no_release_in_flight() {
  local busy
  busy=$(kc get canaries.flagger.app -A -o json | jq -r '.items[]
    | select(.status.phase as $p | ["Progressing", "Promoting", "Finalising", "Waiting", "WaitingPromotion"] | index($p))
    | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"') || return 1
  HINT=${busy//$'\n'/, }
  [[ -z "$busy" ]]
}

# ── The result ────────────────────────────────────────────────────────────

res() { printf '%s\n' "$@" >>"$RESULT"; }

# result_head TITLE starts the result with what ran, where and when.
result_head() {
  : >"$RESULT"
  res "## Drill result: $1" "" \
    "<!-- drill-run: $RUN_ID -->" \
    "Run \`$RUN_ID\` of [\`drills/$(basename "$0")\`](https://github.com/$ESTATE/blob/main/drills/$(basename "$0")) (estate $(estate_revision)), against kubectl context \`$CTX\`, $(printf '%(%Y-%m-%d %H:%M)T' "$T0")–$(printf '%(%H:%M)T' -1) UTC." ""
}

# show_result prints the result and posts it on the drill's issue, unless
# DRILL_POST=no.
show_result() {
  local line
  printf '\n' >&3
  while IFS= read -r line; do printf '  %s│%s %s\n' "$DIM" "$RESET" "$line" >&3; done <"$RESULT"
  printf '\n' >&3
  if [[ "$DRILL_POST" == no ]]; then
    note "DRILL_POST=no: not posted. To post it: gh issue comment $ISSUE --repo $ORG/deploy-kit --body-file $RESULT"
    return 0
  fi
  change "Post the result on #$ISSUE" <<<"gh issue comment $ISSUE --repo $ORG/deploy-kit --body-file $RESULT"
  wait_until "the result is on #$ISSUE" 300 result_posted || true
}

drill_done() {
  printf '\n  %s%s✓ Drill #%s complete%s %s(%s)%s\n' "$BOLD" "$GREEN" "$ISSUE" "$RESET" "$DIM" "$(_dur $((EPOCHSECONDS - T0)))" "$RESET" >&3
  _log "DONE"
}

result_posted() {
  gh api "repos/$ORG/deploy-kit/issues/$ISSUE/comments?per_page=100" --paginate --jq '.[].body' 2>/dev/null \
    | grep -qF "drill-run: $RUN_ID"
}
