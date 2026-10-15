# bwrap + private-netns host launcher, replacing lib/mkRunner.nix's QEMU
# launcher. Generalizes prototypes/bwrap-pi.sh (proven end-to-end: real
# netns/slirp4netns/dnsmasq/nftables/bwrap/seccomp chain, interactively
# tested with a live TUI session) so it's data-driven from tools.nix instead
# of hardcoding one tool's values.
{
  pkgs,
  name,
  toolDefaults,
  launcherOut,
}:

let
  seccompDenylist = import ./seccomp-denylist.nix { inherit pkgs; };
  toolExe = pkgs.lib.getExe launcherOut.toolPackage;
  # Selftest probe derivation (lib/selftest.nix): a standalone store file
  # the --selftest branch binds as /selftest.sh. Kept out of this runner's
  # text because its $()/$var fragments would trip the
  # writeShellApplication's shellcheck pass (SC2016) as quoted literals -
  # the previous inline version failed the build on exactly that. The probe
  # itself contains no Nix interpolation; everything it needs arrives as
  # SELFTEST_* env vars set in the selftest branch.
  selftestProbe = import ./selftest.nix { inherit pkgs; };
  # Sync-back (lib/sync-back.sh): one implementation for the exit trap and
  # for the mid-session $RUNDIR/sync command the operator can run from
  # another terminal.
  syncBack = pkgs.lib.getExe (import ./sync-back.nix { inherit pkgs; });
  selftestDomain = builtins.head toolDefaults.allowedDomains;
  selftestUnshare = "${pkgs.util-linux}/bin/unshare";
  # Optional per-tool data: a tool with no dangerous-mode CLI flag (pi) just
  # omits it and --dangerous then errors out instead of passing something
  # the tool would reject.
  dangerousFlag = toolDefaults.dangerousFlag or "";
  # Fixed env the tool itself needs (launchers/<tool>.nix extraEnv), e.g.
  # telemetry/autoupdate switches. Emitted as bwrap --setenv args ahead of
  # the user's --env pairs so those still take precedence.
  extraEnvArgs = pkgs.lib.concatStringsSep "\n      " (
    pkgs.lib.mapAttrsToList (k: v: "--setenv ${k} ${pkgs.lib.escapeShellArg v}") (
      launcherOut.extraEnv or { }
    )
  );
in
pkgs.writeShellApplication {
  name = "llm-custody-${name}";
  runtimeInputs = [
    pkgs.bubblewrap
    pkgs.slirp4netns
    pkgs.dnsmasq
    pkgs.nftables
    pkgs.iproute2
    pkgs.util-linux
    pkgs.coreutils
    pkgs.jq
    pkgs.gnugrep
  ];
  text = ''
    set -euo pipefail

    ALLOWED_DOMAINS=(
      ${builtins.concatStringsSep "\n      " (map (d: "\"${d}\"") toolDefaults.allowedDomains)}
    )

    PROFILE="''${LLMCUSTODY_PROFILE:-default}"
    STATE_ROOT="''${LLMCUSTODY_STATE_DIR:-}"
    SAME_PATH=0
    NET_FILTER=1
    LLMCUSTODY_TMPDIR="''${TMPDIR:-/tmp}"
    EXTRA_DOMAINS=()
    EXTRA_MOUNTS=()
    MASK_PATTERNS=()
    ENV_PAIRS=()
    TOOL_ARGS=()
    OVERLAY=0
    GIT_MODE="limited"
    SELFTEST=0
    MERGE_CONFIG=0
    MERGE_CONFIG_SRC=""
    RESUME_MODE=""
    RESUME_ARG=""
    RW_SKILLS=0
    DANGEROUS=0
    X11=0
    DANGEROUS_FLAG="${dangerousFlag}"
    # Root-level settings.json keys --merge-config never offers, because the
    # bootstrapScript owns them (tools.nix mergeSkipKeys).
    MERGE_SKIP_KEYS=(
      ${builtins.concatStringsSep "\n      " (map (k: "\"${k}\"") (toolDefaults.mergeSkipKeys or [ ]))}
    )
    # Per-tool session-resume translation (tools.nix resumeFlags):
    # -c/--continue -> CONTINUE_FLAG, -r/--resume -> RESUME_FLAG (picker),
    # and --resume <id> -> RESUME_WITH_ID_FLAG.
    CONTINUE_FLAG="${toolDefaults.resumeFlags.continue}"
    RESUME_FLAG="${toolDefaults.resumeFlags.resume}"
    RESUME_WITH_ID_FLAG="${toolDefaults.resumeFlags.resumeWithId}"

    usage() {
      cat <<'USAGE'
    Usage: llm-custody-${name} [options] [-- tool-args...]

    Options:
      --profile NAME        State profile, a subdir of --state-dir/${name} (default: default)
      --state-dir PATH      Jail state root dir (default: ~/.config/llm-custody)
      --same-path           Mount workspace and every --mount at their host
                             paths instead of under /workspace (lets tools
                             like 'claude --resume' match sessions started
                             outside the sandbox)
      --tmpdir PATH         Directory to use for runtime data (default: ''${TMPDIR:-/tmp})
      --mount HOSTPATH[:GUESTPATH]
                             Extra read-write mount (repeatable). GUESTPATH
                             defaults to /workspace/<basename HOSTPATH>; a
                             relative GUESTPATH is resolved under /workspace.
                             Colliding targets are an error - give one of them
                             an explicit GUESTPATH.
                             Isolated exactly like the workspace: --git
                             limited/none give the jail a copy that syncs back
                             on exit, --overlay-workspace makes it
                             copy-on-write, --git full binds the real tree.
                             A single file is always bound directly.
      --ro-mount HOSTPATH[:GUESTPATH]
                             Extra read-only mount (repeatable). Same GUESTPATH
                             rules as --mount.
      --allow-domain DOMAIN Add domain to network whitelist (repeatable;
                             persistent ones can live in --state-dir/domains)
      --env KEY=VAL         Pass environment variable into the sandbox (repeatable)
      --x11                 Allow X11/Wayland clipboard access by passing
                             DISPLAY/XAUTHORITY/WAYLAND_DISPLAY and binding
                             the display sockets. Without this, those vars
                             are stripped so the terminal uses OSC 52 instead
      --git MODE            How much of the repo the jail sees (default: limited)
                             limited: copy of the working tree as a fresh repo
                                      with a single baseline commit - no host
                                      history, so masked files can't be read
                                      back out of .git
                             none:    same copy, no repo at all
                             full:    bind the real tree including its .git
                             limited/none sync changes back to the real tree on
                             exit (prompted on a tty, automatic otherwise) -
                             for the workspace and every rw --mount
      --overlay-workspace   Mount the workspace and every rw --mount
                             copy-on-write; edits are shown for review and
                             synced back to the real trees on exit, never
                             without confirmation (needs --git full)
      --selftest            Run a sandbox self-check (full chain incl. netns +
                             seccomp + git wrapper) and exit without launching
                             the tool; no in-jail /login needed
      -c, --continue, -r, --resume [ID]
                             Resume a session; translated to the tool's own
                             resume flags (see tools.nix resumeFlags)
      --dangerous           Skip the tool's own permission prompts (passes its
                             dangerous-mode flag, if it has one)
      --rw-skills           Mount skills read-write (default: read-only). Only
                             for deliberate in-jail skill maintenance - an
                             agent can edit files the host then reads
      --mask GLOB           Hide files/dirs matching GLOB inside the workspace
                             (binds empty file/dir over each match, repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
      --merge-config        Interactively merge root-level keys from the host
                             tool's settings.json into the jail-private
                             settings.json; each differing key prompts y/N
                             individually ('a' accepts the rest)
      --merge-config-from PATH
                             Same as --merge-config with an explicit source
                             file instead of the default host settings.json
      -h, --help            Show this help
    USAGE
      exit 0
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --profile)       PROFILE="$2"; shift 2 ;;
        --state-dir)     STATE_ROOT="$2"; shift 2 ;;
        --same-path)     SAME_PATH=1; shift ;;
        --tmpdir)        LLMCUSTODY_TMPDIR="$2"; shift 2 ;;
        --mount)         EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
        --ro-mount)      EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
        --allow-domain)  EXTRA_DOMAINS+=("$2"); shift 2 ;;
        --env)           ENV_PAIRS+=("$2"); shift 2 ;;
        --overlay-workspace) OVERLAY=1; shift ;;
        --git)
          case "$2" in
            full|limited|none) GIT_MODE="$2" ;;
            *) echo "ERROR: --git expects full|limited|none, got: $2" >&2; exit 1 ;;
          esac
          shift 2 ;;
        --selftest)      SELFTEST=1; shift ;;
        --dangerous)
          if [ -z "$DANGEROUS_FLAG" ]; then
            echo "ERROR: ${name} has no dangerous-mode flag (tools.nix dangerousFlag unset)" >&2
            exit 1
          fi
          DANGEROUS=1; shift ;;
        --rw-skills)     RW_SKILLS=1; shift ;;
        --x11)           X11=1; shift ;;
        --mask)          MASK_PATTERNS+=("$2"); shift 2 ;;
        --no-net-filter) NET_FILTER=0; shift ;;
        --merge-config)      MERGE_CONFIG=1; shift ;;
        --merge-config-from) MERGE_CONFIG=1; MERGE_CONFIG_SRC="$2"; shift 2 ;;
        -c|--continue)   RESUME_MODE="continue"; shift ;;
        -r|--resume)     RESUME_MODE="picker"; shift
          # Optional session id: --resume <id> targets a specific session
          # directly instead of opening the picker. Ids never start with '-'.
          if [ $# -gt 0 ] && [[ "$1" != -* ]]; then RESUME_ARG="$1"; shift; fi ;;
        -h|--help)       usage ;;
        --)              shift; TOOL_ARGS=("$@"); break ;;
        *)               # Anything we don't recognize isn't necessarily
                         # wrong - it may be a tool argument (e.g. pi's -p)
                         # nix run left after consuming its own `--`. Pass it
                         # through; the tool's own parser rejects what it
                         # doesn't know.
                         TOOL_ARGS+=("$1"); shift ;;
      esac
    done

    # /workspace is a container, not the workspace itself: the cwd lands at
    # /workspace/<its basename> and every --mount without an explicit target
    # becomes a sibling under the same root. That keeps the in-jail layout
    # recognizable (a project and its dependencies side by side, each under
    # its own name) instead of scattering extra mounts across host paths
    # that otherwise don't exist inside the sandbox.
    WORKSPACE_ROOT="/workspace"
    WORKSPACE_HOST="$(pwd)"
    WORKSPACE_NAME=$(basename -- "$WORKSPACE_HOST")
    # pwd is / (basename "/" is "/"): no name to nest under, so fall back to
    # the bare root.
    case "$WORKSPACE_NAME" in
      /|.|..) WORKSPACE_GUEST="$WORKSPACE_ROOT" ;;
      *)      WORKSPACE_GUEST="$WORKSPACE_ROOT/$WORKSPACE_NAME" ;;
    esac
    [ "$SAME_PATH" = "1" ] && WORKSPACE_GUEST="$WORKSPACE_HOST"

    # --overlay-workspace only means something for the real tree: --git
    # limited/none already hand the sandbox a copy, with their own
    # review-and-sync-back step at exit.
    if [ "$OVERLAY" = "1" ] && [ "$GIT_MODE" != "full" ]; then
      echo "ERROR: --overlay-workspace needs --git full (limited/none already isolate the host tree)" >&2
      exit 1
    fi

    # Safety net for two ways a jailed agent's git usage could bite the host
    # later: (1) it rewrites core.hooksPath in the still-writable
    # .git/config to point at somewhere it controls - the read-only
    # .git/hooks bind alone doesn't stop that once the host runs plain git
    # here again outside the jail; (2) it just wrecks the working tree
    # (rm -rf, a bad rebase, ...) since /workspace is a direct bind, not a
    # copy-on-write layer. Both are cheap to at least partially cover
    # without changing the live-edit workflow /workspace otherwise gives.
    #
    # Initialized here (before the cleanup trap exists) rather than in the
    # git-specific block below, so `set -u` never sees these unbound if
    # cleanup fires before GIT_SAFETY is otherwise touched.
    GIT_SAFETY=0
    PRE_HOOKSPATH=""
    if [ -d "$WORKSPACE_HOST/.git" ] && command -v git >/dev/null 2>&1; then
      GIT_SAFETY=1
      PRE_HOOKSPATH=$(git -C "$WORKSPACE_HOST" config --get core.hooksPath 2>/dev/null || true)
      # `stash create` only parks a dangling commit object (and prints its
      # hash) - unlike `stash push`/`store` it never touches the working
      # tree or the visible stash list, so it's a free recovery point for
      # tracked-file damage. Doesn't cover untracked files or a plain
      # `rm -rf` of the tree.
      if SNAPSHOT=$(git -C "$WORKSPACE_HOST" stash create 2>/dev/null) && [ -n "$SNAPSHOT" ]; then
        echo "llm-custody: safety snapshot of tracked changes: $SNAPSHOT (git show $SNAPSHOT to inspect, git stash apply $SNAPSHOT to restore)" >&2
      fi
    fi

    # Jail-private tool state, fully separate from the host tool's own
    # config dir - never the host tool's real config.
    if [ -z "$STATE_ROOT" ]; then
      STATE_ROOT="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-custody"
    fi
    STATE_DIR="$STATE_ROOT/${name}/$PROFILE"
    mkdir -p "$STATE_DIR"

    # Persistent per-run additions to the network whitelist: a plain file
    # next to the state dirs (one domain per line, '#' comments allowed).
    # Same effect as --allow-domain, for hosts with their own API endpoints
    # that shouldn't need re-passing on every launch.
    if [ -f "$STATE_ROOT/domains" ]; then
      while IFS= read -r d; do
        case "$d" in ""|\#*) continue ;; esac
        EXTRA_DOMAINS+=("$d")
      done < "$STATE_ROOT/domains"
    fi

    ${launcherOut.bootstrapScript}

    if [ ! -d "$LLMCUSTODY_TMPDIR" ]; then
      echo "ERROR: tmpdir '$LLMCUSTODY_TMPDIR' does not exist" >&2
      exit 1
    fi

    RUNDIR=$(mktemp -d --tmpdir="$LLMCUSTODY_TMPDIR")

    # --merge-config: one-time interactive adoption of host tool config into
    # the jail-private state dir. The bootstrap owns `extensions` and
    # `defaultProjectTrust` (re-injected every launch), so those are skipped;
    # every other root-level key is offered one by one, host value overwriting
    # the jail's. Keys whose jail value already matches are skipped silently,
    # so repeated runs stay quiet unless the host config actually changed -
    # merge once, then only changed keys prompt again.
    if [ "$MERGE_CONFIG" = "1" ]; then
      SRC="''${MERGE_CONFIG_SRC:-$HOME/${toolDefaults.configDirName}/settings.json}"
      TARGET="$STATE_DIR/settings.json"
      if [ ! -r "$SRC" ]; then
        echo "ERROR: --merge-config source not readable: $SRC" >&2
        exit 1
      fi
      if ! jq -e . "$SRC" >/dev/null 2>&1; then
        echo "ERROR: --merge-config source is not valid JSON: $SRC" >&2
        exit 1
      fi
      if [ ! -t 0 ]; then
        echo "ERROR: --merge-config prompts per key on stdin; needs a tty" >&2
        exit 1
      fi
      MERGE_DOC="$RUNDIR/merge.json"
      if [ -f "$TARGET" ]; then
        cp "$TARGET" "$MERGE_DOC"
      else
        echo '{}' > "$MERGE_DOC"
      fi
      MERGE_ALL=0
      MERGED=0
      # ANSI colors for the interactive prompt. NO_COLOR opts out; the
      # prompt already required a tty above, so no further guard is needed.
      C_RESET=$'\033[0m'
      C_KEY=$'\033[1;36m'
      C_BOLD=$'\033[1m'
      [ -n "''${NO_COLOR:-}" ] && { C_RESET=""; C_KEY=""; C_BOLD=""; }
      # Keys arrive on fd 3, not stdin: the loop-level redirect would
      # otherwise hijack fd 0 for the whole loop body, stealing the terminal
      # from the `read -r ans` below (prompts would fire back-to-back with no
      # waiting and key lines consumed as answers). fd 0 stays on the tty.
      while IFS= read -r key <&3; do
        [ -n "$key" ] || continue
        SKIP_KEY=0
        for sk in "''${MERGE_SKIP_KEYS[@]+"''${MERGE_SKIP_KEYS[@]}"}"; do
          [ "$key" = "$sk" ] && SKIP_KEY=1
        done
        [ "$SKIP_KEY" = "1" ] && continue
        # CUR empty when the jail lacks the key entirely (`// empty`); NEW is
        # always JSON since the key came from $SRC's keys[]. Both sides are
        # key-sorted (-S) so semantically equal objects in different key order
        # don't re-prompt: the host file's hand-written order would otherwise
        # diff against the canonical order the target is written in.
        CUR=$(jq -Sc --arg k "$key" '.[$k] // empty' "$MERGE_DOC")
        NEW=$(jq -Sc --arg k "$key" '.[$k] // empty' "$SRC")
        [ "$CUR" = "$NEW" ] && continue
        if [ "$MERGE_ALL" != "1" ]; then
          # Show the value being offered, not just the key name - it is the
          # actual approval target. -r keeps objects/arrays multi-line and
          # prints strings/bools as literal text; each line indented for
          # readability under the prompt header.
          printf 'llm-custody: merge key %s%s%s from %s:\n' "$C_KEY" "$key" "$C_RESET" "$(basename "$SRC")" >&2
          printf '%s\n' "$(jq -r --arg k "$key" '.[$k]' "$SRC")" | while IFS= read -r line; do printf '    %s\n' "$line"; done >&2
          printf '%sAccept this value?%s [y/N/a] ' "$C_BOLD" "$C_RESET" >&2
          # EOF on the tty (Ctrl-D) aborts the whole merge - and the launch -
          # rather than answering 'no' silently; target stays unmodified.
          read -r ans || { echo "llm-custody: --merge-config aborted (no answer)" >&2; exit 1; }
          case "$ans" in
            [yY]|[yY][eE][sS]) ;;
            [aA]|[aA][lL][lL]) MERGE_ALL=1 ;;
            *) continue ;;
          esac
        fi
        VAL=$(jq -c --arg k "$key" '.[$k]' "$SRC")
        jq --arg k "$key" --argjson v "$VAL" '.[$k] = $v' "$MERGE_DOC" > "$MERGE_DOC.tmp"
        mv "$MERGE_DOC.tmp" "$MERGE_DOC"
        MERGED=$((MERGED+1))
      done 3< <(jq -r 'keys[]' "$SRC")
      if [ "$MERGED" -gt 0 ]; then
        jq -S . "$MERGE_DOC" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
        echo "llm-custody: --merge-config: merged $MERGED key(s) into $TARGET" >&2
      else
        echo "llm-custody: --merge-config: nothing changed (jail settings already match)" >&2
      fi
    fi
    # Workspace exposure, filled in by the --git limited/none copy step below.
    # Declared ahead of cleanup() so the trap can run before that step with
    # `set -u` active.
    WORKSPACE_BIND="$WORKSPACE_HOST"
    WORKSPACE_COPY=""
    TRACK_GIT=""
    # Every tree the sandbox sees through a copy or an overlay instead of a
    # direct bind, as manifest lines for the sync-back helper (see
    # lib/sync-back.sh for the format). Filled in by the --git copy step and
    # the extra-mount loop; written out to $SYNC_MANIFEST right before
    # launch, which is also what $RUNDIR/sync and the exit trap consume.
    SYNC_ENTRIES=()
    SYNC_MANIFEST=""
    SYNC_REG=""
    USERVAR_SET=0
    MOUNT_INDEX=0
    # Names the empty bind sources under $RUNDIR/masks. Shared by every tree
    # jail_mask_binds shadows (workspace and extra mounts alike), so it is
    # declared here rather than next to one of its callers.
    MASK_INDEX=0
    # Identity for the commits this runner makes itself (jail baseline, change
    # tracking). The host .gitconfig may have none, or a signing key whose
    # agent isn't reachable here.
    JAIL_GIT_IDENT=(-c user.name=llm-custody -c user.email=llm-custody@localhost -c commit.gpgsign=false)

    HOLDER_PID=""
    SLIRP_PID=""
    DNSMASQ_PID=""
    WATCH_PID=""

    # Publish this run's mid-session sync command as a WezTerm user var, so a
    # keybinding can fire it (pane:get_user_vars().llm_custody_sync) instead
    # of the operator having to catch - and keep - the path printed at
    # launch. Written straight to the terminal device so it never ends up in
    # a redirected stdout, and wrapped in tmux's DCS passthrough when there
    # is a tmux between us and the terminal. Empty value = session gone.
    emit_sync_uservar() {
      local value="$1" b64 seq
      b64=$(printf '%s' "$value" | base64 -w0)
      seq=$(printf '\033]1337;SetUserVar=llm_custody_sync=%s\007' "$b64")
      if [ -n "''${TMUX:-}" ]; then
        # DCS passthrough: ESC P tmux; <payload, every ESC doubled> ESC \.
        # The payload's only ESC is its leading one, hence the single extra
        # \033 ahead of %s. \134 is the closing backslash in octal - a
        # literal one right before the quote reads as a quote escape.
        seq=$(printf '\033Ptmux;\033%s\033\134' "$seq")
      fi
      printf '%s' "$seq" > /dev/tty 2>/dev/null || true
    }

    cleanup() {
      local status=$?
      [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
      [ -n "$DNSMASQ_PID" ] && kill "$DNSMASQ_PID" 2>/dev/null || true
      [ -n "$SLIRP_PID" ] && kill "$SLIRP_PID" 2>/dev/null || true
      [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null || true
      # backstop for the nsenter'd tail/dnsmasq children the PIDs above don't
      # reach directly (they're rooted in the holder's PID namespace, not
      # this shell's process group)
      pkill -f "$RUNDIR" 2>/dev/null || true

      # Fold every isolated tree (the --git limited/none copies and the
      # --overlay-workspace upper layers, workspace and extra rw mounts
      # alike) back into the real host trees. Must run before the
      # `rm -rf $RUNDIR` below, which would otherwise take the copies and
      # upper layers - and every un-synced change - with them.
      #
      # Same helper the operator can run mid-session as $RUNDIR/sync, so
      # both paths review and apply changes identically. Interactive runs
      # confirm per tree; without a tty copies sync automatically (what a
      # direct workspace bind did anyway - a headless `-p "..."` run that
      # silently threw its work away would be worse than the host mutation
      # it avoids) while overlays never do.
      if [ -n "$SYNC_MANIFEST" ] && [ -f "$SYNC_MANIFEST" ]; then
        if [ -t 0 ]; then
          ${syncBack} --prompt "$SYNC_MANIFEST" || true
        else
          ${syncBack} --auto "$SYNC_MANIFEST" || true
        fi
      fi

      # Session is over: drop the mid-session sync handles so nothing points
      # at a $RUNDIR that is about to disappear.
      if [ "$USERVAR_SET" = "1" ]; then
        emit_sync_uservar ""
      fi
      if [ -n "$SYNC_REG" ]; then
        rm -f "$SYNC_REG"
        if [ "$(readlink "$(dirname "$SYNC_REG")/current" 2>/dev/null || true)" = "$RUNDIR/sync" ]; then
          rm -f "$(dirname "$SYNC_REG")/current"
        fi
      fi

      rm -rf "$RUNDIR"

      if [ "$GIT_SAFETY" = "1" ]; then
        POST_HOOKSPATH=$(git -C "$WORKSPACE_HOST" config --get core.hooksPath 2>/dev/null || true)
        if [ "$POST_HOOKSPATH" != "$PRE_HOOKSPATH" ]; then
          echo "llm-custody: WARNING - core.hooksPath in $WORKSPACE_HOST/.git/config changed during this run" >&2
          echo "          (was: [''${PRE_HOOKSPATH:-unset}], now: [''${POST_HOOKSPATH:-unset}])" >&2
          echo "          plain git run outside the jail on this repo will honor whatever it points to now - review before trusting it." >&2
        fi
      fi

      exit "$status"
    }
    trap cleanup EXIT

    # --overlay-workspace preflight. Unprivileged overlayfs needs kernel
    # >= 5.11, and the upper layer's filesystem must support user xattrs
    # (overlay mounted inside a userns runs with `userxattr`) - tmpfs only
    # gained those in 6.6, and --tmpdir defaults to /tmp, which is tmpfs on
    # NixOS. Probe dirs live under $RUNDIR, i.e. on the same filesystem as
    # the real upper/workdir, so the verdict applies to what the run will
    # actually use. Done here rather than at mount-assembly time so the
    # whole netns/slirp/dnsmasq chain isn't brought up just to fail, and
    # after the trap so a failed probe still cleans $RUNDIR up.
    if [ "$OVERLAY" = "1" ]; then
      mkdir -p "$RUNDIR"/overlay-probe/{lower,upper,work} "$RUNDIR/workspace-upper" "$RUNDIR/workspace-work"
      if ! bwrap --unshare-user --unshare-pid --ro-bind /nix/store /nix/store \
             --overlay-src "$RUNDIR/overlay-probe/lower" \
             --overlay "$RUNDIR/overlay-probe/upper" "$RUNDIR/overlay-probe/work" /mnt \
             -- "${pkgs.coreutils}/bin/true" 2>"$RUNDIR/overlay-probe.log"; then
        echo "ERROR: --overlay-workspace is not usable on this host:" >&2
        # Indented read loop rather than sed: everything else in this script
        # sticks to coreutils/bash builtins that runtimeInputs guarantees.
        while IFS= read -r line; do printf '       %s\n' "$line" >&2; done < "$RUNDIR/overlay-probe.log"
        echo "       Unprivileged overlayfs needs kernel >= 5.11, and the upper layer must sit" >&2
        echo "       on a filesystem with user xattr support (tmpfs: kernel >= 6.6)." >&2
        echo "       Point --tmpdir at a disk-backed directory, or drop --overlay-workspace." >&2
        exit 1
      fi
      rm -rf "$RUNDIR/overlay-probe" "$RUNDIR/overlay-probe.log"
      SYNC_ENTRIES+=("$(printf 'overlay\t%s\t-\t%s\t%s' "$RUNDIR/workspace-upper" "$WORKSPACE_HOST" "overlay workspace")")
    fi

    # Copy a host tree into the jail runtime dir, minus its .git - used for
    # the workspace and for every extra rw --mount under --git limited|none.
    jail_copy_tree() {
      local src="$1" dest="$2" entry
      mkdir -p "$dest"
      # dotglob picks up hidden entries (.config, .envrc) but never . or ..;
      # .git is skipped explicitly. --reflink=auto makes this a cheap CoW
      # clone on btrfs/xfs and a normal copy elsewhere.
      shopt -s dotglob nullglob
      for entry in "$src"/*; do
        [ "''${entry##*/}" = ".git" ] && continue
        cp -a --reflink=auto -- "$entry" "$dest/" || {
          echo "ERROR: copying $entry into the jail copy at $dest failed" >&2
          exit 1
        }
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
      [ "''${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
      # Subshell so the cd and the glob options stay local to the expansion.
      removed=$(
        cd "$dir" || exit 0
        shopt -s nullglob globstar
        for m in "''${MASK_PATTERNS[@]}"; do
          # shellcheck disable=SC2086
          for entry in $m; do
            rm -rf -- "''${entry:?mask target empty}" && printf '%s\n' "$entry"
          done
        done
        # A failed rm must not take the whole runner down through errexit:
        # the subshell's status is the loop's, and the assignment below
        # propagates it.
        exit 0
      )
      [ -n "$removed" ] || return 0
      count=$(printf '%s\n' "$removed" | wc -l)
      echo "llm-custody: --mask: removed $count path(s) from $label" >&2
      while IFS= read -r line; do printf '          %s\n' "$line" >&2; done <<< "$removed"
    }

    # Mask a tree the sandbox sees through a direct bind (--ro-mount, and
    # everything under --git full): there is no copy to delete from, so each
    # match is shadowed by an empty read-only file/dir instead. Appends to
    # BWRAP_ARGS, so it has to be called after the bind it shadows - bwrap
    # applies its mounts in argument order.
    #
    # Weaker than the deletion jail_apply_masks does, and deliberately so
    # flagged below: an empty bind only covers the working copy, so a tree
    # bound together with its .git still hands out the masked content as
    # blobs (git show HEAD:<path>).
    jail_mask_binds() {
      local hostroot="$1" guestroot="$2" label="$3" entry
      local -a matches
      [ "''${#MASK_PATTERNS[@]}" -gt 0 ] || return 0
      # NUL-delimited: a path with a newline in it would otherwise split
      # into two bogus mask targets.
      mapfile -d "" -t matches < <(
        cd "$hostroot" || exit 0
        shopt -s nullglob globstar
        for m in "''${MASK_PATTERNS[@]}"; do
          # shellcheck disable=SC2086
          for entry in $m; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            printf '%s\0' "$entry"
          done
        done
        exit 0
      )
      [ "''${#matches[@]}" -gt 0 ] || return 0
      mkdir -p "$RUNDIR/masks"
      for entry in "''${matches[@]}"; do
        MASK_INDEX=$((MASK_INDEX+1))
        if [ -d "$hostroot/$entry" ] && [ ! -L "$hostroot/$entry" ]; then
          mkdir -p "$RUNDIR/masks/$MASK_INDEX"
        else
          : > "$RUNDIR/masks/$MASK_INDEX"
        fi
        BWRAP_ARGS+=(--ro-bind "$RUNDIR/masks/$MASK_INDEX" "$guestroot/$entry")
      done
      echo "llm-custody: --mask: shadowed ''${#matches[@]} path(s) in $label with empty binds" >&2
      if [ -d "$hostroot/.git" ]; then
        echo "          NOTE: $label is bound along with its .git, so masked content is still" >&2
        echo "          readable from history (git show HEAD:<path>). Only a copy (--mount" >&2
        echo "          under --git limited|none) removes it outright." >&2
      fi
    }

    # Re-init a copy as a fresh repo with a single baseline commit, so in-jail
    # git (status/diff/commit/branch) still works with no history to mine.
    jail_init_repo() {
      local dir="$1" src="$2" label="$3" branch
      # Same branch name as the host checkout so prompts, status lines and
      # the agent's own assumptions about the branch still line up.
      branch=$(git -C "$src" symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)
      git -C "$dir" init -q -b "$branch"
      git -C "$dir" "''${JAIL_GIT_IDENT[@]}" add -A
      git -C "$dir" "''${JAIL_GIT_IDENT[@]}" commit -q -m "llm-custody jail baseline" --allow-empty
      git -C "$dir" tag jail-baseline
      echo "llm-custody: $label: branch $branch, single commit tagged jail-baseline" >&2
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
      GIT_DIR="$track" GIT_WORK_TREE="$worktree" git "''${JAIL_GIT_IDENT[@]}" add -A
      GIT_DIR="$track" GIT_WORK_TREE="$worktree" git "''${JAIL_GIT_IDENT[@]}" commit -q -m "llm-custody tracking baseline" --allow-empty
    }

    # --git limited|none: hand the sandbox a copy of the working tree instead
    # of the real one, with .git left behind on the host. Without this, --mask
    # only shadows the working copy - every masked file is still readable as a
    # blob (`git show HEAD:secrets/hiera.yaml`) because .git itself is bound
    # read-write. Partial/sparse clones don't help: they are lazy-fetch, not
    # deletion.
    #   limited: the copy is re-initialized as a fresh repo with one baseline
    #            commit, so in-jail git (status/diff/commit/branch) still
    #            works, just with no history to mine.
    #   none:    plain directory, no repo at all.
    # Changes come back via cleanup()'s sync-back step.
    if [ "$GIT_MODE" != "full" ]; then
      if ! command -v git >/dev/null 2>&1; then
        echo "ERROR: --git $GIT_MODE needs git on the host (it records the baseline used for sync-back)" >&2
        exit 1
      fi
      WORKSPACE_COPY="$RUNDIR/workspace"
      TRACK_GIT="$RUNDIR/track.git"
      WORKSPACE_BIND="$WORKSPACE_COPY"
      echo "llm-custody: --git $GIT_MODE - copying the working tree into $RUNDIR (history stays on the host)" >&2
      jail_copy_tree "$WORKSPACE_HOST" "$WORKSPACE_COPY"

      jail_apply_masks "$WORKSPACE_COPY" "the workspace copy"

      if [ "$GIT_MODE" = "limited" ] && [ -d "$WORKSPACE_HOST/.git" ]; then
        jail_init_repo "$WORKSPACE_COPY" "$WORKSPACE_HOST" "jail repo"
      elif [ "$GIT_MODE" = "limited" ]; then
        echo "llm-custody: workspace is not a git repo - jail gets a plain copy" >&2
      fi

      jail_track_init "$WORKSPACE_COPY" "$TRACK_GIT"
      SYNC_ENTRIES+=("$(printf 'copy\t%s\t%s\t%s\t%s' "$WORKSPACE_COPY" "$TRACK_GIT" "$WORKSPACE_HOST" "jail workspace")")
    fi

    nsenter_holder() {
      nsenter -U -n -t "$HOLDER_PID" --preserve-credentials -- "$@"
    }

    if [ "$NET_FILTER" = "1" ]; then
      # Long-lived netns holder: slirp4netns and dnsmasq/nft attach to its
      # /proc/<pid>/ns/{user,net} by PID; the final sandboxed process later
      # re-enters the same pair via nsenter, sharing this network without
      # also sharing the holder's mount/pid/ipc namespaces.
      #
      # Mapped via newuidmap/newgidmap (not `unshare --map-root-user`), on
      # purpose: a plain single-entry unprivileged mapping forces
      # /proc/<pid>/setgroups to "deny" as a kernel precondition for letting
      # an unprivileged process write gid_map at all, and that "deny" is
      # permanent and namespace-wide - dnsmasq's own privilege-drop calls
      # setgroups() unconditionally whenever it sees euid 0, so with a plain
      # mapping it always dies with "failed to change group-id" (confirmed
      # directly with a raw setgroups() syscall test, isolated from dnsmasq
      # entirely). newuidmap/newgidmap are setuid helpers (present here for
      # rootless Incus containers already - /etc/subuid, /etc/subgid) that
      # perform the mapping from already-privileged code, so setgroups never
      # gets forced to "deny" and a wide range (not just identity 0) is
      # genuinely mapped.
      if ! command -v newuidmap >/dev/null || ! command -v newgidmap >/dev/null; then
        echo "ERROR: newuidmap/newgidmap not found - required for network filtering." >&2
        echo "       (NixOS: enabled by any rootless-container feature, e.g. Incus; see /etc/subuid)" >&2
        exit 1
      fi
      unshare --user --net -- sleep infinity &
      HOLDER_PID=$!
      for _ in $(seq 1 50); do
        [ -e "/proc/$HOLDER_PID/ns/net" ] && break
        sleep 0.02
      done
      newuidmap "$HOLDER_PID" 0 "$(id -u)" 1 1 100000 65536
      newgidmap "$HOLDER_PID" 0 "$(id -g)" 1 1 100000 65536

      nsenter_holder ip link set lo up

      # PID is positional, not a --pid flag (slirp4netns's own usage: `slirp4netns
      # [OPTION]... PID|PATH|FD [TAPNAME]`) - passing it as --pid silently falls
      # through to the "unrecognized option" usage message instead of erroring.
      # -6/--enable-ipv6 is marked experimental by slirp4netns itself, but
      # --configure applies to whatever families are enabled, so no extra
      # manual route/address setup is needed for v6 beyond this flag.
      slirp4netns --configure --mtu=65520 --disable-host-loopback --disable-dns \
        --enable-ipv6 "$HOLDER_PID" tap0 >"$RUNDIR/slirp4netns.log" 2>&1 &
      SLIRP_PID=$!
      sleep 0.3 # let slirp4netns finish configuring tap0/routes before dnsmasq binds

      # Auto-extract domains from base URL env vars, same as the old QEMU
      # runner - otherwise a custom API endpoint's traffic would be
      # forwarded but never whitelisted, silently breaking on the network
      # filter instead of just working.
      for var in ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
        val="''${!var:-}"
        if [ -n "$val" ]; then
          domain="''${val#*://}"
          domain="''${domain%%/*}"
          domain="''${domain%%:*}"
          [ -n "$domain" ] && EXTRA_DOMAINS+=("$domain")
        fi
      done

      {
        echo "no-resolv"
        echo "bind-interfaces"
        echo "listen-address=127.0.0.1"
        echo "log-queries"
        echo "log-facility=$RUNDIR/dnsmasq.log"
        # Most-specific-match wins in dnsmasq, so each allowed domain gets a real
        # upstream and everything else falls through to the catch-all dead end -
        # this is the primary block, not just the nftables IP gate below.
        for d in "''${ALLOWED_DOMAINS[@]}" "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          echo "server=/$d/9.9.9.9"
        done
        # server= above forwards both A and AAAA lookups for allowed domains
        # to the same (dual-stack) upstream - only the catch-all needs a
        # separate line per family.
        echo "address=/#/0.0.0.0"
        echo "address=/#/::"
      } > "$RUNDIR/dnsmasq.conf"

      nsenter_holder dnsmasq --conf-file="$RUNDIR/dnsmasq.conf" \
        --keep-in-foreground --pid-file="$RUNDIR/dnsmasq.pid" &
      DNSMASQ_PID=$!
      sleep 0.2

      # ip daddr only ever matches IPv4 packets, even inside a dual-stack
      # inet-family table - it's simply not-applicable (not "false") for an
      # IPv6 packet, so a v6-unaware ruleset here wouldn't just fail to
      # filter v6 traffic, it would silently let it all through under the
      # chain's default accept policy. Hence the separate ipv6_addr set and
      # ip6 daddr rule below, not just one shared set.
      nsenter_holder nft -f - <<'NFT'
    table inet filter {
      set allowed {
        type ipv4_addr
        flags interval
      }
      set allowed6 {
        type ipv6_addr
        flags interval
      }
      chain output {
        type filter hook output priority 0; policy accept;
        udp dport 53 accept
        tcp dport 53 accept
        tcp dport { 80, 443 } ip daddr != @allowed drop
        tcp dport { 80, 443 } ip6 daddr != @allowed6 drop
      }
    }
    NFT

      # Belt for the dnsmasq block's suspenders: if something bypasses DNS and
      # hardcodes an IP directly, this nftables gate is what actually stops it,
      # since only IPs a whitelisted-domain lookup resolved to are ever added.
      nsenter_holder tail -F -n0 "$RUNDIR/dnsmasq.log" 2>/dev/null | \
        while read -r line; do
          case "$line" in
            *" is "*)
              ip="''${line##* is }"
              if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                nsenter_holder nft add element inet filter allowed "{ $ip }" 2>/dev/null || true
              elif [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                nsenter_holder nft add element inet filter allowed6 "{ $ip }" 2>/dev/null || true
              fi
              ;;
          esac
        done &
      WATCH_PID=$!

      # First-connect race mitigation: the whitelist only learns an IP from
      # dnsmasq's post-reply log line, so the first connect after a lookup
      # can arrive before the set is armed. Pre-arm the sets with a
      # host-side resolution of every allowed domain before the sandbox
      # starts (resolved through the holder ns, inside the private netns, so
      # the queries go out the same slirp link the sandbox will use and the
      # answers match its resolver). The log watcher still tracks CDN record
      # drift during the run.
      if command -v getent >/dev/null 2>&1; then
        for d in "''${ALLOWED_DOMAINS[@]}" "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          while read -r line; do
            ip="''${line%% *}"
            case "$ip" in
              ""|0.0.0.0|*:*|*[!0-9.]*) continue ;;
            esac
            nsenter_holder nft add element inet filter allowed "{ $ip }" 2>/dev/null || true
          done < <(nsenter_holder getent ahostsv4 "$d" 2>/dev/null)
          while read -r line; do
            ip="''${line%% *}"
            case "$ip" in
              ""|*[!0-9a-fA-F:]*) continue ;;
            esac
            nsenter_holder nft add element inet filter allowed6 "{ $ip }" 2>/dev/null || true
          done < <(nsenter_holder getent ahostsv6 "$d" 2>/dev/null)
        done
      fi

      echo "nameserver 127.0.0.1" > "$RUNDIR/resolv.conf"
    fi

    # bwrap's --seccomp wants an already-open fd on the BPF program; a real
    # file (not a `<()` process substitution) avoids relying on bash's
    # fd-inheritance/CLOEXEC behavior across the exec into bwrap.
    ${seccompDenylist}/bin/seccomp-denylist > "$RUNDIR/seccomp.bpf"
    exec {SECCOMP_FD}<"$RUNDIR/seccomp.bpf"

    # WORKSPACE_HOST/WORKSPACE_GUEST were already resolved above, right
    # after arg parsing (needed there for the git safety checks).

    # Workspace mount: plain rw bind by default, or an opt-in copy-on-write
    # overlay.
    #
    # bwrap's overlay takes three distinct pieces: --overlay-src declares a
    # *lower* (read-only) layer, and --overlay RWSRC WORKDIR DEST does the
    # actual mount with RWSRC as the writable upper layer. WORKDIR must be an
    # empty directory on the same filesystem as RWSRC - that's an overlayfs
    # requirement, not a bwrap one - hence both live under $RUNDIR. Every
    # write lands in the upper dir and touches nothing on the host until
    # cleanup()'s sync-back. Both host paths sit under the sandbox runtime
    # dir, which the later --tmpfs /tmp hides from the sandbox's own view.
    if [ "$OVERLAY" = "1" ]; then
      # Dirs and host support were both settled by the preflight right after
      # the cleanup trap was installed.
      # WORKSPACE_BIND is the real tree here: --overlay-workspace is rejected
      # for --git limited/none further up, since those already hand the
      # sandbox a copy.
      WS_SPEC=(
        --overlay-src "$WORKSPACE_BIND"
        --overlay "$RUNDIR/workspace-upper" "$RUNDIR/workspace-work" "$WORKSPACE_GUEST"
      )
    else
      # WORKSPACE_BIND is the real tree with --git full, the RUNDIR copy
      # otherwise.
      WS_SPEC=(--bind "$WORKSPACE_BIND" "$WORKSPACE_GUEST")
    fi

    BWRAP_ARGS=(
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
      --die-with-parent --new-session
      # Drop CAP_SYS_ADMIN from the sandboxed process. Every mount-creation
      # syscall (mount(2), open_tree/move_mount, mount_setattr, umount2,
      # pivot_root, ...) requires it, so this closes the whole class at once
      # - and it's the one that matters most: modern util-linux `mount` uses
      # the mount API (open_tree+move_mount), which a seccomp list of the
      # mount syscall alone misses (the FHS bwrap is denied but the mount
      # API copy is not). bwrap applies --cap-drop after its own sandbox
      # setup, so bwrap itself keeps what it needs for unshare/mount.
      --cap-drop CAP_SYS_ADMIN
      --seccomp "$SECCOMP_FD"
      --proc /proc
      --dev /dev
      --tmpfs /tmp
      --tmpfs /home/user
      --setenv HOME /home/user
      --setenv ${toolDefaults.configEnvVar} /home/user/${toolDefaults.configDirName}
      # Fixed per-tool env (launchers/<tool>.nix extraEnv). bwrap applies
      # --setenv in order, so the --env pairs added further down still win.
      ${extraEnvArgs}
      --chdir "$WORKSPACE_GUEST"
      --ro-bind /nix/store /nix/store
      "''${WS_SPEC[@]}"
      --bind "$STATE_DIR" /home/user/${toolDefaults.configDirName}
    )

    # Hooks dir the in-jail git wrapper below pins core.hooksPath to.
    #
    # --git full: the host repo's own hooks, bound read-only even though the
    # workspace is rw - a jailed agent shouldn't be able to plant or modify
    # git hooks that run on the host later.
    #
    # limited/none: the host .git isn't mounted at all, and the jail repo's
    # hooks dir lives in the discarded copy (it never syncs back, /.git/ is
    # excluded from tracking). Pin to an empty read-only dir anyway so hooks
    # the agent writes don't even fire inside the jail.
    if [ "$GIT_MODE" = "full" ]; then
      HOOKS_GUEST="$WORKSPACE_GUEST/.git/hooks"
      if [ -d "$WORKSPACE_HOST/.git/hooks" ]; then
        BWRAP_ARGS+=(--ro-bind "$WORKSPACE_HOST/.git/hooks" "$HOOKS_GUEST")
      fi
    else
      mkdir -p "$RUNDIR/empty-hooks"
      BWRAP_ARGS+=(--ro-bind "$RUNDIR/empty-hooks" /run/llmcustody-hooks)
      HOOKS_GUEST=/run/llmcustody-hooks
    fi

    # Mirrors the old QEMU runner's host-sw/host-user-sw mounts: the tool
    # shells out to rg/git/jq/etc via its bash tool, so PATH needs the same
    # toolset the host has, not just the tool's own binary. /nix/store is
    # already bound wholesale above, so resolving these through their real
    # store path (rather than binding the ~/.nix-profile /
    # /etc/profiles/per-user symlink itself, which points outside anything
    # mounted in the jail) needs no extra bind at all.
    JAIL_PATH="/usr/bin:/bin"
    if [ -e /run/current-system/sw ]; then
      BWRAP_ARGS+=(--ro-bind /run/current-system/sw /host-sw)
      JAIL_PATH="/host-sw/bin:$JAIL_PATH"
    fi
    USERNAME=$(whoami 2>/dev/null) || USERNAME="$USER"
    if [ -n "$USERNAME" ] && [ -e "/etc/profiles/per-user/$USERNAME" ]; then
      BWRAP_ARGS+=(--ro-bind "/etc/profiles/per-user/$USERNAME" /host-user-sw)
      JAIL_PATH="/host-user-sw/bin:$JAIL_PATH"
    fi
    # Home-manager's legacy (non-per-user) profile - what a tool installed
    # via `home.packages` actually resolves through on such a host
    # (`~/.nix-profile` -> /nix/store/...-profile/bin/<tool>).
    if [ -e "$HOME/.nix-profile" ]; then
      NIX_PROFILE_REAL=$(readlink -f "$HOME/.nix-profile")
      JAIL_PATH="$NIX_PROFILE_REAL/bin:$JAIL_PATH"
    fi
    # Non-NixOS hosts: bind the real /usr/bin and /bin (ro) so the jailed
    # tool's subprocesses can use system-installed binaries (git, make, cc,
    # ...). NixOS has no FHS /usr/bin (/run/current-system/sw is already
    # bound at /host-sw); a /usr/bin symlink (merged-usr, or the /usr/bin/env
    # compat shim some NixOS configs ship) means the real dir lives
    # elsewhere, so skip symlinks as well. Also makes in-jail `command -v
    # git` resolve to /usr/bin/git on such hosts - see the git wrapper below.
    HOST_USR_BIN=0
    if [ -d /usr/bin ] && [ ! -L /usr/bin ]; then
      HOST_USR_BIN=1
      BWRAP_ARGS+=(--ro-bind /usr/bin /usr/bin)
    fi
    if [ -d /bin ] && [ ! -L /bin ]; then
      BWRAP_ARGS+=(--ro-bind /bin /bin)
    fi

    # Shadow `git` ahead of everything else on PATH with a wrapper that
    # always forces -c core.hooksPath at the real, read-only-bound hooks
    # dir. .git/hooks is already ro-bound above, but .git/config is not -
    # an agent can still rewrite core.hooksPath there to point at somewhere
    # writable. A command-line -c beats repo config, so git invoked *inside*
    # this jail can't be redirected that way even if config gets rewritten.
    # (Doesn't protect a plain `git` run on the host outside the jail later
    # if config was rewritten - that's what the hooksPath diff-warn in
    # cleanup() above is for.)
    if REAL_GIT=$(command -v git 2>/dev/null); then
      # The wrapper must exec paths that exist inside the jail. Resolve
      # through their store path (readlink -f): on the host, `command -v`
      # commonly returns a symlink under ~/.nix-profile (home-manager) or
      # /etc/profiles/per-user/$USER, neither of which is bound in the
      # sandbox - but /nix/store is bound wholesale, so a store path
      # always resolves. Same reasoning for the interpreter: no /bin/sh
      # exists inside the jail on NixOS hosts, and even where the host
      # provides one it would only work if /bin or /usr/bin happened to be
      # bound - a bash store path always exists (store is bound wholesale)
      # and is deterministic across every host type.
      REAL_GIT_RESOLVED=$(readlink -f "$REAL_GIT" 2>/dev/null || true)
      case "$REAL_GIT_RESOLVED" in
        /nix/store/*) REAL_GIT="$REAL_GIT_RESOLVED" ;;
        /usr/bin/*)
          if [ "$HOST_USR_BIN" = "1" ]; then REAL_GIT="$REAL_GIT_RESOLVED"; else REAL_GIT=""; fi ;;
        *) REAL_GIT="" ;;
      esac
      if [ -z "$REAL_GIT" ]; then
        echo "warning: git resolves to $REAL_GIT_RESOLVED, not visible inside the jail (needs /nix/store or a bound /usr/bin) - skipping in-jail git hooks shadow" >&2
      fi
      if [ -n "$REAL_GIT" ]; then
        GIT_WRAPPER_DIR="$RUNDIR/bin"
        mkdir -p "$GIT_WRAPPER_DIR"
        printf '#!%s\nexec "%s" -c core.hooksPath="%s" "$@"\n' \
          "${pkgs.bash}/bin/sh" "$REAL_GIT" "$HOOKS_GUEST" \
          > "$GIT_WRAPPER_DIR/git"
        chmod +x "$GIT_WRAPPER_DIR/git"
        BWRAP_ARGS+=(--ro-bind "$GIT_WRAPPER_DIR" /run/llmcustody-bin)
        JAIL_PATH="/run/llmcustody-bin:$JAIL_PATH"
      fi
    fi

    BWRAP_ARGS+=(--setenv PATH "$JAIL_PATH")

    # Bind each skill's *resolved* target rather than the ~/.claude/skills
    # dir itself - external skill managers (e.g. skillissue) place symlinks
    # there, and a symlink bound as-is just dangles inside the sandbox since
    # its target lives outside anything else mounted.
    #
    # Target dir is per-tool (tools.nix skillsDir) because each tool looks in
    # its own place. When that path sits under the tool's config dir (claude:
    # CLAUDE_CONFIG_DIR/skills) these binds stack on top of the state mount
    # added above, which also means a skill the tool installs itself lands in
    # a masked directory and stays invisible for the rest of the run.
    #
    # Read-only by default: the bind source is the real host checkout the
    # host's own agents read via ~/.claude/skills, so a writable bind would
    # let a jailed agent edit the instructions it (and other agents) run,
    # and those changes persist on the host and get pushed on the next
    # skillissue sync. --rw-skills opts into exactly that, only when the
    # in-jail work is deliberately skill maintenance.
    if [ -d "$HOME/.claude/skills" ]; then
      for entry in "$HOME/.claude/skills"/*; do
        [ -e "$entry" ] || continue
        if [ "$RW_SKILLS" = "1" ]; then
          BWRAP_ARGS+=(--bind "$(readlink -f "$entry")" "/home/user/${toolDefaults.skillsDir}/$(basename "$entry")")
        else
          BWRAP_ARGS+=(--ro-bind "$(readlink -f "$entry")" "/home/user/${toolDefaults.skillsDir}/$(basename "$entry")")
        fi
      done
      if [ "$RW_SKILLS" = "1" ]; then
        echo "llm-custody: WARNING - skills are read-write; an in-jail agent can modify ~/.claude/skills content that the host reads (and skillissue may push). Only continue if in-jail skill maintenance is intended." >&2
      fi
    fi
    [ -f /etc/nsswitch.conf ] && BWRAP_ARGS+=(--ro-bind /etc/nsswitch.conf /etc/nsswitch.conf)
    [ -d /etc/ssl ] && BWRAP_ARGS+=(--ro-bind /etc/ssl /etc/ssl)
    # NixOS: /etc/ssl/certs/ca-certificates.crt symlinks through
    # /etc/static/ssl before landing in /nix/store - both need binding, or
    # TLS verification fails with a confusing "unable to get local issuer
    # certificate".
    [ -d /etc/static/ssl ] && BWRAP_ARGS+=(--ro-bind /etc/static/ssl /etc/static/ssl)

    # bwrap can bind a single file directly - no 9p-can't-mount-single-files
    # workaround needed here.
    [ -f "$HOME/.gitconfig" ] && BWRAP_ARGS+=(--ro-bind "$HOME/.gitconfig" /home/user/.gitconfig)

    if [ "$NET_FILTER" = "1" ]; then
      BWRAP_ARGS+=(--ro-bind "$RUNDIR/resolv.conf" /etc/resolv.conf)
    elif [ -f /etc/resolv.conf ]; then
      BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
    fi

    # Explicit list of vars every session needs (credentials, terminal)
    # plus the locale vars tool subprocesses (rg/git/compilers) depend on
    # for sane UTF-8 handling. --env covers anything else, e.g. proxy or
    # custom-endpoint settings.
    for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL TERM COLORTERM LANG LC_ALL LC_CTYPE; do
      [ -n "''${!var:-}" ] && BWRAP_ARGS+=(--setenv "$var" "''${!var}")
    done
    while IFS='=' read -r awsvar awsval; do
      [ -n "$awsvar" ] && BWRAP_ARGS+=(--setenv "$awsvar" "$awsval")
    done < <(env | grep '^AWS_' || true)
    for spec in "''${ENV_PAIRS[@]+"''${ENV_PAIRS[@]}"}"; do
      key="''${spec%%=*}"
      val="''${spec#*=}"
      if [ -z "$key" ] || [ "$key" = "$spec" ]; then
        echo "ERROR: --env expects KEY=VAL, got: $spec" >&2
        exit 1
      fi
      BWRAP_ARGS+=(--setenv "$key" "$val")
    done
    # Display variables are stripped by default so terminals fall back to OSC 52
    # for clipboard. Passing them in without real display access just makes
    # clipboard tools fail. --x11 opts into real X11/Wayland passthrough.
    BWRAP_ARGS+=(--unsetenv DISPLAY --unsetenv XAUTHORITY --unsetenv WAYLAND_DISPLAY)
    if [ "$X11" = "1" ]; then
      for var in DISPLAY XAUTHORITY WAYLAND_DISPLAY; do
        [ -n "''${!var:-}" ] && BWRAP_ARGS+=(--setenv "$var" "''${!var}")
      done
      [ -d /tmp/.X11-unix ] && BWRAP_ARGS+=(--ro-bind /tmp/.X11-unix /tmp/.X11-unix)
      if [ -n "''${XAUTHORITY:-}" ] && [ -f "$XAUTHORITY" ]; then
        BWRAP_ARGS+=(--ro-bind "$XAUTHORITY" "$XAUTHORITY")
      elif [ -f "$HOME/.Xauthority" ]; then
        BWRAP_ARGS+=(--ro-bind "$HOME/.Xauthority" "$HOME/.Xauthority")
      fi
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        WAYLAND_SOCK="/run/user/$(id -u)/$WAYLAND_DISPLAY"
        [ -S "$WAYLAND_SOCK" ] && BWRAP_ARGS+=(--ro-bind "$WAYLAND_SOCK" "$WAYLAND_SOCK")
      fi
    fi
    if STTY_SIZE=$(stty size 2>/dev/null); then
      BWRAP_ARGS+=(--setenv LINES "''${STTY_SIZE%% *}" --setenv COLUMNS "''${STTY_SIZE##* }")
    fi

    # Extra binds land under /workspace by default (see WORKSPACE_ROOT
    # above), named after the host path's last component. Targets are
    # tracked so two sources can never silently end up on the same path -
    # the second bind would shadow the first, and the agent would see one
    # tree where two were asked for. --same-path keeps host paths verbatim,
    # since that mode exists specifically to make in-jail paths match the
    # host's.
    MOUNT_TARGETS=("$WORKSPACE_GUEST")
    MOUNT_SOURCES=("$WORKSPACE_HOST")
    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      mode="''${spec##*:}"
      paths="''${spec%:*}"
      if [[ "$paths" == *:* ]]; then
        hostpath="''${paths%%:*}"; guestpath="''${paths#*:}"
      else
        hostpath="$paths"; guestpath=""
      fi
      if [ ! -e "$hostpath" ]; then
        echo "ERROR: mount path does not exist: $hostpath" >&2
        exit 1
      fi
      if [ -z "$guestpath" ]; then
        if [ "$SAME_PATH" = "1" ]; then
          guestpath="$hostpath"
        else
          # basename handles trailing slashes ('/devel/test/' -> 'test');
          # what it can't name (/, ., ..) has to be spelled out by hand.
          mountname=$(basename -- "$hostpath")
          case "$mountname" in
            /|.|..)
              echo "ERROR: cannot derive a mount target from '$hostpath'" >&2
              echo "       pass one explicitly: --mount $hostpath:$WORKSPACE_ROOT/<name>" >&2
              exit 1 ;;
          esac
          guestpath="$WORKSPACE_ROOT/$mountname"
        fi
      elif [[ "$guestpath" != /* ]]; then
        # A relative target is a name inside the workspace root, not a path
        # relative to the sandbox cwd - bwrap would reject the latter anyway.
        guestpath="$WORKSPACE_ROOT/$guestpath"
      fi
      for i in "''${!MOUNT_TARGETS[@]}"; do
        if [ "''${MOUNT_TARGETS[$i]}" = "$guestpath" ]; then
          echo "ERROR: two mounts resolve to the same jail path: $guestpath" >&2
          echo "       already taken by: ''${MOUNT_SOURCES[$i]}" >&2
          echo "       conflicting with: $hostpath" >&2
          echo "       give one an explicit target, e.g. --mount $hostpath:$WORKSPACE_ROOT/<other-name>" >&2
          exit 1
        fi
      done
      MOUNT_TARGETS+=("$guestpath")
      MOUNT_SOURCES+=("$hostpath")
      if [ "$mode" = "ro" ]; then
        BWRAP_ARGS+=(--ro-bind "$hostpath" "$guestpath")
        # Right after the bind it shadows: bwrap honours argument order.
        jail_mask_binds "$hostpath" "$guestpath" "$guestpath"
        continue
      fi

      # Extra rw mounts get the same host-tree protection as the workspace,
      # chosen by the same flags - an agent let loose in a second checkout
      # can do exactly as much damage there as in the main one, so a direct
      # bind only when --git full explicitly asks for the real tree.
      #
      # --mask applies to every tree, not just the workspace: its globs are
      # relative to whichever tree root they are expanded against, and a
      # pattern written to keep credentials out of the jail is meant to keep
      # them out of a second checkout too. Copies get the deletion, direct
      # binds the weaker empty-bind shadow, same split as the workspace.
      MOUNT_INDEX=$((MOUNT_INDEX+1))
      if [ ! -d "$hostpath" ]; then
        # Single file: nothing to copy into a repo or diff against a
        # baseline, so it stays a direct bind in every mode.
        if [ "$GIT_MODE" != "full" ] || [ "$OVERLAY" = "1" ]; then
          echo "llm-custody: --mount $hostpath is a file - bound directly, writes hit the host immediately" >&2
        fi
        BWRAP_ARGS+=(--bind "$hostpath" "$guestpath")
        continue
      fi
      if [ "$GIT_MODE" != "full" ]; then
        mount_copy="$RUNDIR/mounts/$MOUNT_INDEX"
        mount_track="$RUNDIR/mounts/$MOUNT_INDEX.git"
        echo "llm-custody: --git $GIT_MODE - copying $hostpath into $RUNDIR (history stays on the host)" >&2
        jail_copy_tree "$hostpath" "$mount_copy"
        jail_apply_masks "$mount_copy" "the copy of $hostpath"
        if [ "$GIT_MODE" = "limited" ] && [ -d "$hostpath/.git" ]; then
          jail_init_repo "$mount_copy" "$hostpath" "jail repo for $guestpath"
        fi
        jail_track_init "$mount_copy" "$mount_track"
        SYNC_ENTRIES+=("$(printf 'copy\t%s\t%s\t%s\t%s' "$mount_copy" "$mount_track" "$hostpath" "mount $guestpath")")
        BWRAP_ARGS+=(--bind "$mount_copy" "$guestpath")
      elif [ "$OVERLAY" = "1" ]; then
        # Upper and work dir must share a filesystem (overlayfs requirement);
        # both under $RUNDIR, which the --overlay-workspace preflight already
        # probed for unprivileged-overlay support.
        mkdir -p "$RUNDIR/mounts/$MOUNT_INDEX-upper" "$RUNDIR/mounts/$MOUNT_INDEX-work"
        SYNC_ENTRIES+=("$(printf 'overlay\t%s\t-\t%s\t%s' "$RUNDIR/mounts/$MOUNT_INDEX-upper" "$hostpath" "overlay mount $guestpath")")
        BWRAP_ARGS+=(
          --overlay-src "$hostpath"
          --overlay "$RUNDIR/mounts/$MOUNT_INDEX-upper" "$RUNDIR/mounts/$MOUNT_INDEX-work" "$guestpath"
        )
        jail_mask_binds "$hostpath" "$guestpath" "$guestpath"
      else
        BWRAP_ARGS+=(--bind "$hostpath" "$guestpath")
        jail_mask_binds "$hostpath" "$guestpath" "$guestpath"
      fi
    done

    # --mask GLOB against the workspace. Only --git full needs the empty-bind
    # treatment here: limited/none already deleted the matches from the
    # workspace copy, which is stronger (nothing underneath to unmask, and no
    # .git blobs either). Runs after the workspace and user mounts are in
    # BWRAP_ARGS so the shadows land on top of them.
    if [ "$GIT_MODE" = "full" ]; then
      jail_mask_binds "$WORKSPACE_HOST" "$WORKSPACE_GUEST" "the workspace"
    fi

    if [ "$SELFTEST" = "1" ]; then
      # Run the *entire* runtime chain (netns holder, slirp4netns, dnsmasq,
      # nftables, bwrap arg assembly, git wrapper, seccomp) but exec the
      # probe from selftest.nix (see let above) instead of the tool -
      # exercises everything a real session would, without needing an
      # in-jail /login.
      if [ ! -x "${toolExe}" ]; then
        echo "ERROR (selftest): tool binary not found: ${toolExe}" >&2
        exit 1
      fi
      echo "llm-custody selftest: toolExe=${toolExe}" >&2
      BWRAP_ARGS+=(--setenv SELFTEST_NET "$NET_FILTER")
      BWRAP_ARGS+=(--setenv SELFTEST_CONFIGDIR "/home/user/${toolDefaults.configDirName}")
      BWRAP_ARGS+=(--setenv SELFTEST_UNSHARE "${selftestUnshare}")
      BWRAP_ARGS+=(--setenv SELFTEST_DOMAIN "${selftestDomain}")
      BWRAP_ARGS+=(--setenv SELFTEST_GITMODE "$GIT_MODE")
      BWRAP_ARGS+=(--ro-bind "${selftestProbe}" /selftest.sh)
      if [ "$NET_FILTER" = "1" ]; then
        nsenter_holder bwrap "''${BWRAP_ARGS[@]}" -- "${pkgs.bash}/bin/sh" /selftest.sh
      else
        bwrap "''${BWRAP_ARGS[@]}" -- "${pkgs.bash}/bin/sh" /selftest.sh
      fi
      exit $?
    fi

    # Mid-session sync: the exit trap is not the only moment the operator
    # may want the jail's work on the host - a long session can produce
    # something worth keeping (or reviewing in a real editor) long before
    # the agent is done. The manifest plus a one-line launcher make the
    # exact same sync-back runnable from a second terminal, as often as
    # wanted: each sync advances the tracking baseline, so the next one only
    # reports what changed since.
    #
    # Deliberately *not* reachable from inside the sandbox: $RUNDIR is not
    # mounted there, so the agent cannot sync its own work out unreviewed.
    if [ "''${#SYNC_ENTRIES[@]}" -gt 0 ]; then
      SYNC_MANIFEST="$RUNDIR/sync-manifest"
      : > "$SYNC_MANIFEST"
      for entry in "''${SYNC_ENTRIES[@]}"; do
        printf '%s\n' "$entry" >> "$SYNC_MANIFEST"
      done
      # %q on the manifest path: $RUNDIR inherits --tmpdir, which may well
      # contain a space or a quote.
      printf '#!%s\nexec %s --prompt %s "$@"\n' \
        "${pkgs.bash}/bin/sh" "${syncBack}" "$(printf '%q' "$SYNC_MANIFEST")" > "$RUNDIR/sync"
      chmod +x "$RUNDIR/sync"

      # Stable handle for anything that wants to find the live session
      # without parsing terminal output: a per-pid symlink plus `current`
      # for the most recent run. Concurrent runs each keep their own pid
      # entry; `current` is simply the latest to start.
      SYNC_REG_DIR="''${XDG_RUNTIME_DIR:-$LLMCUSTODY_TMPDIR}/llm-custody"
      mkdir -p "$SYNC_REG_DIR"
      SYNC_REG="$SYNC_REG_DIR/$$.sync"
      ln -sfn "$RUNDIR/sync" "$SYNC_REG"
      ln -sfn "$RUNDIR/sync" "$SYNC_REG_DIR/current"

      echo "llm-custody: mid-session sync: $RUNDIR/sync (also $SYNC_REG_DIR/current)" >&2

      # Terminals that understand OSC 1337 SetUserVar get the path as a
      # variable too, which is what makes a one-key sync binding possible.
      # Off by default elsewhere: terminals that don't know the sequence may
      # print it. LLMCUSTODY_USERVAR=1/0 forces the decision either way.
      case "''${LLMCUSTODY_USERVAR:-auto}" in
        0|off|no) ;;
        1|on|yes) emit_sync_uservar "$RUNDIR/sync"; USERVAR_SET=1 ;;
        *)
          if [ -n "''${WEZTERM_PANE:-}" ] || [ "''${TERM_PROGRAM:-}" = "WezTerm" ]; then
            emit_sync_uservar "$RUNDIR/sync"
            USERVAR_SET=1
          fi ;;
      esac
    fi

    # Session resume: translate the generic -c/--continue (resume most
    # recent session without prompting) and -r/--resume (picker, or a
    # specific session id) aliases into the flags this tool actually
    # accepts (tools.nix resumeFlags), so the same muscle memory works for
    # every tool. Prepended to TOOL_ARGS - anything the user passes after
    # `--` still applies on top.
    if [ "$RESUME_MODE" = "continue" ]; then
      TOOL_ARGS=("$CONTINUE_FLAG" "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}")
    elif [ "$RESUME_MODE" = "picker" ]; then
      if [ -n "$RESUME_ARG" ]; then
        TOOL_ARGS=("$RESUME_WITH_ID_FLAG" "$RESUME_ARG" "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}")
      else
        TOOL_ARGS=("$RESUME_FLAG" "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}")
      fi
    fi

    # --dangerous: the tool's own skip-all-permission-prompts flag
    # (tools.nix dangerousFlag). Prepended, so a session flag the user passes
    # after `--` can still follow it.
    if [ "$DANGEROUS" = "1" ]; then
      TOOL_ARGS=("$DANGEROUS_FLAG" "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}")
    fi

    if [ "$NET_FILTER" = "1" ]; then
      nsenter_holder bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    else
      bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    fi
  '';
}
