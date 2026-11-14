# Diagnostics shared by the runner (lib/mkBwrapRunner.nix) and the mount and
# domain controllers, so a message reads the same whichever of them prints
# it. Plain shell with no Nix interpolation; the callers set VERBOSITY.
#
# Everything goes to stderr, so the jailed tool keeps stdout to itself (a
# `-p` run piped into something else must not get runner chatter mixed into
# its output) and a controller's stdout stays the one line its caller parses.
#
# Colour follows the usual two conditions - stderr is a terminal and
# NO_COLOR is unset - so a redirected log stays plain text. The colours are
# exported because not every script that includes this uses all of them, and
# an assigned-but-unused variable fails the writeShellApplication build.
C_RESET=""; C_BOLD=""; C_DIM=""
C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
fi
export C_RESET C_BOLD C_DIM C_RED C_YELLOW C_GREEN C_CYAN

log()  { [ "$VERBOSITY" -ge 1 ] && printf '%sllm-custody:%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2 || true; }
vlog() { [ "$VERBOSITY" -ge 2 ] && printf '%sllm-custody:%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$*" "$C_RESET" >&2 || true; }
warn() { printf '%sllm-custody: WARNING%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%sllm-custody: ERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
# Continuation line under a log/warn/err message. Never suppressed by
# --quiet: it only ever appears attached to something already printed.
hint() { printf '            %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
