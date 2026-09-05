{
  description = "llm-custody - bubblewrap sandbox for coding agents (hard fork of llm-jail)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, llm-agents, ... }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      tools = import ./tools.nix;

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
      toolsForSystem = system:
        nixpkgs.lib.filterAttrs
          (_: def: builtins.elem system (def.systems or supportedSystems))
          tools;

      mkTool = system: toolName: toolDef:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Default tool packages - overridable via `.override { pi-coding-agent = ...; }`
          # on the resulting runner derivation. Consumers can swap it without
          # forking the flake.
          defaultArgs = {
            pi-coding-agent = llm-agents.packages.${system}.pi;
          };
        in
        pkgs.lib.makeOverridable (
          { pi-coding-agent }:
          let
            launcherOut = import toolDef.launcherModule { inherit pkgs pi-coding-agent; };
          in
          import ./lib/mkBwrapRunner.nix {
            inherit pkgs launcherOut;
            name = toolName;
            toolDefaults = toolDef.defaults;
          }
        ) defaultArgs;

    in {
      packages = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: def: mkTool system name def) (toolsForSystem system)
      );

      apps = forAllSystems (system:
        nixpkgs.lib.mapAttrs (name: _: {
          type = "app";
          program = "${self.packages.${system}.${name}}/bin/llm-custody-${name}";
        }) (toolsForSystem system)
      );
    };
}
