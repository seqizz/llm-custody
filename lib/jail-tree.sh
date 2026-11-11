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
  local dir="$1" label="$2" removed count
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  # Subshell so the cd and the glob options stay local to the expansion.
  removed=$(
    cd "$dir" || exit 0
    shopt -s nullglob globstar
    for m in "${MASK_PATTERNS[@]}"; do
      # shellcheck disable=SC2086
      for entry in $m; do
        rm -rf -- "${entry:?mask target empty}" && printf '%s\n' "$entry"
      done
    done
    # A failed rm must not take the whole runner down through errexit:
    # the subshell's status is the loop's, and the assignment below
    # propagates it.
    exit 0
  )
  [ -n "$removed" ] || return 0
  count=$(printf '%s\n' "$removed" | wc -l)
  log "--mask: removed $count path(s) from $label"
  while IFS= read -r line; do hint "$line"; done <<< "$removed"
}

# The --mask matches of a tree the sandbox sees through a direct bind, as
# NUL-separated tree-relative paths on stdout. There is no copy to delete
# from there, so the caller shadows each match with an empty read-only
# file/dir instead (bwrap binds for the workspace, holder-side binds for an
# extra mount).
#
# NUL-delimited: a path with a newline in it would otherwise split into two
# bogus mask targets.
jail_mask_matches() {
  local hostroot="$1" entry
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  (
    cd "$hostroot" || exit 0
    shopt -s nullglob globstar
    for m in "${MASK_PATTERNS[@]}"; do
      # shellcheck disable=SC2086
      for entry in $m; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        printf '%s\0' "$entry"
      done
    done
    exit 0
  )
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
