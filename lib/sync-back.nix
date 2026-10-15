# Sync-back helper, shared by the runner's exit trap and the mid-session
# $RUNDIR/sync command. The shell itself lives in sync-back.sh (plain file,
# no Nix interpolation to escape); this only wraps it so git/coreutils are
# baked into its PATH - a mid-session run started from an arbitrary shell
# can't be assumed to have them.
{ pkgs }:
pkgs.writeShellApplication {
  name = "llm-custody-sync-back";
  runtimeInputs = [
    pkgs.git
    pkgs.coreutils
  ];
  text = builtins.readFile ./sync-back.sh;
}
