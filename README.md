# llm-custody

Sandbox for running a coding agent ([Pi](https://pi.dev) or
[Claude Code](https://code.claude.com)) with bubblewrap and a private network
namespace. No VM and no disk image: the tool runs on the host kernel,
isolated by Linux namespaces and a seccomp denylist, and can only reach a
whitelist of domains.

Hard fork of [braiins/llm-jail](https://github.com/braiins/llm-jail), which
does the same inside QEMU microVMs for more tools.

## What you get

- The agent sees a copy of your working tree as a fresh single-commit repo,
  with no host git history. Changes are reviewed and synced back on exit.
- Tool state and credentials live in a jail-private directory
  (`~/.config/llm-custody/<tool>/<profile>`). Your real `~/.pi` and
  `~/.claude` are never mounted.
- Outbound network is limited to the tool's API endpoints plus the domains
  you allow.
- Packages, host directories and domains can be added to a running session,
  either by you or on request from the agent (which you approve or deny).

## Requirements

- Linux (x86_64 or aarch64)
- [Nix](https://nixos.org/) with flakes enabled
- `newuidmap`/`newgidmap` and `/etc/subuid`/`/etc/subgid` ranges for your
  user. On NixOS any rootless-container feature (e.g. Incus) provisions
  these.

## Run it

```bash
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#pi"
nix run "git+ssh://gitea@git.gurkan.in/gurkan/llm-custody.git#claude"
```

From a checkout, with tool arguments passed straight through:

```bash
nix run .#pi -- -p "Refactor the auth module"
nix run .#claude -- --dangerous -- -p "Refactor the auth module"
```

The first run walks you through the tool's own `/login` inside the jail. The
login persists per profile; `--profile NAME` gives you a separate one.
Exporting `ANTHROPIC_API_KEY` on the host skips the login.

Check the sandbox wiring on your host without starting a session:

```bash
nix run .#pi -- --selftest
```

## Common options

```bash
nix run .#pi -- --mount /srv/data                 # extra tree as a synced copy, at /workspace/data
nix run .#pi -- --mount-ro ~/.ssh:/home/user/.ssh # read-only, explicit target
nix run .#pi -- --mount-full /srv/scratch         # real tree, writes hit the host
nix run .#pi -- --allow-domain github.com         # extra whitelisted domain
nix run .#pi -- --mask 'secrets/*'                # hide paths from the jail
nix run .#pi -- --pwd-full                        # launch directory as the real tree, no copy
nix run .#pi -- --continue                        # resume the last session
nix run .#pi -- --dry-run                         # print what would happen
```

`--help` lists every flag.

## Managing running sessions

Everything host-side is one command, `llm-custody`, the flake's default
package:

```bash
nix run . -- launch pi            # same as .#pi
nix run . -- session list         # what is running
nix run . -- toolbox add ripgrep  # put a package on every jail's PATH
nix run . -- request answer       # answer what an agent asked for
nix run . -- mount add /srv/data  # attach a host tree to a live session
nix run . -- domain               # edit a live session's whitelist
nix run . -- sync                 # sync a live session's changes to the host, or discard/reset them
```

## More

[ARCH.md](ARCH.md) has the full option reference, the isolation model, the
toolbox and request broker, sync-back, resource limits and the internals.

## License

[MIT](LICENSE), carried over from the upstream project.
