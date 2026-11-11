# Facts about the operator-managed toolbox profile, shared by everything that
# touches it: lib/mkBwrapRunner.nix (binds it, puts it on PATH),
# ../toolbox (the manager that installs into it) and the launchers (tell the
# agent how to ask for an addition). One file so the guest path and the
# request format cannot drift between them.
#
# Why a profile at all: inside the jail /nix/store is read-only and no binary
# cache is in the domain whitelist, so nothing there can realize a derivation -
# `nix build`, `nix-shell` and comma all fail. Packages therefore enter from the
# host, through a nix profile bound read-only at `guestDir`.
{
  # Real host directory bound into the sandbox. Holds nix's own `profile`
  # symlink plus `currentLink` below.
  guestDir = "/toolbox";

  # What goes on the jail's PATH. Deliberately *not* `profile/bin`: nix writes
  # the profile as `profile -> profile-N-link`, and whether that hop is
  # relative or absolute is nix's business - an absolute one points at a host
  # path the sandbox does not have. `current` is maintained by the runner and
  # the CLI as a symlink straight to the resolved /nix/store profile, and the
  # store is bound wholesale, so that target resolves identically on both
  # sides of the bind.
  binDir = "/toolbox/current/bin";

  # Pointer symlink described above.
  currentLink = "current";
  # The nix profile itself, i.e. what `nix profile install --profile` targets.
  profileLink = "profile";

  # Leases (the `leases/` directory under guestDir and the default lifetime)
  # are not described here: nothing on the Nix side reads them any more, and
  # the manager that does is ../toolbox, where they live in src/paths.rs.
  # Two copies of a constant that only one language consumes is how they drift.

  # Appended to the jailed tool's user-level memory file by each launcher, so
  # the agent knows it cannot install anything and knows the format the
  # operator wants the request in.
  notice = ''

    ## Sandbox: asking for packages

    This session runs inside llm-custody. `/nix/store` is read-only here and no
    binary cache is in the network whitelist, so nothing in this sandbox can
    realize a derivation: `nix build`, `nix-shell` and `,` (comma) all fail on
    that, and retrying them is wasted effort.

    Tools the operator has provisioned live in `/toolbox/current/bin` and are
    already on PATH. The operator can add to that while the session runs, and a
    newly added binary becomes usable without restarting anything.

    If a task needs a tool that is not on PATH, ask for it:

        custody-request <attr> --reason "<why you need it>"

    That blocks until the operator approves or refuses. On approval the
    command is on your PATH immediately and you can carry on; exit status 3
    means refused, and refused is a final answer, not something to retry.
    Exit status 4 is different: nobody answered in time, or the broker went
    away. That is not a refusal, but do not ask again in a loop either - say
    in your reply that the request went unanswered and carry on without the
    tool. Name nixpkgs attributes (`lua5_4`, `shellcheck`, `ripgrep`), not commands -
    `, -p <command>` works offline and prints which package ships a given
    binary. Only bare attribute names are accepted; flake references are the
    operator's call, not yours.

    Ask once, for what the task actually needs, and do everything that does
    not depend on the tool first - the operator may be away from the terminal.
    If `custody-request` is missing or reports no broker, fall back to closing
    your reply with a request block in exactly this form:

        required packages: <attr>, <attr>
        good-to-have packages: <attr>, <attr>

    Leave a line out rather than writing it empty, and leave the whole block
    out when nothing is missing.
  '';
}
