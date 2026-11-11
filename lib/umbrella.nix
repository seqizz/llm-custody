# The `llm-custody` command: the Rust binary (lib/toolbox-rs.nix) wrapped so
# its `launch` subcommand can find the per-tool runner scripts.
#
# `launch` resolves a tool through LLMCUSTODY_RUNNER_DIR, a directory of
# symlinks named after the tools. Only that subcommand needs the wrapper -
# `toolbox`, `lease`, `request`, `mount`, `sync` and `session` work from the
# bare binary, which is why lib/mkBwrapRunner.nix can keep pointing at the
# unwrapped store path without this file and the runners becoming circular.
#
# makeOverridable on `runners` because the operator's system flake swaps in
# its own pi and claude builds (grafts/llm-custody.nix):
#
#   llm-custody.packages.<system>.default.override {
#     runners = { pi = <own pi runner>; claude = <own claude runner>; };
#   }
#
# The runner directory and the `launch` completions are both derived from the
# attribute names of `runners`, so wiring another tool into tools.nix needs no
# edit here.
{ pkgs }:

pkgs.lib.makeOverridable (
  { runners }:
  let
    cli = import ./toolbox-rs.nix { inherit pkgs; };
    tools = builtins.attrNames runners;
    completions = (import ./completions.nix { inherit pkgs; }).umbrella { inherit tools; };
    # getExe rather than a hand-built `<out>/bin/llm-custody-<tool>` path: a
    # runner handed in by an override that is not a runner at all then fails
    # at eval with a mainProgram error instead of silently installing a
    # dangling symlink.
    runnerLinks = pkgs.lib.concatMapStringsSep "\n"
      (tool: ''ln -s ${pkgs.lib.getExe runners.${tool}} "$RUNNER_DIR/${tool}"'')
      tools;
  in
  pkgs.runCommand "llm-custody"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta = {
        description = "One command for the llm-custody sandbox: launch, mounts, sync, toolbox, requests";
        mainProgram = "llm-custody";
      };
      passthru = { inherit cli runners completions; };
    }
    ''
      RUNNER_DIR="$out/libexec/llm-custody/runners"
      mkdir -p "$RUNNER_DIR"
      ${runnerLinks}

      # --set, not --prefix: the directory is this package's own and there is
      # nothing to append to. A developer running the binary straight out of
      # cargo has the variable unset and falls back to llm-custody-<tool> on
      # PATH, which is the documented development path.
      makeWrapper ${cli}/bin/llm-custody "$out/bin/llm-custody" \
        --set LLMCUSTODY_RUNNER_DIR "$RUNNER_DIR"

      install -Dm644 ${completions.bash} "$out/share/bash-completion/completions/llm-custody"
      install -Dm644 ${completions.zsh} "$out/share/zsh/site-functions/_llm-custody"
      install -Dm644 ${completions.fish} "$out/share/fish/vendor_completions.d/llm-custody.fish"
    ''
)
