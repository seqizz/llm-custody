# The two listing modes, --list-profiles and --list-sessions: each prints
# and exits, so this runs inline at the point of interpolation rather than
# defining functions. Interpolated into lib/mkBwrapRunner.nix (no Nix
# interpolation in here), after STATE_ROOT and STATE_DIR are resolved and
# before anything touches the workspace; also reads LIST_PROFILES,
# LIST_SESSIONS, TOOL_NAME, PROFILE and SESSIONS_SUBDIR.

# --list-profiles: every profile dir that exists for this tool, with the
# one the current flags would select marked. Sessions are counted rather
# than listed; --list-sessions is the detailed view.
if [ "$LIST_PROFILES" = "1" ]; then
  TOOL_ROOT="$STATE_ROOT/$TOOL_NAME"
  if [ ! -d "$TOOL_ROOT" ]; then
    log "no profiles yet for $TOOL_NAME (state root: $STATE_ROOT)"
    exit 0
  fi
  log "profiles for $TOOL_NAME under $TOOL_ROOT:"
  shopt -s nullglob
  for entry in "$TOOL_ROOT"/*; do
    [ -d "$entry" ] || continue
    pname="${entry##*/}"
    scount=0
    if [ -d "$entry/$SESSIONS_SUBDIR" ]; then
      shopt -s globstar
      for s in "$entry/$SESSIONS_SUBDIR"/**/*.jsonl; do
        [ -f "$s" ] && scount=$((scount+1))
      done
      shopt -u globstar
    fi
    marker="  "
    [ "$pname" = "$PROFILE" ] && marker="${C_GREEN}* ${C_RESET}"
    printf '%s%s%s%s (%s session(s))\n' "$marker" "$C_BOLD" "$pname" "$C_RESET" "$scount" >&2
  done
  shopt -u nullglob
  exit 0
fi

# --list-sessions: the jail-private transcripts of this profile. Host
# sessions of the same tool are deliberately invisible here, exactly as
# they are to --resume: the state dirs are separate on purpose.
if [ "$LIST_SESSIONS" = "1" ]; then
  SESSIONS_ROOT="$STATE_DIR/$SESSIONS_SUBDIR"
  if [ ! -d "$SESSIONS_ROOT" ]; then
    log "no sessions yet in profile '$PROFILE' ($SESSIONS_ROOT)"
    exit 0
  fi
  log "sessions in profile '$PROFILE' ($SESSIONS_ROOT), newest first:"
  shopt -s nullglob globstar
  # -t sorts by mtime; the paths are passed in one batch so the ordering
  # is across all projects, not per project.
  SESSION_FILES=("$SESSIONS_ROOT"/**/*.jsonl)
  shopt -u nullglob globstar
  if [ "${#SESSION_FILES[@]}" -eq 0 ]; then
    log "none found"
    exit 0
  fi
  # stat+sort rather than `ls -lt`: the mtime is wanted as a sort key,
  # and parsing it back out of an ls listing is both fragile and the
  # thing SC2012 exists to flag.
  while read -r ts size path; do
    printf '  %s%s%s  %7s  %s\n' \
      "$C_DIM" "$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$ts")" "$C_RESET" \
      "$size" "${path#"$SESSIONS_ROOT"/}" >&2
  done < <(stat -c '%Y %s %n' "${SESSION_FILES[@]}" 2>/dev/null | sort -rn)
  exit 0
fi
