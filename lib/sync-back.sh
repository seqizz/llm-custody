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
EXCLUDES=()
# Identity for the tracking-baseline commits: the host .gitconfig may have
# none, or a signing key whose agent isn't reachable from here.
GIT_IDENT=(-c user.name=llm-custody -c user.email=llm-custody@localhost -c commit.gpgsign=false)

while [ $# -gt 0 ]; do
  case "$1" in
    --prompt) MODE=prompt; shift ;;
    --auto)   MODE=auto; shift ;;
    --exclude)
      if [ $# -lt 2 ]; then
        printf 'ERROR: --exclude needs a glob\n' >&2
        exit 2
      fi
      EXCLUDES+=("$2"); shift 2 ;;
    -h|--help)
      printf 'Usage: llm-custody-sync-back [--prompt|--auto] [--exclude GLOB]... MANIFEST\n'
      printf '  --prompt       review each changed tree and confirm (default)\n'
      printf '  --auto         sync copies without asking; overlays are never\n'
      printf '                 synced unattended (they exist to be reviewed first)\n'
      printf '  --exclude GLOB never sync paths matching GLOB (repeatable)\n'
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

# Globs are matched against the path relative to the tree root, the same
# frame --mask uses. The matching is bash `case`, where '*' crosses '/' -
# so '*.log' holds back logs at any depth, not just at the top level, which
# is what an exclude pattern is almost always written to mean (--mask
# expands against the filesystem instead, where it does not). A directory
# pattern also covers everything under it: excluding a directory and
# keeping its contents is never what the operator meant.
path_excluded() {
  local path="$1" glob
  for glob in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
    # shellcheck disable=SC2254 # the glob is the point - it must stay unquoted
    case "$path" in
      $glob|$glob/*) return 0 ;;
    esac
  done
  return 1
}

# Reads one answer from the terminal. Returns it verbatim on stdout so
# callers can offer more than yes/no (the copy prompt also takes 'd' for a
# full diff); an empty answer means "no" everywhere.
read_answer() {
  local prompt="$1" ans=""
  if [ "$TTY_FD" = "4" ]; then
    printf '%s' "$prompt" >&4
    read -r ans <&4 || ans=""
  else
    printf '%s' "$prompt" >&2
    read -r ans || ans=""
  fi
  printf '%s' "$ans"
}

# $PAGER where the operator set one, less otherwise (baked into this
# wrapper's PATH), and cat as the last resort so a diff is never swallowed
# just because neither is reachable.
page() {
  local pager="${PAGER:-less}"
  if ! command -v "${pager%% *}" >/dev/null 2>&1; then
    # Quoted so this reads as the string "cat", not as a command to run and
    # capture (SC2209).
    pager="cat"
  fi
  # Unquoted on purpose: $PAGER conventionally carries its own flags
  # ("less -R"), and quoting would look for a binary with a space in it.
  # shellcheck disable=SC2086
  if [ "$TTY_FD" = "4" ]; then
    $pager <&4 >&4 2>&4 || true
  else
    $pager || true
  fi
}

# --git limited|none: the sandbox worked on a copy, so the real tree is
# still untouched. Diff the copy against the baseline in its tracking git
# dir (never mounted into the sandbox, so the agent cannot rewrite the
# baseline to smuggle a change past this review) and copy the differences
# over.
sync_copy() {
  local copy="$1" track="$2" host="$3" label="$4"
  local changes count applied=0 skipped=0 code path ans
  changes=$(GIT_DIR="$track" GIT_WORK_TREE="$copy" git status --porcelain --untracked-files=all 2>/dev/null || true)
  [ -n "$changes" ] || return 0
  count=$(printf '%s\n' "$changes" | wc -l || true)
  printf 'llm-custody: %s changed (host: %s):\n' "$label" "$host" >&2
  # --stat for the tracked side (line counts say far more than a status
  # letter about what is about to be written to the host tree), with the
  # untracked paths listed after it since a diff against the baseline
  # commit cannot show them.
  # `|| true` throughout: called from an EXIT trap with errexit still
  # active, where head closing the pipe early (EPIPE) would otherwise abort
  # cleanup before the sync.
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git --no-pager diff --stat HEAD 2>/dev/null | head -n 40 >&2 || true
  printf '%s\n' "$changes" | grep '^??' | head -n 20 >&2 || true
  if [ "$count" -gt 40 ]; then
    printf '          ... (%s paths total)\n' "$count" >&2
  fi

  if [ "$MODE" = "prompt" ]; then
    while true; do
      ans=$(read_answer "llm-custody: sync these back to $host? [y/N/d=diff] ")
      case "$ans" in
        [yY]|[yY][eE][sS]) break ;;
        [dD])
          # Staging into the *tracking* index is what makes new files show
          # up in the diff at all; it is also harmless to leave behind,
          # since a real sync re-runs `add -A` before committing its own
          # sync point anyway.
          GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" add -A >/dev/null 2>&1 || true
          GIT_DIR="$track" GIT_WORK_TREE="$copy" git --no-pager diff --cached 2>/dev/null | page
          continue ;;
        *)
          printf 'llm-custody: NOT syncing %s\n' "$label" >&2
          return 0 ;;
      esac
    done
  fi

  # -z keeps paths literal (no quoting/escaping of odd names); the status
  # code is the first two chars, the path starts at offset 3.
  while IFS= read -r -d "" entry; do
    code="${entry:0:2}"
    path="${entry:3}"
    [ -n "$path" ] || continue
    if path_excluded "$path"; then
      skipped=$((skipped+1))
      continue
    fi
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
  if [ "$skipped" -gt 0 ]; then
    printf '          %s path(s) held back by --sync-exclude.\n' "$skipped" >&2
  fi
  printf '          gitignored paths are not tracked and never sync back.\n' >&2
}

# --overlay-workspace: fold the overlay upper layer into the real tree.
# Regular files/symlinks copy over, whiteouts (overlayfs deletion markers =
# char device 0:0) remove the corresponding host path. Best-effort - overlay
# quirks like opaque dirs are not fully mirrored, so a git/rsync review
# afterwards is still worthwhile.
#
# $3 is the path of $1 relative to the overlay root, so --sync-exclude globs
# can be matched against the same tree-relative paths they are written for.
# Empty at the top level, "sub/dir/" further down.
sync_overlay_dir() {
  local upper="$1" host="$2" prefix="${3:-}"
  local entry base rel
  for entry in "$upper"/* "$upper"/.[!.]* "$upper"/..?*; do
    # -L as well as -e: a symlink the agent created pointing at something
    # that only exists inside the sandbox is dangling on the host, and -e
    # alone would drop it from the sync.
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="${entry##*/}"
    rel="$prefix$base"
    if path_excluded "$rel"; then
      OVERLAY_SKIPPED=$((OVERLAY_SKIPPED+1))
      continue
    fi
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
      sync_overlay_dir "$entry" "$host/$base" "$rel/"
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
  local upper="$1" host="$2" label="$3" ans
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
  printf 'llm-custody: %s has changes (host: %s):\n' "$label" "$host" >&2
  # An overlay upper layer has no baseline to diff against, so the listing
  # is the review material: every path in it is a path about to be written
  # to (or, for a whiteout, removed from) the host tree. Globstar rather
  # than find: this wrapper only guarantees git and coreutils on PATH.
  (
    cd "$upper" || exit 0
    shopt -s globstar dotglob nullglob
    for entry in **/*; do printf '          %s\n' "$entry"; done
  ) 2>/dev/null | head -n 40 >&2 || true
  ans=$(read_answer "llm-custody: sync them back to $host? [y/N] ")
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *)
      printf 'llm-custody: NOT syncing - %s changes stay in the sandbox runtime dir and are discarded\n' "$label" >&2
      return 0 ;;
  esac
  OVERLAY_APPLIED=0
  OVERLAY_SKIPPED=0
  sync_overlay_dir "$upper" "$host"
  printf 'llm-custody: synced %s changed path(s) back to %s (review with git status/diff)\n' "$OVERLAY_APPLIED" "$host" >&2
  if [ "$OVERLAY_SKIPPED" -gt 0 ]; then
    printf '          %s path(s) held back by --sync-exclude.\n' "$OVERLAY_SKIPPED" >&2
  fi
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
