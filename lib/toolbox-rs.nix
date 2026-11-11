# The `llm-custody` binary (../toolbox), built from source: toolbox manager,
# lease keeper, request broker and the front end over the live-session
# registry, all behind one subcommand tree.
#
# Imported by lib/umbrella.nix, which wraps it so `llm-custody launch` finds
# the runner scripts, and by lib/mkBwrapRunner.nix, which needs this store
# path twice: once to tell the operator what to run, and once to symlink as
# `custody-request` on the jail's PATH (the binary dispatches on argv[0]).
#
# No cargoHash and no vendor directory: the crate has no dependencies (see
# ../toolbox/Cargo.toml for why), so `cargoLock.lockFile` has nothing to fetch
# and the build works on a host with no network.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "llm-custody-toolbox";
  version = "0.1.0";
  src = ../toolbox;
  cargoLock.lockFile = ../toolbox/Cargo.lock;

  # `nix` and `nix-store` are deliberately absent from the closure. The host's
  # own nix (possibly Lix) is the one that owns /nix/var/nix and matches the
  # running daemon, so it has to be found on PATH at run time rather than
  # pinned here to whatever nixpkgs happens to carry.
  meta = {
    description = "Host-side CLI for llm-custody jails: toolbox, leases, request broker, sessions";
    # The unwrapped binary. lib/umbrella.nix wraps it under the same name and
    # is what the flake exposes; only `launch` depends on that wrapper.
    mainProgram = "llm-custody";
  };
}
