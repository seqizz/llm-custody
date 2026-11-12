# Domain controller, shared by the operator's $RUNDIR/domain /
# `llm-custody domain` and the request broker (approving an agent's
# `custody-request --domain`). The shell lives in domain-ctl.sh and the
# network helpers it shares with the runner in net-filter.sh - both plain
# files with no Nix interpolation; this only joins them and bakes in the
# tools a mid-session run started from an arbitrary shell cannot be assumed
# to have.
{ pkgs }:
pkgs.writeShellApplication {
  name = "llm-custody-domain-ctl";
  runtimeInputs = [
    # nsenter into the holder, flock for the mutation lock.
    pkgs.util-linux
    # The restarted resolver is the same dnsmasq the runner starts.
    pkgs.dnsmasq
    pkgs.nftables
    pkgs.coreutils
  ];
  text = builtins.readFile ./net-filter.sh + builtins.readFile ./domain-ctl.sh;
}
