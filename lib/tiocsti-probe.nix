# The --selftest input-injection probe (see tiocsti-probe.c), built like the
# seccomp denylist emitter: a tiny C program is the only thing that can issue
# a specific ioctl without dragging an interpreter into the runner's closure.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "llm-custody-tiocsti-probe";
  version = "1";
  src = ./tiocsti-probe.c;
  dontUnpack = true;
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o tiocsti-probe "$src"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 tiocsti-probe $out/bin/tiocsti-probe
    runHook postInstall
  '';
}
