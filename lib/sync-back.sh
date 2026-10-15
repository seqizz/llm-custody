# llm-custody sync-back.
#
# Folds jail-side workspace copies (--git limited|none) and overlay upper
# layers (--overlay-workspace) back into the real host trees, for the
# workspace and for every extra rw --mount that got the same treatment.
#
# Two callers, one implementation: the runner's exit trap, and the operator
# running $RUNDIR/sync from a second terminal to sync mid-session while the
# agent keeps working. Kept in its own file rather than inlined into
# lib/mkBwrapRunner.nix's Nix string for the same reason as
# lib/selftest.nix: no $-fragment escaping, and heredocs/indentation here
# can't collide with that string's dedent.
#
# Manifest format, one entry per line, tab-separated:
#   copy<TAB>COPYDIR<TAB>TRACKGIT<TAB>HOSTTREE<TAB>LABEL
#   overlay<TAB>UPPERDIR<TAB>-<TAB>HOSTTREE<TAB>LABEL
# Blank lines and '#' comments are ignored.

MODE=prompt
MANIFEST=""
# Identity for the tracking-baseline commits: the host .gitconfig may have
# none, or a signing key whose agent isn't reachable from here.
GIT_IDENT=(-c user.name=llm-custody -c user.email=llm-custody@localhost -c commit.gpgsign=false)

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) MODE=prompt; shift ;;
    --auto)   MODE=auto; shift ;;
    -h|--help)
      printf 'Usage: llm-custody-sync-back [--prompt|--auto] MANIFEST\n'
      printf '  --prompt  review each changed tree and confirm (default)\n'
      printf '  --auto    sync copies without asking; overlays are never\n'
      printf '            synced unattended (they exist to be reviewed first)\n'
      exit 0 ;;
    *) MANIFEST="$1"; shift ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  printf 'ERROR: no sync manifest given\n' >&2
  exit 2
fi
# No manifest means nothing in this run was isolated from the host tree
# (--git full without --overlay-workspace): nothing to sync, not an error.
[ -f "$MANIFEST" ] || exit 0

# Answers come from the terminal device where there is one, not stdin: the
# exit-trap caller's stdin may be anything, and a mid-session run can be
# started with stdin redirected.
#
# Opened once, here, rather than tested per prompt: the /dev/tty node exists
# and looks readable even for a process with no controlling terminal, where
# opening it then fails with ENXIO - so `[ -r /dev/tty ]` passes and the
# redirect still loses the prompt. <> because the same fd is written to and
# read from.
# The brace group (not `exec ... 2>/dev/null`) is what silences the failure:
# redirections apply left to right, so the open would report its error
# before a trailing 2>/dev/null could take effect - while a group's
# redirect covers the exec inside it and still leaves fd 4 open afterwards.
TTY_FD=0
if { exec 4<>/dev/tty; } 2>/dev/null; then
  TTY_FD=4
fi

ask() {
  local prompt="$1" ans=""
  [ "$MODE" = "prompt" ] || return 0
  if [ "$TTY_FD" = "4" ]; then
    printf '%s' "$prompt" >&4
    read -r ans <&4 || ans=""
  else
    printf '%s' "$prompt" >&2
    read -r ans || ans=""
  fi
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; esac
  return 1
}

# --git limited|none: the sandbox worked on a copy, so the real tree is
# still untouched. Diff the copy against the baseline in its tracking git
# dir (never mounted into the sandbox, so the agent cannot rewrite the
# baseline to smuggle a change past this review) and copy the differences
# over.
sync_copy() {
  local copy="$1" track="$2" host="$3" label="$4"
  local changes count applied=0 code path
  changes=$(GIT_DIR="$track" GIT_WORK_TREE="$copy" git status --porcelain --untracked-files=all 2>/dev/null || true)
  [ -n "$changes" ] || return 0
  count=$(printf '%s\n' "$changes" | wc -l || true)
  printf 'llm-custody: %s changed (host: %s):\n' "$label" "$host" >&2
  # `|| true` on both: called from an EXIT trap with errexit still active,
  # where head closing the pipe early (EPIPE) would otherwise abort cleanup
  # before the sync.
  printf '%s\n' "$changes" | head -n 40 >&2 || true
  if [ "$count" -gt 40 ]; then
    printf '          ... (%s paths total)\n' "$count" >&2
  fi
  if ! ask "llm-custody: sync these back to $host? [y/N] "; then
    printf 'llm-custody: NOT syncing %s\n' "$label" >&2
    return 0
  fi
  # -z keeps paths literal (no quoting/escaping of odd names); the status
  # code is the first two chars, the path starts at offset 3.
  while IFS= read -r -d "" entry; do
    code="${entry:0:2}"
    path="${entry:3}"
    [ -n "$path" ] || continue
    case "$code" in
      *D*)
        rm -rf -- "$host/${path:?sync path empty}" 2>/dev/null || true ;;
      *)
        mkdir -p -- "$(dirname -- "$host/$path")" 2>/dev/null || true
        cp -a --reflink=auto -- "$copy/$path" "$host/$path" 2>/dev/null || true ;;
    esac
    applied=$((applied+1))
  done < <(GIT_DIR="$track" GIT_WORK_TREE="$copy" git status --porcelain -z --untracked-files=all 2>/dev/null || true)
  # Advance the baseline so a following sync (mid-session syncs are meant to
  # be repeatable) only reports what changed since this one, instead of
  # re-copying everything already synced.
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" add -A >/dev/null 2>&1 || true
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" commit -q -m "llm-custody sync point" --allow-empty >/dev/null 2>&1 || true
  printf 'llm-custody: synced %s path(s) back to %s (review with git status/diff)\n' "$applied" "$host" >&2
  printf '          gitignored paths are not tracked and never sync back.\n' >&2
}

# --overlay-workspace: fold the overlay upper layer into the real tree.
# Regular files/symlinks copy over, whiteouts (overlayfs deletion markers =
# char device 0:0) remove the corresponding host path. Best-effort - overlay
# quirks like opaque dirs are not fully mirrored, so a git/rsync review
# afterwards is still worthwhile.
sync_overlay_dir() {
  local upper="$1" host="$2"
  local entry base
  for entry in "$upper"/* "$upper"/.[!.]* "$upper"/..?*; do
    # -L as well as -e: a symlink the agent created pointing at something
    # that only exists inside the sandbox is dangling on the host, and -e
    # alone would drop it from the sync.
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    if [ -c "$entry" ]; then
      if [ "$(stat -c '%t:%T' "$entry")" = "0:0" ]; then
        # ${host:?}/${base:?}: host is always set and base is a real dir
        # entry (never empty) - the :? form just keeps the SC2115 lint
        # (rm -rf against an unguarded path) satisfied, so a deletion can
        # never target something empty by accident.
        rm -rf -- "${host:?remove target host unset}/${base:?remove target name unset}" 2>/dev/null
        OVERLAY_APPLIED=$((OVERLAY_APPLIED+1))
      fi
      continue
    fi
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      mkdir -p -- "$host/$base"
      sync_overlay_dir "$entry" "$host/$base"
      continue
    fi
    if [ -L "$entry" ]; then
      if [ ! -e "$host/$base" ] || [ "$(readlink "$entry")" != "$(readlink "$host/$base" 2>/dev/null || true)" ]; then
        cp -a -- "$entry" "$host/$base" 2>/dev/null && OVERLAY_APPLIED=$((OVERLAY_APPLIED+1))
      fi
    elif [ ! -e "$host/$base" ] || ! cmp -s "$entry" "$host/$base"; then
      cp -a -- "$entry" "$host/$base" 2>/dev/null && OVERLAY_APPLIED=$((OVERLAY_APPLIED+1))
    fi
  done
}

sync_overlay() {
  local upper="$1" host="$2" label="$3"
  [ -n "$(ls -A "$upper" 2>/dev/null)" ] || return 0
  # Unlike a copy, an overlay is never synced unattended. A copy replaces
  # what used to be a direct rw bind, so a headless run that silently threw
  # its work away would be worse than the host mutation it avoids;
  # --overlay-workspace is the opposite - an explicit request to review
  # before anything reaches the host.
  if [ "$MODE" != "prompt" ]; then
    printf 'llm-custody: %s has changes but no tty to confirm on - not syncing, they are discarded\n' "$label" >&2
    return 0
  fi
  printf 'llm-custody: %s has changes (host: %s)\n' "$label" "$host" >&2
  if ! ask "llm-custody: sync them back to $host? [y/N] "; then
    printf 'llm-custody: NOT syncing - %s changes stay in the sandbox runtime dir and are discarded\n' "$label" >&2
    return 0
  fi
  OVERLAY_APPLIED=0
  sync_overlay_dir "$upper" "$host"
  printf 'llm-custody: synced %s changed path(s) back to %s (review with git status/diff)\n' "$OVERLAY_APPLIED" "$host" >&2
}

# fd 3 for the manifest so the prompts above keep stdin/the tty to
# themselves.
while IFS=$'\t' read -r type src track host label <&3; do
  case "$type" in
    ""|\#*) continue ;;
    copy)
      if [ -d "$src" ] && [ -d "$track" ]; then
        sync_copy "$src" "$track" "$host" "$label"
      fi ;;
    overlay)
      if [ -d "$src" ]; then
        sync_overlay "$src" "$host" "$label"
      fi ;;
    *) printf 'llm-custody: unknown sync manifest entry type: %s\n' "$type" >&2 ;;
  esac
done 3< "$MANIFEST"
