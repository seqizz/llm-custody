# Tree helpers shared by the runner (workspace copy, workspace masks) and
# lib/mount-ctl.sh (every extra mount, at launch and live). Plain shell with
# no Nix interpolation, included into both wrappers via builtins.readFile so
# a copy made at launch and a copy made mid-session are produced by the
# same code.
#
# Callers provide: MASK_PATTERNS (array of --mask globs), the log/vlog/hint/
# die helpers, and git on PATH.

# Identity for the commits made on the host's behalf (jail baseline, change
# tracking). The host .gitconfig may have none, or a signing key whose agent
# isn't reachable here.
JAIL_GIT_IDENT=(-c user.name=llm-custody -c user.email=llm-custody@localhost -c commit.gpgsign=false)

# Copy a host tree into the jail runtime dir, minus its .git - used for
# the workspace and for every extra rw mount under --git limited|none.
jail_copy_tree() {
  local src="$1" dest="$2" entry
  mkdir -p "$dest"
  # dotglob picks up hidden entries (.config, .envrc) but never . or ..;
  # .git is skipped explicitly. --reflink=auto makes this a cheap CoW
  # clone on btrfs/xfs and a normal copy elsewhere.
  shopt -s dotglob nullglob
  for entry in "$src"/*; do
    [ "${entry##*/}" = ".git" ] && continue
    cp -a --reflink=auto -- "$entry" "$dest/" || die "copying $entry into the jail copy at $dest failed"
  done
  shopt -u dotglob nullglob
}

# Delete every --mask match from a jail copy. Deleting beats shadowing
# with an empty bind: with no .git next to them there is nothing left to
# recover the contents from.
#
# Globs are relative to the root of the tree they are applied to, and
# they are applied to *every* copied tree, not just the workspace: a
# pattern written to keep credentials out of the jail is meant to keep
# them out of a second checkout too.
#
# Must run before jail_init_repo/jail_track_init so neither baseline
# ever contains the masked paths. That ordering is also what keeps the
# masks out of the sync-back diff - copy and tracking baseline agree,
# so the host tree's own copies are never reported as deletions.
jail_apply_masks() {
  local dir="$1" label="$2" path
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  jail_mask_collect "$dir"
  for path in "${MASK_HIT_PATH[@]}"; do
    # A failed rm must not take the whole runner down through errexit, but
    # it leaves masked content in the jail, so it is reported.
    rm -rf -- "$dir/${path:?mask target empty}" || warn "could not remove $path from $label"
  done
  jail_mask_report "$label" removed verbose
}

# Every --mask match under a tree, as two parallel arrays: MASK_HIT_IDX
# (index into MASK_PATTERNS) and MASK_HIT_PATH (tree-relative path).
# Globals rather than stdout because callers need both the paths and the
# pattern behind each one, for the per-pattern report below. A copy is the
# host tree minus .git, so matching the host tree gives exactly what a copy
# would lose, which is what lets --dry-run report masks without copying.
#
# NUL-delimited records: a path with a newline in it would otherwise split
# into two bogus mask targets.
jail_mask_collect() {
  local hostroot="$1" rec
  MASK_HIT_IDX=()
  MASK_HIT_PATH=()
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' rec; do
    MASK_HIT_IDX+=("${rec%%$'\t'*}")
    MASK_HIT_PATH+=("${rec#*$'\t'}")
  done < <(
    # Subshell so the cd and the glob options stay local to the expansion.
    cd "$hostroot" || exit 0
    shopt -s nullglob globstar
    for i in "${!MASK_PATTERNS[@]}"; do
      # shellcheck disable=SC2086
      for entry in ${MASK_PATTERNS[$i]}; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        printf '%s\t%s\0' "$i" "$entry"
      done
    done
    exit 0
  )
}

# Report the last jail_mask_collect for one tree: a summary line with a
# count per pattern, then (DETAIL "always", or "verbose" under -v) the
# matched paths grouped by pattern. Patterns with no match stay in the
# list, since a zero next to a pattern is how a typo in it shows up. Below
# -v each group stops at 20 paths, so a broad glob over a large tree does
# not bury the rest of the output.
jail_mask_report() {
  local label="$1" what="$2" detail="$3" i j n shown cap=20 counts=""
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  [ "$VERBOSITY" -lt 2 ] || cap=0
  for i in "${!MASK_PATTERNS[@]}"; do
    n=0
    for j in "${!MASK_HIT_IDX[@]}"; do
      if [ "${MASK_HIT_IDX[$j]}" = "$i" ]; then n=$((n+1)); fi
    done
    counts="$counts, ${MASK_PATTERNS[$i]}: $n"
  done
  log "--mask: $label, ${#MASK_HIT_PATH[@]} path(s) $what (${counts#, })"
  # hint is not silenced by --quiet, and these lines hang off the log above.
  [ "$VERBOSITY" -ge 1 ] || return 0
  if [ "$detail" != "always" ] && [ "$VERBOSITY" -lt 2 ]; then return 0; fi
  for i in "${!MASK_PATTERNS[@]}"; do
    hint "${MASK_PATTERNS[$i]}"
    n=0; shown=0
    for j in "${!MASK_HIT_IDX[@]}"; do
      [ "${MASK_HIT_IDX[$j]}" = "$i" ] || continue
      n=$((n+1))
      if [ "$cap" -eq 0 ] || [ "$n" -le "$cap" ]; then
        hint "  ${MASK_HIT_PATH[$j]}"
        shown=$n
      fi
    done
    if [ "$n" -eq 0 ]; then
      hint "  (no match)"
    elif [ "$n" -gt "$shown" ]; then
      hint "  ... $((n - shown)) more (-v lists all)"
    fi
  done
}

# Re-init a copy as a fresh repo with a single baseline commit, so in-jail
# git (status/diff/commit/branch) still works with no history to mine.
jail_init_repo() {
  local dir="$1" src="$2" label="$3" branch
  # Same branch name as the host checkout so prompts, status lines and
  # the agent's own assumptions about the branch still line up.
  branch=$(git -C "$src" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)
  git -C "$dir" init -q -b "$branch"
  git -C "$dir" "${JAIL_GIT_IDENT[@]}" add -A
  git -C "$dir" "${JAIL_GIT_IDENT[@]}" commit -q -m "llm-custody jail baseline" --allow-empty
  git -C "$dir" tag jail-baseline
  vlog "$label: branch $branch, single commit tagged jail-baseline"
}

# Change tracking for the sync-back, in its own git dir under RUNDIR that
# is never mounted into the sandbox. Deliberately not the jail repo
# above: that one is writable by the agent, which could amend its
# baseline away and have changes sync back unreviewed. /.git/ is excluded
# so the jail repo's own objects never count as changes.
jail_track_init() {
  local worktree="$1" track="$2"
  GIT_DIR="$track" GIT_WORK_TREE="$worktree" git init -q
  mkdir -p "$track/info"
  printf '/.git/\n' > "$track/info/exclude"
  GIT_DIR="$track" GIT_WORK_TREE="$worktree" git "${JAIL_GIT_IDENT[@]}" add -A
  GIT_DIR="$track" GIT_WORK_TREE="$worktree" git "${JAIL_GIT_IDENT[@]}" commit -q -m "llm-custody tracking baseline" --allow-empty
}
