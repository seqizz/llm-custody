# Shell completions for bash, zsh and fish: one set for the per-tool runner
# scripts (`llm-custody-pi`, `llm-custody-claude`) and one for the umbrella
# `llm-custody` command.
#
# All of them are generated from the data below rather than hand-written per
# shell: a flag added to lib/mkBwrapRunner.nix's parser needs one line here
# instead of three files that drift apart on their own, and the umbrella's
# subcommand tree is described once for all three shells. The runner flag
# list is shared - after `llm-custody launch <tool>` the umbrella completes
# exactly what the runner itself accepts.
#
# Descriptions must avoid apostrophes, '[', ']' and ':'. The first would end
# the single-quoted string carrying them in both the zsh and the fish output,
# and zsh's _arguments and _describe treat the other three as spec structure.
{ pkgs }:

let
  inherit (pkgs) lib;

  # arg: none | string | dir | file | choice (choice carries `values`)
  flags = [
    {
      flag = "--profile";
      arg = "string";
      desc = "State profile under the state dir";
    }
    {
      flag = "--state-dir";
      arg = "dir";
      desc = "Jail state root directory";
    }
    {
      flag = "--toolbox-dir";
      arg = "dir";
      desc = "Operator package profile bound into the jail PATH";
    }
    {
      flag = "--same-path";
      arg = "none";
      desc = "Mount the workspace at its host path";
    }
    {
      flag = "--tmpdir";
      arg = "dir";
      desc = "Directory holding the runtime data of this run";
    }
    {
      flag = "--mount";
      arg = "file";
      desc = "Extra read-write mount, HOSTPATH or HOSTPATH-GUESTPATH";
    }
    {
      flag = "--ro-mount";
      arg = "file";
      desc = "Extra read-only mount, HOSTPATH or HOSTPATH-GUESTPATH";
    }
    {
      flag = "--allow-domain";
      arg = "string";
      desc = "Add one domain to the network whitelist";
    }
    {
      flag = "--env";
      arg = "string";
      desc = "Set KEY=VAL inside the sandbox";
    }
    {
      flag = "--x11";
      arg = "none";
      desc = "Pass through the X11 or Wayland display socket";
    }
    {
      flag = "--git";
      arg = "choice";
      values = [
        "full"
        "limited"
        "none"
      ];
      desc = "How much of the repo the jail sees";
    }
    {
      flag = "--overlay-workspace";
      arg = "none";
      desc = "Make the workspace and rw mounts copy-on-write";
    }
    {
      flag = "--mask";
      arg = "string";
      desc = "Hide paths matching GLOB in every mounted tree";
    }
    {
      flag = "--sync-exclude";
      arg = "string";
      desc = "Never sync paths matching GLOB back to the host";
    }
    {
      flag = "--watch-interval";
      arg = "string";
      desc = "Seconds between unsynced-change checks, 0 disables";
    }
    {
      flag = "--max-mem";
      arg = "string";
      desc = "Memory limit of the jail scope, e.g. 8G, swap disabled";
    }
    {
      flag = "--max-cpu";
      arg = "string";
      desc = "CPU quota of the jail scope in percent, 200 is two cores";
    }
    {
      flag = "--max-pids";
      arg = "string";
      desc = "Maximum number of tasks in the jail scope";
    }
    {
      flag = "--no-net-filter";
      arg = "none";
      desc = "Disable network filtering entirely";
    }
    {
      flag = "--rw-skills";
      arg = "none";
      desc = "Mount skills read-write instead of read-only";
    }
    {
      flag = "--dangerous";
      arg = "none";
      desc = "Skip the permission prompts of the jailed tool";
    }
    {
      flag = "--merge-config";
      arg = "none";
      desc = "Merge host tool settings into the jail-private copy";
    }
    {
      flag = "--merge-config-from";
      arg = "file";
      desc = "Merge from an explicit settings file";
    }
    {
      flag = "--continue";
      arg = "none";
      desc = "Resume the most recent session";
    }
    {
      flag = "--resume";
      arg = "string";
      desc = "Session picker, or a session id to resume";
    }
    {
      flag = "--list-profiles";
      arg = "none";
      desc = "List state profiles and exit";
    }
    {
      flag = "--list-sessions";
      arg = "none";
      desc = "List the sessions of this profile and exit";
    }
    {
      flag = "--dry-run";
      arg = "none";
      desc = "Print the resolved sandbox without launching";
    }
    {
      flag = "--selftest";
      arg = "none";
      desc = "Run the sandbox self-check and exit";
    }
    {
      flag = "--quiet";
      arg = "none";
      desc = "Only warnings and errors";
    }
    {
      flag = "--verbose";
      arg = "none";
      desc = "Extra detail about mounts and network setup";
    }
    {
      flag = "--help";
      arg = "none";
      desc = "Show usage";
    }
  ];

  # Global flags of the umbrella, accepted before the command word.
  globalFlags = [
    {
      flag = "--dir";
      arg = "dir";
      desc = "Toolbox profile to act on";
    }
    {
      flag = "--pid";
      arg = "string";
      desc = "Act on the session of this runner pid";
    }
    {
      flag = "--pause";
      arg = "none";
      desc = "Wait for a keypress before exiting so a spawned pane stays open";
    }
    {
      flag = "--help";
      arg = "none";
      desc = "Show usage";
    }
  ];

  # The mount modes are the --git vocabulary plus ro, shared by `mount add`
  # and by the approval of an agent mount request.
  modeFlag = desc: {
    flag = "--mode";
    arg = "choice";
    values = [
      "ro"
      "full"
      "limited"
      "none"
      "overlay"
    ];
    inherit desc;
  };
  olderThan = {
    flag = "--older-than";
    arg = "string";
    desc = "Age threshold such as 30d or 12h";
  };
  dryRun = {
    flag = "--dry-run";
    arg = "none";
    desc = "Show what would happen and change nothing";
  };

  # The umbrella subcommand tree. `pos` is what the positional arguments of a
  # leaf complete to (file or nothing - a package attribute, a request id or
  # a mount name has nothing on disk to offer).
  #
  # Maintained by hand next to the Rust CLI, which is the authority: the
  # command words are dispatched in toolbox/src/main.rs (`run`) and each
  # group's subcommands and flags in the module that owns it (packages.rs,
  # brokerctl.rs, broker.rs, domain.rs, session.rs, launch.rs). A subcommand
  # or flag added there needs its entry here, and nothing checks that. Not
  # generated from the Rust side because the crate takes no dependencies
  # (toolbox/Cargo.toml), which rules out a completion generator, and the
  # runner half of this file describes a shell parser no Rust tool could
  # read anyway.
  commands = [
    {
      name = "launch";
      desc = "Run one of the tools inside the sandbox";
      # Subcommands are the tool names, which come from the runner set the
      # umbrella was built with, so this entry carries none of its own.
      subs = [ ];
    }
    {
      name = "mount";
      desc = "Attach a host tree to a running session or detach one";
      subs = [
        {
          name = "add";
          desc = "Attach a host path to the session";
          pos = "file";
          flags = [
            (modeFlag "How the tree is exposed to the jail")
            {
              flag = "--guest";
              arg = "string";
              desc = "Guest path to attach the tree at";
            }
            {
              flag = "--name";
              arg = "string";
              desc = "Name of the mount under its dock";
            }
          ];
        }
        {
          name = "remove";
          desc = "Detach a mount, syncing an isolated tree back first";
          flags = [
            {
              flag = "--auto";
              arg = "none";
              desc = "Sync the jail side back without asking";
            }
            {
              flag = "--discard";
              arg = "none";
              desc = "Drop the jail side changes unsynced";
            }
          ];
        }
        {
          name = "list";
          desc = "Show the mounts of the session";
        }
        {
          name = "docks";
          desc = "Show the directories a live mount can attach under";
        }
      ];
    }
    {
      name = "sync";
      desc = "Fold the jail side work back into the host trees";
      subs = [ ];
      pos = "file";
    }
    {
      name = "domain";
      desc = "Network whitelist of a running session, no subcommand opens a menu";
      subs = [
        {
          name = "list";
          desc = "Show the allowed domains and where each came from";
          flags = [
            {
              flag = "--json";
              arg = "none";
              desc = "Machine readable output";
            }
          ];
        }
        {
          name = "blocked";
          desc = "Show the names the filter refused, most hits first";
          flags = [
            {
              flag = "--json";
              arg = "none";
              desc = "Machine readable output";
            }
          ];
        }
        {
          name = "add";
          desc = "Allow a domain for the session";
          flags = [
            {
              flag = "--persist";
              arg = "none";
              desc = "Also append it to the domains file";
            }
          ];
        }
        {
          name = "remove";
          desc = "Stop allowing a domain now";
          flags = [
            {
              flag = "--persist";
              arg = "none";
              desc = "Also drop it from the domains file";
            }
          ];
        }
      ];
    }
    {
      name = "session";
      desc = "The live sandbox sessions of this host";
      subs = [
        {
          name = "list";
          desc = "Show every live session with its workspace and state";
        }
      ];
    }
    {
      name = "request";
      desc = "Package, mount and domain requests made by the jailed agents";
      subs = [
        {
          name = "list";
          desc = "Show the pending requests of every live broker";
          flags = [
            {
              flag = "--json";
              arg = "none";
              desc = "Machine readable output";
            }
          ];
        }
        {
          name = "answer";
          desc = "Walk the pending requests in a numbered picker";
        }
        {
          name = "approve";
          desc = "Approve one request by id";
          flags = [ (modeFlag "Mount mode to approve a mount request with") ];
        }
        {
          name = "deny";
          desc = "Refuse one request by id";
          flags = [
            {
              flag = "--reason";
              arg = "string";
              desc = "Text handed back to the agent";
            }
          ];
        }
      ];
    }
    {
      name = "toolbox";
      desc = "The package profile the jails see on their PATH";
      subs = [
        {
          name = "add";
          desc = "Install packages and renew their leases";
        }
        {
          name = "remove";
          desc = "Uninstall packages from the profile";
        }
        {
          name = "list";
          desc = "Show the installed packages";
        }
        {
          name = "upgrade";
          desc = "Upgrade the named packages or all of them";
        }
      ];
    }
    {
      name = "lease";
      desc = "Expiry of the toolbox packages";
      subs = [
        {
          name = "list";
          desc = "Show the leases and their age";
          flags = [
            olderThan
            {
              flag = "--json";
              arg = "none";
              desc = "Machine readable output";
            }
          ];
        }
        {
          name = "renew";
          desc = "Push the lease of a package out";
        }
        {
          name = "pin";
          desc = "Make a package permanent by dropping its lease";
        }
        {
          name = "remove";
          desc = "Uninstall a package now, leased or permanent";
        }
        {
          name = "prune";
          desc = "Remove the packages whose lease expired";
          flags = [
            olderThan
            dryRun
          ];
        }
        {
          name = "gc";
          desc = "Unpin the generations older than the lease period";
          flags = [
            olderThan
            dryRun
          ];
        }
      ];
    }
  ];

  subsOf = c: c.subs or [ ];
  flagsOf = s: s.flags or [ ];
  posOf = s: s.pos or "none";

  # Every flag that takes a value, anywhere in the tree, for the one `case`
  # that decides whether the word being completed is a flag value. Deduped on
  # name and kind only, so the same flag described differently in two places
  # (--mode) still yields a single arm.
  umbrellaValueFlags = lib.unique (
    map
      (f: {
        inherit (f) flag arg;
        values = f.values or [ ];
      })
      (
        lib.filter (f: f.arg != "none") (
          globalFlags ++ flags ++ lib.concatMap (c: lib.concatMap flagsOf (subsOf c)) commands
        )
      )
  );

  # Nix dedents the literal lines of an indented string but leaves an
  # interpolated block exactly as it was generated, so a multi-line arm has to
  # be re-indented by hand or the generated file comes out ragged. The first
  # line already sits at the interpolation point, hence only the rest.
  indentRest =
    pad: text:
    lib.concatStringsSep "\n" (
      lib.imap0 (i: line: if i == 0 || line == "" then line else pad + line) (lib.splitString "\n" text)
    );
  joinArms = pad: arms: indentRest pad (lib.concatStringsSep "\n" arms);

  joinFlags = fl: lib.concatMapStringsSep " " (f: f.flag) fl;
  allFlags = joinFlags flags;

  compgenArm = pat: gen: "${pat}) COMPREPLY=($(compgen ${gen} -- \"$cur\")); return ;;";

  # Choice flags get one arm each: every flag has its own value list, so
  # they cannot share a grouped arm the way the dir and file kinds do. The
  # string kind returns with no suggestions - a profile name or a glob is
  # not a path, and offering the cwd there is worse than offering nothing.
  bashValueArms =
    fl:
    let
      ofKind = kind: lib.filter (f: f.arg == kind) fl;
      nonEmpty = kind: ofKind kind != [ ];
      # Alternation for one bash `case` arm. Only ever called for a kind that
      # has members - an empty group would emit a bare `)` that bash rejects.
      alt = kind: lib.concatMapStringsSep "|" (f: f.flag) (ofKind kind);
    in
    map (f: compgenArm f.flag "-W \"${lib.concatStringsSep " " f.values}\"") (ofKind "choice")
    ++ lib.optional (nonEmpty "dir") (compgenArm (alt "dir") "-d")
    ++ lib.optional (nonEmpty "file") (compgenArm (alt "file") "-f")
    ++ lib.optional (nonEmpty "string") "${alt "string"}) return ;;";

  zshSpec =
    f:
    let
      head = "'${f.flag}[${f.desc}]";
    in
    if f.arg == "none" then
      "${head}'"
    else if f.arg == "dir" then
      "${head}:dir:_files -/'"
    else if f.arg == "file" then
      "${head}:path:_files'"
    else if f.arg == "choice" then
      "${head}:mode:(${lib.concatStringsSep " " f.values})'"
    else
      "${head}:value:'";

  # `cond` is a fish condition the completion is gated on, or null for one
  # that always applies. The umbrella needs the gate to keep one command's
  # flags out of another command's completion; a runner has no levels.
  fishSpec =
    bin: cond: f:
    let
      gate = lib.optionalString (cond != null) " -n '${cond}'";
      base = "complete -c ${bin}${gate} -l ${lib.removePrefix "--" f.flag} -d '${f.desc}'";
    in
    if f.arg == "none" then
      base
    else if f.arg == "choice" then
      "${base} -x -a '${lib.concatStringsSep " " f.values}'"
    else if f.arg == "dir" || f.arg == "file" then
      "${base} -r -F"
    else
      "${base} -x";

  runnerCompletions =
    { name }:
    let
      bin = "llm-custody-${name}";
    in
    {
      bash = pkgs.writeText "${bin}.bash" ''
        _llm_custody_${name}() {
          local cur prev
          cur="''${COMP_WORDS[COMP_CWORD]}"
          prev="''${COMP_WORDS[COMP_CWORD-1]}"
          case "$prev" in
            ${lib.concatStringsSep "\n    " (bashValueArms flags)}
          esac
          if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "${allFlags}" -- "$cur"))
          else
            COMPREPLY=($(compgen -f -- "$cur"))
          fi
        }
        complete -F _llm_custody_${name} ${bin}
      '';

      zsh = pkgs.writeText "_${bin}" ''
        #compdef ${bin}

        # -S: everything after a literal `--` belongs to the jailed tool, not to
        # the runner, so no runner flags are offered there.
        _arguments -S \
          ${lib.concatMapStringsSep " \\\n  " zshSpec flags} \
          '*:file:_files'
      '';

      fish = pkgs.writeText "${bin}.fish" ''
        ${lib.concatMapStringsSep "\n" (fishSpec bin null) flags}
      '';
    };

  umbrellaCompletions =
    { tools }:
    let
      bin = "llm-custody";
      cmdNames = map (c: c.name) commands;
      allCmdWords = lib.concatStringsSep " " cmdNames;
      allSubWords = lib.concatStringsSep " " (
        lib.unique (lib.concatMap (c: map (s: s.name) (subsOf c)) commands)
      );
      toolWords = lib.concatStringsSep " " tools;

      ## bash

      # One arm per leaf: flags when the word starts with a dash, the leaf's
      # own positional kind otherwise.
      bashSubArm =
        s:
        let
          fl = joinFlags (flagsOf s);
        in
        if posOf s == "file" then
          ''
            ${s.name})
              if [[ "$cur" == -* ]]; then
                COMPREPLY=($(compgen -W "${fl}" -- "$cur"))
              else
                COMPREPLY=($(compgen -f -- "$cur"))
              fi
              ;;''
        else if fl == "" then
          "${s.name}) ;;"
        else
          ''${s.name}) COMPREPLY=($(compgen -W "${fl}" -- "$cur")) ;;'';

      bashCmdArm =
        c:
        if c.name == "launch" then
          ''
            launch)
              if [ -z "$sub" ]; then
                COMPREPLY=($(compgen -W "${toolWords}" -- "$cur"))
              else
                COMPREPLY=($(compgen -W "${allFlags}" -- "$cur"))
              fi
              ;;''
        else if subsOf c == [ ] then
          ''
            ${c.name})
              COMPREPLY=($(compgen ${if (c.pos or "none") == "file" then "-f" else "-W \"\""} -- "$cur"))
              ;;''
        else
          ''
            ${c.name})
              case "$sub" in
                "") COMPREPLY=($(compgen -W "${
                  lib.concatMapStringsSep " " (s: s.name) (subsOf c)
                }" -- "$cur")) ;;
                ${joinArms "    " (map bashSubArm (subsOf c))}
              esac
              ;;'';

      # Flags that take a value, as a bash alternation, so the word scan can
      # skip a value and not mistake it for the command word.
      valueFlagAlt = lib.concatMapStringsSep "|" (f: f.flag) umbrellaValueFlags;

      ## zsh

      zshDescribe = entries: lib.concatMapStringsSep " " (e: "'${e.name}:${e.desc}'") entries;

      zshLeafArm =
        s:
        let
          specs = map zshSpec (flagsOf s);
          tail = if posOf s == "file" then [ "'*:path:_files'" ] else [ ];
          all = specs ++ tail;
        in
        if all == [ ] then "${s.name}) ;;" else "${s.name}) _arguments ${lib.concatStringsSep " " all} ;;";

      zshCmdFn =
        c:
        if c.name == "launch" then
          ''
            _llm_custody_launch() {
              local curcontext="$curcontext" state line
              typeset -A opt_args
              local -a tools
              tools=(${lib.concatMapStringsSep " " (t: "'${t}:Run ${t} inside the sandbox'") tools})
              _arguments -C '1:tool:->tool' '*::arg:->args'
              case $state in
                tool) _describe -t tools 'tool' tools ;;
                args)
                  # After the tool name the runner itself parses everything, so
                  # the runner flag list is what gets offered here.
                  _arguments -S \
                    ${joinArms "        " (map (f: zshSpec f + " \\") flags)}
                    '*:file:_files'
                  ;;
              esac
            }
          ''
        else if subsOf c == [ ] then
          ''
            _llm_custody_${c.name}() {
              _arguments '*:path:_files'
            }
          ''
        else
          ''
            _llm_custody_${c.name}() {
              local curcontext="$curcontext" state line
              typeset -A opt_args
              local -a subs
              subs=(${zshDescribe (subsOf c)})
              _arguments -C '1:subcommand:->sub' '*::arg:->args'
              case $state in
                sub) _describe -t subcommands '${c.name} subcommand' subs ;;
                args)
                  case $words[1] in
                    ${joinArms "        " (map zshLeafArm (subsOf c))}
                  esac
                  ;;
              esac
            }
          '';

      ## fish

      # `__fish_seen_subcommand_from` matches anywhere on the line, so a leaf
      # condition names both levels: `toolbox add` cannot light up the flags
      # of `mount add` because `mount` is not on the line.
      fishCmdLines =
        c:
        let
          seen = "__fish_seen_subcommand_from ${c.name}";
          subNames = map (s: s.name) (subsOf c);
          subLines = map (
            s:
            "complete -c ${bin} -n '${seen}; and not __fish_seen_subcommand_from ${lib.concatStringsSep " " subNames}' -a ${s.name} -d '${s.desc}'"
          ) (subsOf c);
          leafLines = lib.concatMap (
            s: map (fishSpec bin "${seen}; and __fish_seen_subcommand_from ${s.name}") (flagsOf s)
          ) (subsOf c);
          launchLines =
            map (
              t:
              "complete -c ${bin} -n '${seen}; and not __fish_seen_subcommand_from ${toolWords}' -a ${t} -d 'Run ${t} inside the sandbox'"
            ) tools
            ++ map (fishSpec bin seen) flags;
        in
        if c.name == "launch" then launchLines else subLines ++ leafLines;

      fishLines = [
        "# Generated by lib/completions.nix - do not edit."
        "complete -c ${bin} -f"
      ]
      ++ map (fishSpec bin "not __fish_seen_subcommand_from ${allCmdWords}") globalFlags
      ++ map (c: "complete -c ${bin} -n '__fish_use_subcommand' -a ${c.name} -d '${c.desc}'") commands
      ++ lib.concatMap fishCmdLines commands;
    in
    {
      bash = pkgs.writeText "${bin}.bash" ''
        _llm_custody() {
          local cur prev cmd sub word i
          cur="''${COMP_WORDS[COMP_CWORD]}"
          prev="''${COMP_WORDS[COMP_CWORD-1]}"

          # A flag value is completed from the flag, whatever level it is on.
          case "$prev" in
            ${lib.concatStringsSep "\n    " (bashValueArms umbrellaValueFlags)}
          esac

          # The first two words that are neither a flag nor a flag value are
          # the command and its subcommand, and they decide the level.
          cmd=""
          sub=""
          for (( i = 1; i < COMP_CWORD; i++ )); do
            word="''${COMP_WORDS[i]}"
            case "$word" in -*) continue ;; esac
            case "''${COMP_WORDS[i-1]}" in ${valueFlagAlt}) continue ;; esac
            if [ -z "$cmd" ]; then
              cmd="$word"
            elif [ -z "$sub" ]; then
              sub="$word"
            fi
          done

          case "$cmd" in
            "")
              COMPREPLY=($(compgen -W "${allCmdWords} ${joinFlags globalFlags}" -- "$cur"))
              ;;
            ${joinArms "    " (map bashCmdArm commands)}
          esac
        }
        complete -F _llm_custody ${bin}
      '';

      zsh = pkgs.writeText "_${bin}" ''
        #compdef ${bin}

        ${lib.concatMapStringsSep "\n" zshCmdFn commands}
        _llm_custody() {
          local curcontext="$curcontext" state line
          typeset -A opt_args
          local -a commands
          commands=(${zshDescribe commands})

          _arguments -C \
            ${lib.concatMapStringsSep " \\\n    " zshSpec globalFlags} \
            '1:command:->command' \
            '*::arg:->args'

          case $state in
            command) _describe -t commands 'llm-custody command' commands ;;
            args)
              case $words[1] in
                ${joinArms "        " (map (c: "${c.name}) _llm_custody_${c.name} ;;") commands)}
              esac
              ;;
          esac
        }

        _llm_custody "$@"
      '';

      fish = pkgs.writeText "${bin}.fish" ''
        ${lib.concatStringsSep "\n" fishLines}
      '';
    };

in
{
  # Completions for one runner script, installed with packages.<tool>.
  runner = runnerCompletions;
  # Completions for the umbrella command, installed with packages.default.
  # `tools` comes from the runner set the umbrella was built with, so a new
  # tool shows up under `launch` without an edit here.
  umbrella = umbrellaCompletions;
}
