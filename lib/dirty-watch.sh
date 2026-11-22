# The unsynced-change counter and the background poller that advertises it
# while a session runs. Interpolated into lib/mkBwrapRunner.nix (no Nix
# interpolation in here); reads the runner's SYNC_MANIFEST, RUNDIR,
# USERVAR_ON and WATCH_INTERVAL at call time and calls emit_uservar from
# lib/session-publish.sh.

# How many paths the jail has changed but not yet synced, across every
# isolated tree in the manifest. Same two sources the sync-back itself
# reads, so the number here and the number it reports agree.
#
# --no-optional-locks because this runs concurrently with a possible
# mid-session $RUNDIR/sync: plain `git status` may refresh (and so lock)
# the index, which would collide with that sync's own `git add`. The
# flag is exactly for status-reporting callers like this one.
jail_dirty_count() {
  local type src track n total=0
  [ -n "$SYNC_MANIFEST" ] && [ -f "$SYNC_MANIFEST" ] || {
    printf '0'
    return 0
  }
  # The manifest's host-tree and label columns are the sync-back's
  # business, not this counter's - read into one throwaway so the two
  # fields it does need stay aligned with the format.
  while IFS=$'\t' read -r type src track _; do
    n=0
    case "$type" in
    copy)
      [ -d "$src" ] && [ -d "$track" ] || continue
      n=$(GIT_DIR="$track" GIT_WORK_TREE="$src" git --no-optional-locks \
        status --porcelain --untracked-files=all 2>/dev/null | wc -l) || n=0
      ;;
    overlay)
      # An overlay upper layer holds only what was written, so every
      # entry in it is by definition an unsynced change. Plain
      # directories are skipped: overlayfs materializes a directory
      # just to hold a changed file below it, so counting them would
      # inflate the number against the per-path count a copy reports.
      # Symlinks and whiteouts (char devices) do count.
      [ -d "$src" ] || continue
      n=$(
        cd "$src" 2>/dev/null || exit 0
        shopt -s globstar dotglob nullglob
        c=0
        for e in **/*; do
          [ -d "$e" ] && [ ! -L "$e" ] && continue
          c=$((c + 1))
        done
        printf '%s' "$c"
      ) || n=0
      ;;
    *) continue ;;
    esac
    case "$n" in "" | *[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done <"$SYNC_MANIFEST"
  printf '%s' "$total"
}

# Background poller feeding the indicator. Only emits on a *change*, so
# a long session writes a handful of escape sequences rather than one
# every interval - the jailed tool owns the terminal while this runs,
# and a write landing inside one of its own sequences would corrupt a
# frame.
#
# SIGUSR1 means "recount now": the sync launcher sends it when a
# mid-session sync finishes, so the indicator drops with the sync rather
# than up to a full interval later. The emission has to stay in this
# process either way, since the user var belongs to the pane of the
# jail's terminal and the sync runs in another one.
start_dirty_watcher() {
  local last="" now kick=0 sleeper=""
  trap 'kick=1' USR1
  trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' TERM
  # Published only once the trap is in place: an untrapped SIGUSR1 would
  # end the watcher.
  printf '%s\n' "$BASHPID" >"$RUNDIR/dirty.pid" 2>/dev/null || true
  while :; do
    # Reset before the count, so a signal landing while it runs still
    # causes one more pass over the state the sync left behind.
    kick=0
    now=$(jail_dirty_count 2>/dev/null) || now=""
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      printf '%s\n' "$now" >"$RUNDIR/dirty.tmp" 2>/dev/null &&
        mv -f "$RUNDIR/dirty.tmp" "$RUNDIR/dirty" 2>/dev/null || true
      if [ "$USERVAR_ON" = "1" ]; then
        # Empty, not "0", when clean: a consumer can then test the var
        # for emptiness exactly like the other two.
        if [ "$now" = "0" ]; then
          emit_uservar llm_custody_dirty ""
        else
          emit_uservar llm_custody_dirty "$now"
        fi
      fi
      last="$now"
    fi
    if [ "$kick" = "0" ]; then
      # In the background under `wait`, because bash runs a trap only
      # after the foreground command returns: a plain sleep would hold
      # the recount back for the rest of the interval.
      sleep "$WATCH_INTERVAL" &
      sleeper=$!
      wait "$sleeper" || true
      kill "$sleeper" 2>/dev/null || true
      sleeper=""
    fi
  done
}
