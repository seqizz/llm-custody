# `llm-custody-sync`: find and run a live session's mid-session sync without
# having to keep the $RUNDIR/sync path the runner printed at launch.
#
# The runner registers every run under $XDG_RUNTIME_DIR/llm-custody as
# <pid>.state (a key=value record describing the session) plus, when that
# session has isolated trees to fold back, <pid>.sync and a `current` symlink
# to the most recent one. This is just a front end over that registry, so it
# stays host-side only - $RUNDIR is never mounted into a sandbox, which is
# what keeps a jailed agent from syncing its own work out unreviewed.
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
      printf 'Sessions register under %s as <pid>.state.\n' "$REG_DIR"
      exit 0
    }

    # One field out of a session's state record (see the runner's
    # session_state for the format and the key list). An absent key reads as
    # empty, which is also what a record written by an older runner gives for
    # a key added since - so a new key is always safe to ask for.
    state_get() {
      local file="$1" key="$2" line
      [ -r "$file" ] || return 1
      while IFS= read -r line; do
        case "$line" in
          "$key="*) printf '%s' "''${line#"$key="}"; return 0 ;;
        esac
      done < "$file"
      return 0
    }

    # Why a session has nothing to fold back, in the operator's own flag
    # vocabulary. Derived from the record rather than hardcoded, so it stays
    # true if another flag combination ever ends up binding trees directly.
    state_reason() {
      local file="$1" git overlay
      git=$(state_get "$file" git)
      overlay=$(state_get "$file" overlay)
      if [ "$overlay" = "1" ]; then
        printf -- '--git %s with --overlay-workspace' "''${git:-?}"
      else
        printf -- '--git %s without --overlay-workspace' "''${git:-?}"
      fi
    }

    # A session directory with no entries and a dead `current` symlink mean
    # the same thing to the operator - no running jail - so both report it
    # the same way instead of an ENOENT from the launcher.
    list_sessions() {
      local entry pid sync ws rundir dirty found=0
      for entry in "$REG_DIR"/*.state; do
        [ -e "$entry" ] || continue
        pid="''${entry##*/}"
        pid="''${pid%.state}"
        kill -0 "$pid" 2>/dev/null || continue
        found=1
        ws=$(state_get "$entry" workspace)
        sync=$(state_get "$entry" sync)
        if [ -z "$sync" ]; then
          printf '%s  (pid %s, nothing to sync - %s)\n' "$ws" "$pid" "$(state_reason "$entry")"
          continue
        fi
        # The runner's dirty counter lives next to the sync launcher it
        # registered, so the unsynced count comes for free here - which is
        # the whole point of listing sessions rather than just syncing one.
        rundir="''${sync%/sync}"
        dirty=""
        [ -r "$rundir/dirty" ] && dirty=$(cat "$rundir/dirty" 2>/dev/null || true)
        case "''${dirty:-0}" in
          0|"") printf '%s  (pid %s, clean)\n' "$sync" "$pid" ;;
          *)    printf '%s  (pid %s, %s unsynced path(s))\n' "$sync" "$pid" "$dirty" ;;
        esac
      done
      # A session started by a runner from before the state record existed
      # has only its .sync symlink - a plausible mix after a rebuild, since
      # these sessions outlive the build they were started from.
      for entry in "$REG_DIR"/*.sync; do
        [ -e "$entry" ] || continue
        pid="''${entry##*/}"
        pid="''${pid%.sync}"
        [ -e "$REG_DIR/$pid.state" ] && continue
        kill -0 "$pid" 2>/dev/null || continue
        found=1
        printf '%s  (pid %s)\n' "$(readlink -f "$entry")" "$pid"
      done
      [ "$found" = "1" ] || printf 'no live llm-custody sessions\n' >&2
    }

    TARGET="$REG_DIR/current"
    # Empty when no pid was named, which is also what decides whether a
    # missing target is looked up as one specific session or as any live one.
    TARGET_PID=""
    case "''${1:-}" in
      -h|--help) usage ;;
      --list|-l) list_sessions; exit 0 ;;
      ""|--) ;;
      -*) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 1 ;;
      *)  TARGET="$REG_DIR/$1.sync"; TARGET_PID="$1"; shift ;;
    esac
    # Remaining args go to the session's own sync launcher (e.g. --auto).
    # `if` rather than a `&&` chain: a false test as the last command of a
    # chain is the script's exit status under errexit.
    if [ "$#" -gt 0 ] && [ "$1" = "--" ]; then shift; fi

    if [ ! -e "$TARGET" ]; then
      # Before calling it a missing session: a live run that binds every tree
      # straight through registers a state record but no launcher. Nothing to
      # do is not an error, so this exits 0 - the operator asked for their
      # changes on the host and they are already there.
      STATE=""
      if [ -n "$TARGET_PID" ]; then
        [ -e "$REG_DIR/$TARGET_PID.state" ] && STATE="$REG_DIR/$TARGET_PID.state"
      else
        for entry in "$REG_DIR"/*.state; do
          [ -e "$entry" ] || continue
          pid="''${entry##*/}"
          kill -0 "''${pid%.state}" 2>/dev/null || continue
          STATE="$entry"
          break
        done
      fi
      if [ -n "$STATE" ] && [ -z "$(state_get "$STATE" sync)" ]; then
        printf 'nothing to sync: pid %s works in %s directly\n' \
          "$(state_get "$STATE" pid)" "$(state_get "$STATE" workspace)" >&2
        printf '                 %s - the host tree already has the changes\n' \
          "$(state_reason "$STATE")" >&2
        exit 0
      fi
      printf 'ERROR: no such llm-custody session: %s\n' "$TARGET" >&2
      printf '       llm-custody-sync --list shows the live ones\n' >&2
      exit 1
    fi

    exec "$TARGET" "$@"
  '';
}
