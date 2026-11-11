# Mount controller, shared by the runner (launch-time mounts), the operator's
# $RUNDIR/mount / `llm-custody mount`, and the request broker (approving an
# agent's `custody-request --mount`). The shell lives in mount-ctl.sh and the
# tree helpers it shares with the runner in jail-tree.sh - both plain files
# with no Nix interpolation; this only joins them and bakes in the store path
# of the sync-back helper and the tools a mid-session run started from an
# arbitrary shell cannot be assumed to have.
{ pkgs }:
let
  syncBack = pkgs.lib.getExe (import ./sync-back.nix { inherit pkgs; });
in
pkgs.writeShellApplication {
  name = "llm-custody-mount-ctl";
  runtimeInputs = [
    # nsenter and mount: the binds are made from inside the holder's
    # namespaces, and this `mount` is the one that speaks the new mount API
    # (a read-only bind then arrives in the jail read-only, instead of being
    # remounted after the propagation already copied it read-write).
    pkgs.util-linux
    pkgs.git
    pkgs.coreutils
  ];
  text = ''
    SYNC_BACK=${syncBack}
  '' + builtins.readFile ./jail-tree.sh + builtins.readFile ./mount-ctl.sh;
}
