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
  # Guest path and symlink names of the operator-managed package profile
  # (lib/toolbox.nix), shared with lib/toolbox-cli.nix and the launchers.
  toolbox = import ./toolbox.nix;
  # Store path of the host-side provisioning CLI, published as a user var so
  # a terminal keybinding can run it without llm-custody being installed on
  # the host at all - `nix run .#pi` is the documented quick start, and it
  # puts nothing on PATH.
  toolboxCli = pkgs.lib.getExe (import ./toolbox-cli.nix { inherit pkgs; });
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
    TOOLBOX_DIR="''${LLMCUSTODY_TOOLBOX_DIR:-}"
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
    DRYRUN=0
    LIST_PROFILES=0
    LIST_SESSIONS=0
    SYNC_EXCLUDES=()
    # Seconds between unsynced-change checks during a session. 0 disables
    # the watcher entirely - worth it on a tree big enough for `git status`
    # to cost real time.
    WATCH_INTERVAL=15
    # 0 = warnings and errors only, 1 = normal, 2 = verbose.
    VERBOSITY=1
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
    # Where this tool keeps session transcripts inside its state dir
    # (tools.nix sessionsDir), used by --list-sessions.
    SESSIONS_SUBDIR="${toolDefaults.sessionsDir}"

    # Everything the runner says about itself goes through these, on stderr,
    # so the jailed tool keeps stdout to itself (a `-p` run piped into
    # something else must not get runner chatter mixed into its output).
    #
    # Colour follows the usual two conditions - stderr is a terminal and
    # NO_COLOR is unset - so a redirected log stays plain text.
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_YELLOW=""; C_GREEN=""; C_CYAN=""
    if [ -t 2 ] && [ -z "''${NO_COLOR:-}" ]; then
      C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
      C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'
    fi

    log()  { [ "$VERBOSITY" -ge 1 ] && printf '%sllm-custody:%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2 || true; }
    vlog() { [ "$VERBOSITY" -ge 2 ] && printf '%sllm-custody:%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$*" "$C_RESET" >&2 || true; }
    warn() { printf '%sllm-custody: WARNING%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
    err()  { printf '%sllm-custody: ERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
    # Continuation line under a log/warn/err message. Never suppressed by
    # --quiet: it only ever appears attached to something already printed.
    hint() { printf '            %s\n' "$*" >&2; }
    die()  { err "$*"; exit 1; }

    usage() {
      cat <<'USAGE'
    Usage: llm-custody-${name} [options] [-- tool-args...]

    Options:
      --profile NAME        State profile, a subdir of --state-dir/${name} (default: default)
      --state-dir PATH      Jail state root dir (default: ~/.config/llm-custody)
      --toolbox-dir PATH    Operator package profile bound read-only at
                             ${toolbox.guestDir} and prepended to the jail's PATH
                             (default: --state-dir/toolbox). The sandbox cannot
                             realize a derivation itself, so this is how a tool
                             that is not on the host's PATH gets in; add to it
                             from the host with llm-custody-toolbox, including
                             while a session is running
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
      --sync-exclude GLOB   Never sync paths matching GLOB back to the host
                             tree, in any mode that syncs (repeatable).
                             Matched against tree-relative paths; '*' crosses
                             '/' here, so '*.log' covers every depth
      --watch-interval N    Seconds between unsynced-change checks during the
                             session (default 15, 0 disables). The count is
                             written to RUNDIR/dirty and published as the
                             llm_custody_dirty user var whenever it changes
      --selftest            Run a sandbox self-check (full chain incl. netns +
                             seccomp + git wrapper) and exit without launching
                             the tool; no in-jail /login needed
      --dry-run             Resolve everything (mounts, masks, domains, env,
                             bwrap arguments) and print it instead of
                             launching. Starts no network namespace and
                             copies no trees
      --list-profiles       List the state profiles of this tool and exit
      --list-sessions       List the sessions stored in this profile and exit
      -q, --quiet           Only warnings and errors
      -v, --verbose         Extra detail about mounts and network setup
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

    Environment:
      LLMCUSTODY_PROFILE    Default for --profile
      LLMCUSTODY_STATE_DIR  Default for --state-dir
      LLMCUSTODY_TOOLBOX_DIR
                            Default for --toolbox-dir
      LLMCUSTODY_USERVAR    1/0 forces the WezTerm user-var emission that is
                             otherwise only done when WezTerm is detected
      TMPDIR                Default for --tmpdir
      NO_COLOR              Set to anything to disable coloured output
      PAGER                 Pager for the 'd' answer at the sync prompt

    Files:
      --state-dir/domains   Extra whitelist domains, one per line, '#' comments
      --state-dir/toolbox   Operator package profile, see --toolbox-dir
      --state-dir/${name}/PROFILE
                            Per-profile tool state (sessions, credentials)
    USAGE
      exit 0
    }

    # Every flag below that does `shift 2` reads "$2" first, and under
    # `set -u` a missing value aborts with a bare "$2: unbound variable" and
    # a line number - no mention of which flag the operator mistyped. Called
    # as `need_arg "$@"`, so $# is what is left on the command line.
    need_arg() {
      [ $# -ge 2 ] || die "$1 needs an argument"
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --profile)       need_arg "$@"; PROFILE="$2"; shift 2 ;;
        --state-dir)     need_arg "$@"; STATE_ROOT="$2"; shift 2 ;;
        --toolbox-dir)   need_arg "$@"; TOOLBOX_DIR="$2"; shift 2 ;;
        --same-path)     SAME_PATH=1; shift ;;
        --tmpdir)        need_arg "$@"; LLMCUSTODY_TMPDIR="$2"; shift 2 ;;
        --mount)         need_arg "$@"; EXTRA_MOUNTS+=("$2:rw"); shift 2 ;;
        --ro-mount)      need_arg "$@"; EXTRA_MOUNTS+=("$2:ro"); shift 2 ;;
        --allow-domain)  need_arg "$@"; EXTRA_DOMAINS+=("$2"); shift 2 ;;
        --env)           need_arg "$@"; ENV_PAIRS+=("$2"); shift 2 ;;
        --overlay-workspace) OVERLAY=1; shift ;;
        --git)
          need_arg "$@"
          case "$2" in
            full|limited|none) GIT_MODE="$2" ;;
            *) die "--git expects full|limited|none, got: $2" ;;
          esac
          shift 2 ;;
        --selftest)      SELFTEST=1; shift ;;
        --dry-run)       DRYRUN=1; shift ;;
        --list-profiles) LIST_PROFILES=1; shift ;;
        --list-sessions) LIST_SESSIONS=1; shift ;;
        -q|--quiet)      VERBOSITY=0; shift ;;
        -v|--verbose)    VERBOSITY=2; shift ;;
        --dangerous)
          if [ -z "$DANGEROUS_FLAG" ]; then
            die "${name} has no dangerous-mode flag (tools.nix dangerousFlag unset)"
          fi
          DANGEROUS=1; shift ;;
        --rw-skills)     RW_SKILLS=1; shift ;;
        --x11)           X11=1; shift ;;
        --mask)          need_arg "$@"; MASK_PATTERNS+=("$2"); shift 2 ;;
        --sync-exclude)  need_arg "$@"; SYNC_EXCLUDES+=("$2"); shift 2 ;;
        --watch-interval)
          need_arg "$@"
          case "$2" in
            ""|*[!0-9]*) die "--watch-interval expects whole seconds (0 disables), got: $2" ;;
          esac
          WATCH_INTERVAL="$2"; shift 2 ;;
        --no-net-filter) NET_FILTER=0; shift ;;
        --merge-config)      MERGE_CONFIG=1; shift ;;
        --merge-config-from) need_arg "$@"; MERGE_CONFIG=1; MERGE_CONFIG_SRC="$2"; shift 2 ;;
        -c|--continue)   RESUME_MODE="continue"; shift ;;
        -r|--resume)     RESUME_MODE="picker"; shift
          # Optional session id: --resume <id> targets a specific session
          # directly instead of opening the picker. Ids never start with '-'.
          if [ $# -gt 0 ] && [[ "$1" != -* ]]; then RESUME_ARG="$1"; shift; fi ;;
        -h|--help)       usage ;;
        --)              shift; TOOL_ARGS=("$@"); break ;;
        /*)              # A bare absolute path here is almost always a
                         # second mount written without its flag
                         # (`--mount /a /b`), and forwarding it would hand
                         # the tool a prompt consisting of a path - a wasted
                         # session the operator only notices once the agent
                         # starts answering it. Refuse instead; `--` is the
                         # escape hatch for the rare tool that really does
                         # take a bare path.
                         err "unexpected bare path argument: $1"
                         hint "to mount it:  --mount $1"
                         hint "to pass it to ${name} anyway, put it after --"
                         exit 1 ;;
        *)               # Anything else we don't recognize isn't necessarily
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
      die "--overlay-workspace needs --git full (limited/none already isolate the host tree)"
    fi
    if [ "$DRYRUN" = "1" ] && [ "$SELFTEST" = "1" ]; then
      die "--dry-run and --selftest are mutually exclusive (--selftest really runs the sandbox)"
    fi

    # Jail-private tool state, fully separate from the host tool's own
    # config dir - never the host tool's real config. Resolved before the
    # git safety net below so the listing modes, which want nothing but this
    # path, can answer and exit without taking a snapshot of the workspace
    # or touching it at all.
    if [ -z "$STATE_ROOT" ]; then
      STATE_ROOT="''${XDG_CONFIG_HOME:-$HOME/.config}/llm-custody"
    fi
    STATE_DIR="$STATE_ROOT/${name}/$PROFILE"

    # --list-profiles: every profile dir that exists for this tool, with the
    # one the current flags would select marked. Sessions are counted rather
    # than listed; --list-sessions is the detailed view.
    if [ "$LIST_PROFILES" = "1" ]; then
      TOOL_ROOT="$STATE_ROOT/${name}"
      if [ ! -d "$TOOL_ROOT" ]; then
        log "no profiles yet for ${name} (state root: $STATE_ROOT)"
        exit 0
      fi
      log "profiles for ${name} under $TOOL_ROOT:"
      shopt -s nullglob
      for entry in "$TOOL_ROOT"/*; do
        [ -d "$entry" ] || continue
        pname="''${entry##*/}"
        scount=0
        if [ -d "$entry/$SESSIONS_SUBDIR" ]; then
          shopt -s globstar
          for s in "$entry/$SESSIONS_SUBDIR"/**/*.jsonl; do
            [ -f "$s" ] && scount=$((scount+1))
          done
          shopt -u globstar
        fi
        marker="  "
        [ "$pname" = "$PROFILE" ] && marker="''${C_GREEN}* ''${C_RESET}"
        printf '%s%s%s%s (%s session(s))\n' "$marker" "$C_BOLD" "$pname" "$C_RESET" "$scount" >&2
      done
      shopt -u nullglob
      exit 0
    fi

    # --list-sessions: the jail-private transcripts of this profile. Host
    # sessions of the same tool are deliberately invisible here, exactly as
    # they are to --resume: the state dirs are separate on purpose.
    if [ "$LIST_SESSIONS" = "1" ]; then
      SESSIONS_ROOT="$STATE_DIR/$SESSIONS_SUBDIR"
      if [ ! -d "$SESSIONS_ROOT" ]; then
        log "no sessions yet in profile '$PROFILE' ($SESSIONS_ROOT)"
        exit 0
      fi
      log "sessions in profile '$PROFILE' ($SESSIONS_ROOT), newest first:"
      shopt -s nullglob globstar
      # -t sorts by mtime; the paths are passed in one batch so the ordering
      # is across all projects, not per project.
      SESSION_FILES=("$SESSIONS_ROOT"/**/*.jsonl)
      shopt -u nullglob globstar
      if [ "''${#SESSION_FILES[@]}" -eq 0 ]; then
        log "none found"
        exit 0
      fi
      # stat+sort rather than `ls -lt`: the mtime is wanted as a sort key,
      # and parsing it back out of an ls listing is both fragile and the
      # thing SC2012 exists to flag.
      while read -r ts size path; do
        printf '  %s%s%s  %7s  %s\n' \
          "$C_DIM" "$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$ts")" "$C_RESET" \
          "$size" "''${path#"$SESSIONS_ROOT"/}" >&2
      done < <(stat -c '%Y %s %n' "''${SESSION_FILES[@]}" 2>/dev/null | sort -rn)
      exit 0
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
    if [ "$DRYRUN" != "1" ] && [ -d "$WORKSPACE_HOST/.git" ] && command -v git >/dev/null 2>&1; then
      GIT_SAFETY=1
      PRE_HOOKSPATH=$(git -C "$WORKSPACE_HOST" config --get core.hooksPath 2>/dev/null || true)
      # `stash create` only parks a dangling commit object (and prints its
      # hash) - unlike `stash push`/`store` it never touches the working
      # tree or the visible stash list, so it's a free recovery point for
      # tracked-file damage. Doesn't cover untracked files or a plain
      # `rm -rf` of the tree.
      if SNAPSHOT=$(git -C "$WORKSPACE_HOST" stash create 2>/dev/null) && [ -n "$SNAPSHOT" ]; then
        log "safety snapshot of tracked changes: $SNAPSHOT"
        hint "git show $SNAPSHOT to inspect, git stash apply $SNAPSHOT to restore"
      fi
    fi

    [ "$DRYRUN" = "1" ] || mkdir -p "$STATE_DIR"

    # Operator-managed package profile, shared across tools and profiles like
    # the domains file next to it - a tool provisioned once is wanted
    # everywhere, and nothing in it is session state. Nothing inside the
    # sandbox can realize a derivation (read-only store, no binary cache in
    # the whitelist), so this is the only way a tool the host does not already
    # have on PATH gets in.
    if [ -z "$TOOLBOX_DIR" ]; then
      TOOLBOX_DIR="$STATE_ROOT/toolbox"
    fi

    # nix writes the profile as `profile -> profile-N-link`, and whether that
    # hop is relative or absolute is nix's business - an absolute one names a
    # host path the sandbox does not have. `current` short-circuits it to the
    # resolved /nix/store profile, which resolves identically inside the jail
    # because the store is bound wholesale. Refreshed here as well as by
    # llm-custody-toolbox, so a profile edited with plain `nix profile`
    # commands is still picked up at the next launch.
    toolbox_refresh() {
      local real
      [ -L "$TOOLBOX_DIR/${toolbox.profileLink}" ] || return 0
      real=$(readlink -f "$TOOLBOX_DIR/${toolbox.profileLink}" 2>/dev/null) || return 0
      case "$real" in
        /nix/store/*) ln -sfn "$real" "$TOOLBOX_DIR/${toolbox.currentLink}" ;;
        *) warn "toolbox profile resolves to $real, outside /nix/store - invisible inside the jail" ;;
      esac
    }
    if [ "$DRYRUN" != "1" ]; then
      mkdir -p "$TOOLBOX_DIR"
      toolbox_refresh
    fi

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

    # Wrapped in a function rather than run inline so --dry-run can skip it:
    # the bootstrap writes real files into $STATE_DIR (settings.json, the
    # memory file), and a dry run is supposed to resolve the sandbox without
    # changing anything on the host.
    run_bootstrap() {
      # bootstrapScript is optional (tools.nix), and an empty function body
      # is a bash syntax error - this `:` is what keeps such a tool building.
      :
      ${launcherOut.bootstrapScript}
    }
    [ "$DRYRUN" = "1" ] || run_bootstrap

    if [ ! -d "$LLMCUSTODY_TMPDIR" ]; then
      die "tmpdir '$LLMCUSTODY_TMPDIR' does not exist"
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
        die "--merge-config source not readable: $SRC"
      fi
      if ! jq -e . "$SRC" >/dev/null 2>&1; then
        die "--merge-config source is not valid JSON: $SRC"
      fi
      if [ ! -t 0 ]; then
        die "--merge-config prompts per key on stdin; needs a tty"
      fi
      MERGE_DOC="$RUNDIR/merge.json"
      if [ -f "$TARGET" ]; then
        cp "$TARGET" "$MERGE_DOC"
      else
        echo '{}' > "$MERGE_DOC"
      fi
      MERGE_ALL=0
      MERGED=0
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
          log "merge key $C_BOLD$key$C_RESET from $(basename "$SRC"):"
          printf '%s\n' "$(jq -r --arg k "$key" '.[$k]' "$SRC")" | while IFS= read -r line; do printf '    %s\n' "$line"; done >&2
          printf '%sAccept this value?%s [y/N/a] ' "$C_BOLD" "$C_RESET" >&2
          # EOF on the tty (Ctrl-D) aborts the whole merge - and the launch -
          # rather than answering 'no' silently; target stays unmodified.
          read -r ans || die "--merge-config aborted (no answer)"
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
        log "--merge-config: merged $MERGED key(s) into $TARGET"
      else
        log "--merge-config: nothing changed (jail settings already match)"
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
    TOOLBOX_REG=""
    USERVAR_SET=0
    TITLE_SET=0
    # Set right before handing control to the tool. The exit summary keys off
    # it so a run that failed during setup (bad flag, missing tmpdir) doesn't
    # report a session duration for a session that never started.
    LAUNCHED=0
    # --sync-exclude globs, as ready-made arguments for the sync-back helper.
    # Built once here because the exit trap and the $RUNDIR/sync launcher
    # both need the same list.
    SYNC_EXCLUDE_ARGS=()
    for glob in "''${SYNC_EXCLUDES[@]+"''${SYNC_EXCLUDES[@]}"}"; do
      SYNC_EXCLUDE_ARGS+=(--exclude "$glob")
    done
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
    DIRTY_PID=""

    # Publish per-run facts as WezTerm user vars, so the terminal config can
    # act on them: llm_custody_sync carries this run's mid-session sync
    # command (a keybinding can fire it via
    # pane:get_user_vars().llm_custody_sync instead of the operator having
    # to catch - and keep - the path printed at launch), llm_custody_jail
    # carries the jail marker plus tool name for the tab title. Written
    # straight to the terminal device so they never end up in a redirected
    # stdout, and wrapped in tmux's DCS passthrough when there is a tmux
    # between us and the terminal. Empty value = session gone.
    emit_uservar() {
      local var="$1" value="$2" b64 seq
      b64=$(printf '%s' "$value" | base64 -w0)
      seq=$(printf '\033]1337;SetUserVar=%s=%s\007' "$var" "$b64")
      if [ -n "''${TMUX:-}" ]; then
        # DCS passthrough: ESC P tmux; <payload, every ESC doubled> ESC \.
        # The payload's only ESC is its leading one, hence the single extra
        # \033 ahead of %s. \134 is the closing backslash in octal - a
        # literal one right before the quote reads as a quote escape.
        seq=$(printf '\033Ptmux;\033%s\033\134' "$seq")
      fi
      printf '%s' "$seq" > /dev/tty 2>/dev/null || true
    }

    # ▥ marks the window as jailed at a glance. The jailed tool sets its own
    # OSC 2 title during the session and will overwrite this one, which is
    # why the same marker also goes out as a user var above - a terminal
    # config can prepend it durably, where a title we set once cannot
    # survive. Sent anyway for terminals with no such config: it is at least
    # correct until the tool's first title update.
    # One column wide (U+25A5 is East Asian Ambiguous, which terminals
    # render narrow by default), so a consumer putting this in a tab bar
    # pays one cell rather than the two a fullwidth glyph costs.
    JAIL_MARK="▥"
    set_title() {
      printf '\033]2;%s\007' "$1" > /dev/tty 2>/dev/null || true
    }

    # Whether this terminal gets user vars at all. Decided once, here,
    # because three separate places emit them (the sync path at setup, the
    # jail marker at launch, the dirty counter during the session) and they
    # must agree. Automatic only when WezTerm is detected, since terminals
    # that do not know the sequence may print it instead of consuming it;
    # LLMCUSTODY_USERVAR=1/0 forces the decision either way.
    USERVAR_ON=0
    case "''${LLMCUSTODY_USERVAR:-auto}" in
      0|off|no) ;;
      1|on|yes) USERVAR_ON=1 ;;
      *)
        if [ -n "''${WEZTERM_PANE:-}" ] || [ "''${TERM_PROGRAM:-}" = "WezTerm" ]; then
          USERVAR_ON=1
        fi ;;
    esac

    # What the sandbox tried to reach and didn't get. Both halves have to be
    # collected before cleanup() kills the holder: the nftables counter
    # lives in that namespace, and the dnsmasq log is under $RUNDIR, which
    # the same function removes.
    #
    # This is the one piece of feedback a blocked agent otherwise never
    # produces: a request to a non-whitelisted domain just fails somewhere
    # inside the tool, with no indication that the jail is why.
    DROPPED_PACKETS=0
    BLOCKED_DOMAINS=""
    collect_net_stats() {
      local line n dom ip
      [ "$NET_FILTER" = "1" ] || return 0
      if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
        while IFS= read -r line; do
          case "$line" in
            *"counter packets "*)
              n="''${line##*counter packets }"
              n="''${n%% *}"
              case "$n" in ""|*[!0-9]*) continue ;; esac
              DROPPED_PACKETS=$((DROPPED_PACKETS+n)) ;;
          esac
        done < <(nsenter_holder nft list chain inet filter output 2>/dev/null || true)
      fi
      if [ -f "$RUNDIR/dnsmasq.log" ]; then
        # dnsmasq logs its own answer as "<source> <name> is <address>", so
        # a name that landed on the address=/#/ catch-all reads as
        # "... is 0.0.0.0" / "... is ::". Parsed from the right, like the
        # whitelist watcher does, because the log line also carries a
        # timestamp and a pid prefix.
        # `|| true` on the whole pipeline: this runs first thing in the exit
        # trap with errexit active, and `head` closing the pipe early would
        # otherwise abort cleanup before the sync-back below ever runs.
        BLOCKED_DOMAINS=$(
          { while IFS= read -r line; do
            case "$line" in
              *" is "*) ;;
              *) continue ;;
            esac
            ip="''${line##* is }"
            case "$ip" in
              0.0.0.0|::) ;;
              *) continue ;;
            esac
            dom="''${line% is *}"
            dom="''${dom##* }"
            [ -n "$dom" ] && printf '%s\n' "$dom"
          done < "$RUNDIR/dnsmasq.log" | sort -u | head -n 20; } || true
        )
      fi
    }

    cleanup() {
      local status=$?
      # First, so the watcher cannot emit a stale count over the top of the
      # clearing emission further down, or run its git against trees the
      # sync-back is in the middle of.
      [ -n "$DIRTY_PID" ] && kill "$DIRTY_PID" 2>/dev/null || true
      collect_net_stats
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
          ${syncBack} --prompt "''${SYNC_EXCLUDE_ARGS[@]+"''${SYNC_EXCLUDE_ARGS[@]}"}" "$SYNC_MANIFEST" || true
        else
          ${syncBack} --auto "''${SYNC_EXCLUDE_ARGS[@]+"''${SYNC_EXCLUDE_ARGS[@]}"}" "$SYNC_MANIFEST" || true
        fi
      fi

      # Session is over: drop the mid-session sync handles so nothing points
      # at a $RUNDIR that is about to disappear.
      if [ "$USERVAR_SET" = "1" ]; then
        emit_uservar llm_custody_sync ""
        emit_uservar llm_custody_jail ""
        emit_uservar llm_custody_dirty ""
        emit_uservar llm_custody_toolbox ""
        emit_uservar llm_custody_toolbox_cmd ""
      fi
      if [ -n "$SYNC_REG" ]; then
        rm -f "$SYNC_REG"
        if [ "$(readlink "$(dirname "$SYNC_REG")/current" 2>/dev/null || true)" = "$RUNDIR/sync" ]; then
          rm -f "$(dirname "$SYNC_REG")/current"
        fi
      fi
      # The `current.toolbox` pointer only belongs to this run while it still
      # names this run's directory - a session started later has already
      # claimed it, and removing it then would strand that one.
      if [ -n "$TOOLBOX_REG" ]; then
        rm -f "$TOOLBOX_REG"
        if [ "$(readlink "$(dirname "$TOOLBOX_REG")/current.toolbox" 2>/dev/null || true)" = "$TOOLBOX_DIR" ]; then
          rm -f "$(dirname "$TOOLBOX_REG")/current.toolbox"
        fi
      fi

      rm -rf "$RUNDIR"

      if [ "$GIT_SAFETY" = "1" ]; then
        POST_HOOKSPATH=$(git -C "$WORKSPACE_HOST" config --get core.hooksPath 2>/dev/null || true)
        if [ "$POST_HOOKSPATH" != "$PRE_HOOKSPATH" ]; then
          warn "core.hooksPath in $WORKSPACE_HOST/.git/config changed during this run"
          hint "(was: [''${PRE_HOOKSPATH:-unset}], now: [''${POST_HOOKSPATH:-unset}])"
          hint "plain git run outside the jail on this repo will honor whatever it points to now - review before trusting it."
        fi
      fi

      # Exit summary, last so it isn't buried under the sync prompts above.
      # Only the parts that have something to say are printed: a short,
      # uneventful run ends with one line about how long it took.
      if [ "$LAUNCHED" = "1" ] && [ "$VERBOSITY" -ge 1 ]; then
        printf '%s%s session ended after %dm%02ds%s\n' \
          "$C_DIM" "$JAIL_MARK" "$((SECONDS / 60))" "$((SECONDS % 60))" "$C_RESET" >&2
        if [ -n "$BLOCKED_DOMAINS" ]; then
          warn "the sandbox tried to reach domains that are not whitelisted:"
          while IFS= read -r d; do
            [ -n "$d" ] && hint "$d"
          done <<< "$BLOCKED_DOMAINS"
          hint "allow one with --allow-domain DOMAIN, or permanently via $STATE_ROOT/domains"
        fi
        if [ "$DROPPED_PACKETS" -gt 0 ]; then
          warn "$DROPPED_PACKETS packet(s) dropped by the IP gate (connections to addresses no whitelisted lookup returned)"
        fi
      fi

      # The tool owned the title for the whole session; hand it back rather
      # than leaving the jail marker on a window that is no longer jailed.
      # $SHELL is only a default - a terminal that writes its own title on
      # every prompt overwrites this immediately anyway.
      if [ "$TITLE_SET" = "1" ]; then
        TITLE_RESTORE="''${SHELL:-sh}"
        set_title "''${TITLE_RESTORE##*/}"
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
        err "--overlay-workspace is not usable on this host:"
        # Indented read loop rather than sed: everything else in this script
        # sticks to coreutils/bash builtins that runtimeInputs guarantees.
        while IFS= read -r line; do hint "$line"; done < "$RUNDIR/overlay-probe.log"
        hint "Unprivileged overlayfs needs kernel >= 5.11, and the upper layer must sit"
        hint "on a filesystem with user xattr support (tmpfs: kernel >= 6.6)."
        hint "Point --tmpdir at a disk-backed directory, or drop --overlay-workspace."
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
      log "--mask: removed $count path(s) from $label"
      while IFS= read -r line; do hint "$line"; done <<< "$removed"
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
      log "--mask: shadowed ''${#matches[@]} path(s) in $label with empty binds"
      if [ -d "$hostroot/.git" ]; then
        warn "$label is bound along with its .git, so masked content is still"
        hint "readable from history (git show HEAD:<path>). Only a copy (--mount"
        hint "under --git limited|none) removes it outright."
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
        die "--git $GIT_MODE needs git on the host (it records the baseline used for sync-back)"
      fi
      WORKSPACE_COPY="$RUNDIR/workspace"
      TRACK_GIT="$RUNDIR/track.git"
      WORKSPACE_BIND="$WORKSPACE_COPY"
      if [ "$DRYRUN" = "1" ]; then
        # A dry run resolves paths but copies nothing: on a large repo the
        # copy is the slowest part of a launch, and reproducing it would
        # make the one mode meant for a quick look the expensive one.
        log "--git $GIT_MODE would copy $WORKSPACE_HOST into $RUNDIR (not done for --dry-run)"
      else
        log "--git $GIT_MODE - copying the working tree into $RUNDIR (history stays on the host)"
        jail_copy_tree "$WORKSPACE_HOST" "$WORKSPACE_COPY"

        jail_apply_masks "$WORKSPACE_COPY" "the workspace copy"

        if [ "$GIT_MODE" = "limited" ] && [ -d "$WORKSPACE_HOST/.git" ]; then
          jail_init_repo "$WORKSPACE_COPY" "$WORKSPACE_HOST" "jail repo"
        elif [ "$GIT_MODE" = "limited" ]; then
          log "workspace is not a git repo - jail gets a plain copy"
        fi

        jail_track_init "$WORKSPACE_COPY" "$TRACK_GIT"
        SYNC_ENTRIES+=("$(printf 'copy\t%s\t%s\t%s\t%s' "$WORKSPACE_COPY" "$TRACK_GIT" "$WORKSPACE_HOST" "jail workspace")")
      fi
    fi

    nsenter_holder() {
      nsenter -U -n -t "$HOLDER_PID" --preserve-credentials -- "$@"
    }

    # Host preflight. Nothing here is NixOS-specific support (anything else
    # is unsupported), but both conditions produce a bwrap failure whose own
    # message says nothing about the cause, so one line of warning here
    # saves the search. Warnings, not errors: a kernel may well allow what
    # these files claim it doesn't, and refusing to start on a guess would
    # be worse than a launch that fails a second later with bwrap's own
    # message right under this one.
    if [ -r /proc/sys/kernel/unprivileged_userns_clone ] &&
       [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = "0" ]; then
      warn "kernel.unprivileged_userns_clone=0 - bwrap cannot create a user namespace"
      hint "sysctl -w kernel.unprivileged_userns_clone=1 (as root) to allow it"
    fi
    if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] &&
       [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
      warn "AppArmor restricts unprivileged user namespaces on this host (Ubuntu 24.04 default)"
      hint "sysctl -w kernel.apparmor_restrict_unprivileged_userns=0, or install an AppArmor profile for bwrap"
    fi
    if [ ! -e /run/current-system/sw ]; then
      vlog "no /run/current-system - this does not look like NixOS, which is the only supported host"
    fi

    # Auto-extract domains from base URL env vars, same as the old QEMU
    # runner - otherwise a custom API endpoint's traffic would be forwarded
    # but never whitelisted, silently breaking on the network filter instead
    # of just working. Outside the net-filter block below so --dry-run
    # reports the same domain list a real run would use.
    for var in ANTHROPIC_BASE_URL OPENAI_BASE_URL; do
      val="''${!var:-}"
      if [ -n "$val" ]; then
        domain="''${val#*://}"
        domain="''${domain%%/*}"
        domain="''${domain%%:*}"
        [ -n "$domain" ] && EXTRA_DOMAINS+=("$domain")
      fi
    done

    if [ "$NET_FILTER" = "1" ] && [ "$DRYRUN" != "1" ]; then
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
        err "newuidmap/newgidmap not found - required for network filtering."
        hint "(NixOS: enabled by any rootless-container feature, e.g. Incus; see /etc/subuid)"
        exit 1
      fi
      vlog "starting private network namespace"
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
      #
      # --ready-fd makes slirp4netns announce completion instead of being
      # waited out: it writes one byte to the fd once tap0 and the routes
      # are configured. The fixed sleep this replaces was a guess that held
      # on an idle laptop and not on a loaded one, where dnsmasq would bind
      # before the interface existed.
      #
      # A regular file, not a fifo. The byte written is a bare "1" with no
      # newline, so a `read` waiting for a line never completes on it - the
      # status would report failure on a slirp4netns that worked perfectly.
      # Polling a file sidesteps that and the fifo's blocking-open rendezvous
      # at the same time, and matches how dnsmasq is waited for just below.
      : > "$RUNDIR/slirp-ready"
      slirp4netns --configure --mtu=65520 --disable-host-loopback --disable-dns \
        --enable-ipv6 --ready-fd=3 "$HOLDER_PID" tap0 \
        >"$RUNDIR/slirp4netns.log" 2>&1 3>>"$RUNDIR/slirp-ready" &
      SLIRP_PID=$!
      SLIRP_READY=0
      for _ in $(seq 1 500); do
        if [ -s "$RUNDIR/slirp-ready" ]; then SLIRP_READY=1; break; fi
        # Nothing to wait for if it already died; its log has the reason and
        # the next step fails on its own terms.
        kill -0 "$SLIRP_PID" 2>/dev/null || break
        sleep 0.02
      done
      if [ "$SLIRP_READY" = "1" ]; then
        vlog "slirp4netns reported tap0 configured"
      else
        warn "slirp4netns did not report ready within 10s - continuing anyway"
        hint "see $RUNDIR/slirp4netns.log"
      fi

      # The one resolver allowed out of the namespace. Named rather than
      # repeated because the nftables ruleset below pins DNS to exactly this
      # address, and the two drifting apart would break every lookup.
      UPSTREAM_DNS="9.9.9.9"

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
          echo "server=/$d/$UPSTREAM_DNS"
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
      # dnsmasq writes its pid file once it has bound its listening address,
      # which is the point the pre-resolve below can start querying it. Poll
      # for it instead of sleeping a guessed interval; bail out early if the
      # process died, so the failure surfaces as its own error rather than
      # as a timeout.
      for _ in $(seq 1 100); do
        [ -s "$RUNDIR/dnsmasq.pid" ] && break
        kill -0 "$DNSMASQ_PID" 2>/dev/null || break
        sleep 0.02
      done

      # Sets first, chain further down. The pre-resolve step between the two
      # has to reach a resolver, and on a host whose /etc/resolv.conf points
      # at something other than loopback that query leaves the namespace -
      # which the chain's drop policy would block. With no base chain in the
      # table yet, nothing is filtered, so the pre-resolve runs before the
      # policy exists and the sandbox still never sees an unfiltered moment
      # (it starts long after).
      #
      # ip daddr only ever matches IPv4 packets, even inside a dual-stack
      # inet-family table - it's simply not-applicable (not "false") for an
      # IPv6 packet, so a v6-unaware ruleset here wouldn't just fail to
      # filter v6 traffic, it would silently let it all through. Hence the
      # separate ipv6_addr set and ip6 daddr rule, not just one shared set.
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
      #
      # `getent ahosts`, not the ahostsv4/ahostsv6 pair this used to call:
      # those two return rc=2 and print nothing on this glibc even for names
      # that plainly resolve (the same quirk lib/selftest.nix documents),
      # which made the whole pre-resolve a silent no-op and left the race it
      # exists to close wide open. `ahosts` returns both families in one
      # listing, so the family is decided by looking at the address.
      if command -v getent >/dev/null 2>&1; then
        PREARMED=0
        for d in "''${ALLOWED_DOMAINS[@]}" "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          while read -r line; do
            ip="''${line%% *}"
            case "$ip" in
              ""|0.0.0.0|::) continue ;;
              *:*)
                case "$ip" in *[!0-9a-fA-F:]*) continue ;; esac
                nsenter_holder nft add element inet filter allowed6 "{ $ip }" 2>/dev/null || true ;;
              *[!0-9.]*) continue ;;
              *)
                nsenter_holder nft add element inet filter allowed "{ $ip }" 2>/dev/null || true ;;
            esac
            PREARMED=$((PREARMED+1))
          done < <(nsenter_holder getent ahosts "$d" 2>/dev/null)
        done
        vlog "pre-armed the IP whitelist with $PREARMED address(es)"
      fi

      # Policy drop, with the whitelisted addresses as the only general exit.
      # The earlier ruleset gated TCP 80/443 only, which left every other
      # port - and UDP 443, i.e. HTTP/3 - reaching any address at all under
      # an accept policy. Gating on the address rather than on a port list
      # also means the whitelist covers protocols nobody enumerated: git over
      # ssh to an allowed host works, a QUIC connection to a hardcoded
      # address does not.
      #
      # DNS is pinned to the one upstream dnsmasq forwards to. The sandbox's
      # own resolver is 127.0.0.1 (covered by the loopback rule), so an
      # outbound query to anything else is either a misconfiguration or a
      # DNS tunnel, and neither should leave.
      #
      # ICMP stays open in both families because IPv6 neighbour discovery
      # rides on it - dropping it breaks v6 on the tap link entirely.
      # Unquoted heredoc so $UPSTREAM_DNS expands; the ruleset itself has no
      # other shell metacharacters.
      nsenter_holder nft -f - <<NFT
    table inet filter {
      chain output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        meta l4proto { icmp, ipv6-icmp } accept
        ip daddr $UPSTREAM_DNS udp dport 53 accept
        ip daddr $UPSTREAM_DNS tcp dport 53 accept
        ip daddr @allowed accept
        ip6 daddr @allowed6 accept
        counter drop
      }
    }
    NFT

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

    # The operator's toolbox, ahead of the host profiles: a package put here
    # is a deliberate addition (often a newer or patched build of something
    # the host also has), and it would be pointless if the host copy shadowed
    # it. Still behind the git wrapper below, which has to stay first.
    #
    # Bound even when empty, because the bind is what makes a mid-session
    # addition work: `current` is retargeted on the host and the already-bound
    # directory shows the new target immediately. Read-only - a writable one
    # would hand the agent the front of its own PATH.
    BWRAP_ARGS+=(--ro-bind "$TOOLBOX_DIR" ${toolbox.guestDir})
    JAIL_PATH="${toolbox.binDir}:$JAIL_PATH"

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
        warn "git resolves to $REAL_GIT_RESOLVED, not visible inside the jail (needs /nix/store or a bound /usr/bin) - skipping in-jail git hooks shadow"
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
        warn "skills are read-write; an in-jail agent can modify ~/.claude/skills content that the host reads (and skillissue may push)."
        hint "Only continue if in-jail skill maintenance is intended."
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
        die "--env expects KEY=VAL, got: $spec"
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
        die "mount path does not exist: $hostpath"
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
              err "cannot derive a mount target from '$hostpath'"
              hint "pass one explicitly: --mount $hostpath:$WORKSPACE_ROOT/<name>"
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
          err "two mounts resolve to the same jail path: $guestpath"
          hint "already taken by: ''${MOUNT_SOURCES[$i]}"
          hint "conflicting with: $hostpath"
          hint "give one an explicit target, e.g. --mount $hostpath:$WORKSPACE_ROOT/<other-name>"
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
          warn "--mount $hostpath is a file - bound directly, writes hit the host immediately"
        fi
        BWRAP_ARGS+=(--bind "$hostpath" "$guestpath")
        continue
      fi
      if [ "$GIT_MODE" != "full" ]; then
        mount_copy="$RUNDIR/mounts/$MOUNT_INDEX"
        mount_track="$RUNDIR/mounts/$MOUNT_INDEX.git"
        if [ "$DRYRUN" = "1" ]; then
          log "--git $GIT_MODE would copy $hostpath into $RUNDIR (not done for --dry-run)"
        else
          log "--git $GIT_MODE - copying $hostpath into $RUNDIR (history stays on the host)"
          jail_copy_tree "$hostpath" "$mount_copy"
          jail_apply_masks "$mount_copy" "the copy of $hostpath"
          if [ "$GIT_MODE" = "limited" ] && [ -d "$hostpath/.git" ]; then
            jail_init_repo "$mount_copy" "$hostpath" "jail repo for $guestpath"
          fi
          jail_track_init "$mount_copy" "$mount_track"
          SYNC_ENTRIES+=("$(printf 'copy\t%s\t%s\t%s\t%s' "$mount_copy" "$mount_track" "$hostpath" "mount $guestpath")")
        fi
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
        die "(selftest) tool binary not found: ${toolExe}"
      fi
      log "selftest: toolExe=${toolExe}"
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

    # How many paths the jail has changed but not yet synced, across every
    # isolated tree in the manifest. Same two sources the sync-back itself
    # reads, so the number here and the number it reports agree.
    #
    # --no-optional-locks because this runs concurrently with a possible
    # mid-session $RUNDIR/sync: plain `git status` may refresh (and so lock)
    # the index, which would collide with that sync's own `git add`. The
    # flag is exactly for status-reporting callers like this one.
    jail_dirty_count() {
      local type src track n total=0
      [ -n "$SYNC_MANIFEST" ] && [ -f "$SYNC_MANIFEST" ] || { printf '0'; return 0; }
      # The manifest's host-tree and label columns are the sync-back's
      # business, not this counter's - read into one throwaway so the two
      # fields it does need stay aligned with the format.
      while IFS=$'\t' read -r type src track _; do
        n=0
        case "$type" in
          copy)
            [ -d "$src" ] && [ -d "$track" ] || continue
            n=$(GIT_DIR="$track" GIT_WORK_TREE="$src" git --no-optional-locks \
                  status --porcelain --untracked-files=all 2>/dev/null | wc -l) || n=0 ;;
          overlay)
            # An overlay upper layer holds only what was written, so every
            # entry in it is by definition an unsynced change. Plain
            # directories are skipped: overlayfs materializes a directory
            # just to hold a changed file below it, so counting them would
            # inflate the number against the per-path count a copy reports.
            # Symlinks and whiteouts (char devices) do count.
            [ -d "$src" ] || continue
            n=$(
              cd "$src" 2>/dev/null || exit 0
              shopt -s globstar dotglob nullglob
              c=0
              for e in **/*; do
                [ -d "$e" ] && [ ! -L "$e" ] && continue
                c=$((c + 1))
              done
              printf '%s' "$c"
            ) || n=0 ;;
          *) continue ;;
        esac
        case "$n" in ""|*[!0-9]*) n=0 ;; esac
        total=$((total + n))
      done < "$SYNC_MANIFEST"
      printf '%s' "$total"
    }

    # Background poller feeding the indicator. Only emits on a *change*, so
    # a long session writes a handful of escape sequences rather than one
    # every interval - the jailed tool owns the terminal while this runs,
    # and a write landing inside one of its own sequences would corrupt a
    # frame.
    start_dirty_watcher() {
      local last="" now
      while :; do
        now=$(jail_dirty_count 2>/dev/null) || now=""
        if [ -n "$now" ] && [ "$now" != "$last" ]; then
          printf '%s\n' "$now" > "$RUNDIR/dirty.tmp" 2>/dev/null &&
            mv -f "$RUNDIR/dirty.tmp" "$RUNDIR/dirty" 2>/dev/null || true
          if [ "$USERVAR_ON" = "1" ]; then
            # Empty, not "0", when clean: a consumer can then test the var
            # for emptiness exactly like the other two.
            if [ "$now" = "0" ]; then
              emit_uservar llm_custody_dirty ""
            else
              emit_uservar llm_custody_dirty "$now"
            fi
          fi
          last="$now"
        fi
        sleep "$WATCH_INTERVAL"
      done
    }

    # Where a second terminal (or a terminal keybinding) looks up what this
    # session exposes, without having been told the state dir or the rundir:
    # <pid>.sync and <pid>.toolbox, plus a `current`/`current.toolbox` pair
    # naming the most recently started run. Shared by the toolbox block below
    # and the sync block after it.
    REG_DIR="''${XDG_RUNTIME_DIR:-$LLMCUSTODY_TMPDIR}/llm-custody"

    # Toolbox handle. Registered unconditionally, unlike the sync launcher -
    # every run has a toolbox, including the ones with nothing to sync back
    # (--git full), and answering an agent's package request is exactly the
    # case where the operator is in another terminal with no idea which
    # --state-dir this session used.
    if [ "$DRYRUN" != "1" ]; then
      mkdir -p "$REG_DIR"
      TOOLBOX_REG="$REG_DIR/$$.toolbox"
      ln -sfn "$TOOLBOX_DIR" "$TOOLBOX_REG"
      ln -sfn "$TOOLBOX_DIR" "$REG_DIR/current.toolbox"
      vlog "toolbox: $TOOLBOX_DIR -> ${toolbox.guestDir} (${toolboxCli} add PKG)"
      if [ "$USERVAR_ON" = "1" ]; then
        emit_uservar llm_custody_toolbox "$TOOLBOX_DIR"
        # The CLI's own store path alongside the directory: a consumer of the
        # var above still has to *run* something, and with `nix run` there is
        # no llm-custody-toolbox on PATH to run. The store path always works.
        emit_uservar llm_custody_toolbox_cmd "${toolboxCli}"
        USERVAR_SET=1
      fi
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
      # %q on the manifest path and on every exclude glob: $RUNDIR inherits
      # --tmpdir, which may well contain a space or a quote, and a glob is
      # by definition full of characters a shell would otherwise act on.
      SYNC_EXCLUDE_LITERAL=""
      for glob in "''${SYNC_EXCLUDES[@]+"''${SYNC_EXCLUDES[@]}"}"; do
        SYNC_EXCLUDE_LITERAL="$SYNC_EXCLUDE_LITERAL --exclude $(printf '%q' "$glob")"
      done
      printf '#!%s\nexec %s --prompt%s %s "$@"\n' \
        "${pkgs.bash}/bin/sh" "${syncBack}" "$SYNC_EXCLUDE_LITERAL" \
        "$(printf '%q' "$SYNC_MANIFEST")" > "$RUNDIR/sync"
      chmod +x "$RUNDIR/sync"

      # Stable handle for anything that wants to find the live session
      # without parsing terminal output: a per-pid symlink plus `current`
      # for the most recent run. Concurrent runs each keep their own pid
      # entry; `current` is simply the latest to start.
      mkdir -p "$REG_DIR"
      SYNC_REG="$REG_DIR/$$.sync"
      ln -sfn "$RUNDIR/sync" "$SYNC_REG"
      ln -sfn "$RUNDIR/sync" "$REG_DIR/current"

      vlog "mid-session sync: $RUNDIR/sync (also $REG_DIR/current, or llm-custody-sync)"

      # Terminals that understand OSC 1337 SetUserVar get the path as a
      # variable too, which is what makes a one-key sync binding possible.
      if [ "$USERVAR_ON" = "1" ]; then
        emit_uservar llm_custody_sync "$RUNDIR/sync"
        USERVAR_SET=1
      fi

      # Unsynced-change indicator. The count of paths the jail has changed
      # but not yet synced goes into $RUNDIR/dirty (atomically renamed, so a
      # reader never catches a half-written file) and, on a change, out as
      # the llm_custody_dirty user var. Without this, a session that has
      # produced work the host has not seen looks exactly like one that has
      # not - and the only moment that difference surfaces today is the
      # prompt at exit, which is late to learn it.
      #
      # The file exists from the start so a consumer polling it does not
      # have to special-case "not there yet".
      if [ "$WATCH_INTERVAL" -gt 0 ]; then
        printf '0\n' > "$RUNDIR/dirty"
        start_dirty_watcher &
        DIRTY_PID=$!
        vlog "watching for unsynced changes every ''${WATCH_INTERVAL}s ($RUNDIR/dirty)"
      fi
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

      ws_line="$WORKSPACE_HOST ''${C_DIM}->''${C_RESET} $WORKSPACE_GUEST"

      case "$GIT_MODE" in
        full)
          if [ "$OVERLAY" = "1" ]; then
            git_line="''${C_YELLOW}full''${C_RESET}, copy-on-write overlay (review before any sync)"
          else
            git_line="''${C_RED}full''${C_RESET}, real tree bound read-write - writes hit the host immediately"
          fi ;;
        limited) git_line="''${C_GREEN}limited''${C_RESET}, baseline-only copy, syncs back on exit" ;;
        none)    git_line="''${C_GREEN}none''${C_RESET}, plain copy with no repo, syncs back on exit" ;;
      esac

      if [ "$NET_FILTER" = "1" ]; then
        net_line="''${C_GREEN}filtered''${C_RESET}, $((''${#ALLOWED_DOMAINS[@]} + ''${#EXTRA_DOMAINS[@]})) domain(s) allowed"
      else
        net_line="''${C_RED}UNFILTERED''${C_RESET} - the sandbox can reach anything"
      fi

      mounts_line="$((''${#MOUNT_TARGETS[@]} - 1)) extra"
      [ "''${#MASK_PATTERNS[@]}" -gt 0 ] && mounts_line="$mounts_line, ''${#MASK_PATTERNS[@]} mask pattern(s)"
      [ "''${#SYNC_EXCLUDES[@]}" -gt 0 ] && mounts_line="$mounts_line, ''${#SYNC_EXCLUDES[@]} sync exclude(s)"

      extras=""
      [ "$DANGEROUS" = "1" ] && extras="$extras ''${C_RED}dangerous''${C_RESET}"
      [ "$RW_SKILLS" = "1" ] && extras="$extras ''${C_YELLOW}rw-skills''${C_RESET}"
      [ "$X11" = "1" ] && extras="$extras ''${C_YELLOW}x11''${C_RESET}"
      [ "$SAME_PATH" = "1" ] && extras="$extras same-path"

      printf '%s┌─ %s%s %s%s %s(%s)%s\n' \
        "$C_DIM" "$C_RESET" "$JAIL_MARK" "$C_BOLD" "${name}" "$C_DIM" "$PROFILE" "$C_RESET" >&2
      card_row workspace "$ws_line"
      card_row repo "$git_line"
      card_row network "$net_line"
      card_row mounts "$mounts_line"
      # Only when it has something in it: an empty toolbox is the normal case
      # and a row saying so on every launch is noise. No nullglob - an
      # unmatched glob stays literal and the -e test rejects it.
      # `if` rather than a `&&` chain: a false test as the last command of the
      # loop body makes the loop itself exit non-zero, which errexit acts on.
      for tb_entry in "$TOOLBOX_DIR/${toolbox.currentLink}/bin"/*; do
        if [ -e "$tb_entry" ]; then tb_count=$((tb_count + 1)); fi
      done
      [ "$tb_count" -gt 0 ] && card_row toolbox "$tb_count command(s) from $TOOLBOX_DIR"
      [ -n "$extras" ] && card_row flags "''${extras# }"
      card_row state "$STATE_DIR"
      printf '%s└─%s\n' "$C_DIM" "$C_RESET" >&2
    }

    if [ "$DRYRUN" = "1" ]; then
      print_card
      log "allowed domains:"
      for d in "''${ALLOWED_DOMAINS[@]}" "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
        hint "$d"
      done
      # One argument per line rather than a reconstructed command line: the
      # point of a dry run is auditing the mounts, and a 60-argument bwrap
      # invocation on one line is exactly what that cannot be read from.
      log "bwrap arguments:"
      for arg in "''${BWRAP_ARGS[@]}"; do
        hint "$arg"
      done
      if [ "''${#TOOL_ARGS[@]}" -gt 0 ]; then
        log "command: ${toolExe} ''${TOOL_ARGS[*]}"
      else
        log "command: ${toolExe}"
      fi
      exit 0
    fi

    [ "$VERBOSITY" -ge 1 ] && print_card

    # The jailed tool takes the title over as soon as it starts, so the
    # marker also goes out as a user var a terminal config can keep in front
    # of whatever the tool sets.
    set_title "$JAIL_MARK ${name}: $WORKSPACE_NAME"
    TITLE_SET=1
    if [ "$USERVAR_ON" = "1" ]; then
      emit_uservar llm_custody_jail "$JAIL_MARK ${name}"
      USERVAR_SET=1
    fi

    # SECONDS is reset here, not at script start, so the duration in the
    # exit summary measures the session rather than the setup that preceded
    # it (a large --git limited copy can take a while, and counting it would
    # misreport how long the agent actually ran).
    SECONDS=0
    LAUNCHED=1
    if [ "$NET_FILTER" = "1" ]; then
      nsenter_holder bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    else
      bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    fi
  '';
}
