# llm-custody

> **Hard fork of [braiins/llm-jail](https://github.com/braiins/llm-jail).**
> Upstream sandboxes several coding-agent tools inside QEMU microVMs. This
> fork replaced that with bubblewrap + a private network namespace (real
> Linux namespaces on the host kernel instead of a VM boundary, no guest
> kernel to boot) and cut every tool except [Pi](https://pi.dev) in the
> process (maybe will re-add some later). Not a PR-back candidate.

Sandbox for running the Pi coding agent via bubblewrap + a private network
namespace. No VM, no disk image; the tool runs directly on the host kernel,
isolated by Linux namespaces and a seccomp denylist, with DNS+nftables-based
domain whitelisting for outbound network access.

## Requirements

- Linux (x86_64 or aarch64)
- [Nix](https://nixos.org/) with flakes enabled
- `newuidmap`/`newgidmap` (setuid helpers) plus `/etc/subuid`/`/etc/subgid`
  ranges for your user - required for the private network namespace. On
  NixOS, enabling any rootless-container feature (e.g. Incus) provisions
  these; otherwise install `shadow`'s setuid helpers and add subuid/subgid
  ranges yourself.

No host-side `pi` credentials are needed: you log in once inside the jail on
first run (pi's own `/login` flow), and its state persists in a jail-private
directory under `~/.config/llm-custody/pi/` (see
[First run & authentication](#first-run--authentication)).

## Quick start

```bash
# Run Pi
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#pi"

# Pass tool arguments after --
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#pi" -- -p "Refactor the auth module"
```

Or, from a local checkout:

```bash
nix run .#pi -- -p "Refactor the auth module"
```

## First run & authentication

Pi's state lives in a jail-private directory on the host -
`~/.config/llm-custody/pi/<profile>` (profile `default` unless `--profile` is
given) - bound read-write into the sandbox at `/home/user/.pi/agent`
(`PI_CODING_AGENT_DIR`). Your real `~/.pi` is never mounted or read.

On first run the directory is empty, so pi walks you through its own
`/login` flow in the terminal. Credentials and settings then persist across
runs.

Work for multiple clients by giving each its own profile, each with its own
one-time login:

```bash
nix run .#pi -- --profile client1
nix run .#pi -- --profile client2
```

If you want to reuse an existing host login rather than logging in fresh,
you can point `--state-dir` at a directory that itself contains a
`pi/<profile>` symlink onto your real `~/.pi/agent` - at your own risk (host
and jail will then refresh the same credentials independently). Do not point
it directly at a directory the host `pi` also writes to.

## Usage

```
llm-custody-pi [options] [-- pi-args...]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--profile NAME` | State profile, a subdir of `--state-dir/pi` | `default` |
| `--state-dir PATH` | Jail state root dir, mounted read-write | `~/.config/llm-custody` |
| `--same-path` | Mount workspace at its host path instead of `/workspace` | off |
| `--tmpdir PATH` | Directory to use for runtime data | `${TMPDIR:-/tmp}` |
| `--mount HOSTPATH[:GUESTPATH]` | Extra read-write mount (repeatable) | - |
| `--ro-mount HOSTPATH[:GUESTPATH]` | Extra read-only mount (repeatable) | - |
| `--allow-domain DOMAIN` | Add domain to network whitelist (repeatable) | tool defaults |
| `--no-net-filter` | Disable network filtering (unrestricted access) | filtering on |
| `-h`, `--help` | Show help | - |

Not yet ported from the old QEMU jail: `--dangerous` (pi has no
dangerous-mode flag - see below), `--mask`, `--immutable`, `--nix-env`,
`--devenv`.

### Examples

Mount an extra directory:

```bash
nix run .#pi -- --mount /tmp/data -- -p "Process the dataset"
```

Enable git-over-SSH by mounting your SSH directory (read-only):

```bash
nix run .#pi -- --ro-mount ~/.ssh -- -p "Push the changes"
```

Allow access to additional domains (e.g. for package installs or git cloning):

```bash
nix run .#pi -- --allow-domain github.com --allow-domain registry.npmjs.org
```

Disable network filtering entirely:

```bash
nix run .#pi -- --no-net-filter
```

## What's isolated

**Filesystem.** The sandbox has its own mount namespace; only explicitly
bound paths are visible inside it:

- The current working directory -> `/workspace` (read-write; `.git/hooks`
  underneath is re-bound read-only even so, and `git` itself is shadowed
  in-jail to always force `-c core.hooksPath` at that read-only dir, so
  rewriting `core.hooksPath` in the still-writable `.git/config` doesn't let
  an agent redirect in-jail git to a hooks dir it controls)
- The jail-private state dir `~/.config/llm-custody/pi/<profile>` ->
  `/home/user/.pi/agent` (read-write)
- `~/.gitconfig` and `~/.claude/skills` (read-only), if present
- Host system and user packages -> `/host-sw`, `/host-user-sw` (read-only,
  NixOS hosts only)
- `/nix/store` (read-only)
- Any directories added via `--mount` / `--ro-mount`

All other host paths are invisible inside the sandbox.

On NixOS hosts, system packages (`/run/current-system/sw`) and user packages
(`/etc/profiles/per-user/$USER`) are automatically mounted and added to
`PATH`, so tools like `rg`, `git`, `jq`, etc. are available without
hardcoding them, as long as the host has them installed.

`/workspace` is a direct read-write bind of the host directory, not a
copy-on-write layer - a destructive command run by the agent (`rm -rf`, a
bad rebase, force-push, ...) mutates the real working tree. Two safety nets,
neither a full substitute for backups: if the workspace is a git repo, a
`git stash create` snapshot is taken before launch (tracked changes only,
doesn't touch the working tree or `git stash list` - just prints a recovery
hash), and `core.hooksPath` is diffed before/after the run with a loud
warning on exit if it changed (catches the case where a plain `git` run on
the host *outside* the jail later would honor a hooks dir the agent planted).

**Processes.** bwrap unshares mount, PID, IPC, and UTS namespaces - the
sandboxed process has its own PID 1 and no visibility into host processes.
User and network namespaces are shared with a dedicated long-lived netns
holder process (not the host's), so the sandbox gets a private network too.

**Environment variables.** Only these are forwarded into the sandbox:

- `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- `AWS_*`
- `TERM`, `COLORTERM`, `LINES`, `COLUMNS`

All other host environment variables are stripped.

**Network.** By default, outbound access is restricted via DNS-based domain
filtering and a port-level firewall inside a private network namespace:

- DNS resolution (via a per-run dnsmasq instance) is limited to pi's
  whitelisted API/service domains
- Only HTTP/HTTPS traffic (ports 80/443) is allowed outbound to IPs that a
  whitelisted domain actually resolved to (nftables set populated from
  dnsmasq's query log) - a hardcoded-IP bypass that skips DNS still hits
  the drop rule
- Custom API endpoints (via `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL`) are
  automatically whitelisted
- Additional domains can be added with `--allow-domain` (suffix/subdomain
  matched, no wildcard/glob support yet)
- Use `--no-net-filter` to disable all network restrictions

Default allowed domains: `pi.dev`, `api.anthropic.com`, `api.openai.com`,
`auth.openai.com`, `chatgpt.com`, `generativelanguage.googleapis.com`,
`github.com`, `api.github.com`, `openrouter.ai`, `api.deepseek.com`,
`api.mistral.ai`, `api.x.ai`, `api.groq.com`, `api.cerebras.ai`,
`api.novita.ai`.

> [!NOTE]
> Dual-stack: slirp4netns's IPv6 path (`-6`, marked experimental upstream)
> is enabled, with a matching IPv6 nftables set/rule and dnsmasq AAAA
> catch-all alongside the IPv4 ones. Not yet battle-tested against a
> real IPv6-only endpoint.

## Dangerous mode

Pi has no dangerous-mode CLI flag of its own; project trust is instead set
to `trusted` in the jail-private `settings.json` on every launch, so pi
doesn't prompt for it. A.k.a. YOLO forever. The agent can still execute
arbitrary commands, write to any mounted directory, and make network
requests to whitelisted domains without asking, exactly as it would
run outside the jail.

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
|  nix run .#pi                                           |
|    v                                                     |
|  writeShellApplication (lib/mkBwrapRunner.nix)          |
|    - parses CLI args                                     |
|    - runs launchers/pi.nix's bootstrapScript directly    |
|      against the real host state dir                     |
|    - unshare --user --net (+ newuidmap/newgidmap) holder  |
|    - slirp4netns for outbound connectivity                |
|    - dnsmasq (domain whitelist) + nftables (IP gate)      |
|    - opens seccomp fd (lib/seccomp-denylist.nix)          |
|    - nsenter's into the netns holder, execs bwrap ...     |
|                                                            |
|  +-- bwrap sandbox (mount/pid/ipc/uts/user ns) --------+ |
|  |  /nix/store        <- ro-bind                        | |
|  |  /workspace         <- bind (rw)                      | |
|  |  /home/user/.pi/agent <- bind (rw, jail-private state)| |
|  |  seccomp denylist applied at the final execve         | |
|  |  exec pi                                              | |
|  +-------------------------------------------------------+ |
+-----------------------------------------------------------+
```

No guest kernel, no disk image, no 9p - everything above is real bind mounts
and Linux namespaces on the host kernel.

## Overriding the tool package

The runner is built with `lib.makeOverridable`, so `pi-coding-agent` can be
swapped without forking the flake:

```nix
# flake.nix (consumer)
let
  llm-custody = inputs.llm-custody.packages.${system};
in
  llm-custody.pi.override {
    pi-coding-agent = my-pinned-pi;
  }
```

Useful for pinning a specific version, applying local patches, or testing an
unreleased build.

## Adding a new tool

1. Add `launchers/<tool>.nix`: a plain function
   `{ pkgs, <tool-package>, ... }: { toolPackage; bootstrapScript ? ""; }`.
2. Add an entry to `tools.nix` (`launcherModule`, `configDirName`,
   `configEnvVar`, `allowedDomains`).
3. Wire the tool's package into `flake.nix`'s `defaultArgs`.
4. `nix run .#your-tool` - the flake generates a runner automatically.

CLI flags like `--dangerous`, `--mask`, `--immutable`, `--nix-env`, and
`--devenv` existed in the old QEMU jail and haven't been ported to the bwrap
runner yet; a new tool that needs one of these needs that support added to
`lib/mkBwrapRunner.nix` too.

## License

This project is licensed under the [MIT License](LICENSE), carried over
from the upstream project this was forked from.
