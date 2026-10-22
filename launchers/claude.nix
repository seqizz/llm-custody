# Per-tool bwrap launcher config for Claude Code. Same
# `{ pkgs, <tool-package>, ... }:` convention as launchers/pi.nix - the `...`
# swallows the tool packages this launcher doesn't use, so only claude-code
# becomes a store dependency of the claude runner.
{ pkgs, claude-code, ... }:
let
  toolbox = import ../lib/toolbox.nix;
in
{
  toolPackage = claude-code;

  # Applied as bwrap --setenv before the user's own --env pairs, so --env
  # still wins for any of these.
  extraEnv = {
    # The package lives in the read-only store, so an in-place self-update
    # can only fail noisily - and checking for one pulls registry traffic the
    # whitelist would otherwise have to allow.
    DISABLE_AUTOUPDATER = "1";
    DISABLE_TELEMETRY = "1";
    DISABLE_ERROR_REPORTING = "1";
    # Drops feature-flag and analytics fetches, which is what keeps
    # statsig/sentry out of the domain whitelist entirely.
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    # The in-jail uid is 0: the netns holder maps inner uid 0 to the invoking
    # host uid, which is what keeps workspace writes owned by the real user.
    # Claude Code otherwise refuses --dangerously-skip-permissions for a
    # uid-0 process; IS_SANDBOX tells it the isolation is already in place.
    IS_SANDBOX = "1";
  };

  # Runs host-side against $STATE_DIR (the very directory CLAUDE_CONFIG_DIR
  # will point at inside the sandbox) before bwrap starts, so it can use the
  # runner's already-resolved $WORKSPACE_GUEST.
  bootstrapScript = ''
    # Claude Code's user-level memory file. `|| true` for the same reason
    # pi's launcher needs it: if STATE_DIR is symlinked onto a real
    # ~/.claude, source and destination are the same file and cp correctly
    # refuses - not an error.
    [ -f "$HOME/.claude/CLAUDE.md" ] && cp "$HOME/.claude/CLAUDE.md" "$STATE_DIR/CLAUDE.md" 2>/dev/null || true

    # Rewritten on every launch because the copy above overwrites the file
    # first, so it never accumulates. printf rather than a heredoc: this
    # script is interpolated into mkBwrapRunner.nix's indented Nix string,
    # where a flush-left terminator would break that string's dedent.
    #
    # The disable below is for the markdown backticks in the notice: inside
    # the single quotes escapeShellArg puts around it they are literal text,
    # which is the point, but SC2016 reads them as a command substitution
    # that will not expand - and writeShellApplication fails the build on an
    # info-level finding.
    # shellcheck disable=SC2016
    printf '%s' ${pkgs.lib.escapeShellArg toolbox.notice} >> "$STATE_DIR/CLAUDE.md"

    # .claude.json holds onboarding state and per-project trust, and lives
    # inside CLAUDE_CONFIG_DIR rather than $HOME once that var is set. A
    # fresh jail-private dir means claude would otherwise open with the
    # onboarding wizard and the "do you trust this folder" dialog, which
    # hangs a non-interactive `-p` run outright. Keyed by $WORKSPACE_GUEST,
    # not a literal /workspace, so --same-path runs are trusted too.
    CLAUDE_JSON="$STATE_DIR/.claude.json"
    BASE='{}'
    if [ -f "$CLAUDE_JSON" ] && ${pkgs.jq}/bin/jq -e . "$CLAUDE_JSON" >/dev/null 2>&1; then
      BASE=$(<"$CLAUDE_JSON")
    fi
    printf '%s' "$BASE" | ${pkgs.jq}/bin/jq --arg ws "$WORKSPACE_GUEST" '
      .hasCompletedOnboarding = true
      | .bypassPermissionsModeAccepted = true
      | .theme = (.theme // "dark")
      | .projects[$ws] = ((.projects[$ws] // {}) + {
          hasTrustDialogAccepted: true,
          hasCompletedProjectOnboarding: true
        })' > "$CLAUDE_JSON.tmp"
    mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
  '';
}
