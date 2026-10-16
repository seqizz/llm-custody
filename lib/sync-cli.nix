# `llm-custody-sync`: find and run a live session's mid-session sync without
# having to keep the $RUNDIR/sync path the runner printed at launch.
#
# The runner registers every run under $XDG_RUNTIME_DIR/llm-custody as
# <pid>.sync plus a `current` symlink to the most recent one. This is just a
# front end over that registry, so it stays host-side only - $RUNDIR is never
# mounted into a sandbox, which is what keeps a jailed agent from syncing its
# own work out unreviewed.
{ pkgs }:
pkgs.writeShellApplication {
  name = "llm-custody-sync";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    set -euo pipefail

    # Same fallback chain the runner uses when it registers a session, so
    # both sides agree on the directory on hosts without XDG_RUNTIME_DIR.
    REG_DIR="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/llm-custody"

    usage() {
      printf 'Usage: llm-custody-sync [--list | PID] [-- sync-args...]\n'
      printf '\n'
      printf '  (no args)  sync the most recently started session\n'
      printf '  --list     list live sessions\n'
      printf '  PID        sync that specific session\n'
      printf '\n'
      printf 'Sessions register under %s as <pid>.sync.\n' "$REG_DIR"
      exit 0
    }

    # A session directory with no entries and a dead `current` symlink mean
    # the same thing to the operator - no running jail - so both report it
    # the same way instead of an ENOENT from the launcher.
    list_sessions() {
      local entry pid target rundir dirty found=0
      for entry in "$REG_DIR"/*.sync; do
        [ -e "$entry" ] || continue
        pid="''${entry##*/}"
        pid="''${pid%.sync}"
        kill -0 "$pid" 2>/dev/null || continue
        found=1
        target=$(readlink -f "$entry")
        # The runner's dirty counter lives next to the sync launcher it
        # registered, so the unsynced count comes for free here - which is
        # the whole point of listing sessions rather than just syncing one.
        rundir="''${target%/sync}"
        dirty=""
        [ -r "$rundir/dirty" ] && dirty=$(cat "$rundir/dirty" 2>/dev/null || true)
        case "''${dirty:-0}" in
          0|"") printf '%s  (pid %s, clean)\n' "$target" "$pid" ;;
          *)    printf '%s  (pid %s, %s unsynced path(s))\n' "$target" "$pid" "$dirty" ;;
        esac
      done
      [ "$found" = "1" ] || printf 'no live llm-custody sessions\n' >&2
    }

    TARGET="$REG_DIR/current"
    case "''${1:-}" in
      -h|--help) usage ;;
      --list|-l) list_sessions; exit 0 ;;
      ""|--) ;;
      -*) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 1 ;;
      *)  TARGET="$REG_DIR/$1.sync"; shift ;;
    esac
    # Remaining args go to the session's own sync launcher (e.g. --auto).
    # `if` rather than a `&&` chain: a false test as the last command of a
    # chain is the script's exit status under errexit.
    if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then shift; fi

    if [ ! -e "$TARGET" ]; then
      printf 'ERROR: no such llm-custody session: %s\n' "$TARGET" >&2
      printf '       llm-custody-sync --list shows the live ones\n' >&2
      exit 1
    fi

    exec "$TARGET" "$@"
  '';
}
