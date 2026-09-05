# bwrap + private-netns host launcher, replacing lib/mkRunner.nix's QEMU
# launcher. Generalizes prototypes/bwrap-pi.sh (proven end-to-end: real
# netns/slirp4netns/dnsmasq/nftables/bwrap/seccomp chain, interactively
# tested with a live TUI session) so it's data-driven from tools.nix instead
# of hardcoding one tool's values.
{ pkgs
, name
, toolDefaults
, launcherOut
,
}:

let
  seccompDenylist = import ./seccomp-denylist.nix { inherit pkgs; };
  toolExe = pkgs.lib.getExe launcherOut.toolPackage;
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
    TOOL_ARGS=()

    usage() {
      cat <<'USAGE'
    Usage: llm-custody-${name} [options] [-- tool-args...]

    Options:
      --profile NAME        State profile, a subdir of --state-dir/${name} (default: default)
      --state-dir PATH      Jail state root dir (default: ~/.config/llm-custody)
      --same-path           Mount workspace at its host path instead of /workspace
                             (lets tools like 'claude --resume' match sessions
                             started outside the sandbox)
      --tmpdir PATH         Directory to use for runtime data (default: ''${TMPDIR:-/tmp})
      --mount HOSTPATH[:GUESTPATH]
                             Extra read-write mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --ro-mount HOSTPATH[:GUESTPATH]
                             Extra read-only mount (repeatable). GUESTPATH
                             defaults to HOSTPATH if omitted.
      --allow-domain DOMAIN Add domain to network whitelist (repeatable)
      --no-net-filter       Disable network filtering (unrestricted access)
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
        --no-net-filter) NET_FILTER=0; shift ;;
        -h|--help)       usage ;;
        --)              shift; TOOL_ARGS=("$@"); break ;;
        *)               echo "Unknown option: $1" >&2; usage ;;
      esac
    done

    WORKSPACE_HOST="$(pwd)"
    WORKSPACE_GUEST="/workspace"
    [ "$SAME_PATH" = "1" ] && WORKSPACE_GUEST="$WORKSPACE_HOST"

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

    ${launcherOut.bootstrapScript}

    if [ ! -d "$LLMCUSTODY_TMPDIR" ]; then
      echo "ERROR: tmpdir '$LLMCUSTODY_TMPDIR' does not exist" >&2
      exit 1
    fi

    RUNDIR=$(mktemp -d --tmpdir="$LLMCUSTODY_TMPDIR")
    HOLDER_PID=""
    SLIRP_PID=""
    DNSMASQ_PID=""
    WATCH_PID=""

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

      echo "nameserver 127.0.0.1" > "$RUNDIR/resolv.conf"
    fi

    # bwrap's --seccomp wants an already-open fd on the BPF program; a real
    # file (not a `<()` process substitution) avoids relying on bash's
    # fd-inheritance/CLOEXEC behavior across the exec into bwrap.
    ${seccompDenylist}/bin/seccomp-denylist > "$RUNDIR/seccomp.bpf"
    exec {SECCOMP_FD}<"$RUNDIR/seccomp.bpf"

    # WORKSPACE_HOST/WORKSPACE_GUEST were already resolved above, right
    # after arg parsing (needed there for the git safety checks).

    BWRAP_ARGS=(
      --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
      --die-with-parent --new-session
      --seccomp "$SECCOMP_FD"
      --proc /proc
      --dev /dev
      --tmpfs /tmp
      --tmpfs /home/user
      --setenv HOME /home/user
      --setenv ${toolDefaults.configEnvVar} /home/user/${toolDefaults.configDirName}
      --chdir "$WORKSPACE_GUEST"
      --ro-bind /nix/store /nix/store
      --bind "$WORKSPACE_HOST" "$WORKSPACE_GUEST"
      --bind "$STATE_DIR" /home/user/${toolDefaults.configDirName}
    )

    # Read-only even though the workspace itself is rw - a jailed agent
    # shouldn't be able to plant/modify git hooks that run on the host later.
    if [ -d "$WORKSPACE_HOST/.git/hooks" ]; then
      BWRAP_ARGS+=(--ro-bind "$WORKSPACE_HOST/.git/hooks" "$WORKSPACE_GUEST/.git/hooks")
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
      # exists inside the jail (or on a NixOS host at all), so the shebang
      # must point at bash's store path instead of /bin/sh or
      # /usr/bin/env sh (env and /usr/bin are not bound either).
      REAL_GIT=$(readlink -f "$REAL_GIT" 2>/dev/null || true)
      if [[ "$REAL_GIT" != /nix/store/* ]]; then
        echo "warning: git resolves to $REAL_GIT, outside /nix/store - skipping in-jail git hooks shadow" >&2
        REAL_GIT=""
      fi
      if [ -n "$REAL_GIT" ]; then
        GIT_WRAPPER_DIR="$RUNDIR/bin"
        mkdir -p "$GIT_WRAPPER_DIR"
        printf '#!%s\nexec "%s" -c core.hooksPath="%s/.git/hooks" "$@"\n' \
          "${pkgs.bash}/bin/sh" "$REAL_GIT" "$WORKSPACE_GUEST" \
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
    if [ -d "$HOME/.claude/skills" ]; then
      for entry in "$HOME/.claude/skills"/*; do
        [ -e "$entry" ] || continue
        BWRAP_ARGS+=(--ro-bind "$(readlink -f "$entry")" "/home/user/.agents/skills/$(basename "$entry")")
      done
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

    for var in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL TERM COLORTERM; do
      [ -n "''${!var:-}" ] && BWRAP_ARGS+=(--setenv "$var" "''${!var}")
    done
    while IFS='=' read -r awsvar awsval; do
      [ -n "$awsvar" ] && BWRAP_ARGS+=(--setenv "$awsvar" "$awsval")
    done < <(env | grep '^AWS_' || true)
    if STTY_SIZE=$(stty size 2>/dev/null); then
      BWRAP_ARGS+=(--setenv LINES "''${STTY_SIZE%% *}" --setenv COLUMNS "''${STTY_SIZE##* }")
    fi

    for spec in "''${EXTRA_MOUNTS[@]+"''${EXTRA_MOUNTS[@]}"}"; do
      mode="''${spec##*:}"
      paths="''${spec%:*}"
      if [[ "$paths" == *:* ]]; then
        hostpath="''${paths%%:*}"; guestpath="''${paths#*:}"
      else
        hostpath="$paths"; guestpath="$paths"
      fi
      if [ ! -e "$hostpath" ]; then
        echo "ERROR: mount path does not exist: $hostpath" >&2
        exit 1
      fi
      if [ "$mode" = "ro" ]; then
        BWRAP_ARGS+=(--ro-bind "$hostpath" "$guestpath")
      else
        BWRAP_ARGS+=(--bind "$hostpath" "$guestpath")
      fi
    done

    if [ "$NET_FILTER" = "1" ]; then
      nsenter_holder bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    else
      bwrap "''${BWRAP_ARGS[@]}" -- ${toolExe} "''${TOOL_ARGS[@]+"''${TOOL_ARGS[@]}"}"
    fi
  '';
}
