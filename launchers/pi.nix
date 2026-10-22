# Per-tool bwrap launcher config, mirroring the old QEMU jail's
# guests/pi.nix content but as a plain function instead of a NixOS module -
# there's no guest OS to attach options to under bwrap. Same
# `{ pkgs, pi-coding-agent, ... }:` signature convention the old guest
# modules used via specialArgs, so adding a tool back later stays
# low-friction: lib/mkBwrapRunner.nix and tools.nix don't need to change,
# just a new launchers/<tool>.nix + tools.nix entry.
{ pkgs, pi-coding-agent, ... }:
let
  toolbox = import ../lib/toolbox.nix;
in
{
  toolPackage = pi-coding-agent;

  # Same reflection pi's real ~/.pi/agent setup does: global instructions
  # copied in as AGENTS.md, host-declared extensions (config/home/pi.nix
  # manifest) merged into settings.json, and defaultProjectTrust forced on
  # every launch since pi's own /login flow can drop it from settings.json.
  # Runs directly against $STATE_DIR - under bwrap that IS the real host
  # state directory, no 9p indirection to route a guest-side service
  # through like the old QEMU jail needed.
  bootstrapScript = ''
    # `|| true`: when STATE_DIR is a symlink onto the real ~/.pi/agent (as
    # when testing with real host credentials instead of a fresh
    # jail-private dir), AGENTS.md is itself home-manager's
    # mkOutOfStoreSymlink onto this exact CLAUDE.md, so cp correctly refuses
    # a same-file copy - not an error.
    [ -f "$HOME/.claude/CLAUDE.md" ] && cp "$HOME/.claude/CLAUDE.md" "$STATE_DIR/AGENTS.md" 2>/dev/null || true

    # Appended after the copy above, which overwrites the file on every
    # launch - so this is rewritten every launch too and never accumulates.
    # Without it an agent that hits a missing tool keeps trying to install it
    # (nix, nix-shell, comma) against a read-only store instead of asking.
    # printf, not a heredoc: this whole script is interpolated into
    # mkBwrapRunner.nix's indented Nix string, where a flush-left heredoc
    # terminator would drag that string's dedent to zero and break every
    # other line in it.
    #
    # The disable below is for the markdown backticks in the notice: inside
    # the single quotes escapeShellArg puts around it they are literal text,
    # which is the point, but SC2016 reads them as a command substitution
    # that will not expand - and writeShellApplication fails the build on an
    # info-level finding.
    # shellcheck disable=SC2016
    printf '%s' ${pkgs.lib.escapeShellArg toolbox.notice} >> "$STATE_DIR/AGENTS.md"

    SETTINGS="$STATE_DIR/settings.json"
    MANIFEST="$HOME/.config/llm-custody/pi-extensions"
    BASE='{}'
    [ -f "$SETTINGS" ] && BASE=$(<"$SETTINGS")
    if [ -r "$MANIFEST" ]; then
      EXT_JSON=$(${pkgs.jq}/bin/jq -Rn '[inputs | select(length > 0)]' "$MANIFEST")
      printf '%s' "$BASE" | ${pkgs.jq}/bin/jq --argjson ext "$EXT_JSON" \
        '.extensions = $ext | .defaultProjectTrust = "trusted"' > "$SETTINGS.tmp"
    else
      printf '%s' "$BASE" | ${pkgs.jq}/bin/jq '.defaultProjectTrust = "trusted"' > "$SETTINGS.tmp"
    fi
    mv "$SETTINGS.tmp" "$SETTINGS"
  '';
}
