# `llm-custody-toolbox`: add packages to the profile a running (or future)
# jail sees on its PATH.
#
# The jail cannot install anything itself - read-only /nix/store, no binary
# cache in the domain whitelist - so this is the host-side half of that: it
# realizes a derivation where realizing one is possible, and retargets the
# `current` symlink the sandbox resolves through. The bind is live, so a
# package added here lands on the PATH of a session that is already running.
#
# Deliberately host-side only, like llm-custody-sync: the jailed agent asks
# for a package in its reply and the operator decides, rather than the agent
# pulling arbitrary nixpkgs attributes into its own PATH.
{ pkgs }:
let
  toolbox = import ./toolbox.nix;
in
pkgs.writeShellApplication {
  name = "llm-custody-toolbox";
  # `nix` is deliberately absent: the host's own nix (possibly Lix) is the one
  # that owns /nix/var/nix and matches the running daemon, and
  # writeShellApplication prepends to PATH rather than replacing it, so the
  # host binary is what `command -v nix` finds.
  runtimeInputs = [
    pkgs.coreutils
    # flock: one toolbox is shared by every jail under the same --state-dir,
    # so two sessions can be provisioned at the same time.
    pkgs.util-linux
  ];
  text = ''
    set -euo pipefail

    # Same fallback chain the runner uses when it registers a session, so both
    # sides agree on the directory on hosts without XDG_RUNTIME_DIR.
    REG_DIR="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}/llm-custody"
    DEFAULT_DIR="''${LLMCUSTODY_TOOLBOX_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/llm-custody/toolbox}"
    # Overridable so a host pinned to a specific nixpkgs can provision from it
    # instead of whatever the flake registry currently resolves to.
    FLAKE="''${LLMCUSTODY_TOOLBOX_FLAKE:-nixpkgs}"

    DIR=""
    PAUSE=0

    usage() {
      printf 'Usage: llm-custody-toolbox [--dir PATH] [--pause] <add|rm|list|gc> [ARG...]\n'
      printf '\n'
      printf '  add PKG...   install nixpkgs attributes into the toolbox profile\n'
      printf '  rm PKG...    remove them again\n'
      printf '  list         show what is installed\n'
      printf '  gc           drop the profile generations every add leaves\n'
      printf '               behind, so a garbage collection can reclaim them\n'
      printf '               [--older-than PERIOD] keep anything newer (e.g. 30d)\n'
      printf '               [--dry-run] report without deleting\n'
      printf '  (no args)    prompt for packages to add\n'
      printf '  --pause      wait for a keypress before exiting, so a pane a\n'
      printf '               terminal keybinding spawned does not close over\n'
      printf '               the output\n'
      printf '\n'
      printf 'A bare name is resolved against %s; anything containing\n' "$FLAKE"
      printf '# or : is passed to nix verbatim as a flake reference.\n'
      printf '\n'
      printf 'The whole request block an agent printed can be pasted as-is:\n'
      printf '  llm-custody-toolbox add required packages: lua5_4, shellcheck\n'
      printf '\n'
      printf 'Without --dir: the toolbox of the most recently started session\n'
      printf '(%s/current.toolbox), else %s.\n' "$REG_DIR" "$DEFAULT_DIR"
      exit 0
    }

    die() { printf 'llm-custody-toolbox: %s\n' "$*" >&2; exit 1; }

    # The live session's toolbox first: with --state-dir in play it is not
    # necessarily the default one, and the operator answering an agent's
    # request should not have to remember which.
    resolve_dir() {
      [ -n "$DIR" ] && return 0
      if [ -L "$REG_DIR/current.toolbox" ]; then
        DIR=$(readlink -f "$REG_DIR/current.toolbox" 2>/dev/null || true)
        [ -n "$DIR" ] && return 0
      fi
      DIR="$DEFAULT_DIR"
    }

    # Agents are asked (see lib/toolbox.nix) to print their request as
    # `required packages: a, b`, so accept that shape verbatim - the operator
    # pastes the line instead of retyping the names out of it. Commas are
    # separators in that format and never part of an attribute name.
    normalize_pkgs() {
      local word w out=() words=()
      for word in "$@"; do
        # read -ra rather than an unquoted expansion: same word splitting,
        # without a glob in a pasted line expanding against the cwd.
        read -r -a words <<< "''${word//,/ }"
        for w in "''${words[@]+"''${words[@]}"}"; do
          case "$w" in
            required|required:|good-to-have|good-to-have:|packages|packages:) continue ;;
          esac
          out+=("$w")
        done
      done
      printf '%s\n' "''${out[@]+"''${out[@]}"}"
    }

    to_ref() {
      case "$1" in
        *"#"*|*:*|/*|.|./*) printf '%s' "$1" ;;
        *) printf '%s#%s' "$FLAKE" "$1" ;;
      esac
    }

    # Names currently on the jail's PATH through the toolbox, as a
    # space-delimited string for a `case` membership test. Used to report what
    # an install actually made available: the operator asks for a package, the
    # agent asked for a command, and the two rarely have the same name.
    snapshot_bins() {
      local f base names=""
      for f in "$DIR/${toolbox.currentLink}/bin"/*; do
        [ -e "$f" ] || continue
        base="''${f##*/}"
        names="$names$base "
      done
      # Leading space as well as the trailing one each name carries, so a
      # `case "$names" in *" $x "*)` membership test matches the first entry
      # too.
      printf '%s' " $names"
    }

    # nix writes `profile -> profile-N-link`; `current` short-circuits that to
    # the resolved store path, which is the only form that resolves on both
    # sides of the sandbox bind. Must be refreshed after every generation
    # change, which is what makes the new package visible to a running jail.
    #
    # Written with `nix-store --indirect --add-root` rather than `ln -sfn`
    # because that also registers the link under /nix/var/nix/gcroots/auto: a
    # profile outside /nix/var/nix/profiles is not automatically a GC root, so
    # a `nix-collect-garbage` between sessions could otherwise take the whole
    # toolbox with it. Falls back to a plain symlink - a toolbox that works
    # until the next GC beats one that failed to install.
    refresh_current() {
      local real
      [ -L "$DIR/${toolbox.profileLink}" ] || return 0
      real=$(readlink -f "$DIR/${toolbox.profileLink}" 2>/dev/null) || return 0
      case "$real" in
        /nix/store/*) ;;
        *) die "toolbox profile resolves to $real, outside /nix/store - a jail would not see it" ;;
      esac
      if ! nix-store --indirect --add-root "$DIR/${toolbox.currentLink}" \
             --realise "$real" >/dev/null 2>&1; then
        printf 'llm-custody-toolbox: could not register a GC root, falling back to a plain symlink\n' >&2
        ln -sfn "$real" "$DIR/${toolbox.currentLink}"
      fi
    }

    # One toolbox serves every jail under the same --state-dir, so two sessions
    # can be provisioned at the same time. nix locks the profile for its own
    # generation switch, but `current` is retargeted *after* that lock is
    # released: without this, two interleaved adds can leave `current` on the
    # older generation and the second package missing from every jail's PATH
    # until the next add. gc takes it too - a wipe racing an add would be
    # deleting generations the other side is still creating.
    #
    # Lives inside $DIR, which the mkdir just guaranteed is writable; it is
    # bound into the sandbox as an empty file, same as the symlinks beside it.
    take_lock() {
      mkdir -p "$DIR"
      exec 9>"$DIR/.lock"
      flock 9
    }

    # Generations nix has accumulated in the toolbox, counted for gc's report.
    # Tested with -L, not -e: a generation whose store path a garbage
    # collection already took is a dangling symlink, which -e rejects, and it
    # is exactly one of the links gc exists to clean up.
    count_generations() {
      local f n=0
      for f in "$DIR/${toolbox.profileLink}"-*-link; do
        if [ -L "$f" ]; then n=$((n + 1)); fi
      done
      printf '%s' "$n"
    }

    nix_profile() {
      command -v nix >/dev/null 2>&1 || die "no nix on PATH - this is the host-side half of the toolbox"
      # Spelled out rather than relying on the host's nix.conf: a host with
      # neither feature enabled would otherwise fail with nix's own error
      # about an experimental feature, which reads like a bug in this tool.
      nix --extra-experimental-features "nix-command flakes" profile "$@"
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        -h|--help) usage ;;
        --dir) [ $# -ge 2 ] || die "--dir needs an argument"; DIR="$2"; shift 2 ;;
        --pause) PAUSE=1; shift ;;
        *) break ;;
      esac
    done

    # A keybinding-spawned pane dies with the process, taking the nix build
    # log and the list of new commands with it. The trap rather than a line
    # at the end so a failed install - the case actually worth reading - is
    # held open too.
    if [ "$PAUSE" = "1" ]; then
      trap 'printf "\n[enter to close] " >&2; read -r _ || true' EXIT
    fi

    CMD="''${1:-}"
    [ $# -gt 0 ] && shift

    resolve_dir

    case "$CMD" in
      list|ls)
        [ -d "$DIR" ] || die "no toolbox at $DIR yet"
        nix_profile list --profile "$DIR/${toolbox.profileLink}"
        exit 0 ;;
      gc)
        # Every add switches the profile to a new generation and leaves the
        # old one behind as a profile-N-link symlink. Those links are what
        # make the toolbox grow without bound: a profile outside
        # /nix/var/nix/profiles gets no automatic generation cleanup, and
        # `nix-collect-garbage -d` does not know about this one.
        [ -d "$DIR" ] || die "no toolbox at $DIR yet"
        GC_ARGS=()
        while [ $# -gt 0 ]; do
          case "$1" in
            --older-than)
              [ $# -ge 2 ] || die "--older-than needs a period, e.g. 30d"
              GC_ARGS+=(--older-than "$2"); shift 2 ;;
            --dry-run) GC_ARGS+=(--dry-run); shift ;;
            *) die "gc: unknown option: $1 (try --help)" ;;
          esac
        done
        take_lock
        BEFORE=$(count_generations)
        nix_profile wipe-history --profile "$DIR/${toolbox.profileLink}" \
          "''${GC_ARGS[@]+"''${GC_ARGS[@]}"}"
        # The current generation keeps its number, so `current` still resolves
        # - refreshed anyway because the GC root it carries is the one thing
        # that must never be left pointing at something wipe-history dropped.
        refresh_current
        AFTER=$(count_generations)
        printf 'llm-custody-toolbox: %s generation(s) dropped, %s kept\n' \
          "$((BEFORE - AFTER))" "$AFTER" >&2
        # Said plainly because the obvious next question is why the store did
        # not shrink: this only unpins, it frees nothing on its own.
        printf 'llm-custody-toolbox: store paths are only unpinned - run nix-collect-garbage to reclaim them\n' >&2
        exit 0 ;;
      add|install|i) ;;
      rm|remove) ;;
      "")
        # Interactive path, which is what a terminal keybinding spawns: one
        # prompt, one line, same paste-the-request-block handling as the
        # argument form.
        [ -t 0 ] || usage
        printf 'package(s) to add to %s: ' "$DIR" >&2
        IFS= read -r REPLY_LINE || exit 1
        [ -n "''${REPLY_LINE// /}" ] || die "nothing to add"
        CMD=add
        # One argument on purpose - normalize_pkgs below does the splitting,
        # and it has to handle a pasted `required packages: a, b` anyway.
        set -- "$REPLY_LINE" ;;
      *) die "unknown command: $CMD (try --help)" ;;
    esac

    [ $# -gt 0 ] || die "$CMD needs at least one package"

    PKGS=()
    while IFS= read -r p; do
      [ -n "$p" ] && PKGS+=("$p")
    done < <(normalize_pkgs "$@")
    [ "''${#PKGS[@]}" -gt 0 ] || die "no package names in: $*"

    take_lock

    if [ "$CMD" = "add" ]; then
      BEFORE=$(snapshot_bins)
      REFS=()
      for p in "''${PKGS[@]}"; do
        REFS+=("$(to_ref "$p")")
      done
      printf 'llm-custody-toolbox: installing %s\n' "''${REFS[*]}" >&2
      nix_profile install --profile "$DIR/${toolbox.profileLink}" "''${REFS[@]}"
      refresh_current

      # What the jail gained, by name. A running session picks these up
      # without a restart - the toolbox bind resolves through `current`, which
      # refresh_current just retargeted.
      NEW=()
      for f in "$DIR/${toolbox.currentLink}/bin"/*; do
        [ -e "$f" ] || continue
        base="''${f##*/}"
        case "$BEFORE" in
          *" $base "*) ;;
          *) NEW+=("$base") ;;
        esac
      done
      if [ "''${#NEW[@]}" -gt 0 ]; then
        printf 'llm-custody-toolbox: now on the jail PATH: %s\n' "''${NEW[*]}" >&2
      else
        printf 'llm-custody-toolbox: no new commands (already present, or the package ships no bin/)\n' >&2
      fi
    else
      nix_profile remove --profile "$DIR/${toolbox.profileLink}" "''${PKGS[@]}"
      refresh_current
    fi
  '';
}
