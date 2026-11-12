# llm-custody network filter helpers, shared by the runner (launch-time
# whitelist) and the domain controller (lib/domain-ctl.sh, live changes), so
# a domain allowed at launch and one allowed mid-session go through the same
# validation, the same dnsmasq config and the same nftables pre-arm.
#
# Interpolated into lib/mkBwrapRunner.nix's text and concatenated into
# lib/domain-ctl.nix, like lib/jail-tree.sh: functions only, nothing runs at
# load time. The callers provide nsenter_holder (into the holder's user,
# mount and network namespaces) and vlog.
#
# $RUNDIR/domains.active is the session's whitelist as `NAME<TAB>SOURCE`
# lines, SOURCE one of default (tools.nix), file (--state-dir/domains), flag
# (--allow-domain, a *_BASE_URL host) or live (added mid-session). The
# dnsmasq config is always generated from it, never edited in place.

# The name ends up in a dnsmasq `server=/NAME/IP` line, where `/`, `#`,
# whitespace or a newline would be config injection, so only plain LDH
# hostnames pass: lowercase (callers normalize first), at most 253 chars,
# two or more labels of 1-63 [a-z0-9-] chars not starting or ending with
# `-`, no trailing dot, no wildcard, and not an IPv4 literal in any form
# inet_aton reads (decimal, octal, 0x hex, short forms; an IPv6 one
# already fails on `:`). Same rules as proto::validate_domain on the Rust
# side.
domain_valid() {
  local d="$1" label rest
  [ -n "$d" ] && [ "${#d}" -le 253 ] || return 1
  case "$d" in
    *[!a-z0-9.-]*|.*|*.|*..*) return 1 ;;
    *.*) ;;
    *) return 1 ;;
  esac
  # all_numeric tracks whether every label is a number inet_aton accepts
  # (decimal, octal, or 0x hex). Such a name is an IPv4 literal in disguise
  # (`0x7f.1`, `0x5d.0xb8.0xd8.0x22`): getaddrinfo parses it without asking
  # DNS, so net_prearm would put that address straight into the nft set.
  local all_numeric=1
  rest="$d"
  while [ -n "$rest" ]; do
    label="${rest%%.*}"
    if [ "$label" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
    [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
    case "$label" in -*|*-) return 1 ;; esac
    case "$label" in
      *[!0-9]*)
        case "$label" in
          0x*) case "${label#0x}" in *[!0-9a-f]*) all_numeric=0 ;; esac ;;
          *) all_numeric=0 ;;
        esac ;;
    esac
  done
  [ "$all_numeric" = 0 ]
}

# Whether NAME is one of the given domains or a subdomain of one, which is
# exactly what dnsmasq's server=/DOMAIN/ forwards.
domain_covered() {
  local name="$1" d
  shift
  for d in "$@"; do
    case "$name" in
      "$d"|*."$d") return 0 ;;
    esac
  done
  return 1
}

# Names of the active whitelist, one per line.
net_active_names() {
  local name _src
  [ -r "$1" ] || return 0
  while IFS=$'\t' read -r name _src; do
    if [ -n "$name" ]; then printf '%s\n' "$name"; fi
  done < "$1"
}

# 4 or 6 for a plain IPv4/IPv6 address, failure for anything else. The
# nftables element syntax is the only place these strings go, so nothing
# looser than hex digits, colons and dots gets through.
net_ip_family() {
  case "$1" in
    ""|0.0.0.0|::) return 1 ;;
    *:*)
      case "$1" in *[!0-9a-fA-F:]*) return 1 ;; esac
      printf '6' ;;
    *[!0-9.]*) return 1 ;;
    *.*.*.*) printf '4' ;;
    *) return 1 ;;
  esac
}

# Generates $RUNDIR/dnsmasq.conf from $RUNDIR/domains.active. Written to a
# temp file and renamed, so a dnsmasq (re)started concurrently never reads
# half a config.
#
# The whole config is regenerated and dnsmasq restarted on a change, rather
# than the server lines living in a `servers-file=` reloaded on SIGHUP:
# dnsmasq re-reads that file after it has dropped privileges to `nobody`
# (mapped into the holder's user namespace, so a subordinate host uid), and
# that uid cannot traverse the 0700 $RUNDIR. The reload would fail with a
# log line and keep the old list.
net_write_dnsmasq_conf() {
  local rundir="$1" upstream="$2" name
  {
    echo "no-resolv"
    echo "bind-interfaces"
    echo "listen-address=127.0.0.1"
    echo "log-queries"
    echo "log-facility=$rundir/dnsmasq.log"
    # Most-specific-match wins in dnsmasq, so each allowed domain gets a real
    # upstream and everything else falls through to the catch-all dead end -
    # this is the primary block, not just the nftables IP gate below.
    while IFS= read -r name; do
      echo "server=/$name/$upstream"
    done < <(net_active_names "$rundir/domains.active")
    # server= above forwards both A and AAAA lookups for allowed domains
    # to the same (dual-stack) upstream - only the catch-all needs a
    # separate line per family.
    echo "address=/#/0.0.0.0"
    echo "address=/#/::"
  } > "$rundir/dnsmasq.conf.tmp"
  mv -f "$rundir/dnsmasq.conf.tmp" "$rundir/dnsmasq.conf"
}

# Pid of the session's running dnsmasq, from its pid file. Checked against
# /proc so a pid recycled after a restart or a crash is never signalled.
net_dnsmasq_pid() {
  local pid
  pid=$(cat "$1/dnsmasq.pid" 2>/dev/null || true)
  if net_dnsmasq_alive "$pid"; then printf '%s' "$pid"; fi
}

# Whether PID is a live (not zombie) dnsmasq.
net_dnsmasq_alive() {
  local pid="$1" stat
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = "dnsmasq" ] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null || true)
  stat="${stat##*) }"
  [ "${stat%% *}" != "Z" ]
}

# Every address the given domains resolve to through the holder's network
# namespace, one per line, deduplicated. Unusable answers (the catch-all's
# 0.0.0.0/::, anything not a plain address) are dropped here.
#
# `getent ahosts`, not the ahostsv4/ahostsv6 pair this used to call:
# those two return rc=2 and print nothing on this glibc even for names
# that plainly resolve (the same quirk lib/selftest.nix documents),
# which made the whole pre-resolve a silent no-op and left the race it
# exists to close wide open. `ahosts` returns both families in one
# listing, so the family is decided by looking at the address.
net_resolve() {
  local d line ip
  command -v getent >/dev/null 2>&1 || return 0
  for d in "$@"; do
    while read -r line; do
      ip="${line%% *}"
      net_ip_family "$ip" >/dev/null || continue
      printf '%s\n' "$ip"
    done < <(nsenter_holder getent ahosts "$d" 2>/dev/null)
  done | sort -u
}

# First-connect race mitigation: the whitelist only learns an IP from
# dnsmasq's post-reply log line, so the first connect after a lookup
# can arrive before the set is armed. Pre-arm the sets with a
# host-side resolution of every allowed domain before the sandbox
# starts (resolved through the holder ns, inside the private netns, so
# the queries go out the same slirp link the sandbox will use and the
# answers match its resolver). The log watcher still tracks CDN record
# drift during the run. Also run for a domain added mid-session, for the
# same race.
net_prearm() {
  local ip n=0
  command -v getent >/dev/null 2>&1 || return 0
  while IFS= read -r ip; do
    case "$(net_ip_family "$ip")" in
      6) nsenter_holder nft add element inet filter allowed6 "{ $ip }" 2>/dev/null || true ;;
      4) nsenter_holder nft add element inet filter allowed "{ $ip }" 2>/dev/null || true ;;
      *) continue ;;
    esac
    n=$((n+1))
  done < <(net_resolve "$@")
  vlog "pre-armed the IP whitelist with $n address(es)"
}

# `COUNT<TAB>NAME` for every name that got the address=/#/ catch-all, most
# often blocked first. With a second argument (a domains.active file), names
# that file now allows, or a subdomain of one, are left out: a name blocked
# early and allowed since is no longer blocked.
#
# dnsmasq logs its own answer as "<source> <name> is <address>", so
# a name that landed on the address=/#/ catch-all reads as
# "... is 0.0.0.0" / "... is ::". Parsed from the right, like the
# whitelist watcher does, because the log line also carries a
# timestamp and a pid prefix.
net_blocked_counts() {
  local log="$1" active="${2:-}" line ip dom
  local -A count=()
  local -a allowed=()
  [ -r "$log" ] || return 0
  if [ -n "$active" ]; then
    mapfile -t allowed < <(net_active_names "$active")
  fi
  while IFS= read -r line; do
    case "$line" in
      *" is "*) ;;
      *) continue ;;
    esac
    ip="${line##* is }"
    case "$ip" in
      0.0.0.0|::) ;;
      *) continue ;;
    esac
    dom="${line% is *}"
    dom="${dom##* }"
    [ -n "$dom" ] || continue
    count[$dom]=$(( ${count[$dom]:-0} + 1 ))
  done < "$log"
  for dom in "${!count[@]}"; do
    if [ "${#allowed[@]}" -gt 0 ] && domain_covered "$dom" "${allowed[@]}"; then
      continue
    fi
    printf '%s\t%s\n' "${count[$dom]}" "$dom"
  done | sort -t $'\t' -k1,1nr -k2,2
}
