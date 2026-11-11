# `llm-custody-mount`: attach a host tree to a live session, or detach one,
# without having to keep the $RUNDIR/mount path the runner printed at launch.
#
# The runner registers every run under $XDG_RUNTIME_DIR/llm-custody as
# <pid>.mount plus a `current.mount` symlink to the most recent one. This is
# just a front end over that registry; the controller itself (lib/mount-ctl.sh)
# does the work, host-side only - the jail never sees $RUNDIR, and an agent
# gets a tree only by asking through custody-request and being approved.
{ pkgs }:
pkgs.writeShellApplication {
  name = "llm-custody-mount";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    set -euo pipefail

    # Same fallback chain the runner uses when it registers a session, so
    # both sides agree on the directory on hosts without XDG_RUNTIME_DIR.
    REG_DIR="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/llm-custody"

    usage() {
      printf 'Usage: llm-custody-mount [--list | --pid PID] [--pause] COMMAND [args...]\n'
      printf '\n'
      printf '  add [--mode ro|full|limited|none|overlay] [--guest PATH] [--name NAME] HOSTPATH\n'
      printf '  remove [--auto|--discard] NAME|GUESTPATH\n'
      printf '  list\n'
      printf '  docks\n'
      printf '\n'
      printf '  (no option)  act on the most recently started session\n'
      printf '  --pid PID    act on that specific session\n'
      printf '  --list       list live sessions\n'
      printf '  --pause      wait for a keypress before exiting, so a pane a terminal\n'
      printf '               keybinding spawned does not close over the output\n'
      printf '  (no command) prompt for a host path and add it read-only\n'
      printf '\n'
      printf 'Sessions register under %s as <pid>.mount.\n' "$REG_DIR"
      exit 0
    }

    list_sessions() {
      local entry pid found=0
      for entry in "$REG_DIR"/*.mount; do
        [ -e "$entry" ] || continue
        pid="''${entry##*/}"
        pid="''${pid%.mount}"
        kill -0 "$pid" 2>/dev/null || continue
        found=1
        printf '%s  (pid %s)\n' "$(readlink -f "$entry")" "$pid"
        "$entry" list 2>&1 | while IFS= read -r line; do printf '    %s\n' "$line"; done
      done
      [ "$found" = "1" ] || printf 'no live llm-custody sessions\n' >&2
    }

    TARGET="$REG_DIR/current.mount"
    PAUSE=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -h|--help) usage ;;
        --list|-l) list_sessions; exit 0 ;;
        --pid)
          [ $# -ge 2 ] || { printf 'ERROR: --pid needs a value\n' >&2; exit 1; }
          TARGET="$REG_DIR/$2.mount"; shift 2 ;;
        --pause) PAUSE=1; shift ;;
        --) shift; break ;;
        *) break ;;
      esac
    done

    if [ ! -e "$TARGET" ]; then
      printf 'ERROR: no such llm-custody session: %s\n' "$TARGET" >&2
      printf '       llm-custody-mount --list shows the live ones\n' >&2
      exit 1
    fi

    # With nothing else on the line this is a keybinding's way in: ask for
    # the one thing it cannot know, the path.
    if [ $# -eq 0 ]; then
      if [ ! -t 0 ]; then usage; fi
      printf 'host path to mount read-only (add --mode for anything else): ' >&2
      IFS= read -r path || exit 1
      [ -n "$path" ] || exit 1
      set -- add -- "$path"
    fi

    status=0
    "$TARGET" "$@" || status=$?
    if [ "$PAUSE" = "1" ]; then
      printf '\n[enter to close] ' >&2
      IFS= read -r _ || true
    fi
    exit "$status"
  '';
}
