# Sync-back helper, shared by the runner's exit trap and the mid-session
# $RUNDIR/sync command. The shell itself lives in sync-back.sh (plain file,
# no Nix interpolation to escape); this only wraps it so git/coreutils are
# baked into its PATH - a mid-session run started from an arbitrary shell
# can't be assumed to have them. log.sh and jail-tree.sh come along for the
# reset answer, which rebuilds a copy with the same helpers the launch used.
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
    # The reset answer updates the copy in place from a masked staging copy,
    # deletions included.
    pkgs.rsync
    # Modified gitignored files are found with find -files0-from over the
    # baseline list and compared against the host with cmp.
    pkgs.findutils
    pkgs.diffutils
  ];
  text =
    builtins.readFile ./log.sh + builtins.readFile ./jail-tree.sh + builtins.readFile ./sync-back.sh;
}
