# The toolbox manager and request broker (../toolbox), built from source.
#
# Imported by flake.nix as `packages.toolbox` and by lib/mkBwrapRunner.nix,
# which needs the same store path twice: once to tell the operator what to run,
# and once to symlink as `custody-request` on the jail's PATH.
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
    description = "Host-side package toolbox and request broker for llm-custody jails";
    mainProgram = "llm-custody-toolbox";
  };
}
