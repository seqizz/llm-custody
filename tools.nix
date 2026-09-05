{
  pi = {
    launcherModule = ./launchers/pi.nix;
    defaults = {
      configDirName = ".pi/agent";
      configEnvVar = "PI_CODING_AGENT_DIR";
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
