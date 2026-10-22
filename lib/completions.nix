# Shell completions for the runner's own flags, for bash, zsh and fish.
#
# All three are generated from the single `flags` list below rather than
# hand-written per shell: a flag added to lib/mkBwrapRunner.nix's parser
# needs one line here instead of three files that drift apart on their own.
#
# Descriptions must avoid apostrophes, '[', ']' and ':'. The first would end
# the single-quoted string carrying them in both the zsh and the fish output,
# and zsh's _arguments treats the other three as spec structure.
{ pkgs, name }:

let
  inherit (pkgs) lib;

  bin = "llm-custody-${name}";

  # arg: none | string | dir | file | choice (choice carries `values`)
  flags = [
    { flag = "--profile"; arg = "string"; desc = "State profile under the state dir"; }
    { flag = "--state-dir"; arg = "dir"; desc = "Jail state root directory"; }
    { flag = "--toolbox-dir"; arg = "dir"; desc = "Operator package profile bound into the jail PATH"; }
    { flag = "--same-path"; arg = "none"; desc = "Mount the workspace at its host path"; }
    { flag = "--tmpdir"; arg = "dir"; desc = "Directory holding the runtime data of this run"; }
    { flag = "--mount"; arg = "file"; desc = "Extra read-write mount, HOSTPATH or HOSTPATH-GUESTPATH"; }
    { flag = "--ro-mount"; arg = "file"; desc = "Extra read-only mount, HOSTPATH or HOSTPATH-GUESTPATH"; }
    { flag = "--allow-domain"; arg = "string"; desc = "Add one domain to the network whitelist"; }
    { flag = "--env"; arg = "string"; desc = "Set KEY=VAL inside the sandbox"; }
    { flag = "--x11"; arg = "none"; desc = "Pass through the X11 or Wayland display socket"; }
    {
      flag = "--git";
      arg = "choice";
      values = [ "full" "limited" "none" ];
      desc = "How much of the repo the jail sees";
    }
    { flag = "--overlay-workspace"; arg = "none"; desc = "Make the workspace and rw mounts copy-on-write"; }
    { flag = "--mask"; arg = "string"; desc = "Hide paths matching GLOB in every mounted tree"; }
    { flag = "--sync-exclude"; arg = "string"; desc = "Never sync paths matching GLOB back to the host"; }
    { flag = "--watch-interval"; arg = "string"; desc = "Seconds between unsynced-change checks, 0 disables"; }
    { flag = "--no-net-filter"; arg = "none"; desc = "Disable network filtering entirely"; }
    { flag = "--rw-skills"; arg = "none"; desc = "Mount skills read-write instead of read-only"; }
    { flag = "--dangerous"; arg = "none"; desc = "Skip the permission prompts of the jailed tool"; }
    { flag = "--merge-config"; arg = "none"; desc = "Merge host tool settings into the jail-private copy"; }
    { flag = "--merge-config-from"; arg = "file"; desc = "Merge from an explicit settings file"; }
    { flag = "--continue"; arg = "none"; desc = "Resume the most recent session"; }
    { flag = "--resume"; arg = "string"; desc = "Session picker, or a session id to resume"; }
    { flag = "--list-profiles"; arg = "none"; desc = "List state profiles and exit"; }
    { flag = "--list-sessions"; arg = "none"; desc = "List the sessions of this profile and exit"; }
    { flag = "--dry-run"; arg = "none"; desc = "Print the resolved sandbox without launching"; }
    { flag = "--selftest"; arg = "none"; desc = "Run the sandbox self-check and exit"; }
    { flag = "--quiet"; arg = "none"; desc = "Only warnings and errors"; }
    { flag = "--verbose"; arg = "none"; desc = "Extra detail about mounts and network setup"; }
    { flag = "--help"; arg = "none"; desc = "Show usage"; }
  ];

  ofKind = kind: lib.filter (f: f.arg == kind) flags;
  nonEmpty = kind: ofKind kind != [ ];
  # Alternation for one bash `case` arm. Only ever called for a kind that
  # has members - an empty group would emit a bare `)` that bash rejects.
  alt = kind: lib.concatMapStringsSep "|" (f: f.flag) (ofKind kind);

  allFlags = lib.concatMapStringsSep " " (f: f.flag) flags;

  compgenArm = pat: gen: "${pat}) COMPREPLY=($(compgen ${gen} -- \"$cur\")); return ;;";

  # Choice flags get one arm each: every flag has its own value list, so
  # they cannot share a grouped arm the way the dir and file kinds do. The
  # string kind returns with no suggestions - a profile name or a glob is
  # not a path, and offering the cwd there is worse than offering nothing.
  bashArms =
    map (f: compgenArm f.flag "-W \"${lib.concatStringsSep " " f.values}\"") (ofKind "choice")
    ++ lib.optional (nonEmpty "dir") (compgenArm (alt "dir") "-d")
    ++ lib.optional (nonEmpty "file") (compgenArm (alt "file") "-f")
    ++ lib.optional (nonEmpty "string") "${alt "string"}) return ;;";

  zshSpec = f:
    let head = "'${f.flag}[${f.desc}]";
    in
    if f.arg == "none" then "${head}'"
    else if f.arg == "dir" then "${head}:dir:_files -/'"
    else if f.arg == "file" then "${head}:path:_files'"
    else if f.arg == "choice" then "${head}:mode:(${lib.concatStringsSep " " f.values})'"
    else "${head}:value:'";

  fishSpec = f:
    let base = "complete -c ${bin} -l ${lib.removePrefix "--" f.flag} -d '${f.desc}'";
    in
    if f.arg == "none" then base
    else if f.arg == "choice" then "${base} -x -a '${lib.concatStringsSep " " f.values}'"
    else if f.arg == "dir" || f.arg == "file" then "${base} -r -F"
    else "${base} -x";

in
{
  bash = pkgs.writeText "${bin}.bash" ''
    _llm_custody_${name}() {
      local cur prev
      cur="''${COMP_WORDS[COMP_CWORD]}"
      prev="''${COMP_WORDS[COMP_CWORD-1]}"
      case "$prev" in
        ${lib.concatStringsSep "\n    " bashArms}
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
    ${lib.concatMapStringsSep "\n" fishSpec flags}
  '';
}
