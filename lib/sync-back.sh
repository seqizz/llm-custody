# llm-custody sync-back.
#
# Folds jail-side copies (modes limited|nogit) and overlay upper layers
# (mode overlay) back into the real host trees, for the workspace
# (--pwd-MODE) and for every extra mount (--mount-MODE) in one of those
# modes.
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
# Set by the mid-session launcher. Only a live session offers discard and
# reset at the copy prompt: at exit the copy is deleted right after, so
# declining the sync already discards, and there is nothing left to reset.
LIVE=0
MANIFEST=""
EXCLUDES=()
# --mask globs of the session, re-applied when a copy is reset from the host
# (jail_apply_masks, lib/jail-tree.sh).
MASK_PATTERNS=()
# Modified gitignored files of the tree being synced, filled by
# ignored_scan and read by the sync, discard and reset steps of that tree,
# and their grouping by ignore rule (ignored_group).
IGNORED_MODS=()
IGN_RULES=()
IGN_WHERE=()
IGN_COUNT=()
IGN_OF=()
# Read by the log helpers and jail-tree.sh, which this script is built with.
VERBOSITY=1
# Identity for the tracking-baseline commits: the host .gitconfig may have
# none, or a signing key whose agent isn't reachable from here.
GIT_IDENT=(-c user.name=llm-custody -c user.email=llm-custody@localhost -c commit.gpgsign=false)

while [ $# -gt 0 ]; do
  case "$1" in
  --prompt)
    MODE=prompt
    shift
    ;;
  --auto)
    MODE=auto
    shift
    ;;
  --exclude)
    if [ $# -lt 2 ]; then
      printf 'ERROR: --exclude needs a glob\n' >&2
      exit 2
    fi
    EXCLUDES+=("$2")
    shift 2
    ;;
  --mask)
    if [ $# -lt 2 ]; then
      printf 'ERROR: --mask needs a glob\n' >&2
      exit 2
    fi
    MASK_PATTERNS+=("$2")
    shift 2
    ;;
  --live)
    LIVE=1
    shift
    ;;
  -h | --help)
    printf 'Usage: llm-custody-sync-back [--prompt|--auto] [--live] [--exclude GLOB]... [--mask GLOB]... MANIFEST\n'
    printf '  --prompt       review each changed tree and confirm (default)\n'
    printf '  --auto         sync copies without asking; overlays are never\n'
    printf '                 synced unattended (they exist to be reviewed first);\n'
    printf '                 a path also changed on the host keeps the host\n'
    printf '                 version, the agent one lands beside it as PATH.llm-custody\n'
    printf '  --live         the session is still running: the copy prompt also\n'
    printf '                 offers x (discard the jail changes) and r (reset the\n'
    printf '                 copy to the current host tree)\n'
    printf '  --exclude GLOB never sync paths matching GLOB (repeatable)\n'
    printf '  --mask GLOB    session --mask glob, re-applied on reset (repeatable)\n'
    exit 0
    ;;
  -*)
    # Refused rather than taken for the manifest path: a mistyped option
    # would otherwise replace the real manifest, find no such file and exit
    # 0 as if there were nothing to sync.
    printf 'ERROR: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  *)
    if [ -n "$MANIFEST" ]; then
      printf 'ERROR: more than one manifest given: %s and %s\n' "$MANIFEST" "$1" >&2
      exit 2
    fi
    MANIFEST="$1"
    shift
    ;;
  esac
done

if [ -z "$MANIFEST" ]; then
  printf 'ERROR: no sync manifest given\n' >&2
  exit 2
fi
# No manifest means nothing in this run was isolated from the host tree
# (every tree is ro or full): nothing to sync, not an error.
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
    $glob | $glob/*) return 0 ;;
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
  # stdin stays the pipe carrying the diff: less takes its keys from
  # /dev/tty on its own, only its output needs pointing at the terminal.
  # shellcheck disable=SC2086
  if [ "$TTY_FD" = "4" ]; then
    $pager >&4 2>&4 || true
  else
    $pager || true
  fi
}

# Blob id git would store for $4 at tree path $3, or nothing when $4 does
# not exist. Regular files are hashed with --path so the copy's
# .gitattributes filters apply exactly as they did when the baseline was
# committed; symlinks hash their target text, which is how git stores them.
# A directory gets a marker that matches no blob id.
tree_blob() {
  local copy="$1" track="$2" path="$3" file="$4"
  if [ -L "$file" ]; then
    printf '%s' "$(readlink -- "$file")" | GIT_DIR="$track" git hash-object --no-filters --stdin 2>/dev/null || true
  elif [ -d "$file" ]; then
    printf 'directory'
  elif [ -e "$file" ]; then
    GIT_DIR="$track" GIT_WORK_TREE="$copy" git hash-object --path="$path" -- "$file" 2>/dev/null || true
  fi
}

# True when syncing $4 would overwrite or delete a host-side edit: the host
# file moved away from the last sync point and does not already match the
# agent's version (both sides making the same change is no conflict). The
# baseline is the tracking repo's HEAD, which holds what the host had for
# that path when it was copied in or last synced.
host_conflict() {
  local copy="$1" track="$2" host="$3" path="$4" base cur
  base=$(GIT_DIR="$track" git rev-parse -q --verify "HEAD:$path" 2>/dev/null || true)
  cur=$(tree_blob "$copy" "$track" "$path" "$host/$path")
  [ "$base" != "$cur" ] || return 1
  [ "$cur" != "$(tree_blob "$copy" "$track" "$path" "$copy/$path")" ]
}

# Asks how to settle one conflicting path and leaves the answer in
# RESOLUTION (agent|keep). Called directly, never in $(...), so an uppercase
# answer can set CONFLICT_ALL and settle every later conflict in the same
# tree without asking again. An empty answer keeps the host version, the
# choice that loses nothing on the host side.
resolve_conflict() {
  local copy="$1" host="$2" path="$3" ans old new
  if [ -n "$CONFLICT_ALL" ]; then
    RESOLUTION="$CONFLICT_ALL"
    return 0
  fi
  while true; do
    ans=$(read_answer "llm-custody: $path changed on both sides: [a]gent / [k]eep on-disk / [d]iff, A/K = all remaining [k] ")
    case "$ans" in
    a)
      RESOLUTION=agent
      return 0
      ;;
    A)
      RESOLUTION=agent
      CONFLICT_ALL=agent
      return 0
      ;;
    K)
      RESOLUTION=keep
      CONFLICT_ALL=keep
      return 0
      ;;
    d | D)
      # /dev/null stands in for a missing side, so a deletion on either
      # end still shows as a diff instead of a git error.
      old="$host/$path"
      [ -e "$old" ] || [ -L "$old" ] || old=/dev/null
      new="$copy/$path"
      [ -e "$new" ] || [ -L "$new" ] || new=/dev/null
      git --no-pager diff --no-index -- "$old" "$new" 2>/dev/null | page || true
      continue
      ;;
    *)
      RESOLUTION=keep
      return 0
      ;;
    esac
  done
}

# Second confirmation for the two answers that delete agent work for good.
# An empty answer is a no, as everywhere else.
confirm_drop() {
  local ans
  ans=$(read_answer "llm-custody: $1? [y/N] ")
  case "$ans" in
  [yY] | [yY][eE][sS]) return 0 ;;
  esac
  return 1
}

# The paths of a `git status --porcelain` listing, capped for a commit body.
change_list() {
  local changes="$1" count
  count=$(printf '%s\n' "$changes" | wc -l || true)
  printf '%s\n' "$changes" | cut -c4- | head -n 50 || true
  if [ "$count" -gt 50 ]; then
    printf '... and %s more\n' "$((count - 50))"
  fi
}

# The jail repo (mode limited) is agent-writable, and a .git/config the
# agent wrote can name hooks, an fsmonitor or filter drivers that git would
# run here, on the host. So it is only ever replaced: a fresh repo made the
# same way the launch made it, whose single commit tells the agent what
# happened to its tree, since there is no other channel into the session.
# Mode nogit has no jail repo unless the agent made one, which is replaced
# the same way.
reinit_jail_repo() {
  local copy="$1" host="$2" label="$3" subject="$4" body="$5"
  [ -e "$copy/.git" ] || [ -L "$copy/.git" ] || return 0
  rm -rf -- "${copy:?copy dir unset}/.git"
  jail_init_repo "$copy" "$host" "jail repo for $label" "$subject" "$body"
}

# Gitignored files are in no tracking commit, so `git status` never reports
# them. Fills IGNORED_MODS with the ones that were in the tree at the last
# baseline (ignored.list, see jail_ignored_baseline), carry a ctime newer
# than its stamp, and differ from the host file: regular files by content,
# symlinks by target. Only those few candidates are read; the rest of the
# list costs one lstat each.
#
# A path that changed type on either side is reported and left alone, since
# copying a file over a symlink or a directory would write somewhere the
# operator did not review. A path gone from the copy is no candidate, so a
# deletion in the jail never reaches the host.
ignored_scan() {
  local copy="$1" track="$2" host="$3" label="$4" dir="$2/llm-custody"
  local root path src dst want parent
  IGNORED_MODS=()
  [ -s "$dir/ignored.list" ] && [ -f "$dir/stamp" ] || return 0
  root=$(realpath -e -- "$copy" 2>/dev/null) || return 0
  while IFS= read -r -d "" path; do
    path_excluded "$path" && continue
    src="$copy/$path"
    dst="$host/$path"
    # The copy is agent-writable: a directory swapped for a symlink would
    # make the read below follow it to any file on the host.
    want="$root"
    case "$path" in */*) want="$root/${path%/*}" ;; esac
    parent=$(realpath -e -- "$(dirname -- "$src")" 2>/dev/null || true)
    if [ "$parent" != "$want" ]; then
      warn "$label: $path is reached through a symlink in the jail copy, not synced"
      continue
    fi
    if [ -L "$src" ]; then
      if [ -L "$dst" ]; then
        [ "$(readlink -- "$src")" != "$(readlink -- "$dst")" ] || continue
      elif [ -e "$dst" ]; then
        warn "$label: gitignored $path is a symlink in the jail and not on the host, not synced"
        continue
      fi
    elif [ -f "$src" ]; then
      if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
        warn "$label: gitignored $path is a regular file in the jail and not on the host, not synced"
        continue
      elif [ -f "$dst" ]; then
        ! cmp -s -- "$src" "$dst" || continue
      fi
    else
      warn "$label: gitignored $path is no longer a file or symlink in the jail, not synced"
      continue
    fi
    IGNORED_MODS+=("$path")
  done < <(ignored_candidates "$copy" "$dir")
}

# The baseline paths of $1 whose ctime is newer than the stamp in $2,
# NUL-separated. find exits non-zero for every listed path the agent
# deleted, which is expected.
ignored_candidates() {
  # shellcheck disable=SC2185 # the start points are the paths in the list
  (cd "$1" && find -files0-from "$2/ignored.list" -maxdepth 0 -cnewer "$2/stamp" -print0 2>/dev/null) || true
}

# Answer x at a live sync prompt: put the copy back to the last sync point
# (the launch state if nothing was synced yet) and leave the host tree
# alone. Gitignored paths are not tracked, so they stay as the agent left
# them.
discard_copy() {
  local copy="$1" track="$2" host="$3" label="$4" changes="$5" count since body
  if [ -z "$changes" ]; then
    printf 'llm-custody: nothing to discard in %s, modified gitignored files have no stored version to go back to\n' "$label" >&2
    return 0
  fi
  count=$(printf '%s\n' "$changes" | wc -l || true)
  if ! confirm_drop "throw away $count changed path(s) in the jail copy of $label for good"; then
    printf 'llm-custody: NOT discarding %s\n' "$label" >&2
    return 0
  fi
  since=$(GIT_DIR="$track" git log -1 --format=%ci 2>/dev/null || true)
  # The tracking dir excludes /.git/, so the clean leaves the jail repo to
  # reinit_jail_repo below.
  if ! GIT_DIR="$track" GIT_WORK_TREE="$copy" git reset -q --hard HEAD ||
    ! GIT_DIR="$track" GIT_WORK_TREE="$copy" git clean -fdq; then
    printf 'llm-custody: ERROR discarding the changes in %s failed, the copy may be partly reverted\n' "$label" >&2
    return 0
  fi
  body=$(
    printf 'The operator discarded the changes made in this tree since the last\n'
    printf 'sync point (%s). The files are back to that state, and the\n' "$since"
    printf 'earlier history of this repo is gone. Discarded paths:\n\n'
    change_list "$changes"
  )
  reinit_jail_repo "$copy" "$host" "$label" "llm-custody: operator discarded unsynced changes" "$body"
  printf 'llm-custody: discarded %s path(s) in %s, back at the sync point of %s\n' "$count" "$label" "$since" >&2
  if [ "${#IGNORED_MODS[@]}" -gt 0 ]; then
    printf '          %s modified gitignored file(s) stay as the agent left them.\n' "${#IGNORED_MODS[@]}" >&2
  fi
}

# Answer r at a live sync prompt: make the copy match the host tree as it is
# now, minus the --mask matches, and take that as the new sync point. What
# the agent changed since the last sync is lost, gitignored files included,
# and host-side edits made since the copy was taken reach the jail. Asks
# first when that loses tracked changes or anything in IGNORED_MODS.
reset_copy() {
  local copy="$1" track="$2" host="$3" label="$4" changes="$5" count=0 stage body what=""
  if [ ! -d "$host" ]; then
    printf 'llm-custody: ERROR host tree %s is gone, not resetting %s\n' "$host" "$label" >&2
    return 0
  fi
  if [ -n "$changes" ]; then
    count=$(printf '%s\n' "$changes" | wc -l || true)
    what="$count changed path(s)"
  fi
  if [ "${#IGNORED_MODS[@]}" -gt 0 ]; then
    what="${what:+$what and }${#IGNORED_MODS[@]} modified gitignored file(s)"
  fi
  if [ -n "$what" ]; then
    if ! confirm_drop "throw away $what in the jail copy of $label and reset it to $host"; then
      printf 'llm-custody: NOT resetting %s\n' "$label" >&2
      return 0
    fi
  fi
  # Built beside the copy, which keeps it outside the jail, and masked
  # before any of it reaches the copy: a masked file never shows up in the
  # jail, not even for the length of the transfer.
  stage="${copy%/}.reset"
  rm -rf -- "$stage"
  jail_copy_tree "$host" "$stage"
  jail_apply_masks "$stage" "the reset copy of $host"
  # Synced in place, so an agent process whose cwd is inside the tree keeps
  # a valid one. /.git/ is the jail repo, replaced by reinit_jail_repo.
  if ! rsync -a --delete --exclude=/.git/ -- "$stage/" "$copy/"; then
    rm -rf -- "$stage"
    printf 'llm-custody: ERROR resetting %s from %s failed, the copy may be partly updated\n' "$label" "$host" >&2
    return 0
  fi
  rm -rf -- "$stage"
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" add -A >/dev/null 2>&1 || true
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" commit -q -m "llm-custody host reset" --allow-empty >/dev/null 2>&1 || true
  # The gitignored files the host tree holds now are the ones whose jail
  # edits sync back from here on, files that arrived with this reset
  # included.
  jail_ignored_baseline "$copy" "$track"
  IGNORED_MODS=()
  body=$(
    printf 'The operator reset this tree to the state of the host tree at %s.\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Edits made on the host meanwhile are in it now; the earlier history\n'
    printf 'of this repo is gone.'
    if [ -n "$changes" ]; then
      printf ' Jail changes discarded by the reset:\n\n'
      change_list "$changes"
    fi
  )
  reinit_jail_repo "$copy" "$host" "$label" "llm-custody: operator reset the tree to the host state" "$body"
  printf 'llm-custody: reset %s to the current state of %s\n' "$label" "$host" >&2
}

# Modes limited|nogit: the sandbox worked on a copy, so the real tree is
# still untouched. Diff the copy against the baseline in its tracking git
# dir (never mounted into the sandbox, so the agent cannot rewrite the
# baseline to smuggle a change past this review) and copy the differences
# over.
#
# The copy is a snapshot, so the host tree can move underneath it. A path
# the agent changed whose host side also moved since the last sync point is
# a conflict: with a tty the operator picks per path, without one the host
# file stays and the agent's version is written next to it as
# <path>.llm-custody, since the copy is deleted right after an unattended
# sync and would otherwise take that version with it.
sync_tracked() {
  local copy="$1" track="$2" host="$3" label="$4"
  local changes count applied=0 skipped=0 kept=0 code path ans entry what="unsynced"
  local -a entries=() conflict_paths=() sidecars=() nested=()
  local -A conflict=()
  # --ignore-submodules=all on every status/diff against the tracking dir:
  # a nested repo the agent creates in the copy is tracked as a gitlink, and
  # checking a gitlink for local changes runs git inside that repo with its
  # own config, which the agent writes (core.fsmonitor is a command line).
  changes=$(GIT_DIR="$track" GIT_WORK_TREE="$copy" git status --porcelain --ignore-submodules=all --untracked-files=all 2>/dev/null || true)
  if [ -z "$changes" ]; then
    # Nothing to sync, but the host side may have moved since the copy was
    # made, and a reset is the only way to bring that into the jail.
    if [ "$MODE" = "prompt" ] && [ "$LIVE" = "1" ]; then
      # Worded as an offer, not a yes/no question: a run of y answers meant
      # for the trees that do have changes must read as a skip here.
      [ "${#IGNORED_MODS[@]}" -eq 0 ] || what="tracked"
      ans=$(read_answer "llm-custody: $label has no $what changes [r=reset to host tree, anything else skips] ")
      case "$ans" in
      [rR]) reset_copy "$copy" "$track" "$host" "$label" "" ;;
      esac
    fi
    return 0
  fi
  count=$(printf '%s\n' "$changes" | wc -l || true)

  # Read into an array up front: the conflict prompts below may read their
  # answers from stdin, which must not be the status stream. --no-renames
  # because the 'd' review stages into the tracking index, and a staged
  # rename turns into a two-field -z record the loop would misparse.
  while IFS= read -r -d "" entry; do
    entries+=("$entry")
  done < <(GIT_DIR="$track" GIT_WORK_TREE="$copy" git status --porcelain -z --no-renames --ignore-submodules=all --untracked-files=all 2>/dev/null || true)
  for entry in "${entries[@]+"${entries[@]}"}"; do
    path="${entry:3}"
    [ -n "$path" ] || continue
    path_excluded "$path" && continue
    if host_conflict "$copy" "$track" "$host" "$path"; then
      conflict["$path"]=1
      conflict_paths+=("$path")
    fi
  done

  printf 'llm-custody: %s changed (host: %s):\n' "$label" "$host" >&2
  # --stat for the tracked side (line counts say far more than a status
  # letter about what is about to be written to the host tree), with the
  # untracked paths listed after it since a diff against the baseline
  # commit cannot show them.
  # `|| true` throughout: called from an EXIT trap with errexit still
  # active, where head closing the pipe early (EPIPE) would otherwise abort
  # cleanup before the sync.
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git --no-pager diff --stat --ignore-submodules=all HEAD 2>/dev/null | head -n 40 >&2 || true
  printf '%s\n' "$changes" | grep '^??' | head -n 20 >&2 || true
  if [ "$count" -gt 40 ]; then
    printf '          ... (%s paths total)\n' "$count" >&2
  fi
  if [ "${#conflict_paths[@]}" -gt 0 ]; then
    printf 'llm-custody: %s of these also changed on the host since the last sync:\n' "${#conflict_paths[@]}" >&2
    printf '          %s\n' "${conflict_paths[@]}" | head -n 20 >&2 || true
  fi

  if [ "$MODE" = "prompt" ]; then
    local choices="y/N/d=diff"
    [ "$LIVE" = "1" ] && choices="$choices/x=discard/r=reset from host"
    while true; do
      ans=$(read_answer "llm-custody: sync these back to $host? [$choices] ")
      case "$ans" in
      [yY] | [yY][eE][sS]) break ;;
      [xX] | [rR])
        # Not offered outside a live session, where the copy is deleted
        # right after this: there they mean the same as the default no.
        if [ "$LIVE" != "1" ]; then
          printf 'llm-custody: NOT syncing %s\n' "$label" >&2
          return 0
        fi
        case "$ans" in
        [xX]) discard_copy "$copy" "$track" "$host" "$label" "$changes" ;;
        *) reset_copy "$copy" "$track" "$host" "$label" "$changes" ;;
        esac
        return 0
        ;;
      [dD])
        # Staging into the *tracking* index is what makes new files show
        # up in the diff at all; it is also harmless to leave behind,
        # since a real sync re-runs `add -A` before committing its own
        # sync point anyway.
        GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" add -A >/dev/null 2>&1 || true
        GIT_DIR="$track" GIT_WORK_TREE="$copy" git --no-pager diff --cached --ignore-submodules=all 2>/dev/null | page
        continue
        ;;
      *)
        printf 'llm-custody: NOT syncing %s\n' "$label" >&2
        return 0
        ;;
      esac
    done
  fi

  # -z keeps paths literal (no quoting/escaping of odd names); the status
  # code is the first two chars, the path starts at offset 3.
  CONFLICT_ALL=""
  for entry in "${entries[@]+"${entries[@]}"}"; do
    code="${entry:0:2}"
    path="${entry:3}"
    [ -n "$path" ] || continue
    if path_excluded "$path"; then
      skipped=$((skipped + 1))
      continue
    fi
    if [ -n "${conflict[$path]+x}" ]; then
      if [ "$MODE" = "prompt" ]; then
        resolve_conflict "$copy" "$host" "$path"
      else
        RESOLUTION=sidecar
      fi
      case "$RESOLUTION" in
      keep)
        kept=$((kept + 1))
        continue
        ;;
      sidecar)
        # Nothing to save when the agent's side of the conflict is a
        # deletion.
        if [ -e "$copy/$path" ] || [ -L "$copy/$path" ]; then
          mkdir -p -- "$(dirname -- "$host/$path")" 2>/dev/null || true
          if cp -a --reflink=auto -- "$copy/$path" "$host/$path.llm-custody" 2>/dev/null; then
            sidecars+=("$path.llm-custody")
          fi
        fi
        kept=$((kept + 1))
        continue
        ;;
      esac
    fi
    case "$code" in
    *D*)
      rm -rf -- "$host/${path:?sync path empty}" 2>/dev/null || true
      ;;
    *)
      # A directory entry is a nested repo the agent made in the jail
      # (the tracking repo lists those as one path instead of their files).
      # cp -a onto an existing host directory would nest a second copy
      # inside it, so such a path is held back and named instead.
      if [ -d "$copy/$path" ] && [ ! -L "$copy/$path" ]; then
        nested+=("$copy/$path")
        continue
      fi
      mkdir -p -- "$(dirname -- "$host/$path")" 2>/dev/null || true
      cp -a --reflink=auto -- "$copy/$path" "$host/$path" 2>/dev/null || true
      ;;
    esac
    applied=$((applied + 1))
  done
  # Advance the baseline so a following sync (mid-session syncs are meant to
  # be repeatable) only reports what changed since this one, instead of
  # re-copying everything already synced. Kept conflicts advance with it:
  # the agent's version counts as seen, and the host side still differs
  # from the new baseline, so a later agent edit to that path conflicts
  # again instead of overwriting the kept file.
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" add -A >/dev/null 2>&1 || true
  GIT_DIR="$track" GIT_WORK_TREE="$copy" git "${GIT_IDENT[@]}" commit -q -m "llm-custody sync point" --allow-empty >/dev/null 2>&1 || true
  printf 'llm-custody: synced %s path(s) back to %s (review with git status/diff)\n' "$applied" "$host" >&2
  if [ "$skipped" -gt 0 ]; then
    printf '          %s path(s) held back by --sync-exclude.\n' "$skipped" >&2
  fi
  if [ "$kept" -gt 0 ]; then
    printf '          %s conflicting path(s) kept their host version.\n' "$kept" >&2
  fi
  if [ "${#sidecars[@]}" -gt 0 ]; then
    printf '          agent versions of those written beside them, review and delete:\n' >&2
    printf '            %s\n' "${sidecars[@]}" >&2
  fi
  if [ "${#nested[@]}" -gt 0 ]; then
    printf '          git repos created in the jail were not synced, they are at:\n' >&2
    printf '            %s\n' "${nested[@]}" >&2
  fi
}

# Sorts IGNORED_MODS into groups by the ignore rule that covers each path
# (`git check-ignore`), so one rule with hundreds of touched files, an
# installed dependency tree for instance, is a single line to pick or pass
# over. Fills IGN_RULES (pattern, in order of first appearance), IGN_WHERE
# (file:line the pattern comes from), IGN_COUNT, and IGN_OF, the group index
# of each IGNORED_MODS entry. A path no rule covers any more was un-ignored
# in the jail and is an untracked path of the tracked sync, so it is taken
# out of IGNORED_MODS here.
ignored_group() {
  local copy="$1" track="$2" src line pat path key i
  local -A rule=() where=() index=()
  local -a kept=()
  IGN_RULES=()
  IGN_WHERE=()
  IGN_COUNT=()
  IGN_OF=()
  [ "${#IGNORED_MODS[@]}" -gt 0 ] || return 0
  while IFS= read -r -d "" src && IFS= read -r -d "" line && IFS= read -r -d "" pat && IFS= read -r -d "" path; do
    rule["$path"]="$pat"
    where["$path"]="$src:$line"
  done < <(printf '%s\0' "${IGNORED_MODS[@]}" | GIT_DIR="$track" GIT_WORK_TREE="$copy" git -C "$copy" check-ignore -v -z --stdin 2>/dev/null || true)
  for path in "${IGNORED_MODS[@]}"; do
    [ -n "${rule[$path]+x}" ] || continue
    key="${where[$path]}:${rule[$path]}"
    if [ -z "${index[$key]+x}" ]; then
      index["$key"]="${#IGN_RULES[@]}"
      IGN_RULES+=("${rule[$path]}")
      IGN_WHERE+=("${where[$path]}")
      IGN_COUNT+=(0)
    fi
    i="${index[$key]}"
    IGN_COUNT[i]=$((IGN_COUNT[i] + 1))
    kept+=("$path")
    IGN_OF+=("$i")
  done
  IGNORED_MODS=("${kept[@]+"${kept[@]}"}")
}

# The paths of group $1, one per line.
ignored_group_paths() {
  local i
  for i in "${!IGNORED_MODS[@]}"; do
    [ "${IGN_OF[$i]}" = "$1" ] && printf '%s\n' "${IGNORED_MODS[$i]}"
  done
  return 0
}

# Second part of a copy sync: the modified gitignored files IGNORED_MODS
# holds. Asked separately from the tracked changes and by ignore rule, with
# nothing selected by default, because no baseline content exists for these
# files: a yes writes the jail version over whatever the host has now, so
# it has to be a choice made per rule. The single paths and their diffs
# against the host are one answer away.
#
# With nobody to choose, nothing is written: the changes are named in a
# warning and go away with the copy.
sync_ignored() {
  local copy="$1" track="$2" host="$3" label="$4"
  local i n ans tok path old applied=0 valid
  local -a picked=()
  ignored_group "$copy" "$track"
  [ "${#IGNORED_MODS[@]}" -gt 0 ] || return 0

  if [ "$MODE" != "prompt" ]; then
    warn "$label: ${#IGNORED_MODS[@]} modified gitignored file(s) NOT synced, nobody to choose them:"
    for i in "${!IGN_RULES[@]}"; do
      hint "${IGN_RULES[$i]}  ${IGN_COUNT[$i]} file(s)"
    done
    return 0
  fi

  while true; do
    printf 'llm-custody: %s: gitignored files modified in the jail, by ignore rule:\n' "$label" >&2
    for i in "${!IGN_RULES[@]}"; do
      printf '          %2s) %s  %s file(s)  (%s)\n' "$((i + 1))" "${IGN_RULES[$i]}" "${IGN_COUNT[$i]}" "${IGN_WHERE[$i]}" >&2
    done
    # One answer per line with the key set apart in colour: packed into
    # the prompt, "l N" and "d N" were hard to tell from their separators.
    printf '          %s%-7s%s write those rules over the files in %s\n' "$C_YELLOW" "1 2 .." "$C_RESET" "$host" >&2
    printf '          %s%-7s%s write all of them\n' "$C_YELLOW" "a" "$C_RESET" >&2
    printf '          %s%-7s%s list the files of rule N\n' "$C_YELLOW" "l N" "$C_RESET" >&2
    printf '          %s%-7s%s diff rule N against the host\n' "$C_YELLOW" "d N" "$C_RESET" >&2
    printf '          %s%-7s%s write nothing\n' "$C_YELLOW" "enter" "$C_RESET" >&2
    ans=$(read_answer "llm-custody: which? ")
    # Commas read as spaces, so "1,3" and "1 3" both work.
    read -r -a picked <<<"${ans//,/ }" || true
    case "${picked[0]:-}" in
    "")
      printf 'llm-custody: NOT syncing the gitignored files of %s\n' "$label" >&2
      return 0
      ;;
    a | A)
      picked=()
      for i in "${!IGN_RULES[@]}"; do picked+=("$((i + 1))"); done
      break
      ;;
    l | L | d | D)
      n="${picked[1]:-}"
      case "$n" in "" | *[!0-9]*) n=0 ;; esac
      if [ "$n" -lt 1 ] || [ "$n" -gt "${#IGN_RULES[@]}" ]; then
        printf 'llm-custody: give the number of a rule, as in "%s 1"\n' "${picked[0]}" >&2
        continue
      fi
      case "${picked[0]}" in
      l | L) ignored_group_paths "$((n - 1))" | page ;;
      *)
        # /dev/null stands in for a host file that is gone.
        while IFS= read -r path; do
          old="$host/$path"
          [ -e "$old" ] || [ -L "$old" ] || old=/dev/null
          git --no-pager diff --no-index -- "$old" "$copy/$path" 2>/dev/null || true
        done < <(ignored_group_paths "$((n - 1))") | page
        ;;
      esac
      continue
      ;;
    esac
    valid=1
    for tok in "${picked[@]}"; do
      case "$tok" in *[!0-9]*) valid=0 ;; esac
      if [ "$valid" = "1" ] && { [ "$tok" -lt 1 ] || [ "$tok" -gt "${#IGN_RULES[@]}" ]; }; then valid=0; fi
    done
    [ "$valid" = "1" ] && break
    printf 'llm-custody: not understood: %s\n' "$ans" >&2
  done

  for i in "${!IGNORED_MODS[@]}"; do
    path="${IGNORED_MODS[$i]}"
    valid=0
    for tok in "${picked[@]}"; do
      [ "$((tok - 1))" = "${IGN_OF[$i]}" ] && valid=1
    done
    [ "$valid" = "1" ] || continue
    mkdir -p -- "$(dirname -- "$host/$path")" 2>/dev/null || true
    if [ -L "$copy/$path" ]; then
      # cp refuses to write a symlink over an existing one.
      cp -a --remove-destination -- "$copy/$path" "$host/$path" 2>/dev/null || continue
    else
      cp -a --reflink=auto -- "$copy/$path" "$host/$path" 2>/dev/null || continue
    fi
    applied=$((applied + 1))
  done
  printf 'llm-custody: wrote %s of %s modified gitignored file(s) to %s\n' "$applied" "${#IGNORED_MODS[@]}" "$host" >&2
}

# One copied tree: the tracked changes first, then the gitignored files.
# The scan runs before either prompt because a reset answered at the first
# one has to know what it would throw away; a reset empties IGNORED_MODS, so
# the second part has nothing left to ask about.
sync_copy() {
  local copy="$1" track="$2" host="$3" label="$4"
  ignored_scan "$copy" "$track" "$host" "$label"
  sync_tracked "$copy" "$track" "$host" "$label"
  sync_ignored "$copy" "$track" "$host" "$label"
}

# Mode overlay: fold the overlay upper layer into the real tree.
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
      OVERLAY_SKIPPED=$((OVERLAY_SKIPPED + 1))
      continue
    fi
    if [ -c "$entry" ]; then
      if [ "$(stat -c '%t:%T' "$entry")" = "0:0" ]; then
        # ${host:?}/${base:?}: host is always set and base is a real dir
        # entry (never empty) - the :? form just keeps the SC2115 lint
        # (rm -rf against an unguarded path) satisfied, so a deletion can
        # never target something empty by accident.
        rm -rf -- "${host:?remove target host unset}/${base:?remove target name unset}" 2>/dev/null
        OVERLAY_APPLIED=$((OVERLAY_APPLIED + 1))
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
        cp -a -- "$entry" "$host/$base" 2>/dev/null && OVERLAY_APPLIED=$((OVERLAY_APPLIED + 1))
      fi
    elif [ ! -e "$host/$base" ] || ! cmp -s "$entry" "$host/$base"; then
      cp -a -- "$entry" "$host/$base" 2>/dev/null && OVERLAY_APPLIED=$((OVERLAY_APPLIED + 1))
    fi
  done
}

sync_overlay() {
  local upper="$1" host="$2" label="$3" ans
  [ -n "$(ls -A "$upper" 2>/dev/null)" ] || return 0
  # Unlike a copy, an overlay is never synced unattended. A copy replaces
  # what used to be a direct rw bind, so a headless run that silently threw
  # its work away would be worse than the host mutation it avoids;
  # an overlay is the opposite - an explicit request to review
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
  [yY] | [yY][eE][sS]) ;;
  *)
    printf 'llm-custody: NOT syncing - %s changes stay in the sandbox runtime dir and are discarded\n' "$label" >&2
    return 0
    ;;
  esac
  OVERLAY_APPLIED=0
  OVERLAY_SKIPPED=0
  sync_overlay_dir "$upper" "$host"
  printf 'llm-custody: synced %s changed path(s) back to %s (review with git status/diff)\n' "$OVERLAY_APPLIED" "$host" >&2
  if [ "$OVERLAY_SKIPPED" -gt 0 ]; then
    printf '          %s path(s) held back by --sync-exclude.\n' "$OVERLAY_SKIPPED" >&2
  fi
}

# A manifest with no entries is the normal state of a session that bound
# everything straight through (and of any session before its first copy
# mount). The exit trap skips those; a mid-session run deserves an answer
# rather than silence.
if [ "$MODE" = "prompt" ] && ! grep -q '^[a-z]' "$MANIFEST" 2>/dev/null; then
  printf 'llm-custody: nothing to sync - no tree in this session is isolated from the host\n' >&2
  exit 0
fi

# fd 3 for the manifest so the prompts above keep stdin/the tty to
# themselves.
while IFS=$'\t' read -r type src track host label <&3; do
  case "$type" in
  "" | \#*) continue ;;
  copy)
    if [ -d "$src" ] && [ -d "$track" ]; then
      sync_copy "$src" "$track" "$host" "$label"
    fi
    ;;
  overlay)
    if [ -d "$src" ]; then
      sync_overlay "$src" "$host" "$label"
    fi
    ;;
  *) printf 'llm-custody: unknown sync manifest entry type: %s\n' "$type" >&2 ;;
  esac
done 3<"$MANIFEST"
