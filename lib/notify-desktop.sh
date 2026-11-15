# Default notify hook of the request broker: a desktop notification for every
# new agent request. Called by `llm-custody serve` as
#   <hook> <event> <id> <attr> <reason> <count> <label>
# with no shell in between, and never waited on.

event="${1:-}"
attr="${3:-}"
reason="${4:-}"
count="${5:-}"
label="${6:-}"

# Only a new request needs the operator. approved/denied are the operator's
# own actions, and `dropped` means the agent already carried on without it.
[ "$event" = "request" ] || exit 0

# A host with no session bus (ssh, a headless run) has nobody to notify, and
# notify-send would spend its D-Bus autolaunch timeout finding that out.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ ! -S "${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
  exit 0
fi

# Notification bodies are markup, and attr and reason are written inside the
# jail: unescaped, a bare `<` or `&` makes a server such as naughty reject or
# mangle the body, and a crafted reason could style itself as something else.
# The assignments stay unquoted on purpose: `\&` has to reach the expansion as
# a literal ampersand both with bash 5.2's patsub_replacement (where a bare
# `&` means "the match") and without it.
escape_markup() {
  local s=$1
  s=${s//&/\&amp;}
  s=${s//</\&lt;}
  s=${s//>/\&gt;}
  printf '%s' "$s"
}

body="<b>$(escape_markup "$attr")</b>"
if [ -n "$reason" ]; then
  body+=$'\n'"$(escape_markup "$reason")"
fi
if [ -n "$label" ]; then
  body+=$'\n'"$(escape_markup "$label")"
fi

summary="llm-custody: agent is waiting on a request"
case "$count" in
  "" | 0 | 1) ;;
  *) summary="llm-custody: agent is waiting on $count requests" ;;
esac

# Agent-written text goes in the body only, and after `--`, so it can be
# read neither as an option nor as the summary line.
exec notify-send \
  --app-name=llm-custody \
  --urgency=normal \
  --expire-time=30000 \
  -- "$summary" "$body"
