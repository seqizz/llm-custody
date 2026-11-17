# The --dry-run report sections printed after the session card: the mask
# matches of every tree and a grouped summary of the bwrap arguments.
# Runner-only, interpolated into lib/mkBwrapRunner.nix (no Nix
# interpolation in here); reads the runner's resolved state at call time
# (MASK_PATTERNS, GIT_MODE, WORKSPACE_HOST, the DRY_MOUNT_* arrays,
# BWRAP_ARGS, RUNDIR, SKILLS_GUEST_DIR) plus the log helpers.

# Masks of the workspace and every extra mount, resolved against the host
# trees. Nothing is copied or bound for a dry run, but a copy is the host
# tree minus .git, so the host-side matches are exactly what a launch would
# delete or shadow.
dry_mask_report() {
  local i host mode what
  [ "${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
  dry_mask_tree "$WORKSPACE_HOST" "workspace $WORKSPACE_HOST" "$GIT_MODE"
  for i in "${!DRY_MOUNT_HOSTS[@]}"; do
    host="${DRY_MOUNT_HOSTS[$i]}"
    mode="${DRY_MOUNT_MODES[$i]}"
    what="mount ${DRY_MOUNT_GUESTS[$i]}"
    if [ ! -d "$host" ]; then
      log "--mask: $what is a single file, masks do not apply to it"
      continue
    fi
    dry_mask_tree "$host" "$what" "$mode"
  done
}

dry_mask_tree() {
  local host="$1" label="$2" mode="$3"
  jail_mask_collect "$host"
  case "$mode" in
    limited|none) jail_mask_report "$label" "to delete from the copy" always ;;
    *)
      jail_mask_report "$label" "to shadow with empty binds" always
      if [ "${#MASK_HIT_PATH[@]}" -gt 0 ] && [ -d "$host/.git" ]; then
        hint "bound with its .git: masked content stays readable as git blobs"
      fi
      ;;
  esac
}

# Terminal width for packing rows, from stderr since that is where the
# report goes. 100 when stderr is not a terminal.
dry_cols() {
  local size cols=""
  # stty reports "ROWS COLS" for the terminal on its stdin.
  if size=$(stty size <&2 2>/dev/null); then
    cols="${size##* }"
  fi
  case "$cols" in
    ''|*[!0-9]*) cols=100 ;;
  esac
  printf '%s' "$cols"
}

# The runtime dir and the home dir are the prefixes that make most bind
# lines long; the summary header prints both once.
dry_short() {
  local p="$1"
  case "$p" in
    "$RUNDIR"|"$RUNDIR"/*) p="\$RUNDIR${p#"$RUNDIR"}" ;;
    "$HOME"|"$HOME"/*) p="~${p#"$HOME"}" ;;
  esac
  printf '%s' "$p"
}

dry_row() {
  hint "$(printf '%-9s %s' "$1" "$2")"
}

# One labelled row per terminal line: ITEMS are joined with SEP and
# wrapped at the terminal width, the label only on the first line.
dry_pack() {
  local label="$1" sep="$2" width line="" item
  shift 2
  # 12 columns of hint indent plus the 10-column label.
  width=$(( DRY_COLS - 22 ))
  [ "$width" -ge 30 ] || width=30
  for item in "$@"; do
    if [ -n "$line" ] && [ $(( ${#line} + ${#sep} + ${#item} )) -gt "$width" ]; then
      dry_row "$label" "$line"
      label=""
      line="$item"
    else
      line="${line:+$line$sep}$item"
    fi
  done
  [ -z "$line" ] || dry_row "$label" "$line"
}

# Fold paths that share a parent into dir/{a,b}, keeping first-seen order.
# The root is never folded: /{bin,nix} reads worse than the two paths.
# Result in DRY_FOLDED.
dry_fold_paths() {
  local i j n dir names
  local -a paths=("$@") dirs=() used=()
  DRY_FOLDED=()
  for i in "${!paths[@]}"; do dirs+=("$(dirname -- "${paths[$i]}")"); done
  for i in "${!paths[@]}"; do
    [ -z "${used[$i]:-}" ] || continue
    dir="${dirs[$i]}"
    names="$(basename -- "${paths[$i]}")"
    n=1
    if [ "$dir" != "/" ]; then
      for j in "${!paths[@]}"; do
        if [ "$j" -gt "$i" ] && [ -z "${used[$j]:-}" ] && [ "${dirs[$j]}" = "$dir" ]; then
          names="$names,$(basename -- "${paths[$j]}")"
          used[j]=1
          n=$((n+1))
        fi
      done
    fi
    if [ "$n" -gt 1 ]; then
      DRY_FOLDED+=("$(dry_short "$dir")/{$names}")
    else
      DRY_FOLDED+=("$(dry_short "${paths[$i]}")")
    fi
  done
}

# Fold variables with the same value and the same prefix up to the first
# underscore into PREFIX_{A,B}=VALUE, keeping first-seen order. Values with
# whitespace or shell metacharacters are printed %q-quoted. Reads the
# env_k/env_v arrays of its caller, dry_bwrap_summary; result in
# DRY_FOLDED.
dry_fold_env() {
  local i j prefix rest val
  local -a used=()
  DRY_FOLDED=()
  for i in "${!env_k[@]}"; do
    [ -z "${used[$i]:-}" ] || continue
    val="${env_v[$i]}"
    if [[ "$val" =~ [^A-Za-z0-9_./:,=+@%-] ]]; then val=$(printf '%q' "$val"); fi
    rest=""
    if [[ "${env_k[$i]}" == *_* ]]; then
      prefix="${env_k[$i]%%_*}_"
      for j in "${!env_k[@]}"; do
        if [ "$j" -gt "$i" ] && [ -z "${used[$j]:-}" ] &&
           [ "${env_v[$j]}" = "${env_v[$i]}" ] && [[ "${env_k[$j]}" == "$prefix"* ]]; then
          rest="$rest,${env_k[$j]#"$prefix"}"
          used[j]=1
        fi
      done
    fi
    if [ -n "$rest" ]; then
      DRY_FOLDED+=("$prefix{${env_k[$i]#"$prefix"}$rest}=$val")
    else
      DRY_FOLDED+=("${env_k[$i]}=$val")
    fi
  done
}

# BWRAP_ARGS grouped by what each argument does. Grouping loses argument
# order, and order decides which bind shadows which, so -vv prints the raw
# list as well. An option this does not know lands in the "other" row with
# no operands, which shifts the rest of the parse; the raw list is the
# reference when that row is not empty.
dry_bwrap_summary() {
  local i=0 n="${#BWRAP_ARGS[@]}" a b c d k skills_rw=0 skills_ro=0 masks=0
  local cwd="" path_val="" sec=""
  local -a unshare=() flags=() fs=() remount=() unset_vars=() other=() overlay=()
  local -a b_kind=() b_src=() b_dst=() env_k=() env_v=()
  local -a ro_same=() rw_same=() ro_lines=() rw_lines=() docks=() skill_dirs=()

  DRY_COLS=$(dry_cols)

  while [ "$i" -lt "$n" ]; do
    a="${BWRAP_ARGS[$i]}"
    b="${BWRAP_ARGS[$((i+1))]:-}"
    c="${BWRAP_ARGS[$((i+2))]:-}"
    case "$a" in
      --unshare-cgroup-try) unshare+=("cgroup(try)"); i=$((i+1)) ;;
      --unshare-*) unshare+=("${a#--unshare-}"); i=$((i+1)) ;;
      --disable-userns) flags+=("no nested userns"); i=$((i+1)) ;;
      --share-net|--die-with-parent|--new-session|--as-pid-1|--clearenv|--assert-userns-disabled)
        flags+=("${a#--}"); i=$((i+1)) ;;
      --cap-drop|--cap-add) sec="$sec, ${a#--} $b"; i=$((i+2)) ;;
      --seccomp|--add-seccomp-fd) sec="$sec, seccomp fd $b"; i=$((i+2)) ;;
      --proc|--dev|--tmpfs|--mqueue|--dir) fs+=("${a#--} $(dry_short "$b")"); i=$((i+2)) ;;
      --remount-ro) remount+=("$b"); i=$((i+2)) ;;
      --chdir) cwd="$b"; i=$((i+2)) ;;
      --unsetenv) unset_vars+=("$b"); i=$((i+2)) ;;
      --setenv)
        if [ "$b" = "PATH" ]; then path_val="$c"; else env_k+=("$b"); env_v+=("$c"); fi
        i=$((i+3)) ;;
      --ro-bind|--ro-bind-try|--bind|--bind-try|--dev-bind|--dev-bind-try)
        case "$a" in
          --ro-bind*) b_kind+=("ro") ;;
          *) b_kind+=("rw") ;;
        esac
        # -try binds are skipped by bwrap when the source is missing.
        case "$a" in
          *-try) b_src+=("$b?") ;;
          *) b_src+=("$b") ;;
        esac
        b_dst+=("$c")
        i=$((i+3)) ;;
      --overlay-src) overlay+=("lower $(dry_short "$b")"); i=$((i+2)) ;;
      --overlay)
        d="${BWRAP_ARGS[$((i+3))]:-}"
        overlay+=("upper $(dry_short "$b") -> $d"); i=$((i+4)) ;;
      --tmp-overlay|--ro-overlay) overlay+=("${a#--} -> $b"); i=$((i+2)) ;;
      --symlink|--chmod|--file|--bind-data|--ro-bind-data)
        other+=("$a $(dry_short "$b") $c"); i=$((i+3)) ;;
      --perms|--size|--uid|--gid|--hostname|--userns|--userns2|--pidns|--info-fd|--sync-fd|--block-fd|--userns-block-fd|--json-status-fd|--lock-file|--argv0|--exec-label|--file-label)
        other+=("$a $b"); i=$((i+2)) ;;
      *) other+=("$a"); i=$((i+1)) ;;
    esac
  done

  for k in "${!b_dst[@]}"; do
    a="${b_src[$k]}"
    b="${b_dst[$k]}"
    case "$b" in
      "$SKILLS_GUEST_DIR"/*)
        if [ "${b_kind[$k]}" = "rw" ]; then skills_rw=$((skills_rw+1)); else skills_ro=$((skills_ro+1)); fi
        skill_dirs+=("$(dirname -- "$a")")
        continue ;;
    esac
    case "$a" in
      "$RUNDIR"/masks/*) masks=$((masks+1)); continue ;;
    esac
    if [ "${b_kind[$k]}" = "rw" ] && [[ " ${remount[*]} " == *" $b "* ]]; then
      docks+=("$b")
    elif [ "$a" = "$b" ]; then
      if [ "${b_kind[$k]}" = "ro" ]; then ro_same+=("$a"); else rw_same+=("$a"); fi
    elif [ "${b_kind[$k]}" = "ro" ]; then
      ro_lines+=("$(dry_short "$a") -> $b")
    else
      rw_lines+=("$(dry_short "$a") -> $b")
    fi
  done

  d="${unshare[*]}"
  for a in "${flags[@]}"; do d="${d:+$d, }$a"; done
  [ -z "$d" ] || dry_row isolate "$d"
  [ -z "$sec" ] || dry_row security "${sec#, }"
  [ "${#fs[@]}" -eq 0 ] || dry_pack fs ", " "${fs[@]}"

  if [ "${#ro_same[@]}" -gt 0 ]; then
    dry_fold_paths "${ro_same[@]}"
    dry_pack ro " " "${DRY_FOLDED[@]}"
    a=""
  else
    a=ro
  fi
  for d in "${ro_lines[@]}"; do dry_row "$a" "$d"; a=""; done
  if [ "${#rw_same[@]}" -gt 0 ]; then
    dry_fold_paths "${rw_same[@]}"
    dry_pack rw " " "${DRY_FOLDED[@]}"
    a=""
  else
    a=rw
  fi
  for d in "${rw_lines[@]}"; do dry_row "$a" "$d"; a=""; done
  [ "${#docks[@]}" -eq 0 ] || dry_row docks "${docks[*]} (ro, live mounts attach inside)"
  a=overlay
  for d in "${overlay[@]}"; do dry_row "$a" "$d"; a=""; done
  [ "$masks" -eq 0 ] || dry_row masks "$masks empty ro bind(s) over --mask matches"

  if [ $((skills_rw + skills_ro)) -gt 0 ]; then
    if [ "$skills_ro" -eq 0 ]; then
      a="$skills_rw rw"
    elif [ "$skills_rw" -eq 0 ]; then
      a="$skills_ro ro"
    else
      a="$skills_ro ro, $skills_rw rw"
    fi
    dry_row skills "$a from $(dry_skill_sources "${skill_dirs[@]}")"
  fi

  if [ "${#env_k[@]}" -gt 0 ]; then
    dry_fold_env
    dry_pack env "  " "${DRY_FOLDED[@]}"
  fi
  [ -z "$path_val" ] || dry_row "" "PATH=$path_val"
  [ "${#unset_vars[@]}" -eq 0 ] || dry_pack unset " " "${unset_vars[@]}"
  [ -z "$cwd" ] || dry_row cwd "$cwd"
  [ "${#other[@]}" -eq 0 ] || dry_pack other "  " "${other[@]}"
}

# Where the skill binds come from: their source dirs with a count each,
# under a common parent when they share one (the usual case, one checkout
# per skill repo in the skillissue cache).
dry_skill_sources() {
  local d parent="" same=1 out=""
  local -a groups=() counts=()
  local i found
  for d in "$@"; do
    found=""
    for i in "${!groups[@]}"; do
      if [ "${groups[$i]}" = "$d" ]; then counts[i]=$((counts[i]+1)); found=1; break; fi
    done
    [ -n "$found" ] || { groups+=("$d"); counts+=(1); }
  done
  if [ "${#groups[@]}" -eq 1 ]; then
    dry_short "${groups[0]}"
    return 0
  fi
  for d in "${groups[@]}"; do
    if [ -z "$parent" ]; then parent="$(dirname -- "$d")"
    elif [ "$(dirname -- "$d")" != "$parent" ]; then same=0
    fi
  done
  for i in "${!groups[@]}"; do
    if [ "$same" = "1" ]; then
      out="$out, $(basename -- "${groups[$i]}"): ${counts[$i]}"
    else
      out="$out, $(dry_short "${groups[$i]}"): ${counts[$i]}"
    fi
  done
  if [ "$same" = "1" ]; then
    printf '%s (%s)' "$(dry_short "$parent")" "${out#, }"
  else
    printf '%s' "${out#, }"
  fi
}
