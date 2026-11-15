# Default notify hook of the request broker (lib/notify-desktop.sh): a desktop
# notification when an agent starts waiting on a package, mount or domain
# request. notify-send is baked in because the broker runs the hook with the
# runner's environment, which need not have libnotify on PATH.
{ pkgs }:
pkgs.writeShellApplication {
  name = "llm-custody-notify-desktop";
  runtimeInputs = [ pkgs.libnotify ];
  text = builtins.readFile ./notify-desktop.sh;
}
