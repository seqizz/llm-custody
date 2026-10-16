{
  pi = {
    launcherModule = ./launchers/pi.nix;
    defaults = {
      configDirName = ".pi/agent";
      configEnvVar = "PI_CODING_AGENT_DIR";
      # Where this tool looks for user-level skills inside its home,
      # relative to /home/user. Host skill dirs are bound here one entry at
      # a time.
      skillsDir = ".agents/skills";
      # Subdirectory of the state dir holding session transcripts, for
      # --list-sessions. Both supported tools store one *.jsonl per session
      # under a per-project subdirectory, so the runner just walks it.
      # (pi: getSessionsDir() = <agentDir>/sessions in its dist/config.js.)
      sessionsDir = "sessions";
      # Root-level settings.json keys --merge-config must never offer: the
      # bootstrapScript owns these and rewrites them on every launch, so
      # adopting a host value would be undone immediately.
      mergeSkipKeys = [ "extensions" "defaultProjectTrust" ];
      # Per-tool translation table for the runner's generic session-resume
      # flags. The runner accepts -c/--continue/-r/--resume and maps them to
      # whatever this tool actually accepts: `continue` = resume the most
      # recent session without prompting, `resume` = interactive session
      # picker, `resumeWithId` = target a specific session id directly.
      # (pi's real CLI, verified in pi's cli/args.js: --continue/-c,
      # --resume/-r picker with no id arg, --session <path|id> for a
      # specific one.)
      resumeFlags = {
        continue = "--continue";
        resume = "--resume";
        resumeWithId = "--session";
      };
      allowedDomains = [
        "pi.dev"
        "api.anthropic.com"
        "api.openai.com"
        "auth.openai.com"
        "chatgpt.com"
        "generativelanguage.googleapis.com"
        "github.com"
        "api.github.com"
        "openrouter.ai"
        "api.deepseek.com"
        "api.mistral.ai"
        "api.x.ai"
        "api.groq.com"
        "api.cerebras.ai"
        "api.novita.ai"
      ];
    };
  };

  claude = {
    launcherModule = ./launchers/claude.nix;
    defaults = {
      configDirName = ".claude";
      configEnvVar = "CLAUDE_CONFIG_DIR";
      # Claude Code reads user-level skills from its config dir only, and
      # CLAUDE_CONFIG_DIR already points that at the jail-private state dir,
      # so these binds land *inside* the state mount (they stack because
      # bwrap applies them after it).
      skillsDir = ".claude/skills";
      # Claude Code keeps one *.jsonl per session under projects/<cwd>/ in
      # its config dir, same shape pi uses for sessions/.
      sessionsDir = "projects";
      # Trust and onboarding live in .claude.json, not settings.json, so the
      # bootstrapScript rewrites nothing here and every settings key is
      # offerable to --merge-config.
      mergeSkipKeys = [ ];
      dangerousFlag = "--dangerously-skip-permissions";
      # claude's --resume takes an optional session id of its own, so the
      # picker and the direct-id form are the same flag.
      resumeFlags = {
        continue = "--continue";
        resume = "--resume";
        resumeWithId = "--resume";
      };
      # platform.claude.com and claude.ai are only needed by the in-jail
      # /login flow, not by an API-key session: the OAuth authorize page,
      # its code callback and the token exchange all live on
      # platform.claude.com (/oauth/authorize, /oauth/code/callback,
      # /v1/oauth/token), with the client metadata document on claude.ai.
      # This is where the old console.anthropic.com endpoints moved to -
      # claude-code 2.1.x no longer references that host at all, so a
      # whitelist built around it fails the token exchange with an opaque
      # OAuth error.
      #
      # statsig/sentry are deliberately absent: the launcher's extraEnv
      # turns off telemetry, error reporting and non-essential traffic, so
      # nothing should try to reach them.
      allowedDomains = [
        "api.anthropic.com"
        "platform.claude.com"
        "claude.ai"
        "github.com"
        "api.github.com"
      ];
    };
  };
}
