# llm-custody

> **Hard fork of [braiins/llm-jail](https://github.com/braiins/llm-jail).**
> Upstream sandboxes several coding-agent tools inside QEMU microVMs. This
> fork replaced that with bubblewrap + a private network namespace (real
> Linux namespaces on the host kernel instead of a VM boundary, no guest
> kernel to boot) and cut every tool except [Pi](https://pi.dev)/[Claude Code](https://code.claude.com).
> Not a PR-back candidate.

Sandbox for running a coding agent via bubblewrap + a private network
namespace. No VM, no disk image; the tool runs directly on the host kernel,
isolated by Linux namespaces and a seccomp denylist, with DNS+nftables-based
domain whitelisting for outbound network access.

Supported tools (one runner package each, `nix run .#<tool>`):

| Tool | Config dir in sandbox | Relocated via | Dangerous mode |
|------|-----------------------|----------------|----------------|
| `pi` | `/home/user/.pi/agent` | `PI_CODING_AGENT_DIR` | no flag (trust is pre-set instead) |
| `claude` | `/home/user/.claude` | `CLAUDE_CONFIG_DIR` | `--dangerous` |

## Requirements

- Linux (x86_64 or aarch64)
- [Nix](https://nixos.org/) with flakes enabled
- `newuidmap`/`newgidmap` (setuid helpers) plus `/etc/subuid`/`/etc/subgid`
  ranges for your user - required for the private network namespace. On
  NixOS, enabling any rootless-container feature (e.g. Incus) provisions
  these; otherwise install `shadow`'s setuid helpers and add subuid/subgid
  ranges yourself.

No host-side tool credentials are needed: you log in once inside the jail on
first run (the tool's own `/login` flow), and that state persists in a
jail-private directory under `~/.config/llm-custody/<tool>/` (see
[First run & authentication](#first-run--authentication)).

## Quick start

```bash
# Run Pi
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#pi"

# Run Claude Code
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#claude"

# Pass tool arguments after --
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#pi" -- -p "Refactor the auth module"
```

Or, from a local checkout:

```bash
nix run .#pi -- -p "Refactor the auth module"
nix run .#claude -- --dangerous -- -p "Refactor the auth module"
```

## First run & authentication

Tool state lives in a jail-private directory on the host -
`~/.config/llm-custody/<tool>/<profile>` (profile `default` unless
`--profile` is given) - bound read-write into the sandbox at the tool's own
config location (see the table above). Your real `~/.pi` / `~/.claude` is
never mounted or read.

On first run the directory is empty, so the tool walks you through its own
`/login` flow in the terminal. Credentials and settings then persist across
runs.

For claude, that login is the paste-a-code variant of the OAuth flow: there
is no browser inside the sandbox, so claude prints the authorize URL, you
open it on the host and paste the code back. `platform.claude.com` and
`claude.ai` are whitelisted for exactly this. Alternatively,
export `ANTHROPIC_API_KEY` on the host - it is forwarded into the sandbox and
skips the login entirely.

Work for multiple clients by giving each its own profile, each with its own
one-time login:

```bash
nix run .#pi -- --profile client1
nix run .#pi -- --profile client2
```

If you want to reuse an existing host login rather than logging in fresh,
you can point `--state-dir` at a directory that itself contains a
`<tool>/<profile>` symlink onto your real config dir (`~/.pi/agent`,
`~/.claude`) - at your own risk (host and jail will then refresh the same
credentials independently). Do not point it directly at a directory the host
tool also writes to.

## Usage

```
llm-custody-<tool> [options] [-- tool-args...]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--profile NAME` | State profile, a subdir of `--state-dir/<tool>` | `default` |
| `--state-dir PATH` | Jail state root dir, mounted read-write | `~/.config/llm-custody` |
| `--same-path` | Mount the workspace and every `--mount` at their host paths instead of under `/workspace` | off |
| `--tmpdir PATH` | Directory to use for runtime data | `${TMPDIR:-/tmp}` |
| `--mount HOSTPATH[:GUESTPATH]` | Extra read-write mount (repeatable). Isolated like the workspace: copy + sync-back under `--git limited/none`, copy-on-write with `--overlay-workspace`, real tree with `--git full`. A single file is always bound directly | `/workspace/<basename HOSTPATH>` |
| `--ro-mount HOSTPATH[:GUESTPATH]` | Extra read-only mount (repeatable) | `/workspace/<basename HOSTPATH>` |
| `--allow-domain DOMAIN` | Add domain to network whitelist (repeatable) | tool defaults |
| `--env KEY=VAL` | Pass environment variable into the sandbox (repeatable) | - |
| `--x11` | Allow X11/Wayland clipboard access; without it, display vars are stripped so terminals use OSC 52 | off |
| `--git full\|limited\|none` | How much of the repo the jail sees: `limited` = copy of the working tree as a fresh single-commit repo (no host history), `none` = same copy without a repo, `full` = the real tree including `.git` | `limited` |
| `--overlay-workspace` | Mount the workspace and every rw `--mount` copy-on-write; edits sync back to the real trees only on explicit confirmation (needs `--git full`) | off |
| `--selftest` | Run a sandbox self-check (full chain incl. netns, seccomp and the git wrapper) and exit; no in-jail `/login` needed | off |
| `-c`, `--continue` | Resume the most recent session, translated to the tool's own continue flag | - |
| `-r`, `--resume [ID]` | Open the tool's session picker, or target a specific session id directly | - |
| `--dangerous` | Pass the tool's own skip-all-permission-prompts flag (claude: `--dangerously-skip-permissions`; errors out for a tool that has none) | off |
| `--rw-skills` | Mount skills read-write instead of read-only (only for deliberate in-jail skill maintenance - an agent can edit files the host reads and skillissue may push) | read-only |
| `--mask GLOB` | Hide files/dirs matching GLOB in the workspace (deleted from the jail copy; with `--git full`, shadowed by an empty file/dir instead; repeatable) | - |
| `--no-net-filter` | Disable network filtering (unrestricted access) | filtering on |
| `--merge-config` | Interactively merge root-level keys from the host tool's settings.json into the jail-private one; each differing key prompts y/N individually ('a' accepts the rest) | off |
| `--merge-config-from PATH` | Same as `--merge-config` with an explicit source file instead of the default host tool settings.json | - |
| `-h`, `--help` | Show help | - |

Any other argument (e.g. pi's `-p`) is passed straight through to the tool,
so the quick-start style `nix run .#pi -- -p "..."` works as written - the
runner only intercepts its own flags.

Not yet ported from the old QEMU jail: `--immutable`, `--nix-env`,
`--devenv`.

### Examples

Mount an extra directory - it lands next to the workspace, as
`/workspace/data`:

```bash
nix run .#pi -- --mount /tmp/data -- -p "Process the dataset"
```

Two sources with the same basename collide, so name one of them explicitly:

```bash
nix run .#pi -- --mount /srv/a/config --mount /srv/b/config:/workspace/b-config
```

Mount somewhere other than `/workspace` by giving an absolute target - e.g.
git-over-SSH needs the keys where ssh looks for them, in the sandbox's own
`$HOME`:

```bash
nix run .#pi -- --ro-mount ~/.ssh:/home/user/.ssh -- -p "Push the changes"
```

Allow access to additional domains (e.g. for package installs or git cloning):

```bash
nix run .#pi -- --allow-domain github.com --allow-domain registry.npmjs.org
```

Domains you want on every run for a given state root go into
`~/.config/llm-custody/domains` (one per line, `#` comments allowed) instead
of being re-passed each time.

Pass extra environment (e.g. a proxy or a custom endpoint):

```bash
nix run .#pi -- --env HTTPS_PROXY=http://127.0.0.1:8080 --env MIRROR=…
```

Verify the sandbox wiring (netns holder, dnsmasq/nft whitelist, seccomp
denylist, git wrapper) without starting a session:

```bash
nix run .#pi -- --selftest
```

Resume a previous session (the aliases are translated to the tool's own
flags; pi accepts `--continue`/`-c` and `--resume`/`-r`):

```bash
# resume the most recent session without prompting
nix run .#pi -- --continue
# pick a session from the interactive picker
nix run .#pi -- --resume
# resume a specific session by id (pi: --session <id>)
nix run .#pi -- --resume 01a07268-cf99-73e8
```

Sessions live in the jail-private state dir, so by design you can only
resume sessions started inside the sandbox (host pi state stays untouched).
The per-tool translation table lives in `tools.nix` (`resumeFlags`), so a
future tool with different flag names just declares its own there.

### Repo history exposure (`--git`)

By default (`--git limited`) the sandbox does **not** see your `.git`. The
working tree is copied into the runtime dir, masked paths are deleted from
the copy, and the copy is re-initialized as a fresh repo with a single
baseline commit (same branch name as the host checkout, tagged
`jail-baseline`). In-jail `git status`/`diff`/`commit`/`branch` all work -
there is simply no history to mine.

That is the point: with the real `.git` bound, `--mask` only hides the
*working copy* of a file. `git show HEAD:secrets/hiera.yaml` still prints it
straight out of the packfile. Partial or sparse clones do not fix this
(`--filter=blob:none` is lazy-fetch, sparse-checkout only controls checkout
- the objects are still there or still fetchable).

```bash
nix run .#pi -- --git limited --mask '**/*[Hh]iera*'   # default mode, masks really gone
nix run .#pi -- --git none                              # copy, no repo at all
nix run .#pi -- --git full                              # old behaviour: real tree + real .git
```

Changes made in the copy are synced back to the real tree at exit: on a tty
you get the change list and a y/N prompt, without one (e.g. `-p "..."`) the
sync happens automatically, which is what a direct workspace bind did
anyway. Change detection uses a separate git dir under the runtime dir that
is never mounted into the sandbox, so an agent cannot rewrite the baseline
to smuggle an edit past the review. The same applies to every read-write
`--mount` (see [Syncing changes back](#syncing-changes-back)), and it does
not have to wait for exit - see
[Mid-session sync](#mid-session-sync).

Trade-offs:

- The copy costs disk and time proportional to the working tree, and every
  read-write `--mount` adds its own. They land under `--tmpdir` (default
  `/tmp`, which is tmpfs on NixOS - point `--tmpdir` at real disk for big
  repos). `cp --reflink=auto` makes them near free on btrfs/xfs.
- A copy is a snapshot: edits you make on the host during the run do not
  reach the jail. `--git full` is the mode for live two-way editing.
- Gitignored paths are copied into the jail but not tracked, so changes to
  them never sync back.
- No history in the jail means no `git log`, `git blame`, rebase or
  branch-comparison work. Use `--git full` for those.
- `--overlay-workspace` only applies to `--git full`.

Work on a repo without letting the agent's edits touch the real tree until
you confirm - every write goes to a copy-on-write overlay, and on exit you
are asked whether to sync (a subset of) the changes back:

```bash
cd ~/devel/some-project && nix run .#pi -- --git full --overlay-workspace
```

This is the safest way to work on the real tree with its history: a
destructive agent run (`rm -rf`, bad rebase) can be declined at the sync
prompt and the host tree stays untouched. Three caveats: only
*confirmation* is interactive, overlayfs quirks (e.g. opaque directories)
are not fully mirrored by the sync-back, so review with `git status`/`git
diff` afterwards, and the host needs unprivileged overlayfs support -
kernel >= 5.11, plus an upper layer on a filesystem with user xattrs. The
upper layer lives under `--tmpdir`, which defaults to `/tmp`, so on a host
where that is tmpfs this needs kernel >= 6.6 or a `--tmpdir` pointed at
disk. Checked before launch, with that hint in the error.

Disable network filtering entirely:

```bash
nix run .#pi -- --no-net-filter
```

### Syncing changes back

Everything the sandbox sees through a copy or an overlay instead of a
direct bind goes through the same review-and-sync step, and that covers
extra mounts, not just the workspace - an agent let loose in a second
checkout can do exactly as much damage there as in the main one:

| Mode | Workspace and every rw `--mount` | Sync-back |
|------|----------------------------------|-----------|
| `--git limited` (default) | copy of the working tree, fresh single-commit repo | yes: prompted on a tty, automatic without one |
| `--git none` | copy of the working tree, no repo | yes: same as above |
| `--git full` | the real host tree | n/a - writes are live |
| `--git full --overlay-workspace` | copy-on-write overlay | yes, but **only** on explicit confirmation; never unattended |

`--ro-mount` is always a plain read-only bind, and a `--mount` pointing at
a single file is always bound directly (there is no tree to copy or diff) -
both are reported at launch. `--mask` globs still apply to the workspace
only.

#### Mid-session sync

A long session often produces something worth keeping - or worth reading in
a real editor - well before the agent is done. The runner writes the exact
same sync-back out as a standalone command, runnable from a second terminal
as often as you like while the session keeps going:

```bash
$XDG_RUNTIME_DIR/llm-custody/current      # the most recently started run
$XDG_RUNTIME_DIR/llm-custody/<pid>.sync   # a specific run, for concurrent sessions
```

Both are symlinks to `$RUNDIR/sync`, whose path is also printed at launch.
Each sync advances the tracking baseline, so the next one only reports what
changed since - and the exit prompt then has nothing left to ask about for
the parts already synced.

This is deliberately *not* reachable from inside the sandbox: `$RUNDIR` is
not mounted there, so an agent cannot sync its own work out unreviewed.
Syncing while the agent is mid-write is safe for the host (worst case a
file lands half-written and the next sync corrects it), but the jail-side
copy is the agent's working tree, so review as usual.

In a WezTerm pane the sync command is also published as the user var
`llm_custody_sync` (OSC 1337 `SetUserVar`, tmux passthrough handled), which
is enough for a one-key binding. It is cleared when the session ends:

```lua
-- wezterm.lua
local shell = os.getenv('SHELL') or '/bin/sh'

config.keys = {
  {
    key = 's', mods = 'CTRL|SHIFT',
    action = wezterm.action_callback(function(win, pane)
      local sync = pane:get_user_vars().llm_custody_sync
      if not sync or sync == '' then
        win:toast_notification('llm-custody', 'no live jail session in this pane', nil, 3000)
        return
      end
      -- Own pane, because the sync prompts y/N per changed tree - and held
      -- open afterwards, because a bare spawn would close it together with
      -- the report of what was applied.
      win:perform_action(
        wezterm.action.SplitPane {
          direction = 'Down',
          size = { Percent = 35 },
          command = {
            args = { shell, '-c', sync .. '; printf "\\n[finished, press enter]"; read -r _' },
          },
        },
        pane
      )
    end),
  },
}
```

Emission is automatic only when WezTerm is detected (`WEZTERM_PANE` or
`TERM_PROGRAM=WezTerm`), since terminals that do not know the sequence may
print it. `LLMCUSTODY_USERVAR=1` forces it on (e.g. a terminal that
understands the same OSC but is not detected), `LLMCUSTODY_USERVAR=0` off.

## What's isolated

**Filesystem.** The sandbox has its own mount namespace; only explicitly
bound paths are visible inside it:

- The current working directory -> `/workspace/<its basename>` (read-write),
  which is also the sandbox cwd. `/workspace` itself is just the root the
  workspace and every extra mount hang under, so the in-jail layout mirrors
  a project plus its siblings instead of scattered host paths. With the
  default `--git limited`/`none` this is a *copy* of the working tree
  without `.git`; with `--git full` it is the real directory, and then
  `.git/hooks` underneath is re-bound read-only. Either way `git` is
  shadowed in-jail to always force `-c core.hooksPath` at a read-only dir
  (the host hooks with `full`, an empty dir otherwise), so rewriting
  `core.hooksPath` in a writable `.git/config` doesn't let an agent redirect
  in-jail git to a hooks dir it controls
- The jail-private state dir `~/.config/llm-custody/<tool>/<profile>` ->
  the tool's config dir inside the sandbox (read-write)
- `~/.gitconfig` and `~/.claude/skills` (the latter one entry at a time,
  into whatever dir the tool reads skills from - `tools.nix` `skillsDir`;
  read-only by default, because skills are the instructions a jailed agent
  executes and their real host checkout is what the host's own agents and
  skillissue read, so writes would persist; `--rw-skills` mounts them
  read-write instead, opt-in only)
- Host system and user packages -> `/host-sw`, `/host-user-sw` (read-only,
  NixOS hosts only; on non-NixOS hosts the real `/usr/bin` and `/bin` are
  bound read-only instead, so system-installed tools are available there
  too)
- `/nix/store` (read-only)
- Any directories added via `--mount` / `--ro-mount`, by default under
  `/workspace` next to the workspace itself. A read-write one is isolated
  the same way the workspace is (copy, overlay or real tree, per `--git` /
  `--overlay-workspace`) and reviewed on the way back out - see
  [Syncing changes back](#syncing-changes-back)

The sandboxed process runs without `CAP_SYS_ADMIN` (bwrap
`--cap-drop CAP_SYS_ADMIN`), so it cannot create bind mounts or remount
anything regardless of syscall flavor. That matters because `mount --bind`
that an agent runs via the jail's own `mount` binary uses the mount API
(`open_tree`/`move_mount`), not `mount(2)` - a seccomp list of the classic
mount syscall alone wouldn't block it. The seccomp denylist additionally
blocks `open_tree`/`move_mount`/`mount_setattr` (and the fsopen family) as
a second layer. So a masked file cannot be recovered by bind-mounting the
workspace elsewhere and reading the original. Only the jail-private state
file and workspace, which are writable by design, are exposed.

All other host paths are invisible inside the sandbox.

On NixOS hosts, system packages (`/run/current-system/sw`) and user packages
(`/etc/profiles/per-user/$USER`) are automatically mounted and added to
`PATH`, so tools like `rg`, `git`, `jq`, etc. are available without
hardcoding them, as long as the host has them installed.

With `--git full`, the workspace is a direct read-write bind of the host
directory, not a copy-on-write layer - a destructive command run by the
agent (`rm -rf`, a bad rebase, force-push, ...) mutates the real working
tree immediately. The default `--git limited` avoids that by construction
(the agent works on a copy and the damage shows up in the sync-back change
list first). In every mode two safety nets run on the host repo,
neither a full substitute for backups: if the workspace is a git repo, a
`git stash create` snapshot is taken before launch (tracked changes only,
doesn't touch the working tree or `git stash list` - just prints a recovery
hash), and `core.hooksPath` is diffed before/after the run with a loud
warning on exit if it changed (catches the case where a plain `git` run on
the host *outside* the jail later would honor a hooks dir the agent
planted). With `--overlay-workspace` (see above) the tree is instead
copy-on-write and nothing reaches the host until you confirm a sync-back.

**Processes.** bwrap unshares mount, PID, IPC, and UTS namespaces - the
sandboxed process has its own PID 1 and no visibility into host processes.
User and network namespaces are shared with a dedicated long-lived netns
holder process (not the host's), so the sandbox gets a private network too.

**Environment variables.** Only these are forwarded into the sandbox:

- `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- `AWS_*`
- `TERM`, `COLORTERM`, `LINES`, `COLUMNS`, `LANG`, `LC_ALL`, `LC_CTYPE`
- Anything passed via `--env KEY=VAL`

`DISPLAY`, `XAUTHORITY`, and `WAYLAND_DISPLAY` are explicitly stripped by
default. This prevents tools like `pi` from trying (and failing) to use X11
clipboard helpers inside a sandboxed session with no real display access; a
terminal that supports OSC 52 (e.g. WezTerm, kitty, Alacritty) then handles
copy-on-select through the terminal stream instead. To actually pass through a
local X11 or Wayland session, run with `--x11`.

Warning: `--x11` weakens the sandbox. X11 does not isolate clients from each
other, so a sandboxed process can sniff keystrokes and screenshots of any
other X11 client on the same server. Prefer OSC 52 unless you really need
native clipboard helpers.

All other host environment variables are stripped.

On top of those, each tool's launcher sets a fixed set of its own
(`launchers/<tool>.nix` `extraEnv`), applied before the `--env` pairs so
yours override them. For claude that is `DISABLE_AUTOUPDATER`,
`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` (the store is read-only, and this
is what keeps statsig/sentry off the whitelist) and `IS_SANDBOX` (the
in-jail uid is 0, since the netns holder maps inner uid 0 to your host uid
so workspace writes stay owned by you - claude otherwise refuses
`--dangerously-skip-permissions` for a uid-0 process).

**Network.** By default, outbound access is restricted via DNS-based domain
filtering and a port-level firewall inside a private network namespace:

- DNS resolution (via a per-run dnsmasq instance) is limited to the tool's
  whitelisted API/service domains
- Only HTTP/HTTPS traffic (ports 80/443) is allowed outbound to IPs that a
  whitelisted domain actually resolved to (nftables set populated from
  dnsmasq's query log) - a hardcoded-IP bypass that skips DNS still hits
  the drop rule
- Custom API endpoints (via `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) are
  automatically whitelisted
- Additional domains can be added with `--allow-domain` (suffix/subdomain
  matched, no wildcard/glob support yet), or persistently via
  `~/.config/llm-custody/domains`
- Whitelisted domains are pre-resolved into the nftables sets before the
  sandbox starts (first-connect race mitigation); later DNS answers keep
  the sets fresh
- Use `--no-net-filter` to disable all network restrictions

Default allowed domains are per tool (`tools.nix` `allowedDomains`).

- `pi`: `pi.dev`, `api.anthropic.com`, `api.openai.com`, `auth.openai.com`,
  `chatgpt.com`, `generativelanguage.googleapis.com`, `github.com`,
  `api.github.com`, `openrouter.ai`, `api.deepseek.com`, `api.mistral.ai`,
  `api.x.ai`, `api.groq.com`, `api.cerebras.ai`, `api.novita.ai`
- `claude`: `api.anthropic.com`, `platform.claude.com`, `claude.ai` (the
  last two only matter for the in-jail login - authorize page, code
  callback and token exchange live on `platform.claude.com`, which is where
  the old `console.anthropic.com` endpoints moved), `github.com`,
  `api.github.com`. Plugin/marketplace installs need
  `--allow-domain registry.npmjs.org` (and possibly
  `raw.githubusercontent.com`) on top.

> [!NOTE]
> Dual-stack: slirp4netns's IPv6 path (`-6`, marked experimental upstream)
> is enabled, with a matching IPv6 nftables set/rule and dnsmasq AAAA
> catch-all alongside the IPv4 ones. Not yet battle-tested against a
> real IPv6-only endpoint.

## Dangerous mode

`--dangerous` passes the tool's own skip-all-permission-prompts flag
(`tools.nix` `dangerousFlag`); for claude that is
`--dangerously-skip-permissions`. Pi has no such flag, so `--dangerous`
errors out for it - there, project trust is set to `trusted` in the
jail-private `settings.json` on every launch instead, which is effectively
the same thing (A.k.a. YOLO forever).

Either way the agent can execute arbitrary commands, write to any mounted
directory, and make network requests to whitelisted domains without asking,
exactly as it would run outside the jail.

Independently of the flag, both tools start with their one-time trust and
onboarding prompts pre-accepted in the jail-private state dir (claude:
`.claude.json` keyed by the workspace mount path; pi:
`defaultProjectTrust`). Without that, a non-interactive `-p` run would hang
on the trust dialog on every fresh profile.

Network filtering remains active regardless - the agent can only reach
whitelisted domains unless you pass `--no-net-filter`.

**If you're relying on this for isolation:**
- Scope API keys to the minimum permissions needed
- Avoid mounting directories containing secrets
- Be cautious with `--allow-domain` - domains like `github.com` or
  `npmjs.org` are bidirectional and could be used for data exfiltration
- Review agent output before trusting it

## How it works

```
+-- Host -------------------------------------------------+
|  nix run .#<tool>                                       |
|    v                                                     |
|  writeShellApplication (lib/mkBwrapRunner.nix)          |
|    - parses CLI args                                     |
|    - runs launchers/<tool>.nix's bootstrapScript         |
|      directly against the real host state dir            |
|    - unshare --user --net (+ newuidmap/newgidmap) holder  |
|    - slirp4netns for outbound connectivity                |
|    - dnsmasq (domain whitelist) + nftables (IP gate)      |
|    - opens seccomp fd (lib/seccomp-denylist.nix)          |
|    - nsenter's into the netns holder, execs bwrap ...     |
|    - on exit (and on demand, lib/sync-back.sh): reviews   |
|      the jail copies/overlays back into the host trees    |
|                                                            |
|  +-- bwrap sandbox (mount/pid/ipc/uts/user ns) --------+ |
|  |  /nix/store         <- ro-bind                        | |
|  |  /workspace/<name>  <- bind (rw, cwd)                 | |
|  |  /home/user/<cfg>   <- bind (rw, jail-private state)  | |
|  |  seccomp denylist applied at the final execve         | |
|  |  exec the tool                                        | |
|  +-------------------------------------------------------+ |
+-----------------------------------------------------------+
```

No guest kernel, no disk image, no 9p - everything above is real bind mounts
and Linux namespaces on the host kernel.

## Overriding the tool package

The runner is built with `lib.makeOverridable`, so `pi-coding-agent` /
`claude-code` can be swapped without forking the flake:

```nix
# flake.nix (consumer)
let
  llm-custody = inputs.llm-custody.packages.${system};
in
  llm-custody.claude.override {
    claude-code = my-pinned-claude-code;
  }
```

Useful for pinning a specific version, applying local patches, or testing an
unreleased build.

## Adding a new tool

1. Add `launchers/<tool>.nix`: a plain function
   `{ pkgs, <tool-package>, ... }: { toolPackage; extraEnv ? {}; bootstrapScript ? ""; }`.
2. Add an entry to `tools.nix` (`launcherModule`, `configDirName`,
   `configEnvVar`, `skillsDir`, `allowedDomains`, `resumeFlags`, plus
   optional `dangerousFlag` and `mergeSkipKeys`).
3. Wire the tool's package into `flake.nix`'s `defaultArgs`.
4. `nix run .#your-tool` - the flake generates a runner automatically.

CLI flags like `--immutable`, `--nix-env`, and `--devenv` existed in the old
QEMU jail and haven't been ported to the bwrap runner yet; a new tool that
needs one of these needs that support added to `lib/mkBwrapRunner.nix` too.

## License

This project is licensed under the [MIT License](LICENSE), carried over
from the upstream project this was forked from.
