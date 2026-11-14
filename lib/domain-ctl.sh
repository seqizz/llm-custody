# llm-custody domain controller.
#
# Changes the network whitelist of a running jail without restarting it.
# One implementation for three callers: the operator from a second terminal
# ($RUNDIR/domain, `llm-custody domain`), and the request broker when the
# operator approves an agent's `custody-request --domain`.
#
# The whitelist has two halves, both inside the holder's network namespace:
# dnsmasq, which forwards an allowed name upstream and answers everything
# else with the address=/#/ catch-all, and the nftables address sets, which
# only let traffic out to addresses an allowed lookup returned. Adding a
# domain regenerates the dnsmasq config, restarts dnsmasq and pre-arms the
# sets with the new name's addresses. Removing one does the same restart and
# then replaces the sets' contents with the addresses of what is still
# allowed, because nothing records which address came from which name.
#
# Invocation: domain-ctl RUNDIR <command> [args]. The runner writes
# RUNDIR/domain.env (holder pid, upstream resolver, state root) only when
# the network filter is on; without it there is nothing to manage.
#
# Interface, relied on by the broker and `llm-custody domain`
# (toolbox/src): stdout carries only the lines below, diagnostics go to
# stderr. Exit 0 on success, 2 when NAME is not a valid domain, 1 otherwise.
#
#   add [--persist] -- NAME      NAME<TAB>session|persist
#   remove [--persist] -- NAME   NAME<TAB>removed
#   list                         NAME<TAB>SOURCE per line
#   blocked                      COUNT<TAB>NAME per line, allowed names excluded
#
# Wrapped by lib/domain-ctl.nix, which prepends lib/log.sh (the log/warn/die
# helpers) and lib/net-filter.sh.

RUNDIR=""
VERBOSITY=1
# Everything below is set by RUNDIR/domain.env, written by the runner with
# `declare -p`. Declared here first so a missing key reads as empty rather
# than as an unbound variable.
HOLDER_PID=""
STATE_ROOT=""
UPSTREAM_DNS=""
DNSMASQ_PID=""

# A name that fails domain_valid gets its own exit status, so a caller can
# tell "you asked for something malformed" from "the session could not do it".
invalid() { err "$*"; exit 2; }

usage() {
  cat <<'USAGE'
Usage: domain add [--persist] [--] NAME
       domain remove [--persist] [--] NAME
       domain list
       domain blocked

  add      allow NAME (and its subdomains) for the rest of the session
           --persist  also append it to --state-dir/domains, so every
                      later session allows it from the start
  remove   stop allowing NAME. Its DNS forward goes, and the IP whitelist
           is rebuilt from what is still allowed
           --persist  also drop it from --state-dir/domains
  list     the allowed names, each with where it came from: default
           (the tool's built-in list), file (--state-dir/domains), flag
           (--allow-domain or a *_BASE_URL host) or live (added here)
  blocked  names the jail looked up and got the catch-all for, with how
           often, most frequent first
USAGE
  exit 0
}

if [ $# -lt 1 ]; then usage; fi
RUNDIR="$1"; shift
[ -d "$RUNDIR" ] || die "no such session runtime dir: $RUNDIR"
[ -r "$RUNDIR/domain.env" ] || die "$RUNDIR/domain.env missing - this session runs without the network filter, or has already ended"
# shellcheck source=/dev/null
. "$RUNDIR/domain.env"
if [ -z "$HOLDER_PID" ] || ! kill -0 "$HOLDER_PID" 2>/dev/null; then
  die "the session's namespace holder (pid ${HOLDER_PID:-?}) is gone"
fi

ACTIVE="$RUNDIR/domains.active"
PERSIST_FILE="$STATE_ROOT/domains"

# The holder's network namespace is where dnsmasq, the nftables sets and the
# pre-resolve all live; user and mount come along because the network one is
# owned by the holder's user namespace.
nsenter_holder() {
  nsenter -U -m -n -t "$HOLDER_PID" --preserve-credentials -- "$@"
}

# A broker approval and an operator action can arrive at the same moment,
# and two read-modify-write passes over domains.active would lose one of
# them. Held until the script exits.
take_lock() {
  exec 9>"$RUNDIR/domain.lock"
  flock 9
}

# Source tag of NAME in domains.active, failure when it is not active.
active_source() {
  local want="$1" name src
  [ -r "$ACTIVE" ] || return 1
  while IFS=$'\t' read -r name src; do
    if [ "$name" = "$want" ]; then
      printf '%s' "$src"
      return 0
    fi
  done < "$ACTIVE"
  return 1
}

# Rewrites domains.active through a temp file and a rename, so a reader
# (list, blocked, the conf generator) never sees half of it. With a second
# argument the line is appended, otherwise NAME's line is dropped.
rewrite_active() {
  local drop="$1" add_src="${2:-}" name src
  {
    if [ -r "$ACTIVE" ]; then
      while IFS=$'\t' read -r name src; do
        [ -n "$name" ] || continue
        [ -z "$add_src" ] && [ "$name" = "$drop" ] && continue
        printf '%s\t%s\n' "$name" "$src"
      done < "$ACTIVE"
    fi
    if [ -n "$add_src" ]; then
      printf '%s\t%s\n' "$drop" "$add_src"
    fi
  } > "$ACTIVE.tmp"
  mv -f "$ACTIVE.tmp" "$ACTIVE"
}

# Restarts the session's dnsmasq on the freshly written config. A restart and
# not a SIGHUP: see net_write_dnsmasq_conf for why a reload cannot pick up a
# changed server list here. The new instance daemonizes (no
# --keep-in-foreground): it must outlive this script, and dnsmasq's parent
# only exits once the child has bound its address or failed to, so the exit
# status says whether DNS is back. Its stdio goes nowhere this script's
# caller is reading, or the broker would wait on a pipe the daemon holds.
#
# Lookups that arrive in the gap between the old instance exiting and the
# new one binding go unanswered and are retried by the resolver after its
# timeout (glibc: 5s).
restart_dnsmasq() {
  local pid
  pid=$(net_dnsmasq_pid "$RUNDIR")
  if [ -z "$pid" ] && net_dnsmasq_alive "$DNSMASQ_PID"; then
    pid="$DNSMASQ_PID"
  fi
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      net_dnsmasq_alive "$pid" || break
      sleep 0.02
    done
    if net_dnsmasq_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.05
    fi
  fi
  rm -f "$RUNDIR/dnsmasq.pid"
  if ! nsenter_holder dnsmasq --conf-file="$RUNDIR/dnsmasq.conf" \
         --pid-file="$RUNDIR/dnsmasq.pid" \
         </dev/null >/dev/null 2>"$RUNDIR/dnsmasq.restart.log"; then
    return 1
  fi
  for _ in $(seq 1 100); do
    [ -s "$RUNDIR/dnsmasq.pid" ] && return 0
    sleep 0.02
  done
  return 1
}

# Regenerates the config and restarts dnsmasq; dies with the reason on
# failure. ROLLBACK is the rewrite_active call that undoes the change, run
# before a second restart attempt so a bad state never outlives the error.
apply_or_rollback() {
  local line
  net_write_dnsmasq_conf "$RUNDIR" "$UPSTREAM_DNS"
  restart_dnsmasq && return 0
  err "dnsmasq did not come back up on the new config:"
  while IFS= read -r line; do hint "$line"; done < "$RUNDIR/dnsmasq.restart.log"
  "$@"
  net_write_dnsmasq_conf "$RUNDIR" "$UPSTREAM_DNS"
  if restart_dnsmasq; then
    hint "the previous whitelist is back in place"
  else
    hint "dnsmasq is down: every lookup in the jail fails until the session restarts"
  fi
  exit 1
}

persist_has() {
  local want="$1" line
  [ -r "$PERSIST_FILE" ] || return 1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ "${line,,}" = "$want" ] && return 0
  done < "$PERSIST_FILE"
  return 1
}

# Appends NAME to --state-dir/domains, the file the runner reads at every
# launch. Through a temp copy and a rename, like everything else written
# here, and with a newline supplied when the file's last line lacks one.
persist_add() {
  local name="$1"
  persist_has "$name" && return 0
  mkdir -p "$STATE_ROOT"
  {
    if [ -s "$PERSIST_FILE" ]; then
      cat "$PERSIST_FILE"
      [ -z "$(tail -c1 "$PERSIST_FILE")" ] || printf '\n'
    fi
    printf '%s\n' "$name"
  } > "$PERSIST_FILE.tmp"
  mv -f "$PERSIST_FILE.tmp" "$PERSIST_FILE"
}

# Drops every line naming NAME from --state-dir/domains. Comments and blank
# lines stay: the file is the operator's, edited by hand as often as not.
persist_drop() {
  local name="$1" line trimmed
  [ -r "$PERSIST_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ "${trimmed,,}" = "$name" ] && continue
    printf '%s\n' "$line"
  done < "$PERSIST_FILE" > "$PERSIST_FILE.tmp"
  mv -f "$PERSIST_FILE.tmp" "$PERSIST_FILE"
}

# Addresses dnsmasq has handed out this session for names that are still
# allowed, from its own log. Re-arming from a fresh lookup alone is not
# enough after a flush: a CDN answers a new lookup with different addresses
# than the ones an open connection (an agent's API stream, say) is using,
# and the drop policy has no conntrack exception to keep that connection
# alive.
#
# An answer is logged as consecutive "reply|cached NAME is VALUE" lines,
# a CNAME chain as "is <CNAME>" lines leading to the target's addresses.
# A line counts when its name is allowed, or when it continues a counted
# answer: the previous line was a <CNAME> step or named the same host.
logged_ips() {
  local log="$1" line rest kind name value prev_name="" prev_value="" ok=0
  shift
  [ -r "$log" ] || return 0
  while IFS= read -r line; do
    rest="${line#*]: }"
    kind="${rest%% *}"
    case "$kind" in
      reply|cached) ;;
      *) ok=0; prev_name=""; prev_value=""; continue ;;
    esac
    case "$rest" in
      *" is "*) ;;
      *) ok=0; prev_name=""; prev_value=""; continue ;;
    esac
    value="${rest##* is }"
    name="${rest% is *}"
    name="${name#* }"
    if domain_covered "$name" "$@"; then
      ok=1
    elif [ "$ok" = "1" ] && { [ "$prev_value" = "<CNAME>" ] || [ "$name" = "$prev_name" ]; }; then
      ok=1
    else
      ok=0
    fi
    prev_name="$name"
    prev_value="$value"
    [ "$ok" = "1" ] || continue
    if net_ip_family "$value" >/dev/null; then printf '%s\n' "$value"; fi
  done < "$log"
}

# Replaces the contents of both address sets with the addresses of what is
# still allowed, in one nft transaction: there is no moment in which a
# still-allowed address is missing from the sets, and if the batch fails
# the old contents stay (nothing is flushed). The non-atomic fallback below
# does leave such a window, in which a connect to a still-allowed domain
# can be dropped and has to be retried.
rearm_sets() {
  local -a names
  local ip fam batch line
  mapfile -t names < <(net_active_names "$ACTIVE")
  batch="$RUNDIR/nft-rearm"
  {
    printf 'flush set inet filter allowed\n'
    printf 'flush set inet filter allowed6\n'
    {
      net_resolve "${names[@]+"${names[@]}"}"
      if [ "${#names[@]}" -gt 0 ]; then
        logged_ips "$RUNDIR/dnsmasq.log" "${names[@]}"
      fi
    } | sort -u | while IFS= read -r ip; do
      fam=$(net_ip_family "$ip") || continue
      if [ "$fam" = "6" ]; then
        printf 'add element inet filter allowed6 { %s }\n' "$ip"
      else
        printf 'add element inet filter allowed { %s }\n' "$ip"
      fi
    done
  } > "$batch"
  if nsenter_holder nft -f "$batch" 2>"$batch.err"; then
    vlog "IP whitelist rebuilt with $(( $(wc -l < "$batch") - 2 )) address(es)"
    rm -f "$batch" "$batch.err"
    return 0
  fi
  warn "atomic rebuild of the IP whitelist failed, flushing and re-adding one by one:"
  while IFS= read -r line; do hint "$line"; done < "$batch.err"
  nsenter_holder nft flush set inet filter allowed 2>/dev/null || true
  nsenter_holder nft flush set inet filter allowed6 2>/dev/null || true
  net_prearm "${names[@]+"${names[@]}"}"
  rm -f "$batch" "$batch.err"
}

# Common argument parsing for add and remove: [--persist] [--] NAME, NAME
# lowercased and validated.
PERSIST=0
NAME=""
parse_name_args() {
  local verb="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --persist) PERSIST=1; shift ;;
      -h|--help) usage ;;
      --) shift; break ;;
      -*) die "$verb: unknown option: $1" ;;
      *) [ -z "$NAME" ] || die "$verb takes exactly one domain"; NAME="$1"; shift ;;
    esac
  done
  if [ $# -gt 0 ]; then
    [ -z "$NAME" ] && [ $# -eq 1 ] || die "$verb takes exactly one domain"
    NAME="$1"
  fi
  [ -n "$NAME" ] || die "$verb: which domain?"
  NAME="${NAME,,}"
  domain_valid "$NAME" || invalid "not a valid domain name: $NAME (plain hostname, at least two labels, no wildcard or IP)"
}

cmd_add() {
  local src
  parse_name_args add "$@"
  take_lock
  if src=$(active_source "$NAME"); then
    log "$NAME is already allowed ($src)"
  else
    rewrite_active "$NAME" live
    apply_or_rollback rewrite_active "$NAME"
    net_prearm "$NAME"
    log "$NAME allowed for this session"
  fi
  if [ "$PERSIST" = "1" ]; then
    persist_add "$NAME"
    log "$NAME persisted in $PERSIST_FILE"
    printf '%s\tpersist\n' "$NAME"
  else
    printf '%s\tsession\n' "$NAME"
  fi
}

cmd_remove() {
  local src="" in_file=0
  parse_name_args remove "$@"
  take_lock
  src=$(active_source "$NAME") || src=""
  persist_has "$NAME" && in_file=1
  if [ "$PERSIST" = "1" ] && [ "$src" = "default" ]; then
    die "$NAME is one of this tool's built-in domains (tools.nix allowedDomains), so only the session can drop it - run remove without --persist"
  fi
  if [ -z "$src" ] && { [ "$PERSIST" = "0" ] || [ "$in_file" = "0" ]; }; then
    die "$NAME is not on this session's whitelist"
  fi
  if [ -n "$src" ]; then
    # The source tag is kept for the rollback, so a failed restart puts the
    # name back as what it was rather than as a live addition.
    rewrite_active "$NAME"
    apply_or_rollback rewrite_active "$NAME" "$src"
    rearm_sets
    log "$NAME no longer allowed in this session"
  fi
  if [ "$PERSIST" = "1" ]; then
    persist_drop "$NAME"
    log "$NAME dropped from $PERSIST_FILE"
  elif [ "$in_file" = "1" ]; then
    hint "$NAME is still listed in $PERSIST_FILE and comes back next launch (remove --persist drops it there too)"
  fi
  printf '%s\tremoved\n' "$NAME"
}

cmd_list() {
  [ -r "$ACTIVE" ] || return 0
  local name src
  while IFS=$'\t' read -r name src; do
    if [ -n "$name" ]; then printf '%s\t%s\n' "$name" "$src"; fi
  done < "$ACTIVE"
}

cmd_blocked() {
  net_blocked_counts "$RUNDIR/dnsmasq.log" "$ACTIVE"
}

case "${1:-}" in
  add|allow)     shift; cmd_add "$@" ;;
  remove|rm)     shift; cmd_remove "$@" ;;
  list|ls)       cmd_list ;;
  blocked)       cmd_blocked ;;
  ""|-h|--help)  usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
