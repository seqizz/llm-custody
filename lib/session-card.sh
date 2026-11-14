# The session card: one block, printed last before launch (and by
# --dry-run), describing the sandbox this run is about to enter.
# Interpolated into lib/mkBwrapRunner.nix (no Nix interpolation in here);
# reads the runner's resolved settings at call time (workspace, git mode,
# network filter, mounts, masks, limits, toolbox, flags, state dir) plus
# the colours from lib/log.sh and JAIL_MARK from lib/session-publish.sh.

# Session card: one block, printed last, describing what the sandbox
# this run is about to enter actually looks like. It is here for the
# settings that are dangerous when they are not the ones the operator
# thought they were - a stray --git full or --no-net-filter is visible
# in red on the line above the prompt instead of buried somewhere in the
# scrollback of a command typed ten minutes ago.
card_row() {
  printf '%s│%s %-9s %s\n' "$C_DIM" "$C_RESET" "$1" "$2" >&2
}

print_card() {
  local ws_line net_line git_line mounts_line extras tb_entry tb_count=0

  ws_line="$WORKSPACE_HOST ${C_DIM}->${C_RESET} $WORKSPACE_GUEST"

  case "$GIT_MODE" in
    full)
      if [ "$OVERLAY" = "1" ]; then
        git_line="${C_YELLOW}full${C_RESET}, copy-on-write overlay (review before any sync)"
      else
        git_line="${C_RED}full${C_RESET}, real tree bound read-write - writes hit the host immediately"
      fi ;;
    limited) git_line="${C_GREEN}limited${C_RESET}, baseline-only copy, syncs back on exit" ;;
    none)    git_line="${C_GREEN}none${C_RESET}, plain copy with no repo, syncs back on exit" ;;
  esac

  if [ "$NET_FILTER" = "1" ]; then
    net_line="${C_GREEN}filtered${C_RESET}, $((${#ALLOWED_DOMAINS[@]} + ${#EXTRA_DOMAINS[@]})) domain(s) allowed"
  else
    net_line="${C_RED}UNFILTERED${C_RESET} - the sandbox can reach anything"
  fi

  mounts_line="$EXTRA_MOUNT_COUNT extra, live under ${DOCK_GUESTS[*]}"
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] && mounts_line="$mounts_line, ${#MASK_PATTERNS[@]} mask pattern(s)"
  [ "${#SYNC_EXCLUDES[@]}" -gt 0 ] && mounts_line="$mounts_line, ${#SYNC_EXCLUDES[@]} sync exclude(s)"

  extras=""
  [ "$DANGEROUS" = "1" ] && extras="$extras ${C_RED}dangerous${C_RESET}"
  [ "$RW_SKILLS" = "1" ] && extras="$extras ${C_YELLOW}rw-skills${C_RESET}"
  [ "$X11" = "1" ] && extras="$extras ${C_YELLOW}x11${C_RESET}"
  [ "$SAME_PATH" = "1" ] && extras="$extras same-path"

  printf '%s┌─ %s%s %s%s %s(%s)%s\n' \
    "$C_DIM" "$C_RESET" "$JAIL_MARK" "$C_BOLD" "$TOOL_NAME" "$C_DIM" "$PROFILE" "$C_RESET" >&2
  card_row workspace "$ws_line"
  card_row repo "$git_line"
  card_row network "$net_line"
  card_row mounts "$mounts_line"
  [ -n "$LIMITS_DESC" ] && card_row limits "$LIMITS_DESC"
  # Only when it has something in it: an empty toolbox is the normal case
  # and a row saying so on every launch is noise. No nullglob - an
  # unmatched glob stays literal and the -e test rejects it.
  # `if` rather than a `&&` chain: a false test as the last command of the
  # loop body makes the loop itself exit non-zero, which errexit acts on.
  for tb_entry in "$TOOLBOX_DIR/$TOOLBOX_CURRENT_LINK/bin"/*; do
    if [ -e "$tb_entry" ]; then tb_count=$((tb_count + 1)); fi
  done
  [ "$tb_count" -gt 0 ] && card_row toolbox "$tb_count command(s) from $TOOLBOX_DIR"
  [ -n "$extras" ] && card_row flags "${extras# }"
  card_row state "$STATE_DIR"
  printf '%s└─%s\n' "$C_DIM" "$C_RESET" >&2
}
