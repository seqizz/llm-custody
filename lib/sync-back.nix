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
    pkgs.gnugrep
    # The 'd' answer at the sync prompt pages a full diff; without a pager
    # baked in, a large review would scroll off the terminal on any host
    # whose $PAGER happens to be unset.
    pkgs.less
  ];
  text = builtins.readFile ./sync-back.sh;
}
