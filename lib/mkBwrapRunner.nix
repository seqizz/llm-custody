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
  # Mount controller (lib/mount-ctl.sh): every extra mount goes through it,
  # at launch and while the session runs ($RUNDIR/mount, `llm-custody mount`,
  # the broker's approval of an agent's mount request).
  mountCtl = pkgs.lib.getExe (import ./mount-ctl.nix { inherit pkgs; });
  # Domain controller (lib/domain-ctl.sh): live changes to the network
  # whitelist ($RUNDIR/domain, `llm-custody domain`, the broker's approval of
  # an agent's domain request). Only wired up when the filter is on.
  domainCtl = pkgs.lib.getExe (import ./domain-ctl.nix { inherit pkgs; });
  # Guest path and symlink names of the operator-managed package profile
  # (lib/toolbox.nix), shared with ../toolbox and the launchers.
  toolbox = import ./toolbox.nix;
  # Store path of the host-side CLI, published as a user var so a terminal
  # keybinding can run it without llm-custody being installed on the host at
  # all - `nix run .#pi` is the documented quick start, and it puts nothing on
  # PATH.
  #
  # Deliberately the *unwrapped* binary (lib/toolbox-rs.nix), not the umbrella
  # from lib/umbrella.nix: the umbrella is built from the runners, so a runner
  # referring back to it would be a cycle. Everything this runner and its
  # consumers call (`toolbox`, `request`, `serve`, `custody-request`) is the
  # same binary and behaves identically; only `llm-custody launch` needs the
  # umbrella's LLMCUSTODY_RUNNER_DIR, and nothing here launches a tool.
  custodyCli = pkgs.lib.getExe (import ./toolbox-rs.nix { inherit pkgs; });
  selftestDomain = builtins.head toolDefaults.allowedDomains;
  selftestUnshare = "${pkgs.util-linux}/bin/unshare";
  # Store path, not a bind: /nix/store is bound wholesale, so the probe
  # resolves inside the jail as-is.
  selftestTiocsti = "${import ./tiocsti-probe.nix { inherit pkgs; }}/bin/tiocsti-probe";
  selftestUserns = "${import ./userns-probe.nix { inherit pkgs; }}/bin/userns-probe";
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
    # The subset of EXTRA_DOMAINS read from --state-dir/domains, so the
    # session's whitelist can tag each name with where it came from.
    FILE_DOMAINS=()
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
    # Opt-in resource limits (--max-mem/--max-cpu/--max-pids), applied to a
    # transient systemd user scope around the jail. Empty means no limit.
    MAX_MEM=""
    MAX_CPU=""
    MAX_PIDS=""
    # 0 = warnings and errors only, 1 = normal, 2 = verbose.
    VERBOSITY=1
    DANGEROUS_FLAG="${dangerousFlag}"
    # Root-level settings.json keys --merge-config never offers, because the
    # bootstrapScript owns them or the jail cannot honour them (tools.nix
    # mergeSkipKeys explains each).
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
    # The tool's registry name as a shell variable, for the plain-shell
    # helper files interpolated below, which cannot hold Nix interpolation.
    TOOL_NAME="${name}"
    # Same reason: the name of the toolbox symlink the sandbox resolves
    # through (lib/toolbox.nix currentLink).
    TOOLBOX_CURRENT_LINK="${toolbox.currentLink}"

    # Colours and the log/vlog/warn/err/hint/die helpers everything the
    # runner says about itself goes through, from lib/log.sh, shared with
    # the mount and domain controllers. Interpolated like lib/net-filter.sh
    # further down.
    ${builtins.readFile ./log.sh}

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
                             from the host with 'llm-custody toolbox add PKG',
                             including while a session is running
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
                             Mounts directly under /workspace or /mnt can be
                             detached while the session runs, and more can be
                             attached there: RUNDIR/mount (printed at launch),
                             'llm-custody mount add', or the agent's own
                             custody-request --mount once you approve it.
                             Any other GUESTPATH is fixed for the session.
      --ro-mount HOSTPATH[:GUESTPATH]
                             Extra read-only mount (repeatable). Same GUESTPATH
                             rules as --mount.
      --allow-domain DOMAIN Add domain to network whitelist (repeatable;
                             persistent ones can live in --state-dir/domains).
                             While the session runs: RUNDIR/domain or
                             'llm-custody domain', or the agent's own
                             custody-request --domain once you approve it
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
      --max-mem SIZE        Memory limit for everything inside the jail
                             (SIZE: digits with an optional K, M, G or T
                             suffix). Swap is disabled for the jail too, so
                             the limit cannot be dodged by swapping
      --max-cpu PCT         CPU quota in percent of one core (200 = two cores)
      --max-pids N          Maximum number of tasks (processes and threads).
                             The three limits apply to a systemd user scope
                             holding the jail only; the runner, its network
                             helpers and the sync-back stay outside it. Any
                             of them refuses to launch without a usable
                             systemd user manager and delegated cgroup v2
                             controllers
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
        # The limit values end up as systemd property assignments, so they
        # are held to the plain forms systemd parses the same everywhere.
        # Zero is refused: a zero memory or task limit kills the jail before
        # it starts, which is never what the operator meant.
        --max-mem)
          need_arg "$@"
          [[ "$2" =~ ^0*[1-9][0-9]*[KMGT]?$ ]] ||
            die "--max-mem expects a size like 512M or 8G (suffix K, M, G or T), got: $2"
          MAX_MEM="$2"; shift 2 ;;
        --max-cpu)
          need_arg "$@"
          [[ "$2" =~ ^0*[1-9][0-9]*%?$ ]] ||
            die "--max-cpu expects a percentage of one core like 200 or 200%, got: $2"
          MAX_CPU="''${2%\%}%"; shift 2 ;;
        --max-pids)
          need_arg "$@"
          [[ "$2" =~ ^0*[1-9][0-9]*$ ]] ||
            die "--max-pids expects a positive whole number, got: $2"
          MAX_PIDS="$2"; shift 2 ;;
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

    # --list-profiles and --list-sessions answer and exit here, from
    # lib/list-modes.sh.
    ${builtins.readFile ./list-modes.sh}

    # Resource limits. The jail command runs inside a transient systemd
    # user scope (run_jail puts SCOPE_PREFIX in front of it) whose cgroup
    # carries the limits, so a runaway build or fork bomb in the jail hits
    # the scope and nothing else. The runner, the broker, dnsmasq,
    # slirp4netns and the watchers stay outside on purpose: a limit hit must
    # not take down the helpers, and the sync-back at exit runs from the
    # runner, unaffected by whatever the scope did.
    #
    # MemoryMax is charged for every page the jail's processes own,
    # including tmpfs pages they write: the copies this runner makes under
    # --tmpdir at launch are charged to the runner, but whatever the agent
    # writes into a tmpfs-backed workspace copy afterwards counts against
    # the jail. MemorySwapMax=0 keeps the limit from being dodged by
    # swapping out.
    LIMIT_PROPS=()
    LIMITS_DESC=""
    if [ -n "$MAX_MEM" ]; then
      LIMIT_PROPS+=(-p "MemoryMax=$MAX_MEM" -p MemorySwapMax=0)
      LIMITS_DESC="$LIMITS_DESC mem=$MAX_MEM"
    fi
    if [ -n "$MAX_CPU" ]; then
      LIMIT_PROPS+=(-p "CPUQuota=$MAX_CPU")
      LIMITS_DESC="$LIMITS_DESC cpu=$MAX_CPU"
    fi
    if [ -n "$MAX_PIDS" ]; then
      LIMIT_PROPS+=(-p "TasksMax=$MAX_PIDS")
      LIMITS_DESC="$LIMITS_DESC pids=$MAX_PIDS"
    fi
    LIMITS_DESC="''${LIMITS_DESC# }"
    SCOPE_PREFIX=()
    SCOPE_UNIT=""
    if [ "''${#LIMIT_PROPS[@]}" -gt 0 ]; then
      SCOPE_UNIT="llm-custody-${name}-$$"
      # --scope makes systemd-run exec the command in place once the scope
      # exists, so it keeps the pid, process group and cwd run_jail sets up
      # for it. --collect drops the unit even when the jail exits non-zero,
      # otherwise every failed session would leave a unit behind.
      SCOPE_PREFIX=(systemd-run --user --scope --quiet --collect
        "--unit=$SCOPE_UNIT" "''${LIMIT_PROPS[@]}" --)
    fi

    # The operator asked for a limit, so running without one would silently
    # downgrade the policy: every missing piece is fatal here. Checked
    # before anything is copied or started, and skipped by --dry-run, which
    # only reports what would run.
    limits_preflight() {
      local ctl_file ctl_have c missing=""
      local -a want=()
      if ! command -v systemd-run >/dev/null 2>&1; then
        err "resource limits need systemd-run, which is not on PATH"
        hint "run on a host with a systemd user manager, or drop --max-mem/--max-cpu/--max-pids"
        exit 1
      fi
      if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ ! -S "''${XDG_RUNTIME_DIR:-/nonexistent}/bus" ]; then
        err "resource limits need the systemd user bus, but neither DBUS_SESSION_BUS_ADDRESS nor XDG_RUNTIME_DIR/bus is set up"
        hint "no systemd user session here; run from a login session (or enable lingering: loginctl enable-linger)"
        exit 1
      fi
      if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        err "resource limits need the cgroup v2 unified hierarchy at /sys/fs/cgroup"
        hint "boot with systemd.unified_cgroup_hierarchy=1"
        exit 1
      fi
      # systemd does not reliably fail a scope whose controller is missing,
      # it just leaves the property without effect, so the delegation is
      # checked by hand. These are the controllers the user manager is
      # allowed to hand down to the scopes it creates.
      ctl_file="/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.controllers"
      if [ ! -r "$ctl_file" ]; then
        err "resource limits need a systemd user manager, $ctl_file is missing"
        hint "no user@$UID.service running; run from a login session"
        exit 1
      fi
      ctl_have=" $(cat "$ctl_file") "
      [ -n "$MAX_MEM" ] && want+=(memory)
      [ -n "$MAX_CPU" ] && want+=(cpu)
      [ -n "$MAX_PIDS" ] && want+=(pids)
      for c in "''${want[@]}"; do
        case "$ctl_have" in
          *" $c "*) ;;
          *) missing="$missing $c" ;;
        esac
      done
      if [ -n "$missing" ]; then
        err "cgroup controller(s)''${missing} not delegated to user@$UID.service"
        hint "enable Delegate= for user@.service, e.g. Delegate=cpu memory pids in a drop-in"
        exit 1
      fi
      # One throwaway scope with the same properties. It is what catches
      # the rest: a property this systemd rejects, or a shell outside the
      # user manager's tree that it may not move into a scope (common for
      # ssh sessions), both of which would otherwise only surface after the
      # whole sandbox setup.
      local out
      if ! out=$(systemd-run --user --scope --quiet --collect \
          "--unit=$SCOPE_UNIT-preflight" "''${LIMIT_PROPS[@]}" -- true 2>&1); then
        err "systemd-run could not create a limited scope"
        [ -n "$out" ] && hint "$out"
        exit 1
      fi
    }
    if [ "''${#LIMIT_PROPS[@]}" -gt 0 ] && [ "$DRYRUN" != "1" ]; then
      limits_preflight
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
    # `llm-custody toolbox`, so a profile edited with plain `nix profile`
    # commands is still picked up at the next launch.
    toolbox_refresh() {
      local real
      [ -L "$TOOLBOX_DIR/${toolbox.profileLink}" ] || return 0
      real=$(readlink -f "$TOOLBOX_DIR/${toolbox.profileLink}" 2>/dev/null) || return 0
      case "$real" in
        /nix/store/*) ln -sfn "$real" "$TOOLBOX_DIR/$TOOLBOX_CURRENT_LINK" ;;
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
        FILE_DOMAINS+=("''${d,,}")
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
    # lib/sync-back.sh for the format). Appended to by the --git copy step
    # and by the mount controller for every copy/overlay mount, at launch or
    # later; $RUNDIR/sync, the dirty watcher and the exit trap all read it
    # afresh, so a mount attached mid-session is synced like one from launch.
    # Exists from here on, possibly empty, so every writer can simply append.
    SYNC_MANIFEST="$RUNDIR/sync-manifest"
    : > "$SYNC_MANIFEST"
    SYNC_REG=""
    MOUNT_REG=""
    DOMAIN_REG=""
    STATE_REG=""
    TOOLBOX_REG=""
    # Guest directories a mount can be attached under while the session runs,
    # and the host directories bound there (see the dock setup below).
    DOCK_GUESTS=()
    DOCK_SRCS=()
    EXTRA_MOUNT_COUNT=0
    # The per-session package-request broker: its pid, so cleanup() can stop
    # it, and its runtime directory, so cleanup() can remove the registration
    # even when the broker was killed hard enough to skip its own handler.
    BROKER_PID=""
    BROKER_DIR=""
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
    # Names the empty bind sources under $RUNDIR/masks for the workspace
    # shadows (jail_mask_binds). Extra mounts keep theirs under their own
    # record directory, see lib/mount-ctl.sh.
    MASK_INDEX=0

    HOLDER_PID=""
    SLIRP_PID=""
    DNSMASQ_PID=""
    WATCH_PID=""
    DIRTY_PID=""

    # User vars, the session state record and the window title: what this
    # run publishes about itself (emit_uservar, session_state, publish_state,
    # set_title, JAIL_MARK, USERVAR_ON), from lib/session-publish.sh.
    ${builtins.readFile ./session-publish.sh}

    # Whitelist helpers (domain validation, the dnsmasq config, the nftables
    # pre-arm, the blocked-name count) come from lib/net-filter.sh, shared
    # with the domain controller so a domain allowed at launch and one
    # allowed mid-session go through the same code. Interpolated like
    # lib/jail-tree.sh further down, and ahead of cleanup() because the exit
    # trap's collect_net_stats calls into it.
    ${builtins.readFile ./net-filter.sh}

    # What the sandbox tried to reach and didn't get. Both halves have to be
    # collected before cleanup() kills the holder: the nftables counter
    # lives in that namespace, and the dnsmasq log is under $RUNDIR, which
    # the same function removes.
    #
    # This is the one piece of feedback a blocked agent otherwise never
    # produces: a request to a non-whitelisted domain just fails somewhere
    # inside the tool, with no indication that the jail is why.
    DROPPED_PACKETS=0
    # COUNT<TAB>NAME lines, most often blocked first (net_blocked_counts).
    BLOCKED_DOMAINS=""
    collect_net_stats() {
      local line n
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
        # Names allowed live since they were blocked are left out (the
        # second argument), so the summary lists only what is still blocked.
        # `|| true` on the whole pipeline: this runs first thing in the exit
        # trap with errexit active, and `head` closing the pipe early would
        # otherwise abort cleanup before the sync-back below ever runs.
        BLOCKED_DOMAINS=$(
          { net_blocked_counts "$RUNDIR/dnsmasq.log" "$RUNDIR/domains.active" | head -n 20; } || true
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
      # The pid file first: the domain controller restarts dnsmasq on every
      # whitelist change, after which $DNSMASQ_PID names a process that is
      # long gone. Both are checked to still be a dnsmasq before the signal.
      DNSMASQ_LIVE=$(net_dnsmasq_pid "$RUNDIR")
      [ -n "$DNSMASQ_LIVE" ] && kill "$DNSMASQ_LIVE" 2>/dev/null || true
      net_dnsmasq_alive "$DNSMASQ_PID" && kill "$DNSMASQ_PID" 2>/dev/null || true
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
      # -s, not -f: the manifest exists from the start of every run and is
      # empty for a session that bound everything straight through.
      if [ -n "$SYNC_MANIFEST" ] && [ -s "$SYNC_MANIFEST" ]; then
        if [ -t 0 ]; then
          ${syncBack} --prompt "''${SYNC_EXCLUDE_ARGS[@]+"''${SYNC_EXCLUDE_ARGS[@]}"}" "$SYNC_MANIFEST" || true
        else
          ${syncBack} --auto "''${SYNC_EXCLUDE_ARGS[@]+"''${SYNC_EXCLUDE_ARGS[@]}"}" "$SYNC_MANIFEST" || true
        fi
      fi

      # Session is over: drop the mid-session sync handles so nothing points
      # at a $RUNDIR that is about to disappear.
      # Stopped before the clearing pass below, for the same reason the dirty
      # watcher is: it publishes llm_custody_requests whenever its queue
      # changes, and a request timing out here would re-set a variable this is
      # about to clear.
      if [ -n "$BROKER_PID" ]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
      fi

      if [ "$USERVAR_SET" = "1" ]; then
        emit_uservar llm_custody_sync ""
        emit_uservar llm_custody_mount ""
        emit_uservar llm_custody_domain ""
        emit_uservar llm_custody_state ""
        emit_uservar llm_custody_jail ""
        emit_uservar llm_custody_dirty ""
        emit_uservar llm_custody_requests ""
        emit_uservar llm_custody_toolbox ""
        emit_uservar llm_custody_toolbox_cmd ""
      fi
      if [ -n "$STATE_REG" ]; then
        rm -f "$STATE_REG"
      fi
      if [ -n "$SYNC_REG" ]; then
        rm -f "$SYNC_REG"
        if [ "$(readlink "$(dirname "$SYNC_REG")/current" 2>/dev/null || true)" = "$RUNDIR/sync" ]; then
          rm -f "$(dirname "$SYNC_REG")/current"
        fi
      fi
      if [ -n "$MOUNT_REG" ]; then
        rm -f "$MOUNT_REG"
        if [ "$(readlink "$(dirname "$MOUNT_REG")/current.mount" 2>/dev/null || true)" = "$RUNDIR/mount" ]; then
          rm -f "$(dirname "$MOUNT_REG")/current.mount"
        fi
      fi
      if [ -n "$DOMAIN_REG" ]; then
        rm -f "$DOMAIN_REG"
        if [ "$(readlink "$(dirname "$DOMAIN_REG")/current.domain" 2>/dev/null || true)" = "$RUNDIR/domain" ]; then
          rm -f "$(dirname "$DOMAIN_REG")/current.domain"
        fi
      fi
      # The broker itself was stopped above. Any request still waiting on it
      # was answered by the socket closing, which the jail-side client reports
      # as "the broker went away" rather than hanging - the jail is gone by
      # this point anyway.
      if [ -n "$BROKER_DIR" ]; then
        rm -rf "$BROKER_DIR"
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
          while IFS=$'\t' read -r n d; do
            [ -n "$d" ] && hint "$d ($n lookup(s))"
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
      printf 'overlay\t%s\t-\t%s\t%s\n' "$RUNDIR/workspace-upper" "$WORKSPACE_HOST" "overlay workspace" >> "$SYNC_MANIFEST"
    fi

    # Tree helpers (copy, mask deletion, mask matching, baseline repo, change
    # tracking) come from lib/jail-tree.sh, shared with the mount controller
    # so a copy made at launch and one made mid-session are produced by the
    # same code. Interpolated rather than sourced: the file is part of this
    # script's text and shellcheck sees it as such.
    ${builtins.readFile ./jail-tree.sh}

    # Mask the workspace where the sandbox sees it through a direct bind
    # (--git full): there is no copy to delete from, so each --mask match is
    # shadowed by an empty read-only file/dir instead. Appends to
    # BWRAP_ARGS, so it has to be called after the bind it shadows - bwrap
    # applies its mounts in argument order. Extra mounts get the same
    # treatment from lib/mount-ctl.sh, as holder-side binds.
    #
    # Weaker than the deletion jail_apply_masks does, and deliberately so
    # flagged below: an empty bind only covers the working copy, so a tree
    # bound together with its .git still hands out the masked content as
    # blobs (git show HEAD:<path>).
    jail_mask_binds() {
      local hostroot="$1" guestroot="$2" label="$3" entry
      local -a matches
      mapfile -d "" -t matches < <(jail_mask_matches "$hostroot")
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
        hint "readable from history (git show HEAD:<path>). Only a copy (--git"
        hint "limited|none) removes it outright."
      fi
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
        printf 'copy\t%s\t%s\t%s\t%s\n' "$WORKSPACE_COPY" "$TRACK_GIT" "$WORKSPACE_HOST" "jail workspace" >> "$SYNC_MANIFEST"
      fi
    fi

    # Into the holder's user and mount namespaces, plus its network
    # namespace when the filter is on. -m is what lets a bind made here reach
    # the jail: bwrap is started through this too, so the jail's mount tree
    # is a slave copy of the holder's rather than of the host's.
    holder_ns_args() {
      if [ "$NET_FILTER" = "1" ]; then
        printf '%s\n' -U -m -n -t "$HOLDER_PID" --preserve-credentials --
      else
        printf '%s\n' -U -m -t "$HOLDER_PID" --preserve-credentials --
      fi
    }
    nsenter_holder() {
      local -a ns
      mapfile -t ns < <(holder_ns_args)
      nsenter "''${ns[@]}" "$@"
    }

    # The sandboxed command itself, in the foreground. On a terminal it is
    # run with job control on (set -m), which puts it in a process group of
    # its own and makes that the terminal's foreground group: SIGWINCH then
    # reaches the tool (it keeps the controlling terminal, see the bwrap
    # arguments), while kill(0) from inside the jail reaches only the jail
    # and not this shell's group, where the broker, the dirty watcher and
    # the network helpers all run. `set -m` here rather than a `bash -m -c`
    # wrapper: bash may exec its single -c command without forking, and the
    # fork is what creates the group.
    #
    # The group's leader is `timeout --foreground 0` (0 disables the
    # timeout, so it only waits and forwards signals and the exit status).
    # Terminal multiplexers and WezTerm's split decide the cwd of a new
    # pane from the foreground leader's /proc cwd, and bwrap, the leader
    # otherwise, sits at `/` after its pivot_root - every split would open
    # at the root. timeout keeps this shell's cwd, the host workspace.
    #
    # Without a terminal there is nothing to resize and no foreground to
    # take, so a plain call does.
    #
    # With resource limits, SCOPE_PREFIX (systemd-run --scope) comes first.
    # It execs the rest in place after creating the scope, so the process
    # that becomes the group leader is still timeout, with the same pid and
    # cwd, and the scope holds timeout, nsenter, bwrap and everything the
    # jail starts.
    run_jail() {
      local -a ns
      local status=0
      mapfile -t ns < <(holder_ns_args)
      if [ -t 0 ]; then
        set -m
        "''${SCOPE_PREFIX[@]+"''${SCOPE_PREFIX[@]}"}" timeout --foreground 0 nsenter "''${ns[@]}" "$@" || status=$?
        set +m
        return "$status"
      fi
      "''${SCOPE_PREFIX[@]+"''${SCOPE_PREFIX[@]}"}" nsenter "''${ns[@]}" "$@"
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

    # Every whitelist name ends up in a dnsmasq server=/NAME/ line, where a
    # `/`, `#` or whitespace from a hand-edited domains file would corrupt
    # the config, so the operator's names pass the same check as an agent's
    # live request. Lowercased because that is how the live controller
    # stores and matches them.
    VALID_DOMAINS=()
    for d in "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
      if domain_valid "''${d,,}"; then
        VALID_DOMAINS+=("''${d,,}")
      else
        warn "not a valid domain name, left off the whitelist: $d"
      fi
    done
    EXTRA_DOMAINS=("''${VALID_DOMAINS[@]+"''${VALID_DOMAINS[@]}"}")

    if [ "$DRYRUN" != "1" ]; then
      # Long-lived namespace holder. Two jobs:
      #
      # Network (with the filter on): slirp4netns and dnsmasq/nft attach to
      # its /proc/<pid>/ns/{user,net} by PID, and the sandboxed process later
      # re-enters the same pair via nsenter, sharing this network.
      #
      # Mounts (always): the holder also owns a mount namespace, a copy of
      # the host's with every mount made `shared` (--propagation shared).
      # bwrap is started inside it and marks the jail's tree `slave` to it,
      # so a bind made in the holder on a directory the jail has bound
      # propagates into the jail at the same relative path, and an umount
      # propagates back out. That is how lib/mount-ctl.sh attaches a tree
      # to a running jail without touching the jail's own namespaces, and
      # why every extra mount, launch-time ones included, is made here rather
      # than by bwrap: one mechanism, and all of them detachable alike. The
      # mounts stay invisible to the host (a slave never propagates upward)
      # and die with the holder.
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
      # genuinely mapped. Without the filter there is no dnsmasq, so a host
      # without the helpers falls back to the plain mapping; the holder
      # still has to be root inside its namespace, because util-linux
      # `mount` refuses binds from anything else.
      HAVE_IDMAP=1
      if ! command -v newuidmap >/dev/null || ! command -v newgidmap >/dev/null; then
        HAVE_IDMAP=0
        if [ "$NET_FILTER" = "1" ]; then
          err "newuidmap/newgidmap not found - required for network filtering."
          hint "(NixOS: enabled by any rootless-container feature, e.g. Incus; see /etc/subuid)"
          exit 1
        fi
      fi
      vlog "starting namespace holder"
      HOLDER_ARGS=(--user --mount --propagation shared)
      [ "$NET_FILTER" = "1" ] && HOLDER_ARGS+=(--net)
      [ "$HAVE_IDMAP" = "1" ] || HOLDER_ARGS+=(--map-root-user)
      unshare "''${HOLDER_ARGS[@]}" -- sleep infinity &
      HOLDER_PID=$!
      # The ns links exist from the fork on, pointing at *our* namespaces
      # until unshare has actually run; the mapping below must land in the
      # new user namespace, so wait for the link to move away from ours.
      for _ in $(seq 1 100); do
        [ "$(readlink "/proc/$HOLDER_PID/ns/user" 2>/dev/null || true)" != "$(readlink /proc/self/ns/user)" ] && break
        sleep 0.02
      done
      if [ "$HAVE_IDMAP" = "1" ]; then
        newuidmap "$HOLDER_PID" 0 "$(id -u)" 1 1 100000 65536
        newgidmap "$HOLDER_PID" 0 "$(id -g)" 1 1 100000 65536
      fi
    fi

    if [ "$NET_FILTER" = "1" ] && [ "$DRYRUN" != "1" ]; then
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

      # The session's whitelist with each name's origin, the one list the
      # dnsmasq config is generated from, at launch and by every live change
      # (lib/domain-ctl.sh). First source wins for a name listed twice, in
      # the order default, file, flag, so `remove --persist` knows when the
      # Nix-defined list is what put a name there.
      declare -A SEEN_DOMAIN=()
      {
        for d in "''${ALLOWED_DOMAINS[@]}"; do
          [ -n "''${SEEN_DOMAIN[$d]:-}" ] && continue
          SEEN_DOMAIN[$d]=1
          printf '%s\tdefault\n' "$d"
        done
        for d in "''${FILE_DOMAINS[@]+"''${FILE_DOMAINS[@]}"}"; do
          [ -n "''${SEEN_DOMAIN[$d]:-}" ] && continue
          domain_valid "$d" || continue
          SEEN_DOMAIN[$d]=1
          printf '%s\tfile\n' "$d"
        done
        for d in "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"; do
          [ -n "''${SEEN_DOMAIN[$d]:-}" ] && continue
          SEEN_DOMAIN[$d]=1
          printf '%s\tflag\n' "$d"
        done
      } > "$RUNDIR/domains.active"
      net_write_dnsmasq_conf "$RUNDIR" "$UPSTREAM_DNS"

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

      # First-connect race mitigation, see net_prearm in lib/net-filter.sh.
      net_prearm "''${ALLOWED_DOMAINS[@]}" "''${EXTRA_DOMAINS[@]+"''${EXTRA_DOMAINS[@]}"}"

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

      # Everything the domain controller needs to change the whitelist of
      # this running session, written with declare -p like mount.env (and,
      # like it, host-side only). The launcher is what a second terminal and
      # the broker run.
      {
        declare -p HOLDER_PID RUNDIR STATE_ROOT UPSTREAM_DNS DNSMASQ_PID VERBOSITY
      } > "$RUNDIR/domain.env"
      printf '#!%s\nexec %s %s "$@"\n' \
        "${pkgs.bash}/bin/sh" "${domainCtl}" "$(printf '%q' "$RUNDIR")" > "$RUNDIR/domain"
      chmod +x "$RUNDIR/domain"
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

    # Docks: the guest directories a mount can be attached under while the
    # session runs. Each is a host directory under $RUNDIR bound read-only
    # into the jail; the jail's copy of that bind is a propagation slave of
    # the holder's mount, so a bind the holder makes on a subdirectory shows
    # up inside the jail, and an umount takes it away again (see the holder
    # setup above and lib/mount-ctl.sh). /workspace is one when it is the
    # container the workspace hangs under (not with --same-path, and not
    # when the workspace is / itself), /mnt always.
    #
    # Read-only, so the agent cannot populate a dock with its own entries (a
    # planted symlink where the operator is about to mount would redirect
    # the holder-side bind). Not via --ro-bind, though: that remounts every
    # submount it finds read-only as well, which would turn a launch-time
    # rw --mount already attached under the dock read-only. --bind keeps
    # each submount's own flags and --remount-ro is non-recursive, so only
    # the dock directory itself ends up read-only. The mountpoint of the
    # workspace bind inside it is created here, since bwrap cannot create
    # it in a read-only tree.
    DOCK_ROOT="$RUNDIR/dock"
    DOCK_SPEC=()
    if [ "$WORKSPACE_GUEST" != "$WORKSPACE_ROOT" ] && [ "$SAME_PATH" != "1" ]; then
      DOCK_GUESTS+=("$WORKSPACE_ROOT")
      DOCK_SRCS+=("$DOCK_ROOT/workspace")
      DOCK_SPEC+=(--bind "$DOCK_ROOT/workspace" "$WORKSPACE_ROOT" --remount-ro "$WORKSPACE_ROOT")
      [ "$DRYRUN" = "1" ] || mkdir -p "$DOCK_ROOT/workspace/$WORKSPACE_NAME"
    fi
    DOCK_GUESTS+=(/mnt)
    DOCK_SRCS+=("$DOCK_ROOT/mnt")
    DOCK_SPEC+=(--bind "$DOCK_ROOT/mnt" /mnt --remount-ro /mnt)
    [ "$DRYRUN" = "1" ] || mkdir -p "$DOCK_ROOT/mnt" "$DOCK_ROOT/fixed"

    BWRAP_ARGS=(
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
      # No nested user namespaces. A fresh userns hands its creator a full
      # capability set inside it, which reaches netns-scoped nftables and
      # the rest of the userns-gated kernel surface (a common LPE route).
      # The seccomp rules on unshare/clone/clone3 are what actually enforce
      # this: measured on bwrap 0.13.1, --disable-userns leaves
      # /proc/sys/user/max_user_namespaces at INT_MAX inside the sandbox
      # rather than the 1 it documents, with or without this runner's
      # holder-ns nesting, so nothing here may depend on it. Kept because it
      # costs nothing and becomes a real second layer if a later bwrap makes
      # it stick. Requires --unshare-user (above).
      --disable-userns
      # No --new-session: setsid() would detach the tool from the controlling
      # terminal, and a process with no controlling terminal never receives
      # SIGWINCH - pi/claude then keep painting at the launch width after the
      # pane is resized or split (a mount/sync split in the terminal is enough)
      # and the redraw lands as garbage. The input injection --new-session
      # guards against (TIOCSTI/TIOCLINUX) is denied by the seccomp filter
      # below instead, which is the alternative bwrap's own documentation
      # names for this case.
      --die-with-parent
      # Drop every capability from the sandboxed process. CAP_SYS_ADMIN is
      # the one that matters most - every mount-creation syscall (mount(2),
      # open_tree/move_mount, mount_setattr, umount2, pivot_root, ...)
      # requires it, including the mount API modern util-linux `mount` uses,
      # which a seccomp list of the mount syscall alone misses - but
      # dropping it alone is not enough. The tool runs as uid 0 in the
      # sandbox userns (the holder maps inner 0 to the invoking host uid),
      # and for a uid-0 sandbox bwrap keeps every capability not named in a
      # --cap-drop. CAP_SYS_RESOURCE among them is write access to the
      # userns-owned ucount sysctls, i.e. the sandboxed process could raise
      # user.max_user_namespaces back itself (verified from inside the
      # jail). Nothing in a coding-agent workload needs a capability here:
      # the workspace and state are owned by the mapped uid, so owner
      # permissions cover every write, and the store is world-readable.
      # bwrap applies --cap-drop after its own sandbox setup, so bwrap
      # itself keeps what it needs for unshare/mount.
      --cap-drop ALL
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
      # Docks before the workspace: the workspace bind lands inside the
      # /workspace dock, and bwrap mounts in argument order.
      "''${DOCK_SPEC[@]}"
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

    # One directory at the very front of the jail's PATH, holding everything
    # the runner puts there itself: the git wrapper below, and the
    # `custody-request` entry point an agent asks for a package with. Created
    # and bound unconditionally - the git shadow is conditional on the host
    # having a git the sandbox can see, and custody-request must not disappear
    # along with it.
    JAIL_BIN_DIR="$RUNDIR/bin"
    mkdir -p "$JAIL_BIN_DIR"
    # The same binary as the host-side CLI, reached under another name: it
    # dispatches on argv[0]. A symlink into /nix/store resolves inside the
    # sandbox because the store is bound wholesale.
    ln -sfn "${custodyCli}" "$JAIL_BIN_DIR/custody-request"
    BWRAP_ARGS+=(--ro-bind "$JAIL_BIN_DIR" /run/llmcustody-bin)
    JAIL_PATH="/run/llmcustody-bin:$JAIL_PATH"

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
        printf '#!%s\nexec "%s" -c core.hooksPath="%s" "$@"\n' \
          "${pkgs.bash}/bin/sh" "$REAL_GIT" "$HOOKS_GUEST" \
          > "$JAIL_BIN_DIR/git"
        chmod +x "$JAIL_BIN_DIR/git"
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
    # custom-endpoint settings. Cloud credentials such as AWS_* are not
    # inherited: a host shell often carries keys for unrelated accounts,
    # so one reaches the jail only through an explicit --env.
    for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL TERM COLORTERM LANG LC_ALL LC_CTYPE; do
      [ -n "''${!var:-}" ] && BWRAP_ARGS+=(--setenv "$var" "''${!var}")
    done
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

    # Everything the mount controller needs about this session, for the
    # launch-time mounts below and for every later attach/detach: the holder
    # to enter, the docks, the mask globs and sync excludes. declare -p
    # output is bash's own serialisation, so a glob or a path with a space
    # survives the round trip unchanged. Host-side only ($RUNDIR is never
    # mounted into the sandbox), so sourcing it is sourcing our own data.
    if [ "$DRYRUN" != "1" ]; then
      {
        declare -p HOLDER_PID MASK_PATTERNS SYNC_EXCLUDES SYNC_MANIFEST
        declare -p DOCK_GUESTS DOCK_SRCS WORKSPACE_GUEST VERBOSITY
      } > "$RUNDIR/mount.env"
      # The launcher a second terminal (or the broker) runs: the controller
      # with this session's runtime dir baked in. %q because $RUNDIR inherits
      # --tmpdir, which may well contain a space or a quote.
      printf '#!%s\nexec %s %s "$@"\n' \
        "${pkgs.bash}/bin/sh" "${mountCtl}" "$(printf '%q' "$RUNDIR")" > "$RUNDIR/mount"
      chmod +x "$RUNDIR/mount"
    fi

    # Extra mounts land under /workspace by default (see WORKSPACE_ROOT
    # above), named after the host path's last component. --same-path keeps
    # host paths verbatim, since that mode exists specifically to make
    # in-jail paths match the host's. Each one is attached by the mount
    # controller, exactly as a mount added mid-session would be; the
    # controller refuses two mounts on one guest path, so the second bind
    # can never silently shadow the first.
    #
    # Read-write mounts get the same host-tree protection as the workspace,
    # chosen by the same flags - an agent let loose in a second checkout
    # can do exactly as much damage there as in the main one, so a direct
    # bind only when --git full explicitly asks for the real tree.
    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      access="''${spec##*:}"
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
      if [ "$access" = "ro" ]; then
        mmode="ro"
      elif [ "$OVERLAY" = "1" ]; then
        mmode="overlay"
      else
        mmode="$GIT_MODE"
      fi
      EXTRA_MOUNT_COUNT=$((EXTRA_MOUNT_COUNT+1))
      if [ "$DRYRUN" = "1" ]; then
        log "would mount $hostpath at $guestpath (mode $mmode; nothing copied for --dry-run)"
        continue
      fi
      # --allow-fixed: a guest path outside every dock is still honoured at
      # launch, through a bwrap bind of the holder-side mountpoint; such a
      # mount just cannot be detached before the session ends.
      mount_out=$("$RUNDIR/mount" add --mode "$mmode" --guest "$guestpath" --allow-fixed -- "$hostpath") ||
        die "mounting $hostpath failed"
      IFS=$'\t' read -r _ mount_point mount_fixed <<< "$mount_out"
      if [ "$mount_fixed" = "1" ]; then
        BWRAP_ARGS+=(--bind "$mount_point" "$guestpath")
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
      BWRAP_ARGS+=(--setenv SELFTEST_TIOCSTI "${selftestTiocsti}")
      BWRAP_ARGS+=(--setenv SELFTEST_USERNS "${selftestUserns}")
      BWRAP_ARGS+=(--setenv SELFTEST_DOMAIN "${selftestDomain}")
      BWRAP_ARGS+=(--setenv SELFTEST_GITMODE "$GIT_MODE")
      # With limits, the probe reads the scope's own cgroup files to show
      # what the kernel enforces. The jail has no /sys and a cgroup
      # namespace of its own, so the scope directory is bound in directly.
      # Its path assumes the user manager's default app.slice; -try turns
      # a different layout into a SKIP in the probe instead of a failure.
      if [ -n "$SCOPE_UNIT" ]; then
        BWRAP_ARGS+=(--setenv SELFTEST_LIMITS 1)
        BWRAP_ARGS+=(--ro-bind-try "/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/app.slice/$SCOPE_UNIT.scope" /sys/fs/cgroup)
      else
        BWRAP_ARGS+=(--setenv SELFTEST_LIMITS 0)
      fi
      BWRAP_ARGS+=(--ro-bind "${selftestProbe}" /selftest.sh)
      run_jail bwrap "''${BWRAP_ARGS[@]}" -- "${pkgs.bash}/bin/sh" /selftest.sh
      exit $?
    fi

    # jail_dirty_count and start_dirty_watcher: how many paths the jail has
    # changed but not yet synced, and the poller that publishes that count
    # during the session, from lib/dirty-watch.sh.
    ${builtins.readFile ./dirty-watch.sh}

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
      vlog "toolbox: $TOOLBOX_DIR -> ${toolbox.guestDir} (${custodyCli} toolbox add PKG)"
      if [ "$USERVAR_ON" = "1" ]; then
        emit_uservar llm_custody_toolbox "$TOOLBOX_DIR"
        # The CLI's own store path alongside the directory: a consumer of the
        # var above still has to *run* something, and with `nix run` there is
        # no llm-custody on PATH to run. The store path always works. The var
        # keeps its name because consumers key on it; its value is the whole
        # CLI now, so a keybinding runs `"$cmd" --dir "$dir" toolbox add PKG`.
        emit_uservar llm_custody_toolbox_cmd "${custodyCli}"
        USERVAR_SET=1
      fi

      # Package-request broker for this session. The jail gets one socket,
      # which speaks exactly one verb; approval runs on a second socket that
      # is never bound into the sandbox, so an agent cannot answer its own
      # request. See lib/toolbox-rs.nix and the crate's proto.rs.
      BROKER_DIR="$REG_DIR/brokers/$$"
      rm -rf "$BROKER_DIR"
      # Into a log file, never the terminal: the jailed tool owns the
      # terminal for the whole session, and a line of broker chatter landing
      # inside one of its frames corrupts the display (the same reason the
      # dirty-count user var is only emitted on change). The operator
      # discovers requests with `llm-custody request list`, not by
      # watching this.
      # --mount-cmd: an approved mount request runs this session's mount
      # launcher, so the broker never grows a second way of attaching a tree.
      # --domain-cmd likewise for domain requests, and only with the filter
      # on: without it the broker answers a domain request at once with "the
      # filter is off" instead of queueing something nobody needs to approve.
      BROKER_DOMAIN_ARGS=()
      if [ "$NET_FILTER" = "1" ]; then
        BROKER_DOMAIN_ARGS=(--domain-cmd "$RUNDIR/domain")
      fi
      ${custodyCli} --dir "$TOOLBOX_DIR" serve \
        --broker-id "$$" --label "${name} $WORKSPACE_HOST" \
        --uservar "$USERVAR_ON" --mount-cmd "$RUNDIR/mount" \
        "''${BROKER_DOMAIN_ARGS[@]+"''${BROKER_DOMAIN_ARGS[@]}"}" \
        >"$RUNDIR/broker.log" 2>&1 &
      BROKER_PID=$!
      # Readiness is observed, not slept for (same reason as slirp4netns and
      # dnsmasq above): the socket has to exist before bwrap binds it, and a
      # fixed sleep is the thing that holds on an idle laptop and not on a
      # loaded one. Breaks early if the broker died, so a failure surfaces on
      # its own terms rather than after the full timeout.
      BROKER_SOCK="$BROKER_DIR/request.sock"
      for _ in $(seq 1 100); do
        [ -S "$BROKER_SOCK" ] && break
        kill -0 "$BROKER_PID" 2>/dev/null || break
        sleep 0.05
      done
      if [ -S "$BROKER_SOCK" ]; then
        # A socket is an inode, so bwrap binds it like any other file.
        BWRAP_ARGS+=(--bind "$BROKER_SOCK" /run/custody-request.sock)
        BWRAP_ARGS+=(--setenv CUSTODY_REQUEST_SOCKET /run/custody-request.sock)
        vlog "broker: $BROKER_SOCK -> /run/custody-request.sock (${custodyCli} request list)"
      else
        # Not fatal: the session is still perfectly usable, the agent just has
        # to ask in its reply the way it did before there was a broker.
        warn "package-request broker did not start - custody-request will not work in this jail"
        hint "see $RUNDIR/broker.log"
        kill "$BROKER_PID" 2>/dev/null || true
        BROKER_PID=""
        BROKER_DIR=""
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
    # Registered for every run, even one whose manifest is empty at launch:
    # a copy mount attached later lands in the same manifest, and the
    # launcher has to already be where the operator's key looks for it.
    #
    # Deliberately *not* reachable from inside the sandbox: $RUNDIR is not
    # mounted there, so the agent cannot sync its own work out unreviewed.
    if [ "$DRYRUN" != "1" ]; then
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

      # Stable handles for anything that wants to find the live session
      # without parsing terminal output: a per-pid symlink plus `current`
      # for the most recent run, for the sync launcher and the mount
      # launcher alike. Concurrent runs each keep their own pid entry;
      # `current` is simply the latest to start.
      mkdir -p "$REG_DIR"
      SYNC_REG="$REG_DIR/$$.sync"
      ln -sfn "$RUNDIR/sync" "$SYNC_REG"
      ln -sfn "$RUNDIR/sync" "$REG_DIR/current"
      MOUNT_REG="$REG_DIR/$$.mount"
      ln -sfn "$RUNDIR/mount" "$MOUNT_REG"
      ln -sfn "$RUNDIR/mount" "$REG_DIR/current.mount"
      # The domain launcher only exists with the filter on (it is written
      # next to the dnsmasq setup), and so do its handles.
      if [ -x "$RUNDIR/domain" ]; then
        DOMAIN_REG="$REG_DIR/$$.domain"
        ln -sfn "$RUNDIR/domain" "$DOMAIN_REG"
        ln -sfn "$RUNDIR/domain" "$REG_DIR/current.domain"
      fi

      vlog "mid-session sync: $RUNDIR/sync (also $REG_DIR/current, or llm-custody sync)"
      vlog "live mounts: $RUNDIR/mount add|remove|list (also $REG_DIR/current.mount, or llm-custody mount)"
      if [ -n "$DOMAIN_REG" ]; then
        vlog "live domains: $RUNDIR/domain add|remove|list|blocked (also $REG_DIR/current.domain, or llm-custody domain)"
      fi

      # Terminals that understand OSC 1337 SetUserVar get both paths as
      # variables too, which is what makes a one-key binding possible.
      if [ "$USERVAR_ON" = "1" ]; then
        emit_uservar llm_custody_sync "$RUNDIR/sync"
        emit_uservar llm_custody_mount "$RUNDIR/mount"
        if [ -n "$DOMAIN_REG" ]; then
          emit_uservar llm_custody_domain "$RUNDIR/domain"
        fi
        USERVAR_SET=1
      fi
      # The state names what the launch produced: isolated trees to fold
      # back, or everything bound straight through. A consumer told
      # `direct` still gets the sync path, for the mount attached later.
      if [ -s "$SYNC_MANIFEST" ]; then
        publish_state sync
      else
        publish_state direct
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
      # have to special-case "not there yet". Started even over an empty
      # manifest: it re-reads the manifest on every pass, so a copy mount
      # attached later is counted from then on.
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

    # card_row and print_card, the session card printed last before launch,
    # from lib/session-card.sh.
    ${builtins.readFile ./session-card.sh}

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
      if [ "''${#SCOPE_PREFIX[@]}" -gt 0 ]; then
        log "resource limit scope (prefixed to the jail command, not checked against systemd for --dry-run):"
        for arg in "''${SCOPE_PREFIX[@]}"; do
          hint "$arg"
        done
      fi
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
    # Always through the holder, filter or not: its mount namespace is what
    # live mounts propagate through.
    run_jail bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
  '';
}
