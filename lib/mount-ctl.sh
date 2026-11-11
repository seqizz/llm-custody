# llm-custody mount controller.
#
# Attaches a host tree to a running jail, and detaches it again, without
# restarting anything. One implementation for three callers: the runner at
# launch (every --mount/--ro-mount goes through here), the operator from a
# second terminal ($RUNDIR/mount, llm-custody-mount, or a terminal
# keybinding), and the request broker when the operator approves an agent's
# `custody-request --mount`.
#
# How a mount reaches a jail that is already running: the netns holder owns
# a mount namespace whose mounts are all `shared`, and bwrap marks the jail's
# tree `slave` to it. A bind made in the holder on a directory the jail has
# bound (a "dock": /workspace and /mnt are both bound from $RUNDIR/dock/*)
# propagates into the jail at the same relative path, and an umount in the
# holder propagates the same way. Nothing here enters the jail's own
# namespaces, and the jail cannot do any of this itself (CAP_SYS_ADMIN is
# dropped there).
#
# A guest path whose parent is not a dock cannot arrive by propagation. At
# launch the runner still accepts one - the tree is bound in the holder at a
# private mountpoint and bwrap binds that at the guest path - but such a
# mount is `fixed`: it stays until the session ends.
#
# Invocation: mount-ctl RUNDIR <command> [args]. The runner writes
# RUNDIR/mount.env with everything else (holder pid, docks, masks, excludes).
#
# Wrapped by lib/mount-ctl.nix, which prepends SYNC_BACK and lib/jail-tree.sh.

RUNDIR=""
VERBOSITY=1
# Everything below is set by RUNDIR/mount.env, written by the runner with
# `declare -p`. Declared here first so a missing key reads as empty rather
# than as an unbound variable.
HOLDER_PID=""
MASK_PATTERNS=()
SYNC_EXCLUDES=()
SYNC_MANIFEST=""
DOCK_GUESTS=()
DOCK_SRCS=()
WORKSPACE_GUEST=""

C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
fi
log()  { [ "$VERBOSITY" -ge 1 ] && printf '%sllm-custody:%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2 || true; }
vlog() { [ "$VERBOSITY" -ge 2 ] && printf '%sllm-custody:%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$*" "$C_RESET" >&2 || true; }
warn() { printf '%sllm-custody: WARNING%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%sllm-custody: ERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
hint() { printf '            %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'USAGE'
Usage: mount add [--mode MODE] [--guest PATH] [--name NAME] HOSTPATH
       mount remove [--auto|--discard] NAME|GUESTPATH
       mount list
       mount docks

  add      attach HOSTPATH to the running jail
           --mode ro       read-only bind (default)
                  full     the real tree, read-write - writes hit the host
                  limited  a copy re-initialised as a baseline-only repo,
                           synced back on request and at exit (alias: copy)
                  none     the same copy without a repo
                  overlay  copy-on-write over the real tree, synced back
                           only on explicit confirmation
           --guest PATH    where the jail sees it (default: under the first
                           dock, named after HOSTPATH)
           --name NAME     the mount's name, for remove and list
  remove   detach it again. A copy or overlay is offered for sync-back
           first; --auto syncs a copy without asking, --discard skips it
  list     the mounts of this session
  docks    the guest directories a live mount can land in
USAGE
  exit 0
}

if [ $# -lt 1 ]; then usage; fi
RUNDIR="$1"; shift
[ -d "$RUNDIR" ] || die "no such session runtime dir: $RUNDIR"
[ -r "$RUNDIR/mount.env" ] || die "$RUNDIR/mount.env missing - this session's runner predates live mounts, or has already ended"
# shellcheck source=/dev/null
. "$RUNDIR/mount.env"
if [ -z "$HOLDER_PID" ] || ! kill -0 "$HOLDER_PID" 2>/dev/null; then
  die "the session's namespace holder (pid ${HOLDER_PID:-?}) is gone"
fi

MOUNTS_DIR="$RUNDIR/mounts"
mkdir -p "$MOUNTS_DIR"

holder() {
  nsenter -U -m -t "$HOLDER_PID" --preserve-credentials -- "$@"
}

record_get() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s' "${line#"$key="}"; return 0 ;;
    esac
  done < "$file"
}

# The mount whose name or guest path is $1, as its record directory.
find_mount() {
  local want="$1" dir
  for dir in "$MOUNTS_DIR"/*/; do
    [ -r "$dir/record" ] || continue
    if [ "$(record_get "$dir/record" name)" = "$want" ] ||
       [ "$(record_get "$dir/record" guest)" = "$want" ]; then
      printf '%s' "${dir%/}"
      return 0
    fi
  done
  return 1
}

# Holder-side mountpoint for a guest path: DOCKSRC/<basename> when the guest
# path's parent is a dock (attachable and detachable live), empty otherwise.
dock_point() {
  local guest="$1" parent base i
  parent=$(dirname -- "$guest")
  base=$(basename -- "$guest")
  for i in "${!DOCK_GUESTS[@]}"; do
    if [ "${DOCK_GUESTS[$i]}" = "$parent" ]; then
      printf '%s/%s' "${DOCK_SRCS[$i]}" "$base"
      return 0
    fi
  done
  return 1
}

# Overlayfs reads its option string with ',' and ':' as separators, so a
# layer path containing one has to be escaped (bwrap does the same inside
# its --overlay handling).
ovl_escape() {
  local p="$1"
  p="${p//\\/\\\\}"
  p="${p//,/\\,}"
  p="${p//:/\\:}"
  printf '%s' "$p"
}

# Shadow every --mask match of a directly bound tree with an empty read-only
# file/dir, as child mounts of the tree's own bind so they propagate into the
# jail along with it. Weaker than deleting from a copy, which is why a tree
# bound with its .git gets a warning: the masked content is still readable
# as blobs (git show HEAD:<path>).
shadow_masks() {
  local hostroot="$1" point="$2" mdir="$3" label="$4" entry n=0
  local -a matches
  mapfile -d "" -t matches < <(jail_mask_matches "$hostroot")
  [ "${#matches[@]}" -gt 0 ] || return 0
  mkdir -p "$mdir"
  for entry in "${matches[@]}"; do
    n=$((n+1))
    if [ -d "$hostroot/$entry" ] && [ ! -L "$hostroot/$entry" ]; then
      mkdir -p "$mdir/$n"
    else
      : > "$mdir/$n"
    fi
    holder mount --bind -o ro "$mdir/$n" "$point/$entry" ||
      warn "could not shadow $entry in $label"
  done
  log "--mask: shadowed $n path(s) in $label with empty binds"
  if [ -d "$hostroot/.git" ]; then
    warn "$label is bound along with its .git, so masked content is still"
    hint "readable from history (git show HEAD:<path>). Only a copy (mode"
    hint "limited|none) removes it outright."
  fi
}

cmd_add() {
  local mode="ro" guest="" name="" host="" allow_fixed=0 point fixed=0
  local mdir copy track upper work label hooks
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)  [ $# -ge 2 ] || die "--mode needs a value"; mode="$2"; shift 2 ;;
      --guest) [ $# -ge 2 ] || die "--guest needs a value"; guest="$2"; shift 2 ;;
      --name)  [ $# -ge 2 ] || die "--name needs a value"; name="$2"; shift 2 ;;
      # Launch-time only: the runner can still bind a non-dock guest path
      # through bwrap, a live caller cannot.
      --allow-fixed) allow_fixed=1; shift ;;
      -h|--help) usage ;;
      --) shift; break ;;
      -*) die "add: unknown option: $1" ;;
      *)  [ -z "$host" ] || die "add takes exactly one host path"; host="$1"; shift ;;
    esac
  done
  [ -n "$host" ] || [ $# -eq 0 ] || { host="$1"; shift; }
  [ -n "$host" ] || die "add: which host path?"
  case "$mode" in
    copy) mode="limited" ;;
    ro|full|limited|none|overlay) ;;
    *) die "add: --mode expects ro|full|limited|none|overlay, got: $mode" ;;
  esac
  case "$host" in /*) ;; *) host="$(pwd)/$host" ;; esac
  [ -e "$host" ] || die "mount path does not exist: $host"

  if [ -z "$name" ]; then
    name=$(basename -- "$host")
    case "$name" in
      /|.|..)
        err "cannot derive a mount name from '$host'"
        hint "pass one: --name NAME"
        exit 1 ;;
    esac
    # Two trees of the same basename are an ordinary case (two checkouts of
    # one repo): the second one gets a numbered name instead of an error,
    # since the name is only how remove/list refer to it. A guest path
    # collision below is still an error - that one the agent would notice.
    if [ -d "$MOUNTS_DIR/$name" ]; then
      local n=2
      while [ -d "$MOUNTS_DIR/$name-$n" ]; do n=$((n+1)); done
      name="$name-$n"
    fi
  fi
  case "$name" in
    ""|.|..|*/*) die "not usable as a mount name: $name" ;;
  esac
  [ ! -d "$MOUNTS_DIR/$name" ] || die "a mount named $name already exists (see: list)"

  if [ -z "$guest" ]; then
    [ "${#DOCK_GUESTS[@]}" -gt 0 ] || die "this session has no dock to attach a live mount under"
    guest="${DOCK_GUESTS[0]}/$name"
  fi
  case "$guest" in /*) ;; *) die "--guest must be an absolute path: $guest" ;; esac
  guest="${guest%/}"
  [ "$guest" != "$WORKSPACE_GUEST" ] || die "$guest is the workspace itself"
  if find_mount "$guest" >/dev/null; then
    die "something is already mounted at $guest (see: list)"
  fi
  for i in "${!DOCK_GUESTS[@]}"; do
    [ "$guest" != "${DOCK_GUESTS[$i]}" ] || die "$guest is a dock directory, mount under it instead"
  done

  if point=$(dock_point "$guest"); then
    fixed=0
  elif [ "$allow_fixed" = "1" ]; then
    fixed=1
    point="$RUNDIR/dock/fixed/$name"
  else
    err "$guest is not directly under a dock, so it cannot be attached to a running jail"
    hint "live mounts go under: ${DOCK_GUESTS[*]:-(none)}"
    exit 1
  fi

  mdir="$MOUNTS_DIR/$name"
  label="mount $guest"
  mkdir -p "$mdir" "$(dirname -- "$point")"
  # The docks are read-only inside the jail, so nothing there can be the
  # agent's; checked anyway, because a symlink at the mountpoint would send
  # the holder-side bind wherever it points.
  if [ -L "$point" ] || [ -L "$(dirname -- "$point")" ]; then
    die "$point is a symlink - refusing to mount over it"
  fi

  if [ ! -d "$host" ]; then
    # Single file: nothing to copy into a repo or diff against a baseline, so
    # it is bound directly in every mode, read-only unless asked otherwise.
    if [ "$mode" != "ro" ] && [ "$mode" != "full" ]; then
      warn "$host is a file - bound directly, writes hit the host immediately"
      mode="full"
    fi
    : > "$point"
  else
    mkdir -p "$point"
  fi

  copy=""; track=""; upper=""; work=""
  case "$mode" in
    ro)
      holder mount --bind -o ro "$host" "$point" || { rm -rf "$mdir"; die "binding $host failed"; }
      [ -d "$host" ] && shadow_masks "$host" "$point" "$mdir/masks" "$guest"
      ;;
    full)
      holder mount --bind "$host" "$point" || { rm -rf "$mdir"; die "binding $host failed"; }
      # The real tree is writable, its hooks are not: a jailed agent must not
      # be able to plant git hooks that run on the host later. (In-jail git
      # already pins core.hooksPath to the workspace's hooks, so these never
      # fire inside the jail either way.)
      hooks="$host/.git/hooks"
      if [ -d "$hooks" ]; then
        holder mount --bind -o ro "$hooks" "$point/.git/hooks" || warn "could not bind $hooks read-only"
      fi
      [ -d "$host" ] && shadow_masks "$host" "$point" "$mdir/masks" "$guest"
      ;;
    limited|none)
      command -v git >/dev/null 2>&1 || die "mode $mode needs git (it records the baseline used for sync-back)"
      copy="$mdir/copy"
      track="$mdir/track.git"
      log "mode $mode - copying $host into $RUNDIR (history stays on the host)"
      jail_copy_tree "$host" "$copy"
      jail_apply_masks "$copy" "the copy of $host"
      if [ "$mode" = "limited" ] && [ -d "$host/.git" ]; then
        jail_init_repo "$copy" "$host" "jail repo for $guest"
      fi
      jail_track_init "$copy" "$track"
      printf 'copy\t%s\t%s\t%s\t%s\n' "$copy" "$track" "$host" "$label" >> "$SYNC_MANIFEST"
      holder mount --bind "$copy" "$point" || { rm -rf "$mdir"; die "binding the copy of $host failed"; }
      ;;
    overlay)
      # Upper and work dir must share a filesystem (overlayfs requirement);
      # both under $RUNDIR, which the runner's --overlay-workspace preflight
      # probed for unprivileged-overlay support. userxattr is what overlayfs
      # requires from a mount made inside a user namespace.
      upper="$mdir/upper"; work="$mdir/work"
      mkdir -p "$upper" "$work"
      printf 'overlay\t%s\t-\t%s\t%s\n' "$upper" "$host" "overlay $label" >> "$SYNC_MANIFEST"
      if ! holder mount -t overlay overlay \
           -o "lowerdir=$(ovl_escape "$host"),upperdir=$(ovl_escape "$upper"),workdir=$(ovl_escape "$work"),userxattr" \
           "$point"; then
        rm -rf "$mdir"
        err "overlay mount of $host failed"
        hint "unprivileged overlayfs needs kernel >= 5.11 and an upper layer on a filesystem"
        hint "with user xattr support (tmpfs: kernel >= 6.6); try --tmpdir on disk"
        exit 1
      fi
      shadow_masks "$host" "$point" "$mdir/masks" "$guest"
      ;;
  esac

  {
    printf 'name=%s\n' "$name"
    printf 'host=%s\n' "$host"
    printf 'guest=%s\n' "$guest"
    printf 'mode=%s\n' "$mode"
    printf 'point=%s\n' "$point"
    printf 'fixed=%s\n' "$fixed"
    printf 'copy=%s\n' "$copy"
    printf 'track=%s\n' "$track"
    printf 'upper=%s\n' "$upper"
    printf 'work=%s\n' "$work"
    printf 'added=%s\n' "$(date +%s)"
  } > "$mdir/record.tmp"
  mv -f "$mdir/record.tmp" "$mdir/record"

  case "$mode" in
    full)    log "mounted $host at $guest ${C_RED}read-write, real tree${C_RESET}" ;;
    overlay) log "mounted $host at $guest ${C_YELLOW}copy-on-write${C_RESET}" ;;
    ro)      log "mounted $host at $guest read-only" ;;
    *)       log "mounted a copy of $host at $guest (mode $mode, syncs back on request and at exit)" ;;
  esac
  [ "$fixed" = "0" ] || vlog "$guest is outside every dock: fixed for the whole session"
  # The one line on stdout, for callers that need the answer rather than the
  # commentary (the broker tells the agent where its request landed).
  printf '%s\t%s\t%s\n' "$guest" "$point" "$fixed"
}

# Drop this mount's lines from the shared sync manifest. The exit trap, the
# dirty watcher and a mid-session sync all read the file afresh, so after
# this none of them sees the tree again.
manifest_drop() {
  local src="$1" tmp line
  [ -n "$SYNC_MANIFEST" ] && [ -f "$SYNC_MANIFEST" ] || return 0
  tmp="$SYNC_MANIFEST.tmp.$$"
  : > "$tmp"
  while IFS= read -r line; do
    case "$line" in
      *$'\t'"$src"$'\t'*) continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
  done < "$SYNC_MANIFEST"
  mv -f "$tmp" "$SYNC_MANIFEST"
}

cmd_remove() {
  local sync_mode="prompt" want="" mdir rec name guest mode point fixed copy track upper
  local -a excl=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto)    sync_mode="auto"; shift ;;
      --discard) sync_mode="discard"; shift ;;
      -h|--help) usage ;;
      -*) die "remove: unknown option: $1" ;;
      *)  [ -z "$want" ] || die "remove takes exactly one mount"; want="$1"; shift ;;
    esac
  done
  [ -n "$want" ] || die "remove: which mount? (see: list)"
  want="${want%/}"
  mdir=$(find_mount "$want") || die "no mount named or at $want (see: list)"
  rec="$mdir/record"
  name=$(record_get "$rec" name); guest=$(record_get "$rec" guest)
  mode=$(record_get "$rec" mode); point=$(record_get "$rec" point)
  fixed=$(record_get "$rec" fixed); copy=$(record_get "$rec" copy)
  track=$(record_get "$rec" track); upper=$(record_get "$rec" upper)

  if [ "$fixed" = "1" ]; then
    err "$guest is bound outside every dock (fixed at launch) and cannot be detached live"
    hint "it stays until the session ends"
    exit 1
  fi

  # Whatever the jail wrote into a copy or an overlay would vanish with the
  # mount, so the sync-back review comes first, with the same helper and the
  # same prompts the exit trap uses - restricted to this one tree.
  if [ -n "$copy" ] || [ -n "$upper" ]; then
    if [ "$sync_mode" = "discard" ]; then
      warn "discarding unsynced changes in $guest, as asked"
    else
      for g in "${SYNC_EXCLUDES[@]+"${SYNC_EXCLUDES[@]}"}"; do excl+=(--exclude "$g"); done
      if [ -n "$copy" ]; then
        printf 'copy\t%s\t%s\t%s\t%s\n' "$copy" "$track" "$(record_get "$rec" host)" "mount $guest" > "$mdir/manifest-one"
      else
        printf 'overlay\t%s\t-\t%s\t%s\n' "$upper" "$(record_get "$rec" host)" "overlay mount $guest" > "$mdir/manifest-one"
      fi
      "$SYNC_BACK" "--$sync_mode" "${excl[@]+"${excl[@]}"}" "$mdir/manifest-one" || true
    fi
    manifest_drop "${copy:-$upper}"
  fi

  # Plain umount first, so a clean detach stays quiet. It fails with EBUSY
  # when anything in the jail still has the tree open (a shell sitting in
  # it is enough), because the propagated copy counts as a user of the
  # holder's mount; the lazy fallback detaches the whole propagation tree
  # and leaves that process with a dangling cwd, which is the documented
  # cost of unmounting under it.
  if ! holder umount -R "$point" 2>/dev/null; then
    if holder umount -l "$point"; then
      warn "$guest was busy inside the jail - detached lazily, a process still in it keeps a dangling cwd"
    else
      die "umount of $guest failed"
    fi
  fi
  if [ -d "$point" ]; then rmdir "$point" 2>/dev/null || true; else rm -f "$point"; fi
  rm -rf "$mdir"
  log "unmounted $guest ($name, mode $mode)"
}

cmd_list() {
  local dir rec name guest mode host fixed found=0 n
  for dir in "$MOUNTS_DIR"/*/; do
    rec="$dir/record"
    [ -r "$rec" ] || continue
    found=1
    name=$(record_get "$rec" name); guest=$(record_get "$rec" guest)
    mode=$(record_get "$rec" mode); host=$(record_get "$rec" host)
    fixed=$(record_get "$rec" fixed)
    case "$mode" in
      full)    mode="${C_RED}full${C_RESET}" ;;
      overlay) mode="${C_YELLOW}overlay${C_RESET}" ;;
      *)       mode="${C_GREEN}$mode${C_RESET}" ;;
    esac
    n=""
    if [ -n "$(record_get "$rec" copy)" ] && command -v git >/dev/null 2>&1; then
      n=$(GIT_DIR="$(record_get "$rec" track)" GIT_WORK_TREE="$(record_get "$rec" copy)" \
            git --no-optional-locks status --porcelain --untracked-files=all 2>/dev/null | wc -l) || n=""
      if [ "${n:-0}" = "0" ]; then n=""; else n=", $n unsynced"; fi
    fi
    printf '%s%-18s%s %s  %s %s<- %s%s%s\n' \
      "$C_BOLD" "$name" "$C_RESET" "$mode" "$guest" "$C_DIM" "$host" "$([ "$fixed" = "1" ] && printf ', fixed')$n" "$C_RESET"
  done
  [ "$found" = "1" ] || log "no extra mounts in this session"
}

cmd_docks() {
  local i
  for i in "${!DOCK_GUESTS[@]}"; do
    printf '%s\n' "${DOCK_GUESTS[$i]}"
  done
}

case "${1:-}" in
  add|mount)        shift; cmd_add "$@" ;;
  remove|rm|umount) shift; cmd_remove "$@" ;;
  list|ls)          cmd_list ;;
  docks)            cmd_docks ;;
  ""|-h|--help)     usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
