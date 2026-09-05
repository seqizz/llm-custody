{
  pi = {
    launcherModule = ./launchers/pi.nix;
    defaults = {
      configDirName = ".pi/agent";
      configEnvVar = "PI_CODING_AGENT_DIR";
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
}
