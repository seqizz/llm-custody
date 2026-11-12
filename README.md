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

Everything else on the host - the package profile the jail sees, the
requests it blocks on, the trees attached to a running session - is one
command, `llm-custody`, which is the flake's default package:

```bash
nix run . -- launch pi -p "Refactor the auth module"      # same as .#pi
nix run . -- session list                                 # what is running
nix run . -- toolbox add ripgrep                          # provision a tool
nix run . -- request answer                               # answer what a jail asked
```

See [One command on the host](#one-command-on-the-host) for the whole tree.

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

## One command on the host

Everything host-side is one binary with a subcommand per feature, so the
sandbox has a single entry point to discover:

```
llm-custody [--dir TOOLBOX] [--pid PID] [--pause] <command> [ARG...]

  launch TOOL ...   start a sandboxed tool, no TOOL lists them
  mount ...         attach a host tree to a live session, or detach one
  sync ...          fold a live session's isolated trees back to the host
  session list      the live sessions and what each one has outstanding
  request ...       the package and mount requests jailed agents wait on
  toolbox ...       the package profile every jail sees on its PATH
  lease ...         how long an added package survives without being used
  serve             the per-jail request broker, started by the runner
```

`--dir` picks the toolbox profile to act on, `--pid` the session (default:
the most recently started one), and `--pause` waits for a keypress before
exiting, so a pane a terminal keybinding spawned does not close over the
output. `llm-custody help <command>` and `llm-custody <command> --help` are
the same page.

The package is `packages.default`, also exposed as `packages.llm-custody`,
so `nix run . -- session list` works straight from a checkout. The per-tool
runners stay what `nix run .#pi` and `nix run .#claude` run, and
`llm-custody launch pi` is the same runner reached through the umbrella.

`session list` is the overview of what is running, and needs no terminal
integration to read:

```console
$ llm-custody session list
pid 48213  pi  /home/user/devel/llm-custody
    git limited, no overlay, 7 unsynced path(s), 1 mount(s), 0 request(s) pending
    sync   /tmp/tmp.T4dWf4vSKz/sync
    mount  /tmp/tmp.T4dWf4vSKz/mount
```

The two launcher paths in that block are what `sync` and `mount` exec for
that session; they are the session's own, so a second terminal needs nothing
from the first.

`custody-request` is the same binary under another name, on the jail's PATH,
and is the only part of this an agent can reach - see [Asking from inside the
jail](#asking-from-inside-the-jail).

## Usage

```
llm-custody-<tool> [options] [-- tool-args...]
llm-custody launch <tool> [options] [-- tool-args...]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--profile NAME` | State profile, a subdir of `--state-dir/<tool>` | `default` |
| `--state-dir PATH` | Jail state root dir, mounted read-write | `~/.config/llm-custody` |
| `--toolbox-dir PATH` | Operator package profile, bound read-only at `/toolbox` and prepended to the jail's PATH (see [Providing packages](#providing-packages)) | `--state-dir/toolbox` |
| `--same-path` | Mount the workspace and every `--mount` at their host paths instead of under `/workspace` | off |
| `--tmpdir PATH` | Directory to use for runtime data | `${TMPDIR:-/tmp}` |
| `--mount HOSTPATH[:GUESTPATH]` | Extra read-write mount (repeatable). Isolated like the workspace: copy + sync-back under `--git limited/none`, copy-on-write with `--overlay-workspace`, real tree with `--git full`. A single file is always bound directly. Detachable while the session runs when GUESTPATH is directly under `/workspace` or `/mnt`, see [Live mounts](#live-mounts) | `/workspace/<basename HOSTPATH>` |
| `--ro-mount HOSTPATH[:GUESTPATH]` | Extra read-only mount (repeatable) | `/workspace/<basename HOSTPATH>` |
| `--allow-domain DOMAIN` | Add domain to network whitelist (repeatable) | tool defaults |
| `--env KEY=VAL` | Pass environment variable into the sandbox (repeatable) | - |
| `--x11` | Allow X11/Wayland clipboard access; without it, display vars are stripped so terminals use OSC 52 | off |
| `--git full\|limited\|none` | How much of the repo the jail sees: `limited` = copy of the working tree as a fresh single-commit repo (no host history), `none` = same copy without a repo, `full` = the real tree including `.git` | `limited` |
| `--overlay-workspace` | Mount the workspace and every rw `--mount` copy-on-write; edits sync back to the real trees only on explicit confirmation (needs `--git full`) | off |
| `--sync-exclude GLOB` | Never sync paths matching GLOB back to the host tree, in any mode that syncs (repeatable). Matched against tree-relative paths; unlike `--mask`, `*` crosses `/` here, so `*.log` covers every depth | - |
| `--watch-interval N` | Seconds between unsynced-change checks during the session; 0 disables the watcher (see [Unsynced-change indicator](#unsynced-change-indicator)) | `15` |
| `--selftest` | Run a sandbox self-check (full chain incl. netns, seccomp and the git wrapper) and exit; no in-jail `/login` needed | off |
| `--dry-run` | Resolve everything (mounts, masks, domains, env, bwrap arguments) and print it instead of launching. Starts no network namespace and copies no trees | off |
| `--list-profiles` | List the state profiles of this tool, with session counts, and exit | off |
| `--list-sessions` | List the sessions stored in the selected profile, newest first, and exit | off |
| `-q`, `--quiet` | Only warnings and errors | normal |
| `-v`, `--verbose` | Extra detail about mounts and network setup | normal |
| `-c`, `--continue` | Resume the most recent session, translated to the tool's own continue flag | - |
| `-r`, `--resume [ID]` | Open the tool's session picker, or target a specific session id directly | - |
| `--dangerous` | Pass the tool's own skip-all-permission-prompts flag (claude: `--dangerously-skip-permissions`; errors out for a tool that has none) | off |
| `--rw-skills` | Mount skills read-write instead of read-only (only for deliberate in-jail skill maintenance - an agent can edit files the host reads and skillissue may push) | read-only |
| `--mask GLOB` | Hide files/dirs matching GLOB in the workspace **and in every extra mount** (deleted from a jail copy; shadowed by an empty read-only file/dir where the tree is bound directly, i.e. `--ro-mount` and `--git full`; repeatable) | - |
| `--max-mem SIZE` | Memory limit for the jail (`512M`, `8G`; suffix K/M/G/T), swap disabled for it too (see [Resource limits](#resource-limits)) | no limit |
| `--max-cpu PCT` | CPU quota in percent of one core, `200` = two cores | no limit |
| `--max-pids N` | Maximum number of tasks (processes and threads) in the jail | no limit |
| `--no-net-filter` | Disable network filtering (unrestricted access) | filtering on |
| `--merge-config` | Interactively merge root-level keys from the host tool's settings.json into the jail-private one; each differing key prompts y/N individually ('a' accepts the rest) | off |
| `--merge-config-from PATH` | Same as `--merge-config` with an explicit source file instead of the default host tool settings.json | - |
| `-h`, `--help` | Show help | - |

Any other argument (e.g. pi's `-p`) is passed straight through to the tool,
so the quick-start style `nix run .#pi -- -p "..."` works as written - the
runner only intercepts its own flags. The one exception is a bare absolute
path: that is almost always a second `--mount` written without its flag, so
it is refused rather than forwarded as a prompt. Put it after `--` if the
tool really is meant to receive it.

Environment: `LLMCUSTODY_PROFILE`, `LLMCUSTODY_STATE_DIR` and
`LLMCUSTODY_TOOLBOX_DIR` are the defaults for `--profile`, `--state-dir` and
`--toolbox-dir`, `LLMCUSTODY_USERVAR=1|0` forces the WezTerm user-var
emission, `NO_COLOR` disables coloured output, and `PAGER` is used for the
`d` answer at the sync prompt.

Shell completions for bash, zsh and fish ship in the package under
`share/`, so they are picked up automatically wherever the package is on a
profile.

Not yet ported from the old QEMU jail: `--immutable`, `--devenv`.
`--nix-env` is superseded by the toolbox below, which provisions from the
host instead of per run.

### Providing packages

Inside the sandbox `/nix/store` is read-only and no binary cache is in the
domain whitelist, so nothing there can realize a derivation: `nix build`,
`nix-shell` and `,` (comma) all fail. That is deliberate - a shared store the
jail could write to is not a sandbox - but it means a tool the host does not
already have on PATH has no way in on its own.

The toolbox is that way in: a plain nix profile on the host, bound read-only
at `/toolbox` and prepended to the jail's PATH. One profile per
`--state-dir`, shared by every tool and every `--profile` under it, because a
tool worth provisioning once is worth having everywhere and none of it is
session state.

```bash
llm-custody toolbox add lua5_4 shellcheck   # install (or renew), host-side
llm-custody toolbox list                    # what is in there
llm-custody lease list                      # ... and how long it stays
llm-custody lease renew shellcheck          # push its lease out, install nothing
llm-custody toolbox remove shellcheck       # (alias: rm)
llm-custody lease pin shellcheck            # never expire this one
llm-custody toolbox upgrade                 # re-resolve every installed ref
llm-custody toolbox upgrade ripgrep         # or just one of them
llm-custody lease prune                     # drop what nobody asked for lately
llm-custody lease gc                        # drop the old generations
llm-custody toolbox                         # prompt for a line of names

llm-custody request list                    # what the running jails asked for
llm-custody request approve 41207.1         # install it and unblock the jail
llm-custody request deny 41207.1 --reason X # refuse, profile untouched
```

Without the command on the host's PATH, every one of those reads
`nix run . -- toolbox add lua5_4 shellcheck` and so on.

`llm-custody` is a Rust binary (`toolbox/`) with no dependencies
outside std, so it builds offline. It calls `nix` and `nix-store` with argv
arrays and reads `nix profile list --json`: nothing an agent can influence -
an attribute name, a reason string - is ever assembled into a shell command,
and no output is scraped out of human-readable text. `nix` itself is
deliberately not in the package's closure, because the host's own nix
(possibly Lix) is the one that matches the running daemon.

A bare name resolves against `nixpkgs` (override with
`LLMCUSTODY_TOOLBOX_FLAKE`); anything containing `#` or `:` is handed to nix
verbatim as a flake reference.

`upgrade` rebuilds the installed entries from the flake refs they were
installed with, so what it picks up depends on what those refs resolve to
now: the registry's `nixpkgs` moves on its own (subject to `tarball-ttl`),
while an `LLMCUSTODY_TOOLBOX_FLAKE` pointing at a pinned nixpkgs only moves
when that pin does. It goes through the same lock and `current` retarget as
`add`, which is why it is a subcommand - a bare `nix profile upgrade
--profile ...` builds a generation that no running jail sees and that nothing
holds a GC root on. Like `add`, it leaves the previous generation pinned
behind it; see [Garbage collection](#garbage-collection).

**Additions apply to a running session.** The bind is live: `nix profile
install` writes a new generation, `llm-custody toolbox` retargets the
`current` symlink the sandbox resolves through, and the next PATH lookup
inside the jail finds the new binary. Nothing has to be restarted, which is
the point - the agent asks for a tool mid-task and keeps going once you have
provisioned it.

Without `--dir`, the CLI targets the most recently started session's toolbox
(`$XDG_RUNTIME_DIR/llm-custody/current.toolbox`, with `<pid>.toolbox` for a
specific one) and falls back to the default path when no session is running.
So answering a request needs no knowledge of which `--state-dir` that session
used. The same path also goes out as the `llm_custody_toolbox` WezTerm user
var, for a terminal keybinding that prompts for a name and runs the install;
`--pause` holds the output on screen when that binding spawns a throwaway
pane.

A second var, `llm_custody_toolbox_cmd`, carries the CLI's own store path.
`nix run .#pi` is the documented way to start a jail and it installs nothing
on the host, so a keybinding that called `llm-custody` by name would find no
such command; the store path always resolves. The var keeps the name it was
introduced with, because consumers key on it.

### Asking from inside the jail

An agent that needs a tool runs, in the sandbox:

```bash
custody-request shellcheck --reason "Validate scripts"
```

and blocks there. The request shows up on the host:

```console
$ llm-custody request list
ID      PACKAGE     AGE  JAIL               REASON
41207.1 shellcheck  2m   pi /workspace/foo  Validate scripts
$ llm-custody request approve 41207.1
```

The same channel carries a request for a host directory:

```bash
custody-request --mount /srv/datasets/2024 --reason "The task reads the raw exports"
```

```console
$ llm-custody request list
ID      REQUEST                    AGE  JAIL               REASON
41207.2 mount /srv/datasets/2024   1m   pi /workspace/foo  The task reads the raw exports
$ llm-custody request approve 41207.2 --mode ro
```

The agent names a path and a reason, nothing else; how the tree is attached
is the operator's choice at approval (`--mode ro|full|limited|none|overlay`,
default read-only, and the interactive `request answer` asks for it).
Approval runs the session's own mount launcher, the same one a keybinding
runs - see
[Live mounts](#live-mounts) - and the client is told where the tree landed
(`/workspace/2024` here).

Approval of a package goes through the same `add` the host CLI uses, so the
package is installed, leased, and on the PATH by the time the client unblocks. It
appears in every jail sharing that **toolbox**, which is not the same as
every jail: a runner starts its broker with its own `--toolbox-dir`, so a
session under a different `--state-dir` has a different profile and will not
see the package (see [Providing packages](#providing-packages)). Check which
toolbox a broker serves with `cat
$XDG_RUNTIME_DIR/llm-custody/brokers/*/meta`.

Denial (`request deny ID [--reason TEXT]`) leaves the profile untouched and
the client exits 3, which the agent is told to read as a final answer rather
than a retry. Nothing happens without an operator: there is no auto-approval and
no timer that approves.

A request that nobody answers before `--timeout` exits **4**, not 3, and says
"unanswered" rather than "refused". The distinction is the whole reason exit 4
exists: a denial is an answer and the agent is told to accept it, while an
operator who was away from the terminal has decided nothing, and an agent that
recorded that as a refusal would be reporting a decision that was never made.

Each jail runner starts its own broker (`llm-custody serve`) and binds
**one** of its two sockets into the sandbox:

| Socket | Bound into the jail | Verbs |
|--------|--------------------|-------|
| `request.sock` | yes, at `/run/custody-request.sock` | `request` (a package or a mount) |
| `control.sock` | **never** | `list`, `approve`, `deny` |

That split is the whole authorization model, and it is the reason there are
two sockets rather than one with an `approve` verb on it: the jail runs as the
same uid as the operator, so peer credentials cannot tell an agent's
connection from a human's. The jail-facing socket parses no other verb at all.
Requests from it are additionally restricted to **bare nixpkgs attributes** -
`ripgrep`, `python3Packages.black` - because a flake reference is a URL, and
choosing a URL to fetch with the host's network and the host's nix is the
operator's call. Host-side `add` still takes full refs. A mount request is
restricted the same way to an absolute path with no `..` in it, and carries
no mode: read-write access to a real host tree is never something the jail
gets to ask for by name.

### Being told, instead of polling

A request blocks the agent, so the operator needs to find out without running
`request list` on a timer. The broker publishes every queue change three
ways, all of them best-effort and none of them able to affect the request
itself:

| Sink | When | Notes |
|------|------|-------|
| `<broker>/pending` | every change | the count, atomically rewritten; what a second terminal can read at any time |
| `llm_custody_requests` user var | on change | OSC 1337, empty when the queue drains |
| `--notify-hook` | every change | your command, argv only |

`request list --json` prints the queue flattened across every broker, oldest
first - the one that has been blocking an agent longest is the one to answer
first, and a stable order keeps a picker's entries from jumping around.

**The tab badge** in `llm-custody.lua` recolours rather than growing: the
same `▥` at the same width, orange when a request is pending, green when
there is unsynced work, plain otherwise. Orange wins because the two states
differ in who has to act - unsynced work waits on nothing, a pending request
has stopped the agent until you answer.

**`llm-custody request answer`** is the queue, interactively:

```console
2 pending package request(s)

   1  pdftocairo  2s  pi ~/devel/llm-custody
      needs pdftocairo for the thing
   2  shellcheck  1s  pi ~/devel/llm-custody
      needs shellcheck for the thing

  type 1-2 to approve, 1d-2d to deny, r to refresh, q to quit
> 
```

Rows are numbered because a request id is a broker pid and a counter
(`171481.2`) - fine for routing, hopeless to type. It redraws after each
answer and leaves when the queue empties.

That picker lives in the CLI rather than in the terminal integration, which
is what `Ctrl+Shift+r` runs in a split. WezTerm has a selector widget, but it
is a full-window overlay with no size control, and it would have made the
feature WezTerm-only; a command in a pane is sized by the pane and works the
same over ssh, under tmux and in a terminal with no picker widget at all.
`request list --json` remains for anything that does want to build its own,
with a short read timeout on the CLI side so a wedged broker cannot freeze a
caller that is blocking on it.

The broker writes that user variable straight to the terminal, mid-session,
while the jailed tool owns it. That is safe for a narrow reason worth
recording: the kernel serialises tty writes, so a single `write()` of a
complete sequence cannot interleave with the tool's output, and `SetUserVar`
moves no cursor and changes no SGR state, so nothing renders. The emission is
therefore one `write_all` of one buffer, deliberately, and only on a change
of count. Whether to emit at all is decided by the runner and passed in with
`serve --uservar 0|1`, never re-derived - several processes publish these
variables and they have to agree.

The hook gets six separate argv values and no shell:

```
<hook> <event> <id> <attr> <reason> <count> <label>
```

`event` is `start`, `request`, `approved`, `denied` or `dropped`, and
`dropped` fires only for a request that really left the queue unanswered (a
client that hung up, or the hold time running out) - never as a second event
for one that was approved or denied. `reason` is whatever explains that
event: the agent's justification everywhere except `denied`, where it is the
operator's refusal, which is the half the operator has not already read.

The attr and reason come from inside a jail, so the one thing that must never
happen to them is being pasted into a command line for something to re-parse;
a reason of `Validate scripts; rm -rf /` arrives as one argument, and
`toolbox/src/broker.rs` has tests asserting exactly that - one on the argv the
broker builds, one running a real hook that reports what it was handed and
checking that nothing in the reason executed on the way. Set it with
`--notify-hook PATH` or
`$LLMCUSTODY_NOTIFY_HOOK`. A hook that is missing, unexecutable, slow or
failing is logged to `broker.log` and changes nothing: it is spawned, never
waited on (a reaper thread collects it), so a hook that sleeps for a minute
does not delay the approval by a millisecond. `notify-send` is the obvious
one to put there if you want a desktop popup as well.

Both sockets live under `$XDG_RUNTIME_DIR/llm-custody/brokers/<pid>/`, so
several jails broker in parallel and `request list` aggregates across all of
them; a request id is `<broker>.<n>`, which is how `approve` finds the
broker holding it. Requests are bounded (8 KiB per message, 128 characters of
attribute, 512 of reason, 32 pending per broker) and held until approved,
denied, disconnected, or timed out (`serve --timeout`, default 30m). A client
that dies is dropped from the queue within a poll interval rather than
occupying it until the timeout, and killing a broker unblocks whatever was
waiting on it with exit 4.

A broker also asks the kernel to SIGTERM it when its parent dies
(`PR_SET_PDEATHSIG`, re-checked immediately for the case where the parent was
already gone). The runner's exit trap covers every ordinary end of a session;
this covers the runner being SIGKILLed or its terminal going away, which would
otherwise leave a live broker serving a jail that no longer exists - and a
live one is exactly what the pid check below refuses to prune.

The runner removes the broker's registration on exit; the broker also removes
it on SIGTERM/SIGINT itself, and the host CLI prunes any registration whose
pid is gone. Three layers, because the only thing worse than a stale socket is
a request list the operator cannot act on.

If no broker is running - an older runner, or `serve` failed to start - the
launcher notice tells the agent to fall back to ending its reply with:

```
required packages: lua5_4, shellcheck
good-to-have packages: ripgrep
```

`llm-custody toolbox add` accepts that line pasted verbatim - the labels and
commas are stripped - so answering it is a copy, a paste and a return.
`, -p <command>` works inside the jail (nix-index's database is local) and is
how the agent turns a command name into a nixpkgs attribute.

The toolbox is bound **read-only**. A writable one would put the front of the
jail's own PATH under the agent's control, which is worth rather more to a
misbehaving agent than any single package.

**A tool that prepends its own PATH entries sits ahead of the toolbox.** The
runner sets `PATH` once, with `/run/llmcustody-bin` and then
`/toolbox/current/bin` at the front, but that is only the PATH the tool
*starts* with. pi, for one, prepends `$PI_CODING_AGENT_DIR/bin` plus the store
paths of the fd and ripgrep it ships with, so a toolbox `fd` is installed,
leased and completely invisible to it. Check before provisioning something a
tool may already carry:

```bash
# in the jail
echo "$PATH" | tr : '\n' | head -5
command -v fd
```

The same ordering means the `git` hooks wrapper in `/run/llmcustody-bin` can
be shadowed by a tool that prepends a directory the agent can write - pi's
`$PI_CODING_AGENT_DIR/bin` is inside the rw-bound state dir. That is a known
limit rather than a hole to plug: the wrapper defends against a rewritten
`.git/config`, and an agent set on avoiding it can invoke git by its store
path regardless (see [Repo history exposure](#repo-history-exposure-git)).

One toolbox is shared by every jail under the same `--state-dir` - both
tools, every `--profile`, any number of concurrent sessions. That is the
point (a tool provisioned once is wanted everywhere, and none of it is
session state), and `--toolbox-dir` separates them when it is not. Concurrent
`add`s are serialised on a lock file in the toolbox directory: nix locks the
profile for its own generation switch, but `current` is retargeted after that
lock drops, so two interleaved adds could otherwise leave it on the older
generation.

### Package leases

Provisioning is a one-way ratchet without something to expire it: a package
added for one afternoon's task stays on every future jail's PATH, and keeps
its whole closure pinned, until somebody remembers its name and removes it.

Every `add` therefore stamps a lease: one file per package under
`<toolbox-dir>/leases/`, named and filled with the package's nix profile
element name, its mtime being the last time an operator asked for it.
`prune` removes the elements whose lease has gone 30 days unrenewed, deletes
those lease files, retargets `current` and wipes the generations that held
them. Every jail start runs it (see below), so this happens whether or not
anyone thinks about it.

```bash
llm-custody toolbox add shellcheck     # install, 30-day lease starts
llm-custody toolbox add shellcheck     # ... and that is also how you renew
llm-custody lease renew shellcheck     # renew without reinstalling
llm-custody lease pin shellcheck       # drop the lease: permanent
llm-custody lease list                 # package, lease age, expiry
llm-custody lease prune --older-than 30d
llm-custody lease prune --dry-run      # report what would go
```

**`add` is also the renewal.** The thing an operator does naturally - answer
the same request again when an agent asks for a tool it last used two months
ago - is the thing that keeps the tool alive. Re-adding something already
installed skips the install (nix would refuse a second element under an
existing name anyway) and only pushes the lease out.

`renew` does that half on its own, for the two cases `add` cannot express:
pushing a lease out without naming a flake reference, and putting a
*permanent* package back under a lease. It never touches the profile.

`prune`'s period defaults to 30 days and is spelled like `gc`'s:
`--older-than 30d`, or a bare count of days. `LLMCUSTODY_TOOLBOX_LEASE_DAYS`
moves that default for a host that wants a different one, and `lease list`
takes the same flag so its expiry column can be read against another
lifetime.

`lease list` lists the leased packages with the age of each lease and what is
left of it, then the installed elements that hold no lease at all:

```
ripgrep                  leased 3d ago, expires in 27d
shellcheck               leased 45d ago, EXPIRED
git                      permanent (no lease)
```

**A package with no lease file is permanent.** That covers everything
provisioned before leases existed and anything installed with a plain `nix
profile install --profile ...`, neither of which anyone agreed to have
expire. `pin` puts a package into that state by deleting its lease, so
permanence stays the *absence* of state rather than a second flag that could
disagree with the first; `add` puts it back under one.

`pin` and `prune` take the same lock as `add` and `upgrade`, and `prune`'s
effect is live: a command a running jail had a moment ago can be gone from
its next PATH lookup. That is the deal a lease makes, and the session carries
on without it.

**Expiry runs itself, at every jail start.** The broker each runner starts
does one `prune` plus one `gc` in the background, right after its socket comes
up: a jail start is the one moment that reliably happens, and the broker is
already running host-side with the toolbox and its lock. It costs the launch
nothing (the runner is waiting for `request.sock`, not for nix), failures are
a line in `broker.log` and nothing else, and
`LLMCUSTODY_TOOLBOX_AUTOPRUNE=0` turns it off. Running `prune` by hand is
then only for expiring something early or with a different lifetime.

Leaving it to an operator-run `prune` was the earlier design, and it expires
packages on the days somebody remembers to type it, which is not a policy.

What that pass does **not** do is collect garbage. It unpins - the profile
elements, then the generations that held them, then the generations `add` and
`upgrade` left behind - and leaves reclaiming the store to whatever
`nix-collect-garbage` the host already runs, which is where the policy for the
rest of the store lives. So a cleanup alias needs nothing from this project:
by the time it runs, the expired paths are already unreferenced.

### Garbage collection

A profile outside `/nix/var/nix/profiles` is not a GC root on its own, so
`llm-custody` writes `current` with `nix-store --indirect --add-root`
and the toolbox survives `nix-collect-garbage`. If that call fails it falls
back to a plain symlink and says so - the contents then last until the next
GC, and a re-`add` restores them.

Only the *current* generation is rooted that way. Every `add` or `upgrade`
leaves the one before it behind as a `profile-N-link` symlink, and nothing
cleans those up: a custom profile path gets no automatic generation pruning,
and `nix-collect-garbage -d` does not know about this profile at all. An
upgraded toolbox is the expensive case, since each stale generation pins a
whole old closure of everything in it.

```bash
llm-custody lease gc                     # drop every generation but the current one
llm-custody lease gc --older-than 30d    # keep the recent ones
llm-custody lease gc --dry-run           # report first
```

Both of these run on their own at every jail start (see [Package
leases](#package-leases)), `gc` with the lease period as its `--older-than`
and a floor of one day. Calling either by hand is for doing it sooner, or
harder: a bare `gc` keeps only the current generation, which nothing automatic
will ever do.

`gc` only unpins; it frees nothing by itself. Run `nix-collect-garbage`
afterwards to actually reclaim the store paths. To check what is holding a
generation:

```bash
nix-store --query --roots ~/.config/llm-custody/toolbox/profile-1-link
```

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

See exactly which trees would be mounted where, with the full bwrap
argument list, without starting anything:

```bash
nix run .#pi -- --mount /srv/data --mask 'secrets/*' --dry-run
```

List the state profiles of a tool and the sessions inside one:

```bash
nix run .#pi -- --list-profiles
nix run .#pi -- --profile work --list-sessions
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

### Live mounts

A session's extra mounts are not fixed at launch. Any tree whose guest path
is directly under `/workspace` or `/mnt` (which is every `--mount` and
`--ro-mount` without an explicit target) can be detached while the agent
runs, and more can be attached there, by the operator from a second
terminal or by the agent asking through `custody-request --mount` and the
operator approving. The CLI parameters are unchanged; what changed is
that every extra mount, launch-time ones included, now goes through one
controller.

```bash
llm-custody mount add /srv/datasets/2024                     # read-only, at /workspace/2024
llm-custody mount add --mode limited /devel/other-checkout   # synced copy, like --git limited
llm-custody mount add --mode full --guest /mnt/scratch /tmp/scratch
llm-custody mount list
llm-custody mount remove 2024                                # by name or by guest path
```

`add` takes the same modes the workspace has (`ro`, `full`, `limited`,
`none`, `overlay`; `copy` is an alias for `limited`), defaulting to
read-only. A copy or overlay mount joins the session's sync manifest the
moment it is attached, so the dirty indicator counts it, `llm-custody sync`
folds it back, and the exit trap reviews it like one from launch. `remove`
of such a mount offers the sync-back first (`--auto` syncs a copy without
asking, `--discard` skips it), then detaches.

`llm-custody mount` is a front end over the session registry, like
`llm-custody sync`: it finds the most recent session's launcher
(`$XDG_RUNTIME_DIR/llm-custody/current.mount`; `llm-custody --pid N mount`
for another one, the flag being global and therefore written before the
command), and with no command at all it prompts for a path and mounts it
read-only - the shape a terminal keybinding wants. The launcher path is also
published as the `llm_custody_mount` user var next to `llm_custody_sync`,
and `--pause` keeps a spawned pane open over the output. A session started
by a runner from before live mounts existed has no launcher and is reported
as such.

How it works without touching the jail: the namespace holder the runner
starts (`unshare --user --mount --propagation shared`, plus `--net` with
the filter on) owns a mount namespace in which every mount is `shared`,
and bwrap, started inside it, marks the jail's tree `slave` to it. The
runner binds two empty directories from the runtime dir into the jail,
`/workspace` and `/mnt` (the "docks", read-only inside the jail so the
agent cannot populate them); a bind the holder makes
on a subdirectory of one of them propagates into the jail at the same
relative path, and an umount in the holder propagates the same way. The
jail's own namespaces are never entered, nothing in the jail can do any of
this (`CAP_SYS_ADMIN` is dropped there), and the holder's mounts are
invisible to the host - a slave never propagates upward - and die with it.
Read-only arrives read-only because the controller's `mount` (util-linux
from nixpkgs) sets the flag through the new mount API before attaching,
rather than remounting after the propagation has already copied the mount.

Two consequences worth knowing. A guest path *not* directly under a dock
(`--mount /a:/data`, or anything under `--same-path`) is still honoured at
launch, through a bwrap bind of the holder-side mountpoint, but such a
mount is **fixed**: `list` says so and `remove` refuses it, because the
clone bwrap made has no parent in the holder's propagation tree for an
umount to reach. And detaching a tree something in the jail still has open
(a shell with its cwd inside is enough) falls back to a lazy umount: the
mount is gone from the jail's view, and that process keeps a dangling cwd.

Mode `full` on a live mount is the same host-mutation surface `--git
full` is for the workspace, minus the safety snapshot - the controller
binds `.git/hooks` read-only on top and in-jail git keeps its forced
`core.hooksPath`, but the tree is the real one. Prefer `limited` unless the
agent needs to see the host's edits as they happen.

### Live domain management

The network whitelist can change while the session runs, the same way
mounts can. The operator adds or removes a domain from a second terminal,
and the agent can ask for one it was blocked from:

```bash
llm-custody domain                                  # interactive menu: requests, allowed, blocked
llm-custody domain add registry.npmjs.org           # for this session
llm-custody domain add --persist registry.npmjs.org # also appended to --state-dir/domains
llm-custody domain remove --persist registry.npmjs.org
llm-custody domain list                             # each name with its source
llm-custody domain blocked                          # names that hit the catch-all, with counts
```

Inside the jail, `custody-request --domain NAME --reason "..."` queues a
request like a package or mount one (same exit codes), and approving it
offers *session* or *persist*. With `--no-net-filter` every domain is
already reachable, so such a request is refused at once instead of
queued.

`list` tags every name with where it came from: `default` (the tool's
built-in list in `tools.nix`), `file` (`--state-dir/domains`), `flag`
(`--allow-domain`, or a host taken from `ANTHROPIC_BASE_URL` /
`OPENAI_BASE_URL`) or `live` (added during the session). An approval lasts
for the session; *persist* additionally appends the name to
`--state-dir/domains` so the next launch starts with it. `remove` of a
default works for the session only: `remove --persist` refuses a default,
because that list lives in the Nix source.

Names must be plain hostnames: lowercase LDH labels, at least two of them,
no wildcard, no IP literal, at most 253 characters. A domain covers its
subdomains, as at launch. The same check now applies to `--allow-domain`
and to the domains file; a name that fails it is left off with a warning
rather than written into the dnsmasq config.

What a change does: the controller (`$RUNDIR/domain`, which
`llm-custody domain` runs through the session registry like `mount`)
regenerates the dnsmasq config and restarts dnsmasq inside the holder's
network namespace. A lookup that arrives during the restart (well under a
second) goes unanswered and is retried by the resolver after its timeout.
Adding then pre-resolves the new name into the nftables sets. Removing
replaces the sets' contents, in one nft transaction, with the addresses of
what is still allowed: a fresh lookup of every remaining name, plus every
address dnsmasq has already handed out for those names this session (an
open connection to a CDN address a fresh lookup no longer returns keeps
working). Should that transaction fail, the controller falls back to a
flush and a re-add one by one, and connects to still-allowed domains can
be dropped until it finishes. An established connection to the removed
domain's addresses is cut by the drop policy, unless another allowed name
resolved to the same address.

`blocked` reads the dnsmasq query log: every name that got the
`address=/#/` catch-all, with how often, names allowed since left out. The
exit summary lists the same names.

The launcher is published as the `llm_custody_domain` user var and as
`$XDG_RUNTIME_DIR/llm-custody/<pid>.domain` / `current.domain`, all only
when the network filter is on.

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
both are reported at launch.

`--mask` globs apply to every mounted tree, not just the workspace: they are
expanded against each tree's own root, on the assumption that a pattern
written to keep credentials out of the jail is meant to keep them out of a
second checkout too. How a match is hidden depends on how the jail sees the
tree:

| Tree | Masking |
|------|---------|
| copy (`--git limited\|none`) | deleted from the copy before its baseline commit, so it never reaches the jail and never syncs back |
| direct bind (`--ro-mount`, `--git full`, overlay) | shadowed by an empty read-only file/dir |

The shadow is the weaker of the two: it covers the working copy only, so a
tree bound together with its `.git` still hands the content out as a blob
(`git show HEAD:<path>`). The runner says so at launch when it shadows a
tree that has a `.git`. Masked paths are never deleted on the host - with a
copy, the deletion happens in the copy, and the tracking baseline is taken
afterwards, so sync-back never sees them as removals.

#### Mid-session sync

A long session often produces something worth keeping - or worth reading in
a real editor - well before the agent is done. The runner writes the exact
same sync-back out as a standalone command, runnable from a second terminal
as often as you like while the session keeps going:

```bash
llm-custody sync                          # the most recently started run
llm-custody session list                  # live sessions, with their pids
llm-custody --pid 48213 sync              # a specific run, for concurrent sessions
```

`llm-custody sync` is a front end over a registry of live runs:

```bash
$XDG_RUNTIME_DIR/llm-custody/current      # the most recently started run
$XDG_RUNTIME_DIR/llm-custody/<pid>.sync   # a specific run, for concurrent sessions
```

Both are symlinks to `$RUNDIR/sync`, whose path is also printed at launch
under `--verbose`. Each sync advances the tracking baseline, so the next one
only reports what changed since - and the exit prompt then has nothing left
to ask about for the parts already synced.

Alongside those, every run registers `$XDG_RUNTIME_DIR/llm-custody/<pid>.state`
describing itself (see the state record below). A run with no isolated tree
(`--git full` without `--overlay-workspace`) has no sync-back to register, so
the record is all it leaves: `session list` still shows it, and syncing it
reports that there is nothing to fold back and exits 0. "Your changes are
already on the host" and "no jail is running" are opposite answers, and
without the record they looked identical from outside.

Every prompt takes `d` as well as `y`/`N`: `d` pages the full diff of what
is about to be written to the host (through `$PAGER`) and asks again.
`--sync-exclude GLOB` holds paths back permanently, in both the exit trap
and the mid-session runs.

This is deliberately *not* reachable from inside the sandbox: `$RUNDIR` is
not mounted there, so an agent cannot sync its own work out unreviewed.
Syncing while the agent is mid-write is safe for the host (worst case a
file lands half-written and the next sync corrects it), but the jail-side
copy is the agent's working tree, so review as usual.

#### The session state record

What a run *is* gets published once at setup, as a record of
newline-separated `key=value` lines - first `=` splits, so values stay
free-form and nothing but a newline (which none of these fields can hold)
would need escaping. It goes to two sinks that never drift, because one
function writes both: the registry file `<pid>.state`, and the WezTerm user
var `llm_custody_state`.

| Key | Value |
|-----|-------|
| `state` | `sync` (isolated trees exist, fold them back with the command in `sync`) or `direct` (every tree bound straight through - the host already has whatever the agent wrote) |
| `tool` | tool name (`pi`) |
| `pid` | runner pid, the same one the registry filename carries |
| `workspace` | host path of the workspace |
| `git` | `full` / `limited` / `none` |
| `overlay` | `1` with `--overlay-workspace`, `0` otherwise |
| `sync` | the mid-session sync command. Always present now that a copy mount can be attached after launch; `state=direct` means nothing was isolated *at launch* |
| `manifest` | the sync manifest the command reads, empty for a session with nothing isolated |
| `mount` | the session's mount launcher (`add` / `remove` / `list`), see [Live mounts](#live-mounts) |
| `domain` | the session's domain launcher (`add` / `remove` / `list` / `blocked`), see [Live domain management](#live-domain-management). Absent with `--no-net-filter` |

A record rather than more single-purpose variables, or magic values stuffed
into existing ones: the questions a consumer asks keep growing (is there
anything to sync? if not, why not? which git mode, which workspace?), and
every answer would otherwise cost another variable that every emission site
has to keep in step. **An unknown key is ignorable, so a consumer written
today keeps working when a key is added** - parse the whole record, read the
keys you know, ignore the rest.

`llm_custody_sync` still carries the sync command on its own (path when
there is one, empty otherwise) and stays strictly a path: it is what a
binding execs, and a magic non-path value in it is one missing guard away
from being spawned as a command.

In a WezTerm pane this is enough for a one-key binding that can tell all
three cases apart. All user vars are cleared when the session ends:

```lua
-- wezterm.lua
local shell = os.getenv('SHELL') or '/bin/sh'

-- key=value lines -> table. Unknown keys land in it and are simply unused.
local function parse_state(raw)
  if not raw or raw == '' then return nil end
  local state = {}
  for line in raw:gmatch('[^\n]+') do
    local k, v = line:match('^([^=]+)=(.*)$')
    if k then state[k] = v end
  end
  return state
end

config.keys = {
  {
    key = 's', mods = 'CTRL|SHIFT',
    action = wezterm.action_callback(function(win, pane)
      local st = parse_state(pane:get_user_vars().llm_custody_state)
      if not st then
        win:toast_notification('llm-custody', 'no live jail session in this pane', nil, 3000)
        return
      end
      if not st.sync then
        win:toast_notification('llm-custody',
          ('nothing to sync - --git %s writes to %s directly'):format(st.git, st.workspace),
          nil, 4000)
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
            args = { shell, '-c', st.sync .. '; printf "\\n[finished, press enter]"; read -r _' },
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

Another user var, `llm_custody_jail`, carries the jail marker and the tool
name (`▥ pi`) for the whole session. The runner also sets the window title
to the same thing at launch, but the jailed tool sets its own title as soon
as it starts and overwrites it - the user var is what a terminal config can
keep in front of whatever the tool writes.

Two more, `llm_custody_toolbox` and `llm_custody_toolbox_cmd`,
carry this session's toolbox directory and the store path of the CLI that
fills it, so a binding can prompt for a package and install it without
resolving the registry itself and without llm-custody being on the host's
PATH:

```lua
-- prompt, then provision into the toolbox of the pane's session
wezterm.action_callback(function(window, pane)
  local vars = pane:get_user_vars()
  local dir = vars.llm_custody_toolbox
  if not dir or dir == '' then return end
  -- store path, because `nix run .#pi` installs nothing on the host
  local cmd = vars.llm_custody_toolbox_cmd or 'llm-custody'
  window:perform_action(wezterm.action.PromptInputLine {
    description = 'package(s) to add to the jail',
    action = wezterm.action_callback(function(w, p, line)
      if not line or line:match('^%s*$') then return end
      -- the line is user input: pass it as an argument, never concatenated
      -- into a shell string
      w:perform_action(wezterm.action.SpawnCommandInNewTab {
        args = { cmd, '--dir', dir, '--pause', 'toolbox', 'add', line },
      }, p)
    end),
  }, pane)
end)
```

#### Unsynced-change indicator

A jail copy that has work the host has not seen looks exactly like one that
does not, and without an indicator the first moment that difference surfaces
is the prompt at exit. So the runner counts the paths changed-but-not-synced
across every isolated tree (the same two sources the sync-back reads) and
publishes the number two ways:

- `$RUNDIR/dirty`, a plain file holding the count, rewritten atomically.
  Readable by anything - a tmux `status-right`, a starship module, a polling
  script
- `llm_custody_dirty`, a user var, emitted **only when the count changes**
  (empty when clean). A long session writes a handful of escape sequences
  rather than one per interval: the jailed tool owns the terminal, and a
  write landing inside one of its own sequences would corrupt a frame

`--watch-interval` sets the poll period (default 15s, `0` disables it
entirely - worth doing on a tree big enough for `git status` to cost real
time). The check uses `git --no-optional-locks status`, so it never collides
with a mid-session sync running `git add` against the same tracking dir.

Putting both vars in the tab title:

```lua
wezterm.on('format-tab-title', function(tab)
  local vars = tab.active_pane.user_vars
  local title = tab.active_pane.title
  if not vars.llm_custody_jail or vars.llm_custody_jail == '' then
    return title
  end
  local dirty = vars.llm_custody_dirty
  return {
    -- Marker colored by state, not widened by the count: a badge that gains
    -- a cell when the count crosses 9 reflows the whole tab bar, and it does
    -- so every time the agent writes a file.
    { Foreground = { Color = (dirty and dirty ~= '') and '#fb4934' or '#d5c4a1' } },
    { Text = '▥ ' },
    { Text = title },
  }
end)
```

The count itself is better placed somewhere with room to vary - a status
line, or just `llm-custody session list`.

`llm-custody session list` reports the same count per live session, which
needs no terminal support at all:

```
pid 48213  pi  /home/user/devel/llm-custody
    git limited, no overlay, 7 unsynced path(s), 1 mount(s), 0 request(s) pending
    sync   /tmp/tmp.T4dWf4vSKz/sync
    mount  /tmp/tmp.T4dWf4vSKz/mount
```

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
- `/workspace` and `/mnt` themselves are empty directories from the runtime
  dir, bound read-only: the docks a live mount propagates into (see
  [Live mounts](#live-mounts)). Read-only so the agent cannot populate them
- Any directories added via `--mount` / `--ro-mount`, by default under
  `/workspace` next to the workspace itself, and anything attached later
  with `llm-custody mount add` or an approved `custody-request --mount`. A
  read-write one is isolated the same way the workspace is (copy, overlay
  or real tree, per `--git` / `--overlay-workspace`) and reviewed on the way
  back out - see [Syncing changes back](#syncing-changes-back)

The sandboxed tool keeps the controlling terminal (no bwrap
`--new-session`): a process detached from it never receives SIGWINCH, so
pi/claude would keep painting at the launch width after a pane resize or a
split and the redraw lands as garbage. The input injection that flag guards
against is closed by the seccomp denylist instead, which refuses
`ioctl(TIOCSTI)` and `ioctl(TIOCLINUX)` with EPERM (the alternative bwrap's
own documentation names for this case; `--selftest` probes it). On a
terminal the tool also runs in a process group of its own (job control in
the runner), so a `kill(0)` from inside the jail cannot reach the runner's
helpers (broker, dirty watcher, network) and SIGWINCH has one unambiguous
foreground group to go to. That group's leader is a `timeout --foreground
0` sitting in the host workspace, because terminal splits take a new
pane's cwd from the foreground leader and bwrap itself sits at `/`.

The sandboxed process runs without any capability (bwrap
`--cap-drop ALL`), so it cannot create bind mounts or remount
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

The sandboxed process cannot create user namespaces of its own. The
seccomp filter is what enforces that: it denies `unshare` and
namespace-creating `clone` flags, and answers `clone3` with `ENOSYS` so
glibc falls back to the inspectable `clone`. bwrap's `--disable-userns` is
passed too, but measured inert on bwrap 0.13.1 (it leaves
`/proc/sys/user/max_user_namespaces` at `INT_MAX` instead of the documented
`1`), so nothing depends on it. A fresh user namespace would
hand it a full capability set inside, enough to reach netns-scoped
nftables and the rest of the userns-gated kernel surface. The flip side:
anything that needs one inside the jail fails, e.g. rootless podman, a
nested bwrap, or Claude Code's own `sandbox` mode (which is why
`--merge-config` never imports claude's `sandbox` key). `--selftest`
probes `clone` and `clone3`.

**Environment variables.** Only these are forwarded into the sandbox:

- `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- `TERM`, `COLORTERM`, `LANG`, `LC_ALL`, `LC_CTYPE` (not `LINES`/`COLUMNS`:
  the terminal size comes from the pty and follows resizes, a fixed value
  in the environment would pin ncurses-style tools to the launch size)
- Anything passed via `--env KEY=VAL`

Cloud credentials (`AWS_*` and the like) are not inherited from the host
shell, which often carries keys for unrelated accounts. Pass the one the
session needs explicitly, e.g. `--env AWS_PROFILE=dev` (plus a
`--ro-mount` of the matching config) or `--env AWS_ACCESS_KEY_ID=...`.

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
filtering and a default-deny firewall inside a private network namespace:

- DNS resolution (via a per-run dnsmasq instance) is limited to the tool's
  whitelisted API/service domains
- The nftables output chain is `policy drop`. What gets out: loopback,
  ICMP/ICMPv6 (IPv6 neighbour discovery rides on it), DNS to the single
  upstream resolver dnsmasq forwards to, and any traffic to an IP that a
  whitelisted domain actually resolved to (set populated from dnsmasq's
  query log). A hardcoded-IP bypass that skips DNS hits the drop, and so
  does UDP 443 (HTTP/3) and every other port - the gate is on the address,
  not on a port list, so `git` over SSH to an allowed host works while a
  QUIC connection to an unknown address does not
- DNS itself is pinned to that one upstream address. The sandbox's resolver
  is `127.0.0.1`, so an outbound query to anything else is either a
  misconfiguration or a tunnel
- Custom API endpoints (via `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) are
  automatically whitelisted
- Additional domains can be added with `--allow-domain` (suffix/subdomain
  matched, no wildcard/glob support yet), or persistently via
  `~/.config/llm-custody/domains`, or while the session runs (see
  [Live domain management](#live-domain-management))
- Whitelisted domains are pre-resolved into the nftables sets before the
  sandbox starts (first-connect race mitigation); later DNS answers keep
  the sets fresh
- At exit, the runner reports every domain the sandbox tried to reach that
  was not whitelisted, plus the drop counter. A blocked request otherwise
  just fails somewhere inside the tool with no indication that the jail was
  the reason
- Use `--no-net-filter` to disable all network restrictions

Default allowed domains are per tool (`tools.nix` `allowedDomains`).

- `pi`: `pi.dev`, `api.anthropic.com`, `api.openai.com`, `auth.openai.com`,
  `chatgpt.com`, `generativelanguage.googleapis.com`, `openrouter.ai`,
  `api.deepseek.com`. Any other provider (Mistral, xAI, Groq, Cerebras,
  Novita, ...) needs its API host added with `--allow-domain`
- `claude`: `api.anthropic.com`, `platform.claude.com`, `claude.ai` (the
  last two only matter for the in-jail login - authorize page, code
  callback and token exchange live on `platform.claude.com`, which is where
  the old `console.anthropic.com` endpoints moved)

GitHub is on neither list: it is a bidirectional channel, so it is granted
per need. Plugin/marketplace installs (and `git`/`gh` against GitHub) need
`github.com`, `api.github.com`, `registry.npmjs.org` and possibly
`raw.githubusercontent.com`, added with `--allow-domain`, the persistent
`domains` file, or a live domain approval during the session.

> [!NOTE]
> Dual-stack: slirp4netns's IPv6 path (`-6`, marked experimental upstream)
> is enabled, with a matching IPv6 nftables set/rule and dnsmasq AAAA
> catch-all alongside the IPv4 ones. Not yet battle-tested against a
> real IPv6-only endpoint.

## Resource limits

Off by default. `--max-mem`, `--max-cpu` and `--max-pids` put the jail in a
transient systemd user scope (`systemd-run --user --scope`, unit
`llm-custody-<tool>-<runner pid>.scope`) carrying `MemoryMax=` plus
`MemorySwapMax=0`, `CPUQuota=` and `TasksMax=` respectively:

```bash
nix run .#pi -- --max-mem 8G --max-cpu 200 --max-pids 4096
```

The scope holds the jailed tool and everything it starts. The runner, the
request broker, dnsmasq, slirp4netns and the watchers stay outside it, so a
fork bomb or an OOM kill inside the jail leaves the helpers running and the
sync-back at exit still happens. Exceeding `--max-mem` gets a process in
the scope OOM-killed, nothing outside it.

Memory accounting follows the kernel's rules for tmpfs: pages are charged
to the cgroup of the process that wrote them. The workspace copy the runner
makes under `--tmpdir` at launch is not counted against the jail, but files
the agent writes into a tmpfs-backed copy afterwards are. Point `--tmpdir`
at disk if a big build in the workspace would otherwise eat the limit.

Any limit flag needs a working systemd user manager, and the runner refuses
to launch rather than run unlimited when something is missing:
`systemd-run` on PATH, the user bus (`DBUS_SESSION_BUS_ADDRESS` or
`$XDG_RUNTIME_DIR/bus`), cgroup v2, and the requested controllers
(`memory`, `cpu`, `pids`) delegated to `user@<uid>.service`. Before the
sandbox is set up it also creates a throwaway scope with the same
properties, which catches a shell that systemd cannot move into a scope
(typical for some ssh sessions). `--dry-run` prints the `systemd-run`
prefix without checking any of this. `--selftest` with limit flags runs the
probe inside the scope and prints the `memory.max`, `memory.swap.max`,
`cpu.max` and `pids.max` it sees.

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
|    - unshare --user --mount --propagation shared [--net]  |
|      (+ newuidmap/newgidmap) namespace holder             |
|    - slirp4netns for outbound connectivity                |
|    - dnsmasq (domain whitelist) + nftables (IP gate)      |
|    - opens seccomp fd (lib/seccomp-denylist.nix)          |
|    - attaches every --mount in the holder (lib/mount-ctl) |
|    - starts the request broker (llm-custody serve)        |
|    - nsenter's into the holder, execs bwrap ...           |
|    - on demand (lib/mount-ctl.sh): attaches/detaches      |
|      trees under /workspace and /mnt by propagation       |
|    - on exit (and on demand, lib/sync-back.sh): reviews   |
|      the jail copies/overlays back into the host trees    |
|                                                            |
|  +-- bwrap sandbox (mount/pid/ipc/uts/user ns) --------+ |
|  |  /nix/store         <- ro-bind                        | |
|  |  /workspace, /mnt   <- ro-bind docks (live mounts)    | |
|  |  /workspace/<name>  <- bind (rw, cwd)                 | |
|  |  /workspace/<other> <- propagated from the holder     | |
|  |  /home/user/<cfg>   <- bind (rw, jail-private state)  | |
|  |  /toolbox           <- ro-bind (operator packages)    | |
|  |  /run/llmcustody-bin <- ro-bind (git wrapper,          | |
|  |                         custody-request), first on PATH| |
|  |  /run/custody-request.sock <- bind (broker, ask only)  | |
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

`llm-custody launch` execs whichever runner the umbrella was built with, so a
consumer that overrides a runner has to hand the result back to the umbrella
for `launch` to see it:

```nix
llm-custody.default.override {
  runners = { pi = my-pi; claude = my-claude; };
}
```

## Adding a new tool

1. Add `launchers/<tool>.nix`: a plain function
   `{ pkgs, <tool-package>, ... }: { toolPackage; extraEnv ? {}; bootstrapScript ? ""; }`.
2. Add an entry to `tools.nix` (`launcherModule`, `configDirName`,
   `configEnvVar`, `skillsDir`, `allowedDomains`, `resumeFlags`, plus
   optional `dangerousFlag` and `mergeSkipKeys`).
3. Wire the tool's package into `flake.nix`'s `defaultArgs`.
4. `nix run .#your-tool` - the flake generates a runner automatically, and
   `llm-custody launch your-tool` finds it too: the umbrella's runner
   directory and its completions are built from the same attribute set.

A launcher should also append `lib/toolbox.nix`'s `notice` to whatever
user-level memory file its tool reads, the way `launchers/pi.nix` and
`launchers/claude.nix` do - an agent that does not know it cannot install
anything will burn turns on `nix` and comma against a read-only store.

CLI flags like `--immutable` and `--devenv` existed in the old QEMU jail and
haven't been ported to the bwrap runner yet; a new tool that needs one of
these needs that support added to `lib/mkBwrapRunner.nix` too.

## License

This project is licensed under the [MIT License](LICENSE), carried over
from the upstream project this was forked from.
